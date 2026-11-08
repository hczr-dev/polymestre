// Une série telle qu'elle sera enregistrée — modifiable avant — et les gestes
// purs sur l'arbre des questions (Polymestre/Domain/SeriesDraft.swift).
//
// Le **même** brouillon sert à relire un import et à modifier une série déjà
// enregistrée : les deux écrans se comportent donc de la même façon, et un
// exercice mal importé se corrige avec les gestes qui ont servi à l'importer.

import { DetectedSubQuestion, type DetectedExercise } from "../services/seriesPDFParser.ts";
import { Exercise, ExerciseSeries, type DetectedSubQuestionData } from "../models/exercise.ts";
import type { ModelStore } from "../models/store.ts";
import type { Course } from "../models/course.ts";
import { characters, isLetter, isNumber, trimWhitespaces } from "./textRepair.ts";
import { trimAll } from "../models/util.ts";
import { newId } from "../models/relations.ts";
import { SeriesReconciler } from "./seriesReconciler.ts";
import { SeriesIdentity, type SeriesKey } from "./seriesIdentity.ts";

// MARK: - Brouillons

export interface SeriesDraftInit {
  id?: string;
  existingID?: string | null;
  number: number;
  label?: string;
  title: string;
  plannedWeek: number;
  dueDate?: Date | null;
  exercises: ExerciseDraft[];
}

/// Une série telle qu'elle sera enregistrée — modifiable avant.
export class SeriesDraft {
  readonly id: string;
  /** La série enregistrée que ce brouillon modifie, s'il y en a une. */
  existingID: string | null;
  number: number;
  /** « b », « mardi » : ce qui distingue deux séries de même numéro. */
  label: string;
  title: string;
  plannedWeek: number;
  dueDate: Date | null;
  exercises: ExerciseDraft[];

  constructor(o: SeriesDraftInit) {
    this.id = o.id ?? newId();
    this.existingID = o.existingID ?? null;
    this.number = o.number;
    this.label = SeriesIdentity.normalized(o.label ?? "");
    this.title = o.title;
    this.plannedWeek = o.plannedWeek;
    this.dueDate = o.dueDate ?? null;
    this.exercises = o.exercises;
  }

  /// Le brouillon d'une série enregistrée, pour la modifier.
  static fromSeries(series: ExerciseSeries): SeriesDraft {
    return new SeriesDraft({
      existingID: series.id,
      number: series.seriesNumber,
      label: series.label,
      // « Série 3 » est le titre par défaut : on le laisse vide pour
      // que changer le numéro ne laisse pas un « Série 3 » périmé.
      title: series.title === series.displayName || series.title === `Série ${series.seriesNumber}` ? "" : series.title,
      plannedWeek: series.plannedWeek,
      dueDate: series.dueDate,
      exercises: series.sortedExercises.map((exercise) => ExerciseDraft.fromExercise(exercise)),
    });
  }

  /// Ajoute la ligne suivante : « 4.3 » après « 4.2 ».
  addExercise(): void {
    const minors = this.exercises
      .map((exercise) => swiftWholeInt(exercise.minor))
      .filter((value): value is number => value !== null);
    const next = (minors.length === 0 ? 0 : Math.max(...minors)) + 1;
    this.exercises.push(new ExerciseDraft({ minor: String(next), title: "", isBonus: false }));
  }

  /// Renumérote 1, 2, 3… dans l'ordre affiché.
  renumberExercises(): void {
    this.exercises.forEach((exercise, index) => { exercise.minor = String(index + 1); });
  }

  get leafCount(): number {
    return this.exercises.reduce((total, exercise) => total + exercise.leafCount, 0);
  }

  /// Ce qui empêche d'enregistrer, en phrases.
  ///
  get key(): SeriesKey { return SeriesIdentity.key(this.number, this.label); }
  get displayName(): string { return SeriesIdentity.displayName(this.number, this.label); }

