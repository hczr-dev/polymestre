import Foundation
import SwiftData

// Deux séries par semaine, et des séries aux exercices sans numéro.
//
// Les noms viennent de cours qui ne sont pas ceux du développeur : la lecture
// doit reconnaître le format, pas un cours en particulier.

func seriesIdentityResults(context: ModelContext) -> [(Bool, String)] {
    var results: [(Bool, String)] = []
    func note(_ ok: Bool, _ label: String) { results.append((ok, label)) }

    // MARK: Étiquette lue dans un nom
    let labels: [(String, String)] = [
        ("Série 5a", "a"), ("Serie_05-B", "b"), ("Série 5 (b)", "b"), ("Série 05.pdf", ""),
        ("Série 5 à rendre", ""), ("Serie 5 a rendre", ""), ("Série 1 - exercices", ""), ("Série 1 (corrigé)", ""),
        ("Exercices du mardi", "mardi"), ("Exercises (Thursday)", "jeudi"),
        ("Série 3 — à rendre avant mardi", ""), ("Série 5.2", "2"), ("Série 5, partie 2", "partie 2"),
        ("Problem Set 2 - Part II", "partie 2"), ("Série A", "a"), ("Problem Set 1: Motion in 1D", ""), ("Série 10", ""),
    ]
    for (name, expected) in labels {
        let got = SeriesIdentity.label(in: name)
        note(got == expected, "étiquette de « \(name) » : « \(expected) » (lu « \(got) »)")
    }
    note(MoodleCourseAnalyzer.seriesNumber("Série 5a") == 5, "« Série 5a » est la série 5")
    note(SeriesIdentity.displayName(number: 5, label: "b") == "Série 5b"
         && SeriesIdentity.displayName(number: 5, label: "mardi") == "Série 5 · mardi"
         && SeriesIdentity.displayName(number: 5, label: "2") == "Série 5.2"
         && SeriesIdentity.displayName(number: 5, label: "") == "Série 5", "noms affichés")
    note([SeriesIdentity.Key(5, "jeudi"), SeriesIdentity.Key(5, "mardi"), SeriesIdentity.Key(4), SeriesIdentity.Key(5)].sorted()
         == [SeriesIdentity.Key(4), SeriesIdentity.Key(5), SeriesIdentity.Key(5, "mardi"), SeriesIdentity.Key(5, "jeudi")],
         "ordre : numéro, puis jours de la semaine")

    // MARK: Moodle
    let term = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 9, day: 7))!
    var nextID = 0
    func act(_ name: String, _ module: String = "resource") -> MoodleActivity {
        nextID += 1
        return MoodleActivity(id: "s\(nextID)", name: name, module: module,
                              url: "https://moodle.epfl.ch/mod/\(module)/view.php?id=\(9000 + nextID)")
    }
    let snapshot = MoodleCourseSnapshot(title: "Cours test", url: "https://moodle.epfl.ch/course/view.php?id=1", sections: [
        MoodleSection(number: 3, title: "Semaine 3", activities: [
            act("Exercices du mardi"), act("Exercices du jeudi"),
            act("Corrigé exercices du jeudi"), act("Corrigé exercices du mardi")]),
        MoodleSection(number: 4, title: "Semaine 4", activities: [
            act("Exercices — Suites"), act("Exercices — Intégrales"), act("Corrigé — Suites")]),
        MoodleSection(number: 5, title: "Semaine 5", activities: [
            act("Série 5a"), act("Série 5b"), act("Corrigé série 5b")]),
        MoodleSection(number: 6, title: "Semaine 6", activities: [act("Exercices"), act("Corrigé")]),
        MoodleSection(number: 7, title: "Semaine 7", activities: [act("Série 9"), act("Série 10")]),
    ])
    let draft = MoodleCourseAnalyzer.draft(from: snapshot, termStart: term)
    func series(week: Int) -> [ContentDraftItem] {
        draft.sections.filter { $0.week == week }.flatMap(\.items).filter { $0.kind == .series }
    }
    func url(_ item: ContentDraftItem?) -> String { item?.solutionURL ?? "-" }
    let w3 = series(week: 3)
    note(w3.map { "\($0.seriesNumber ?? 0)\($0.seriesLabel)" } == ["3mardi", "3jeudi"],
         "sans numéro : la semaine Moodle, et le jour départage (\(w3.map { "\($0.seriesNumber ?? 0)·\($0.seriesLabel)" }))")
    let corrigeMardi = snapshot.sections[0].activities[3].link, corrigeJeudi = snapshot.sections[0].activities[2].link
    note(url(w3.first) == corrigeMardi && url(w3.last) == corrigeJeudi, "chaque corrigé rejoint son jour")
    let w4 = series(week: 4)
    note(w4.map(\.seriesLabel) == ["1", "2"] && w4.allSatisfy { $0.seriesNumber == 4 },
         "deux énoncés sans numéro ni jour la même semaine : deux séries 4.1 et 4.2 (\(w4.map(\.seriesLabel)))")
    note(url(w4.first) == snapshot.sections[1].activities[2].link && w4.last?.solutionURL.isEmpty == true,
         "« Corrigé — Suites » va à « Exercices — Suites »")
    let w5 = series(week: 5)
    note(w5.map(\.seriesLabel) == ["a", "b"] && w5.map(\.title) == ["Série 5a", "Série 5b"], "« Série 5a » et « 5b » : deux séries")
    note(w5.first?.solutionURL.isEmpty == true && url(w5.last) == snapshot.sections[2].activities[2].link,
         "le corrigé de 5b ne va pas à 5a")
    let w6 = series(week: 6)
    note(w6.count == 1 && w6.first?.seriesNumber == 6 && w6.first?.seriesLabel == "" && !(w6.first?.solutionURL.isEmpty ?? true),
         "une seule série sans numéro : la série de sa semaine, avec son corrigé")
    let w7 = series(week: 7)
    note(w7.map { $0.seriesNumber ?? 0 } == [9, 10], "deux séries numérotées la même semaine restent 9 et 10")

    // MARK: Écriture : une série enregistrée sans étiquette n'est pas doublée
    let course = Course(code: "TST-200", name: "Deux séries", credits: 4)
    context.insert(course)
    let old = ExerciseSeries(course: course, seriesNumber: 5, plannedWeek: 5)
    context.insert(old)
    let oldExercise = Exercise(series: old, exerciseNumber: "5.1", title: "Ancien")
    oldExercise.doneAt = Date()
    context.insert(oldExercise)
    let only5 = ContentDraft(source: .moodle, courseTitle: "Cours test", url: "", sections: draft.sections.filter { $0.week == 5 })
    ContentDraftWriter.apply(only5, to: course, context: context)
    let after = course.sortedSeries.filter { $0.seriesNumber == 5 }
    note(after.map(\.label) == ["a", "b"], "une série 5 enregistrée devient 5a, 5b s'ajoute (\(after.map(\.label)))")
    note(after.first?.id == old.id && after.first?.title == "Série 5a" && after.first?.exercises.first?.isDone == true,
         "…en gardant son avancement")
    ContentDraftWriter.apply(only5, to: course, context: context)
    note(course.series.filter { $0.seriesNumber == 5 }.count == 2, "réimporter ne crée pas de double")
    let unnumbered = ContentDraft(source: .moodle, courseTitle: "Cours test", url: "", sections: draft.sections.filter { $0.week == 3 })
    ContentDraftWriter.apply(unnumbered, to: course, context: context)
    ContentDraftWriter.apply(unnumbered, to: course, context: context)
    note(course.sortedSeries.filter { $0.seriesNumber == 3 }.map(\.displayName) == ["Série 3 · mardi", "Série 3 · jeudi"],
         "sans numéro : retrouvées par semaine et jour au réimport")

    // Le brouillon : deux séries 5 sans étiquette sont un doublon, 5a et 5b non.
    let draft5b = SeriesDraft(number: 5, label: "b", title: "", plannedWeek: 5, exercises: [])
    note(draft5b.problems(taken: [SeriesIdentity.Key(5, "a")]).isEmpty, "5b à côté de 5a : pas un doublon")
    note(!SeriesDraft(number: 5, title: "", plannedWeek: 5, exercises: []).problems(taken: [SeriesIdentity.Key(5)]).isEmpty,
         "deux séries 5 sans étiquette : un doublon")
    let written = SeriesDraftWriter.write(SeriesDraft(number: 5, label: "b", title: "", plannedWeek: 5,
                                                      exercises: [ExerciseDraft(minor: "1", title: "Nouveau", isBonus: false)]),
                                          to: course, mode: .importMerge, context: context).series
    note(written.label == "b" && course.series(number: 5, label: "a")?.exercises.contains { $0.title == "Nouveau" } == false,
         "importer 5b n'écrit pas dans 5a")

    // MARK: Groupes : 5a et 5b ne se confondent pas
    let ex5a = course.series(number: 5, label: "a")?.sortedExercises.first
    let ex5b = written.sortedExercises.first
    note(ex5a?.groupNumber == "5a.1" && ex5b?.groupNumber == "5b.1", "numéros partagés : 5a.1 et 5b.1 (\(ex5a?.groupNumber ?? "-"), \(ex5b?.groupNumber ?? "-"))")
    let plain = Exercise(exerciseNumber: "3.2")
    note(plain.groupNumber == "3.2", "sans série étiquetée, le numéro partagé ne change pas")
    let boards = GroupSeriesEngine.boards(
        series: [GroupSeriesEngine.SeriesRef(number: 5, label: "a", title: "", plannedWeek: 5, required: ["5a.1"], bonus: []),
                 GroupSeriesEngine.SeriesRef(number: 5, label: "b", title: "", plannedWeek: 5, required: ["5b.1"], bonus: [])],
        members: [GroupSeriesEngine.MemberRef(userID: "u", displayName: "Camille", isMe: false)],
        itemsDone: [GroupSeriesEngine.ItemDone(userID: "u", number: "5b.1")],
        seriesDone: [GroupSeriesEngine.SeriesDone(userID: "u", seriesNumber: 5)],
        meID: nil)
    note(boards.map(\.displayName) == ["Série 5a", "Série 5b"]
         && boards.map { $0.rows.first?.isComplete ?? false } == [false, true],
         "groupe : 5b.1 fait ne coche pas 5a, et « série 5 terminée » ne vaut pour aucune des deux")

    // MARK: PDF : en-têtes « Série 5b », exercices sans numéro
    let twoInOne = SeriesLayoutParser.parse([
        layout("Série 5a — Suites", 16, bold: true), layout("Exercice 1", 13, bold: true), layout("Montrer que.", 11),
        layout("Exercice 2", 13, bold: true), layout("Calculer.", 11),
        layout("Série 5b — Séries", 16, bold: true, page: 1), layout("Exercice 1", 13, bold: true, page: 1), layout("Montrer.", 11, page: 1),
    ])
    note(twoInOne.map(\.label) == ["a", "b"] && twoInOne.map { $0.exercises.count } == [2, 1],
         "un PDF « Série 5a » puis « 5b » : deux séries, chacune ses exercices (\(twoInOne.map { "\($0.number)\($0.label):\($0.exercises.count)" }))")
    note(twoInOne.first?.title == "Suites", "le titre suit l'étiquette (« \(twoInOne.first?.title ?? "") »)")
    note(SeriesLayoutParser.seriesHeaderWithLabel("Série 5 à rendre le 12.10")?.label == "", "« Série 5 à rendre » n'a pas d'étiquette")

    let bare = SeriesLayoutParser.parse([
        layout("Série 4", 16, bold: true),
        layout("Exercice", 13, bold: true), layout("Montrer que la suite converge.", 11),
        layout("Exercice — Suites de Cauchy", 13, bold: true), layout("Soit (x_n) une suite.", 11),
        layout("Exercice (Rosen 1.2)", 13, bold: true), layout("Déterminer qui ment.", 11),
    ])
    note(bare.first?.exercises.map(\.number) == ["4.1", "4.2", "4.3"],
         "« Exercice » sans numéro : numérotés dans l'ordre (\(bare.first?.exercises.map(\.number) ?? []))")
    note(bare.first?.exercises.map(\.title) == ["", "Suites de Cauchy", "Rosen 1.2"],
         "…avec l'intitulé imprimé (\(bare.first?.exercises.map(\.title) ?? []))")
    let pageTitle = SeriesLayoutParser.parse([
        layout("Exercices", 16, bold: true), layout("Exercice 1", 13, bold: true), layout("Calculer.", 11),
        layout("Exercice 2", 13, bold: true), layout("Montrer.", 11),
    ])
    note(pageTitle.first?.exercises.map(\.number) == ["1.1", "1.2"], "un titre de page « Exercices » n'est pas un exercice")

    // MARK: Sous-questions sans étiquette (puces)
    func line(_ text: String, _ indent: Double, _ size: Double = 11, bold: Bool = false) -> PDFLayoutLine {
        PDFLayoutLine(text: text, fontSize: size, isBold: bold, indent: indent)
    }
    let bullets = SeriesLayoutParser.parse([
        line("Série 2", 16, 16, bold: true),
        line("Exercice 1", 40, 13, bold: true),
        line("Soit f : ℝ → ℝ définie par f(x) = x². Montrer :", 40),
        line("• f est continue en 0 ;", 60),
        line("• f est dérivable, et calculer f′ ;", 60),
        line("◦ en 0,", 80),
        line("◦ en un point quelconque ;", 80),
        line("• f est convexe.", 60),
        line("Exercice 2", 40, 13, bold: true),
        line("1) Calculer la limite.", 60),
        line("– à gauche ;", 80),
        line("– à droite.", 80),
        line("2) Conclure.", 60),
        line("Exercice 3", 40, 13, bold: true),
        line("On suppose que f satisfait les conditions suivantes :", 40),
        line("• f(0) = 0 ;", 60),
        line("• f est croissante.", 60),
        line("Montrer que f est positive.", 40),
    ])
    let ex = bullets.first?.exercises ?? []
    func tree(_ e: DetectedExercise?) -> String {
        (e?.subQuestions ?? []).filter { $0.kind == .question }
            .map { $0.label + ($0.children.isEmpty ? "" : "(" + $0.children.map(\.label).joined(separator: ",") + ")") }
            .joined(separator: " ")
    }
    note(tree(ex.first) == "1 2(a,b) 3", "puces : trois questions, deux points sous la 2ᵉ (« \(tree(ex.first)) »)")
    note(ex.first?.subQuestions.first { $0.label == "2" }?.text.hasPrefix("f est dérivable") == true, "le texte de la puce est gardé")
    note(ex.count > 1 && tree(ex[1]) == "1(a,b) 2", "puces sous des questions numérotées : leurs points (« \(ex.count > 1 ? tree(ex[1]) : "-") »)")
    note(ex.count > 2 && tree(ex[2]) == "", "une liste de conditions en puces n'est pas du travail (« \(ex.count > 2 ? tree(ex[2]) : "-") »)")

    // MARK: IA
    let ai = SeriesAIParsing.parse(#"{"series":[{"number":5,"label":"b","title":"Séries","exercises":[{"number":"5.1","title":"Critère"}]},{"number":"5a","title":"Suites","exercises":[{"number":"5.1","title":"Monotonie"}]}]}"#)
    note(ai.map(\.label) == ["a", "b"] && ai.allSatisfy { $0.number == 5 }, "IA : « label », et « 5a » écrit dans « number »")
    let merged = SeriesAIParsing.merge(heuristic: [DetectedSeries(number: 5, title: "", exercises: [], label: "b")],
                                       ai: [DetectedSeries(number: 5, title: "Séries", exercises: [DetectedExercise(number: "5.1", title: "Critère", isBonus: false)])])
    note(merged.count == 1 && merged.first?.label == "b", "l'étiquette lue en tête du PDF reste quand l'IA ne la voit pas")
    return results
}
