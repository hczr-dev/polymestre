import Foundation

/// Ce que le chrono propose dans « Sur » : d'abord ce qui reste à faire.
///
/// Le sélecteur listait tous les exercices du cours par ordre alphabétique de
/// numéro — « Exercice 1.1 » en tête en semaine 5, alors qu'il est fait depuis
/// un mois. On travaille presque toujours sur **le prochain** exercice : il
/// vient en premier, le reste derrière, sous « Déjà faits ».
enum FocusTargets {

    struct Ordered {
        /// À faire, dans l'ordre où on les ferait.
        var upNext: [Exercise]
        /// Faits (ou corrigés) : encore choisissables, mais après.
        var done: [Exercise]
    }

    /// Les exercices d'un cours, rangés pour un travail donné.
    ///
    /// - Séries : la série la plus pressée d'abord (échéance, puis semaine
    ///   prévue, puis numéro) ; dans une série, l'ordre du polycopié, bonus en
    ///   dernier. Un exercice « à refaire » est à faire.
    /// - Correction : ce qui attend une correction, puis ce qui est à refaire.
    static func exercises(of series: [ExerciseSeries], for taskType: TaskType, now: Date = Date()) -> Ordered {
        let ordered = series
            .filter { !$0.exercises.isEmpty }
            .sorted { lhs, rhs in
                let left = urgency(lhs, now: now), right = urgency(rhs, now: now)
                if left != right { return left.lexicographicallyPrecedes(right) }
                return lhs.seriesNumber < rhs.seriesNumber
            }
            .flatMap { series in
                series.exercises.sorted { lhs, rhs in
                    if lhs.isBonus != rhs.isBonus { return !lhs.isBonus }
                    return lhs.sortOrder < rhs.sortOrder
                }
            }
        let isPending: (Exercise) -> Bool
        switch taskType.canonical {
        case .correction:
            isPending = { exercise in
                let stage = ExerciseStage(exercise)
                return stage == .toCorrect || stage == .redo
            }
        default:
            isPending = { exercise in !ExerciseStage(exercise).isDone }
        }
        var upNext = ordered.filter(isPending)
        if taskType.canonical == .correction {
            // Corriger avant de refaire.
            upNext = upNext.filter { ExerciseStage($0) == .toCorrect } + upNext.filter { ExerciseStage($0) == .redo }
        }
        let pendingIDs = Set(upNext.map(\.id))
        return Ordered(upNext: upNext, done: ordered.filter { !pendingIDs.contains($0.id) })
    }

    /// Plus petit = plus pressé : une série commencée, puis l'échéance la plus
    /// proche, puis la semaine prévue la plus ancienne. Une série finie passe
    /// derrière.
    private static func urgency(_ series: ExerciseSeries, now: Date) -> [Double] {
        let required = series.requiredExercises
        let finished = !required.isEmpty && required.allSatisfy { ExerciseStage($0).isDone }
        let started = series.exercises.contains { exercise in
            exercise.isDone || exercise.subQuestionDoneCount > 0
        }
        let due = series.dueDate.map { $0.timeIntervalSince(now) } ?? .greatestFiniteMagnitude
        let week = series.plannedWeek > 0 ? Double(series.plannedWeek) : 99
        return [finished ? 1 : 0, started && !finished ? 0 : 1, week, due]
    }

    /// Les éléments de théorie, pas vus d'abord.
    static func theory(_ items: [TheoryItem]) -> (upNext: [TheoryItem], done: [TheoryItem]) {
        (items.filter { !$0.isWatched }, items.filter(\.isWatched))
    }
}

/// Où se trouve chaque exercice dans le PDF de sa série.
///
/// Le chrono montre l'énoncé de l'exercice en cours **tel qu'il est imprimé** :
/// formules, figures, tableaux — tout ce qu'un texte extrait perd. La lecture
/// de la mise en page (`SeriesLayoutParser`) sait déjà où commence chaque
/// exercice ; un exercice s'étend jusqu'au début du suivant, éventuellement
/// sur plusieurs pages.
enum ExerciseRegions {

    /// Une bande de page : de `top` à `bottom` (0 = haut de page, 1 = bas).
    struct Slice: Equatable {
        var page: Int
        var top: Double
        var bottom: Double
    }

    /// Le début d'un exercice : son numéro, sa page, sa position.
    struct Heading: Equatable {
        var number: String
        var page: Int
        var top: Double
    }

