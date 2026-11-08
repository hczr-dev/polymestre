// Les règles de l'import d'une série, hors interface (StudyKit/SeriesImportSheet.swift).
//
// L'écran suit trois temps — choisir, analyser, relire — ; ce qui ne dépend ni du
// DOM ni du réseau est ici pour être testé : le résumé de ce que l'IA a changé, la
// semaine par défaut, l'application d'une lecture aux brouillons, et le pipeline
// commun « motifs tout de suite, IA ensuite, relecture toujours ».

import { DetectedExercise, DetectedSeries } from "./seriesPDFParser.ts";
import { Plural } from "../domain/plural.ts";
import { ExerciseDraft, SeriesDraft } from "../domain/seriesDraft.ts";
import { SeriesDocumentInference } from "../domain/seriesDocumentInference.ts";
import { SeriesLayoutParser, PDFLayoutLine } from "../domain/seriesLayout.ts";
import { SeriesAIParsing } from "../domain/seriesAIParsing.ts";
import { SeriesExtractionSource } from "./seriesAIExtractor.ts";

/// Le texte d'une ligne par défaut : la première lecture « rapide ».
export function localSummary(local: DetectedSeries[]): string {
  const exercises = local.reduce((total, item) => total + item.exercises.length, 0);
  return Plural.count(exercises, `${exercises} exercice repéré`, `${exercises} exercices repérés`);
}

/// Ce que le modèle a changé par rapport à la lecture locale, en une ligne.
export function summary(local: DetectedSeries[], merged: DetectedSeries[], source: SeriesExtractionSource): string {
  const before = local.reduce((total, item) => total + item.exercises.length, 0);
  const after = merged.reduce((total, item) => total + item.exercises.length, 0);
  const leaves = merged.flatMap((item) => item.exercises)
    .reduce((total, exercise) => total + Math.max(1, DetectedExercise.leafQuestionCount(exercise)), 0);
  const localExercises = local.flatMap((item) => item.exercises);
  const mergedExercises = merged.flatMap((item) => item.exercises);
  // `zip` s'arrête au plus court.
  let changed = 0;
  for (let index = 0; index < Math.min(localExercises.length, mergedExercises.length); index++) {
    const a = localExercises[index];
    const b = mergedExercises[index];
    if (a.number === b.number && !sameQuestions(a, b)) changed++;
  }
  const parts = [`${Plural.count(after, `${after} exercice`, `${after} exercices`)}, ${leaves} cases`];
  if (changed > 0) parts.push(`questions relues pour ${changed}`);
  if (after > before) parts.push(Plural.count(after - before, `${after - before} ajouté`, `${after - before} ajoutés`));
  if (after < before) {
    parts.push(Plural.count(before - after, `${before - after} repère douteux écarté`, `${before - after} repères douteux écartés`));
  }
  return `${parts.join(" · ")} — ${SeriesExtractionSource.label(source)}`;
}

function sameQuestions(a: DetectedExercise, b: DetectedExercise): boolean {
  return a.subQuestions.length === b.subQuestions.length
    && a.subQuestions.every((q, index) => equalQuestion(q, b.subQuestions[index]));
}

function equalQuestion(a: DetectedExercise["subQuestions"][number], b: DetectedExercise["subQuestions"][number]): boolean {
  return a.label === b.label && a.text === b.text && a.kind === b.kind
    && a.children.length === b.children.length && a.children.every((c, i) => equalQuestion(c, b.children[i]));
}

/// Le contexte d'un cours pour les semaines : `term.totalWeeks` et `currentWeek`.
export interface WeekContext {
  totalWeeks: number | null;
  currentWeek: number | null;
}

/// La semaine où la série est prévue : son numéro, quand il tient dans le semestre —
/// la série 4 se fait en semaine 4 — sinon la semaine en cours.
export function defaultWeek(number: number, course: WeekContext | null): number {
  const total = course?.totalWeeks ?? 14;
  if (number >= 1 && number <= total) return number;
  return Math.max(course?.currentWeek ?? 1, 1);
}

/// Les lectures appliquées aux brouillons : l'aperçu s'arrête où commence
/// l'exercice suivant, s'il est sur la même page.
export function draftsFrom(series: DetectedSeries[], course: (WeekContext & { name: string; code: string }) | null): SeriesDraft[] {
  return series.map((detected) => new SeriesDraft({
    number: detected.number,
    label: detected.label ?? "",
    title: SeriesDocumentInference.seriesTitle(detected.title, course?.name ?? "", course?.code ?? ""),
    plannedWeek: defaultWeek(detected.number, course),
    exercises: detected.exercises.map((exercise, index) => {
      const draft = ExerciseDraft.fromDetected(exercise);
      const next = detected.exercises[index + 1];
      if (next && next.pageIndex === exercise.pageIndex) draft.bottom = next.verticalPosition;
      return draft;
    }),
  }));
}

/// Une empreinte des brouillons : s'en écarter, c'est avoir corrigé à la main.
export function fingerprint(drafts: SeriesDraft[]): string {
  return JSON.stringify(drafts.map((draft) => ({
    n: draft.number, t: draft.title, w: draft.plannedWeek, d: draft.dueDate?.getTime() ?? null,
    e: draft.exercises.map((e) => [e.minor, e.title, e.isBonus, e.statement, outline(e.subQuestions), e.pageIndex ?? null, e.top ?? null, e.bottom ?? null]),
  })));
}

function outline(questions: DetectedExercise["subQuestions"]): unknown {
  return questions.map((q) => [q.label, q.text, q.kind, outline(q.children)]);
}

export interface CourseChoice { id: string; code: string; name: string }

/// Ce que le document dit de lui : motifs tout de suite, et ce qu'il faut envoyer au modèle.
export interface Analysis {
  preferredSeries: number | null;
  detectedCourse: string | null;
  parsed: DetectedSeries[];
  language: string | null;
  aiInput: string;
}

export function analyzeLines(lines: PDFLayoutLine[], filename: string | null, candidates: CourseChoice[], detectCourse: boolean): Analysis {
  const preferredSeries = SeriesDocumentInference.seriesNumber(lines, filename)?.number ?? null;
  const detectedCourse = detectCourse
    ? SeriesDocumentInference.course(lines, filename, candidates.map(({ id, code, name }) => ({ id, code, name })))
    : null;
  const parsed = SeriesLayoutParser.fillingStatements(SeriesLayoutParser.parse(lines, preferredSeries), lines);
  const hasLayout = lines.some((line) => line.fontSize > 0);
  const language = SeriesDocumentInference.languageName(lines.map((line) => line.text).join("\n"));
  const aiInput = hasLayout
    ? SeriesAIParsing.prepareLayout(lines, preferredSeries, language)
    : (preferredSeries !== null ? `[Indice : ce document semble être la série ${preferredSeries}]\n` : "")
      + ((hint) => (hint !== null ? `${hint}\n` : ""))(SeriesDocumentInference.languageHint(language))
      + SeriesAIParsing.prepare(lines.map((line) => line.text).join("\n"));
  return { preferredSeries, detectedCourse, parsed, language, aiInput };
}

/// Le texte collé (Moodle, mail) : aucune information de police, l'analyse retombe sur les motifs.
export function linesFromText(text: string): PDFLayoutLine[] {
  return text.split(/\r\n|\r|\n/).map((line) => PDFLayoutLine.make(line));
}

export const SeriesImportFlow = { localSummary, summary, defaultWeek, draftsFrom, fingerprint, analyzeLines, linesFromText };
