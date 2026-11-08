import Foundation
import SwiftData

/// Tient le calendrier académique à jour dans l'app.
///
/// Deux sources, dans cet ordre :
///   1. **L'instantané embarqué** — disponible hors ligne dès l'installation, et
///      le jour de la rentrée, quand on n'a justement pas de réseau.
///   2. **La page publique de l'EPFL**, relue à la demande. L'EPFL publie deux
///      semestres à la fois et fait glisser la fenêtre chaque année : sans
///      relecture, l'app saurait le semestre en cours mais pas le suivant.
enum AcademicCalendarService {

    static let sourceURL = AcademicCalendarParser.sourceURL

    enum RefreshError: LocalizedError {
        case network(String)
        case http(Int)
        case empty
        case unreadable

        var errorDescription: String? {
            switch self {
            case .network(let detail): return String(localized: "Téléchargement impossible : \(detail)")
            case .http(let code): return String(localized: "La page de l'EPFL a répondu \(code).")
            case .empty: return String(localized: "La page ne contient aucune date lisible.")
            case .unreadable: return String(localized: "La page n'a pas pu être lue comme du texte.")
            }
        }
    }

    struct RefreshResult {
        var added = 0
        var updated = 0
        var removed = 0
        var total = 0

        var message: String {
            var parts: [String] = [String(localized: "\(Plural.count(total, "\(total) échéance", "\(total) échéances")) à jour")]
            if added > 0 { parts.append(Plural.count(added, "\(added) ajoutée", "\(added) ajoutées")) }
            if updated > 0 { parts.append(Plural.count(updated, "\(updated) corrigée", "\(updated) corrigées")) }
            if removed > 0 { parts.append(Plural.count(removed, "\(removed) retirée", "\(removed) retirées")) }
            return parts.joined(separator: " · ")
        }
    }

    // MARK: Amorçage

    /// Installe l'instantané si l'app ne connaît encore aucune échéance.
    ///
    /// Idempotent : une échéance déjà présente est mise à jour, jamais dupliquée.
    @discardableResult
    static func seedIfNeeded(_ context: ModelContext) -> Int {
        AcademicMilestone.installSnapshotIfNeeded(in: context)
    }

    // MARK: Relecture

    /// Relit la page publique et met le calendrier à jour.
    static func refresh(_ context: ModelContext,
                        urlString: String = sourceURL,
                        session: URLSession = .shared) async throws -> RefreshResult {
        let html = try await fetch(urlString, session: session)
        let values = AcademicCalendarParser.parse(html: html)
        guard !values.isEmpty else { throw RefreshError.empty }

        let outcome = AcademicMilestone.upsert(values, in: context)
        return RefreshResult(added: outcome.added,
                             updated: outcome.updated,
                             removed: outcome.removed,
                             total: values.count)
    }

    /// Télécharge la page. Séparé de l'analyse : le réseau se teste à part du
    /// parseur, qui est pur.
    static func fetch(_ urlString: String, session: URLSession = .shared) async throws -> String {
        var raw = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, let url = URL(string: raw), url.scheme?.hasPrefix("http") == true else {
            throw RefreshError.network(String(localized: "adresse invalide"))
        }
        raw = url.absoluteString

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        // Sans en-tête explicite, certains serveurs renvoient une page allégée.
        request.setValue("Polymestre/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        request.setValue("fr-CH,fr;q=0.9", forHTTPHeaderField: "Accept-Language")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw RefreshError.network(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw RefreshError.http(http.statusCode)
        }
        guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            throw RefreshError.unreadable
        }
        return text
    }

    // MARK: Lecture

    /// Les prochaines échéances, la plus proche d'abord.
    static func upcoming(_ milestones: [AcademicMilestone],
                         limit: Int? = nil,
                         from reference: Date = Date()) -> [AcademicMilestone] {
        let future = milestones
            .filter { $0.date >= Calendar.current.startOfDay(for: reference) }
            .sorted { $0.date < $1.date }
        guard let limit else { return future }
        return Array(future.prefix(limit))
    }

    /// La prochaine échéance **structurante** — celle qui décide du semestre.
    static func nextStructural(_ milestones: [AcademicMilestone],
                               from reference: Date = Date()) -> AcademicMilestone? {
        upcoming(milestones.filter { $0.kind.isStructural }, from: reference).first
    }

}
