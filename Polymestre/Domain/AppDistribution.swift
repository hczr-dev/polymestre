import Foundation

/// Distribuer l'app hors du simulateur, et en entendre parler : le courriel
/// « Signaler un problème » et le flux de mises à jour du Mac (Developer ID,
/// donc sans App Store pour prévenir d'une nouvelle version).
///
/// Les adresses viennent de la configuration (`FEEDBACK_EMAIL`, `SITE_HOST` dans
/// `Support/Supabase.xcconfig`), jamais du code : une autre école qui distribue
/// sa propre build y met les siennes. Vides, les boutons n'apparaissent pas.
enum AppDistribution {
    /// Le courriel de retour (`nil` : pas de bouton).
    static var feedbackAddress: String? { configured("FeedbackEmail") }
    /// Le site public de l'app : confidentialité, téléchargement du Mac.
    static var siteHost: String? { configured("SiteHost") }

    /// « 2.1 (14) » — lue dans le bundle.
    static var versionLabel: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return build.isEmpty ? short : "\(short) (\(build))"
    }

    static var build: String? { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String }

    private static func configured(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty, !value.hasPrefix("$(") else { return nil }
        return value
    }
}

// MARK: - Signaler un problème

/// Un courriel prêt à envoyer, avec ce qu'il faut pour comprendre : version,
/// appareil, et la fin du journal (`AppLog`). Un lien `mailto:` plutôt qu'une
/// pièce jointe : il marche sur l'iPhone et le Mac, avec n'importe quelle app
/// de messagerie, sans MessageUI.
enum FeedbackMail {
    /// Au-delà, certaines apps de messagerie refusent le lien.
    static let maxBody = 6000

    static func url(to address: String, version: String, device: String, entries: [LogEntry]) -> URL? {
        let subject = "Polymestre \(version) — retour"
        var body = String(localized: "Ce qui s'est passé (et ce que tu attendais) :\n\n\n\n— Polymestre \(version) · \(device)\n")
        if !entries.isEmpty {
            let room = maxBody - body.count - 20
            // La fin du journal : les dernières lignes sont celles qui expliquent.
            body += String(localized: "\nFin du journal :\n") + String(LogBuffer.text(Array(entries.suffix(40))).suffix(max(0, room)))
        }
        let query = [("subject", subject), ("body", body)]
            .map { "\($0)=\(percent($1.replacingOccurrences(of: "\n", with: "\r\n")))" }
            .joined(separator: "&")
        return URL(string: "mailto:\(address)?\(query)")
    }

    /// RFC 6068 : seuls les caractères non réservés restent tels quels — un « & »
    /// ou un « = » du journal couperait sinon le corps du message.
    static func percent(_ text: String) -> String {
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        allowed.insert(charactersIn: "-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }
}

// MARK: - Mises à jour du Mac

/// `https://<site>/mac/latest.json` : la dernière build du Mac. Sans Sparkle ni
/// dépendance : un petit fichier, lu au plus une fois par jour.
///
///     {"version": "2.1", "build": 3, "url": "https://…/Polymestre.dmg", "notes": "…"}
struct MacUpdateFeed: Codable, Equatable {
    var version: String
    var build: Int
    var url: URL
    var notes: String?

    static func feedURL(siteHost: String) -> URL? { URL(string: "https://\(siteHost)/mac/latest.json") }

    static func decode(_ data: Data) -> MacUpdateFeed? { try? JSONDecoder().decode(Self.self, from: data) }

    /// Plus récente que la build qui tourne ? Le numéro de build seul fait foi :
    /// il monte à chaque envoi, la version affichée pas toujours.
    func isNewer(thanBuild current: String?) -> Bool {
        guard let current = current.flatMap({ Int($0) }) else { return false }
        return build > current
    }

    /// Une lecture par jour au plus (une horloge reculée relit aussitôt).
    static func isDue(lastCheck: Date?, now: Date = Date()) -> Bool {
        guard let lastCheck else { return true }
        return now < lastCheck || now.timeIntervalSince(lastCheck) >= 86_400
    }
}
