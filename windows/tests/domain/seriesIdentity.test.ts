// Port de Validation/SeriesIdentityTests.swift : deux séries par semaine, et des
// séries aux exercices sans numéro. Les noms ne viennent d'aucun cours en
// particulier : la lecture doit reconnaître le format.

import { describe, expect, it } from "vitest";
import { Course, Exercise, ExerciseSeries, ModelStore } from "../../src/models/index.ts";
import { ContentDraft } from "../../src/domain/courseContentImport.ts";
import { MoodleActivity, MoodleCourseAnalyzer, MoodleCourseSnapshot, MoodleSection } from "../../src/domain/moodleCourseAnalyzer.ts";
import { ContentDraftWriter } from "../../src/domain/courseContentWriter.ts";
import { ExerciseDraft, SeriesDraft, SeriesDraftWriter } from "../../src/domain/seriesDraft.ts";
import { SeriesIdentity } from "../../src/domain/seriesIdentity.ts";
import { PDFLayoutLine, SeriesLayoutParser } from "../../src/domain/seriesLayout.ts";
import { SeriesAIParsing } from "../../src/domain/seriesAIParsing.ts";

describe("Étiquette lue dans un nom", () => {
  const cases: [string, string][] = [
    ["Série 5a", "a"], ["Serie_05-B", "b"], ["Série 5 (b)", "b"], ["Série 05.pdf", ""],
    ["Série 5 à rendre", ""], ["Serie 5 a rendre", ""], ["Série 1 - exercices", ""], ["Série 1 (corrigé)", ""],
    ["Exercices du mardi", "mardi"], ["Exercises (Thursday)", "jeudi"],
    ["Série 3 — à rendre avant mardi", ""], ["Série 5.2", "2"], ["Série 5, partie 2", "partie 2"],
    ["Problem Set 2 - Part II", "partie 2"], ["Série A", "a"], ["Problem Set 1: Motion in 1D", ""], ["Série 10", ""],
  ];
  for (const [name, expected] of cases) {
    it(`« ${name} » → « ${expected} »`, () => { expect(SeriesIdentity.label(name)).toBe(expected); });
  }
  it("« Série 5a » est la série 5", () => { expect(MoodleCourseAnalyzer.seriesNumber("Série 5a")).toBe(5); });
  it("noms affichés", () => {
    expect([SeriesIdentity.displayName(5, "b"), SeriesIdentity.displayName(5, "mardi"), SeriesIdentity.displayName(5, "2"),
      SeriesIdentity.displayName(5)]).toEqual(["Série 5b", "Série 5 · mardi", "Série 5.2", "Série 5"]);
  });
  it("ordre : numéro, puis jours de la semaine", () => {
    const keys = [SeriesIdentity.key(5, "jeudi"), SeriesIdentity.key(5, "mardi"), SeriesIdentity.key(4), SeriesIdentity.key(5)];
    expect(keys.sort(SeriesIdentity.compare).map(SeriesIdentity.id)).toEqual(["4|", "5|", "5|mardi", "5|jeudi"]);
  });
});

