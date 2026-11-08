// Port des sections de Validation/main.swift qui exercent les fichiers de la
// série : lecture de la réponse d'un modèle, ordre des moteurs, exercice par
// exercice, brouillons, import PDF (ce que le document dit de lui-même), rapport
// et file de reprise, pages HTML. Un `it` par check Swift, le libellé du check
// pour nom.

import { describe, expect, it } from "vitest";
import { SeriesIdentity } from "../../src/domain/seriesIdentity.ts";

import {
  SeriesAIParsing, layoutBudget, maxCharacters, prepare, prepareLayout,
} from "../../src/domain/seriesAIParsing.ts";
import { SeriesDocumentInference } from "../../src/domain/seriesDocumentInference.ts";
import { SeriesEngineKind, SeriesEngineOrder } from "../../src/domain/seriesEngineOrder.ts";
import {
  ExerciseFlow, ExerciseStage,
} from "../../src/domain/exerciseFlow.ts";
import {
  ExerciseDraft, SeriesDraft, SeriesDraftWriter, SubQuestionTree,
} from "../../src/domain/seriesDraft.ts";
import {
  RedoLadder, SeriesReview,
} from "../../src/domain/seriesReview.ts";
import { SeriesPageParser } from "../../src/domain/seriesPageParser.ts";
import {
  PDFLayoutLine, SeriesLayoutParser,
} from "../../src/domain/seriesLayout.ts";
import {
  DetectedExercise, DetectedSubQuestion,
} from "../../src/services/seriesPDFParser.ts";
import { Course } from "../../src/models/course.ts";
import { Exercise, ExerciseSeries, SubQuestion } from "../../src/models/exercise.ts";
import { StudySession } from "../../src/models/studySession.ts";
import { characters } from "../../src/domain/textRepair.ts";

const numbers = (series: { exercises: { number: string }[] } | null | undefined) =>
  series?.exercises.map((exercise) => exercise.number);

const exercise = (number: string, o: Partial<{
  title: string; isBonus: boolean; isConfident: boolean; subQuestions: ReturnType<typeof DetectedSubQuestion.make>[];
}> = {}) => DetectedExercise.make({
  number,
  title: o.title ?? "",
  isBonus: o.isBonus ?? false,
  isConfident: o.isConfident ?? true,
  subQuestions: o.subQuestions ?? [],
});

describe("Lecture de la réponse d'un modèle", () => {
  // Le cas réel : un PDF dont les exercices sont numérotés 1,2,3 dans chaque section,
  // sans intitulé individuel. Le modèle renvoie des titres qu'il a lui-même écrits.
  const realAnswer = `{"series":[{"number":2,"title":"Sommes, bornes et densité","exercises":[
{"number":"2.1","title":"Inégalité des suprema","isBonus":false},
{"number":"2.2","title":"Suite d'intervalles ouverts","isBonus":false},
{"number":"2.5","title":"Infimum de ⌊x⌋ + ⌊x−1⌋","isBonus":false}]}]}`;
  const parsedReal = SeriesAIParsing.parse(realAnswer);

  it("une série lue (1)", () => { expect(parsedReal.length).toBe(1); });
  it("numéro de série entier", () => { expect(parsedReal[0]?.number).toBe(2); });
  it("titre de série conservé", () => { expect(parsedReal[0]?.title).toBe("Sommes, bornes et densité"); });
  it("trois exercices", () => { expect(parsedReal[0]?.exercises.length).toBe(3); });
  it("numéro qualifié par la série — 2.1", () => { expect(parsedReal[0]?.exercises[0]?.number).toBe("2.1"); });
  it("titre français conservé", () => { expect(parsedReal[0]?.exercises[0]?.title).toBe("Inégalité des suprema"); });

  // Les formes que le modèle peut produire et qui faisaient tout échouer.
  const messyAnswer = `{"series":[{"number":"02a","title":"Sommes","exercises":[
{"number":3,"title":"Trois","isBonus":"oui"},
{"number":"2.4","title":"Quatre","isBonus":"non"}]}]}`;
  const parsedMessy = SeriesAIParsing.parse(messyAnswer);

  it("« number » en texte « 02a » ne fait plus perdre la série (1)", () => {
    expect(parsedMessy.length).toBe(1);
  });
  it("…et donne 2", () => { expect(parsedMessy[0]?.number).toBe(2); });
  it("les deux exercices survivent", () => { expect(parsedMessy[0]?.exercises.length).toBe(2); });
  it("un numéro écrit en nombre est qualifié — 2.3", () => {
    expect(parsedMessy[0]?.exercises[0]?.number).toBe("2.3");
  });
  it("« oui » vaut true", () => { expect(parsedMessy[0]?.exercises[0]?.isBonus).toBe(true); });
  it("« non » vaut false", () => { expect(parsedMessy[0]?.exercises[1]?.isBonus).toBe(false); });

  // Un exercice sans numéro reçoit le suivant dans l'ordre.
  const unnumbered = `{"series":[{"number":5,"title":"Densité","exercises":[
{"title":"Un"},{"title":"Deux"}]}]}`;
  const parsedUnnumbered = SeriesAIParsing.parse(unnumbered);

  it("un exercice sans numéro n'est pas jeté (2)", () => {
    expect(parsedUnnumbered[0]?.exercises.length).toBe(2);
  });
  it("…il reçoit le numéro suivant — 5.1,5.2", () => {
    expect(parsedUnnumbered[0]?.exercises.map((item) => item.number)).toEqual(["5.1", "5.2"]);
  });
  it("…et garde son titre", () => { expect(parsedUnnumbered[0]?.exercises[0]?.title).toBe("Un"); });

  // Une liste d'exercices absente ne doit pas faire perdre la série.
  const parsedEmpty = SeriesAIParsing.parse(`{"series":[{"number":7,"title":"Vide"}]}`);
  it("une série sans exercices reste une série", () => {
    expect(parsedEmpty.length === 1 && parsedEmpty[0]?.exercises.length === 0).toBe(true);
  });

  it("sans JSON, rien", () => { expect(SeriesAIParsing.parse("pas de json")).toEqual([]); });
  it("liste vide", () => { expect(SeriesAIParsing.parse(`{"series":[]}`)).toEqual([]); });
  it("un numéro de série hors bornes est refusé", () => {
    expect(SeriesAIParsing.parse(`{"series":[{"number":99,"title":"Trop grand"}]}`)).toEqual([]);
  });

  it("un numéro nu est préfixé par la série", () => {
    expect(SeriesAIParsing.normalizeNumber("1", 2)).toBe("2.1");
  });
  it("un numéro déjà qualifié reste", () => {
    expect(SeriesAIParsing.normalizeNumber("2.3", 2)).toBe("2.3");
  });
  it("la série de l'objet parent fait foi", () => {
    expect(SeriesAIParsing.normalizeNumber("Ex 3.2", 2)).toBe("2.2");
  });
  it("« 02a » se lit 2 — cas réel d'un en-tête de série EPFL", () => {
    expect(SeriesAIParsing.normalizeNumber("02a", 2)).toBe("2.2");
  });
  it("un numéro vide ne donne rien", () => { expect(SeriesAIParsing.normalizeNumber("", 2)).toBeNull(); });
  it("un numéro absent non plus", () => { expect(SeriesAIParsing.normalizeNumber(null, 2)).toBeNull(); });
});