  /// `taken` : numéros et étiquettes des **autres** séries du cours. Deux séries 5
  /// la même semaine se distinguent par leur étiquette (« a », « b »).
  problems(taken: readonly SeriesKey[]): string[] {
    const result: string[] = [];
    if (taken.some((key) => SeriesIdentity.same(key, this.key))) {
      result.push(this.label === ""
        ? `La série ${this.number} existe déjà dans ce cours. Pour une deuxième série la même semaine, donne-lui une étiquette (« b », « jeudi »).`
        : `La ${this.displayName} existe déjà dans ce cours.`);
    }
    const minors = this.exercises.map((exercise) => trimWhitespaces(exercise.minor));
    if (minors.some((minor) => minor === "")) {
      result.push("Un exercice n'a pas de numéro.");
    }
    const counts = new Map<string, number>();
    for (const minor of minors) {
      if (minor === "") continue;
      counts.set(minor, (counts.get(minor) ?? 0) + 1);
    }
    const duplicates = [...counts.entries()]
      .filter(([, count]) => count > 1)
      .map(([minor]) => minor)
      .sort();
    if (duplicates.length > 0) {
      result.push("Numéro en double : " + duplicates.map((minor) => `${this.number}.${minor}`).join(", ") + ".");
    }
    return result;
  }
}

/// `Int(String)` de Swift : un entier signé en décimal, rien d'autre.
function swiftWholeInt(text: string): number | null {
  return /^[+-]?\d+$/.test(text) ? Number(text) : null;
}

export interface ExerciseDraftInit {
  id?: string;
  existingID?: string | null;
  minor: string;
  title: string;
  isBonus: boolean;
  subQuestions?: DetectedSubQuestion[];
  statement?: string;
  pageIndex?: number;
  top?: number;
  bottom?: number;
  isDone?: boolean;
}

/// Un exercice tel qu'il sera enregistré. Le numéro est stocké **sans** la
/// série : changer le numéro de série renumérote toute la liste d'un coup.
export class ExerciseDraft {
  readonly id: string;
  /** L'exercice enregistré que cette ligne modifie : son avancement le suit
   * même si on change son numéro. */
  existingID: string | null;
  minor: string;
  title: string;
  isBonus: boolean;
  /** Ce que l'exercice demande, en une phrase. */
  statement: string;
  subQuestions: DetectedSubQuestion[];
  /** Où l'exercice se trouve dans le PDF importé, pour l'aperçu. */
  pageIndex?: number;
  top?: number;
  bottom?: number;
  /** Déjà fait (exercice existant) : affiché dans l'éditeur, jamais modifié par lui. */
  isDone: boolean;

  constructor(o: ExerciseDraftInit) {
    this.id = o.id ?? newId();
    this.existingID = o.existingID ?? null;
    this.minor = o.minor;
    this.title = o.title;
    this.isBonus = o.isBonus;
    this.statement = o.statement ?? "";
    this.subQuestions = o.subQuestions ?? [];
    this.pageIndex = o.pageIndex;
    this.top = o.top;
    this.bottom = o.bottom;
    this.isDone = o.isDone ?? false;
  }

  static fromDetected(detected: DetectedExercise): ExerciseDraft {
    return new ExerciseDraft({
      minor: lastPart(detected.number.split(".")) ?? detected.number,
      title: detected.title,
      isBonus: detected.isBonus,
      subQuestions: detected.subQuestions,
      statement: detected.statement,
      pageIndex: detected.pageIndex,
      top: detected.verticalPosition,
    });
  }

  static fromExercise(exercise: Exercise): ExerciseDraft {
    return new ExerciseDraft({
      existingID: exercise.id,
      minor: lastPart(exercise.exerciseNumber.split(".")) ?? exercise.exerciseNumber,
      title: exercise.title,
      isBonus: exercise.isBonus,
      subQuestions: exercise.detectedSubQuestions.map(toDetected),
      statement: exercise.statement,
      isDone: exercise.isDone,
    });
  }

  get leafCount(): number {
    return this.subQuestions.length === 0
      ? 1
      : this.subQuestions.reduce((total, question) => total + DetectedSubQuestion.leafCount(question), 0);
  }
}

function toDetected(data: DetectedSubQuestionData): DetectedSubQuestion {
  return DetectedSubQuestion.make(data.label, {
    text: data.text,
    kind: data.kind,
    children: data.children.map(toDetected),
  });
}

// MARK: - Arbre des questions

