import Foundation
import AuthenticationServices
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// La feuille de connexion du système (`ASWebAuthenticationSession`) qui capte
/// `polymestre://auth-callback` : elle n'exige pas d'enregistrer le schéma.
@MainActor
final class SupabaseOAuthWebSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = SupabaseOAuthWebSession()
    private var session: ASWebAuthenticationSession?

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if canImport(UIKit)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? ASPresentationAnchor()
        #else
        return NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
        #endif
    }

    func authenticate(url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: OAuthPKCE.callbackScheme) { [weak self] callback, error in
                Task { @MainActor in self?.session = nil }
                if let callback { continuation.resume(returning: callback); return }
                if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: OAuthFlowError(text: String(localized: "Connexion annulée.")))
                } else {
                    continuation.resume(throwing: error ?? OAuthFlowError(text: String(localized: "La connexion Google a été interrompue.")))
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() {
                self.session = nil
                continuation.resume(throwing: OAuthFlowError(text: String(localized: "Impossible d'ouvrir la fenêtre de connexion.")))
            }
        }
    }
}

extension SupabaseClient {
    /// « Continuer avec Google » (`link: false`) ou lier Google au compte connecté (`link: true`).
    /// La session est posée comme après `signIn` : trousseau, groupes et synchronisation suivent.
    func continueWithGoogle(link: Bool = false) async throws {
        if link, !isSignedIn { throw SupabaseError.notSignedIn }
        let verifier = OAuthPKCE.makeVerifier()
        let challenge = OAuthPKCE.challenge(for: verifier)
        let target: URL
        if let resolved = try await resolveAuthorizeURL(challenge: challenge, link: link) {
            target = resolved
        } else if let direct = OAuthPKCE.authorizeURL(base: baseURL, challenge: challenge, link: link) {
            target = direct
        } else {
            throw SupabaseError.invalidURL
        }
        let callbackURL = try await SupabaseOAuthWebSession.shared.authenticate(url: target)
        switch OAuthPKCE.parseCallback(callbackURL) {
        case .code(let code):
            do {
                try await exchangePKCE(code: code, verifier: verifier)
            } catch SupabaseError.server(let status, let body) {
                throw OAuthFlowError(text: OAuthPKCE.message(status: status, body: body, link: link))
            }
        case .error(let description):
            throw OAuthFlowError(text: OAuthPKCE.callbackMessage(description, link: link))
        case nil:
            throw OAuthFlowError(text: String(localized: "La connexion Google a été interrompue."))
        }
    }

    /// Demande à GoTrue l'adresse du fournisseur (`skip_http_redirect`) : un fournisseur éteint se dit tout
    /// de suite, au lieu d'une page d'erreur dans la feuille. `nil` : réponse inattendue — on ouvre l'adresse directe.
    private func resolveAuthorizeURL(challenge: String, link: Bool) async throws -> URL? {
        let query = OAuthPKCE.authorizeQuery(challenge: challenge, skipRedirect: true)
        do {
            let data: Data?
            if link {
                data = try await request(OAuthPKCE.authorizePath(link: true), query: query)
            } else {
                guard let url = OAuthPKCE.authorizeURL(base: baseURL, challenge: challenge, skipRedirect: true) else { return nil }
                var req = URLRequest(url: url)
                req.timeoutInterval = 30
                req.setValue(anonKey, forHTTPHeaderField: "apikey")
                let (body, response) = try await URLSession(configuration: .ephemeral).data(for: req)
                guard let http = response as? HTTPURLResponse else { return nil }
                if http.statusCode >= 400 {
                    throw SupabaseError.server(status: http.statusCode, message: String(data: body, encoding: .utf8) ?? "")
                }
                data = body
            }
            guard let data, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = json["url"] as? String else { return nil }
            return URL(string: text)
        } catch SupabaseError.server(let status, let body) {
            throw OAuthFlowError(text: OAuthPKCE.message(status: status, body: body, link: link))
        } catch let error as OAuthFlowError {
            throw error
        } catch {
            return nil
        }
    }
}
