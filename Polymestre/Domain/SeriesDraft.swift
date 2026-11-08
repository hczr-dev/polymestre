import Foundation
import SwiftData

// MARK: - Brouillons

/// Une série telle qu'elle sera enregistrée — modifiable avant.
///
/// Le **même** brouillon sert à relire un import et à modifier une série déjà
/// enregistrée : les deux écrans se comportent donc de la même façon, et un
/// exercice mal importé se corrige avec les gestes qui ont servi à l'importer.
struct SeriesDraft: Identifiable, Equatable {
    let id: UUID
    /// La série enregistrée que ce brouillon modifie, s'il y en a une.
    var existingID: UUID?
    var number: Int
    /// « b », « mardi » : ce qui distingue deux séries de même numéro (`SeriesIdentity`).
    var label: String = ""
    var title: String
    var plannedWeek: Int
    var dueDate: Date?
    var exercises: [ExerciseDraft]

    init(id: UUID = UUID(), existingID: UUID? = nil, number: Int, label: String = "", title: String,
         plannedWeek: Int, dueDate: Date? = nil, exercises: [ExerciseDraft]) {
        self.id = id
        self.existingID = existingID
        self.number = number
        self.label = SeriesIdentity.normalized(label)
        self.title = title
        self.plannedWeek = plannedWeek
        self.dueDate = dueDate
        self.exercises = exercises
    }

    /// Le brouillon d'une série enregistrée, pour la modifier.
    init(series: ExerciseSeries) {
        self.init(existingID: series.id,
                  number: series.seriesNumber,
                  label: series.label,
                  // « Série 3 » est le titre par défaut : on le laisse vide pour
                  // que changer le numéro ne laisse pas un « Série 3 » périmé.
                  title: series.title == series.displayName || series.title == "Série \(series.seriesNumber)" ? "" : series.title,
                  plannedWeek: series.plannedWeek,
                  dueDate: series.dueDate,
                  exercises: series.sortedExercises.map(ExerciseDraft.init(exercise:)))
    }

    /// Ajoute la ligne suivante : « 4.3 » après « 4.2 ».
    mutating func addExercise() {
        let next = (exercises.compactMap { Int($0.minor) }.max() ?? 0) + 1
        exercises.append(ExerciseDraft(minor: "\(next)", title: "", isBonus: false))
    }

    /// Renumérote 1, 2, 3… dans l'ordre affiché.
    mutating func renumberExercises() {
        for index in exercises.indices { exercises[index].minor = "\(index + 1)" }
    }

    var leafCount: Int { exercises.reduce(0) { $0 + $1.leafCount } }

    var key: SeriesIdentity.Key { SeriesIdentity.Key(number, label) }
    var displayName: String { SeriesIdentity.displayName(number: number, label: label) }

    /// Ce qui empêche d'enregistrer, en phrases.
    ///
    /// `taken` : les séries (numéro et étiquette) des **autres** séries du cours.
    /// Deux séries 5 la même semaine se distinguent par leur étiquette (« a », « b »).
    func problems(taken: Set<SeriesIdentity.Key>) -> [String] {
        var result: [String] = []
        if taken.contains(key) {
            result.append(label.isEmpty
                ? "La série \(number) existe déjà dans ce cours. Pour une deuxième série la même semaine, donne-lui une étiquette (« b », « jeudi »)."
                : "La \(displayName) existe déjà dans ce cours.")
        }
        let minors = exercises.map { $0.minor.trimmingCharacters(in: .whitespaces) }
        if minors.contains(where: \.isEmpty) {
            result.append("Un exercice n'a pas de numéro.")
        }
        let duplicates = Dictionary(grouping: minors.filter { !$0.isEmpty }, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
        if !duplicates.isEmpty {
            result.append("Numéro en double : " + duplicates.map { "\(number).\($0)" }.joined(separator: ", ") + ".")
        }
        return result
    }
}

/// Un exercice tel qu'il sera enregistré. Le numéro est stocké **sans** la
/// série : changer le numéro de série renumérote toute la liste d'un coup.
struct ExerciseDraft: Identifiable, Equatable {
    let id: UUID
    /// L'exercice enregistré que cette ligne modifie : son avancement le suit
    /// même si on change son numéro.
    var existingID: UUID?
    var minor: String
    var title: String
    var isBonus: Bool
    /// Ce que l'exercice demande, en une phrase.
    var statement: String = ""
    var subQuestions: [DetectedSubQuestion] = []
    /// Où l'exercice se trouve dans le PDF importé, pour l'aperçu.
    var pageIndex: Int?
    var top: Double?
    var bottom: Double?
    /// Déjà fait (exercice existant) : affiché dans l'éditeur, jamais modifié par lui.
    var isDone = false

