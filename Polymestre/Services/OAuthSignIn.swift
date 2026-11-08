import Foundation
import AuthenticationServices
import CryptoKit
import UIKit

/// Les identifiants OAuth des fournisseurs de tâches, compilés dans l'app
/// (`Support/Supabase.xcconfig` → Info.plist), comme ceux de Supabase.
///
/// Une valeur absente est un état valide : le bouton « Se connecter avec… »
/// disparaît et le fournisseur reste configurable à la main (jeton collé).
enum OAuthConfig {
    static var todoistClientID: String { value("TodoistClientID") }
    static var googleClientID: String { value("GoogleClientID") }
    static var tickTickClientID: String { value("TickTickClientID") }
    static var notionClientID: String { value("NotionClientID") }

    static func clientID(for provider: OAuthProvider) -> String {
        switch provider {
        case .todoist: return todoistClientID
        case .google: return googleClientID
        case .tickTick: return tickTickClientID
        case .notion: return notionClientID
        }
    }

    static func isAvailable(_ provider: OAuthProvider) -> Bool {
        let id = clientID(for: provider)
        guard SupabaseConfig.isUsable(id) else { return false }
        // Les fournisseurs à secret passent par la fonction Supabase.
        return provider.usesPKCE || SupabaseConfig.isConfigured
    }

    private static func value(_ key: String) -> String {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum OAuthProvider: String, CaseIterable, Identifiable {
    case todoist, google, tickTick = "ticktick", notion
    var id: String { rawValue }

    /// Google accepte un client public (PKCE, sans secret) :
    /// l'échange du code se fait depuis l'app. Les autres exigent un secret, qui
    /// ne vit que dans la fonction Supabase `oauth`.
    var usesPKCE: Bool { self == .google }

    var label: String {
        switch self {
        case .todoist: return "Todoist"
        case .google: return "Google"
        case .tickTick: return "TickTick"
        case .notion: return "Notion"
        }
    }
}

/// Le résultat d'une connexion : de quoi appeler l'API, et la renouveler.
struct OAuthTokens {
    var accessToken: String
    var refreshToken: String?
}

enum OAuthError: LocalizedError {
    case notConfigured, cancelled, badResponse(String), stateMismatch

    var errorDescription: String? {
        switch self {
        case .notConfigured: return String(localized: "Connexion indisponible dans cette version de l'app.")
        case .cancelled: return String(localized: "Connexion annulée.")
        case .badResponse(let detail): return String(localized: "Le service a refusé la connexion (\(detail)).")
        case .stateMismatch: return String(localized: "Réponse inattendue : réessaie.")
        }
    }
}

/// « Se connecter avec… » : une feuille de connexion du fournisseur, et le
/// retour dans l'app avec un jeton. Rien à copier-coller.
@MainActor
final class OAuthSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = OAuthSignIn()

    private var session: ASWebAuthenticationSession?

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }

    func signIn(_ provider: OAuthProvider) async throws -> OAuthTokens {
        guard OAuthConfig.isAvailable(provider) else { throw OAuthError.notConfigured }
        let state = Self.randomString(24)
        if provider.usesPKCE {
            let verifier = Self.randomString(64)
            let redirect = redirectURI(provider)
            let url = authorizeURL(provider, state: state, redirect: redirect, challenge: Self.challenge(verifier))
            let callback = try await authenticate(url: url, scheme: URL(string: redirect)?.scheme ?? "polymestre")
            let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard items.first(where: { $0.name == "state" })?.value == state else { throw OAuthError.stateMismatch }
            guard let code = items.first(where: { $0.name == "code" })?.value else {
                throw OAuthError.badResponse(items.first { $0.name == "error" }?.value ?? String(localized: "pas de code"))
            }
            return try await exchangePKCE(provider, code: code, verifier: verifier, redirect: redirect)
        }
        // Avec secret : le fournisseur renvoie vers la fonction Supabase, qui
        // échange le code et rouvre l'app sur `polymestre://oauth?…`.
        let redirect = "\(SupabaseConfig.urlString)/functions/v1/oauth"
        // `.polymestre` : la fonction rouvre cette app-ci (`polymestre://`), pas l'ancienne.
        let sent = "\(provider.rawValue).\(state).polymestre"
        let url = authorizeURL(provider, state: sent, redirect: redirect, challenge: nil)
        let callback = try await authenticate(url: url, scheme: "polymestre")
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let error = items.first(where: { $0.name == "error" })?.value { throw OAuthError.badResponse(error) }
        guard items.first(where: { $0.name == "state" })?.value == sent else {
            throw OAuthError.stateMismatch
        }
        guard let token = items.first(where: { $0.name == "access_token" })?.value, !token.isEmpty else {
            throw OAuthError.badResponse(String(localized: "pas de jeton"))
        }
        return OAuthTokens(accessToken: token, refreshToken: items.first { $0.name == "refresh_token" }?.value)
    }

