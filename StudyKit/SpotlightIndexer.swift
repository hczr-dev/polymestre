import CoreSpotlight
import Foundation
import SwiftData
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

/// Les cours dans la recherche du système (Spotlight, iPhone et Mac) : un
/// cours, une série, un exercice, un élément de théorie, et les notes de cours.
/// Taper « 3.4 analyse » ou « midterm barème » depuis l'écran d'accueil ouvre
/// le bon cours, sans passer par l'app.
@MainActor
enum SpotlightIndexer {
    private nonisolated static let domain = "ch.polymestre.content"
    private static var pending: Task<Void, Never>?
    /// L'empreinte du dernier index : rien n'est réécrit si rien n'a changé.
    private static var lastFingerprint: Int?

    /// Réindexe, groupé (plusieurs enregistrements de suite n'en font qu'un).
    static func schedule(container: ModelContainer) {
        pending?.cancel()
        pending = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, CSSearchableIndex.isIndexingAvailable() else { return }
            // Lire tous les cours, séries et exercices prend un moment : hors du
            // fil principal (un contexte à lui), pour ne pas figer l'interface.
            let built = await Task.detached(priority: .background) { collect(context: ModelContext(container)) }.value
            guard !Task.isCancelled, built.fingerprint != lastFingerprint else { return }
            lastFingerprint = built.fingerprint
            let index = CSSearchableIndex.default()
            let items = built.items
            index.deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in
                index.indexSearchableItems(items) { _ in }
            }
        }
    }

    private struct Built: @unchecked Sendable {
        let items: [CSSearchableItem]
        let fingerprint: Int
    }

    private nonisolated static func collect(context: ModelContext) -> Built {
        let courses = ((try? context.fetch(FetchDescriptor<Course>())) ?? []).filter(\.isTracked)
        var items: [CSSearchableItem] = []
        for course in courses {
            let label = "\(course.displayCode) · \(course.name)"
            items.append(item(id: "course:\(course.id)", title: label,
                              detail: course.notes.isEmpty ? String(localized: "Cours (au singulier)") : String(course.notes.prefix(300)),
                              keywords: [course.code, course.displayCode, course.name, "notes"]))
            for series in course.series {
                let name = series.title.isEmpty ? series.displayName : series.title
                items.append(item(id: "series:\(course.id):\(series.id)", title: "\(name) · \(course.displayCode)",
                                  detail: series.topic.isEmpty ? course.name : series.topic,
                                  keywords: [course.code, "série \(series.seriesNumber)"]))
                for exercise in series.exercises {
                    let summary = exercise.title.isEmpty ? MathMarkup.plain(exercise.statement) : exercise.title
                    items.append(item(id: "exercise:\(course.id):\(exercise.id)",
                                      title: String(localized: "Exercice \(exercise.displayNumber) · \(course.displayCode)"),
                                      detail: String(summary.prefix(200)),
                                      keywords: [course.code, exercise.exerciseNumber]))
                }
            }
            for theory in course.theoryItems {
                items.append(item(id: "theory:\(course.id):\(theory.id)",
                                  title: "\(theory.kind.label) \(theory.number) · \(course.displayCode)",
                                  detail: theory.title, keywords: [course.code, theory.number]))
            }
        }
        var hasher = Hasher()
        for entry in items {
            hasher.combine(entry.uniqueIdentifier)
            hasher.combine(entry.attributeSet.title)
            hasher.combine(entry.attributeSet.contentDescription)
        }
        return Built(items: items, fingerprint: hasher.finalize())
    }

    private nonisolated static func item(id: String, title: String, detail: String, keywords: [String]) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = title
        attributes.contentDescription = detail
        attributes.keywords = keywords
        return CSSearchableItem(uniqueIdentifier: id, domainIdentifier: domain, attributeSet: attributes)
    }

    /// Un résultat touché dans Spotlight : le cours, et la cible s'il y en a une.
    static func destination(of identifier: String) -> (courseID: UUID, targetID: UUID?)? {
        let parts = identifier.split(separator: ":").map(String.init)
        guard parts.count >= 2, let course = UUID(uuidString: parts[1]) else { return nil }
        return (course, parts.count >= 3 ? UUID(uuidString: parts[2]) : nil)
    }
}
