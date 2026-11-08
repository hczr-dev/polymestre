// Port de Polymestre/Domain/AssistantCommands.swift : une modification demandée
// par un assistant, par le serveur MCP. L'assistant n'écrit jamais directement
// dans les données : l'app applique la commande avec les mêmes règles que
// l'interface. Une commande qui ne trouve pas sa cible échoue proprement.

import { SeriesIdentity } from "./seriesIdentity.ts";
import type { Course } from "../models/course.ts";
import { Exercise } from "../models/exercise.ts";
import { Exam } from "../models/exam.ts";
import { StudySession } from "../models/studySession.ts";
import { TheoryItem } from "../models/theoryItem.ts";
import { Correctness, ConfidenceLevel, ExamKind, TaskType } from "../models/enums.ts";
import { DateUtils } from "./dateUtils.ts";
import { Plural } from "./plural.ts";
import { ExerciseDraft, SeriesDraft, SeriesDraftWriter } from "./seriesDraft.ts";
import { DetectedSubQuestion } from "../services/seriesPDFParser.ts";
// `setDone` / `correct` : l'extension Exercise de Domain/ExerciseFlow.swift.
import "./exerciseFlow.ts";

export interface NewExerciseSpec {
  number: string;
  title?: string | null;
  statement?: string | null;
  bonus?: boolean | null;
  questions?: string[] | null;
}

export interface AssistantPayload {
  // Cible
  courseId?: string | null;
  course?: string | null;
  exerciseId?: string | null;
  exercise?: string | null;
  theoryId?: string | null;
  theory?: string | null;
  // Exercice
  done?: boolean | null;
  confidence?: string | null;
  correctness?: string | null;
  redo?: boolean | null;
  note?: string | null;
  questions?: string[] | null;
  // Théorie
  watched?: boolean | null;
  summary?: string | null;
  // Session
  type?: string | null;
  minutes?: number | null;
  startedAt?: string | null;
  // Série, évaluation
  number?: number | null;
  /** « b », « mardi » : la deuxième série d'une semaine. */
  label?: string | null;
  week?: number | null;
  title?: string | null;
  exercises?: NewExerciseSpec[] | null;
  date?: string | null;
  examKind?: string | null;
  location?: string | null;
}

export interface AssistantCommandInit {
  id: string;
  kind: string;
  payload: AssistantPayload;
}

export class AssistantCommand {
  id: string;
  kind: string;
  payload: AssistantPayload;

  constructor(o: AssistantCommandInit) {
    this.id = o.id;
    this.kind = o.kind;
    this.payload = o.payload;
  }

  /** `[AssistantCommand].self` : une liste illisible est une liste vide. */
  static decodeList(json: string): AssistantCommand[] {
    let value: unknown;
    try { value = JSON.parse(json); } catch { return []; }
    if (!Array.isArray(value)) return [];
    const result: AssistantCommand[] = [];
    for (const item of value) {
      if (item === null || typeof item !== "object") continue;
      const object = item as Record<string, unknown>;
      if (typeof object["id"] !== "string" || typeof object["kind"] !== "string") continue;
      const payload = object["payload"];
      result.push(new AssistantCommand({
        id: object["id"],
        kind: object["kind"],
        payload: payload !== null && typeof payload === "object" && !Array.isArray(payload)
          ? payload as AssistantPayload : {},
      }));
    }
    return result;
  }
}

export class AssistantCommandResult {
  id: string;
  status: "applied" | "failed";
  message: string;

  constructor(o: AssistantCommandResult) {
    this.id = o.id;
    this.status = o.status;
    this.message = o.message;
  }

  static applied(id: string, message: string): AssistantCommandResult {
    return new AssistantCommandResult({ id, status: "applied", message });
  }

  static failed(id: string, message: string): AssistantCommandResult {
    return new AssistantCommandResult({ id, status: "failed", message });
  }
}