describe("Ordre des moteurs d'analyse", () => {
  const engines = (shared: boolean, device: boolean) =>
    SeriesEngineOrder.engines(shared, device).map((kind) => kind);

  it("le service passé avant le modèle embarqué — shared,onDevice", () => {
    expect(engines(true, true)).toEqual(["shared", "onDevice"]);
  });
  it("sans fonction déployée, le modèle embarqué prend le relais", () => {
    expect(engines(false, true)).toEqual(["onDevice"]);
  });
  it("aucun moteur : la lecture par motifs seule", () => {
    expect(engines(false, false)).toEqual([]);
  });
  it("le service seul suffit", () => { expect(engines(true, false)).toEqual(["shared"]); });
  it("les libellés des moteurs", () => {
    expect(SeriesEngineKind.label("shared")).toBe("IA Polymestre");
    expect(SeriesEngineKind.label("onDevice")).toBe("IA sur l'appareil");
  });
});

describe("Exercice par exercice", () => {
  const flowSeries = new ExerciseSeries({ seriesNumber: 9 });
  const e1 = new Exercise({ series: flowSeries, exerciseNumber: "9.1", sortOrder: 0 });
  const e2 = new Exercise({ series: flowSeries, exerciseNumber: "9.2", sortOrder: 1 });
  const e3 = new Exercise({ series: flowSeries, exerciseNumber: "9.3", isBonus: true, sortOrder: 2 });
  const e4 = new Exercise({ series: flowSeries, exerciseNumber: "9.4", sortOrder: 3 });
  const all = [e1, e2, e3, e4];

  it("rien de coché : à faire", () => {
    expect(ExerciseStage(e1)).toEqual({ kind: "toDo" });
  });
  it("on reprend au premier exercice", () => { expect(ExerciseFlow.resumePoint(all)?.id).toBe(e1.id); });

  it("cocher ne donne aucune couleur : la couleur est celle de la correction", () => {
    e1.setDone(true);
    expect(e1.correctness).toBeNull();
  });
  it("fait : à corriger", () => { expect(ExerciseStage(e1)).toEqual({ kind: "toCorrect" }); });
  it("puis au suivant pas fait", () => { expect(ExerciseFlow.resumePoint(all)?.id).toBe(e2.id); });

  it("corrigé orange", () => {
    e1.correct("partial");
    expect(ExerciseStage(e1)).toEqual({ kind: "corrected", correctness: "partial" });
    expect(e1.redoRequired).toBe(false);
  });

  it("retirer la correction revient à « à corriger »", () => {
    e1.clearCorrection();
    expect(ExerciseStage(e1)).toEqual({ kind: "toCorrect" });
  });

  it("corrigé faux : à refaire, et c'est ce qui s'affiche", () => {
    e1.correct("wrong");
    expect(e1.redoRequired).toBe(true);
    expect(ExerciseStage(e1)).toEqual({ kind: "redo" });
  });

  it("refait juste : le « à refaire » tombe", () => {
    e1.correct("correct");
    expect(e1.redoRequired).toBe(false);
    expect(ExerciseStage(e1)).toEqual({ kind: "corrected", correctness: "correct" });
  });

  it("les bonus passent après les obligatoires", () => {
    e2.setDone(true);
    e4.setDone(true);
    expect(ExerciseFlow.resumePoint(all)?.id).toBe(e3.id);
  });

  it("…et après ce qui est à refaire", () => {
    e4.redoRequired = true;
    expect(ExerciseFlow.resumePoint(all)?.id).toBe(e4.id);
  });

  it("« Suivant » saute les exercices déjà faits", () => {
    e4.redoRequired = false;
    expect(ExerciseFlow.next(e1, all)?.id).toBe(e3.id);
  });
  it("fin de série : pas de suivant", () => { expect(ExerciseFlow.next(e4, all)).toBeNull(); });

  it("décocher efface la correction", () => {
    e2.correct("correct");
    e2.setDone(false);
    expect(e2.correctness).toBeNull();
    expect(e2.isDone).toBe(false);
  });

  it("corriger un exercice le marque fait", () => {
    const e5 = new Exercise({ series: flowSeries, exerciseNumber: "9.5", sortOrder: 4 });
    e5.correct("correct");
    expect(e5.isDone).toBe(true);
    expect(ExerciseStage(e5)).toEqual({ kind: "corrected", correctness: "correct" });
  });

  const sub1 = new SubQuestion({ exercise: e2, label: "a", sortOrder: 0 });
  const sub2 = new SubQuestion({ exercise: e2, label: "b", sortOrder: 1 });
  it("une question sur deux : en cours, 1/2", () => {
    e2.subQuestions = [sub1, sub2];
    sub1.toggle();
    expect(ExerciseStage(e2)).toEqual({ kind: "inProgress", done: 1, total: 2 });
  });
  it("…et c'est ce que dit la ligne", () => { expect(ExerciseStage.label(ExerciseStage(e2))).toBe("1/2"); });

  const session = new StudySession({ taskType: "exercise", durationSeconds: 1200, exercise: e1 });
  it("temps d'un exercice : sessions + chrono en cours", () => {
    expect(ExerciseFlow.seconds(e1, 30)).toBe(1230);
  });
  it("temps d'une série", () => { expect(ExerciseFlow.seconds(flowSeries)).toBe(1200); });
  void session;
});

