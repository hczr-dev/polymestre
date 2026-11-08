import Foundation

/// Ce qui est apparu sur Moodle depuis la dernière vérification.
///
/// Pur, donc testé : la surveillance en arrière-plan (`MoodleWatcher`) lit le
/// plan du cours, et c'est ici qu'on décide ce qui est **nouveau**, ce qui
/// mérite d'être dit, et comment le dire.
enum MoodleNews {

    /// Les familles qu'on peut choisir d'annoncer.
    enum Kind: String, CaseIterable, Identifiable, Codable {
        case series, solution, deadline, lecture, document

        var id: String { rawValue }

        /// Ce qu'on annonce si l'étudiant·e n'a rien choisi : ce qui se fait.
        static let defaults: Set<Kind> = [.series, .solution, .deadline]

        var label: String {
            switch self {
            case .series: return String(localized: "Séries")
            case .solution: return String(localized: "Corrigés")
            case .deadline: return String(localized: "Rendus")
            case .lecture: return String(localized: "Cours et vidéos")
            case .document: return String(localized: "Autres documents")
            }
        }

        var icon: String {
            switch self {
            case .series: return "doc.text"
            case .solution: return "checkmark.seal"
            case .deadline: return "tray.and.arrow.up"
            case .lecture: return "play.rectangle"
            case .document: return "folder"
            }
        }

        /// « Nouvelle série », en tête d'une notification d'un seul élément.
        var newLabel: String {
            switch self {
            case .series: return String(localized: "Nouvelle série")
            case .solution: return String(localized: "Nouveau corrigé")
            case .deadline: return String(localized: "Nouveau rendu")
            case .lecture: return String(localized: "Nouveau cours")
            case .document: return String(localized: "Nouveau document")
            }
        }

        init?(_ kind: MoodleCourseAnalyzer.ActivityKind) {
            switch kind {
            case .series: self = .series
            case .solution: self = .solution
            case .deadline: self = .deadline
            case .lecture: self = .lecture
            case .document: self = .document
            case .ignore: return nil
            }
        }

        /// `series,solution` ⇄ l'ensemble : un réglage en une chaîne.
        static func decode(_ raw: String?) -> Set<Kind> {
            guard let raw else { return defaults }
            return Set(raw.split(separator: ",").compactMap { Kind(rawValue: String($0)) })
        }

        static func encode(_ kinds: Set<Kind>) -> String {
            allCases.filter(kinds.contains).map(\.rawValue).joined(separator: ",")
        }
    }

    struct Item: Equatable {
        var id: String
        var name: String
        var kind: Kind
    }

    /// Les activités **visibles** d'un cours, rangées : une activité cachée
    /// n'est pas vue, pour qu'un corrigé dévoilé plus tard soit annoncé.
    static func visibleItems(of snapshot: MoodleCourseSnapshot) -> [Item] {
        snapshot.sections.flatMap { section in
            section.activities.compactMap { activity -> Item? in
                guard activity.isVisible,
                      let kind = Kind(MoodleCourseAnalyzer.classify(activity, inWeek: section.number > 0)) else { return nil }
                return Item(id: activity.id, name: activity.name, kind: kind)
            }
        }
    }

    /// Ce qui n'était pas là, et l'ensemble vu à retenir.
    ///
    /// `known == nil` : premier passage. On retient sans rien annoncer — sinon
    /// le premier relevé annoncerait tout le semestre.
    static func diff(_ snapshot: MoodleCourseSnapshot, known: Set<String>?) -> (new: [Item], seen: Set<String>) {
        let items = visibleItems(of: snapshot)
        let seen = Set(items.map(\.id))
        guard let known else { return ([], seen) }
        // Une activité disparue puis revenue reste connue : l'union évite de
        // réannoncer ce qu'un·e enseignant·e cache le temps d'une correction.
        return (items.filter { !known.contains($0.id) }, seen.union(known))
    }

    /// Le texte d'une notification : une par cours et par relevé.
    static func message(courseCode: String, items: [Item]) -> (title: String, body: String)? {
        guard let first = items.first else { return nil }
        if items.count == 1 {
            return ("\(first.kind.newLabel) · \(courseCode)", first.name)
        }
        let shown = items.prefix(3).map(\.name)
        let rest = items.count - shown.count
        let body = shown.joined(separator: " · ") + (rest > 0 ? " · +\(rest)" : "")
        return (String(localized: "\(items.count) nouveautés · \(courseCode)"), body)
    }

    /// Quand dire la nouvelle : maintenant (`nil`), ou à la fin des heures
    /// calmes. `start == end` : pas d'heures calmes. La fenêtre peut passer
    /// minuit (22 h → 8 h).
    static func deliveryDate(now: Date, quietStart: Int, quietEnd: Int, calendar: Calendar = .current) -> Date? {
        guard quietStart != quietEnd else { return nil }
        let hour = calendar.component(.hour, from: now)
        let inside = quietStart < quietEnd
            ? (hour >= quietStart && hour < quietEnd)
            : (hour >= quietStart || hour < quietEnd)
        guard inside else { return nil }
        let today = calendar.date(bySettingHour: quietEnd, minute: 0, second: 0, of: now) ?? now
        return today > now ? today : calendar.date(byAdding: .day, value: 1, to: today)
    }
}