describe("Moodle : deux séries par semaine, séries sans numéro", () => {
  let nextID = 0;
  const act = (name: string, module = "resource") => {
    nextID += 1;
    return new MoodleActivity({ id: `s${nextID}`, name, module, url: `https://moodle.epfl.ch/mod/${module}/view.php?id=${9000 + nextID}` });
  };
  const sections = [
    new MoodleSection({ number: 3, title: "Semaine 3", activities: [
      act("Exercices du mardi"), act("Exercices du jeudi"), act("Corrigé exercices du jeudi"), act("Corrigé exercices du mardi")] }),
    new MoodleSection({ number: 4, title: "Semaine 4", activities: [
      act("Exercices — Suites"), act("Exercices — Intégrales"), act("Corrigé — Suites")] }),
    new MoodleSection({ number: 5, title: "Semaine 5", activities: [act("Série 5a"), act("Série 5b"), act("Corrigé série 5b")] }),
    new MoodleSection({ number: 6, title: "Semaine 6", activities: [act("Exercices"), act("Corrigé")] }),
    new MoodleSection({ number: 7, title: "Semaine 7", activities: [act("Série 9"), act("Série 10")] }),
  ];
  const snapshot = new MoodleCourseSnapshot({ title: "Cours test", url: "https://moodle.epfl.ch/course/view.php?id=1", sections });
  const draft = MoodleCourseAnalyzer.draft(snapshot, new Date(2026, 8, 7));
  const series = (week: number) => draft.sections.filter((s) => s.week === week).flatMap((s) => s.items).filter((i) => i.kind === "series");

  it("sans numéro : la semaine Moodle, et le jour départage", () => {
    expect(series(3).map((i) => `${i.seriesNumber}${i.seriesLabel}`)).toEqual(["3mardi", "3jeudi"]);
  });
  it("chaque corrigé rejoint son jour", () => {
    expect(series(3).map((i) => i.solutionURL)).toEqual([sections[0].activities[3].link, sections[0].activities[2].link]);
  });
  it("deux énoncés sans numéro ni jour la même semaine : deux séries 4.1 et 4.2", () => {
    expect(series(4).map((i) => `${i.seriesNumber}.${i.seriesLabel}`)).toEqual(["4.1", "4.2"]);
  });
  it("« Corrigé — Suites » va à « Exercices — Suites »", () => {
    expect(series(4).map((i) => i.solutionURL)).toEqual([sections[1].activities[2].link, ""]);
  });
  it("« Série 5a » et « 5b » : deux séries, le corrigé de 5b ne va pas à 5a", () => {
    expect(series(5).map((i) => [i.seriesLabel, i.title, i.solutionURL]))
      .toEqual([["a", "Série 5a", ""], ["b", "Série 5b", sections[2].activities[2].link]]);
  });
  it("une seule série sans numéro : la série de sa semaine, avec son corrigé", () => {
    expect(series(6).map((i) => [i.seriesNumber, i.seriesLabel, i.solutionURL !== ""])).toEqual([[6, "", true]]);
  });
  it("deux séries numérotées la même semaine restent 9 et 10", () => {
    expect(series(7).map((i) => i.seriesNumber)).toEqual([9, 10]);
  });

  it("une série 5 enregistrée devient 5a, 5b s'ajoute, sans double au réimport", () => {
    const store = new ModelStore();
    const course = new Course({ code: "TST-200", name: "Deux séries" });
    store.insert(course);
    const old = new ExerciseSeries({ course, seriesNumber: 5, plannedWeek: 5 });
    store.insert(old);
    const oldExercise = new Exercise({ series: old, exerciseNumber: "5.1", title: "Ancien" });
    oldExercise.doneAt = new Date();
    store.insert(oldExercise);
    const only = (week: number) => new ContentDraft({ source: "moodle", courseTitle: "Cours test", url: "",
      sections: draft.clone().sections.filter((s) => s.week === week) });
    ContentDraftWriter.apply(only(5), course, store);
    const five = () => course.sortedSeries.filter((s) => s.seriesNumber === 5);
    expect(five().map((s) => s.label)).toEqual(["a", "b"]);
    expect(five()[0].id).toBe(old.id);
    expect(five()[0].title).toBe("Série 5a");
    expect(five()[0].exercises[0]?.doneAt).not.toBeNull();
    ContentDraftWriter.apply(only(5), course, store);
    expect(five().length).toBe(2);
    ContentDraftWriter.apply(only(3), course, store);
    ContentDraftWriter.apply(only(3), course, store);
    expect(course.sortedSeries.filter((s) => s.seriesNumber === 3).map((s) => s.displayName)).toEqual(["Série 3 · mardi", "Série 3 · jeudi"]);

    // Le brouillon : 5b à côté de 5a n'est pas un doublon, deux séries 5 sans étiquette si.
    expect(new SeriesDraft({ number: 5, label: "b", title: "", plannedWeek: 5, exercises: [] })
      .problems([SeriesIdentity.key(5, "a")])).toEqual([]);
    expect(new SeriesDraft({ number: 5, title: "", plannedWeek: 5, exercises: [] })
      .problems([SeriesIdentity.key(5)]).length).toBe(1);
    const written = SeriesDraftWriter.write(new SeriesDraft({ number: 5, label: "b", title: "", plannedWeek: 5,
      exercises: [new ExerciseDraft({ minor: "1", title: "Nouveau", isBonus: false })] }), course, "importMerge", store).series;
    expect(written.label).toBe("b");
    expect(course.seriesWith(5, "a")?.exercises.some((e) => e.title === "Nouveau")).toBe(false);
  });
});

