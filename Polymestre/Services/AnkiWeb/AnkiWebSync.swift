import Foundation
import Observation
import Security
import SwiftData

/// Une carte à ajouter dans Anki : le paquet, le type de note, ses champs.
struct AnkiDraftNote: Codable, Hashable, Identifiable {
    var id = UUID()
    var deckID: Int64
    var notetypeID: Int64
    var fields: [String]
    var tags: [String]
    /// D'où elle vient (« Exercice 3.2 · CS-250 ») : affiché dans la file d'attente.
    var origin: String
}

/// AnkiWeb, sans ordinateur : se connecter, garder une copie de la collection,
/// y ajouter des notes, et lire les statistiques de révision.
///
/// **Sûreté.** L'app n'envoie jamais la collection entière. Un ajout est une
/// synchronisation normale où l'app déclare n'avoir rien reçu depuis la copie
/// qu'elle tient (qui doit être identique au serveur — sinon elle la
/// retélécharge d'abord). Le serveur applique les notes dans une transaction,
/// vérifie les comptes, et **annule tout** si quoi que ce soit diffère.
@MainActor
@Observable
final class AnkiWebSync {
    static let shared = AnkiWebSync()

    private(set) var isWorking = false
    private(set) var status = ""
    private(set) var lastError: String?
    /// Les notes pas encore envoyées (hors ligne, ou envoi refusé).
    private(set) var pending: [AnkiDraftNote] = []

    private let defaults = UserDefaults.standard
    private enum Key {
        static let username = "ankiweb.username"
        static let endpoint = "ankiweb.endpoint"
        static let serverMod = "ankiweb.mirror.mod"
        static let serverUsn = "ankiweb.mirror.usn"
        static let lastRefresh = "ankiweb.mirror.refreshedAt"
        static let pending = "ankiweb.pending"
        static let lastReviewID = "ankiweb.lastReviewID"
        static let deckMap = "ankiweb.deckMap"
        static let notetype = "ankiweb.notetype"
        static let autoRedo = "ankiweb.autoRedo"
    }

    // MARK: Préférences

    /// Le paquet de chaque cours (code du cours → identifiant du paquet).
    var deckMap: [String: Int64] {
        get { (defaults.dictionary(forKey: Key.deckMap) as? [String: NSNumber])?.mapValues(\.int64Value) ?? [:] }
        set { defaults.set(newValue.mapValues { NSNumber(value: $0) }, forKey: Key.deckMap) }
    }

    /// Le type de note des cartes créées (question / réponse).
    var notetypeID: Int64? {
        get { (defaults.object(forKey: Key.notetype) as? NSNumber)?.int64Value }
        set { defaults.set(newValue.map { NSNumber(value: $0) }, forKey: Key.notetype) }
    }

    /// Un exercice corrigé « faux » devient une carte, tout seul.
    var autoRedo: Bool {
        get { defaults.bool(forKey: Key.autoRedo) }
        set { defaults.set(newValue, forKey: Key.autoRedo) }
    }

    /// Le paquet d'un cours : choisi, sinon deviné (code ou nom dans le paquet).
    func deck(for course: Course?, in collection: AnkiCollection) -> AnkiCollection.Deck? {
        let decks = collection.decks.filter { !$0.isFiltered }
        guard let course else { return decks.first { $0.name == "Default" } ?? decks.first }
        if let id = deckMap[course.code], let deck = decks.first(where: { $0.id == id }) { return deck }
        let code = course.code.uppercased()
        let name = course.name.lowercased()
        return decks.first { $0.name.uppercased().contains(code) }
            ?? decks.first { !name.isEmpty && $0.leaf.lowercased().contains(name) }
            ?? decks.first { !name.isEmpty && name.contains($0.leaf.lowercased()) && $0.leaf.count >= 4 }
    }

