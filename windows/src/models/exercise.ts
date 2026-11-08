import { ConfidenceLevel, Correctness, SubQuestionKind } from "./enums.ts";
import { defineToMany, defineToOne, newId } from "./relations.ts";
import type { ModelStore } from "./store.ts";
import { isLetter, trimAll, trimWhitespaces } from "./util.ts";
import type { Course } from "./course.ts";
import { SeriesIdentity, type SeriesKey } from "../domain/seriesIdentity.ts";
import type { LinkedTask } from "./linkedTask.ts";
import type { Mistake } from "./mistake.ts";
import type { StudySession } from "./studySession.ts";

/**
 * Une sous-question repérée par l'import (`DetectedSubQuestion`,
 * Services/SeriesPDFParser.swift) : la forme dans laquelle on relit et rédite
 * l'arbre d'un exercice. Deux niveaux : « 1) » porte ses points dans `children`.
 */
export interface DetectedSubQuestionData {
  label: string;
  text: string;
  kind: SubQuestionKind;
  children: DetectedSubQuestionData[];
}

// MARK: - Série

export interface ExerciseSeriesInit {
  id?: string;
  course?: Course | null;
  seriesNumber: number;
  /** « b », « mardi » : la deuxième série d'une semaine. */
  label?: string;
  title?: string;
  plannedWeek?: number;
  publishedAt?: Date | null;
  dueDate?: Date | null;
  urlString?: string;
}

/** Série d'exercices (« Série 1 ») contenant des sous-exercices. */
export class ExerciseSeries {
  static readonly modelName = "ExerciseSeries";

  id: string;
  declare course: Course | null;
  seriesNumber: number;
  /** Ce qui distingue deux séries de même numéro (« a », « mardi ») ; vide sinon. */
  label = "";
  title: string;
  plannedWeek: number;
  publishedAt: Date | null;
  dueDate: Date | null;
  urlString: string;
  /** Le thème de la série quand la source le donne (« Suites », « ℂ, Séries »). */
  topic = "";
  /** Quand le corrigé est publié, s'il l'est à date fixe (Botafogo). */
  solutionsAt: Date | null = null;
  /** Où lire le corrigé (le PDF « Corrigé série 3 » de Moodle, la page de la série sur Botafogo). */
  solutionURLString = "";
  /** L'énoncé est à relire (son adresse a changé) : la lecture automatique repasse, en gardant l'avancement. */
  needsReread = false;

  declare exercises: Exercise[];
  declare exercisesStore: Exercise[];

  constructor(o: ExerciseSeriesInit) {
    this.id = o.id ?? newId();
    this.course = o.course ?? null;
    this.seriesNumber = o.seriesNumber;
    this.label = SeriesIdentity.normalized(o.label ?? "");
    this.title = (o.title ?? "") === "" ? SeriesIdentity.displayName(o.seriesNumber, this.label) : o.title!;
    this.plannedWeek = o.plannedWeek ?? 1;
    this.publishedAt = o.publishedAt ?? null;
    this.dueDate = o.dueDate ?? null;
    this.urlString = o.urlString ?? "";
  }

  /** Numéro et étiquette : ce qui identifie la série dans son cours. */
  get key(): SeriesKey { return SeriesIdentity.key(this.seriesNumber, this.label); }
  get displayName(): string { return SeriesIdentity.displayName(this.seriesNumber, this.label); }

  get sortedExercises(): Exercise[] {
    return [...this.exercises].sort((a, b) => a.sortOrder - b.sortOrder);
  }

  get requiredExercises(): Exercise[] { return this.exercises.filter((e) => !e.isBonus); }
  get bonusExercises(): Exercise[] { return this.exercises.filter((e) => e.isBonus); }

  get doneCount(): number { return this.requiredExercises.filter((e) => e.doneAt !== null).length; }
  get correctedCount(): number { return this.requiredExercises.filter((e) => e.doneAt !== null && e.correctedAt !== null).length; }

  /**
   * La série est-elle échue ? Son échéance quand elle en a une (« à rendre jeudi » :
   * pas en retard le lundi), sinon la fin de sa semaine prévue.
   */
  isDue(beforeWeek: number, now: Date = new Date()): boolean {
    if (this.dueDate) return this.dueDate <= now;
    return this.plannedWeek > 0 && this.plannedWeek < beforeWeek;
  }

