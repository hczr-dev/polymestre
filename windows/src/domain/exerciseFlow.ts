// Où en est un exercice, en **une** valeur, et le parcours d'une série
// (Polymestre/Domain/ExerciseFlow.swift).
//
// Le code vert / orange / rouge est celui de la **correction** — juste,
// moyen, faux — et non une « sureté » donnée en cochant : c'est en corrigeant
// qu'on sait si c'était juste. Le parcours d'un exercice est donc : à faire →
// questions en cours → fait (à corriger) → corrigé vert, orange ou rouge ;
// rouge le marque « à refaire », qui prime tant qu'il n'est pas refait.
//
// Les méthodes `setDone` / `correct` / `clearCorrection` sont l'extension
// `Exercise` du même fichier Swift : elles sont ajoutées au prototype ici, pour
// que les appels gardent le nom Swift sans modifier le modèle.

import { Correctness } from "../models/enums.ts";
import { Exercise, ExerciseSeries } from "../models/exercise.ts";

/// L'état d'un exercice, avec ses valeurs associées.
export type ExerciseStage =
  | { kind: "toDo" }
  | { kind: "inProgress"; done: number; total: number }
  | { kind: "toCorrect" }
  | { kind: "corrected"; correctness: Correctness }
  | { kind: "redo" };

interface ExerciseStageCallable {
  (exercise: Exercise): ExerciseStage;
  isOpen(stage: ExerciseStage): boolean;
  isDone(stage: ExerciseStage): boolean;
  label(stage: ExerciseStage): string;
}

function stageOf(exercise: Exercise): ExerciseStage {
  if (exercise.redoRequired) return { kind: "redo" };
  const correctness = exercise.correctness;
  if (correctness !== null && exercise.isCorrected && exercise.isDone) return { kind: "corrected", correctness };
  if (exercise.isDone) return { kind: "toCorrect" };
  if (exercise.hasSubQuestions && exercise.subQuestionDoneCount > 0) {
    return { kind: "inProgress", done: exercise.subQuestionDoneCount, total: exercise.leafSubQuestions.length };
  }
  return { kind: "toDo" };
}

function stageIsOpen(stage: ExerciseStage): boolean {
  if (stage.kind === "corrected") return stage.correctness === "wrong";
  return true;
}

function stageIsDone(stage: ExerciseStage): boolean {
  switch (stage.kind) {
    case "toDo": case "inProgress": case "redo": return false;
    case "toCorrect": case "corrected": return true;
  }
}

function stageLabel(stage: ExerciseStage): string {
  switch (stage.kind) {
    case "toDo": return "à faire";
    case "inProgress": return `${stage.done}/${stage.total}`;
    case "toCorrect": return "à corriger";
    case "corrected": return Correctness.shortLabel(stage.correctness).toLowerCase();
    case "redo": return "à refaire";
  }
}

/// `ExerciseStage(exercise)` et ses propriétés calculées.
export const ExerciseStage: ExerciseStageCallable = Object.assign(stageOf, {
  isOpen: stageIsOpen,
  isDone: stageIsDone,
  label: stageLabel,
});

// MARK: Extension Exercise

declare module "../models/exercise.ts" {
  interface Exercise {
    /** Marque l'exercice fait ou à faire — questions comprises. */
    setDone(done: boolean): void;
    /** Enregistre la correction — la couleur de l'exercice. */
    correct(result: Correctness): void;
    /** Retire la correction (un toucher de trop sur une pastille). */
    clearCorrection(): void;
  }
}

Exercise.prototype.setDone = function setDone(this: Exercise, done: boolean): void {
  if (this.hasSubQuestions) {
    this.setSubQuestions(done);
  } else {
    this.doneAt = done ? (this.doneAt ?? new Date()) : null;
  }
  // Décocher efface aussi la correction : un exercice « à faire » n'a pas
  // encore de couleur.
  if (!done) {
    this.correctness = null;
    this.correctedAt = null;
    this.confidence = null;
  }
};

Exercise.prototype.correct = function correct(this: Exercise, result: Correctness): void {
  if (!this.isDone) this.setDone(true);
  this.correctness = result;
  this.correctedAt = new Date();
  switch (result) {
    case "wrong": this.redoRequired = true; break;
    case "correct": this.redoRequired = false; break;
    case "partial": break;
  }
};

Exercise.prototype.clearCorrection = function clearCorrection(this: Exercise): void {
  this.correctness = null;
  this.correctedAt = null;
  this.redoRequired = false;
};

// MARK: Parcours

/// Le parcours d'une série, exercice après exercice.
export const ExerciseFlow = {
  /// L'exercice où reprendre la série : le premier qui n'est pas fait, dans
  /// l'ordre du polycopié ; à défaut, le premier à refaire, puis un bonus pas
  /// fait, puis le premier à juger ou à corriger. `null` quand tout est corrigé.
  ///
  /// Les bonus passent après les exercices obligatoires **et** après ce qui
  /// est à refaire : on ne reprend pas une série par son bonus.
  resumePoint(inExercises: Exercise[]): Exercise | null {
    const ordered = [...inExercises].sort((lhs, rhs) => {
      if (lhs.isBonus !== rhs.isBonus) return lhs.isBonus ? 1 : -1;
      return lhs.sortOrder - rhs.sortOrder;
    });
    const pending = (exercise: Exercise): boolean => !stageIsDone(stageOf(exercise)) && !exercise.redoRequired;
    const open = ordered.find((exercise) => !exercise.isBonus && pending(exercise));
    if (open) return open;
    const redo = ordered.find((exercise) => exercise.redoRequired);
    if (redo) return redo;
    const bonus = ordered.find(pending);
    if (bonus) return bonus;
    return ordered.find((exercise) => stageIsOpen(stageOf(exercise))) ?? null;
  },

  /// L'exercice qui suit `current` dans l'ordre de la série, en sautant ceux
  /// qui sont déjà faits — ce que « Suivant » propose une fois l'exercice fini.
  /// À défaut, simplement le suivant ; `null` en fin de série.
  next(after: Exercise, inExercises: Exercise[]): Exercise | null {
    const ordered = [...inExercises].sort((a, b) => a.sortOrder - b.sortOrder);
    const index = ordered.findIndex((exercise) => exercise.id === after.id);
    if (index < 0) return null;
    const rest = ordered.slice(index + 1);
    return rest.find((exercise) => !stageIsDone(stageOf(exercise))) ?? rest[0] ?? null;
  },

  /// Le temps passé sur un exercice : ses sessions enregistrées, plus ce que
  /// le chrono compte **en ce moment** sur lui.
  seconds(target: Exercise | ExerciseSeries, live = 0): number {
    if (target instanceof ExerciseSeries) {
      return target.exercises.reduce((total, exercise) => total + ExerciseFlow.seconds(exercise), 0);
    }
    return target.targetedSessions.reduce((total, session) => total + session.durationSeconds, 0) + Math.trunc(live);
  },
};
