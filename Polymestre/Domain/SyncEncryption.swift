import Foundation

/// Le chiffrement des lignes, entre le moteur et le transport — le pendant de
/// `windows/src/sync/encryptedTransport.ts`.
///
/// Le moteur parle en lignes « à plat » (`id`, `updated_at`, `deleted_at` et les
/// colonnes du modèle). Le serveur ne reçoit que l'enveloppe :
///
///     { id, updated_at, deleted_at, key_id, payload }      payload = bytea
///
/// `payload` est le JSON des champs, scellé par AES-256-GCM (`SyncCrypto`). Une pierre
/// tombale n'a pas de payload. Les lignes à laisser de côté (autre clé, illisible)
/// reviennent marquées `_skipped` : le moteur les saute sans y toucher.
final class SyncSkipStats: @unchecked Sendable {
    private let lock = NSLock()
    private var foreign = 0, unreadable = 0
    var foreignKey: Int { lock.lock(); defer { lock.unlock() }; return foreign }
    var unreadableCount: Int { lock.lock(); defer { lock.unlock() }; return unreadable }
    func noteForeign() { lock.lock(); foreign += 1; lock.unlock() }
    func noteUnreadable() { lock.lock(); unreadable += 1; lock.unlock() }
}

/// Le serveur nous a rendu, à l'envoi, une ligne d'une autre clé.
struct SyncForeignKeyError: LocalizedError {
    var errorDescription: String? { SyncMessages.foreignKey }
}

enum SyncMessages {
    static let foreignKey = String(localized: "Clé différente : des données de ce compte sont chiffrées avec une autre clé et restent ignorées. Ajoute cet appareil depuis un appareil connecté, ou utilise la clé de secours.")
}

final class EncryptingSyncTransport: SyncTransport {
    private let inner: SyncTransport
    private let keys: SyncCrypto.Keys
    let stats: SyncSkipStats

    private static let meta: Set<String> = ["id", "updated_at", "deleted_at", "server_updated_at", "key_id", "payload"]

    init(inner: SyncTransport, keys: SyncCrypto.Keys, stats: SyncSkipStats = SyncSkipStats()) {
        self.inner = inner
        self.keys = keys
        self.stats = stats
    }

    func push(table: String, rows: [[String: Any]]) async throws -> [[String: Any]] {
        guard !rows.isEmpty else { return [] }
        let kept = try await inner.push(table: table, rows: try rows.map { try seal(table, $0) })
        return try kept.map { row in
            let opened = open(table, row)
            if opened["_skipped"] as? String == "foreignKey" { throw SyncForeignKeyError() }
            return opened
        }
    }

    func pull(table: String, since: String?, afterID: String?, limit: Int) async throws -> [[String: Any]] {
        try await inner.pull(table: table, since: since, afterID: afterID, limit: limit).map { row in
            let opened = open(table, row)
            switch opened["_skipped"] as? String {
            case "foreignKey": stats.noteForeign()
            case "unreadable": stats.noteUnreadable()
            default: break
            }
            return opened
        }
    }

    private func seal(_ table: String, _ row: [String: Any]) throws -> [String: Any] {
        let id = (row["id"] as? String ?? "").lowercased()
        let tombstone = !(row["deleted_at"] is NSNull) && row["deleted_at"] != nil
        var fields: [String: Any] = [:]
        for (k, v) in row where !Self.meta.contains(k) { fields[k] = v }
        var envelope: [String: Any] = [
            "id": id,
            "updated_at": row["updated_at"] ?? NSNull(),
            "deleted_at": row["deleted_at"] ?? NSNull(),
            "key_id": keys.keyID,
            "payload": NSNull(),
        ]
        if !tombstone {
            envelope["payload"] = SyncCrypto.bytea(try SyncCrypto.sealRow(dataKey: keys.dataKey, table: table, id: id, fields: fields))
        }
        return envelope
    }

    /// Enveloppe du serveur → ligne à plat.
    private func open(_ table: String, _ env: [String: Any]) -> [String: Any] {
        var base: [String: Any] = [:]
        for k in ["id", "updated_at", "deleted_at", "server_updated_at"] { base[k] = env[k] ?? NSNull() }
        if env["key_id"] as? String != keys.keyID { base["_skipped"] = "foreignKey"; return base }
        if !(base["deleted_at"] is NSNull) { return base }
        guard let box = SyncCrypto.data(fromBytea: env["payload"]),
              let id = env["id"] as? String,
              let fields = try? SyncCrypto.openRow(dataKey: keys.dataKey, table: table, id: id, box: box) else {
            base["_skipped"] = "unreadable"
            return base
        }
        return fields.merging(base) { _, new in new }
    }
}