  get isComplete(): boolean {
    const required = this.requiredExercises;
    return required.length !== 0 && this.doneCount === required.length;
  }

  get progress(): number {
    const required = this.requiredExercises;
    return required.length === 0 ? 0 : this.doneCount / required.length;
  }
}

defineToOne(ExerciseSeries, "course", "seriesStore");
defineToMany(ExerciseSeries, "exercises", "series", "exercisesStore");

// MARK: - Exercice

export interface ExerciseInit {
  id?: string;
  series?: ExerciseSeries | null;
  exerciseNumber: string;
  title?: string;
  isBonus?: boolean;
  sortOrder?: number;
  statementURLString?: string;
}

/** Un indice reçu (`Exercise.hints`). */
export interface HintEntry {
  date: Date;
  level: number;
  text: string;
}

/** Sous-exercice (« exercice 1.1 », « 1.2 ») avec suivi complet. */
export class Exercise {
  static readonly modelName = "Exercise";

  id: string;
  declare series: ExerciseSeries | null;
  /** Numéro affiché : « 1.1 ». */
  exerciseNumber: string;
  title: string;
  /**
   * Ce que l'exercice demande, en une phrase. Sans elle, un exercice sans questions
   * numérotées n'était qu'un numéro et un titre. Lue par l'IA sur la page.
   */
  statement = "";
  isBonus: boolean;
  sortOrder: number;
  statementURLString: string;
  /** L'indication de l'énoncé, quand la source en donne une (Botafogo). */
  hint = "";
  /**
   * La solution, quand la source la publie : affichée seulement à partir de
   * `series.solutionsAt`, pour ne pas la lire avant d'avoir cherché.
   */
  solution = "";

  // Fait
  doneAt: Date | null = null;
  /** ConfidenceLevel.rawValue — code couleur vert / orange / rouge. */
  confidenceRaw: string | null = null;

  // Correction
  correctedAt: Date | null = null;
  /** Correctness.rawValue — juste / moyennement juste / faux. */
  correctnessRaw: string | null = null;
  redoRequired = false;
  correctionNote: string | null = null;
  score: number | null = null;
  maxScore: number | null = null;

  /**
   * Les sous-questions — « 1. », « 2. », « (a) » — d'un même exercice. Un polycopié
   * regroupe souvent sous un seul numéro plusieurs questions : les compter comme des
   * exercices séparés gonfle la liste et fausse la progression.
   */
  declare subQuestions: SubQuestion[];
  declare subQuestionsStore: SubQuestion[];

  /** Les sessions et les tâches qui visent cet exercice. */
  declare targetedSessions: StudySession[];
  declare targetedTasks: LinkedTask[];

  // Carnet d'erreurs, file de reprise, indices (tous facultatifs).

  /** Les erreurs notées sur cet exercice. */
  declare mistakesStore: Mistake[];

  /** Le palier de la file de reprise (indice dans `RedoLadder.Config.steps`) ; `null` : pas dans la file. */
  redoPass: number | null = null;
  /** Quand le refaire (`null` au palier « pré-examen » sans date d'examen). */
  redoDueAt: Date | null = null;
  /** Pourquoi il est en file : le type d'erreur et ce qui a coincé. */
  redoWhy = "";
  /** Le premier geste — montré seulement après une tentative. */
  redoFirstMove = "";
  /** Les échecs de suite au même palier. */
  redoFailures = 0;
  /** `RedoLadder.Result.rawValue` de la dernière reprise. */
  redoLastResultRaw: string | null = null;
  /** Sorti de la file (réussi sans notes, ou après le dernier palier). */
  redoClearedAt: Date | null = null;

  /** Le niveau d'indice le plus haut reçu (0 aucun · 1 orientation · 2 outil · 3 amorce · 4 solution). */
  hintLevel = 0;
  /** Les indices reçus, une ligne chacun : « date|niveau|texte ». */
  hintLog = "";

  constructor(o: ExerciseInit) {
    this.id = o.id ?? newId();
    this.series = o.series ?? null;
    this.exerciseNumber = o.exerciseNumber;
    this.title = o.title ?? "";
    this.isBonus = o.isBonus ?? false;
    this.sortOrder = o.sortOrder ?? 0;
    this.statementURLString = o.statementURLString ?? "";
    this.redoRequired = false;
  }

  /** Les erreurs, de la plus ancienne à la plus récente. */
  get mistakes(): Mistake[] {
    return [...this.mistakesStore].sort((a, b) => a.createdAt.getTime() - b.createdAt.getTime());
  }

