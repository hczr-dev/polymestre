import Foundation

/// « Marquer la semaine faite » : toute la théorie vue, tous les exercices
/// faits, d'un geste — et défaisable.
///
/// Arriver dans l'app en semaine 4 (ou importer un cours en retard) laissait
/// trois semaines de contenu à cocher ligne par ligne, alors qu'elles étaient
/// finies. Les semaines « en retard » faussaient ensuite toute la progression.
enum WeekCompletion {

    enum Scope: Equatable {
        /// Théorie vue et exercices faits (à corriger).
        case all
        /// Théorie vue, exercices faits **et corrigés justes** : une semaine
        /// finie et corrigée depuis longtemps.
        case allCorrected
        /// La théorie seulement.
        case theoryOnly
    }

    /// Ce qui a changé : de quoi le défaire exactement, sans toucher à ce qui
    /// était déjà coché avant.
    struct Change: Equatable {
        var theory: [UUID] = []
        var exercises: [UUID] = []
        var corrected: [UUID] = []

        var isEmpty: Bool { theory.isEmpty && exercises.isEmpty && corrected.isEmpty }

        /// « 4 éléments de théorie, 7 exercices ».
        var summary: String {
            var parts: [String] = []
            if !theory.isEmpty { parts.append(String(localized: "\(theory.count) théorie")) }
            if !exercises.isEmpty { parts.append(Plural.count(exercises.count, "\(exercises.count) exercice", "\(exercises.count) exercices")) }
            if !corrected.isEmpty, corrected.count != exercises.count {
                parts.append(Plural.count(corrected.count, "\(corrected.count) corrigé", "\(corrected.count) corrigés"))
            }
            return parts.isEmpty ? String(localized: "rien à cocher") : parts.joined(separator: ", ")
        }
    }

    /// Ce que contient la semaine, pour dire combien de lignes seront cochées.
    static func pending(in weeks: ClosedRange<Int>, of course: Course) -> (theory: Int, exercises: Int) {
        let theory = course.theoryItems.filter { weeks.contains($0.plannedWeek) && !$0.isWatched }.count
        let exercises = course.series.filter { weeks.contains($0.plannedWeek) }
            .flatMap(\.requiredExercises).filter { !$0.isDone }.count
        return (theory, exercises)
    }

    /// Coche les semaines `weeks` du cours. Les bonus ne sont pas touchés :
    /// facultatifs, ils ne sont pas « dus ».
    @discardableResult
    static func mark(_ weeks: ClosedRange<Int>, of course: Course, scope: Scope, now: Date = Date()) -> Change {
        var change = Change()
        for item in course.theoryItems where weeks.contains(item.plannedWeek) && !item.isWatched {
            item.watchedAt = now
            change.theory.append(item.id)
        }
        guard scope != .theoryOnly else { return change }
        for exercise in course.series.filter({ weeks.contains($0.plannedWeek) }).flatMap(\.requiredExercises) {
            if !exercise.isDone {
                exercise.setDone(true)
                change.exercises.append(exercise.id)
            }
            if scope == .allCorrected, !exercise.isCorrected, !exercise.redoRequired {
                exercise.correct(.correct)
                change.corrected.append(exercise.id)
            }
        }
        return change
    }

    /// Défait exactement `change` : ce qui était coché avant le reste.
    static func undo(_ change: Change, in course: Course) {
        let theory = Set(change.theory)
        for item in course.theoryItems where theory.contains(item.id) {
            item.watchedAt = nil
        }
        let done = Set(change.exercises)
        let corrected = Set(change.corrected)
        for exercise in course.allExercises {
            if done.contains(exercise.id) {
                exercise.setDone(false)
            } else if corrected.contains(exercise.id) {
                exercise.clearCorrection()
            }
        }
    }
}