describe("Brouillons de série : plan rapide, gestes sur l'arbre, enregistrement", () => {
  const Tree = SubQuestionTree;
  const plan = (text: string): string => {
    const parsed = Tree.parse(text);
    return parsed === null ? "illisible" : Tree.outline(parsed);
  };

  it("plan lu et réécrit à l'identique — 1(a-d) 2(a-e) 3", () => {
    expect(plan("1(a-d) 2(a-e) 3")).toBe("1(a-d) 2(a-e) 3");
  });
  it("plage de questions", () => {
    expect(Tree.parse("1-4")?.map((question) => question.label)).toEqual(["1", "2", "3", "4"]);
  });
  it("liste de points", () => {
    expect(Tree.parse("1(a,b) 2")?.[0]?.children.map((child) => child.label)).toEqual(["a", "b"]);
  });
  it("plage romaine", () => {
    expect(Tree.parse("i-iv")?.map((question) => question.label)).toEqual(["i", "ii", "iii", "iv"]);
  });
  it("parties sans numéro", () => {
    expect(Tree.parse("+ 1 2 +")?.map((question) => question.kind)).toEqual(["part", "question", "question", "part"]);
  });
  it("parenthèse non fermée : illisible", () => { expect(Tree.parse("1(a-")).toBeNull(); });
  it("deux points restent écrits en liste", () => { expect(plan("1(a,b)")).toBe("1(a,b)"); });

  const kept = Tree.parse("1(a-b)", [
    DetectedSubQuestion.make("1", { text: "Soit x", children: [DetectedSubQuestion.make("a", { text: "borne" })] }),
  ]);
  it("réécrire le plan garde les énoncés déjà saisis", () => {
    expect(kept?.[0]?.text).toBe("Soit x");
    expect(kept?.[0]?.children[0]?.text).toBe("borne");
  });

  const tree = Tree.parse("1 2 3")!;
  const two = tree[1].id;
  it("« 2 » devient un point de « 1 » — 1(2) 3", () => {
    Tree.indent(two, tree);
    expect(Tree.outline(tree)).toBe("1(2) 3");
  });
  it("…et remonte à sa place — 1 2 3", () => {
    Tree.outdent(two, tree);
    expect(Tree.outline(tree)).toBe("1 2 3");
  });
  it("points ajoutés a, b — 1(a,b) 2 3", () => {
    Tree.addChild(tree[0].id, tree);
    Tree.addChild(tree[0].id, tree);
    expect(Tree.outline(tree)).toBe("1(a,b) 2 3");
  });
  it("renumérotation — 1(a) 2 3", () => {
    Tree.remove(tree[0].children[0].id, tree);
    Tree.relabel(tree);
    expect(Tree.outline(tree)).toBe("1(a) 2 3");
  });
  it("affichage à plat avec profondeur", () => {
    expect(Tree.rows(tree).map((row) => row.depth)).toEqual([0, 1, 0, 0]);
  });
  it("seule une question précédée d'une autre peut devenir un point", () => {
    expect(Tree.rows(tree)[2].canIndent).toBe(true);
    expect(Tree.rows(tree)[0].canIndent).toBe(false);
  });

  // Problèmes signalés avant d'enregistrer.
  const draft = new SeriesDraft({ number: 5, title: "", plannedWeek: 5, exercises: [] });
  it("exercices ajoutés 5.1, 5.2", () => {
    draft.addExercise();
    draft.addExercise();
    expect(draft.exercises.map((item) => item.minor)).toEqual(["1", "2"]);
  });
  it("numéro en double signalé", () => {
    draft.exercises[1].minor = "1";
    expect(draft.problems([]).some((problem) => problem.includes("5.1"))).toBe(true);
  });
  it("série en double signalée", () => {
    expect(draft.problems([SeriesIdentity.key(5)]).some((problem) => problem.includes("série 5"))).toBe(true);
  });
  it("renuméroter corrige", () => {
    draft.renumberExercises();
    expect(draft.problems([])).toEqual([]);
  });

  // Modification : renuméroter garde l'avancement, retirer supprime.
  const draftCourse = new Course({ code: "TST-100", name: "Test", credits: 4 });
  let written: ReturnType<typeof SeriesDraftWriter.write>;
  it("série créée avec trois exercices", () => {
    written = SeriesDraftWriter.write(new SeriesDraft({
      number: 2,
      title: "Suites",
      plannedWeek: 2,
      exercises: [
        new ExerciseDraft({ minor: "1", title: "", isBonus: false, subQuestions: Tree.parse("1(a-b) 2")! }),
        new ExerciseDraft({ minor: "2", title: "", isBonus: false }),
        new ExerciseDraft({ minor: "3", title: "", isBonus: true }),
      ],
    }), draftCourse, "edit", null);
    expect(written.outcome.created).toBe(3);
    expect(written.series.exercises.length).toBe(3);
  });
  it("questions créées avec l'exercice", () => {
    expect(written!.series.sortedExercises[0]?.subQuestionLabel).toBe("0/3");
  });

  let edit: SeriesDraft;
  it("le brouillon relit la série", () => {
    written!.series.sortedExercises[0].sortedSubQuestions[0].sortedChildren[0].toggle();
    written!.series.sortedExercises[1].doneAt = new Date();
    edit = SeriesDraft.fromSeries(written!.series);
    expect(edit.title).toBe("Suites");
    expect(edit.exercises.length).toBe(3);
  });

  let second: ReturnType<typeof SeriesDraftWriter.write>;
  it("l'exercice retiré est supprimé", () => {
    edit.exercises.splice(2, 1);
    [edit.exercises[0], edit.exercises[1]] = [edit.exercises[1], edit.exercises[0]];
    edit.renumberExercises();
    second = SeriesDraftWriter.write(edit, draftCourse, "edit", null);
    expect(second.outcome.deleted).toBe(1);
    expect(second.series.exercises.length).toBe(2);
  });
  it("renumérotés dans le nouvel ordre", () => {
    expect(second!.series.sortedExercises.map((item) => item.exerciseNumber)).toEqual(["2.1", "2.2"]);
  });
  it("l'ancien 2.2, devenu 2.1, garde son « fait »", () => {
    expect(second!.series.sortedExercises[0].isDone).toBe(true);
  });
  it("l'ancien 2.1, devenu 2.2, garde ses cases cochées — 1/3", () => {
    expect(second!.series.sortedExercises[1].subQuestionLabel).toBe("1/3");
  });

  // Import : ne supprime jamais, met à jour par numéro.
  let merged: ReturnType<typeof SeriesDraftWriter.write>;
  let relu: Exercise | undefined;
  it("import : un mis à jour, un créé, aucun supprimé — created 1, updated 1, deleted 0", () => {
    merged = SeriesDraftWriter.write(new SeriesDraft({
      number: 2,
      title: "",
      plannedWeek: 2,
      exercises: [
        new ExerciseDraft({ minor: "2", title: "Relu", isBonus: false, subQuestions: Tree.parse("1(a-c) 2")! }),
        new ExerciseDraft({ minor: "4", title: "", isBonus: false }),
      ],
    }), draftCourse, "importMerge", null);
    expect(merged.outcome).toEqual({ created: 1, updated: 1, deleted: 0 });
  });
  it("un titre vide à l'import ne l'efface pas", () => { expect(merged!.series.title).toBe("Suites"); });
  it("arbre remplacé, case 1.a conservée — 1/4", () => {
    relu = merged!.series.exercises.find((item) => item.exerciseNumber === "2.2");
    expect(relu?.title).toBe("Relu");
    expect(relu?.subQuestionLabel).toBe("1/4");
  });
  it("un import sans énoncé n'efface pas celui qui existe", () => {
    relu!.statement = "Montrer la borne";
    const noStatement = SeriesDraft.fromSeries(merged!.series);
    for (const item of noStatement.exercises) item.statement = "";
    SeriesDraftWriter.write(noStatement, draftCourse, "importMerge", null);
    expect(relu?.statement).toBe("Montrer la borne");
  });
  it("…mais le vider à la main, si", () => {
    const noStatement = SeriesDraft.fromSeries(merged!.series);
    for (const item of noStatement.exercises) item.statement = "";
    SeriesDraftWriter.write(noStatement, draftCourse, "edit", null);
    expect(relu?.statement).toBe("");
  });
});

