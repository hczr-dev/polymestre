import Foundation
import SwiftData

// MARK: - Ce que Claude rapporte d'une série

/// Ce que Claude rapporte d'une série, lu dans le bloc ```polymestre qui
/// termine sa réponse : les corrections (vert / orange / rouge), les erreurs
/// du carnet, les exercices admis dans la file de reprise, et les indices
/// donnés pendant la résolution. Rien n'est noté sans que l'étudiant·e le
/// confirme — sauf les indices, un simple journal.
///
/// Le format est fait pour être écrit par Claude et relu sans ambiguïté, une
/// ligne par fait :
///
/// ```polymestre
/// 2 : faux
/// erreur 2 | méthode | oubli de vérifier la continuité en 0 | vérifier f continue en 0 avant le TAF | continuité
/// reprise 2 | méthode : n'a pas vu le critère | Pose M_n = sup |f_n(x)|
/// indice 3 | 2 | Le critère de Weierstrass s'applique : vérifie la majoration
/// ```
///
/// Pur, testé dans `validate.sh`.
enum SeriesReview {

    enum MistakeKind: String, CaseIterable, Identifiable, Codable {
        case calculation, method, understanding, slip, gap, time, reading
        var id: String { rawValue }

        var label: String {
            switch self {
            case .calculation: return String(localized: "Calcul")
            case .method: return String(localized: "Méthode")
            case .understanding: return String(localized: "Compréhension")
            case .slip: return String(localized: "Étourderie")
            case .gap: return String(localized: "Lacune de cours")
            case .time: return String(localized: "Gestion du temps")
            case .reading: return String(localized: "Lecture de l'énoncé")
            }
        }

        var icon: String {
            switch self {
            case .calculation: return "plus.forwardslash.minus"
            case .method: return "point.topleft.down.to.point.bottomright.curvepath"
            case .understanding: return "brain"
            case .slip: return "exclamationmark.triangle"
            case .gap: return "book.closed"
            case .time: return "timer"
            case .reading: return "text.magnifyingglass"
            }
        }

        /// Les erreurs qui récidivent : elles seules entrent en file de reprise.
        var recurs: Bool { self == .method || self == .gap }

        /// « méthode », « Lacune de cours », « étourderie »… → le genre.
        static func parse(_ word: String) -> MistakeKind? {
            let key = word.lowercased().folding(options: .diacriticInsensitive, locale: nil).trimmingCharacters(in: .whitespaces)
            if key.hasPrefix("calcul") { return .calculation }
            if key.hasPrefix("method") || key.hasPrefix("methode") { return .method }
            if key.hasPrefix("compreh") { return .understanding }
            if key.hasPrefix("etourd") || key.hasPrefix("inatten") { return .slip }
            if key.hasPrefix("lacune") || key.contains("cours") { return .gap }
            if key.contains("temps") || key.hasPrefix("time") { return .time }
            if key.hasPrefix("lecture") || key.contains("enonce") { return .reading }
            return nil
        }
    }

    /// Une erreur rapportée (pas encore notée : `Mistake` est la ligne du carnet).
    struct MistakeNote: Equatable {
        var exercise: String
        var kind: MistakeKind
        /// Précis : « oubli de vérifier l'hypothèse de continuité en 0 ».
        var summary: String
        /// La bonne démarche, en une ou deux phrases.
        var correction: String = ""
        /// La notion en jeu.
        var notion: String = ""
    }

    /// Un exercice admis en file de reprise.
    struct Admission: Equatable {
        var exercise: String
        /// Le type d'erreur et ce qui a coincé, en une phrase.
        var why: String
        /// Le premier geste — jamais la solution. Montré seulement après une
        /// tentative, en reprise.
        var firstMove: String
    }

    /// Un indice donné pendant la résolution.
    struct Hint: Equatable {
        var exercise: String
        /// 1 orientation · 2 outil · 3 amorce · 4 solution.
        var level: Int
        var text: String
    }

    struct Report: Equatable {
        var verdicts: [ClaudeTutor.Verdict] = []
        var mistakes: [MistakeNote] = []
        var admissions: [Admission] = []
        var hints: [Hint] = []

