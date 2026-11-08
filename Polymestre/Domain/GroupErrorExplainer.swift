import Foundation

/// Traduit une erreur Supabase en une phrase actionnable.
///
/// Fonction **pure** : elle ne reçoit qu'une chaîne, donc elle se teste sur les
/// réponses réelles du serveur. C'est important : ce traducteur a déjà menti deux
/// fois — en annonçant « politiques RLS » sans dire quelle table, et en laissant
/// croire qu'un réexécutable du SQL suffisait. Un diagnostic qu'on ne peut pas
/// tester est un diagnostic qu'on devine.
enum GroupErrorExplainer {

    static func explain(raw: String) -> String {
        let detail = serverDetail(raw)

        if raw.contains("PGRST205") {
            return String(localized: "les tables n'existent pas encore côté Supabase. Exécute `Support/supabase-schema.sql` dans le SQL Editor, puis relance la synchronisation.")
        }
        if raw.contains("PGRST202") {
            return String(localized: "la fonction `group_leaderboard` est absente. Elle est incluse dans `Support/supabase-schema.sql`.")
        }
        if raw.contains("PGRST201") {
            return String(localized: "le serveur trouve deux chemins entre deux tables et refuse de choisir. Relance `Support/supabase-schema.sql` : les clés étrangères y sont explicites.")
        }
        if raw.contains("permission denied") {
            // 42501 sur une **lecture** : ce n'est pas une politique RLS — elle
            // filtrerait en silence — mais un droit de table manquant.
            return String(localized: "le serveur refuse l'accès à la table (droits manquants). Réexécute `Support/supabase-schema.sql` : il accorde explicitement les droits aux rôles de l'app.\(detail)")
        }
        if raw.contains("42501") || raw.contains("row-level security") {
            return String(localized: "les politiques RLS refusent cette écriture — le plus souvent parce que tu n'es pas membre du groupe côté serveur. Appuie sur « Réparer et réessayer » : la synchronisation rétablit ton adhésion si tu as créé le groupe.\(detail)")
        }
        if raw.contains("23503") {
            return String(localized: "le profil n'existe pas encore côté serveur. Reconnecte-toi, puis relance.\(detail)")
        }
        if raw.contains("23505") {
            return String(localized: "cette ligne existe déjà côté serveur.\(detail)")
        }
        return raw
    }

    /// Extrait le message Postgres de la réponse JSON, pour l'ajouter au texte.
    ///
    /// PostgREST renvoie `{"code":"42501","message":"new row violates row-level
    /// security policy for table \"presence\"","details":null}`. Le `message` nomme
    /// la table et l'opération ; sans lui, l'utilisateur — et moi — devinons.
    /// Renvoie une chaîne vide s'il n'y a rien à ajouter : jamais de « Serveur : »
    /// orphelin.
    static func serverDetail(_ raw: String) -> String {
        guard let start = raw.firstIndex(of: "{"),
              let data = String(raw[start...]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ""
        }
        let message = (object["message"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let code = (object["code"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        let hint = (object["hint"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty

        var parts: [String] = []
        if let message, !message.isEmpty { parts.append(message) }
        if let hint { parts.append(hint) }
        if let code { parts.append("code \(code)") }
        return parts.isEmpty ? "" : "\n\nServeur : " + parts.joined(separator: " · ")
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