    init(id: UUID = UUID(), minor: String, title: String, isBonus: Bool,
         subQuestions: [DetectedSubQuestion] = []) {
        self.id = id
        self.minor = minor
        self.title = title
        self.isBonus = isBonus
        self.subQuestions = subQuestions
    }

    init(detected: DetectedExercise) {
        self.init(minor: detected.number.split(separator: ".").last.map(String.init) ?? detected.number,
                  title: detected.title, isBonus: detected.isBonus, subQuestions: detected.subQuestions)
        statement = detected.statement
        pageIndex = detected.pageIndex
        top = detected.verticalPosition
    }

    init(exercise: Exercise) {
        self.init(minor: exercise.exerciseNumber.split(separator: ".").last.map(String.init) ?? exercise.exerciseNumber,
                  title: exercise.title, isBonus: exercise.isBonus, subQuestions: exercise.detectedSubQuestions)
        existingID = exercise.id
        statement = exercise.statement
        isDone = exercise.isDone
    }

    var leafCount: Int { subQuestions.isEmpty ? 1 : subQuestions.reduce(0) { $0 + $1.leafCount } }
}

// MARK: - Arbre des questions

/// Les gestes sur l'arbre des questions d'un exercice, **purs** et testés.
///
/// L'éditeur affiche l'arbre à plat — une ligne par question ou point, avec sa
/// profondeur — et chaque geste (supprimer, rattacher à la question précédente,
/// remonter au premier niveau, déplacer) passe par ici.
enum SubQuestionTree {

    struct Row: Identifiable, Equatable {
        var id: UUID
        var depth: Int
        var question: DetectedSubQuestion
        /// Peut devenir un point de la question du dessus.
        var canIndent: Bool
        var canOutdent: Bool { depth == 1 }
    }

    static func rows(_ questions: [DetectedSubQuestion]) -> [Row] {
        var result: [Row] = []
        for (index, question) in questions.enumerated() {
            let previous = index > 0 ? questions[index - 1] : nil
            result.append(Row(id: question.id, depth: 0, question: question,
                              canIndent: previous?.kind == .question && question.kind == .question && question.children.isEmpty))
            for child in question.children {
                result.append(Row(id: child.id, depth: 1, question: child, canIndent: false))
            }
        }
        return result
    }

    static func remove(_ id: UUID, from questions: inout [DetectedSubQuestion]) {
        questions.removeAll { $0.id == id }
        for index in questions.indices { questions[index].children.removeAll { $0.id == id } }
    }

    static func update(_ id: UUID, in questions: inout [DetectedSubQuestion],
                       _ change: (inout DetectedSubQuestion) -> Void) {
        for index in questions.indices {
            if questions[index].id == id { change(&questions[index]); return }
            for child in questions[index].children.indices where questions[index].children[child].id == id {
                change(&questions[index].children[child])
                return
            }
        }
    }

    /// « 2) » devient le point suivant de « 1) ».
    static func indent(_ id: UUID, in questions: inout [DetectedSubQuestion]) {
        guard let index = questions.firstIndex(where: { $0.id == id }), index > 0,
              questions[index - 1].kind == .question, questions[index].children.isEmpty else { return }
        let moved = questions.remove(at: index)
        questions[index - 1].children.append(moved)
    }

    /// Un point remonte au premier niveau, juste après sa question. Les points
    /// qui le suivaient restent à leur question.
    static func outdent(_ id: UUID, in questions: inout [DetectedSubQuestion]) {
        for index in questions.indices {
            guard let child = questions[index].children.firstIndex(where: { $0.id == id }) else { continue }
            let moved = questions[index].children.remove(at: child)
            questions.insert(moved, at: index + 1)
            return
        }
    }