class Failure extends Error {
  constructor(message: string) {
    super(message);
    this.name = "Failure";
  }
}

export const AssistantCommandApplier = {
  /** Applique les commandes, dans l'ordre ; chaque résultat dit ce qui a été fait. */
  apply(commands: AssistantCommand[], courses: Course[], now: Date = new Date()): AssistantCommandResult[] {
    return commands.map((command) => {
      try {
        return AssistantCommandResult.applied(command.id, applyOne(command, courses, now));
      } catch (error) {
        return AssistantCommandResult.failed(command.id, error instanceof Error ? error.message : String(error));
      }
    });
  },

  confidence(raw: string): ConfidenceLevel | null {
    switch (fold(raw)) {
      case "sure": case "sur": case "high": case "green": case "vert": return ConfidenceLevel.high;
      case "medium": case "moyen": case "orange": return ConfidenceLevel.medium;
      case "unsure": case "pas sur": case "low": case "red": case "rouge": return ConfidenceLevel.low;
      default: return null;
    }
  },

  correctness(raw: string): Correctness | null {
    switch (fold(raw)) {
      case "correct": case "juste": case "right": case "green": case "vert": case "sure": case "high": return "correct";
      case "partial": case "moyen": case "partiel": case "moyennement juste": case "orange": case "medium": return "partial";
      case "wrong": case "faux": case "incorrect": case "red": case "rouge": case "unsure": case "low": return "wrong";
      default: return null;
    }
  },

  /** « (a) », « a) », « 1.a » → « a », « 1.a ». */
  normalizeLabel(raw: string): string {
    return raw.toLowerCase().replace(/^[ (.:]+|[ (.:]+$/g, "").split("(").join("").split(")").join("");
  },

  parseDate(raw: string): Date | null {
    const date = new Date(raw);
    if (!Number.isNaN(date.getTime()) && /T/.test(raw)) return date;
    const day = /^(\d{4})-(\d{2})-(\d{2})$/.exec(raw);
    if (day !== null) return new Date(Number(day[1]), Number(day[2]) - 1, Number(day[3]));
    return Number.isNaN(date.getTime()) ? null : date;
  },
};

function applyOne(command: AssistantCommand, courses: Course[], now: Date): string {
  const p = command.payload;
  switch (command.kind) {
    case "update_exercise": {
      const exercise = findExercise(p, courses);
      const changes: string[] = [];
      if (p.done !== undefined && p.done !== null) {
        exercise.setDone(p.done);
        changes.push(p.done ? "fait" : "à faire");
      }
      // `confidence` venait d'une version où la couleur était une « sureté ».
      const raw = p.correctness ?? p.confidence;
      if (raw !== undefined && raw !== null) {
        const result = AssistantCommandApplier.correctness(raw);
        if (result === null) throw new Failure(`Correction inconnue « ${raw} » (correct/green, partial/orange, wrong/red).`);
        exercise.correct(result);
        changes.push("corrigé " + Correctness.shortLabel(result).toLowerCase());
      }
      if (p.redo !== undefined && p.redo !== null) {
        exercise.redoRequired = p.redo;
        changes.push(p.redo ? "à refaire" : "plus à refaire");
      }
      if (p.note !== undefined && p.note !== null) {
        exercise.correctionNote = p.note === "" ? null : p.note;
        changes.push("remarque");
      }
      if (changes.length === 0) throw new Failure(`Rien à modifier sur ${exercise.displayNumber}.`);
      return `${exercise.displayNumber} : ` + changes.join(", ");
    }

    case "check_questions": {
      const exercise = findExercise(p, courses);
      if (!exercise.hasSubQuestions) {
        exercise.setDone(p.done ?? true);
        return `${exercise.displayNumber} n'a pas de questions : marqué ${exercise.isDone ? "fait" : "à faire"}`;
      }
      const done = p.done ?? true;
      const wanted = new Set((p.questions ?? []).map(AssistantCommandApplier.normalizeLabel));
      const leaves = exercise.leafSubQuestions;
      const targets = wanted.size === 0 ? leaves : leaves.filter((leaf) =>
        wanted.has(AssistantCommandApplier.normalizeLabel(leaf.path))
        || wanted.has(AssistantCommandApplier.normalizeLabel(leaf.label)));
      if (targets.length === 0) {
        throw new Failure(`Aucune question « ${[...wanted].sort().join(", ")} » dans ${exercise.displayNumber} (questions : ${leaves.map((leaf) => leaf.path).join(", ")}).`);
      }
      for (const leaf of targets) if (leaf.isDone !== done) leaf.toggle();
      exercise.refreshCompletion();
      const questions = done
        ? Plural.count(targets.length, `${targets.length} question cochée`, `${targets.length} questions cochées`)
        : Plural.count(targets.length, `${targets.length} question décochée`, `${targets.length} questions décochées`);
      return `${exercise.displayNumber} : ${questions} (${exercise.subQuestionLabel ?? ""})`;
    }

    case "update_theory": {
      const item = findTheory(p, courses);
      const changes: string[] = [];
      if (p.watched !== undefined && p.watched !== null) {
        item.watchedAt = p.watched ? (item.watchedAt ?? now) : null;
        changes.push(p.watched ? "vu" : "pas vu");
      }
      if (p.summary !== undefined && p.summary !== null) {
        item.summaryText = p.summary;
        item.summarizedAt = p.summary === "" ? null : now;
        if (p.summary !== "" && item.watchedAt === null) item.watchedAt = now;
        changes.push("résumé");
      }
      if (changes.length === 0) throw new Failure(`Rien à modifier sur ${item.displayNumber}.`);
      return `${item.course?.displayCode ?? ""} ${item.displayNumber} : ` + changes.join(", ");
    }

    case "log_session": {
      const minutes = p.minutes;
      if (minutes === undefined || minutes === null || !(minutes > 0) || minutes > 16 * 60) {
        throw new Failure("Durée invalide (entre 1 et 960 minutes).");
      }
      const course = tryFind(() => findCourse(p, courses));
      const type = TaskType.fromRaw(p.type ?? "") ?? "other";
      const exercise = p.exerciseId != null || p.exercise != null ? tryFind(() => findExercise(p, courses)) : null;
      const theory = p.theoryId != null || p.theory != null ? tryFind(() => findTheory(p, courses)) : null;
      const seconds = Math.trunc(minutes * 60);
      const start = p.startedAt != null ? (AssistantCommandApplier.parseDate(p.startedAt) ?? new Date(now.getTime() - seconds * 1000)) : new Date(now.getTime() - seconds * 1000);
      const session = new StudySession({
        course: course ?? exercise?.series?.course ?? theory?.course ?? null,
        taskType: type,
        startedAt: start,
        durationSeconds: seconds,
        isManual: true,
        note: p.note ?? "Ajouté par l'assistant",
        exercise,
        theoryItem: theory,
      });
      return `Session de ${DateUtils.durationLabel(seconds)} enregistrée${session.course !== null ? ` (${session.course.displayCode})` : ""}`;
    }

    case "add_series": {
      const course = findCourse(p, courses);
      const number = p.number;
      if (number === undefined || number === null || !(number > 0)) throw new Failure("Numéro de série manquant.");
      const label = SeriesIdentity.normalized(p.label ?? "");
      const draft = new SeriesDraft({
        number,
        label,
        title: "",
        plannedWeek: p.week ?? course.currentWeek,
        exercises: (p.exercises ?? []).map((spec) => new ExerciseDraft({
          // « 3.4 » → « 4 » : le brouillon porte le numéro **dans** la série.
          minor: spec.number.split(".")[spec.number.split(".").length - 1] ?? spec.number,
          title: spec.title ?? "",
          isBonus: spec.bonus ?? false,
          statement: spec.statement ?? "",
          subQuestions: (spec.questions ?? []).map((label) => DetectedSubQuestion.make(label)),
        })),
      });
      const existed = course.seriesWith(number, label) !== null;
      const written = SeriesDraftWriter.write(draft, course, "importMerge", null).series;
      if (p.title !== undefined && p.title !== null && p.title !== "") written.title = p.title;
      return `${course.displayCode} : ${written.displayName.toLowerCase()} ${existed ? "complétée" : "ajoutée"} (${Plural.count(draft.exercises.length, `${draft.exercises.length} exercice`, `${draft.exercises.length} exercices`)})`;
    }

    case "add_exam": {
      const course = findCourse(p, courses);
      const date = p.date != null ? AssistantCommandApplier.parseDate(p.date) : null;
      if (date === null) throw new Failure("Date invalide (ISO 8601 attendu).");
      const kind = ExamKind.fromRaw(p.examKind ?? "") ?? "exam";
      const exam = new Exam({ course, kind, title: p.title ?? "", date, location: p.location ?? "" });
      return `${course.displayCode} : ${exam.title} le ${DateUtils.shortDay(exam.date)}`;
    }

    default:
      throw new Failure(`Commande inconnue « ${command.kind} ». Mets Polymestre à jour.`);
  }
}

// MARK: Cibles

function findCourse(p: AssistantPayload, courses: Course[]): Course {
  if (p.courseId != null) {
    const course = courses.find((item) => item.id === p.courseId);
    if (course !== undefined) return course;
  }
  const code = p.course?.replace(/^\s+|\s+$/g, "");
  if (code !== undefined && code !== "") {
    const folded = fold(code);
    const match = courses.find((item) => fold(item.code) === folded || fold(item.displayCode) === folded)
      ?? courses.find((item) => fold(item.name) === folded)
      ?? courses.find((item) => fold(item.code).startsWith(folded) || fold(item.name).includes(folded));
    if (match !== undefined) return match;
    throw new Failure(`Cours « ${code} » introuvable.`);
  }
  throw new Failure("Cours manquant.");
}

function findExercise(p: AssistantPayload, courses: Course[]): Exercise {
  if (p.exerciseId != null) {
    for (const course of courses) {
      const exercise = course.allExercises.find((item) => item.id === p.exerciseId);
      if (exercise !== undefined) return exercise;
    }
    throw new Failure("Exercice introuvable (supprimé depuis ?).");
  }
  const number = p.exercise?.replace(/^\s+|\s+$/g, "");
  if (number === undefined || number === "") throw new Failure("Exercice manquant.");
  const course = findCourse(p, courses);
  const bare = number.split("Exercice ").join("");
  const exercise = course.allExercises.find((item) => item.exerciseNumber === bare);
  if (exercise === undefined) throw new Failure(`Exercice ${bare} introuvable dans ${course.displayCode}.`);
  return exercise;
}

function findTheory(p: AssistantPayload, courses: Course[]): TheoryItem {
  if (p.theoryId != null) {
    for (const course of courses) {
      const item = course.theoryItems.find((theory) => theory.id === p.theoryId);
      if (item !== undefined) return item;
    }
    throw new Failure("Élément de théorie introuvable.");
  }
  const number = p.theory?.replace(/^\s+|\s+$/g, "");
  if (number === undefined || number === "") throw new Failure("Élément de théorie manquant.");
  const course = findCourse(p, courses);
  const item = course.theoryItems.find((theory) => theory.number === number);
  if (item === undefined) throw new Failure(`Théorie ${number} introuvable dans ${course.displayCode}.`);
  return item;
}

function tryFind<T>(body: () => T): T | null {
  try { return body(); } catch { return null; }
}

// MARK: Valeurs

/** `ContentDraftBuilder.fold` (autre fichier) : sans accents ni casse. */
function fold(text: string): string {
  return text.normalize("NFD").replace(/\p{M}/gu, "").toLowerCase();
}
