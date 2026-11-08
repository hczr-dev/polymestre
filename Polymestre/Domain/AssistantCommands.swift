import Foundation
import SwiftData

/// Une modification demandée par un assistant, par le serveur MCP.
///
/// L'assistant n'écrit **jamais** directement dans les données : il dépose une
/// commande sur le serveur, et c'est l'app qui l'applique à sa prochaine
/// synchronisation, avec les mêmes règles que l'interface (`setDone`,
/// `correct`, `ContentDraftWriter`…). Une commande qui ne trouve pas sa cible
/// échoue proprement, et l'assistant le lit dans `list_pending_changes`.
struct AssistantCommand: Codable, Equatable {
    var id: String
    var kind: String
    var payload: Payload

    struct Payload: Codable, Equatable {
        // Cible
        var courseId: String?
        var course: String?
        var exerciseId: String?
        var exercise: String?
        var theoryId: String?
        var theory: String?
        // Exercice
        var done: Bool?
        var confidence: String?
        var correctness: String?
        var redo: Bool?
        var note: String?
        var questions: [String]?
        // Théorie
        var watched: Bool?
        var summary: String?
        // Session
        var type: String?
        var minutes: Double?
        var startedAt: String?
        // Série, évaluation
        var number: Int?
        /// « b », « mardi » : la deuxième série d'une semaine.
        var label: String?
        var week: Int?
        var title: String?
        var exercises: [NewExercise]?
        var date: String?
        var examKind: String?
        var location: String?
    }

    struct NewExercise: Codable, Equatable {
        var number: String
        var title: String?
        var statement: String?
        var bonus: Bool?
        var questions: [String]?
    }
}

/// Le compte rendu d'une commande, renvoyé au serveur.
struct AssistantCommandResult: Codable, Equatable {
    var id: String
    var status: String
    var message: String

    static func applied(_ id: String, _ message: String) -> Self { .init(id: id, status: "applied", message: message) }
    static func failed(_ id: String, _ message: String) -> Self { .init(id: id, status: "failed", message: message) }
}

/// Applique les commandes d'un assistant.
enum AssistantCommandApplier {

    static func apply(_ commands: [AssistantCommand], context: ModelContext, now: Date = Date()) -> [AssistantCommandResult] {
        let courses = (try? context.fetch(FetchDescriptor<Course>())) ?? []
        let results = commands.map { command -> AssistantCommandResult in
            do {
                return .applied(command.id, try apply(command, courses: courses, context: context, now: now))
            } catch let error as Failure {
                return .failed(command.id, error.message)
            } catch {
                return .failed(command.id, error.localizedDescription)
            }
        }
        try? context.save()
        return results
    }

    struct Failure: Error { var message: String }

