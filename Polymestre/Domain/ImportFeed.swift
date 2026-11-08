import Foundation

/// Ce que l'import fait de chaque cours, **élément par élément** — ce que
/// l'accueil montre pendant qu'il travaille.
///
/// Trois moments, tous réels :
///   1. le **plan** : les sections du cours Moodle et leurs activités, avec leur
///      vrai nom (« Série 3 — énoncé », « Vidéos du chapitre 2 ») ;
///   2. l'**ouverture** : chaque activité ouverte dit ce qu'elle cachait
///      (« PDF », « Dossier · 12 PDF », « Vidéo », « Devoir ») ;
///   3. le **rangement** : ce que l'app en a compris — une série, une vidéo, une
///      échéance — posé dans sa semaine.
///
/// Pur : l'écran l'observe, la validation le teste (`validate.sh`).
struct ImportFeed: Equatable {

    struct Course: Equatable, Identifiable {
        let id: String
        var code: String
        var name: String
        var colorHex: String
        var stage: ImportProgress.Stage = .waiting
        var sections: [Section] = []
        var placed: [Placed] = []
        /// Combien d'activités l'import ouvre vraiment (plafonné : `MoodleClient.openLimit`).
        var openTotal: Int?
        /// Les autres sources lues, dans l'ordre (« MOOC », « MediaSpace »…), et celle en cours.
        var sourcesRead: [String] = []
        var currentSource: String?

        var activities: [Activity] { sections.flatMap(\.activities) }
        var openedCount: Int { activities.filter(\.isOpened).count }
        /// Les activités que l'import ouvre (les autres — forums, étiquettes — se lisent dans le plan).
        var openableCount: Int { openTotal ?? activities.filter(\.isOpenable).count }

        func placed(inWeek week: Int) -> [Placed] { placed.filter { $0.week == week } }
    }

    struct Section: Equatable, Identifiable {
        let id: Int
        var title: String
        var activities: [Activity]
    }

    struct Activity: Equatable, Identifiable {
        let id: String
        var name: String
        var module: String
        /// Ce que l'activité s'est révélée être une fois ouverte ; `nil` avant.
        var revealed: String?

        var isOpened: Bool { revealed != nil }
        var isOpenable: Bool { ImportFeed.openedModules.contains(module) }

        /// L'icône de l'activité telle que Moodle la présente.
        var icon: String {
            switch module {
            case "resource": return "doc"
            case "url": return "link"
            case "assign": return "tray.and.arrow.up"
            case "page": return "doc.plaintext"
            case "folder": return "folder"
            case "forum": return "bubble.left.and.bubble.right"
            case "quiz": return "checklist"
            default: return "square.dashed"
            }
        }
    }

    /// Un élément compris et rangé.
    struct Placed: Equatable, Identifiable {
        enum Kind: String { case video, theory, series, deadline }
        let id: String
        var kind: Kind
        var title: String
        var week: Int
        /// « 2 vidéos », « 12 oct. »…
        var detail: String?

        var icon: String {
            switch kind {
            case .video: return "play.rectangle.fill"
            case .theory: return "book.closed.fill"
            case .series: return "doc.text.fill"
            case .deadline: return "flag.fill"
            }
        }

        var kindLabel: String {
            switch kind {
            case .video: return String(localized: "Vidéo")
            case .theory: return String(localized: "Théorie")
            case .series: return String(localized: "Série")
            case .deadline: return String(localized: "Échéance")
            }
        }
    }

    /// Les modules que l'import ouvre (`CourseSiteClients.snapshot`).
    static let openedModules: Set<String> = ["url", "assign", "resource", "page", "folder"]
    /// Les modules qui ne disent rien du travail à faire : absents du plan montré.
    static let hiddenModules: Set<String> = ["label", "subsection", "qbank"]

    private(set) var courses: [Course] = []
    var currentID: String?

    var current: Course? { courses.first { $0.id == currentID } }

    // MARK: Écriture

    mutating func reset(_ list: [(id: String, code: String, name: String, colorHex: String)]) {
        courses = list.map { Course(id: $0.id, code: $0.code, name: $0.name, colorHex: $0.colorHex) }
        currentID = nil
    }

    mutating func remove(_ id: String) {
        courses.removeAll { $0.id == id }
    }

    mutating func setStage(_ stage: ImportProgress.Stage, course id: String) {
        update(id) { if stage > $0.stage { $0.stage = stage } }
    }

    /// Le plan du cours, tel que Moodle le donne.
    mutating func outline(_ sections: [MoodleSection], course id: String) {
        update(id) { course in
            course.sections = sections.compactMap { section in
                let activities = section.activities
                    .filter { $0.isVisible && !ImportFeed.hiddenModules.contains($0.module) }
                    .map { Activity(id: $0.id, name: TextRepair.clean($0.name), module: $0.module) }
                guard !activities.isEmpty else { return nil }
                let title = TextRepair.clean(section.title)
                return Section(id: section.number,
                               title: title.isEmpty ? "Section \(section.number)" : title,
                               activities: activities)
            }
        }
    }

    mutating func setOpenTotal(_ total: Int, course id: String) {
        update(id) { $0.openTotal = total }
    }

