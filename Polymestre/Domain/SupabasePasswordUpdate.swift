import Foundation

/// Définir (ou changer) le mot de passe du compte : `PUT /auth/v1/user`.
///
/// Un compte créé avec « Se connecter avec Apple » n'a pas de mot de passe, donc ne
/// peut pas se connecter sur Windows ni sur le Mac. Cette requête lui en donne un,
/// sans rien configurer sur le tableau de bord Supabase. Pure : la forme de la
/// requête se teste sans réseau.
enum SupabasePasswordUpdate {
    static let path = "/auth/v1/user"
    static let method = "PUT"
    static let minimumLength = 6

    /// Les mêmes règles que le formulaire d'inscription : 6 caractères au moins, et deux saisies identiques.
    enum Problem: Equatable {
        case tooShort, mismatch
        var message: String {
            switch self {
            case .tooShort: return String(localized: "6 caractères au moins.")
            case .mismatch: return String(localized: "Les deux mots de passe ne sont pas identiques.")
            }
        }
    }

    static func validate(_ password: String, confirmation: String) -> Problem? {
        if password.count < minimumLength { return .tooShort }
        if password != confirmation { return .mismatch }
        return nil
    }

    static func body(password: String) -> Data? {
        try? JSONSerialization.data(withJSONObject: ["password": password])
    }

    /// Les fournisseurs d'identité d'un utilisateur Supabase (`app_metadata.providers`, `identities[].provider`).
    static func providers(in user: [String: Any]) -> [String] {
        var found: [String] = []
        if let meta = user["app_metadata"] as? [String: Any] {
            if let list = meta["providers"] as? [String] { found += list }
            if let one = meta["provider"] as? String { found.append(one) }
        }
        if let identities = user["identities"] as? [[String: Any]] {
            found += identities.compactMap { $0["provider"] as? String }
        }
        var seen = Set<String>()
        return found.filter { seen.insert($0).inserted }
    }

    static func message(forStatus status: Int, body: String) -> String {
        let lower = body.lowercased()
        if lower.contains("same_password") || lower.contains("different from the old") {
            return String(localized: "Ce mot de passe est déjà le tien : choisis-en un autre.")
        }
        if lower.contains("weak") || lower.contains("at least") || lower.contains("short") {
            return String(localized: "Le mot de passe est trop faible (6 caractères au moins).")
        }
        if status == 401 || status == 403 { return String(localized: "Session expirée : reconnecte-toi, puis réessaie.") }
        if status >= 500 { return String(localized: "Le serveur a un problème (\(status)) : réessaie dans un instant.") }
        return String(localized: "Le serveur a refusé le changement (\(status)).")
    }
}