    private static func apply(_ command: AssistantCommand, courses: [Course], context: ModelContext, now: Date) throws -> String {
        let p = command.payload
        switch command.kind {
        case "update_exercise":
            let exercise = try findExercise(p, in: courses)
            var changes: [String] = []
            if let done = p.done {
                exercise.setDone(done)
                changes.append(done ? "fait" : "à faire")
            }
            // `confidence` venait d'une version où la couleur était une
            // « sureté » ; c'est la correction, et on la lit comme telle.
            if let raw = p.correctness ?? p.confidence {
                guard let result = correctness(raw) else { throw Failure(message: "Correction inconnue « \(raw) » (correct/green, partial/orange, wrong/red).") }
                exercise.correct(result)
                changes.append("corrigé \(result.shortLabel.lowercased())")
            }
            if let redo = p.redo {
                exercise.redoRequired = redo
                changes.append(redo ? "à refaire" : "plus à refaire")
            }
            if let note = p.note {
                exercise.correctionNote = note.isEmpty ? nil : note
                changes.append("remarque")
            }
            guard !changes.isEmpty else { throw Failure(message: "Rien à modifier sur \(exercise.displayNumber).") }
            return "\(exercise.displayNumber) : " + changes.joined(separator: ", ")

        case "check_questions":
            let exercise = try findExercise(p, in: courses)
            guard exercise.hasSubQuestions else {
                exercise.setDone(p.done ?? true)
                return "\(exercise.displayNumber) n'a pas de questions : marqué \(exercise.isDone ? "fait" : "à faire")"
            }
            let done = p.done ?? true
            let wanted = Set((p.questions ?? []).map(normalizeLabel))
            let leaves = exercise.leafSubQuestions
            let targets = wanted.isEmpty ? leaves : leaves.filter { leaf in
                wanted.contains(normalizeLabel(leaf.path)) || wanted.contains(normalizeLabel(leaf.label))
            }
            guard !targets.isEmpty else {
                throw Failure(message: "Aucune question « \(wanted.sorted().joined(separator: ", ")) » dans \(exercise.displayNumber) (questions : \(leaves.map(\.path).joined(separator: ", "))).")
            }
            for leaf in targets where leaf.isDone != done { leaf.toggle() }
            exercise.refreshCompletion()
            let questions = done
                ? Plural.count(targets.count, "\(targets.count) question cochée", "\(targets.count) questions cochées")
                : Plural.count(targets.count, "\(targets.count) question décochée", "\(targets.count) questions décochées")
            return "\(exercise.displayNumber) : \(questions) (\(exercise.subQuestionLabel ?? ""))"

        case "update_theory":
            let item = try findTheory(p, in: courses)
            var changes: [String] = []
            if let watched = p.watched {
                item.watchedAt = watched ? (item.watchedAt ?? now) : nil
                changes.append(watched ? "vu" : "pas vu")
            }
            if let summary = p.summary {
                item.summaryText = summary
                item.summarizedAt = summary.isEmpty ? nil : now
                if !summary.isEmpty, item.watchedAt == nil { item.watchedAt = now }
                changes.append("résumé")
            }
            guard !changes.isEmpty else { throw Failure(message: "Rien à modifier sur \(item.displayNumber).") }
            return "\(item.course?.displayCode ?? "") \(item.displayNumber) : " + changes.joined(separator: ", ")

        case "log_session":
            guard let minutes = p.minutes, minutes > 0, minutes <= 16 * 60 else {
                throw Failure(message: "Durée invalide (entre 1 et 960 minutes).")
            }
            let course = try? findCourse(p, in: courses)
            let type = TaskType(rawValue: p.type ?? "") ?? .other
            let exercise = (p.exerciseId != nil || p.exercise != nil) ? try? findExercise(p, in: courses) : nil
            let theory = (p.theoryId != nil || p.theory != nil) ? try? findTheory(p, in: courses) : nil
            let seconds = Int(minutes * 60)
            let start = p.startedAt.flatMap(parseDate) ?? now.addingTimeInterval(-TimeInterval(seconds))
            let session = StudySession(course: course ?? exercise?.series?.course ?? theory?.course,
                                       taskType: type, startedAt: start, durationSeconds: seconds,
                                       isManual: true, note: p.note ?? "Ajouté par l'assistant",
                                       exercise: exercise, theoryItem: theory)
            context.insert(session)
            return "Session de \(DateUtils.durationLabel(seconds: seconds)) enregistrée\(session.course.map { " (\($0.displayCode))" } ?? "")"

        case "add_series":
            let course = try findCourse(p, in: courses)
            guard let number = p.number, number > 0 else { throw Failure(message: "Numéro de série manquant.") }
            let label = SeriesIdentity.normalized(p.label ?? "")
            let draft = SeriesDraft(number: number,
                                    label: label,
                                    title: "",
                                    plannedWeek: p.week ?? course.currentWeek,
                                    exercises: (p.exercises ?? []).map { spec in
                                        // « 3.4 » → « 4 » : le brouillon porte le
                                        // numéro **dans** la série.
                                        var draft = ExerciseDraft(minor: spec.number.split(separator: ".").last.map(String.init) ?? spec.number,
                                                                  title: spec.title ?? "",
                                                                  isBonus: spec.bonus ?? false,
                                                                  subQuestions: (spec.questions ?? []).map { DetectedSubQuestion(label: $0, text: "") })
                                        draft.statement = spec.statement ?? ""
                                        return draft
                                    })
            let existed = course.series(number: number, label: label) != nil
            let written = SeriesDraftWriter.write(draft, to: course, mode: .importMerge, context: context).series
            if let title = p.title, !title.isEmpty { written.title = title }
            return "\(course.displayCode) : \(written.displayName.lowercased()) \(existed ? "complétée" : "ajoutée") (\(Plural.count(draft.exercises.count, "\(draft.exercises.count) exercice", "\(draft.exercises.count) exercices")))"

        case "add_exam":
            let course = try findCourse(p, in: courses)
            guard let date = p.date.flatMap(parseDate) else { throw Failure(message: "Date invalide (ISO 8601 attendu).") }
            let kind = ExamKind(rawValue: p.examKind ?? "") ?? .exam
            let exam = Exam(course: course, kind: kind, title: p.title ?? "", date: date, location: p.location ?? "")
            context.insert(exam)
            return "\(course.displayCode) : \(exam.title) le \(DateUtils.shortDay.string(from: date))"

        default:
            throw Failure(message: "Commande inconnue « \(command.kind) ». Mets Polymestre à jour.")
        }
    }