describe("SeriesAIParsing : lecture de la réponse d'un modèle", () => {
  const answer = `Voici le résultat : \`\`\`json
{"series":[{"number":3,"title":"Récurrences","exercises":[
  {"number":"3.1","title":"Tri fusion","isBonus":false},
  {"number":"2","title":"","isBonus":true},
  {"number":"Ex 3.1","title":"doublon","isBonus":false},
  {"number":"abc","title":"","isBonus":false},
  {"number":"3.3","title":"Montrer que pour tout n, la suite converge vers la limite attendue, en détaillant chaque étape.","isBonus":false}
]},{"number":0,"exercises":[]},{"number":3,"exercises":[{"number":"3.4","title":"","isBonus":false}]}]}
\`\`\``;
  const parsed = SeriesAIParsing.parse(answer);

  it("une série (le numéro 0 est rejeté, la répétition fusionnée) (1)", () => {
    expect(parsed.length).toBe(1);
  });
  it("série 3 « Récurrences »", () => {
    expect(parsed[0]?.number).toBe(3);
    expect(parsed[0]?.title).toBe("Récurrences");
  });
  it("numéros normalisés et dédoublonnés : 3.1,3.2,3.3,3.4", () => {
    expect(numbers(parsed[0])).toEqual(["3.1", "3.2", "3.3", "3.4"]);
  });
  it("« 2 » dans la série 3 → 3.2, bonus", () => {
    expect(parsed[0]?.exercises.find((item) => item.number === "3.2")?.isBonus).toBe(true);
  });
  it("un énoncé n'est pas pris pour un titre", () => {
    expect(parsed[0]?.exercises.find((item) => item.number === "3.3")?.title).toBe("");
  });
  it("l'intitulé court est gardé", () => {
    expect(parsed[0]?.exercises.find((item) => item.number === "3.1")?.title).toBe("Tri fusion");
  });
  it("sans JSON : rien", () => { expect(SeriesAIParsing.parse("pas de json")).toEqual([]); });
  it("liste vide : rien", () => { expect(SeriesAIParsing.parse(`{"series":[]}`)).toEqual([]); });
  it("un numéro d'une autre série suit la série parente", () => {
    expect(SeriesAIParsing.normalizeNumber("4.2", 3)).toBe("3.2");
  });
  it("trois niveaux : refusé", () => { expect(SeriesAIParsing.normalizeNumber("1.2.3", 1)).toBeNull(); });

  // Fusion : le modèle complète, ne retire jamais.
  const heuristic = [{
    number: 3,
    title: "",
    exercises: [
      exercise("3.1"),
      exercise("3.5", { title: "Vu par les motifs seulement" }),
    ],
  }];
  const merged = SeriesAIParsing.merge(heuristic, parsed);
  it("fusion : le titre de série vient du modèle", () => {
    expect(merged.length).toBe(1);
    expect(merged[0].title).toBe("Récurrences");
  });
  it("fusion : union triée (3.1,3.2,3.3,3.4,3.5)", () => {
    expect(numbers(merged[0])).toEqual(["3.1", "3.2", "3.3", "3.4", "3.5"]);
  });
  it("fusion : l'intitulé manquant est complété", () => {
    expect(merged[0].exercises.find((item) => item.number === "3.1")?.title).toBe("Tri fusion");
  });
  it("fusion : rien de l'heuristique n'est perdu", () => {
    expect(merged[0].exercises.find((item) => item.number === "3.5")?.title).toBe("Vu par les motifs seulement");
  });
  it("fusion avec réponse vide : heuristique inchangée", () => {
    expect(SeriesAIParsing.merge(heuristic, [])).toBe(heuristic);
  });

  // Préparation : un long texte est réduit à ses lignes structurantes.
  const noise = "Soit f une fonction continue sur un intervalle fermé borné.\n".repeat(400);
  const long = "Série 4\n" + noise + "Exercice 4.1 Théorème des valeurs intermédiaires\nMontrer que…\n" + noise;
  const prepared = prepare(long);
  it("texte long (plus de 7000 car.)", () => { expect(characters(long).length).toBeGreaterThan(maxCharacters); });
  it("préparé sous la limite (7000 car.)", () => {
    expect(characters(prepared).length).toBeLessThanOrEqual(maxCharacters);
  });
  it("les en-têtes survivent", () => {
    expect(prepared.includes("Série 4")).toBe(true);
    expect(prepared.includes("Exercice 4.1")).toBe(true);
  });
  it("la ligne suivant un exercice survit (intitulé possible)", () => {
    expect(prepared.includes("Montrer que…")).toBe(true);
  });
  it("le bruit répété est retiré", () => {
    expect(prepared.includes("intervalle fermé borné.\nSoit f")).toBe(false);
  });
  it("un texte court passe tel quel", () => { expect(prepare("court")).toBe("court"); });
});

