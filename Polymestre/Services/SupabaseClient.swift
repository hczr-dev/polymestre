import Foundation

/// Erreurs du client Supabase.
enum SupabaseError: LocalizedError {
    case notConfigured
    /// Configuré, mais sans session utilisable : jamais connecté·e, ou session
    /// expirée et refusée au rafraîchissement.
    case notSignedIn
    case invalidURL
    case invalidResponse
    case server(status: Int, message: String)
    case decoding(String)
    /// L'entraide d'un groupe est chiffrée, et la clé n'est pas encore arrivée
    /// sur cet appareil : on n'envoie rien plutôt que d'envoyer en clair.
    case groupKeyPending

    var errorDescription: String? {
        switch self {
        case .notConfigured: return String(localized: "Supabase n'est pas configuré (URL ou clé manquante).")
        case .notSignedIn: return String(localized: "Session expirée ou absente : reconnecte-toi dans Réglages › Compte et groupes.")
        case .invalidURL: return String(localized: "URL Supabase invalide.")
        case .invalidResponse: return String(localized: "Réponse invalide du serveur.")
        case .server(let status, let message): return String(localized: "Erreur serveur (\(status)) : \(message)")
        case .decoding(let detail): return String(localized: "Décodage impossible : \(detail)")
        case .groupKeyPending: return String(localized: "La clé de chiffrement du groupe n'est pas encore arrivée sur ce téléphone. Elle arrive dès qu'un membre du groupe ouvre l'app ; réessaie dans un instant.")
        }
    }
}

/// Session authentifiée Supabase.
struct SupabaseSession: Decodable {
    var accessToken: String
    var tokenType: String?
    var expiresIn: Int?
    var refreshToken: String?
    var user: SupabaseUser?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case user
    }
}

struct SupabaseUser: Decodable {
    var id: String
    var email: String?
}

/// Client REST minimal pour Supabase (Auth + PostgREST), sans dépendance externe.
///
/// `@MainActor` : le jeton, son rafraîchissement en cours (`refreshing`) et la
/// session vivent ici, et une synchronisation lance six requêtes ensemble
/// (`async let`). Sans isolation, elles tournaient sur six fils à la fois : deux
/// d'entre elles pouvaient présenter le **même** jeton de rafraîchissement, que
/// Supabase fait tourner à chaque usage — le second est pris pour un vol, et la
/// session entière est révoquée. C'était la « connexion qui ne tient pas ».
/// Le réseau, lui, ne bloque pas le fil principal : `URLSession` attend ailleurs.
@MainActor
final class SupabaseClient {

    let baseURL: URL
    let anonKey: String

    private let session: URLSession
    private(set) var accessToken: String?
    private(set) var userID: String?
    private(set) var userEmail: String?
    /// Jeton de rafraîchissement : sans lui, la session mourait au bout d'une heure
    /// et toutes les requêtes échouaient en 401 — en silence, puisque les appelants
    /// ignoraient l'erreur.
    private var refreshToken: String?
    private var expiresAt: Date?

    var isSignedIn: Bool { accessToken != nil }

    /// Appelé à chaque changement de session — connexion, rafraîchissement,
    /// effacement. `SocialService` en tenait une copie figée au lancement : une
    /// session effacée pendant l'exécution le laissait se croire connecté.
    var onSessionChange: (() -> Void)?

    /// Hôte, utilisé comme clé de trousseau.
    private var host: String { baseURL.host ?? baseURL.absoluteString }

    init?(urlString: String, anonKey: String, session: URLSession = .shared) {
        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = anonKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty, !trimmedKey.isEmpty,
              let url = URL(string: trimmedURL) else { return nil }
        self.baseURL = url
        self.anonKey = trimmedKey
        self.session = session

        // Reprise de la session du lancement précédent.
        if let stored = SupabaseSessionStore.load(host: url.host ?? trimmedURL) {
            self.accessToken = stored.accessToken
            self.refreshToken = stored.refreshToken
            // Une session enregistrée avant que l'identifiant ne le soit : il est
            // dans le jeton lui-même.
            self.userID = stored.userID ?? StoredSession.subject(ofJWT: stored.accessToken)
            self.userEmail = stored.email
            self.expiresAt = stored.expiresAt
        }
    }

    // MARK: - Requête générique

    @discardableResult
    func request(_ path: String,
                 method: String = "GET",
                 query: [URLQueryItem] = [],
                 body: Data? = nil,
                 prefer: String? = nil,
                 useAuth: Bool = true) async throws -> Data? {
        try await perform(path, method: method, query: query, body: body,
                          prefer: prefer, useAuth: useAuth, allowsRefresh: true)
    }

