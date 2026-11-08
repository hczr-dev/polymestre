import Foundation

/// Où en est un exercice, en **une** valeur.
///
/// Le code vert / orange / rouge est celui de la **correction** — juste,
/// moyen, faux — et non une « sureté » donnée en cochant : c'est en corrigeant
/// qu'on sait si c'était juste. Le parcours d'un exercice est donc : à faire →
/// questions en cours → fait (à corriger) → corrigé vert, orange ou rouge ;
/// rouge le marque « à refaire », qui prime tant qu'il n'est pas refait.
enum ExerciseStage: Equatable {
    /// Rien de coché.
    case toDo
    /// Des questions cochées, pas toutes.
    case inProgress(done: Int, total: Int)
    /// Fait, pas encore corrigé.
    case toCorrect
    /// Corrigé : vert, orange ou rouge.
    case corrected(Correctness)
    /// À refaire (corrigé rouge, ou marqué à la main).
    case redo

    init(_ exercise: Exercise) {
        if exercise.redoRequired {
            self = .redo
        } else if let correctness = exercise.correctness, exercise.isCorrected, exercise.isDone {
            self = .corrected(correctness)
        } else if exercise.isDone {
            self = .toCorrect
        } else if exercise.hasSubQuestions, exercise.subQuestionDoneCount > 0 {
            self = .inProgress(done: exercise.subQuestionDoneCount, total: exercise.leafSubQuestions.count)
        } else {
            self = .toDo
        }
    }

    /// Reste-t-il quelque chose à faire **sur** l'exercice (le faire, le
    /// corriger ou le refaire) ?
    var isOpen: Bool {
        if case .corrected(let result) = self { return result == .wrong }
        return true
    }

    /// L'exercice est-il fait (au sens de la progression) ?
    var isDone: Bool {
        switch self {
        case .toDo, .inProgress, .redo: return false
        case .toCorrect, .corrected: return true
        }
    }

    /// « à faire », « 2/5 », « à corriger », « juste », « à refaire »…
    var label: String {
        switch self {
        case .toDo: return "à faire"
        case .inProgress(let done, let total): return "\(done)/\(total)"
        case .toCorrect: return "à corriger"
        case .corrected(let correctness): return correctness.shortLabel.lowercased()
        case .redo: return "à refaire"
        }
    }
}

/// Le parcours d'une série, exercice après exercice.
enum ExerciseFlow {

    /// L'exercice où reprendre la série : le premier qui n'est pas fait, dans
    /// l'ordre du polycopié ; à défaut, le premier à refaire, puis un bonus pas
    /// fait, puis le premier à juger ou à corriger. `nil` quand tout est corrigé.
    ///
    /// Les bonus passent après les exercices obligatoires **et** après ce qui
    /// est à refaire : on ne reprend pas une série par son bonus.
    static func resumePoint(in exercises: [Exercise]) -> Exercise? {
        let ordered = exercises.sorted { lhs, rhs in
            if lhs.isBonus != rhs.isBonus { return !lhs.isBonus }
            return lhs.sortOrder < rhs.sortOrder
        }
        let pending = { (exercise: Exercise) in !ExerciseStage(exercise).isDone && !exercise.redoRequired }
        if let open = ordered.first(where: { !$0.isBonus && pending($0) }) { return open }
        if let redo = ordered.first(where: \.redoRequired) { return redo }
        if let bonus = ordered.first(where: pending) { return bonus }
        return ordered.first { ExerciseStage($0).isOpen }
    }

    /// L'exercice qui suit `current` dans l'ordre de la série, en sautant ceux
    /// qui sont déjà faits — ce que « Suivant » propose une fois l'exercice fini.
    /// À défaut, simplement le suivant ; `nil` en fin de série.
    static func next(after current: Exercise, in exercises: [Exercise]) -> Exercise? {
        let ordered = exercises.sorted { $0.sortOrder < $1.sortOrder }
        guard let index = ordered.firstIndex(where: { $0.id == current.id }) else { return nil }
        let rest = ordered.dropFirst(index + 1)
        return rest.first { !ExerciseStage($0).isDone } ?? rest.first
    }

    /// Le temps passé sur un exercice : ses sessions enregistrées, plus ce que
    /// le chrono compte **en ce moment** sur lui.
    ///
    /// Lu par la relation inverse (`targetedSessions`) : l'écran de l'exercice
    /// relisait **toutes** les sessions jamais enregistrées, chaque seconde.
    static func seconds(on exercise: Exercise, live: TimeInterval = 0) -> Int {
        (exercise.targetedSessions ?? []).reduce(0) { $0 + $1.durationSeconds } + Int(live)
    }

    /// Le temps passé sur une série entière.
    static func seconds(on series: ExerciseSeries) -> Int {
        series.exercises.reduce(0) { $0 + seconds(on: $1) }
    }
}

extension Exercise {
    /// Marque l'exercice fait ou à faire — questions comprises.
    ///
    /// Décocher efface aussi la correction : un exercice « à faire » n'a pas
    /// encore de couleur.
    func setDone(_ done: Bool) {
        if hasSubQuestions {
            setSubQuestions(done: done)
        } else {
            doneAt = done ? (doneAt ?? Date()) : nil
        }
        if !done {
            correctness = nil
            correctedAt = nil
            confidence = nil
        }
    }

    /// Enregistre la correction — la couleur de l'exercice. Corriger un
    /// exercice le marque fait. Rouge le marque à refaire ; vert retire le
    /// « à refaire » d'une correction précédente (il a été refait).
    func correct(_ result: Correctness) {
        if !isDone { setDone(true) }
        correctness = result
        correctedAt = Date()
        switch result {
        case .wrong: redoRequired = true
        case .correct: redoRequired = false
        case .partial: break
        }
    }

    /// Retire la correction (un toucher de trop sur une pastille).
    func clearCorrection() {
        correctness = nil
        correctedAt = nil
        redoRequired = false
    }
}