    // MARK: Adresses

    /// Google : le schéma inversé du client iOS.
    private func redirectURI(_ provider: OAuthProvider) -> String {
        switch provider {
        case .google:
            let reversed = OAuthConfig.googleClientID.split(separator: ".").reversed().joined(separator: ".")
            return "\(reversed):/oauth2redirect"
        default:
            return "polymestre://oauth"
        }
    }

    private func authorizeURL(_ provider: OAuthProvider, state: String, redirect: String, challenge: String?) -> URL {
        let clientID = OAuthConfig.clientID(for: provider)
        var components: URLComponents
        var items = [URLQueryItem(name: "client_id", value: clientID),
                     URLQueryItem(name: "state", value: state),
                     URLQueryItem(name: "redirect_uri", value: redirect)]
        switch provider {
        case .todoist:
            components = URLComponents(string: "https://todoist.com/oauth/authorize")!
            items.append(URLQueryItem(name: "scope", value: "data:read_write"))
        case .google:
            components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
            items += [URLQueryItem(name: "response_type", value: "code"),
                      URLQueryItem(name: "scope", value: "https://www.googleapis.com/auth/tasks"),
                      URLQueryItem(name: "access_type", value: "offline"),
                      URLQueryItem(name: "prompt", value: "consent")]
        case .tickTick:
            components = URLComponents(string: "https://ticktick.com/oauth/authorize")!
            items += [URLQueryItem(name: "response_type", value: "code"),
                      URLQueryItem(name: "scope", value: "tasks:read tasks:write")]
        case .notion:
            components = URLComponents(string: "https://api.notion.com/v1/oauth/authorize")!
            items += [URLQueryItem(name: "response_type", value: "code"),
                      URLQueryItem(name: "owner", value: "user")]
        }
        if let challenge {
            items += [URLQueryItem(name: "code_challenge", value: challenge),
                      URLQueryItem(name: "code_challenge_method", value: "S256")]
        }
        components.queryItems = items
        return components.url!
    }

    // MARK: Échanges

    private func exchangePKCE(_ provider: OAuthProvider, code: String, verifier: String,
                              redirect: String) async throws -> OAuthTokens {
        let endpoint = provider == .google
            ? "https://oauth2.googleapis.com/token"
            : "https://login.microsoftonline.com/common/oauth2/v2.0/token"
        var fields = ["client_id": OAuthConfig.clientID(for: provider),
                      "code": code,
                      "code_verifier": verifier,
                      "redirect_uri": redirect,
                      "grant_type": "authorization_code"]
        let payload = try await Self.postForm(endpoint, fields: fields)
        guard let access = payload["access_token"] as? String else {
            throw OAuthError.badResponse(payload["error_description"] as? String ?? payload["error"] as? String ?? "?")
        }
        return OAuthTokens(accessToken: access, refreshToken: payload["refresh_token"] as? String)
    }


    static func postForm(_ endpoint: String, fields: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = fields.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&").data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: request)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func authenticate(url: URL, scheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { callback, error in
                if let callback {
                    continuation.resume(returning: callback)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: OAuthError.cancelled)
                } else {
                    continuation.resume(throwing: error ?? OAuthError.cancelled)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            session.start()
        }
    }

    // MARK: PKCE

    static func randomString(_ length: Int) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String((0..<length).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] })
    }

    static func challenge(_ verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8)))
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