export interface SubQuestionRow {
  id: string;
  depth: number;
  question: DetectedSubQuestion;
  /** Peut devenir un point de la question du dessus. */
  canIndent: boolean;
  canOutdent: boolean;
}

/// Les gestes sur l'arbre des questions d'un exercice, **purs** et testés.
///
/// L'éditeur affiche l'arbre à plat — une ligne par question ou point, avec sa
/// profondeur — et chaque geste (supprimer, rattacher à la question précédente,
/// remonter au premier niveau, déplacer) passe par ici.
export const SubQuestionTree = {
  rows(questions: DetectedSubQuestion[]): SubQuestionRow[] {
    const result: SubQuestionRow[] = [];
    questions.forEach((question, index) => {
      const previous = index > 0 ? questions[index - 1] : null;
      result.push({
        id: question.id,
        depth: 0,
        question,
        canIndent: previous?.kind === "question" && question.kind === "question" && question.children.length === 0,
        canOutdent: false,
      });
      for (const child of question.children) {
        result.push({ id: child.id, depth: 1, question: child, canIndent: false, canOutdent: true });
      }
    });
    return result;
  },

  remove(id: string, questions: DetectedSubQuestion[]): void {
    for (let index = questions.length - 1; index >= 0; index--) {
      if (questions[index].id === id) questions.splice(index, 1);
    }
    for (const question of questions) {
      question.children = question.children.filter((child) => child.id !== id);
    }
  },

  update(id: string, questions: DetectedSubQuestion[], change: (question: DetectedSubQuestion) => void): void {
    for (const question of questions) {
      if (question.id === id) { change(question); return; }
      for (const child of question.children) {
        if (child.id === id) { change(child); return; }
      }
    }
  },

  /// « 2) » devient le point suivant de « 1) ».
  indent(id: string, questions: DetectedSubQuestion[]): void {
    const index = questions.findIndex((question) => question.id === id);
    if (index <= 0) return;
    const current = questions[index];
    if (questions[index - 1].kind !== "question" || current.children.length !== 0) return;
    questions.splice(index, 1);
    questions[index - 1].children.push(current);
  },

  /// Un point remonte au premier niveau, juste après sa question. Les points
  /// qui le suivaient restent à leur question.
  outdent(id: string, questions: DetectedSubQuestion[]): void {
    for (let index = 0; index < questions.length; index++) {
      const child = questions[index].children.findIndex((question) => question.id === id);
      if (child < 0) continue;
      const [moved] = questions[index].children.splice(child, 1);
      questions.splice(index + 1, 0, moved);
      return;
    }
  },

  /// Ajoute un point à une question : « c » après « b ».
  addChild(to: string, questions: DetectedSubQuestion[]): void {
    const index = questions.findIndex((question) => question.id === to);
    if (index < 0) return;
    const kids = questions[index].children;
    const label = SubQuestionTree.nextLabel(lastPart(kids)?.label ?? null, "a");
    questions[index].children.push(DetectedSubQuestion.make(label));
  },

  addQuestion(questions: DetectedSubQuestion[]): void {
    const questionsOnly = questions.filter((question) => question.kind === "question");
    const last = lastPart(questionsOnly)?.label ?? null;
    questions.push(DetectedSubQuestion.make(SubQuestionTree.nextLabel(last, "1")));
  },

  /// Déplace une question du premier niveau (ses points la suivent).
  move(questions: DetectedSubQuestion[], from: readonly number[], to: number): void {
    const source = [...from].sort((a, b) => a - b);
    if (source.length === 0) return;
    const moving = source.map((index) => questions[index]);
    const rest = questions.filter((_, index) => !source.includes(index));
    let destination = to;
    for (const index of source) if (index < to) destination -= 1;
    rest.splice(Math.max(0, Math.min(rest.length, destination)), 0, ...moving);
    questions.splice(0, questions.length, ...rest);
  },

  /// Réécrit les étiquettes dans l'ordre : 1, 2, 3 et a, b, c sous chacune.
  relabel(questions: DetectedSubQuestion[]): void {
    let rank = 0;
    for (const question of questions) {
      if (question.kind !== "question") continue;
      rank += 1;
      question.label = String(rank);
      question.children.forEach((child, index) => { child.label = SubQuestionTree.letter(index); });
    }
  },

  /// « 3 » après « 2 », « c » après « b », « iv » après « iii ».
  nextLabel(after: string | null, fallback: string): string {
    if (after === null || after === "") return fallback;
    const value = swiftWholeInt(after);
    if (value !== null) return String(value + 1);
    const romanIndex = SubQuestionTree.romans.indexOf(after);
    if (romanIndex >= 0 && romanIndex + 1 < SubQuestionTree.romans.length) {
      return SubQuestionTree.romans[romanIndex + 1];
    }
    if (characters(after).length === 1) {
      const scalar = after.codePointAt(0);
      if (scalar !== undefined) {
        const next = String.fromCodePoint(scalar + 1);
        if (next.length > 0 && !(next.length === 1 && next.charCodeAt(0) >= 0xd800 && next.charCodeAt(0) <= 0xdfff)) return next;
      }
    }
    return fallback;
  },

  letter(index: number): string {
    return String.fromCharCode(97 + Math.min(index, 25));
  },

  romans: ["i", "ii", "iii", "iv", "v", "vi", "vii", "viii", "ix", "x", "xi", "xii"],

  // MARK: Plan en une ligne

  /// L'arbre écrit en une ligne : « 1(a-d) 2(a-e) 3 + ».
  ///
  /// C'est aussi une **saisie** : taper le plan d'un exercice est plus rapide
  /// que d'ajouter neuf lignes une par une, et c'est la forme sous laquelle on
  /// lit un polycopié.
  outline(questions: DetectedSubQuestion[]): string {
    return questions.map((question) => {
      if (question.kind === "part") return "+";
      const labels = question.children.map((child) => child.label);
      const first = labels[0];
      const last = lastPart(labels);
      if (first === undefined || last === undefined) return question.label;
      if (labels.length >= 3 && sameLabels(labels, SubQuestionTree.expand(first, last))) {
        return `${question.label}(${first}-${last})`;
      }
      return `${question.label}(${labels.join(",")})`;
    }).join(" ");
  },

  /// Lit un plan. Les textes des questions existantes sont repris quand leur
  /// étiquette ne change pas : réécrire le plan ne doit pas effacer ce qui a
  /// été saisi. Renvoie `null` si le plan est illisible.
  parse(text: string, previous: DetectedSubQuestion[] = []): DetectedSubQuestion[] | null {
    const result: DetectedSubQuestion[] = [];
    let remaining = characters(trimAll(text));
    let partIndex = 0;
    const previousParts = previous.filter((question) => question.kind === "part");

    const skipSeparators = (): void => {
      while (remaining.length > 0 && (remaining[0] === " " || remaining[0] === "," || remaining[0] === ";")) {
        remaining.shift();
      }
    };
    const token = (): string => {
      let value = "";
      while (remaining.length > 0) {
        const first = remaining[0];
        if (!(isLetter(first) || isNumber(first) || first === "-" || first === "–")) break;
        value += first === "–" ? "-" : first;
        remaining.shift();
      }
      return value;
    };

    skipSeparators();
    while (remaining.length > 0) {
      if (remaining[0] === "+") {
        remaining.shift();
        const kept = partIndex < previousParts.length ? previousParts[partIndex] : null;
        partIndex += 1;
        result.push(DetectedSubQuestion.make("", { text: kept?.text ?? "", kind: "part" }));
        skipSeparators();
        continue;
      }
      const head = token();
      if (head === "") return null;
      const labels = SubQuestionTree.rangeLabels(head);
      if (labels.length === 0) return null;
      let childLabels: string[] = [];
      if (remaining[0] === "(") {
        remaining.shift();
        const close = remaining.indexOf(")");
        if (close < 0) return null;
        const inside = remaining.slice(0, close).join("");
        remaining = remaining.slice(close + 1);
        for (const piece of inside.split(/[, ]+/u).filter((part) => part !== "")) {
          const expanded = SubQuestionTree.rangeLabels(piece.split("–").join("-"));
          if (expanded.length === 0) return null;
          childLabels = childLabels.concat(expanded);
        }
        // « 1-3(a-b) » : chaque question reçoit les mêmes points.
      }
      for (const label of labels) {
        const old = previous.find((question) => question.kind === "question" && question.label === label);
        result.push(DetectedSubQuestion.make(label, {
          text: old?.text ?? "",
          children: childLabels.map((child) => DetectedSubQuestion.make(child, {
            text: old?.children.find((item) => item.label === child)?.text ?? "",
          })),
        }));
      }
      skipSeparators();
    }
    return result;
  },

  /// « 3-5 » → 3, 4, 5 ; « a-d » → a…d ; « ii-iv » → ii, iii, iv ; « 7 » → 7.
  rangeLabels(token: string): string[] {
    const parts = token.split("-");
    if (parts.length === 1) return parts[0] === "" ? [] : [parts[0].toLowerCase()];
    if (!(parts.length === 2 && parts[0] !== "" && parts[1] !== "")) return [];
    return SubQuestionTree.expand(parts[0].toLowerCase(), parts[1].toLowerCase());
  },

  expand(first: string, last: string): string[] {
    const a = swiftWholeInt(first);
    const b = swiftWholeInt(last);
    if (a !== null && b !== null && a <= b && b - a < 60) {
      return Array.from({ length: b - a + 1 }, (_, index) => String(a + index));
    }
    const romanA = SubQuestionTree.romans.indexOf(first);
    const romanB = SubQuestionTree.romans.indexOf(last);
    if (romanA >= 0 && romanB >= 0 && romanA <= romanB
      && !(characters(first).length === 1 && characters(last).length === 1 && first !== "i")) {
      return SubQuestionTree.romans.slice(romanA, romanB + 1);
    }
    if (characters(first).length === 1 && characters(last).length === 1 && isLetter(first)) {
      const start = first.codePointAt(0)!;
      const end = last.codePointAt(0)!;
      if (start <= end && end - start < 26) {
        return Array.from({ length: end - start + 1 }, (_, index) => String.fromCodePoint(start + index));
      }
    }
    return [];
  },
};