        var isEmpty: Bool { verdicts.isEmpty && mistakes.isEmpty && admissions.isEmpty && hints.isEmpty }
        /// Ce qui demande une confirmation (les indices s'écrivent seuls).
        var needsConfirmation: Bool { !verdicts.isEmpty || !mistakes.isEmpty || !admissions.isEmpty }
    }

    /// Tous les blocs ```polymestre d'une réponse, lus ligne à ligne.
    static func parse(_ original: String) -> Report {
        let text = ClaudeTutor.currentFences(original)
        var report = Report()
        for block in blocks(in: text) {
            for raw in block.components(separatedBy: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty else { continue }
                let lower = line.lowercased().folding(options: .diacriticInsensitive, locale: nil)
                if lower.hasPrefix("erreur") {
                    let fields = pipeFields(line, dropping: "erreur", limit: 5)
                    guard fields.count >= 3, let kind = MistakeKind.parse(fields[1]), !fields[0].isEmpty, !fields[2].isEmpty else { continue }
                    report.mistakes.append(MistakeNote(exercise: fields[0], kind: kind, summary: fields[2],
                                                   correction: fields.count > 3 ? fields[3] : "",
                                                   notion: fields.count > 4 ? fields[4] : ""))
                } else if lower.hasPrefix("reprise") {
                    let fields = pipeFields(line, dropping: "reprise", limit: 3)
                    guard fields.count >= 2, !fields[0].isEmpty else { continue }
                    // L'amorce est le dernier champ : elle peut contenir « | » (une valeur absolue).
                    report.admissions.append(Admission(exercise: fields[0], why: fields[1],
                                                       firstMove: fields.count > 2 ? fields[2] : ""))
                } else if lower.hasPrefix("indice") {
                    let fields = pipeFields(line, dropping: "indice", limit: 3)
                    guard fields.count >= 3, !fields[0].isEmpty, let level = Int(fields[1].filter(\.isNumber)) else { continue }
                    report.hints.append(Hint(exercise: fields[0], level: min(4, max(1, level)),
                                             text: fields[2]))
                } else if let hint = bareHint(line) {
                    // « 6.3 | 1 | … » : Claude oublie souvent le mot « indice » (vu en vrai).
                    report.hints.append(hint)
                } else if let verdict = ClaudeTutor.verdicts(in: "```\(ClaudeTutor.verdictFence)\n\(line)\n```").first {
                    report.verdicts.append(verdict)
                }
            }
        }
        return report
    }

    /// Un indice écrit sans son mot-clé : « numéro | niveau 1 à 4 | texte ».
    static func bareHint(_ line: String) -> Hint? {
        let fields = line.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard fields.count == 3, !fields[2].isEmpty, fields[0].first?.isNumber == true,
              fields[0].allSatisfy({ $0.isNumber || $0 == "." || $0 == "-" }),
              let level = Int(fields[1]), (1...4).contains(level) else { return nil }
        return Hint(exercise: fields[0], level: level, text: fields[2])
    }

