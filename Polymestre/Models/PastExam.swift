import Foundation
import SwiftData

/// Un sujet d'examen passé : l'annale.
///
/// L'app connaissait les évaluations **à venir** — date, pondération, rappel. Elle
/// ignorait les sujets déjà tombés, qui sont pourtant la matière première de toute
/// révision sérieuse. Ce sont deux choses différentes : une évaluation se prépare,
/// une annale se travaille.
///
/// Pas de note : l'app ne suit pas les résultats. Ce qui est consigné, c'est
/// **quand** le sujet a été travaillé, avec quelle sureté, et ce qu'on en retient.
@Model
final class PastExam {
    var id: UUID = UUID()
    var course: Course?
    var title: String = ""
    /// Année de la session.
    var year: Int = 0
    /// `ExamKind.rawValue` — examen, midterm, quiz…
    var kindRaw: String = ""
    var urlString: String = ""
    var solutionURLString: String = ""
    /// `ConfidenceLevel.rawValue` — vert / orange / rouge, comme partout ailleurs.
    var confidenceRaw: String?
    /// Date à laquelle le sujet a été travaillé. `nil` = pas encore fait.
    var workedAt: Date?
    var notes: String = ""
    var addedAt: Date = Date.now

    init(id: UUID = UUID(),
         course: Course? = nil,
         title: String = "",
         year: Int = Calendar.current.component(.year, from: Date()),
         kind: ExamKind = .exam,
         urlString: String = "",
         solutionURLString: String = "",
         confidence: ConfidenceLevel? = nil,
         workedAt: Date? = nil,
         notes: String = "") {
        self.id = id
        self.course = course
        self.title = title.isEmpty ? "\(kind.label) \(year)" : title
        self.year = year
        self.kindRaw = kind.rawValue
        self.urlString = urlString
        self.solutionURLString = solutionURLString
        self.confidenceRaw = confidence?.rawValue
        self.workedAt = workedAt
        self.notes = notes
        self.addedAt = Date()
    }

    var kind: ExamKind {
        get { ExamKind(rawValue: kindRaw) ?? .exam }
        set { kindRaw = newValue.rawValue }
    }

    var confidence: ConfidenceLevel? {
        get { confidenceRaw.flatMap(ConfidenceLevel.init(rawValue:)) }
        set { confidenceRaw = newValue?.rawValue }
    }

    var isWorked: Bool { workedAt != nil }

    /// Raccourci pour ouvrir le sujet, s'il y en a un.
    var url: URL? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed)
    }

    var solutionURL: URL? {
        let trimmed = solutionURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed)
    }

    /// « Travaillé le 12 mars · vert ».
    var statusLabel: String {
        guard let workedAt else { return String(localized: "Pas encore travaillé") }
        var parts = [String(localized: "Travaillé le \(DateUtils.shortDay.string(from: workedAt))")]
        if let confidence { parts.append(confidence.label) }
        return parts.joined(separator: " · ")
    }
}

/// Ce que les annales d'un cours disent de la préparation.
///
/// Fonction **pure** sur des valeurs : la règle « reste-t-il des sujets à
/// travailler, et lesquels » se teste sans base.
enum PastExamProgress {

    struct Summary: Equatable {
        var total: Int
        var worked: Int
        /// Les sujets jamais travaillés, du plus récent au plus ancien.
        var pendingYears: [Int]

        var isComplete: Bool { total > 0 && worked == total }
        var ratio: Double { total == 0 ? 0 : Double(worked) / Double(total) }

        var label: String {
            guard total > 0 else { return String(localized: "Aucune annale") }
            if isComplete { return String(localized: "\(total)/\(total) travaillées") }
            return String(localized: "\(worked)/\(total) travaillées")
        }
    }

    /// Le bilan, à partir des couples (année, travaillée).
    ///
    /// On passe des valeurs et non des modèles : le calcul se teste alors sans
    /// SwiftData, et l'écran comme le test s'appuient sur la même vérité.
    static func summary(_ entries: [(year: Int, worked: Bool)]) -> Summary {
        let worked = entries.filter(\.worked).count
        let pending = entries.filter { !$0.worked }.map(\.year).sorted(by: >)
        return Summary(total: entries.count, worked: worked, pendingYears: pending)
    }

    /// Les sujets à travailler en priorité : les plus **récents** d'abord.
    ///
    /// Le programme change peu d'une année à l'autre, mais il change : un sujet de
    /// l'an dernier ressemble davantage à celui qui tombera qu'un sujet de 2019.
    static func priority(_ entries: [(year: Int, worked: Bool)], limit: Int = 3) -> [Int] {
        Array(entries.filter { !$0.worked }.map(\.year).sorted(by: >).prefix(limit))
    }
}