describe("Import PDF : ce que le document dit de lui-même", () => {
  const line = (text: string, size = 11, o: { bold?: boolean; page?: number; indent?: number; startsBold?: boolean } = {}) =>
    PDFLayoutLine.make(text, {
      fontSize: size,
      isBold: o.bold ?? false,
      pageIndex: o.page ?? 0,
      indent: o.indent ?? 60,
      startsBold: o.startsBold ?? false,
    });

  // La série n'est pas toujours en début de ligne : c'était la cause de tout
  // un PDF rangé en « série 1 ».
  const header = [line("EPFL — Analyse I — Série 4", 9), line("Automne 2026", 9), line("Exercice 1", 13)];
  it("« … — Série 4 » en en-tête : série 4", () => {
    expect(SeriesDocumentInference.seriesNumberInDocument(header)).toBe(4);
  });
  it("« Exercise Set 5 » : série 5", () => {
    expect(SeriesDocumentInference.seriesNumberInDocument([line("Exercise Set 5", 14)])).toBe(5);
  });
  it("« Problem Sheet 02 » : série 2", () => {
    expect(SeriesDocumentInference.seriesNumberInDocument([line("Problem Sheet 02", 14)])).toBe(2);
  });
  it("« série de Taylor » n'est pas un numéro", () => {
    expect(SeriesDocumentInference.seriesNumberInDocument([line("Série de Taylor", 11)])).toBeNull();
  });
  it("nom de fichier « serie03_sol » : 3", () => {
    expect(SeriesDocumentInference.seriesNumberInFilename("serie03_sol.pdf")).toBe(3);
  });
  it("nom de fichier « Series_4 » : 4", () => {
    expect(SeriesDocumentInference.seriesNumberInFilename("Series_4.pdf")).toBe(4);
  });
  it("nom de fichier « ex7 » : 7", () => {
    expect(SeriesDocumentInference.seriesNumberInFilename("ex7.pdf")).toBe(7);
  });
  it("un code de cours n'est pas un numéro de série", () => {
    expect(SeriesDocumentInference.seriesNumberInFilename("cs250-notes.pdf")).toBeNull();
  });
  it("le document l'emporte sur le nom du fichier", () => {
    expect(SeriesDocumentInference.seriesNumber(header, "serie09.pdf")?.number).toBe(4);
  });

  // Le cours désigné par le PDF.
  const cs = { id: "cs-id", code: "CS-250", name: "Algorithms I" };
  const math = { id: "math-id", code: "MATH-101", name: "Analyse I" };
  it("« Analyse I » dans l'en-tête : MATH-101", () => {
    expect(SeriesDocumentInference.course(header, null, [cs, math])).toBe("math-id");
  });
  it("« cs250 » dans le nom de fichier : CS-250", () => {
    expect(SeriesDocumentInference.course([], "cs250_serie2.pdf", [cs, math])).toBe("cs-id");
  });
  it("aucun indice : on ne choisit pas à la place de l'étudiant·e", () => {
    expect(SeriesDocumentInference.course([line("Série 3", 14)], "s3.pdf", [cs, math])).toBeNull();
  });

  // Fusion : une seule série, même quand les deux côtés ne s'accordent pas.
  const heuristicOne = [{
    number: 1,
    title: "",
    exercises: [
      exercise("1.1"),
      exercise("1.2", { isBonus: true }),
      exercise("1.5", { isConfident: false }),
    ],
  }];
  const aiFour = [{
    number: 4,
    title: "Intégrales",
    exercises: [
      exercise("4.1", { title: "Changement de variable" }),
      exercise("4.2", { title: "Intégrale impropre" }),
      exercise("4.3", { title: "Fubini" }),
    ],
  }];
  const reconciled = SeriesAIParsing.merge(heuristicOne, aiFour, 4);
  it("une seule série, la 4 — 4", () => {
    expect(reconciled.length).toBe(1);
    expect(reconciled[0].number).toBe(4);
  });
  it("le « 1.5 » douteux est écarté, rien n'est dupliqué — 4.1,4.2,4.3", () => {
    expect(numbers(reconciled[0])).toEqual(["4.1", "4.2", "4.3"]);
  });
  it("le bonus lu par les motifs est gardé", () => {
    expect(reconciled[0]?.exercises.find((item) => item.number === "4.2")?.isBonus).toBe(true);
  });

  // Une note de page lue sous chaque titre : le modèle décide.
  const blanketHeuristic = [{
    number: 6,
    title: "",
    exercises: [1, 2, 3, 4].map((n) => exercise(`6.${n}`, { isBonus: true })),
  }];
  const plainAI = [{
    number: 6,
    title: "",
    exercises: [1, 2, 3, 4].map((n) => exercise(`6.${n}`, { title: `T${n}`, isBonus: n === 4 })),
  }];
  it("un « facultatif » lu sous tous les titres ne fait pas toute la série bonus", () => {
    expect(SeriesAIParsing.merge(blanketHeuristic, plainAI)[0]?.exercises.map((item) => item.isBonus))
      .toEqual([false, false, false, true]);
  });
  const allBonusAI = [{
    number: 6,
    title: "",
    exercises: [1, 2, 3, 4].map((n) => exercise(`6.${n}`, { title: `T${n}`, isBonus: true })),
  }];
  it("une série entière en bonus est une lecture ratée : remise au programme", () => {
    expect(SeriesAIParsing.merge([], allBonusAI)[0]?.exercises.some((item) => item.isBonus)).toBe(false);
  });
  it("sans indice du document, le numéro du modèle l'emporte sur le défaut « 1 »", () => {
    expect(SeriesAIParsing.merge(heuristicOne, aiFour)[0]?.number).toBe(4);
  });

  // Entrée de l'IA : mise en page conservée, tout le document dans le budget.
  const long: ReturnType<typeof line>[] = [line("Série 8", 16)];
  for (let number = 1; number <= 12; number++) {
    const page = Math.trunc(number / 3);
    long.push(line(`Exercice ${number}`, 13, { page }));
    for (let index = 0; index < 40; index++) {
      long.push(line("Soit f une fonction continue sur un intervalle fermé borné, alors f atteint ses bornes.", 11, { page }));
    }
    long.push(line("a) Première question.", 11, { page, indent: 84 }));
  }
  const preparedLayout = prepareLayout(long, 8);
  it("entrée IA sous le budget (5800 car.)", () => {
    expect(characters(preparedLayout).length).toBeLessThanOrEqual(layoutBudget);
  });
  it("le dernier exercice survit, marqué comme titre", () => {
    expect(preparedLayout.includes("# Exercice 12")).toBe(true);
  });
  it("le retrait d'une question est conservé", () => {
    expect(preparedLayout.includes("  a) Première question.")).toBe(true);
  });
  it("l'indice de série est transmis", () => { expect(preparedLayout.includes("série 8")).toBe(true); });
});