    /// Ajoute un point à une question : « c » après « b ».
    static func addChild(to id: UUID, in questions: inout [DetectedSubQuestion]) {
        guard let index = questions.firstIndex(where: { $0.id == id }) else { return }
        let label = nextLabel(after: questions[index].children.last?.label, fallback: "a")
        questions[index].children.append(DetectedSubQuestion(label: label))
    }

    static func addQuestion(to questions: inout [DetectedSubQuestion]) {
        let last = questions.last { $0.kind == .question }?.label
        questions.append(DetectedSubQuestion(label: nextLabel(after: last, fallback: "1")))
    }

    /// Déplace une question du premier niveau (ses points la suivent).
    static func move(in questions: inout [DetectedSubQuestion], from source: IndexSet, to destination: Int) {
        questions.move(fromOffsets: source, toOffset: destination)
    }

    /// Réécrit les étiquettes dans l'ordre : 1, 2, 3 et a, b, c sous chacune.
    static func relabel(_ questions: inout [DetectedSubQuestion]) {
        var rank = 0
        for index in questions.indices where questions[index].kind == .question {
            rank += 1
            questions[index].label = String(rank)
            for child in questions[index].children.indices {
                questions[index].children[child].label = letter(child)
            }
        }
    }

    /// « 3 » après « 2 », « c » après « b », « iv » après « iii ».
    static func nextLabel(after label: String?, fallback: String) -> String {
        guard let label, !label.isEmpty else { return fallback }
        if let value = Int(label) { return String(value + 1) }
        if let index = romans.firstIndex(of: label), index + 1 < romans.count { return romans[index + 1] }
        if label.count == 1, let scalar = label.unicodeScalars.first,
           let next = Unicode.Scalar(scalar.value + 1) { return String(Character(next)) }
        return fallback
    }

    static func letter(_ index: Int) -> String {
        String(Character(Unicode.Scalar(UInt8(97 + min(index, 25)))))
    }

    static let romans = ["i", "ii", "iii", "iv", "v", "vi", "vii", "viii", "ix", "x", "xi", "xii"]

    // MARK: Plan en une ligne

    /// L'arbre écrit en une ligne : « 1(a-d) 2(a-e) 3 + ».
    ///
    /// C'est aussi une **saisie** : taper le plan d'un exercice est plus rapide
    /// que d'ajouter neuf lignes une par une, et c'est la forme sous laquelle on
    /// lit un polycopié.
    static func outline(_ questions: [DetectedSubQuestion]) -> String {
        questions.map { question in
            if question.kind == .part { return "+" }
            let labels = question.children.map(\.label)
            guard let first = labels.first else { return question.label }
            if labels.count >= 3, labels == expand(first, labels.last!) { return "\(question.label)(\(first)-\(labels.last!))" }
            return "\(question.label)(\(labels.joined(separator: ",")))"
        }.joined(separator: " ")
    }

    /// Lit un plan. Les textes des questions existantes sont repris quand leur
    /// étiquette ne change pas : réécrire le plan ne doit pas effacer ce qui a
    /// été saisi. Renvoie `nil` si le plan est illisible.
    static func parse(_ text: String, keeping previous: [DetectedSubQuestion] = []) -> [DetectedSubQuestion]? {
        var result: [DetectedSubQuestion] = []
        var remaining = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        var partIndex = 0
        let previousParts = previous.filter { $0.kind == .part }

        func skipSeparators() {
            while let first = remaining.first, first == " " || first == "," || first == ";" { remaining.removeFirst() }
        }
        func token() -> String {
            var value = ""
            while let first = remaining.first, first.isLetter || first.isNumber || first == "-" || first == "–" {
                value.append(first == "–" ? "-" : first)
                remaining.removeFirst()
            }
            return value
        }

        skipSeparators()
        while !remaining.isEmpty {
            if remaining.first == "+" {
                remaining.removeFirst()
                let kept = partIndex < previousParts.count ? previousParts[partIndex] : nil
                partIndex += 1
                result.append(DetectedSubQuestion(label: "", text: kept?.text ?? "", kind: .part))
                skipSeparators()
                continue
            }
            let head = token()
            guard !head.isEmpty else { return nil }
            var labels = rangeLabels(head)
            guard !labels.isEmpty else { return nil }
            var children: [String] = []
            if remaining.first == "(" {
                remaining.removeFirst()
                guard let close = remaining.firstIndex(of: ")") else { return nil }
                let inside = remaining[..<close]
                remaining = remaining[remaining.index(after: close)...]
                for piece in inside.split(whereSeparator: { $0 == "," || $0 == " " }) {
                    let expanded = rangeLabels(String(piece).replacingOccurrences(of: "–", with: "-"))
                    guard !expanded.isEmpty else { return nil }
                    children += expanded
                }
                // « 1-3(a-b) » : chaque question reçoit les mêmes points.
            }
            for label in labels {
                let old = previous.first { $0.kind == .question && $0.label == label }
                result.append(DetectedSubQuestion(
                    label: label, text: old?.text ?? "",
                    children: children.map { child in
                        DetectedSubQuestion(label: child, text: old?.children.first { $0.label == child }?.text ?? "")
                    }))
            }
            labels = []
            skipSeparators()
        }
        return result
    }