    /// Le type question / réponse : choisi, sinon « Basic » / « Basique ».
    func basicNotetype(in collection: AnkiCollection) -> AnkiCollection.Notetype? {
        let types = collection.notetypes.filter { !$0.isCloze && $0.fields.count >= 2 }
        if let id = notetypeID, let type = types.first(where: { $0.id == id }) { return type }
        return types.first { ["basic", "basique", "einfach"].contains($0.name.lowercased()) }
            ?? types.first { $0.templateCount == 1 }
    }

    private init() {
        if let data = defaults.data(forKey: Key.pending),
           let saved = try? JSONDecoder().decode([AnkiDraftNote].self, from: data) {
            pending = saved
        }
    }

    var username: String { defaults.string(forKey: Key.username) ?? "" }
    var isSignedIn: Bool { AnkiKeychain.hostKey != nil }
    var lastRefresh: Date? { defaults.object(forKey: Key.lastRefresh) as? Date }

    private func client() -> AnkiWebClient {
        AnkiWebClient(hostKey: AnkiKeychain.hostKey ?? "",
                      endpoint: defaults.string(forKey: Key.endpoint).flatMap(URL.init(string:)))
    }

    private func remember(_ client: AnkiWebClient) {
        defaults.set(client.endpoint.absoluteString, forKey: Key.endpoint)
    }

    // MARK: Compte