    /// La marge gardée au-dessus d'un titre : `top` est le **milieu** de sa
    /// ligne, et le titre ne doit pas être coupé.
    static let headingMargin = 0.02
    /// Où s'arrête un exercice : juste au-dessus du titre suivant — assez près
    /// pour ne pas rogner la dernière ligne de l'énoncé, assez loin pour ne pas
    /// montrer le haut du titre suivant.
    static let endMargin = 0.011
    /// Le haut d'une page (en-tête, numéro) : une suite d'énoncé qui n'en
    /// dépasse pas n'est que l'en-tête, et n'est pas montrée.
    static let pageHeader = 0.15

    /// Les bandes de chaque exercice, indexées par numéro **court** (« 3 »
    /// pour « 4.3 », « Ex-02-03 » → « 3 ») : c'est ce qui relie le PDF aux
    /// exercices enregistrés, dont la numérotation de série peut différer.
    static func slices(for headings: [Heading], pageCount: Int) -> [String: [Slice]] {
        let sorted = headings.sorted { ($0.page, $0.top) < ($1.page, $1.top) }
        var result: [String: [Slice]] = [:]
        for (index, heading) in sorted.enumerated() {
            let start = (page: heading.page, top: max(0, heading.top - headingMargin))
            let end: (page: Int, top: Double) = index + 1 < sorted.count
                ? (sorted[index + 1].page, max(0, sorted[index + 1].top - endMargin))
                : (max(heading.page, pageCount - 1), 1)
            var slices: [Slice] = []
            for page in start.page...max(start.page, end.page) {
                let top = page == start.page ? start.top : 0
                let bottom = page == end.page ? end.top : 1
                // Une bande vide, ou réduite à l'en-tête de la page suivante
                // (le suivant commence en haut de page), n'est pas montrée.
                let headerOnly = page != start.page && bottom < pageHeader
                if bottom - top > 0.02, !headerOnly { slices.append(Slice(page: page, top: top, bottom: bottom)) }
            }
            let key = shortNumber(heading.number)
            if result[key] == nil, !slices.isEmpty { result[key] = slices }
        }
        return result
    }

    /// « 4.3 » → « 3 », « 3b » → « 3b », « Ex-02-03 » → « 3 ».
    static func shortNumber(_ number: String) -> String {
        let last = number.split(whereSeparator: { $0 == "." || $0 == "-" }).last.map(String.init) ?? number
        let trimmed = last.drop { $0 == "0" }
        return trimmed.isEmpty ? last : String(trimmed)
    }
}

/// Ce que l'horaire dit du moment : sur quoi le chrono s'ouvre.
///
/// Ouvrir le chrono pendant la séance d'exercices d'Analyse proposait « Sans
/// cours · Séries », à régler à la main à chaque fois. L'app connaît
/// l'horaire : pendant une séance d'exercices (ou juste avant), elle propose
/// ce cours et son prochain exercice ; juste après un cours en amphi, sa
/// théorie. Une proposition seulement — rien ne démarre tout seul.
enum FocusContext {

    struct Slot: Equatable {
        var courseID: UUID
        var courseCode: String
        var kind: CalendarEventKind
        var start: Date
        var end: Date
    }

    struct Suggestion: Equatable {
        var courseID: UUID
        var taskType: TaskType
        /// « Séance d'exercices de MATH-101 en cours » : dit pourquoi.
        var reason: String
    }

    /// Avant une séance d'exercices, on la prépare.
    static let leadTime: TimeInterval = 45 * 60
    /// Après un cours, on le relit.
    static let afterLecture: TimeInterval = 2 * 3600

    static func suggestion(now: Date, slots: [Slot]) -> Suggestion? {
        let exercises = slots.filter { $0.kind == .exerciseSession }
        if let current = exercises.first(where: { $0.start.addingTimeInterval(-10 * 60) <= now && now < $0.end }) {
            return Suggestion(courseID: current.courseID, taskType: .exercise,
                              reason: String(localized: "Séance d'exercices de \(current.courseCode) en cours"))
        }
        if let next = exercises.filter({ $0.start > now && $0.start.timeIntervalSince(now) <= leadTime }).min(by: { $0.start < $1.start }) {
            return Suggestion(courseID: next.courseID, taskType: .exercise,
                              reason: String(localized: "Séance d'exercices de \(next.courseCode) à \(DateUtils.time.string(from: next.start))"))
        }
        let lectures = slots.filter { $0.kind == .lecture && $0.end <= now && now.timeIntervalSince($0.end) <= afterLecture }
        if let last = lectures.max(by: { $0.end < $1.end }) {
            return Suggestion(courseID: last.courseID, taskType: .theory,
                              reason: String(localized: "Juste après le cours de \(last.courseCode)"))
        }
        return nil
    }
}