// Les checks de « Sous-questions » qui exercent SeriesAIParsing et DetectedSeries.
describe("Sous-questions (SeriesAIParsing et DetectedSeries)", () => {
  const withLabels = SeriesAIParsing.parse(
    `{"series":[{"number":4,"title":"Suites","exercises":[{"number":"4.2","title":"Bornes","questions":["1","2"]}]}]}`);
  it("questions écrites comme de simples étiquettes", () => {
    expect(withLabels[0]?.exercises[0]?.subQuestions.map((question) => question.label)).toEqual(["1", "2"]);
  });

  const withObjects = SeriesAIParsing.parse(
    `{"series":[{"number":4,"title":"Suites","exercises":[{"number":"4.2","title":"Bornes","questions":[{"label":"a","text":"Première"},{"label":"b"}]}]}]}`);
  it("…ou comme des objets", () => {
    expect(withObjects[0]?.exercises[0]?.subQuestions.map((question) => question.label)).toEqual(["a", "b"]);
  });
  it("le texte est conservé quand il est donné", () => {
    expect(withObjects[0]?.exercises[0]?.subQuestions[0]?.text).toBe("Première");
  });

  const noLabels = SeriesAIParsing.parse(
    `{"series":[{"number":4,"title":"Suites","exercises":[{"number":"4.2","title":"Bornes","questions":["",""]}]}]}`);
  it("une étiquette vide reçoit son rang", () => {
    expect(noLabels[0]?.exercises[0]?.subQuestions.map((question) => question.label)).toEqual(["1", "2"]);
  });

  const duplicated = SeriesAIParsing.parse(
    `{"series":[{"number":4,"title":"Suites","exercises":[{"number":"4.2","title":"Bornes","questions":["1","1","2"]}]}]}`);
  it("les étiquettes en double sont écartées", () => {
    expect(duplicated[0]?.exercises[0]?.subQuestions.length).toBe(2);
  });

  const visionAnswer = `{"series":[{"number":3,"exercises":[{"number":"3.1","page":1,"parts":[{"label":"1)","kind":"question","children":[{"label":"(a)"},{"label":"(b)"}]},{"label":"2","children":[{"label":"a"},{"label":"b"},{"label":"c"}]}]},{"number":"3.11","parts":[{"label":null,"kind":"part","text":"Calculer lim a_n"},{"label":"1"},{"label":"2"}]}]}]}`;
  const visionParsed = SeriesAIParsing.parse(visionAnswer)[0]?.exercises;
  it("réponse « vision » : arbre lu, ponctuation retirée — 1(a,b),2(a,b,c)", () => {
    expect(DetectedSubQuestion.outline(visionParsed?.[0]?.subQuestions ?? [])).toBe("1(a,b),2(a,b,c)");
  });
  it("la page du modèle (1…) devient un index (0…)", () => {
    expect(visionParsed?.[0]?.pageIndex).toBe(0);
  });

  const withStatement = SeriesAIParsing.parse(
    `{"series":[{"number":3,"exercises":[{"number":"3.2","title":"Monotonie","statement":"Montrer que x_n est croissante ⇔ ad − bc ≥ 0"}]}]}`);
  it("l'énoncé d'un exercice sans questions est lu", () => {
    expect(withStatement[0]?.exercises[0]?.statement).toBe("Montrer que x_n est croissante ⇔ ad − bc ≥ 0");
  });
  it("une partie sans numéro est gardée", () => {
    expect(DetectedSubQuestion.outline(visionParsed?.at(-1)?.subQuestions ?? [])).toBe("part,1,2");
  });

  // La fusion ne mélange jamais deux numérotations : la plus complète gagne.
  const heuristicSide = [{
    number: 4,
    title: "Suites",
    exercises: [exercise("4.2", { title: "Bornes" })],
  }];
  const aiSide = [{
    number: 4,
    title: "Suites",
    exercises: [exercise("4.2", {
      title: "Bornes",
      subQuestions: [DetectedSubQuestion.make("1"), DetectedSubQuestion.make("2")],
    })],
  }];
  const merged = SeriesAIParsing.merge(heuristicSide, aiSide);
  it("la fusion apporte les questions — 2", () => {
    expect(merged[0]?.exercises[0]?.subQuestions.length).toBe(2);
  });
  const mergedBack = SeriesAIParsing.merge(aiSide, heuristicSide);
  it("…et ne les retire jamais", () => {
    expect(mergedBack[0]?.exercises[0]?.subQuestions.length).toBe(2);
  });
});

