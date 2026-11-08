import Foundation
import SwiftData

// La page « À rattraper » et le badge « N en retard » lisent la même liste.

func lateWorkResults(context: ModelContext) -> [(Bool, String)] {
    var results: [(Bool, String)] = []
    func note(_ ok: Bool, _ label: String) { results.append((ok, label)) }

    let course = Course(code: "TST-300", name: "Retard", credits: 4)
    context.insert(course)
    let s1 = ExerciseSeries(course: course, seriesNumber: 1, plannedWeek: 1)
    let s2 = ExerciseSeries(course: course, seriesNumber: 2, plannedWeek: 2)
    s2.solutionsAt = Date().addingTimeInterval(86_400)       // corrigé pas encore publié
    let s4 = ExerciseSeries(course: course, seriesNumber: 4, plannedWeek: 4)  // semaine en cours
    [s1, s2, s4].forEach(context.insert)
    func exercise(_ series: ExerciseSeries, _ number: String, _ order: Int) -> Exercise {
        let e = Exercise(series: series, exerciseNumber: number, sortOrder: order)
        context.insert(e)
        return e
    }
    let uncorrected = exercise(s1, "1.1", 1); uncorrected.setDone(true)
    let undone = exercise(s1, "1.2", 2)
    let redoUndone = exercise(s1, "1.3", 3); redoUndone.redoRequired = true    // non fait ET à refaire
    let bonus = exercise(s1, "1.4", 4); bonus.isBonus = true
    let right = exercise(s1, "1.5", 5); right.correct(.correct)
    let waiting = exercise(s2, "2.1", 1); waiting.setDone(true)                 // corrigé pas publié
    _ = exercise(s2, "2.2", 2)
    _ = exercise(s4, "4.1", 1)                                                  // semaine en cours
    for (week, n) in [(1, "1"), (2, "2a"), (2, "2b"), (4, "4")] {
        context.insert(TheoryItem(course: course, sectionNumber: week, number: n, title: "T\(n)", kind: .video,
                                  plannedWeek: week, sortOrder: week, urlString: ""))
    }

    let late = LateWork.of(course, currentWeek: 4)
    note(late.redo.map(\.exerciseNumber) == ["1.3"], "à refaire : 1.3")
    note(late.toCorrect.map(\.exerciseNumber) == ["1.1"], "à corriger : 1.1 seulement (le corrigé de la série 2 n'est pas publié)")
    note(late.series.map { $0.exercises.map(\.exerciseNumber) } == [["1.2"], ["2.2"]],
         "à faire, série par série, sans le bonus ni l'exercice à refaire (\(late.series.map { $0.exercises.map(\.exerciseNumber) }))")
    note(late.theory.map { "\($0.week):\($0.items.count)" } == ["1:1", "2:2"], "théorie groupée par semaine, sans la semaine en cours")
    note(late.total == 7 && ProgressEngine.lateCount(for: course, currentWeek: 4) == late.total,
         "le badge et la page disent le même nombre (\(late.total))")
    note(late.summary == "1 à refaire, 1 à corriger, 2 exercices à faire et 3 éléments de théorie", "« \(late.summary) »")
    note(LateWork.of(course, currentWeek: 1).total == 1, "en semaine 1, seul l'exercice à refaire est en retard")
    return results
}
