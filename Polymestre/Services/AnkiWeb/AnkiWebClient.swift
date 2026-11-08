import Foundation

/// Le protocole de synchronisation d'AnkiWeb, côté client — comme AnkiMobile ou
/// AnkiDroid, sans ordinateur.
///
/// Version **10** du protocole (formulaire `multipart`, JSON non compressé) :
/// le serveur de référence d'Anki l'accepte toujours (`SYNC_VERSION_MIN = 8`), et
/// elle évite le zstd de la version 11, qu'iOS ne sait pas décoder. Les
/// réponses de la version 10 ne sont pas compressées.
///
/// Méthodes : `hostKey` (connexion), `meta`, `download` (collection entière,
/// SQLite au schéma 11), puis la synchronisation normale — `start`,
/// `applyGraves`, `applyChanges`, `chunk`, `applyChunk`, `sanityCheck2`,
/// `finish`, `abort`. Voir `rslib/src/sync` dans le dépôt d'Anki.
///
/// **Jamais d'envoi complet** (`upload`) : l'app n'écrase jamais la collection
/// d'AnkiWeb. Elle ne fait qu'y ajouter des notes, par une synchronisation
/// normale que le serveur annule entièrement si quoi que ce soit ne concorde.
final class AnkiWebClient {
    static let syncVersion = 10
    /// L'identifiant de client, **au format d'Anki** : `anki,<version>
    /// (<build>),<plateforme>`.
    ///
    /// AnkiWeb lit la version dans cet identifiant et refuse (400, sans
    /// message) tout ce qui n'en a pas la forme ou qui est trop ancien :
    /// « polymestre,1.0,ios » faisait échouer la lecture du compte (`meta`)
    /// juste après une connexion réussie. Vérifié sur sync20.ankiweb.net le
    /// 1ᵉʳ octobre 2026 : cette forme répond 200, la nôtre 400.
    static let clientVersion = "anki,25.02.7 (6ddc22e5),ios"
    /// La forme courte, celle de l'en-tête `anki-sync` (« 25.02.7,6ddc22e5,ios »).
    static let shortClientVersion = "25.02.7,6ddc22e5,ios"
    static let defaultEndpoint = URL(string: "https://sync.ankiweb.net/")!

    private(set) var endpoint: URL
    var hostKey: String
    /// Clé de session : la même pour toutes les requêtes d'une synchronisation.
    private let sessionKey: String
    private let session: URLSession

    init(hostKey: String = "", endpoint: URL? = nil, session: URLSession = .shared) {
        self.hostKey = hostKey
        self.endpoint = endpoint ?? Self.defaultEndpoint
        self.sessionKey = Self.randomKey(8)
        self.session = session
    }

    enum Failure: LocalizedError {
        case badCredentials
        case server(Int, String, method: String = "")
        case decoding(String)
        case unsupported(String)
        case sanity(String)
        case fullSyncRequired

        var errorDescription: String? {
            switch self {
            case .badCredentials: return "Identifiant ou mot de passe AnkiWeb incorrect."
            case .server(let code, let body, let method):
                let step = method.isEmpty ? "" : String(localized: " (étape « \(method) »)")
                let detail = body.trimmingCharacters(in: .whitespacesAndNewlines)
                return "AnkiWeb a répondu \(code)\(step)\(detail.isEmpty || detail == String(code) ? "" : " : \(detail.prefix(160))")."
            case .decoding(let what): return String(localized: "Réponse d'AnkiWeb illisible (\(what)).")
            case .unsupported(let message): return message
            case .sanity(let detail): return String(localized: "AnkiWeb a refusé l'envoi (contrôle de cohérence) — rien n'a été modifié. \(detail)")
            case .fullSyncRequired: return String(localized: "Ta collection AnkiWeb demande une synchronisation complète : synchronise d'abord Anki sur ton ordinateur ou ton téléphone.")
            }
        }
    }

    // MARK: Transport