    private func perform(_ path: String,
                         method: String,
                         query: [URLQueryItem],
                         body: Data?,
                         prefer: String?,
                         useAuth: Bool,
                         allowsRefresh: Bool) async throws -> Data? {
        if useAuth, allowsRefresh, needsRefresh() {
            try await refreshOrForget()
        }

        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw SupabaseError.invalidURL
        }
        components.path = path
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw SupabaseError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if useAuth, let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        } else {
            request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        }
        if let prefer {
            request.setValue(prefer, forHTTPHeaderField: "Prefer")
        }
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SupabaseError.invalidResponse }

        // Jeton refusé alors qu'on se croyait connecté : on rafraîchit **une fois**
        // et on rejoue la requête. Sans cette seconde chance, une session expirée
        // faisait échouer chaque appel jusqu'au prochain redémarrage manuel.
        if http.statusCode == 401, useAuth, allowsRefresh, refreshToken != nil {
            try await refreshOrForget(force: true)
            return try await perform(path, method: method, query: query, body: body,
                                     prefer: prefer, useAuth: useAuth, allowsRefresh: false)
        }

        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw SupabaseError.server(status: http.statusCode, message: message)
        }
        return data
    }

    // MARK: - Session

    private func needsRefresh() -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= Date().addingTimeInterval(StoredSession.leeway)
    }

    /// Le rafraîchissement en cours, partagé : dix requêtes parties ensemble
    /// avec un jeton expiré n'en font qu'**un**. Supabase fait tourner le jeton
    /// de rafraîchissement à chaque usage ; le présenter deux fois de suite le
    /// fait révoquer — et toute la session avec.
    private var refreshing: Task<Void, Error>?

    /// Rafraîchit ; n'efface la session que si le serveur **refuse** le jeton.
    ///
    /// Avant, n'importe quel échec — métro sans réseau, requête expirée — effaçait
    /// la session : il fallait se reconnecter aux groupes après chaque coupure.
    /// Une erreur réseau laisse la session intacte, réessayée à la requête
    /// suivante.
    private func refreshOrForget(force: Bool = false) async throws {
        do {
            try await refreshSession(force: force)
        } catch let error as SupabaseError {
            if case .server(let status, _) = error, [400, 401, 403].contains(status) {
                clearSession()
                Task { @MainActor in ConnectionCenter.shared.report(.groups, .expired) }
                throw SupabaseError.notSignedIn
            }
            throw error
        }
    }

    /// Échange le jeton de rafraîchissement contre un jeton d'accès neuf.
    private func refreshSession(force: Bool = false) async throws {
        if let refreshing { return try await refreshing.value }
        guard refreshToken != nil else { return }
        if !force, !needsRefresh() { return }
        let task = Task { try await self.exchangeRefreshToken() }
        refreshing = task
        defer { refreshing = nil }
        try await task.value
    }

    private func exchangeRefreshToken() async throws {
        guard let refreshToken else { return }

        let payload: [String: Any] = ["refresh_token": refreshToken]
        let data = try await perform("/auth/v1/token",
                                     method: "POST",
                                     query: [URLQueryItem(name: "grant_type", value: "refresh_token")],
                                     body: try JSONSerialization.data(withJSONObject: payload),
                                     prefer: nil,
                                     useAuth: false,
                                     allowsRefresh: false)
        try applySession(data)
    }

    /// Efface la session partout — mémoire **et** trousseau.
    private func clearSession() {
        accessToken = nil
        refreshToken = nil
        userID = nil
        userEmail = nil
        expiresAt = nil
        SupabaseSessionStore.clear(host: host)
        onSessionChange?()
    }

    // MARK: - Authentification

    func signInWithApple(idToken: String, nonce: String) async throws {
        let payload: [String: Any] = [
            "provider": "apple",
            "id_token": idToken,
            "nonce": nonce
        ]
        let data = try await request("/auth/v1/token",
                                     method: "POST",
                                     query: [URLQueryItem(name: "grant_type", value: "id_token")],
                                     body: try JSONSerialization.data(withJSONObject: payload),
                                     useAuth: false)
        try applySession(data)
    }

    /// Échange le code d'un retour OAuth (PKCE) contre la session (voir `OAuthPKCE`).
    func exchangePKCE(code: String, verifier: String) async throws {
        guard let body = OAuthPKCE.exchangeBody(code: code, verifier: verifier) else { throw SupabaseError.invalidResponse }
        let data = try await request(OAuthPKCE.exchangePath,
                                     method: "POST",
                                     query: OAuthPKCE.exchangeQuery,
                                     body: body,
                                     useAuth: false)
        try applySession(data)
    }

    func signUp(email: String, password: String) async throws {
        let payload: [String: Any] = ["email": email, "password": password]
        let data = try await request("/auth/v1/signup",
                                     method: "POST",
                                     body: try JSONSerialization.data(withJSONObject: payload),
                                     useAuth: false)
        try applySession(data)
    }

    func signIn(email: String, password: String) async throws {
        let payload: [String: Any] = ["email": email, "password": password]
        let data = try await request("/auth/v1/token",
                                     method: "POST",
                                     query: [URLQueryItem(name: "grant_type", value: "password")],
                                     body: try JSONSerialization.data(withJSONObject: payload),
                                     useAuth: false)
        try applySession(data)
    }

    /// Définit le mot de passe du compte connecté (voir `SupabasePasswordUpdate`).
    /// Passe par `request` : jeton rafraîchi et requête rejouée sur 401, comme les autres appels.
    func updatePassword(_ password: String) async throws {
        guard isSignedIn else { throw SupabaseError.notSignedIn }
        guard let body = SupabasePasswordUpdate.body(password: password) else { throw SupabaseError.invalidResponse }
        _ = try await request(SupabasePasswordUpdate.path, method: SupabasePasswordUpdate.method, body: body)
    }

    /// Les fournisseurs de connexion du compte (« apple », « email »…), lus sur le serveur.
    func fetchProviders() async throws -> [String] {
        let data = try await request(SupabasePasswordUpdate.path)
        guard let data, let user = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return SupabasePasswordUpdate.providers(in: user)
    }

    func signOut() async {
        Task { @MainActor in ConnectionCenter.shared.report(.groups, .unknown) }
        if accessToken != nil {
            _ = try? await request("/auth/v1/logout", method: "POST")
        }
        clearSession()
    }

    private func applySession(_ data: Data?) throws {
        guard let data else { throw SupabaseError.invalidResponse }
        do {
            let session = try JSONDecoder().decode(SupabaseSession.self, from: data)
            self.accessToken = session.accessToken
            self.refreshToken = session.refreshToken ?? self.refreshToken
            self.userID = session.user?.id ?? StoredSession.subject(ofJWT: session.accessToken) ?? self.userID
            self.userEmail = session.user?.email ?? self.userEmail
            // Sans `expires_in`, on suppose une heure : c'est la valeur par défaut
            // de Supabase, et se tromper vers le bas ne coûte qu'un rafraîchissement.
            self.expiresAt = Date().addingTimeInterval(TimeInterval(session.expiresIn ?? 3600))

            if let accessToken, let expiresAt {
                SupabaseSessionStore.save(
                    StoredSession(accessToken: accessToken,
                                  refreshToken: self.refreshToken,
                                  userID: self.userID,
                                  email: self.userEmail,
                                  expiresAt: expiresAt),
                    host: host)
            }
            onSessionChange?()
            Task { @MainActor in ConnectionCenter.shared.report(.groups, .connected) }
        } catch {
            throw SupabaseError.decoding(error.localizedDescription)
        }
    }

    // MARK: - PostgREST helpers

    @discardableResult
    func select(_ table: String, query: [URLQueryItem]) async throws -> Data? {
        try await request("/rest/v1/\(table)", query: query)
    }

    @discardableResult
    /// - Parameter returning: `false` = `return=minimal`. **Indispensable** sur une
    ///   table dont la politique de lecture dépend de la ligne qu'on insère
    ///   (`group_members` : « visible par les membres ») — avec `RETURNING`,
    ///   Postgres relit la ligne dans la même instruction, la fonction `stable`
    ///   ne la voit pas encore, et l'insertion échoue en 42501 alors qu'elle est
    ///   parfaitement autorisée.
    func insert(_ table: String, values: [String: Any], returning: Bool = true) async throws -> Data? {
        let body = try JSONSerialization.data(withJSONObject: values)
        return try await request("/rest/v1/\(table)",
                                 method: "POST",
                                 body: body,
                                 prefer: returning ? "return=representation" : "return=minimal")
    }

    @discardableResult
    func insert(_ table: String, rows: [[String: Any]], returning: Bool = true) async throws -> Data? {
        let body = try JSONSerialization.data(withJSONObject: rows)
        return try await request("/rest/v1/\(table)",
                                 method: "POST",
                                 body: body,
                                 prefer: returning ? "return=representation" : "return=minimal")
    }

    @discardableResult
    func update(_ table: String, query: [URLQueryItem], values: [String: Any]) async throws -> Data? {
        let body = try JSONSerialization.data(withJSONObject: values)
        return try await request("/rest/v1/\(table)",
                                 method: "PATCH",
                                 query: query,
                                 body: body,
                                 prefer: "return=representation")
    }

    @discardableResult
    func delete(_ table: String, query: [URLQueryItem]) async throws -> Data? {
        try await request("/rest/v1/\(table)", method: "DELETE", query: query)
    }

    @discardableResult
    func upsert(_ table: String, rows: [[String: Any]], onConflict: String, returning: Bool = true) async throws -> Data? {
        let body = try JSONSerialization.data(withJSONObject: rows)
        return try await request("/rest/v1/\(table)",
                                 method: "POST",
                                 query: [URLQueryItem(name: "on_conflict", value: onConflict)],
                                 body: body,
                                 prefer: returning
                                     ? "resolution=merge-duplicates,return=representation"
                                     : "resolution=merge-duplicates,return=minimal")
    }

    @discardableResult
    func rpc(_ function: String, params: [String: Any]) async throws -> Data? {
        let body = try JSONSerialization.data(withJSONObject: params)
        return try await request("/rest/v1/rpc/\(function)", method: "POST", body: body)
    }
}