    /// « 3-5 » → 3, 4, 5 ; « a-d » → a…d ; « ii-iv » → ii, iii, iv ; « 7 » → 7.
    static func rangeLabels(_ token: String) -> [String] {
        let parts = token.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        if parts.count == 1 { return parts[0].isEmpty ? [] : [parts[0].lowercased()] }
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return [] }
        return expand(parts[0].lowercased(), parts[1].lowercased())
    }

    static func expand(_ first: String, _ last: String) -> [String] {
        if let a = Int(first), let b = Int(last), a <= b, b - a < 60 { return (a...b).map(String.init) }
        if let a = romans.firstIndex(of: first), let b = romans.firstIndex(of: last), a <= b,
           !(first.count == 1 && last.count == 1 && first != "i") {
            return Array(romans[a...b])
        }
        if first.count == 1, last.count == 1,
           let a = first.unicodeScalars.first?.value, let b = last.unicodeScalars.first?.value,
           a <= b, b - a < 26, first.first!.isLetter {
            return (a...b).compactMap { Unicode.Scalar($0).map { String(Character($0)) } }
        }
        return []
    }
}

// MARK: - Enregistrement

/// Écrit un brouillon dans la base.
///
/// Deux modes, parce que les deux écrans n'ont pas la même autorité :
///   • **import** — le brouillon *complète* la série du même numéro : on met à
///     jour les exercices de même numéro, on ajoute les autres, on ne supprime
///     rien de ce que le PDF ne mentionne pas ;
///   • **modification** — le brouillon *est* la série : un exercice retiré de la
///     liste est supprimé, un exercice renuméroté garde son avancement ;
///   • **révision** — l'énoncé a changé à la source (`SeriesSourceWatch`) : la
///     nouvelle lecture *est* la série ; un exercice que l'énoncé n'a plus est
///     supprimé (son temps chronométré reste au cours).
///
/// À l'import comme à la révision, un exercice se retrouve **par son contenu**
/// (`SeriesReconciler`), le numéro ne servant qu'en dernier recours : un
/// énoncé où l'on a inséré un exercice décale tous les numéros, pas les
/// exercices.
enum SeriesDraftWriter {

    enum Mode { case importMerge, edit, revision }

    /// La marque que posait la première version des révisions sur un exercice
    /// retiré ; ces exercices sont supprimés au passage (`SeriesAutoReader`).
    static let removedMark = "retiré de l'énoncé"

    struct Outcome: Equatable {
        var created = 0
        var updated = 0
        var deleted = 0
    }

    @discardableResult
    static func write(_ draft: SeriesDraft, to course: Course, mode: Mode,
                      context: ModelContext?) -> (series: ExerciseSeries, outcome: Outcome) {
        var outcome = Outcome()
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)

        let series: ExerciseSeries
        let existing: ExerciseSeries? = switch mode {
        case .edit: course.series.first { $0.id == draft.existingID }
        case .importMerge: course.series.first { $0.id == draft.existingID } ?? course.series(number: draft.number, label: draft.label)
        case .revision: course.series.first { $0.id == draft.existingID } ?? course.series(number: draft.number, label: draft.label)
        }
        if let existing {
            series = existing
            series.seriesNumber = draft.number
            if mode == .edit || !draft.label.isEmpty { series.label = SeriesIdentity.normalized(draft.label) }
            if mode == .edit || !title.isEmpty {
                series.title = title.isEmpty ? draft.displayName : title
            }
            if mode == .edit {
                series.plannedWeek = draft.plannedWeek
                series.dueDate = draft.dueDate
            }
        } else {
            series = ExerciseSeries(course: course, seriesNumber: draft.number, label: draft.label, title: title,
                                    plannedWeek: draft.plannedWeek, dueDate: draft.dueDate)
            context?.insert(series)
            if context == nil { course.series.append(series) }
        }

