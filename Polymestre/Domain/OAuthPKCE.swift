import Foundation
import CryptoKit
import Security

/// « Continuer avec Google » : GoTrue en OAuth avec PKCE (RFC 7636), sans supabase-js.
///
/// Le flux (le même que `windows/src/services/oauth.ts`) :
///   1. un `code_verifier` aléatoire et son `code_challenge` (S256) ;
///   2. `{URL}/auth/v1/authorize?provider=google&redirect_to=polymestre://auth-callback&code_challenge=…
///      &code_challenge_method=s256` s'ouvre dans une feuille de connexion ;
///   3. elle capte `polymestre://auth-callback?code=…` ;
///   4. `POST /auth/v1/token?grant_type=pkce` `{auth_code, code_verifier}` rend la session.
/// Lier Google à un compte déjà connecté passe par `/auth/v1/user/identities/authorize`.
///
/// Pur : tout ce qui se construit sans réseau se teste dans `Validation`.
enum OAuthPKCE {
    /// L'adresse que GoTrue rappelle ; à déclarer dans Authentication › URL Configuration › Redirect URLs.
    static let redirect = "polymestre://auth-callback"
    static let callbackScheme = "polymestre"

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// 32 octets aléatoires → 43 caractères de l'alphabet permis par la RFC.
    static func makeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    /// `BASE64URL(SHA256(verifier))`.
    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func authorizePath(link: Bool) -> String {
        link ? "/auth/v1/user/identities/authorize" : "/auth/v1/authorize"
    }

    static func authorizeQuery(provider: String = "google", challenge: String, skipRedirect: Bool = false) -> [URLQueryItem] {
        var items = [URLQueryItem(name: "provider", value: provider),
                     URLQueryItem(name: "redirect_to", value: redirect),
                     URLQueryItem(name: "code_challenge", value: challenge),
                     URLQueryItem(name: "code_challenge_method", value: "s256")]
        if skipRedirect { items.append(URLQueryItem(name: "skip_http_redirect", value: "true")) }
        return items
    }

    static func authorizeURL(base: URL, provider: String = "google", challenge: String, link: Bool = false, skipRedirect: Bool = false) -> URL? {
        guard var c = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        c.path = authorizePath(link: link)
        c.queryItems = authorizeQuery(provider: provider, challenge: challenge, skipRedirect: skipRedirect)
        return c.url
    }

    enum Callback: Equatable {
        case code(String)
        case error(String)
    }

    /// Ce que GoTrue renvoie à `polymestre://auth-callback` : `?code=…`, ou une erreur en
    /// `?error_description=…` / `#error_description=…`. `nil` : ce n'est pas notre retour.
    static func parseCallback(_ url: URL) -> Callback? {
        guard url.scheme == callbackScheme else { return nil }
        var items: [String: String] = [:]
        let c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        for item in c?.queryItems ?? [] { if let v = item.value { items[item.name] = v } }
        if let fragment = c?.fragment, !fragment.isEmpty {
            var f = URLComponents()
            f.query = fragment
            for item in f.queryItems ?? [] { if let v = item.value, items[item.name] == nil { items[item.name] = v } }
        }
        if let e = items["error_description"] ?? items["error"] { return .error(e) }
        if let code = items["code"], !code.isEmpty { return .code(code) }
        return nil
    }

    /// Le corps de `POST /auth/v1/token?grant_type=pkce`.
    static func exchangeBody(code: String, verifier: String) -> Data? {
        try? JSONSerialization.data(withJSONObject: ["auth_code": code, "code_verifier": verifier])
    }

    static let exchangePath = "/auth/v1/token"
    static let exchangeQuery = [URLQueryItem(name: "grant_type", value: "pkce")]

    // MARK: Messages

    static let notEnabledMessage = String(localized: "La connexion Google n'est pas encore activée sur le serveur.")
    static let linkDisabledMessage = String(localized: "Lier un compte Google n'est pas encore activé sur le serveur.")

    /// Une réponse d'erreur de GoTrue, en français.
    static func message(status: Int, body: String, link: Bool = false) -> String {
        let raw = body.lowercased()
        if raw.contains("manual linking") || raw.contains("manual_linking") || (raw.contains("linking") && raw.contains("disabled")) {
            return linkDisabledMessage
        }
        if raw.contains("provider is not enabled") || raw.contains("unsupported provider") || raw.contains("not enabled") {
            return link ? linkDisabledMessage : notEnabledMessage
        }
        if raw.contains("identity_already_exists") || (raw.contains("already") && raw.contains("linked")) {
            return String(localized: "Ce compte Google est déjà lié à un autre compte Polymestre.")
        }
        if status >= 500 { return String(localized: "Le serveur a un problème (\(status)) : réessaie dans un instant.") }
        return String(localized: "Le serveur a refusé la connexion Google (\(status)).")
    }

    /// Une erreur du retour (dans l'adresse de rappel), en français.
    static func callbackMessage(_ description: String, link: Bool = false) -> String {
        message(status: 400, body: description, link: link)
    }
}

/// Une erreur du flux, déjà en français.
struct OAuthFlowError: LocalizedError {
    let text: String
    var errorDescription: String? { text }
}
