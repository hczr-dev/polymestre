import CloudKit
import CoreData
import Foundation
import OSLog
import Security
import SwiftData
#if os(iOS)
import UIKit
#endif

/// Reprend ce que StudyTrack (l'ancienne identité de l'app) a laissé sur cet
/// appareil : réglages, trousseau, fichiers, et surtout **la base**.
///
/// Principe : **copier, ne jamais modifier l'ancien**. Réinstaller StudyTrack rend
/// tout tel quel. Chaque étape est rejouable : ce qui est déjà là n'est pas réécrit.
///
/// La base passe d'un conteneur iCloud à l'autre sans doublons entre appareils :
/// voir `IdentityMigrationPlan` (le verrou) et `StoreCopier` (la copie par identifiant,
/// vérifiée). À appeler **avant** d'ouvrir la base SwiftData — la copie s'y écrit.
enum IdentityMigration {
    private static let log = Logger(subsystem: "ch.polymestre", category: "migration")

    // MARK: État (réglages de la nouvelle identité)

    private enum Key {
        static let settings = "identity.settingsImported"
        static let keychain = "identity.keychainImported"
        static let files = "identity.filesImported"
        static let data = "identity.data"
        static let device = "identity.device"
    }

    /// L'état de la reprise de la base, montré dans les réglages et le journal.
    struct DataState: Codable, Equatable {
        enum Phase: String, Codable { case pending, done }
        var phase: Phase = .pending
        /// Date de modification de l'ancienne base lors de la dernière vérification.
        var legacyStamp: Date?
        var doneAt: Date?
        var copied = 0
        var mergedDuplicates = 0
        var conflicts = 0
        /// La dernière raison d'attendre, s'il y en a une.
        var waiting: String?
        /// La première tentative sur cet appareil.
        var firstAttempt: Date?
    }