  /** « Exercice 3.2 ». */
  get displayNumber(): string { return `Exercice ${this.exerciseNumber}`; }

  /**
   * Le numéro partagé avec un groupe : « 5.1 », ou « 5b.1 » pour un exercice de la
   * série 5b — sinon le 5.1 de 5a et celui de 5b se confondaient. Inchangé sans étiquette.
   */
  get groupNumber(): string {
    const series = this.series;
    if (!series || series.label === "") return this.exerciseNumber;
    const parts = this.exerciseNumber.split(".");
    return `${series.seriesNumber}${series.label.replace(/ /g, "")}.${parts[parts.length - 1]}`;
  }
  get isDone(): boolean { return this.doneAt !== null; }
  get isCorrected(): boolean { return this.correctedAt !== null; }
  /** Fait **au sens de la progression** — comme `ExerciseStage.isDone` : un exercice à refaire n'est pas fait. */
  get countsAsDone(): boolean { return this.isDone && !this.redoRequired; }

  // MARK: Sous-questions

  /**
   * Les questions **de premier niveau**, dans l'ordre du polycopié. `subQuestions`
   * contient tous les nœuds — premier et second niveau — parce que chacun garde son
   * lien vers l'exercice. L'arbre se lit par `parent` / `children`.
   */
  get sortedSubQuestions(): SubQuestion[] {
    return this.subQuestions.filter((q) => q.parent === null).sort((a, b) => a.sortOrder - b.sortOrder);
  }

  /**
   * Les cases à cocher réelles : les questions sans sous-questions. « 1) (a) (b) 2) (a) »
   * compte **trois** cases, pas cinq.
   */
  get leafSubQuestions(): SubQuestion[] {
    return this.sortedSubQuestions.flatMap((q) => {
      const kids = q.sortedChildren;
      return kids.length === 0 ? [q] : kids;
    });
  }

  get hasSubQuestions(): boolean { return this.subQuestions.length !== 0; }
  get subQuestionDoneCount(): number { return this.leafSubQuestions.filter((q) => q.isDone).length; }

  /** « 2/3 », ou `null` quand l'exercice n'a pas de sous-questions. */
  get subQuestionLabel(): string | null {
    if (!this.hasSubQuestions) return null;
    return `${this.subQuestionDoneCount}/${this.leafSubQuestions.length}`;
  }

  /**
   * Marque toutes les sous-questions d'un coup : cocher l'exercice entier est le geste
   * courant ; le refuser obligerait à ouvrir chaque sous-question une par une.
   */
  setSubQuestions(done: boolean): void {
    const now = new Date();
    for (const question of this.subQuestions) {
      question.isDone = done;
      question.doneAt = done ? (question.doneAt ?? now) : null;
    }
    this.doneAt = done ? (this.doneAt ?? now) : null;
  }

  /**
   * Recalcule « fait » à partir des sous-questions. `doneAt` reste la **seule** vérité
   * pour tout le reste de l'app — séries, progression, statistiques, groupes.
   */
  refreshCompletion(): void {
    if (!this.hasSubQuestions) return;
    for (const question of this.sortedSubQuestions) {
      if (question.children.length !== 0) question.refreshFromChildren();
    }
    if (this.leafSubQuestions.every((q) => q.isDone)) {
      this.doneAt = this.doneAt ?? new Date();
    } else {
      // Comme `setDone(false)` : un exercice qui n'est plus fait n'a plus de correction
      // (jamais « à faire » et juste, ni plus de corrigés que de faits). « À refaire » reste.
      this.doneAt = null;
      this.correctnessRaw = null;
      this.correctedAt = null;
      this.confidenceRaw = null;
    }
  }