        var kept = Set<UUID>()
        var usedNumbers = Set<String>()
        // Import et révision : chaque ligne retrouve son exercice par le contenu.
        var byContent: [Int: Exercise] = [:]
        if mode != .edit {
            let olds = series.sortedExercises
            let found = SeriesReconciler.match(
                existing: olds.map { SeriesReconciler.Item(number: $0.exerciseNumber, title: $0.title, statement: $0.statement) },
                incoming: draft.exercises.map { SeriesReconciler.Item(number: "\(draft.number).\($0.minor)", title: $0.title, statement: $0.statement) })
            for (index, old) in found.enumerated() { if let old { byContent[index] = olds[old] } }
        }
        for (order, item) in draft.exercises.enumerated() {
            let minor = item.minor.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !minor.isEmpty else { continue }
            let number = "\(draft.number).\(minor)"
            guard usedNumbers.insert(number).inserted else { continue }
            let itemTitle = item.title.trimmingCharacters(in: .whitespacesAndNewlines)

            let match: Exercise? = switch mode {
            case .edit: series.exercises.first { $0.id == item.existingID }
            case .importMerge, .revision:
                item.existingID.flatMap { id in series.exercises.first { $0.id == id } }
                    ?? byContent[order]
                    // Le numéro, seulement à l'import et si cet exercice n'est
                    // pas déjà celui d'une autre ligne.
                    ?? (mode == .importMerge
                        ? series.exercises.first { $0.exerciseNumber == number && !kept.contains($0.id) && !byContent.values.contains($0) }
                        : nil)
            }
            if let match, !kept.contains(match.id) {
                match.exerciseNumber = number
                // Une lecture sans titre ne retire pas celui qu'on avait.
                if mode == .edit || !itemTitle.isEmpty { match.title = itemTitle }
                // Un import sans énoncé (lecture locale) n'efface pas celui qu'on avait.
                let statement = item.statement.trimmingCharacters(in: .whitespacesAndNewlines)
                if mode == .edit || !statement.isEmpty { match.statement = statement }
                match.isBonus = item.isBonus
                match.sortOrder = order
                // Réécrire un arbre identique effacerait les dates des cases
                // cochées pour rien.
                if match.detectedSubQuestions != item.subQuestions {
                    match.replaceSubQuestions(with: item.subQuestions, in: context)
                }
                kept.insert(match.id)
                outcome.updated += 1
            } else {
                let exercise = Exercise(series: series, exerciseNumber: number, title: itemTitle,
                                        isBonus: item.isBonus, sortOrder: order)
                exercise.statement = item.statement.trimmingCharacters(in: .whitespacesAndNewlines)
                context?.insert(exercise)
                if context == nil { series.exercises.append(exercise) }
                exercise.replaceSubQuestions(with: item.subQuestions, in: context)
                kept.insert(exercise.id)
                outcome.created += 1
            }
        }

        if mode == .edit {
            for exercise in series.exercises where !kept.contains(exercise.id) {
                series.exercises.removeAll { $0.id == exercise.id }
                context?.delete(exercise)
                outcome.deleted += 1
            }
        } else if mode == .revision {
            // Retiré de l'énoncé : il n'existe plus, il part. Les sessions qui
            // le visaient restent au cours (la relation se vide).
            for exercise in series.exercises where !kept.contains(exercise.id) {
                series.exercises.removeAll { $0.id == exercise.id }
                context?.delete(exercise)
                outcome.deleted += 1
            }
        } else {
            // Les exercices que le PDF ne cite pas restent, après ceux du PDF.
            var order = draft.exercises.count
            for exercise in series.sortedExercises where !kept.contains(exercise.id) {
                exercise.sortOrder = order
                order += 1
            }
        }
        return (series, outcome)
    }
}