    /// La réponse sans ses blocs (ils s'affichent en carte à part).
    static func withoutBlocks(_ text: String) -> String {
        var copy = ClaudeTutor.currentFences(text)
        while let open = copy.range(of: "```" + ClaudeTutor.verdictFence) {
            let end = copy.range(of: "```", range: open.upperBound..<copy.endIndex)
            copy.removeSubrange(open.lowerBound..<(end?.upperBound ?? copy.endIndex))
        }
        return copy.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func blocks(in text: String) -> [String] {
        var found: [String] = []
        var rest = Substring(text)
        while let open = rest.range(of: "```" + ClaudeTutor.verdictFence) {
            let after = rest[open.upperBound...]
            let end = after.range(of: "```")
            found.append(String(after[..<(end?.lowerBound ?? after.endIndex)]))
            rest = end.map { after[$0.upperBound...] } ?? ""
        }
        return found
    }

    /// « erreur 2 | méthode | … » → ["2", "méthode", …] ; « Ex. 2 », « exercice 2 » → « 2 ».
    /// Au plus `limit` champs : le dernier garde ses « | » (une valeur absolue dans une amorce).
    private static func pipeFields(_ line: String, dropping keyword: String, limit: Int) -> [String] {
        var body = String(line.dropFirst(keyword.count)).trimmingCharacters(in: CharacterSet(charactersIn: " :"))
        for prefix in ["exercice", "ex.", "ex"] where body.lowercased().hasPrefix(prefix) {
            body = String(body.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        return body.split(separator: "|", maxSplits: limit - 1, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: Les consignes

    /// Le format, tel qu'on le décrit à Claude — selon ce qui est allumé.
    static func instruction(features: Features) -> String {
        var lines = ["Termine par un bloc de code ```\(ClaudeTutor.verdictFence), une ligne par fait :",
                     "- « numéro : juste », « numéro : moyen » ou « numéro : faux » pour chaque exercice corrigé ;"]
        if features.mistakes {
            lines.append("- « erreur numéro | type | résumé précis | la bonne démarche en une phrase | notion » pour chaque écart, même une étourderie ; type parmi calcul, méthode, compréhension, étourderie, lacune de cours, gestion du temps, lecture de l'énoncé ;")
        }
        if features.redo {
            lines.append("- « reprise numéro | type d'erreur et ce qui a coincé | le premier geste (jamais la solution) » pour les exercices à refaire sur papier : seulement des erreurs de méthode ou des lacunes de cours, que l'étudiant·e ne saurait pas refaire sans ses notes, \(features.redoPerSeries) au plus pour la série.")
        }
        lines.append("Polymestre le propose à l'étudiant·e, qui confirme avant que rien ne soit noté.")
        return lines.joined(separator: "\n")
    }

    /// La consigne des indices, pendant la résolution.
    static let hintInstruction = """
    Quand tu donnes un indice sur un exercice, ajoute à la fin de ta réponse un bloc ```\(ClaudeTutor.verdictFence) \
    d'une ligne, **avec le mot « indice »** : « indice 6.3 | 2 | l'indice en une phrase », niveau 1 (orientation), \
    2 (outil), 3 (amorce) ou 4 (solution). Polymestre le note pour la reprise et le post-mortem.
    """

    /// Ce qui est allumé (réglages de l'app, et `polymestre.json` du projet).
    struct Features: Equatable {
        var mistakes = true
        var redo = true
        var hints = true
        var redoPerSeries = 2
    }
}

// MARK: - La file de reprise

/// Refaire sur papier, à intervalles : J+7 → J+21 → avant l'examen, par
/// défaut ; trois passes. Réussi sans notes à n'importe quelle passe : sorti.
/// Raté : la même passe, une semaine plus tard ; deux échecs de suite, c'est
/// une lacune de cours (on le dit). Le projet de l'étudiant·e peut changer
/// les paliers et les plafonds (`polymestre.json` › `redo`). Pur, testé.
enum RedoLadder {

    enum Step: Equatable, Codable {
        case days(Int)
        /// Avant l'examen du cours.
        case exam

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let days = try? container.decode(Int.self) { self = .days(days) } else { self = .exam }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .days(let days): try container.encode(days)
            case .exam: try container.encode("exam")
            }
        }

        var label: String {
            switch self {
            case .days(let days): return "J+\(days)"
            case .exam: return String(localized: "Pré-examen")
            }
        }
    }

    struct Config: Equatable, Codable {
        var steps: [Step] = [.days(7), .days(21), .exam]
        /// Au plus, par série (l'admission est stricte, sinon la file meurt).
        var maxPerSeries = 2
        /// Au-delà, on le dit : l'admission a été trop large.
        var maxActive = 10
        /// Combien d'exercices par séance de reprise.
        var perSession = 3

        enum CodingKeys: String, CodingKey { case steps, maxPerSeries, maxActive, perSession }

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            steps = (try? container.decode([Step].self, forKey: .steps)).flatMap { $0.isEmpty ? nil : $0 } ?? Config().steps
            maxPerSeries = (try? container.decode(Int.self, forKey: .maxPerSeries)) ?? 2
            maxActive = (try? container.decode(Int.self, forKey: .maxActive)) ?? 10
            perSession = (try? container.decode(Int.self, forKey: .perSession)) ?? 3
        }
    }

    /// Le résultat d'une reprise sur papier.
    enum Result: String, Codable, CaseIterable {
        /// Refait seul, sans notes : sort de la file.
        case cleared
        /// Refait, avec un coup de pouce : passe au palier suivant.
        case passed
        /// Pas refait : même palier, une semaine plus tard.
        case failed

        var label: String {
            switch self {
            case .cleared: return String(localized: "Réussi sans notes")
            case .passed: return String(localized: "Réussi avec aide")
            case .failed: return String(localized: "Raté")
            }
        }
    }

    /// Quand refaire, à une passe donnée. `exam` : quelques jours avant
    /// l'examen du cours (sans date d'examen : pas de date).
    static func due(step: Step, from: Date, examDate: Date?, calendar: Calendar = .current) -> Date? {
        switch step {
        case .days(let days):
            return calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: from))
        case .exam:
            guard let examDate else { return nil }
            return calendar.date(byAdding: .day, value: -5, to: calendar.startOfDay(for: examDate))
        }
    }

