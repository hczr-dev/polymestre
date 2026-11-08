import Foundation
import SwiftData

/// Le moteur : envoyer ce qui a changé ici, lire ce qui a changé ailleurs.
///
/// Le pendant Swift de `windows/src/sync/engine.ts` + `store.ts`. Différences
/// voulues, imposées par SwiftData :
///   - pas de colonnes `updated_at` / `dirty` dans la base : elles sont déduites en
///     comparant l'empreinte du contenu à celle du dernier état synchronisé
///     (`SyncMeta`) ; une ligne qui change reçoit `updated_at = maintenant` ;
///   - une suppression n'est plus visible : un objet connu dont l'identifiant a
///     disparu reçoit une pierre tombale ;
///   - la lecture précède l'envoi : une ligne locale identique à celle du serveur
///     (cas d'un appareil dont iCloud vient d'apporter les données) est adoptée
///     sans rien envoyer.
actor SyncEngine {

    struct Report: Equatable {
        var pushed = 0
        var pulled = 0
        var keptLocal = 0
        var deleted = 0
        var orphans = 0
        var summary: String {
            Plural.count(pushed, "\(pushed) envoyé", "\(pushed) envoyés") + ", " + Plural.count(pulled, "\(pulled) lu", "\(pulled) lus")
        }
    }

    enum Failure: LocalizedError {
        case massDeletion(Int)
        case missingRow(String, String)
        var errorDescription: String? {
            switch self {
            case .massDeletion(let n):
                return String(localized: "\(n) éléments ont disparu de cet appareil d'un coup : rien n'est supprimé ailleurs tant que tu ne l'as pas confirmé.")
            case .missingRow(let table, let id):
                return String(localized: "\(table) : le serveur n'a pas renvoyé \(id).")
            }
        }
    }

    /// Marge de relecture du curseur : une transaction peut valider après une plus récente.
    static let cursorOverlapSeconds = 120

    private let container: ModelContainer
    private let transport: SyncTransport
    private let store: SyncStateStore
    private let tables: [any AnySyncTable]
    private let batch: Int
    private let clock: () -> Date

    init(container: ModelContainer, transport: SyncTransport, store: SyncStateStore,
         tables: [any AnySyncTable] = SyncSchema.tables, batch: Int = 200, clock: @escaping () -> Date = { Date() }) {
        self.container = container
        self.transport = transport
        self.store = store
        self.tables = tables
        self.batch = batch
        self.clock = clock
    }

    // MARK: - Une passe

    private var running: Task<Report, Error>?

    /// Une seule passe à la fois ; un appel pendant l'autre attend la sienne.
    func sync(pull: Bool, acceptMassDeletion: Bool = false) async throws -> Report {
        if let running { return try await running.value }
        let task = Task { try await self.run(pull: pull, acceptMassDeletion: acceptMassDeletion) }
        running = task
        defer { running = nil }
        return try await task.value
    }

    private func run(pull: Bool, acceptMassDeletion: Bool) async throws -> Report {
        let pass = Pass(tables: tables, store: store, transport: transport, batch: batch, clock: clock,
                        context: ModelContext(container), acceptMassDeletion: acceptMassDeletion)
        defer { store.save() }
        try pass.scan()
        guard pull || pass.hasDirty else { return pass.report }
        if pull {
            for t in tables { try await pass.pullTable(t) }
            pass.resolvePending()
            try pass.save()
            try pass.scan()
        }
        for t in tables { try await pass.pushTable(t) }
        try pass.save()
        store.state.lastSyncAt = clock()
        store.markChanged()
        return pass.report
    }

    // MARK: - La passe

    private final class Pass {
        let context: ModelContext
        let acceptMassDeletion: Bool
        var report = Report()
        /// table → id → objet / contenu courant (relations en attente comprises).
        var objects: [String: [String: AnyObject]] = [:]
        var payloads: [String: [String: SyncPayload]] = [:]

        init(tables: [any AnySyncTable], store: SyncStateStore, transport: SyncTransport, batch: Int,
             clock: @escaping () -> Date, context: ModelContext, acceptMassDeletion: Bool) {
            self.tables = tables
            self.store = store
            self.transport = transport
            self.batch = batch
            self.clock = clock
            self.context = context
            self.acceptMassDeletion = acceptMassDeletion
            context.autosaveEnabled = false
        }

        let tables: [any AnySyncTable]
        let store: SyncStateStore
        let transport: SyncTransport
        let batch: Int
        let clock: () -> Date
        var now: String { SyncTime.string(clock()) }

        func table(_ name: String) -> (any AnySyncTable)? { tables.first { $0.name == name } }
        func meta(_ t: String, _ id: String) -> SyncMeta? { store.state.rows[t]?[id] }
        func setMeta(_ t: String, _ id: String, _ m: SyncMeta?) {
            store.state.rows[t, default: [:]][id] = m
            store.markChanged()
        }

        var hasDirty: Bool {
            store.state.rows.values.contains { $0.values.contains { $0.isDirty } }
        }

        func hash(_ t: any AnySyncTable, _ p: SyncPayload) -> String { SyncHash.of(p, columns: t.columns) }

        /// Le contenu local d'un objet, avec les relations encore en attente remises en place.
        func currentPayload(_ t: any AnySyncTable, _ id: String, _ object: AnyObject) -> SyncPayload {
            var p = t.payload(of: object)
            if let pending = meta(t.name, id)?.pending {
                for (col, rid) in pending where p[col] == .null { p[col] = .text(rid) }
            }
            return p
        }

        func save() throws {
            guard context.hasChanges else { return }
            try SyncSaveGate.shared.perform { try context.save() }
        }

        // MARK: Détection des changements locaux

        func scan() throws {
            objects = [:]
            payloads = [:]
            var ghosts: [(any AnySyncTable, AnyObject)] = []
            var vanished: [(String, String)] = []
            var live = 0
            for t in tables {
                var seen = Set<String>()
                var objs: [String: AnyObject] = [:]
                var pays: [String: SyncPayload] = [:]
                for (uuid, object) in try t.fetchAll(context) {
                    let id = uuid.uuidString.lowercased()
                    // Un doublon (iCloud en fusionne) : le premier compte, l'autre sera retiré par la fusion.
                    guard seen.insert(id).inserted else { continue }
                    if let m = meta(t.name, id), m.isTombstone {
                        // Une suppression connue gagne sur un objet qu'iCloud rapporte.
                        ghosts.append((t, object))
                        continue
                    }
                    let payload = currentPayload(t, id, object)
                    let h = hash(t, payload)
                    if var m = meta(t.name, id) {
                        if m.seen != h {
                            m.seen = h
                            m.updatedAt = now
                            setMeta(t.name, id, m)
                        }
                    } else {
                        setMeta(t.name, id, SyncMeta(updatedAt: now, seen: h, synced: nil))
                    }
                    objs[id] = object
                    pays[id] = payload
                }
                objects[t.name] = objs
                payloads[t.name] = pays
                for (id, m) in store.state.rows[t.name] ?? [:] where !m.isTombstone {
                    live += 1
                    if objs[id] == nil { vanished.append((t.name, id)) }
                }
            }
            if vanished.count >= 25, vanished.count * 2 > live, !acceptMassDeletion {
                throw Failure.massDeletion(vanished.count)
            }
            let stamp = now
            for (t, id) in vanished {
                setMeta(t, id, SyncMeta(updatedAt: stamp, seen: nil, synced: meta(t, id)?.synced, deletedAt: stamp, tombstoneSynced: false))
            }
            for (t, object) in ghosts { t.delete(object, in: context) }
        }

        // MARK: Lecture

        func pullTable(_ t: any AnySyncTable) async throws {
            let previous = store.state.cursors[t.name]
            var since = previous.flatMap { SyncTime.rewound($0, seconds: SyncEngine.cursorOverlapSeconds) }
            var afterID: String?
            var newest = previous
            var newestMicros = previous.flatMap(SyncTime.micros)
            while true {
                let rows = try await transport.pull(table: t.name, since: since, afterID: afterID, limit: batch)
                for row in rows {
                    applyRemote(t, row)
                    if let stamp = row["server_updated_at"] as? String, let micros = SyncTime.micros(stamp),
                       newestMicros == nil || micros >= newestMicros! {
                        newestMicros = micros
                        newest = SyncTime.urlSafe(stamp)
                    }
                }
                if rows.count < batch { break }
                guard let last = rows.last, let stamp = last["server_updated_at"] as? String, let id = last["id"] as? String else { break }
                since = SyncTime.urlSafe(stamp)
                afterID = id.lowercased()
            }
            if let newest, newest != previous {
                store.state.cursors[t.name] = newest
                store.markChanged()
            }
        }

        enum Outcome { case applied, keptLocal, unchanged }

        @discardableResult
        func applyRemote(_ t: any AnySyncTable, _ row: [String: Any]) -> Outcome {
            // Une ligne que le chiffrement a laissée de côté (autre clé, illisible) : on n'y touche pas.
            if row["_skipped"] != nil { return .unchanged }
            guard let rawID = row["id"] as? String, UUID(uuidString: rawID) != nil,
                  let ru = (row["updated_at"] as? String).flatMap(SyncTime.canonical) else { return .unchanged }
            let id = rawID.lowercased()
            let rd = (row["deleted_at"] as? String).flatMap(SyncTime.canonical)
            let local = meta(t.name, id)

            report.pulled += 1
            if let local {
                // Déjà connue à l'identique (cas courant : la marge de relecture).
                if !local.isDirty, local.updatedAt == ru, local.isTombstone == (rd != nil) { return .unchanged }
                // Même contenu des deux côtés (iCloud vient d'apporter les mêmes données) : rien à
                // écrire, rien à envoyer — quelle que soit l'heure de chaque côté.
                if rd == nil, let object = objects[t.name]?[id], !local.isTombstone {
                    let remoteHash = hash(t, t.decode(row))
                    if hash(t, currentPayload(t, id, object)) == remoteHash {
                        setMeta(t.name, id, SyncMeta(updatedAt: ru, seen: remoteHash, synced: remoteHash))
                        return .applied
                    }
                }
                // Une modification locale non envoyée, plus récente que le serveur, reste.
                if local.isDirty, local.updatedAt > ru {
                    report.keptLocal += 1
                    return .keptLocal
                }
            }

            if let rd {
                removeLocal(t.name, id, stamp: rd, synced: true)
                return .applied
            }

            let remote = t.decode(row)
            let remoteHash = hash(t, remote)
            var object = objects[t.name]?[id]
            if let object, hash(t, currentPayload(t, id, object)) == remoteHash {
                // Même contenu des deux côtés : rien à écrire, rien à envoyer.
                setMeta(t.name, id, SyncMeta(updatedAt: ru, seen: remoteHash, synced: remoteHash))
                return .applied
            }

            if object == nil {
                object = t.create(id: UUID(uuidString: id)!, in: context)
                objects[t.name, default: [:]][id] = object
            }
            guard let object else { return .unchanged }
            t.apply(remote, to: object)

            var pending: [String: String] = [:]
            var nullified = false
            for ref in t.refInfos {
                guard case .text(let rid) = remote[ref.column] ?? .null else { t.setRef(ref.column, of: object, to: nil); continue }
                if let target = objects[ref.table]?[rid] {
                    t.setRef(ref.column, of: object, to: target)
                } else if let parent = meta(ref.table, rid), parent.isTombstone {
                    // Le parent a été supprimé ailleurs : la règle de suppression s'applique à l'enfant.
                    if ref.onDelete == .cascade {
                        removeLocal(t.name, id, stamp: now, synced: false)
                        report.orphans += 1
                        return .applied
                    }
                    t.setRef(ref.column, of: object, to: nil)
                    nullified = true
                } else {
                    t.setRef(ref.column, of: object, to: nil)
                    pending[ref.column] = rid
                }
            }
            var m = SyncMeta(updatedAt: ru, seen: nil, synced: nil)
            m.pending = pending.isEmpty ? nil : pending
            setMeta(t.name, id, m)
            let local2 = hash(t, currentPayload(t, id, object))
            payloads[t.name, default: [:]][id] = currentPayload(t, id, object)
            if nullified {
                // Notre version diffère de celle du serveur : elle repart avec l'heure d'ici.
                m.updatedAt = now
                m.seen = local2
                m.synced = remoteHash
            } else {
                m.seen = local2
                m.synced = local2
            }
            setMeta(t.name, id, m)
            return .applied
        }

        /// Supprime l'objet local et ses dépendants (règles de SwiftData), et pose la pierre tombale.
        func removeLocal(_ tname: String, _ id: String, stamp: String, synced: Bool) {
            if let object = objects[tname]?[id], let t = table(tname) {
                for child in tables {
                    for ref in child.refInfos where ref.table == tname {
                        let kids = (payloads[child.name] ?? [:]).filter { $0.value[ref.column] == .text(id) }.map(\.key)
                        for kid in kids {
                            guard let kidObject = objects[child.name]?[kid] else { continue }
                            switch ref.onDelete {
                            case .cascade:
                                removeLocal(child.name, kid, stamp: now, synced: false)
                            case .nullify:
                                child.setRef(ref.column, of: kidObject, to: nil)
                                payloads[child.name]?[kid]?[ref.column] = .null
                            }
                        }
                    }
                }
                t.delete(object, in: context)
                objects[tname]?[id] = nil
                payloads[tname]?[id] = nil
                report.deleted += 1
            }
            let previous = meta(tname, id)
            setMeta(tname, id, SyncMeta(updatedAt: stamp, seen: nil, synced: previous?.synced, deletedAt: stamp, tombstoneSynced: synced))
        }

        /// Relations lues avant leur cible : on réessaie une fois toutes les tables lues.
        func resolvePending() {
            for t in tables {
                for (id, m) in store.state.rows[t.name] ?? [:] {
                    guard var pending = m.pending, let object = objects[t.name]?[id] else { continue }
                    for (col, rid) in pending {
                        guard let info = t.refInfos.first(where: { $0.column == col }) else { pending[col] = nil; continue }
                        if let target = objects[info.table]?[rid] {
                            t.setRef(col, of: object, to: target)
                            pending[col] = nil
                        } else if let parent = meta(info.table, rid), parent.isTombstone {
                            pending[col] = nil
                            if info.onDelete == .cascade {
                                removeLocal(t.name, id, stamp: now, synced: false)
                                report.orphans += 1
                                break
                            }
                        }
                    }
                    guard var current = meta(t.name, id), !current.isTombstone else { continue }
                    current.pending = pending.isEmpty ? nil : pending
                    setMeta(t.name, id, current)
                }
            }
        }

        // MARK: Envoi

        func pushTable(_ t: any AnySyncTable) async throws {
            var done = Set<String>()
            while true {
                let dirty = (store.state.rows[t.name] ?? [:])
                    .filter { $0.value.isDirty && !done.contains($0.key) }
                    .sorted { $0.value.updatedAt < $1.value.updatedAt || ($0.value.updatedAt == $1.value.updatedAt && $0.key < $1.key) }
                if dirty.isEmpty { return }
                let slice = Array(dirty.prefix(batch))
                slice.forEach { done.insert($0.key) }

                // Les pierres tombales partent seules : leurs clés (id, updated_at, deleted_at) laissent le
                // serveur conserver les autres colonnes, qu'on ne connaît plus ici.
                let tombstones = slice.filter { $0.value.isTombstone }
                let lives = slice.filter { !$0.value.isTombstone && payloads[t.name]?[$0.key] != nil }

                var sentHash: [String: String] = [:]
                if !lives.isEmpty {
                    let rows: [[String: Any]] = lives.map { id, m in
                        let p = payloads[t.name]![id]!
                        sentHash[id] = hash(t, p)
                        var body = t.encode(p)
                        body["id"] = id
                        body["updated_at"] = m.updatedAt
                        body["deleted_at"] = NSNull()
                        return body
                    }
                    let kept = try await transport.push(table: t.name, rows: rows)
                    try acknowledge(t, sent: lives, hashes: sentHash, kept: kept)
                }
                if !tombstones.isEmpty {
                    let rows: [[String: Any]] = tombstones.map { id, m in
                        ["id": id, "updated_at": m.updatedAt, "deleted_at": m.deletedAt ?? m.updatedAt]
                    }
                    let kept = try await transport.push(table: t.name, rows: rows)
                    try acknowledge(t, sent: tombstones, hashes: [:], kept: kept)
                }
            }
        }

        func acknowledge(_ t: any AnySyncTable, sent: [(key: String, value: SyncMeta)], hashes: [String: String], kept: [[String: Any]]) throws {
            var byID: [String: [String: Any]] = [:]
            for row in kept { if let id = (row["id"] as? String)?.lowercased() { byID[id] = row } }
            for (id, sentMeta) in sent {
                guard let server = byID[id] else { throw Failure.missingRow(t.name, id) }
                let su = (server["updated_at"] as? String).flatMap(SyncTime.canonical)
                if su == sentMeta.updatedAt {
                    // La nôtre est gardée. On ne nettoie que si la ligne n'a pas bougé pendant l'envoi.
                    guard var m = meta(t.name, id), m.updatedAt == sentMeta.updatedAt else { continue }
                    if m.isTombstone { m.tombstoneSynced = true } else { m.synced = hashes[id] }
                    setMeta(t.name, id, m)
                    report.pushed += 1
                } else {
                    // Le serveur détient plus récent : on adopte sa version.
                    // Même une modification locale plus récente que celle envoyée perd ici :
                    // elle est redétectée au prochain passage si le contenu diffère.
                    if var m = meta(t.name, id) { m.updatedAt = ""; setMeta(t.name, id, m) }
                    applyRemote(t, server)
                }
            }
        }
    }
}