    /// Le mot de passe ne sert qu'à obtenir la clé d'hôte ; seule la clé est
    /// gardée (trousseau).
    func signIn(username: String, password: String) async -> Bool {
        isWorking = true
        lastError = nil
        defer { isWorking = false }
        do {
            let client = AnkiWebClient(endpoint: defaults.string(forKey: Key.endpoint).flatMap(URL.init(string:)))
            status = String(localized: "Connexion à AnkiWeb…")
            let key = try await client.login(username: username, password: password)
            AnkiKeychain.hostKey = key
            defaults.set(username, forKey: Key.username)
            remember(client)
            try await refreshMirror(force: true)
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func signOut() {
        ConnectionCenter.shared.report(.ankiweb, .unknown)
        AnkiKeychain.hostKey = nil
        for key in [Key.username, Key.endpoint, Key.serverMod, Key.serverUsn, Key.lastRefresh] {
            defaults.removeObject(forKey: key)
        }
        AnkiCollection.remove()
        status = ""
    }

    // MARK: Copie de la collection

    /// Retélécharge la collection si le serveur a changé depuis la copie.
    ///
    /// Toute erreur est **montrée** (et journalisée) : la synchronisation
    /// automatique l'avalait, et l'écran restait sur « Lecture d'AnkiWeb… »
    /// indéfiniment, sans dire ce qui avait échoué.
    func refreshMirror(force: Bool = false) async throws {
        // Une seule synchronisation à la fois : deux en parallèle enverraient
        // les mêmes lignes et se marcheraient dessus. Une demande arrivée
        // pendant qu'une autre tourne est **rejouée** juste après — c'est ce
        // qui garantit qu'une carte révisée pendant l'envoi part aussi.
        if syncing {
            rerunRequested = true
            return
        }
        syncing = true
        let ownsWork = !isWorking
        if ownsWork { isWorking = true }
        defer {
            syncing = false
            if ownsWork { isWorking = false }
        }
        lastError = nil
        var forceNext = force
        repeat {
            rerunRequested = false
            do {
                try await performRefresh(force: forceNext)
            } catch {
                status = ""
                lastError = error.localizedDescription
                AppLog.record(.warning, "anki", "AnkiWeb : synchronisation impossible", detail: error.localizedDescription)
                throw error
            }
            forceNext = false
        } while rerunRequested
    }

    @ObservationIgnored private var syncing = false
    @ObservationIgnored private var rerunRequested = false
    @ObservationIgnored private var scheduled: Task<Void, Never>?

    /// Synchronise quelques secondes après la dernière modification : chaque
    /// carte révisée part sans attendre la fin de la session, mais dix cartes
    /// enchaînées ne font qu'un envoi.
    func syncSoon(after seconds: Double = 5) {
        guard isSignedIn else { return }
        scheduled?.cancel()
        scheduled = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            try? await refreshMirror()
        }
    }

    /// Tout de suite (fin de session, passage en arrière-plan), s'il y a
    /// quelque chose à envoyer.
    func syncNow() async {
        scheduled?.cancel()
        guard isSignedIn, unsyncedCount > 0 else { return }
        try? await refreshMirror()
    }

    private func performRefresh(force: Bool) async throws {
        let client = client()
        status = "Lecture d'AnkiWeb…"
        let meta: AnkiWebClient.Meta
        do {
            meta = try await client.meta()
        } catch AnkiWebClient.Failure.badCredentials {
            // La clé d'hôte n'est plus acceptée (mot de passe changé, compte
            // déconnecté ailleurs) : c'est le seul cas où il faut redemander.
            ConnectionCenter.shared.report(.ankiweb, .expired)
            throw AnkiWebClient.Failure.badCredentials
        }
        ConnectionCenter.shared.report(.ankiweb, .connected)
        remember(client)

        let local = AnkiCollection(writable: true)
        let pendingLocal = local?.pendingChanges ?? 0
        let structureChanged = local.map { $0.schema != meta.schema } ?? true
        if force || local == nil || structureChanged {
            if pendingLocal > 0, structureChanged, !force {
                // Une synchronisation complète a été faite ailleurs : nos
                // modifications ne peuvent pas être fusionnées. On ne jette rien
                // sans le dire.
                throw AnkiWebClient.Failure.unsupported(Plural.count(pendingLocal,
                    "Ta collection AnkiWeb a été remplacée par une synchronisation complète faite ailleurs : \(pendingLocal) modification faite ici ne peut pas être fusionnée. « Retélécharger la collection » repart de la version d'AnkiWeb.",
                    "Ta collection AnkiWeb a été remplacée par une synchronisation complète faite ailleurs : \(pendingLocal) modifications faites ici ne peuvent pas être fusionnées. « Retélécharger la collection » repart de la version d'AnkiWeb."))
            }
            try await download(with: client)
            return
        }
        guard let local else { return }
        if pendingLocal == 0, local.modified == meta.modified {
            status = String(localized: "À jour")
            defaults.set(Date(), forKey: Key.lastRefresh)
            return
        }
        try await normalSync(local, meta: meta, client: client)
    }

    /// Téléchargement complet : au premier lancement, ou quand la collection
    /// d'AnkiWeb a été remplacée.
    private func download(with client: AnkiWebClient) async throws {
        status = String(localized: "Téléchargement de la collection…")
        let data = try await client.download()
        try AnkiCollection.install(data)
        // Le téléchargement incrémente le numéro de synchronisation du serveur :
        // on relit l'état pour que la copie corresponde exactement.
        let after = try await client.meta()
        AnkiCollection(writable: true)?.adopt(serverUsn: after.usn, modified: after.modified)
        defaults.set(after.modified, forKey: Key.serverMod)
        defaults.set(after.usn, forKey: Key.serverUsn)
        defaults.set(Date(), forKey: Key.lastRefresh)
        status = String(localized: "Collection à jour")
        // Les cartes créées avant d'avoir une copie : écrites maintenant.
        if !pending.isEmpty, let collection = AnkiCollection(writable: true) {
            for draft in pending {
                _ = try? collection.addNote(deckID: draft.deckID, notetypeID: draft.notetypeID, fields: draft.fields, tags: draft.tags)
            }
            pending = []
            savePending()
            if collection.pendingChanges > 0, let fresh = AnkiCollection(writable: true) {
                try await normalSync(fresh, meta: after, client: client)
            }
        }
    }

    /// La synchronisation normale d'Anki, dans les deux sens.
    ///
    /// 1. le serveur dit ce qui a été supprimé ailleurs ; on envoie nos suppressions ;
    /// 2. types de notes, paquets, options, étiquettes : le plus récent l'emporte ;
    /// 3. le serveur envoie ses lignes (historique, cartes, notes) modifiées
    ///    depuis notre dernière synchronisation ; on envoie les nôtres (`usn = -1`) ;
    /// 4. contrôle de cohérence : les deux collections doivent compter
    ///    exactement les mêmes cartes, notes, révisions… Sinon le serveur
    ///    **annule tout** — sa collection reste intacte.
    private func normalSync(_ local: AnkiCollection, meta: AnkiWebClient.Meta, client: AnkiWebClient) async throws {
        status = String(localized: "Synchronisation…")
        let sent = local.pendingChanges
        // Une seconde de marge : ce qui est modifié à partir d'ici repartira.
        let startedAt = Int64(Date().timeIntervalSince1970) - 1
        do {
            let graves = try await client.start(minUsn: local.usn, localIsNewer: false)
            local.applyServerGraves(graves)
            let mine = local.pendingGraves()
            if !(mine.cards.isEmpty && mine.notes.isEmpty && mine.decks.isEmpty) {
                try await client.applyGraves(cards: mine.cards, notes: mine.notes, decks: mine.decks)
            }
            let changes = try await client.applyChanges(tags: local.pendingTags())
            local.applyServerChanges(changes)
            while true {
                let chunk = try await client.chunk()
                local.applyServerChunk(chunk)
                if chunk["done"] as? Bool ?? true { break }
            }
            // Nos lignes, par paquets de 250 comme Anki.
            var revlog = local.pendingRows("revlog", usn: meta.usn)
            var cards = local.pendingRows("cards", usn: meta.usn)
            var notes = local.pendingRows("notes", usn: meta.usn)
            repeat {
                let r = Array(revlog.prefix(250)); revlog.removeFirst(r.count)
                let c = Array(cards.prefix(250 - r.count)); cards.removeFirst(c.count)
                let n = Array(notes.prefix(250 - r.count - c.count)); notes.removeFirst(n.count)
                try await client.applyChunk(notes: n, cards: c, revlog: r,
                                            done: revlog.isEmpty && cards.isEmpty && notes.isEmpty)
            } while !(revlog.isEmpty && cards.isEmpty && notes.isEmpty)

            let check = try await client.sanityCheck(local.sanityCounts())
            guard (check["status"] as? String) == "ok" else {
                AppLog.record(.warning, "anki", "AnkiWeb : contrôle de cohérence refusé",
                              detail: "client \(check["c"] ?? "?") · serveur \(check["s"] ?? "?")")
                throw AnkiWebClient.Failure.sanity("")
            }
            let modified = try await client.finish()
            local.markSynced(serverUsn: meta.usn, modified: modified, startedAt: startedAt,
                             graves: mine.cards + mine.notes + mine.decks)
            defaults.set(modified, forKey: Key.serverMod)
            defaults.set(meta.usn + 1, forKey: Key.serverUsn)
            defaults.set(Date(), forKey: Key.lastRefresh)
            status = sent > 0 ? String(localized: "Synchronisé · \(Plural.count(sent, "\(sent) modification envoyée", "\(sent) modifications envoyées"))") : String(localized: "Collection à jour")
        } catch {
            // Le serveur annule la transaction : sa collection reste intacte, et
            // nos lignes gardent `usn = -1` pour la prochaine fois.
            await client.abort()
            throw error
        }
    }

    // MARK: Créer

    /// Une carte à ajouter : écrite tout de suite dans la copie (elle part à
    /// la prochaine synchronisation) ; gardée en file s'il n'y a pas encore de copie.
    func enqueue(_ note: AnkiDraftNote) {
        lastError = nil
        if let collection = AnkiCollection(writable: true) {
            do {
                try collection.addNote(deckID: note.deckID, notetypeID: note.notetypeID, fields: note.fields, tags: note.tags)
                return
            } catch {
                lastError = error.localizedDescription
                return
            }
        }
        pending.append(note)
        savePending()
    }

    func discard(_ note: AnkiDraftNote) {
        pending.removeAll { $0.id == note.id }
        savePending()
    }

    private func savePending() {
        defaults.set(try? JSONEncoder().encode(pending), forKey: Key.pending)
    }

    /// Envoie ce qui attend ; rend le nombre de modifications envoyées.
    @discardableResult
    func pushPending() async -> Int {
        guard isSignedIn, !isWorking else { return 0 }
        let before = (AnkiCollection()?.pendingChanges ?? 0) + pending.count
        guard before > 0 else { return 0 }
        do {
            try await refreshMirror()
            return before
        } catch {
            return 0
        }
    }

    /// Les modifications faites ici et pas encore envoyées.
    var unsyncedCount: Int { (AnkiCollection()?.pendingChanges ?? 0) + pending.count }

    nonisolated static func clozeNumbers(in text: String) -> [Int] { AnkiNoteTools.clozeNumbers(in: text) }
    nonisolated static func guid() -> String { AnkiNoteTools.guid() }

    // MARK: Révisions

    /// Les révisions faites depuis le dernier relevé (tous appareils confondus,
    /// puisqu'elles arrivent par AnkiWeb).
    func newReviews() -> [AnkiReview] {
        guard let collection = AnkiCollection() else { return [] }
        let floor = Int64((Date().timeIntervalSince1970 - 30 * 86_400) * 1000)
        let after = max(defaults.object(forKey: Key.lastReviewID) as? Int64 ?? 0, floor)
        let reviews = collection.reviews(after: after)
        if let last = reviews.map(\.id).max() { defaults.set(last, forKey: Key.lastReviewID) }
        return reviews
    }
}

extension AnkiWebSync {
    /// Un exercice corrigé « faux » devient une carte (si l'option est active) :
    /// l'énoncé au recto, la note de correction et la solution au verso.
    func enqueueRedo(_ exercise: Exercise) {
        guard autoRedo, isSignedIn, let collection = AnkiCollection() else { return }
        let course = exercise.series?.course
        guard let deck = deck(for: course, in: collection), let type = basicNotetype(in: collection) else { return }
        let origin = "\(exercise.displayNumber) · \(course?.displayCode ?? "")"
        guard !pending.contains(where: { $0.origin == origin }) else { return }
        let statement = exercise.statement.isEmpty ? exercise.title : exercise.statement
        let front = ([course?.displayCode, exercise.displayNumber].compactMap { $0 }.joined(separator: " · ")
                     + (statement.isEmpty ? "" : "<br><br>" + statement))
            .replacingOccurrences(of: "\n", with: "<br>")
        let back = [exercise.correctionNote ?? "", exercise.solution].filter { !$0.isEmpty }
            .joined(separator: "<br><br>").replacingOccurrences(of: "\n", with: "<br>")
        enqueue(AnkiDraftNote(deckID: deck.id, notetypeID: type.id, fields: [front, back],
                              tags: ["polymestre", "à_refaire"], origin: origin))
        Task { await pushPending() }
    }
}

/// La clé d'hôte AnkiWeb, dans le trousseau.
enum AnkiKeychain {
    private static let service = "ch.polymestre.ankiweb"

    static var hostKey: String? {
        get {
            var item: CFTypeRef?
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                        kSecAttrService as String: service,
                                        kSecReturnData as String: true,
                                        kSecMatchLimit as String: kSecMatchLimitOne]
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
                  let data = item as? Data else { return nil }
            // Rangée par une version précédente en `afterFirstUnlock` : elle passe à « cet appareil seulement ».
            SecItemUpdate([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary,
                          [kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary)
            return String(data: data, encoding: .utf8)
        }
        set {
            let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                       kSecAttrService as String: service]
            SecItemDelete(base as CFDictionary)
            guard let newValue else { return }
            var insert = base
            insert[kSecValueData as String] = Data(newValue.utf8)
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(insert as CFDictionary, nil)
        }
    }
}