  /**
   * Remplace l'arbre des sous-questions par celui d'une relecture.
   *
   * L'ancienne version de l'import ne faisait qu'**ajouter** les étiquettes manquantes :
   * une question mal lue restait pour toujours. L'arbre relu fait foi ; l'état « fait »
   * est repris sur chaque case dont le chemin (« 1 », « 1.a ») existait déjà — c'est du
   * travail de l'étudiant·e, pas de l'import.
   */
  replaceSubQuestions(questions: DetectedSubQuestionData[], store: ModelStore | null = null): void {
    const done = new Map<string, Date>();
    for (const question of this.subQuestions) {
      if (question.isDone && question.children.length === 0) done.set(question.path, question.doneAt ?? new Date());
    }
    const old = [...this.subQuestions];
    this.subQuestions = [];
    for (const question of old) store?.delete(question);

    const make = (detected: DetectedSubQuestionData, parent: SubQuestion | null, order: number): SubQuestion => {
      // Le constructeur range déjà le nœud dans `subQuestions` (et dans `parent.children`).
      const node = new SubQuestion({
        exercise: this,
        parent,
        label: trimWhitespaces(detected.label),
        text: trimAll(detected.text),
        kind: detected.kind,
        sortOrder: order,
      });
      store?.insert(node);
      const doneAt = done.get(node.path);
      if (doneAt) {
        node.isDone = true;
        node.doneAt = doneAt;
      }
      return node;
    };
    questions.forEach((question, index) => {
      const node = make(question, null, index);
      question.children.forEach((child, childIndex) => make(child, node, childIndex));
      node.refreshFromChildren();
    });
    if (this.subQuestions.length === 0) {
      // Plus aucune question : l'exercice garde son propre état.
      return;
    }
    this.refreshCompletion();
  }

  /** L'arbre, dans la forme de la relecture — pour le rééditer. */
  get detectedSubQuestions(): DetectedSubQuestionData[] {
    return this.sortedSubQuestions.map((q) => ({
      label: q.label,
      text: q.text,
      kind: q.kind,
      children: q.sortedChildren.map((c) => ({ label: c.label, text: c.text, kind: c.kind, children: [] })),
    }));
  }

  get confidence(): ConfidenceLevel | null {
    return (this.confidenceRaw !== null ? ConfidenceLevel.fromRaw(this.confidenceRaw) : undefined) ?? null;
  }
  set confidence(value: ConfidenceLevel | null) {
    this.confidenceRaw = value;
  }

  get correctness(): Correctness | null {
    return (this.correctnessRaw !== null ? Correctness.fromRaw(this.correctnessRaw) : undefined) ?? null;
  }
  set correctness(value: Correctness | null) {
    this.correctnessRaw = value;
  }

  /** Dans la file de reprise ? */
  get isQueuedForRedo(): boolean { return this.redoPass !== null; }

  /**
   * À refaire **maintenant** : marqué à refaire hors de la file de reprise, ou dans la
   * file et arrivé à son palier. Le palier « pré-examen » sans date d'examen n'est pas dû.
   */
  isRedoDue(now: Date = new Date()): boolean {
    if (!this.redoRequired) return false;
    if (!this.isQueuedForRedo) return true;
    return this.redoDueAt !== null && this.redoDueAt <= now;
  }

  /** Les indices reçus, du plus ancien au plus récent. */
  get hints(): HintEntry[] {
    const result: HintEntry[] = [];
    for (const line of this.hintLog.split("\n")) {
      if (line === "") continue;
      // `split(separator: "|", maxSplits: 2)` : trois morceaux au plus, vides omis.
      const pieces: string[] = [];
      let rest = line;
      for (let i = 0; i < 2; i++) {
        const at = rest.indexOf("|");
        if (at < 0) break;
        pieces.push(rest.slice(0, at));
        rest = rest.slice(at + 1);
      }
      pieces.push(rest);
      const parts = pieces.filter((p) => p !== "");
      if (parts.length !== 3) continue;
      const stamp = Number(parts[0]);
      if (parts[0].trim() !== parts[0] || Number.isNaN(stamp) || !/^[+-]?\d+$/.test(parts[1])) continue;
      result.push({ date: new Date(stamp * 1000), level: Number(parts[1]), text: parts[2] });
    }
    return result;
  }

  /** Note un indice reçu (le journal ne garde que les 20 derniers). */
  recordHint(level: number, text: string, at: Date = new Date()): void {
    const clean = text.replace(/\n/g, " ").replace(/\|/g, "/");
    const lines = this.hintLog.split("\n").filter((l) => l !== "");
    lines.push(`${Math.trunc(at.getTime() / 1000)}|${level}|${clean}`);
    this.hintLog = lines.slice(-20).join("\n");
    this.hintLevel = Math.max(this.hintLevel, level);
  }
}

defineToOne(Exercise, "series", "exercisesStore");
defineToMany(Exercise, "subQuestions", "exercise", "subQuestionsStore");
defineToMany(Exercise, "targetedSessions", "exercise");
defineToMany(Exercise, "targetedTasks", "exercise");
defineToMany(Exercise, "mistakesStore", "exercise");