    /// Une requête : `c=0` (pas de gzip), `k` (clé d'hôte), `s` (session), `data`.
    @discardableResult
    func call(_ method: String, json: Any = [String: Any](), timeout: TimeInterval = 60) async throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: json)
        return try await post(method, data: body, timeout: timeout)
    }

    private func post(_ method: String, data: Data, timeout: TimeInterval, redirects: Int = 0) async throws -> Data {
        let boundary = "Polymestre-\(Self.randomKey(16))"
        var request = URLRequest(url: endpoint.appendingPathComponent("sync").appendingPathComponent(method))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var form = Data()
        func field(_ name: String, _ value: Data, file: Bool = false) {
            form.append("--\(boundary)\r\n".data(using: .utf8)!)
            if file {
                form.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"data\"\r\n".data(using: .utf8)!)
                form.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
            } else {
                form.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            }
            form.append(value)
            form.append("\r\n".data(using: .utf8)!)
        }
        field("c", Data("0".utf8))
        if !hostKey.isEmpty { field("k", Data(hostKey.utf8)) }
        field("s", Data(sessionKey.utf8))
        field("data", data, file: true)
        form.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = form

        // Les redirections sont suivies **à la main** : AnkiWeb renvoie un
        // compte vers son serveur par un 308 dont l'adresse est la **racine**
        // du serveur (`https://sync12.ankiweb.net/`). URLSession, laissé faire,
        // y renvoyait le formulaire tel quel — sur la racine, pas sur
        // `/sync/<méthode>` — et AnkiWeb répondait 400.
        let payload: Data
        let response: URLResponse
        do {
            (payload, response) = try await session.data(for: request, delegate: RedirectBlocker.shared)
        } catch {
            AppLog.record(.warning, "anki", "AnkiWeb « \(method) » : pas de réponse",
                          detail: "\(request.url?.host ?? "?") — \(error.localizedDescription)")
            throw error
        }
        guard let http = response as? HTTPURLResponse else { throw Failure.server(0, "", method: method) }
        if !(200..<300).contains(http.statusCode) {
            // Ce que le serveur a vraiment répondu : la seule piste quand une
            // étape échoue (on ne peut pas reproduire sans le compte).
            let head = String(data: payload.prefix(160), encoding: .utf8)
                ?? payload.prefix(24).map { String(format: "%02x", $0) }.joined()
            AppLog.record(.warning, "anki", "AnkiWeb « \(method) » : HTTP \(http.statusCode)",
                          detail: "\(request.url?.absoluteString ?? "?") · \(http.value(forHTTPHeaderField: "Content-Type") ?? "?") · \(payload.count) o · \(head)")
        }
        switch http.statusCode {
        case 200..<300:
            return payload
        case 301, 302, 303, 307, 308:
            guard redirects < 3,
                  let location = http.value(forHTTPHeaderField: "Location") ?? String(data: payload, encoding: .utf8),
                  let target = Self.endpoint(fromRedirect: location, relativeTo: request.url) else {
                throw Failure.server(http.statusCode, String(localized: "redirection sans adresse"), method: method)
            }
            // Le compte vit sur un autre serveur : on y passe, et on rejoue.
            endpoint = target
            return try await post(method, data: data, timeout: timeout, redirects: redirects + 1)
        case 403:
            throw Failure.badCredentials
        case 501:
            throw Failure.unsupported("AnkiWeb n'accepte plus ce protocole de synchronisation.")
        default:
            throw Failure.server(http.statusCode, String(data: payload, encoding: .utf8) ?? "", method: method)
        }
    }

    /// La racine d'un serveur, lue dans une redirection : `Location` peut
    /// être la racine (`https://sync3.ankiweb.net/`) ou l'adresse complète de
    /// la méthode (`…/sync/meta`) ; on garde ce qui précède `/sync/`.
    static func endpoint(fromRedirect location: String, relativeTo base: URL?) -> URL? {
        let trimmed = location.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed, relativeTo: base)?.absoluteURL,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              url.scheme?.hasPrefix("http") == true else { return nil }
        var path = components.path
        if let range = path.range(of: "/sync/") { path = String(path[..<range.lowerBound]) }
        if !path.hasSuffix("/") { path += "/" }
        components.path = path
        components.query = nil
        return components.url
    }

    /// Refuse les redirections automatiques d'URLSession.
    private final class RedirectBlocker: NSObject, URLSessionTaskDelegate {
        static let shared = RedirectBlocker()
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            nil
        }
    }

    private func object(_ data: Data, _ what: String) throws -> [String: Any] {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let head = String(data: data.prefix(120), encoding: .utf8)
                ?? data.prefix(16).map { String(format: "%02x", $0) }.joined()
            AppLog.record(.warning, "anki", "AnkiWeb « \(what) » : réponse illisible", detail: "\(data.count) o · \(head)")
            throw Failure.decoding(what)
        }
        return value
    }

    // MARK: Connexion et métadonnées

    /// Échange identifiant et mot de passe contre une clé d'hôte, seule gardée.
    func login(username: String, password: String) async throws -> String {
        let reply = try object(try await call("hostKey", json: ["u": username, "p": password]), "hostKey")
        guard let key = reply["key"] as? String, !key.isEmpty else { throw Failure.badCredentials }
        hostKey = key
        return key
    }

    struct Meta {
        var modified: Int64
        var schema: Int64
        var usn: Int
        var hostNumber: Int
        var message: String
        var shouldContinue: Bool
        var empty: Bool
    }

    func meta() async throws -> Meta {
        let data: Data
        do {
            data = try await call("meta", json: ["v": Self.syncVersion, "cv": Self.clientVersion], timeout: 30)
        } catch Failure.server(400, _, _) where endpoint == Self.defaultEndpoint {
            // Le serveur principal répond 400 à l'ancien format quand le compte
            // vit ailleurs, au lieu de rediriger. Le format récent, lui, reçoit
            // la redirection (308 → `https://sync20.ankiweb.net/`) : on s'en
            // sert pour trouver le serveur du compte, puis on rejoue.
            guard let home = try await discoverServer() else { throw Failure.server(400, "", method: "meta") }
            endpoint = home
            data = try await call("meta", json: ["v": Self.syncVersion, "cv": Self.clientVersion], timeout: 30)
        }
        let reply = try object(data, "meta")
        let meta = Meta(modified: (reply["mod"] as? NSNumber)?.int64Value ?? 0,
                        schema: (reply["scm"] as? NSNumber)?.int64Value ?? 0,
                        usn: (reply["usn"] as? NSNumber)?.intValue ?? 0,
                        hostNumber: (reply["hostNum"] as? NSNumber)?.intValue ?? 0,
                        message: reply["msg"] as? String ?? "",
                        shouldContinue: reply["cont"] as? Bool ?? true,
                        empty: reply["empty"] as? Bool ?? false)
        // Anciens clients : le numéro d'hôte désigne le serveur du compte.
        // Les serveurs actuels redirigent eux-mêmes (308) : si celui-ci refuse
        // la clé, on reste sur le serveur qui a répondu.
        if meta.hostNumber > 0, endpoint == Self.defaultEndpoint,
           let url = URL(string: "https://sync\(meta.hostNumber).ankiweb.net/") {
            endpoint = url
            if let moved = try? await self.meta() { return moved }
            AppLog.record(.info, "anki", "AnkiWeb : le serveur sync\(meta.hostNumber) ne répond pas, on reste sur le serveur principal")
            endpoint = Self.defaultEndpoint
        }
        guard meta.shouldContinue else { throw Failure.unsupported(meta.message.isEmpty ? String(localized: "AnkiWeb refuse la synchronisation.") : meta.message) }
        return meta
    }

    /// Le serveur du compte, lu dans la redirection que le format récent du
    /// protocole (en-tête `anki-sync`, corps zstd) reçoit du serveur principal.
    /// Seul le code et l'en-tête `Location` servent : la réponse (zstd) n'est
    /// pas lue.
    func discoverServer() async throws -> URL? {
        let body = try JSONSerialization.data(withJSONObject: ["v": 11, "cv": Self.clientVersion])
        var request = URLRequest(url: Self.defaultEndpoint.appendingPathComponent("sync").appendingPathComponent("meta"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        let header: [String: Any] = ["v": 11, "k": hostKey, "c": Self.shortClientVersion, "s": sessionKey]
        request.setValue(String(decoding: try JSONSerialization.data(withJSONObject: header), as: UTF8.self),
                         forHTTPHeaderField: "anki-sync")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = ZstdFrame.stored(body)
        let (_, response) = try await session.data(for: request, delegate: RedirectBlocker.shared)
        guard let http = response as? HTTPURLResponse, [301, 302, 307, 308].contains(http.statusCode),
              let location = http.value(forHTTPHeaderField: "Location") else { return nil }
        let server = Self.endpoint(fromRedirect: location, relativeTo: request.url)
        AppLog.record(.info, "anki", "AnkiWeb : compte sur \(server?.host ?? "?")")
        return server
    }

    /// La collection entière, un fichier SQLite (schéma 11).
    func download() async throws -> Data {
        let data = try await call("download", timeout: 300)
        guard data.starts(with: Data("SQLite format 3".utf8)) else {
            throw Failure.decoding(String(data: data.prefix(80), encoding: .utf8) ?? "download")
        }
        return data
    }

    // MARK: Synchronisation normale

    func start(minUsn: Int, localIsNewer: Bool) async throws -> [String: Any] {
        try object(try await call("start", json: ["minUsn": minUsn, "lnewer": localIsNewer]), "start")
    }

    func applyGraves(cards: [Int64] = [], notes: [Int64] = [], decks: [Int64] = []) async throws {
        try await call("applyGraves", json: ["chunk": ["cards": cards, "notes": notes, "decks": decks]])
    }

    func applyChanges(models: [Any] = [], decks: [Any] = [], deckConfig: [Any] = [], tags: [String] = []) async throws -> [String: Any] {
        try object(try await call("applyChanges", json: ["changes": ["models": models,
                                                                     "decks": [decks, deckConfig],
                                                                     "tags": tags]]), "applyChanges")
    }

    func chunk() async throws -> [String: Any] {
        try object(try await call("chunk"), "chunk")
    }

    func applyChunk(notes: [[Any]], cards: [[Any]], revlog: [[Any]] = [], done: Bool) async throws {
        var chunk: [String: Any] = ["done": done]
        if !notes.isEmpty { chunk["notes"] = notes }
        if !cards.isEmpty { chunk["cards"] = cards }
        if !revlog.isEmpty { chunk["revlog"] = revlog }
        try await call("applyChunk", json: ["chunk": chunk])
    }

    /// `[[new, learn, review], cards, notes, revlog, graves, models, decks, deckConfig]`.
    func sanityCheck(_ counts: [Any]) async throws -> [String: Any] {
        try object(try await call("sanityCheck2", json: ["client": counts]), "sanityCheck2")
    }

    func finish() async throws -> Int64 {
        let data = try await call("finish")
        if let value = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? NSNumber {
            return value.int64Value
        }
        throw Failure.decoding("finish")
    }

    func abort() async {
        _ = try? await call("abort")
    }

    static func randomKey(_ length: Int) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return String((0..<length).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] })
    }
}