    struct Outcome: Equatable {
        /// `nil` : sorti de la file.
        var pass: Int?
        var due: Date?
        var failures: Int
        /// Deux échecs de suite : une lacune de cours, pas un manque d'entraînement.
        var gap: Bool
    }

    /// Après une reprise : le palier suivant et sa date.
    static func after(_ result: Result, pass: Int, failures: Int, config: Config, now: Date, examDate: Date?,
                      calendar: Calendar = .current) -> Outcome {
        switch result {
        case .cleared:
            return Outcome(pass: nil, due: nil, failures: 0, gap: false)
        case .passed:
            let next = pass + 1
            guard config.steps.indices.contains(next) else { return Outcome(pass: nil, due: nil, failures: 0, gap: false) }
            return Outcome(pass: next, due: due(step: config.steps[next], from: now, examDate: examDate, calendar: calendar), failures: 0, gap: false)
        case .failed:
            let count = failures + 1
            return Outcome(pass: pass, due: calendar.date(byAdding: .day, value: 7, to: calendar.startOfDay(for: now)), failures: count, gap: count >= 2)
        }
    }

    /// Ce qu'on peut admettre d'une série : les admissions proposées, dans
    /// l'ordre, sans dépasser le plafond (moins ce qui y est déjà).
    static func admissible(_ proposed: [SeriesReview.Admission], alreadyQueued: Int, config: Config) -> [SeriesReview.Admission] {
        Array(proposed.prefix(max(0, config.maxPerSeries - alreadyQueued)))
    }
}

// MARK: - Noter un rapport

extension SeriesReview {

    /// Ce que noter un rapport a changé, pour le dire.
    struct Applied: Equatable {
        var corrected = 0
        var mistakes = 0
        var queued: [String] = []
        /// Admissions refusées : plafond de la série atteint.
        var overCap: [String] = []
        var unmatched: [String] = []

        var summary: String {
            var parts: [String] = []
            if corrected > 0 { parts.append(Plural.count(corrected, "\(corrected) correction", "\(corrected) corrections")) }
            if mistakes > 0 { parts.append(Plural.count(mistakes, "\(mistakes) erreur au carnet", "\(mistakes) erreurs au carnet")) }
            if !queued.isEmpty { parts.append(String(localized: "en reprise : \(queued.joined(separator: ", "))")) }
            if !overCap.isEmpty {
                let list = overCap.joined(separator: ", ")
                parts.append(Plural.count(overCap.count, "écarté (plafond) : \(list)", "écartés (plafond) : \(list)"))
            }
            return parts.isEmpty ? String(localized: "Rien de nouveau.") : parts.joined(separator: " · ")
        }
    }

    /// L'exercice que désigne un numéro du rapport.
    static func exercise(_ label: String, in series: ExerciseSeries) -> Exercise? {
        let exercises = series.sortedExercises
        return ClaudeTutor.matchExercise(label, numbers: exercises.map(\.exerciseNumber)).map { exercises[$0] }
    }