describe("PDF : en-têtes « Série 5b », exercices sans numéro", () => {
  const layout = (text: string, size: number, bold = false, page = 0) =>
    PDFLayoutLine.make(text, { fontSize: size, isBold: bold, pageIndex: page });

  it("un PDF « Série 5a » puis « 5b » : deux séries, chacune ses exercices", () => {
    const parsed = SeriesLayoutParser.parse([
      layout("Série 5a — Suites", 16, true), layout("Exercice 1", 13, true), layout("Montrer que.", 11),
      layout("Exercice 2", 13, true), layout("Calculer.", 11),
      layout("Série 5b — Séries", 16, true, 1), layout("Exercice 1", 13, true, 1), layout("Montrer.", 11, false, 1),
    ]);
    expect(parsed.map((s) => [s.number, s.label, s.exercises.length, s.title])).toEqual([[5, "a", 2, "Suites"], [5, "b", 1, "Séries"]]);
  });
  it("« Exercice » sans numéro : numérotés dans l'ordre, avec l'intitulé imprimé", () => {
    const parsed = SeriesLayoutParser.parse([
      layout("Série 4", 16, true),
      layout("Exercice", 13, true), layout("Montrer que la suite converge.", 11),
      layout("Exercice — Suites de Cauchy", 13, true), layout("Soit (x_n) une suite.", 11),
      layout("Exercice (Rosen 1.2)", 13, true), layout("Déterminer qui ment.", 11),
    ]);
    expect(parsed[0]?.exercises.map((e) => [e.number, e.title])).toEqual([["4.1", ""], ["4.2", "Suites de Cauchy"], ["4.3", "Rosen 1.2"]]);
  });
  it("un titre de page « Exercices » n'est pas un exercice", () => {
    const parsed = SeriesLayoutParser.parse([
      layout("Exercices", 16, true), layout("Exercice 1", 13, true), layout("Calculer.", 11),
      layout("Exercice 2", 13, true), layout("Montrer.", 11),
    ]);
    expect(parsed[0]?.exercises.map((e) => e.number)).toEqual(["1.1", "1.2"]);
  });
});

describe("IA : l'étiquette des séries", () => {
  it("« label », et « 5a » écrit dans « number »", () => {
    const ai = SeriesAIParsing.parse(`{"series":[{"number":5,"label":"b","title":"Séries","exercises":[{"number":"5.1","title":"Critère"}]},{"number":"5a","title":"Suites","exercises":[{"number":"5.1","title":"Monotonie"}]}]}`);
    expect(ai.map((s) => [s.number, s.label])).toEqual([[5, "a"], [5, "b"]]);
  });
  it("l'étiquette lue en tête du PDF reste quand l'IA ne la voit pas", () => {
    const merged = SeriesAIParsing.merge([{ number: 5, label: "b", title: "", exercises: [] }],
      [{ number: 5, title: "Séries", exercises: [{ number: "5.1", title: "Critère", isBonus: false, statement: "", subQuestions: [], isConfident: true }] }]);
    expect(merged.map((s) => s.label)).toEqual(["b"]);
  });
});

describe("Sous-questions sans étiquette (puces)", () => {
  const line = (text: string, indent: number, size = 11, bold = false) =>
    PDFLayoutLine.make(text, { fontSize: size, isBold: bold, indent });
  const parsed = SeriesLayoutParser.parse([
    line("Série 2", 16, 16, true),
    line("Exercice 1", 40, 13, true),
    line("Soit f : ℝ → ℝ définie par f(x) = x². Montrer :", 40),
    line("• f est continue en 0 ;", 60),
    line("• f est dérivable, et calculer f′ ;", 60),
    line("◦ en 0,", 80),
    line("◦ en un point quelconque ;", 80),
    line("• f est convexe.", 60),
    line("Exercice 2", 40, 13, true),
    line("1) Calculer la limite.", 60),
    line("– à gauche ;", 80),
    line("– à droite.", 80),
    line("2) Conclure.", 60),
    line("Exercice 3", 40, 13, true),
    line("On suppose que f satisfait les conditions suivantes :", 40),
    line("• f(0) = 0 ;", 60),
    line("• f est croissante.", 60),
    line("Montrer que f est positive.", 40),
  ]);
  const ex = parsed[0]?.exercises ?? [];
  const tree = (i: number) => (ex[i]?.subQuestions ?? []).filter((q) => q.kind === "question")
    .map((q) => q.label + (q.children.length === 0 ? "" : `(${q.children.map((c) => c.label).join(",")})`)).join(" ");
  it("puces : trois questions, deux points sous la 2ᵉ", () => { expect(tree(0)).toBe("1 2(a,b) 3"); });
  it("le texte de la puce est gardé", () => {
    expect(ex[0]?.subQuestions.find((q) => q.label === "2")?.text.startsWith("f est dérivable")).toBe(true);
  });
  it("puces sous des questions numérotées : leurs points", () => { expect(tree(1)).toBe("1(a,b) 2"); });
  it("une liste de conditions en puces n'est pas du travail", () => { expect(tree(2)).toBe(""); });
});