describe("Séries publiées en HTML (CS-107)", () => {
  const html = `
<table border="0" cellpadding="2" cellspacing="0" width="100%">
  <tbody><tr>
    <td width="75">&nbsp;</td>
	<td width="25"><font color="#000000">&nbsp;</font></td>
    <td><b>Tous les exercices sur une page:</b> <a target="_blank" href="../serie03/serie_print.html">[Enonc&eacute;]</a>  | <a target="_blank" href="../serie03/solution_print.html">[Corrig&eacute;]</a> </td>
  </tr>
</tbody></table>

<p>&nbsp; </p>
<table width="100%" border="0" cellpadding="2" cellspacing="0">
  <tr>
    <td width="75"><div align="right"><strong><font size="+1">
	3.1
	</font></strong></div></td>
	<td width="25"><font color="#000000">&nbsp;</font></td>
    <td><strong><font size="+1">
    <a href="../serie03/ex1/task.html">R&eacute;solution de polyn&ocirc;mes de degr&eacute; 2</a>
    </font></strong></td>
    <td width="100"><div align="right"><font size="+1"><strong>Niv. 0</strong></font></div></td>
	<td width="25"><font color="#000000">&nbsp;</font></td>
  </tr>
  <tr>
    <td width="75">&nbsp;</td>
	<td width="25"><font color="#000000">&nbsp;</font></td>
    <td><div align="justify"> Nous voulons &eacute;crire un programme permettant de trouver les z&eacute;ros de polyn&ocirc;mes de degr&eacute; 2.</div></td>
	<td width="100">&nbsp;</td>
	<td width="25"><font color="#000000">&nbsp;</font></td>  </tr>
  <tr>
    <td width="75">&nbsp;</td>
	<td width="25"><font color="#000000">&nbsp;</font></td>
    <td>
		<a href="../serie03/ex1/task.html">[Enonc&eacute;]</a>
		<a href="../serie03/ex1/solution.html">[Corrig&eacute;]</a>
	</td>
	<td width="100">&nbsp;</td>
	<td width="25"><font color="#000000">&nbsp;</font></td>
  </tr>
</table>
<br>
<table width="100%" border="0" cellpadding="2" cellspacing="0">
  <tr>
    <td width="75"><div align="right"><strong><font size="+1">
	3.2
	</font></strong></div></td>
	<td width="25"><font color="#000000">&nbsp;</font></td>
    <td><strong><font size="+1">
    <a href="../serie03/ex2/task.html">MOOC (cours en ligne) </a>
    </font></strong></td>
    <td width="100"><div align="right"><font size="+1"><strong>Niv. 1</strong></font></div></td>
	<td width="25"><font color="#000000">&nbsp;</font></td>
  </tr>
  <tr>
    <td width="75">&nbsp;</td>
	<td width="25"><font color="#000000">&nbsp;</font></td>
    <td><div align="justify">Quiz : structures de contr&ocirc;le</div></td>
	<td width="100">&nbsp;</td>
	<td width="25"><font color="#000000">&nbsp;</font></td>  </tr>
  <tr>
    <td width="75">&nbsp;</td>
	<td width="25"><font color="#000000">&nbsp;</font></td>
    <td>
		<a href="../serie03/ex2/task.html">[Enonc&eacute;]</a>
		<a href="../serie03/ex2/solution.html">[Corrig&eacute;]</a>
	</td>
	<td width="100">&nbsp;</td>
	<td width="25"><font color="#000000">&nbsp;</font></td>
  </tr>
</table>
<br>
`;
  const base = new URL("https://proginsc.epfl.ch/wwwhiver/series/serie03/serie.html");
  const page = SeriesPageParser.parseProginsc(html, base);
  it("exercices lus sur la page (3.1,3.2)", () => {
    expect(page?.exercises.map((item) => item.number)).toEqual(["3.1", "3.2"]);
  });
  it("titre, entités décodées (Résolution de polynômes de degré 2)", () => {
    expect(page?.exercises[0]?.title).toBe("Résolution de polynômes de degré 2");
  });
  it("résumé et niveau", () => {
    expect(page?.exercises[0]?.statement.includes("zéros de polynômes")).toBe(true);
    expect(page?.exercises[0]?.statement.endsWith("Niveau 0")).toBe(true);
  });
  it("lien de l'énoncé", () => {
    expect(page?.exercises[0]?.url).toBe("https://proginsc.epfl.ch/wwwhiver/series/serie03/ex1/task.html");
  });
  it("corrigé complet", () => {
    expect(page?.solutionURL).toBe("https://proginsc.epfl.ch/wwwhiver/series/serie03/solution_print.html");
  });
  it("une autre page n'est pas une série", () => {
    expect(SeriesPageParser.parseProginsc("<html>rien</html>", base)).toBeNull();
  });
});

