import Foundation

/// Les décisions du passage StudyTrack → Polymestre, sans iCloud ni fichiers :
/// ce qu'un appareil doit copier de l'ancienne base vers la nouvelle.
///
/// Le problème : la nouvelle base se synchronise par iCloud. Si deux appareils
/// recopiaient chacun toute l'ancienne base, iCloud recevrait **deux fois** chaque
/// objet (mêmes identifiants, deux enregistrements) — des doublons partout.
///
/// La règle :
///   • un **verrou** dans le nouveau conteneur iCloud (un enregistrement, créé de
///     façon atomique : un seul appareil y parvient) désigne l'appareil qui copie tout ;
///     quand il a fini, il y écrit les identifiants copiés ;
///   • un autre appareil ne copie que ce que **lui seul** a (ses identifiants absents
///     du verrou) — et seulement quand sa nouvelle base a déjà reçu tout ce que le
///     verrou annonce, pour que ses objets se rattachent aux bons cours, séries, etc. ;
///     il ajoute alors ses identifiants au verrou ;
///   • sans compte iCloud, rien ne se synchronise : la copie est locale, sans verrou.
enum IdentityMigrationPlan {

    /// L'enregistrement de verrou, tel que lu dans iCloud.
    struct Lock: Equatable {
        var owner: String
        var startedAt: Date
        var completedAt: Date?
        var ids: Set<UUID>
    }

    enum Decision: Equatable {
        /// Cet appareil tient le verrou : il copie tout.
        case copyAll
        /// Copier ces objets (que cet appareil est seul à avoir), puis les ajouter au verrou.
        case copyOnly(Set<UUID>)
        /// Rien à copier : tout ce que cet appareil a est déjà dans la nouvelle base (ou en chemin).
        case nothing
        /// Pas encore : la raison est dite (journal, et l'état montré dans les réglages).
        case wait(String)
    }

    /// Un verrou commencé et jamais fini depuis ce délai est abandonné (l'appareil
    /// s'est arrêté en route) : un autre peut le reprendre.
    static let staleAfter: TimeInterval = 15 * 60

    /// Le temps laissé à iCloud pour apporter une copie finie à un autre appareil.
    static let settleAfter: TimeInterval = 3 * 24 * 3_600

    /// Ce que doit faire cet appareil, le verrou étant déjà là (créé par un autre, ou
    /// par lui à un lancement précédent).
    ///
    /// - Parameters:
    ///   - legacyIDs: les identifiants de l'ancienne base de cet appareil ;
    ///   - storeIDs: ceux que la nouvelle base de cet appareil contient déjà ;
    ///   - me: l'identifiant de cet appareil (celui écrit dans `owner`).
    static func decide(legacyIDs: Set<UUID>, lock: Lock, storeIDs: Set<UUID>, me: String, now: Date) -> Decision {
        guard lock.completedAt != nil else {
            if lock.owner == me { return .copyAll }  // reprise après un arrêt en route
            if now.timeIntervalSince(lock.startedAt) > staleAfter { return .copyAll }  // à reprendre (voir `takeOver`)
            return .wait(String(localized: "un autre appareil recopie les données (« \(lock.owner) »)"))
        }
        // D'abord que la nouvelle base ait reçu la copie : c'est ce qui relie ses objets, et
        // ce qui retient la synchronisation Supabase (voir `IdentityMigration.holdsBackSync`).
        // Passé `settleAfter`, ce qui manque encore a été supprimé depuis, pas perdu en route.
        let arrived = lock.ids.intersection(storeIDs).count
        let settled = lock.completedAt.map { now.timeIntervalSince($0) > settleAfter } ?? false
        guard arrived == lock.ids.count || settled else {
            return .wait(String(localized: "iCloud apporte encore les données recopiées par « \(lock.owner) » (\(arrived)/\(lock.ids.count))"))
        }
        let mine = legacyIDs.subtracting(lock.ids)
        return mine.isEmpty ? .nothing : .copyOnly(mine)
    }

    /// Faut-il **reprendre** ce verrou (pris par un autre, jamais fini, trop ancien) ?
    static func takeOver(_ lock: Lock, me: String, now: Date) -> Bool {
        lock.completedAt == nil && lock.owner != me && now.timeIntervalSince(lock.startedAt) > staleAfter
    }

    // MARK: Identifiants en binaire (16 octets chacun, triés)

    /// 2 500 objets font 40 Ko : bien sous la limite d'un enregistrement iCloud (1 Mo).
    static func encode(_ ids: Set<UUID>) -> Data {
        var data = Data(capacity: ids.count * 16)
        for id in ids.sorted(by: { $0.uuidString < $1.uuidString }) {
            withUnsafeBytes(of: id.uuid) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func decode(_ data: Data) -> Set<UUID> {
        guard data.count % 16 == 0 else { return [] }
        var out = Set<UUID>()
        out.reserveCapacity(data.count / 16)
        data.withUnsafeBytes { raw in
            for offset in stride(from: 0, to: raw.count, by: 16) {
                var bytes: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
                withUnsafeMutableBytes(of: &bytes) { $0.copyMemory(from: UnsafeRawBufferPointer(rebasing: raw[offset..<offset + 16])) }
                out.insert(UUID(uuid: bytes))
            }
        }
        return out
    }
}