    /// Un message de la chaîne d'import (« vidéos MediaSpace… ») : la source
    /// en cours de lecture.
    mutating func note(_ message: String, course id: String) {
        guard let source = ImportFeed.source(ofMessage: message) else { return }
        update(id) { course in
            if !course.sourcesRead.contains(source) { course.sourcesRead.append(source) }
            course.currentSource = source
        }
    }

    static func source(ofMessage message: String) -> String? {
        let text = message.lowercased()
        if text.contains("botafogo") || text.contains("site du cours") { return "Botafogo" }
        if text.contains("mooc") || text.contains("courseware") { return "MOOC" }
        if text.contains("mediaspace") { return "MediaSpace" }
        if text.contains("explique") { return "Explique" }
        if text.contains("plan du cours") { return "Plan du cours" }
        return nil
    }

    /// Un lot d'activités ouvertes : `[id d'activité: ce qu'elle était]`.
    mutating func opened(_ labels: [String: String], course id: String) {
        update(id) { course in
            for s in course.sections.indices {
                for a in course.sections[s].activities.indices {
                    if let label = labels[course.sections[s].activities[a].id] {
                        course.sections[s].activities[a].revealed = label
                    }
                }
            }
        }
    }

    /// Ce que l'analyse a compris, rangé par semaine.
    mutating func place(_ draft: ContentDraft, course id: String) {
        var placed: [Placed] = []
        for section in draft.sections where section.isIncluded {
            for item in section.items {
                let week = item.plannedWeek(in: section)
                guard week > 0 else { continue }
                let kind: Placed.Kind
                var detail: String?
                switch item.kind {
                case .theory:
                    kind = item.videoCount > 0 ? .video : .theory
                    if item.videoCount > 1 { detail = String(localized: "\(item.videoCount) vidéos") }
                case .series:
                    kind = .series
                    if !item.exercises.isEmpty { detail = String(localized: "\(item.exercises.count) exercices") }
                case .deadline:
                    kind = .deadline
                    detail = item.date.map(ImportFeed.shortDate)
                default:
                    continue
                }
                placed.append(Placed(id: item.id.uuidString, kind: kind,
                                     title: ImportFeed.title(of: item, kind: kind),
                                     week: week, detail: detail))
            }
        }
        update(id) { $0.placed = placed.sorted { ($0.week, $0.kind.order) < ($1.week, $1.kind.order) } }
    }

    private mutating func update(_ id: String, _ change: (inout Course) -> Void) {
        guard let index = courses.firstIndex(where: { $0.id == id }) else { return }
        change(&courses[index])
    }

    // MARK: Lecture

    /// Une semaine, tous cours confondus (l'écran de fin).
    func week(_ week: Int) -> [(course: Course, items: [Placed])] {
        courses.compactMap { course in
            let items = course.placed(inWeek: week)
            return items.isEmpty ? nil : (course, items)
        }
    }

    var totals: (series: Int, videos: Int, theory: Int, deadlines: Int) {
        let all = courses.flatMap(\.placed)
        return (all.filter { $0.kind == .series }.count,
                all.filter { $0.kind == .video }.count,
                all.filter { $0.kind == .theory }.count,
                all.filter { $0.kind == .deadline }.count)
    }

    // MARK: Textes

    /// Le titre court d'un élément : « Série 3 », sinon son titre nettoyé.
    static func title(of item: ContentDraftItem, kind: Placed.Kind) -> String {
        let plain = MathMarkup.plain(TextRepair.clean(item.title)).trimmingCharacters(in: .whitespacesAndNewlines)
        if kind == .series, let number = item.seriesNumber,
           plain.isEmpty || !plain.localizedCaseInsensitiveContains("\(number)") {
            return String(localized: "Série \(number)")
        }
        if !plain.isEmpty { return plain }
        switch kind {
        case .series: return String(localized: "Série")
        case .video: return String(localized: "Vidéos")
        case .theory: return String(localized: "Théorie")
        case .deadline: return String(localized: "Échéance")
        }
    }

    /// « PDF », « Dossier · 12 PDF », « Vidéo », « Devoir »… : ce qu'il y avait
    /// derrière une activité, d'après ce que sa page a donné à l'ouverture.
    static func openedLabel(_ found: [String: Any]) -> String {
        if let dates = found["dates"] as? String, !dates.isEmpty { return "Devoir" }
        let files = (found["files"] as? [Any])?.count ?? 0
        if files > 1 { return "Dossier · \(files) PDF" }
        let target = ((found["target"] as? String) ?? "").lowercased()
        if ["mediaspace", "kaltura", "youtu", "switch.tube", "tube.switch"].contains(where: target.contains) {
            return String(localized: "Vidéo")
        }
        if target.contains("courseware") { return "MOOC" }
        switch found["kind"] as? String {
        case "pdf"?: return "PDF"
        case "dossier"?: return "Dossier"
        case "fichier"?: return String(localized: "Fichier")
        default: return target.isEmpty ? "Page" : "Lien"
        }
    }

    static func shortDate(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).locale(DateUtils.appLocale))
    }
}

private extension ImportFeed.Placed.Kind {
    var order: Int {
        switch self {
        case .video: return 0
        case .theory: return 1
        case .series: return 2
        case .deadline: return 3
        }
    }
}