describe("Rapport d'une série et file de reprise", () => {
  const reviewText = `Voilà le post-mortem.
\`\`\`polymestre
1 : juste
2 : faux
erreur 2 | Méthode | oubli de vérifier la continuité en 0 | vérifier f continue en 0 avant le TAF | continuité
erreur Ex. 3 | étourderie | signe perdu ligne 4 | recopier la ligne
erreur 4 | n'importe quoi | ignoré
reprise 2 | méthode : n'a pas vu le critère | Pose M_n = sup |f_n(x)|
\`\`\`
Et un indice :
\`\`\`polymestre
indice 3 | 2 | Le critère de Weierstrass s'applique
\`\`\``;
  const review = SeriesReview.parse(reviewText);

  it("Rapport : verdicts lus", () => {
    expect(review.verdicts.map((verdict) => verdict.result)).toEqual(["correct", "wrong"]);
  });
  it("Rapport : erreurs lues (type inconnu ignoré, « Ex. 3 » → 3)", () => {
    expect(review.mistakes.length).toBe(2);
    expect(review.mistakes[0].kind).toBe("method");
    expect(review.mistakes[0].notion).toBe("continuité");
    expect(review.mistakes[1].exercise).toBe("3");
    expect(review.mistakes[1].kind).toBe("slip");
  });
  it("Rapport : admission en reprise, avec la barre dans l'amorce", () => {
    expect(review.admissions).toEqual([{
      exercise: "2",
      why: "méthode : n'a pas vu le critère",
      firstMove: "Pose M_n = sup |f_n(x)|",
    }]);
  });
  it("Rapport : indice lu dans un second bloc", () => {
    expect(review.hints).toEqual([{ exercise: "3", level: 2, text: "Le critère de Weierstrass s'applique" }]);
  });
  it("Rapport : la réponse sans ses blocs", () => {
    expect(SeriesReview.withoutBlocks(reviewText)).toBe("Voilà le post-mortem.\n\nEt un indice :");
  });
  it("Rapport : types d'erreur en toutes lettres", () => {
    expect(SeriesReview.MistakeKind.parse("Lacune de cours")).toBe("gap");
    expect(SeriesReview.MistakeKind.parse("Lecture de l'énoncé")).toBe("reading");
  });
  it("Rapport : carnet éteint, la consigne ne le demande pas", () => {
    expect(SeriesReview.instruction(new SeriesReview.Features({ mistakes: false, redo: false })).includes("erreur numéro"))
      .toBe(false);
  });

  // Des dates locales, comme `Calendar(identifier: .gregorian)` à Zurich.
  const ladderNow = new Date(2026, 9, 14, 18);
  const ladderExam = new Date(2027, 0, 20);
  const ladder = new RedoLadder.Config();
  const first = RedoLadder.due(ladder.steps[0], ladderNow, null);
  it("Reprise : J+7", () => {
    expect(first?.getMonth()).toBe(9);
    expect(first?.getDate()).toBe(21);
  });
  const passed = RedoLadder.after("passed", 0, 0, ladder, ladderNow, ladderExam);
  it("Reprise : réussi avec aide → J+21", () => {
    expect(passed.pass).toBe(1);
    expect(passed.due?.getMonth()).toBe(10);
    expect(passed.due?.getDate()).toBe(4);
  });
  const last = RedoLadder.after("passed", 1, 0, ladder, ladderNow, ladderExam);
  it("Reprise : palier pré-examen, 5 jours avant l'examen", () => {
    expect(last.pass).toBe(2);
    expect(last.due?.getMonth()).toBe(0);
    expect(last.due?.getDate()).toBe(15);
  });
  it("Reprise : après le dernier palier, sorti", () => {
    expect(RedoLadder.after("passed", 2, 0, ladder, ladderNow, null).pass).toBeNull();
  });
  it("Reprise : sans notes, sorti d'emblée", () => {
    expect(RedoLadder.after("cleared", 0, 1, ladder, ladderNow, null).pass).toBeNull();
  });
  const failedOnce = RedoLadder.after("failed", 1, 0, ladder, ladderNow, null);
  const failedTwice = RedoLadder.after("failed", 1, 1, ladder, ladderNow, null);
  it("Reprise : raté → même palier ; deux fois → lacune de cours", () => {
    expect(failedOnce.pass).toBe(1);
    expect(failedOnce.gap).toBe(false);
    expect(failedTwice.gap).toBe(true);
  });
  it("Reprise : plafond par série (2), moins ce qui y est déjà", () => {
    expect(RedoLadder.admissible(
      [...review.admissions, { exercise: "5", why: "", firstMove: "" }, { exercise: "6", why: "", firstMove: "" }],
      1,
      ladder,
    ).length).toBe(1);
  });
  const customLadder = RedoLadder.Config.fromJSON({ steps: [3, 10, "exam"], maxPerSeries: 1 });
  it("Reprise : paliers du projet (polymestre.json)", () => {
    expect(customLadder.steps).toEqual([{ days: 3 }, { days: 10 }, "exam"]);
    expect(customLadder.maxPerSeries).toBe(1);
    expect(customLadder.perSession).toBe(3);
  });

  // Noter un rapport confirmé, dans de vrais modèles.
  const reviewCourse = new Course({ code: "MATH-101", name: "Analyse I" });
  const reviewSeries = new ExerciseSeries({ course: reviewCourse, seriesNumber: 6, title: "Série 6" });
  for (let n = 1; n <= 4; n++) {
    new Exercise({ series: reviewSeries, exerciseNumber: `6.${n}`, sortOrder: n });
  }
  const report = SeriesReview.parse(`\`\`\`polymestre
6.1 : juste
2 : faux
erreur 2 | méthode | oubli de la continuité en 0 | vérifier la continuité | continuité
reprise 2 | méthode | Pose g = f - id
reprise 3 | lacune de cours | Relis 5.2
reprise 4 | méthode | Trace le graphe
\`\`\``);
  const features = new SeriesReview.Features({ mistakes: true, redo: true, hints: true, redoPerSeries: 2 });
  let applied: ReturnType<typeof SeriesReview.apply>;
  let again: ReturnType<typeof SeriesReview.apply>;
  let secondExercise: Exercise;
  it("Rapport noté : corrections, carnet, reprise plafonnée à 2", () => {
    applied = SeriesReview.apply(report, reviewSeries, features, new RedoLadder.Config(), null, null);
    again = SeriesReview.apply(report, reviewSeries, features, new RedoLadder.Config(), null, null);
    secondExercise = reviewSeries.sortedExercises[1];
    expect(applied.corrected).toBe(2);
    expect(applied.mistakes).toBe(1);
    expect(applied.queued).toEqual(["6.2", "6.3"]);
    expect(applied.overCap).toEqual(["6.4"]);
  });
  it("Rapport noté deux fois : rien en double", () => {
    expect(again.mistakes).toBe(0);
    expect(again.corrected).toBe(0);
    expect(again.queued).toEqual([]);
  });
  it("Rapport noté : l'exercice 6.2 en reprise, son amorce et son erreur", () => {
    expect(secondExercise.isQueuedForRedo).toBe(true);
    expect(secondExercise.redoRequired).toBe(true);
    expect(secondExercise.redoFirstMove).toBe("Pose g = f - id");
    expect(secondExercise.redoDueAt).not.toBeNull();
    expect(secondExercise.mistakes[0]?.kind).toBe("method");
  });
  it("Reprise réussie sans notes : sort de la file", () => {
    const outcome = SeriesReview.recordRedo("cleared", secondExercise, new RedoLadder.Config(), null);
    expect(outcome.pass).toBeNull();
    expect(secondExercise.isQueuedForRedo).toBe(false);
    expect(secondExercise.redoRequired).toBe(false);
    expect(secondExercise.redoClearedAt).not.toBeNull();
  });
  it("Indices : notés une fois", () => {
    expect(SeriesReview.recordHints([{ exercise: "6.4", level: 3, text: "Trace le graphe" }], reviewSeries)).toBe(1);
    expect(SeriesReview.recordHints([{ exercise: "6.4", level: 3, text: "Trace le graphe" }], reviewSeries)).toBe(0);
  });

  it("Indices : journal et niveau le plus haut", () => {
    const hinted = new Exercise({ series: null, exerciseNumber: "3" });
    hinted.recordHint(2, "Weierstrass | majoration\nvérifie", ladderNow);
    hinted.recordHint(1, "Chapitre 6", ladderNow);
    expect(hinted.hintLevel).toBe(2);
    expect(hinted.hints.length).toBe(2);
    expect(hinted.hints[0]?.text).toBe("Weierstrass / majoration vérifie");
  });

  it("indice : un verdict n'est pas pris pour un indice", () => {
    const verdictOnly = SeriesReview.parse("```polymestre\n6.3 : juste\n```");
    expect(verdictOnly.hints).toEqual([]);
    expect(verdictOnly.verdicts.length).toBe(1);
  });
  it("indice : « 6.3 | 1 | … » sans le mot indice", () => {
    const bare = SeriesReview.parse("Quel X ?\n\n```polymestre\n6.3 | 1 | Choisis un X qui isole une colonne.\n```");
    expect(bare.hints.length).toBe(1);
    expect(bare.hints[0]?.exercise).toBe("6.3");
    expect(bare.hints[0]?.level).toBe(1);
  });
  it("indice : avec le mot indice", () => {
    const keyed = SeriesReview.parse("```polymestre\nindice 6.3 | 2 | L'outil\n```");
    expect(keyed.hints.length).toBe(1);
    expect(keyed.hints[0]?.level).toBe(2);
  });
});

// Une vérification de plus, utile à l'écran : les questions d'une ligne.
describe("Sous-questions : arbre et étiquettes", () => {
  it("« Question 1 » n'est pas un exercice quand le document dit « Exercice »", () => {
    const line = (text: string, size = 11, indent = 60) =>
      PDFLayoutLine.make(text, { fontSize: size, indent });
    const questions = [line("Série 1", 16), line("Exercice 1", 13), line("Soit f."),
      line("a) Montrer que f est continue.", 11, 80), line("b) En déduire la limite.", 11, 80),
      line("Exercice 2", 13), line("Question 1 : calculer."), line("Question 2 : conclure.")];
    expect(SeriesLayoutParser.parse(questions)[0]?.exercises[0]?.subQuestions.map((question) => question.label))
      .toEqual(["a", "b"]);
  });
});