    // MARK: Cibles

    private static func findCourse(_ p: AssistantCommand.Payload, in courses: [Course]) throws -> Course {
        if let id = p.courseId.flatMap(UUID.init(uuidString:)), let course = courses.first(where: { $0.id == id }) { return course }
        if let code = p.course?.trimmingCharacters(in: .whitespaces), !code.isEmpty {
            let folded = ContentDraftBuilder.fold(code)
            if let course = courses.first(where: {
                ContentDraftBuilder.fold($0.code) == folded || ContentDraftBuilder.fold($0.displayCode) == folded
            }) ?? courses.first(where: { ContentDraftBuilder.fold($0.name) == folded })
                ?? courses.first(where: { ContentDraftBuilder.fold($0.code).hasPrefix(folded) || ContentDraftBuilder.fold($0.name).contains(folded) }) {
                return course
            }
            throw Failure(message: "Cours « \(code) » introuvable.")
        }
        throw Failure(message: "Cours manquant.")
    }

    private static func findExercise(_ p: AssistantCommand.Payload, in courses: [Course]) throws -> Exercise {
        if let id = p.exerciseId.flatMap(UUID.init(uuidString:)) {
            for course in courses {
                if let exercise = course.allExercises.first(where: { $0.id == id }) { return exercise }
            }
            throw Failure(message: "Exercice introuvable (supprimé depuis ?).")
        }
        guard let number = p.exercise?.trimmingCharacters(in: .whitespaces), !number.isEmpty else {
            throw Failure(message: "Exercice manquant.")
        }
        let course = try findCourse(p, in: courses)
        let bare = number.replacingOccurrences(of: "Exercice ", with: "")
        guard let exercise = course.allExercises.first(where: { $0.exerciseNumber == bare }) else {
            throw Failure(message: "Exercice \(bare) introuvable dans \(course.displayCode).")
        }
        return exercise
    }

    private static func findTheory(_ p: AssistantCommand.Payload, in courses: [Course]) throws -> TheoryItem {
        if let id = p.theoryId.flatMap(UUID.init(uuidString:)) {
            for course in courses {
                if let item = course.theoryItems.first(where: { $0.id == id }) { return item }
            }
            throw Failure(message: "Élément de théorie introuvable.")
        }
        guard let number = p.theory?.trimmingCharacters(in: .whitespaces), !number.isEmpty else {
            throw Failure(message: "Élément de théorie manquant.")
        }
        let course = try findCourse(p, in: courses)
        guard let item = course.theoryItems.first(where: { $0.number == number }) else {
            throw Failure(message: "Théorie \(number) introuvable dans \(course.displayCode).")
        }
        return item
    }

    // MARK: Valeurs

    static func confidence(_ raw: String) -> ConfidenceLevel? {
        switch ContentDraftBuilder.fold(raw) {
        case "sure", "sur", "high", "green", "vert": return .high
        case "medium", "moyen", "orange": return .medium
        case "unsure", "pas sur", "low", "red", "rouge": return .low
        default: return nil
        }
    }

    static func correctness(_ raw: String) -> Correctness? {
        switch ContentDraftBuilder.fold(raw) {
        case "correct", "juste", "right", "green", "vert", "sure", "high": return .correct
        case "partial", "moyen", "partiel", "moyennement juste", "orange", "medium": return .partial
        case "wrong", "faux", "incorrect", "red", "rouge", "unsure", "low": return .wrong
        default: return nil
        }
    }

    /// « (a) », « a) », « 1.a » → « a », « 1.a ».
    static func normalizeLabel(_ raw: String) -> String {
        raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " ().:"))
            .replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "")
    }

    static func parseDate(_ raw: String) -> Date? {
        let full = ISO8601DateFormatter()
        if let date = full.date(from: raw) { return date }
        let day = ISO8601DateFormatter()
        day.formatOptions = [.withFullDate]
        return day.date(from: raw)
    }
}