    /// Note le rapport confirmé : corrections, erreurs (sans doublon), et les
    /// admissions en reprise dans la limite du plafond.
    @discardableResult
    static func apply(_ report: Report, to series: ExerciseSeries, features: Features, ladder: RedoLadder.Config,
                      examDate: Date?, context: ModelContext?, now: Date = Date()) -> Applied {
        var applied = Applied()
        for verdict in report.verdicts {
            guard let exercise = exercise(verdict.exercise, in: series) else { applied.unmatched.append(verdict.exercise); continue }
            if exercise.correctness != verdict.result || !exercise.isCorrected {
                exercise.correct(verdict.result)
                applied.corrected += 1
            }
        }
        if features.mistakes {
            for mistake in report.mistakes {
                guard let exercise = exercise(mistake.exercise, in: series) else { applied.unmatched.append(mistake.exercise); continue }
                // Le même post-mortem relu (la conversation reprise) ne double pas le carnet.
                guard !exercise.mistakes.contains(where: { $0.summary == mistake.summary }) else { continue }
                let entry = Mistake(exercise: exercise, kind: mistake.kind, summary: mistake.summary, correction: mistake.correction,
                                    notion: mistake.notion, source: "claude", createdAt: now)
                context?.insert(entry)
                exercise.mistakesStore = (exercise.mistakesStore ?? []) + [entry]
                applied.mistakes += 1
            }
        }
        if features.redo {
            var queued = series.exercises.filter(\.isQueuedForRedo).count
            for admission in report.admissions {
                guard let exercise = exercise(admission.exercise, in: series) else { applied.unmatched.append(admission.exercise); continue }
                if exercise.isQueuedForRedo { continue }
                guard queued < min(ladder.maxPerSeries, features.redoPerSeries) else {
                    applied.overCap.append(exercise.exerciseNumber)
                    continue
                }
                exercise.redoPass = 0
                exercise.redoDueAt = ladder.steps.first.flatMap { RedoLadder.due(step: $0, from: now, examDate: examDate) }
                exercise.redoWhy = admission.why
                exercise.redoFirstMove = admission.firstMove
                exercise.redoFailures = 0
                exercise.redoClearedAt = nil
                exercise.redoRequired = true
                queued += 1
                applied.queued.append(exercise.exerciseNumber)
            }
        }
        return applied
    }

    /// Les indices d'une réponse, notés sur leurs exercices (une fois chacun).
    @discardableResult
    static func recordHints(_ hints: [Hint], in series: ExerciseSeries, now: Date = Date()) -> Int {
        var count = 0
        for hint in hints {
            guard let exercise = exercise(hint.exercise, in: series),
                  !exercise.hints.contains(where: { $0.text == hint.text.replacingOccurrences(of: "|", with: "/") }) else { continue }
            exercise.recordHint(level: hint.level, text: hint.text, at: now)
            count += 1
        }
        return count
    }

    /// Une reprise faite : le palier suivant, ou la sortie de la file.
    @discardableResult
    static func recordRedo(_ result: RedoLadder.Result, on exercise: Exercise, ladder: RedoLadder.Config, examDate: Date?,
                           now: Date = Date()) -> RedoLadder.Outcome {
        let outcome = RedoLadder.after(result, pass: exercise.redoPass ?? 0, failures: exercise.redoFailures,
                                       config: ladder, now: now, examDate: examDate)
        exercise.redoLastResultRaw = result.rawValue
        exercise.redoPass = outcome.pass
        exercise.redoDueAt = outcome.due
        exercise.redoFailures = outcome.failures
        if outcome.pass == nil {
            exercise.redoClearedAt = now
            exercise.redoRequired = false
        }
        return outcome
    }

    /// La file de reprise d'un ensemble de cours : ce qui est dû d'abord.
    static func redoQueue(_ courses: [Course]) -> [Exercise] {
        courses.flatMap(\.allExercises).filter(\.isQueuedForRedo).sorted {
            ($0.redoDueAt ?? .distantFuture) < ($1.redoDueAt ?? .distantFuture)
        }
    }
}