    static var dataState: DataState {
        get {
            guard let data = UserDefaults.standard.data(forKey: Key.data),
                  let state = try? JSONDecoder().decode(DataState.self, from: data) else { return DataState() }
            return state
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: Key.data) }
    }

    /// La reprise vérifie encore, à chaque lancement où l'ancienne base a changé
    /// (StudyTrack encore utilisé sur un autre appareil), pendant ce délai.
    static let watchFor: TimeInterval = 60 * 24 * 3_600

    /// Le temps accordé à iCloud pour le verrou : au-delà, la reprise attend le prochain lancement.
    static let networkBudget: TimeInterval = 8

    // MARK: Point d'entrée

    /// Tout reprendre, avant l'ouverture de la base (`newStoreURL` : là où SwiftData l'ouvrira).
    ///
    /// `cloud` faux (copie sans droit iCloud : compilation de contrôle) : réglages et fichiers
    /// seulement, la base n'est pas touchée.
    static func runBeforeStore(newStoreURL: URL?, cloud: Bool) {
        guard !AppIdentity.isLegacyBuild else { return }
        importSettings()
        importKeychain()
        importFiles()
        guard cloud, let newStoreURL else { return }
        migrateData(into: newStoreURL)
    }

    // MARK: Réglages

    /// Les réglages privés de StudyTrack : sur iPhone, la copie déposée par la build
    /// « pont » (`RenameBridge`) dans l'ancien groupe ; sur Mac (hors bac à sable),
    /// directement. Seules les clés absentes sont reprises : un réglage fait depuis
    /// dans Polymestre l'emporte.
    static func importSettings() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Key.settings) else { return }
        #if os(macOS)
        let old = defaults.persistentDomain(forName: AppIdentity.Legacy.bundleID)
        #else
        let old = legacyGroupURL.flatMap { group -> [String: Any]? in
            let file = group.appendingPathComponent("Library/Application Support/Polymestre-migration/standard-defaults.plist")
            guard let data = try? Data(contentsOf: file),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
            return plist["defaults"] as? [String: Any]
        }
        #endif
        if let old {
            var copied = 0
            for (key, value) in old where !key.hasPrefix("identity.") && defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
                copied += 1
            }
            log.notice("réglages de StudyTrack repris : \(copied)")
            AppLog.record(.info, AppLog.Category.storage, "Réglages de StudyTrack repris", detail: "\(copied) réglages")
            defaults.set(true, forKey: Key.settings)
        }
        // Sur iPhone sans copie (StudyTrack pas mis à jour vers la build « pont ») : on
        // réessaie au prochain lancement — la copie apparaît dès que StudyTrack s'ouvre.

        // Les réglages du groupe (chrono partagé avec les widgets et Siri).
        if let oldGroup = UserDefaults(suiteName: AppIdentity.Legacy.appGroup),
           let groupID = Bundle.main.object(forInfoDictionaryKey: "PolymestreAppGroup") as? String,
           groupID != AppIdentity.Legacy.appGroup,
           let newGroup = UserDefaults(suiteName: groupID),
           let values = oldGroup.persistentDomain(forName: AppIdentity.Legacy.appGroup) {
            for (key, value) in values where newGroup.object(forKey: key) == nil { newGroup.set(value, forKey: key) }
        }
    }

    // MARK: Trousseau

    /// Chaque élément des anciens services est recopié sous le nouveau nom (même compte,
    /// mêmes données, même accessibilité). L'ancien reste. Sur Mac, macOS demande une
    /// fois l'autorisation par élément : il appartient à l'ancienne app.
    static func importKeychain() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Key.keychain) else { return }
        var copied = 0, failed = 0
        for (old, new) in AppIdentity.Legacy.keychainServices {
            for attributes in keychainItems(service: old) {
                guard let account = attributes[kSecAttrAccount as String] as? String else { continue }
                let synchronizable = (attributes[kSecAttrSynchronizable as String] as? Bool) ?? false
                if keychainData(service: new, account: account, synchronizable: synchronizable) != nil { continue }
                guard let data = keychainData(service: old, account: account, synchronizable: synchronizable) else {
                    failed += 1
                    continue
                }
                var insert: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: new,
                    kSecAttrAccount as String: account,
                    kSecValueData as String: data,
                    kSecAttrSynchronizable as String: synchronizable,
                ]
                if let accessible = attributes[kSecAttrAccessible as String] { insert[kSecAttrAccessible as String] = accessible }
                if SecItemAdd(insert as CFDictionary, nil) == errSecSuccess { copied += 1 } else { failed += 1 }
            }
        }
        log.notice("trousseau de StudyTrack : \(copied) repris, \(failed) non repris")
        if copied + failed > 0 {
            AppLog.record(failed == 0 ? .info : .warning, AppLog.Category.storage, "Trousseau de StudyTrack",
                          detail: "\(copied) éléments repris" + (failed > 0 ? String(localized: ", \(failed) non repris (reconnecte-toi au besoin)") : ""))
        }
        // Une seule fois, même en cas de refus : redemander à chaque lancement serait pire.
        defaults.set(true, forKey: Key.keychain)
    }

    private static func keychainItems(service: String) -> [[String: Any]] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return [] }
        return result as? [[String: Any]] ?? []
    }

    private static func keychainData(service: String, account: String, synchronizable: Bool) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: synchronizable,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    // MARK: Fichiers

    /// Les fichiers de l'app (pas la base : elle passe par `StoreCopier`). Copiés s'ils
    /// manquent, jamais écrasés.
    static func importFiles() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Key.files) else { return }
        defer { defaults.set(true, forKey: Key.files) }
        let fm = FileManager.default
        #if os(macOS)
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let from = support.appendingPathComponent(AppIdentity.Legacy.folderName, isDirectory: true)
        let to = support.appendingPathComponent(AppIdentity.folderName, isDirectory: true)
        #else
        guard let from = legacyGroupURL, let to = newGroupURL else { return }
        #endif
        guard let names = try? fm.contentsOfDirectory(atPath: from.path) else { return }
        try? fm.createDirectory(at: to, withIntermediateDirectories: true)
        var copied = 0
        for name in names where !isStoreFile(name) && name != "Library" {
            let target = to.appendingPathComponent(name)
            guard !fm.fileExists(atPath: target.path) else { continue }
            if (try? fm.copyItem(at: from.appendingPathComponent(name), to: target)) != nil { copied += 1 }
        }
        log.notice("fichiers de StudyTrack repris : \(copied)")
    }

    /// La base et ce qui l'accompagne (journal, pièces jointes, réglages du miroir iCloud).
    static func isStoreFile(_ name: String) -> Bool {
        name.hasPrefix("default.store") || name.hasPrefix("unsigned.store") || name.hasPrefix(".default_SUPPORT")
            || name.hasPrefix(".unsigned_SUPPORT") || name.hasPrefix("default_ckAssets") || name == "Polymestre-migration"
    }

    // MARK: Emplacements

    static var legacyGroupURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppIdentity.Legacy.appGroup)
    }

    static var newGroupURL: URL? {
        (Bundle.main.object(forInfoDictionaryKey: "PolymestreAppGroup") as? String)
            .flatMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
    }

    /// L'ancienne base sur cet appareil, si elle y est.
    static var legacyStoreURL: URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        #if os(macOS)
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        candidates.append(support.appendingPathComponent("\(AppIdentity.Legacy.folderName)/default.store"))
        #endif
        if let group = legacyGroupURL {
            candidates.append(group.appendingPathComponent("Library/Application Support/default.store"))
        }
        // L'ancien conteneur iCloud, téléchargé faute d'ancienne base ici (`mirrorLegacyCloud`).
        candidates.append(workDirectory.appendingPathComponent("legacy-mirror.store"))
        return candidates.first { fm.fileExists(atPath: $0.path) }
    }

    /// Le dossier de travail de la reprise (instantané, miroir).
    static var workDirectory: URL {
        #if os(macOS)
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppIdentity.folderName, isDirectory: true)
        #else
        let base = (newGroupURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        #endif
        let dir = base.appendingPathComponent("Polymestre-migration", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func stamp(of store: URL) -> Date? {
        let fm = FileManager.default
        return ["", "-wal"].compactMap { suffix in
            (try? fm.attributesOfItem(atPath: store.path + suffix))?[.modificationDate] as? Date
        }.max()
    }

    /// Cet appareil, tel qu'écrit dans le verrou : un nom lisible et un identifiant stable.
    static var deviceTag: String {
        let defaults = UserDefaults.standard
        let id = defaults.string(forKey: Key.device) ?? {
            let new = UUID().uuidString
            defaults.set(new, forKey: Key.device)
            return new
        }()
        #if os(macOS)
        let name = Host.current().localizedName ?? "Mac"
        #else
        let name = MainActor.assumeIsolated { UIDevice.current.name }
        #endif
        return "\(name)#\(id.prefix(8))"
    }

    private static func displayName(_ tag: String) -> String {
        tag.split(separator: "#").first.map(String.init) ?? tag
    }

    // MARK: La base

    /// La synchronisation Supabase attend-elle la reprise ? Elle créerait dans une base
    /// encore vide les objets qu'iCloud apporte aussi — deux objets de même identifiant.
    /// Bornée : au-delà de `IdentityMigrationPlan.settleAfter`, elle reprend quoi qu'il arrive.
    static var holdsBackSync: Bool {
        let state = dataState
        guard state.phase == .pending, let first = state.firstAttempt else { return false }
        return Date().timeIntervalSince(first) < IdentityMigrationPlan.settleAfter
    }

    static func migrateData(into newStoreURL: URL) {
        var state = dataState
        guard let legacyURL = legacyStoreURL else {
            if state.phase == .pending { mirrorLegacyCloudIfNeeded() }
            return
        }
        let legacyStamp = stamp(of: legacyURL)
        state.firstAttempt = state.firstAttempt ?? Date()
        if state.phase == .done {
            // Rien de neuf dans l'ancienne base, ou la période de surveillance est finie.
            if legacyStamp == state.legacyStamp { return }
            if let doneAt = state.doneAt, Date().timeIntervalSince(doneAt) > watchFor { return }
        }
        guard let model = NSManagedObjectModel.makeManagedObjectModel(for: SchemaV1.models) else { return }
        let started = Date()
        do {
            let snapshot = workDirectory.appendingPathComponent("legacy-snapshot.store")
            defer { removeStore(at: snapshot, model: model) }
            try takeSnapshot(of: legacyURL, to: snapshot, model: model)
            let legacy = try openStore(snapshot, model: model, readOnly: true)
            let fresh = try openStore(newStoreURL, model: model, readOnly: false)
            defer { close(legacy); close(fresh) }
            let legacyIDs = try StoreCopier.allIDs(in: legacy.viewContext)
            guard !legacyIDs.isEmpty else {
                state.phase = .done
                state.doneAt = state.doneAt ?? Date()
                state.legacyStamp = legacyStamp
                dataState = state
                return
            }
            let me = deviceTag
            let storeIDs = try StoreCopier.allIDs(in: fresh.viewContext)
            let outcome = waitFor(networkBudget) {
                try await negotiate(legacyIDs: legacyIDs, storeIDs: storeIDs, me: me)
            }
            switch outcome {
            case nil:
                state.waiting = String(localized: "iCloud ne répond pas : la reprise se fera au prochain lancement")
            case .failure(let error)?:
                state.waiting = "iCloud : \(error.localizedDescription)"
                log.error("verrou iCloud : \(String(describing: error), privacy: .public)")
            case .success(let negotiation)?:
                switch negotiation.decision {
                case .wait(let reason):
                    state.waiting = reason
                case .nothing:
                    state.waiting = nil
                    finish(&state, stamp: legacyStamp)
                case .copyAll, .copyOnly:
                    let only: Set<UUID>? = if case .copyOnly(let ids) = negotiation.decision { ids } else { nil }
                    let report = try StoreCopier.copyMissing(from: legacy.viewContext, to: fresh.viewContext, only: only)
                    let wanted = only ?? legacyIDs
                    let present = try StoreCopier.allIDs(in: fresh.viewContext)
                    let lacking = wanted.subtracting(present)
                    state.copied += report.copied
                    state.mergedDuplicates += report.mergedDuplicates
                    state.conflicts += report.conflicts.count
                    let elapsed = String(format: "%.1f", Date().timeIntervalSince(started))
                    if lacking.isEmpty {
                        // Annoncer ce qui a été copié : les autres appareils ne le recopieront pas.
                        let publish = negotiation.publish
                        _ = waitFor(networkBudget) { try await publish(wanted) }
                        state.waiting = nil
                        finish(&state, stamp: legacyStamp)
                        AppLog.record(.info, AppLog.Category.storage, "Données de StudyTrack reprises",
                                      detail: "\(report.copied) objets copiés en \(elapsed) s · \(report.mergedDuplicates) doublons fondus · \(report.conflicts.count) conflits · vérifié : rien ne manque")
                    } else {
                        state.waiting = String(localized: "\(lacking.count) objets pas encore repris : nouvel essai au prochain lancement")
                        AppLog.record(.error, AppLog.Category.storage, "Reprise des données de StudyTrack incomplète",
                                      detail: "\(lacking.count) objets manquent après la copie (\(report.summary))")
                    }
                    log.notice("reprise : \(report.summary, privacy: .public)")
                }
            }
        } catch {
            state.waiting = String(localized: "reprise interrompue : \(error.localizedDescription)")
            log.error("reprise : \(String(describing: error), privacy: .public)")
            AppLog.record(.error, AppLog.Category.storage, "Reprise des données de StudyTrack", detail: String(describing: error))
        }
        dataState = state
    }

    private static func finish(_ state: inout DataState, stamp: Date?) {
        state.phase = .done
        state.doneAt = state.doneAt ?? Date()
        state.legacyStamp = stamp
    }

    // MARK: Le verrou (iCloud)

    struct Negotiation {
        var decision: IdentityMigrationPlan.Decision
        /// Ajoute ces identifiants au verrou (et le marque fini).
        var publish: @Sendable (Set<UUID>) async throws -> Void
    }

    /// Prend le verrou ou le lit, et décide. Sans compte iCloud : copie locale, sans verrou.
    static func negotiate(legacyIDs: Set<UUID>, storeIDs: Set<UUID>, me: String) async throws -> Negotiation {
        let container = CKContainer(identifier: AppIdentity.cloudContainer)
        let status = try await container.accountStatus()
        switch status {
        case .available: break
        case .noAccount, .restricted:
            // Rien ne se synchronise : aucun doublon possible entre appareils.
            return Negotiation(decision: .copyAll, publish: { _ in })
        default:
            return Negotiation(decision: .wait(String(localized: "compte iCloud pas encore disponible")), publish: { _ in })
        }
        let lock = CloudLock(database: container.privateCloudDatabase)
        let now = Date()
        if let fetched = try await lock.fetch() {
            var current = fetched.0
            let record = fetched.1
            if IdentityMigrationPlan.takeOver(current, me: me, now: now) {
                current.owner = me
                current.startedAt = now
                guard try await lock.save(current, over: record) != nil else {
                    return Negotiation(decision: .wait(String(localized: "un autre appareil vient de reprendre la copie")), publish: { _ in })
                }
                return Negotiation(decision: .copyAll, publish: { ids in try await lock.complete(adding: ids, me: me) })
            }
            let decision = IdentityMigrationPlan.decide(legacyIDs: legacyIDs, lock: current, storeIDs: storeIDs, me: me, now: now)
            if case .wait(let reason) = decision {
                return Negotiation(decision: .wait(reason.replacingOccurrences(of: current.owner, with: displayName(current.owner))),
                                  publish: { _ in })
            }
            return Negotiation(decision: decision, publish: { ids in try await lock.complete(adding: ids, me: me) })
        }
        let mine = IdentityMigrationPlan.Lock(owner: me, startedAt: now, completedAt: nil, ids: [])
        guard try await lock.save(mine, over: nil) != nil else {
            // Un autre appareil l'a pris entre la lecture et l'écriture : on attend sa copie.
            return Negotiation(decision: .wait(String(localized: "un autre appareil recopie les données")), publish: { _ in })
        }
        return Negotiation(decision: .copyAll, publish: { ids in try await lock.complete(adding: ids, me: me) })
    }

    /// L'enregistrement de verrou : zone par défaut de la base privée du nouveau conteneur.
    struct CloudLock {
        static let recordType = "IdentityMigration"
        static let recordID = CKRecord.ID(recordName: "identity-migration-v1")
        let database: CKDatabase

        func fetch() async throws -> (IdentityMigrationPlan.Lock, CKRecord)? {
            do {
                let record = try await database.record(for: Self.recordID)
                return (Self.lock(from: record), record)
            } catch let error as CKError where error.code == .unknownItem {
                return nil
            }
        }

        /// Écrit le verrou **seulement si** l'enregistrement n'a pas changé depuis `record`
        /// (ou n'existe pas, quand `record` est nil). Nil : un autre appareil est passé avant.
        func save(_ lock: IdentityMigrationPlan.Lock, over record: CKRecord?) async throws -> CKRecord? {
            let target = record ?? CKRecord(recordType: Self.recordType, recordID: Self.recordID)
            target["owner"] = lock.owner
            target["startedAt"] = lock.startedAt
            target["completedAt"] = lock.completedAt
            target["ids"] = IdentityMigrationPlan.encode(lock.ids)
            do {
                let (saved, _) = try await database.modifyRecords(saving: [target], deleting: [],
                                                                   savePolicy: .ifServerRecordUnchanged, atomically: true)
                return try saved[Self.recordID]?.get()
            } catch let error as CKError where Self.isConflict(error) {
                return nil
            }
        }

        /// L'enregistrement a changé (ou existe déjà) sur le serveur : un autre appareil est passé avant.
        static func isConflict(_ error: CKError) -> Bool {
            if error.code == .serverRecordChanged { return true }
            if error.code == .partialFailure, let inner = error.partialErrorsByItemID?[recordID] as? CKError {
                return inner.code == .serverRecordChanged
            }
            return false
        }

        /// Ajoute des identifiants et marque le verrou fini (relit et recommence si un
        /// autre appareil écrit en même temps).
        func complete(adding ids: Set<UUID>, me: String) async throws {
            for _ in 0..<5 {
                guard let fetched = try await fetch() else { return }
                let record = fetched.1
                var next = fetched.0
                next.ids.formUnion(ids)
                next.completedAt = next.completedAt ?? Date()
                if try await save(next, over: record) != nil { return }
            }
        }

        static func lock(from record: CKRecord) -> IdentityMigrationPlan.Lock {
            IdentityMigrationPlan.Lock(owner: record["owner"] as? String ?? "",
                                       startedAt: record["startedAt"] as? Date ?? .distantPast,
                                       completedAt: record["completedAt"] as? Date,
                                       ids: (record["ids"] as? Data).map(IdentityMigrationPlan.decode) ?? [])
        }
    }

    // MARK: Core Data

    /// Un instantané cohérent de l'ancienne base (sauvegarde SQLite), qu'une app
    /// StudyTrack ouverte au même moment ne gêne pas. L'original n'est pas modifié.
    private static func takeSnapshot(of source: URL, to target: URL, model: NSManagedObjectModel) throws {
        removeStore(at: target, model: model)
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        try coordinator.replacePersistentStore(at: target, destinationOptions: nil, withPersistentStoreFrom: source,
                                               sourceOptions: [NSReadOnlyPersistentStoreOption: true,
                                                               NSPersistentHistoryTrackingKey: true],
                                               type: .sqlite)
    }

    private static func removeStore(at url: URL, model: NSManagedObjectModel) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        try? coordinator.destroyPersistentStore(at: url, type: .sqlite)
        for suffix in ["-shm", "-wal"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
    }

    /// Ouverte comme SwiftData l'ouvrira (historique et changements distants), sans iCloud :
    /// le miroir de SwiftData envoie ensuite ce qui a été écrit.
    private static func openStore(_ url: URL, model: NSManagedObjectModel, readOnly: Bool) throws -> NSPersistentContainer {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let container = NSPersistentContainer(name: url.deletingPathExtension().lastPathComponent, managedObjectModel: model)
        let description = NSPersistentStoreDescription(url: url)
        description.isReadOnly = readOnly
        description.shouldAddStoreAsynchronously = false
        description.shouldMigrateStoreAutomatically = !readOnly
        description.shouldInferMappingModelAutomatically = !readOnly
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        container.persistentStoreDescriptions = [description]
        var failure: Error?
        container.loadPersistentStores { _, error in failure = error }
        if let failure { throw failure }
        return container
    }

    private static func close(_ container: NSPersistentContainer) {
        for store in container.persistentStoreCoordinator.persistentStores {
            try? container.persistentStoreCoordinator.remove(store)
        }
    }

    // MARK: Faute d'ancienne base ici

    /// Cet appareil n'a jamais eu StudyTrack (ou plus) : tant que personne n'a pris le
    /// verrou, l'ancien conteneur iCloud est téléchargé, en arrière-plan, dans une base
    /// de travail ; au lancement suivant, elle tient lieu d'ancienne base.
    static func mirrorLegacyCloudIfNeeded() {
        Task.detached(priority: .utility) {
            let container = CKContainer(identifier: AppIdentity.cloudContainer)
            guard (try? await container.accountStatus()) == .available,
                  case .some(.none) = try? await CloudLock(database: container.privateCloudDatabase).fetch(),
                  let model = NSManagedObjectModel.makeManagedObjectModel(for: SchemaV1.models) else { return }
            let url = workDirectory.appendingPathComponent("legacy-mirror-download.store")
            let description = NSPersistentStoreDescription(url: url)
            description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: AppIdentity.Legacy.cloudContainer)
            description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
            description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
            let mirror = NSPersistentCloudKitContainer(name: "legacy-mirror", managedObjectModel: model)
            mirror.persistentStoreDescriptions = [description]
            mirror.loadPersistentStores { _, _ in }
            // Une importation réussie : la copie est prête, sous le nom que lit `legacyStoreURL`.
            for await note in NotificationCenter.default.notifications(named: NSPersistentCloudKitContainer.eventChangedNotification, object: mirror) {
                guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey] as? NSPersistentCloudKitContainer.Event,
                      event.type == .import, event.endDate != nil, event.succeeded else { continue }
                let ready = workDirectory.appendingPathComponent("legacy-mirror.store")
                removeStore(at: ready, model: model)
                let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
                try? coordinator.replacePersistentStore(at: ready, destinationOptions: nil, withPersistentStoreFrom: url,
                                                        sourceOptions: [NSPersistentHistoryTrackingKey: true], type: .sqlite)
                log.notice("ancien conteneur iCloud téléchargé : reprise au prochain lancement")
                break
            }
        }
    }

    // MARK: Attente bornée

    /// Attend un travail asynchrone au plus `seconds`, sans bloquer ce dont il a besoin
    /// (il ne doit pas utiliser le fil principal). Nil : délai dépassé.
    private static func waitFor<T>(_ seconds: TimeInterval, _ work: @escaping @Sendable () async throws -> T) -> Result<T, Error>? {
        let box = WaitBox<T>()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do { box.value = .success(try await work()) } catch { box.value = .failure(error) }
            done.signal()
        }
        return done.wait(timeout: .now() + seconds) == .success ? box.value : nil
    }
}

/// Le résultat d'un travail attendu par `IdentityMigration.waitFor` (écrit une fois, lu après le signal).
private final class WaitBox<T>: @unchecked Sendable {
    var value: Result<T, Error>?
}