// MARK: - Sous-question

export interface SubQuestionInit {
  id?: string;
  exercise?: Exercise | null;
  parent?: SubQuestion | null;
  label: string;
  text?: string;
  kind?: SubQuestionKind;
  isDone?: boolean;
  sortOrder?: number;
}

/**
 * Une sous-question d'un exercice : « 1. », « 2. », « (a) », « (b) ». Elle a son propre
 * état — fait ou non — parce que c'est ainsi qu'on travaille : on fait la première
 * question, on bute sur la deuxième, on y revient.
 */
export class SubQuestion {
  static readonly modelName = "SubQuestion";

  id: string;
  declare exercise: Exercise | null;
  /**
   * La question dont celle-ci est un point : « (a) » sous « 1) ». `null` au premier
   * niveau. Deux niveaux au plus — c'est ce que les polycopiés font.
   */
  declare parent: SubQuestion | null;
  declare children: SubQuestion[];
  declare childrenStore: SubQuestion[];
  /**
   * L'étiquette telle qu'elle apparaît dans le polycopié : « 1 », « 2 », « a ». Vide
   * pour une partie sans numéro (« Ensuite, … »).
   */
  label: string;
  /** L'énoncé court, quand il a pu être lu. */
  text: string;
  /** `SubQuestionKind.rawValue`. Une « partie » est un travail demandé sans numéro. */
  kindRaw: string;
  isDone: boolean;
  doneAt: Date | null;
  sortOrder: number;

  constructor(o: SubQuestionInit) {
    this.id = o.id ?? newId();
    this.exercise = o.exercise ?? null;
    this.parent = o.parent ?? null;
    this.label = o.label;
    this.text = o.text ?? "";
    this.kindRaw = o.kind ?? "question";
    this.isDone = o.isDone ?? false;
    this.doneAt = this.isDone ? new Date() : null;
    this.sortOrder = o.sortOrder ?? 0;
  }

  get kind(): SubQuestionKind {
    return SubQuestionKind.fromRaw(this.kindRaw) ?? "question";
  }
  set kind(value: SubQuestionKind) {
    this.kindRaw = value;
  }

  get sortedChildren(): SubQuestion[] {
    return [...this.children].sort((a, b) => a.sortOrder - b.sortOrder);
  }

  /**
   * Le chemin stable de la question : « 1 », « 1.a ». Sert à retrouver une case cochée
   * quand on remplace l'arbre par un nouvel import.
   */
  get path(): string {
    const own = this.label === "" ? `#${this.sortOrder}` : this.label;
    return this.parent ? `${this.parent.path}.${own}` : own;
  }

  /** « 1. » ou « (a). », selon ce que le polycopié écrit. */
  get displayLabel(): string {
    const trimmed = trimWhitespaces(this.label);
    if (trimmed === "") return "";
    // Une étiquette déjà ponctuée n'est pas reponctuée.
    if (trimmed.endsWith(".") || trimmed.endsWith(")") || trimmed.endsWith(":")) return trimmed;
    return Array.from(trimmed).length === 1 && isLetter(trimmed) ? `(${trimmed})` : `${trimmed}.`;
  }

  /**
   * Une question avec des points se coche **par ses points** : la toucher coche ou
   * décoche tous ses points d'un coup.
   */
  toggle(): void {
    const target = !this.isDone;
    if (this.children.length === 0) {
      this.isDone = target;
      this.doneAt = target ? new Date() : null;
    } else {
      const now = new Date();
      for (const child of this.children) {
        child.isDone = target;
        child.doneAt = target ? (child.doneAt ?? now) : null;
      }
      this.refreshFromChildren();
    }
    this.parent?.refreshFromChildren();
    (this.exercise ?? this.parent?.exercise ?? null)?.refreshCompletion();
  }

  /** Une question à points est faite quand tous ses points le sont. */
  refreshFromChildren(): void {
    if (this.children.length === 0) return;
    const all = this.children.every((c) => c.isDone);
    this.isDone = all;
    this.doneAt = all ? (this.doneAt ?? new Date()) : null;
  }
}

defineToOne(SubQuestion, "exercise", "subQuestionsStore");
defineToOne(SubQuestion, "parent", "childrenStore");
defineToMany(SubQuestion, "children", "parent", "childrenStore");
