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

    // Une reprise espacée n'est en retard qu'à son palier.
    let now = Date()
    let spaced = exercise(s1, "1.6", 6)
    spaced.correct(.partial)
    spaced.redoRequired = true
    spaced.redoPass = 1
    spaced.redoDueAt = now.addingTimeInterval(10 * 86_400)
    let queued = LateWork.of(course, currentWeek: 4, now: now)
    note(queued.redo.map(\.exerciseNumber) == ["1.3"] && !queued.toCorrect.contains { $0.id == spaced.id },
         "une reprise prévue dans dix jours n'est ni à refaire ni à corriger aujourd'hui")
    note(LateWork.of(course, currentWeek: 4, now: now.addingTimeInterval(11 * 86_400)).redo.contains { $0.id == spaced.id },
         "elle l'est une fois son palier arrivé")
    spaced.redoDueAt = nil
    note(!LateWork.of(course, currentWeek: 4, now: now).redo.contains { $0.id == spaced.id },
         "le palier « pré-examen » sans date d'examen n'est pas dû")
    context.delete(spaced)

    // Une série à rendre jeudi n'est pas en retard le lundi ; une série de la
    // semaine en cours dont l'échéance est passée l'est.
    let dated = Course(code: "TST-301", name: "Échéances", credits: 4)
    context.insert(dated)
    let nextThursday = ExerciseSeries(course: dated, seriesNumber: 1, plannedWeek: 2)
    nextThursday.dueDate = now.addingTimeInterval(3 * 86_400)
    let passed = ExerciseSeries(course: dated, seriesNumber: 2, plannedWeek: 3)
    passed.dueDate = now.addingTimeInterval(-3_600)
    [nextThursday, passed].forEach(context.insert)
    _ = exercise(nextThursday, "1.1", 1)
    let doneEarly = exercise(nextThursday, "1.2", 2); doneEarly.setDone(true)
    _ = exercise(passed, "2.1", 1)
    let datedLate = LateWork.of(dated, currentWeek: 3, now: now)
    note(datedLate.series.map(\.series.seriesNumber) == [2], "l'échéance fait foi, pas la semaine (\(datedLate.series.map(\.series.seriesNumber)))")
    note(ProgressEngine.correctionsDue(for: dated, currentWeek: 3, now: now).toCorrect == 1,
         "la série pas encore échue : 1 à corriger cette semaine, hors retard")
    note(LateWork.of(dated, currentWeek: 3, now: now.addingTimeInterval(4 * 86_400)).total == 3,
         "passé jeudi : la série 1 entre au retard (1 à faire, 1 à corriger) avec la 2")

    // La dernière semaine devient due après le semestre.
    let start = DateUtils.startOfWeek(DateUtils.addDays(-20 * 7, to: now))
    let ended = AcademicTerm(year: 2020, season: .autumn, startDate: start, endDate: DateUtils.addDays(14 * 7, to: start), totalWeeks: 14)
    context.insert(ended)
    let finished = Course(code: "TST-302", name: "Fini", credits: 4)
    context.insert(finished)
    finished.term = ended
    context.insert(TheoryItem(course: finished, sectionNumber: 14, number: "14", title: "T14", kind: .video,
                              plannedWeek: 14, sortOrder: 1, urlString: ""))
    note(finished.currentWeek == 14 && finished.dueWeek(at: now) > 14 && LateWork.of(finished, now: now).theoryCount == 1,
         "après le semestre, la semaine 14 est échue (semaine affichée \(finished.currentWeek), due \(finished.dueWeek(at: now)))")

    // Décocher une question efface la correction : jamais « à faire » et juste.
    let parted = Exercise(series: s4, exerciseNumber: "4.2", sortOrder: 2)
    context.insert(parted)
    for label in ["a", "b"] {
        let q = SubQuestion(exercise: parted, parent: nil, label: label, text: "", kind: .question, sortOrder: 0)
        context.insert(q); parted.subQuestions.append(q)
    }
    parted.correct(.correct)
    parted.subQuestions[0].isDone = false
    parted.refreshCompletion()
    note(!parted.isDone && !parted.isCorrected && parted.correctness == nil && ExerciseStage(parted) == .inProgress(done: 1, total: 2),
         "une question décochée : l'exercice repasse en cours, sans couleur")

    // Progression : un exercice à refaire n'est pas fait ; corrigés ⩽ faits.
    let graded = Course(code: "TST-303", name: "Progression", credits: 4)
    context.insert(graded)
    let gs = ExerciseSeries(course: graded, seriesNumber: 1, plannedWeek: 1)
    context.insert(gs)
    let ok = exercise(gs, "1.1", 1); ok.correct(.correct)
    let ko = exercise(gs, "1.2", 2); ko.correct(.wrong)
    let stale = exercise(gs, "1.3", 3); stale.correctedAt = now; stale.correctness = .correct  // donnée ancienne : corrigé sans être fait
    let p = ProgressEngine.progress(for: graded)
    note(p.doneCount == 1 && p.correctedCount == 1 && p.correctionPercent <= 1,
         "1 fait (le faux est à refaire), 1 corrigé, jamais plus de 100 % (\(p.doneCount) faits, \(p.correctedCount) corrigés)")

    // Le widget passe au bon retard sans l'app.
    var snapshot = WidgetSnapshot(updatedAt: now)
    snapshot.courses = [WidgetCourse(id: "x", code: "X", colorHex: "#000000", done: 0, total: 0, summary: "", late: 1,
                                     lateChanges: [WidgetCount(from: now.addingTimeInterval(3_600), value: 4)])]
    note(snapshot.resolved(at: now).courses?.first?.late == 1 && snapshot.resolved(at: now.addingTimeInterval(7_200)).courses?.first?.late == 4,
         "le widget lit le retard de l'instant affiché")
    note(snapshot.timelineDates(from: now).dates.contains(now.addingTimeInterval(3_600)), "et prévoit une entrée au changement")
    return results
}