function lastPart<T>(items: readonly T[]): T | undefined {
  return items[items.length - 1];
}

function sameLabels(a: string[], b: string[]): boolean {
  return a.length === b.length && a.every((label, index) => label === b[index]);
}

// MARK: - Enregistrement

export interface SeriesDraftOutcome {
  created: number;
  updated: number;
  deleted: number;
}

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
export type SeriesDraftMode = "importMerge" | "edit" | "revision";

export const SeriesDraftWriter = {
  /** La marque que posait la première version des révisions sur un exercice
   * retiré ; ces exercices sont supprimés au passage (`SeriesAutoReader`). */
  removedMark: "retiré de l'énoncé",

  write(draft: SeriesDraft, course: Course, mode: SeriesDraftMode,
    context: ModelStore | null): { series: ExerciseSeries; outcome: SeriesDraftOutcome } {
    const outcome: SeriesDraftOutcome = { created: 0, updated: 0, deleted: 0 };
    const title = trimAll(draft.title);

    let series: ExerciseSeries;
    const existing: ExerciseSeries | undefined = mode === "edit"
      ? course.series.find((item) => item.id === draft.existingID)
      : course.series.find((item) => item.id === draft.existingID)
          ?? course.seriesWith(draft.number, draft.label) ?? undefined;
    if (existing) {
      series = existing;
      series.seriesNumber = draft.number;
      if (mode === "edit" || draft.label !== "") series.label = SeriesIdentity.normalized(draft.label);
      if (mode === "edit" || title !== "") {
        series.title = title === "" ? draft.displayName : title;
      }
      if (mode === "edit") {
        series.plannedWeek = draft.plannedWeek;
        series.dueDate = draft.dueDate;
      }
    } else {
      // Le constructeur pose la relation inverse : inutile de repousser la
      // série dans `course.series` quand `context` est nul.
      series = new ExerciseSeries({
        course,
        seriesNumber: draft.number,
        label: draft.label,
        title,
        plannedWeek: draft.plannedWeek,
        dueDate: draft.dueDate,
      });
      context?.insert(series);
    }

    const kept = new Set<string>();
    const usedNumbers = new Set<string>();
    // Import et révision : chaque ligne retrouve son exercice par le contenu.
    const byContent = new Map<number, Exercise>();
    if (mode !== "edit") {
      const olds = series.sortedExercises;
      const found = SeriesReconciler.match(
        olds.map((exercise) => ({
          number: exercise.exerciseNumber,
          title: exercise.title,
          statement: exercise.statement,
        })),
        draft.exercises.map((exercise) => ({
          number: `${draft.number}.${exercise.minor}`,
          title: exercise.title,
          statement: exercise.statement,
        })));
      found.forEach((oldIndex, index) => {
        if (oldIndex !== null) byContent.set(index, olds[oldIndex]);
      });
    }
    const byContentExercises = new Set(byContent.values());
    for (let order = 0; order < draft.exercises.length; order++) {
      const item = draft.exercises[order];
      const minor = trimAll(item.minor);
      if (minor === "") continue;
      const number = `${draft.number}.${minor}`;
      if (usedNumbers.has(number)) continue;
      usedNumbers.add(number);
      const itemTitle = trimAll(item.title);

      let matched: Exercise | undefined;
      if (mode === "edit") {
        matched = series.exercises.find((exercise) => exercise.id === item.existingID);
      } else {
        matched = item.existingID !== null
          ? series.exercises.find((exercise) => exercise.id === item.existingID)
          : undefined;
        matched ??= byContent.get(order);
        // Le numéro, seulement à l'import et si cet exercice n'est
        // pas déjà celui d'une autre ligne.
        if (matched === undefined && mode === "importMerge") {
          matched = series.exercises.find((exercise) =>
            exercise.exerciseNumber === number
            && !kept.has(exercise.id)
            && !byContentExercises.has(exercise));
        }
      }
      if (matched !== undefined && !kept.has(matched.id)) {
        matched.exerciseNumber = number;
        // Une lecture sans titre ne retire pas celui qu'on avait.
        if (mode === "edit" || itemTitle !== "") matched.title = itemTitle;
        // Un import sans énoncé (lecture locale) n'efface pas celui qu'on avait.
        const statement = trimAll(item.statement);
        if (mode === "edit" || statement !== "") matched.statement = statement;
        matched.isBonus = item.isBonus;
        matched.sortOrder = order;
        // Réécrire un arbre identique effacerait les dates des cases
        // cochées pour rien.
        if (!sameQuestions(matched.detectedSubQuestions, item.subQuestions)) {
          matched.replaceSubQuestions(item.subQuestions, context);
        }
        kept.add(matched.id);
        outcome.updated += 1;
      } else {
        // Le constructeur pose déjà `series.exercises` via la relation inverse.
        const exercise = new Exercise({
          series,
          exerciseNumber: number,
          title: itemTitle,
          isBonus: item.isBonus,
          sortOrder: order,
        });
        exercise.statement = trimAll(item.statement);
        context?.insert(exercise);
        exercise.replaceSubQuestions(item.subQuestions, context);
        kept.add(exercise.id);
        outcome.created += 1;
      }
    }

    if (mode === "edit" || mode === "revision") {
      // Retiré de l'énoncé : il n'existe plus, il part. Les sessions qui
      // le visaient restent au cours (la relation se vide).
      const doomed = series.exercises.filter((exercise) => !kept.has(exercise.id));
      series.exercises = series.exercises.filter((exercise) => kept.has(exercise.id));
      for (const exercise of doomed) {
        context?.delete(exercise);
        outcome.deleted += 1;
      }
    } else {
      // Les exercices que le PDF ne cite pas restent, après ceux du PDF.
      let order = draft.exercises.length;
      for (const exercise of series.sortedExercises) {
        if (kept.has(exercise.id)) continue;
        exercise.sortOrder = order;
        order += 1;
      }
    }
    return { series, outcome };
  },
};

/// `==` d'un arbre de sous-questions : l'identité d'édition n'y entre pas.
function sameQuestions(
  left: DetectedSubQuestionData[],
  right: DetectedSubQuestion[],
): boolean {
  if (left.length !== right.length) return false;
  return left.every((item, index) => {
    const data = right[index];
    return item.label === data.label && item.text === data.text && item.kind === data.kind
      && sameQuestions(item.children, data.children);
  });
}
