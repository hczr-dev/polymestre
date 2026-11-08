// Progression d'un cours (Polymestre/Domain/ProgressEngine.swift).
//
// Le calcul est pur : il lit les relations d'un `Course` (théorie, séries,
// semestre) et ne touche ni au disque ni à l'interface. Les pourcentages sont
// des fractions (0 → 1) ; la mise en forme reste à l'affichage.

import { lateWork } from "./lateWork.ts";
import type { Course } from "../models/course.ts";
import type { Exercise } from "../models/exercise.ts";
import type { TheoryItem } from "../models/theoryItem.ts";

/** Agrégat des pourcentages d'un cours (théorie / exercices / corrections). */
export class CourseProgress {
  constructor(init: Partial<CourseProgress> = {}) { Object.assign(this, init); }

  videoCount = 0;
  watchedCount = 0;
  summarizedCount = 0;
  exerciseCount = 0;
  doneCount = 0;
  correctedCount = 0;
  bonusCount = 0;
  bonusDoneCount = 0;
  wrongOrRedoCount = 0;

  static ratio(value: number, total: number): number {
    return total <= 0 ? 0 : value / total;
  }

  /** Théorie : vidéos regardées / total. */
  get theoryPercent(): number { return CourseProgress.ratio(this.watchedCount, this.videoCount); }
  /** Exercices : exos (hors bonus) faits / total. */
  get exercisePercent(): number { return CourseProgress.ratio(this.doneCount, this.exerciseCount); }
  /** Corrections : exos corrigés / exos faits. */
  get correctionPercent(): number { return CourseProgress.ratio(this.correctedCount, this.doneCount); }

  /** Le chiffre d'un cours, en un nombre : la part faite de ce qui est à faire. */
  get completion(): number {
    return CourseProgress.ratio(this.watchedCount + this.doneCount, this.videoCount + this.exerciseCount);
  }

  get remainingVideos(): number { return Math.max(0, this.videoCount - this.watchedCount); }
  get remainingExercises(): number { return Math.max(0, this.exerciseCount - this.doneCount); }
}

/** Progression d'une semaine donnée. */
export class WeeklyProgress {
  week: number;
  videoCount = 0;
  watchedCount = 0;
  exerciseCount = 0;
  doneCount = 0;
  correctedCount = 0;
  /** Durée totale des vidéos restantes pour cette semaine. */
  remainingVideoSeconds = 0;
  /** Numéros des séries planifiées cette semaine (« Série 3 »). */
  seriesNumbers: number[] = [];

  constructor(week: number, init: Partial<WeeklyProgress> = {}) {
    this.week = week;
    Object.assign(this, init);
  }

  get id(): number { return this.week; }
  get theoryPercent(): number { return CourseProgress.ratio(this.watchedCount, this.videoCount); }
  get exercisePercent(): number { return CourseProgress.ratio(this.doneCount, this.exerciseCount); }
  get correctionPercent(): number { return CourseProgress.ratio(this.correctedCount, this.doneCount); }
  get hasItems(): boolean { return this.videoCount > 0 || this.exerciseCount > 0; }

  /** Ce qui reste, tous axes confondus (théorie non vue + exercices non faits). */
  get remainingCount(): number {
    return (this.videoCount - this.watchedCount) + (this.exerciseCount - this.doneCount);
  }
  get isComplete(): boolean { return this.hasItems && this.remainingCount === 0; }
}

/**
 * Les corrections à faire **hors du retard** : exercices faits, corrigé publié, d'une série
 * pas encore échue. Le retard compte déjà les séries échues et tout ce qui est à refaire ;
 * la carte affichait les deux côte à côte, et le même exercice y comptait deux fois.
 */
export class CorrectionsDue {
  constructor(init: Partial<CorrectionsDue> = {}) { Object.assign(this, init); }

  toCorrect = 0;
  get isEmpty(): boolean { return this.toCorrect === 0; }
}

// MARK: - Moteur

function progress(course: Course): CourseProgress {
  const p = new CourseProgress();
  const videos = course.theoryItems;
  p.videoCount = videos.length;
  p.watchedCount = videos.filter((v) => v.isWatched).length;
  p.summarizedCount = videos.filter((v) => v.isSummarized).length;

  const all = course.allExercises;
  const required = all.filter((e) => !e.isBonus);
  p.bonusCount = all.filter((e) => e.isBonus).length;
  p.bonusDoneCount = all.filter((e) => e.isBonus && e.isDone).length;
  p.exerciseCount = required.length;
  // Au sens de `ExerciseStage` : à refaire n'est pas fait ; corrigés ⩽ faits.
  p.doneCount = required.filter((e) => e.countsAsDone).length;
  p.correctedCount = required.filter((e) => e.countsAsDone && e.isCorrected).length;
  p.wrongOrRedoCount = all.filter((e) => e.redoRequired || e.correctness === "wrong").length;
  return p;
}

/** Ce qui aurait dû être fait **avant** cette semaine et ne l'est pas. */
function lateCount(course: Course, currentWeek?: number | null, now: Date = new Date()): number {
  // Une seule définition du retard : celle de la page « À rattraper ».
  return lateWork(course, currentWeek, now).total;
}

/** Les corrections à faire hors du retard (séries pas encore échues). */
function correctionsDue(course: Course, currentWeek?: number | null, now: Date = new Date()): CorrectionsDue {
  const week = currentWeek ?? course.dueWeek(now);
  const due = new CorrectionsDue();
  for (const series of course.series) {
    if (series.isDue(week, now)) continue;
    if (series.solutionsAt && series.solutionsAt > now) continue;
    for (const exercise of series.exercises) {
      if (exercise.isBonus && !exercise.isDone) continue;
      if (!exercise.redoRequired && exercise.isDone && !exercise.isCorrected) due.toCorrect += 1;
    }
  }
  return due;
}

/** Ce qui est fait **en avance** : éléments des semaines à venir déjà faits. */
function aheadCount(course: Course, currentWeek?: number | null): number {
  const week = currentWeek ?? course.currentWeek;
  const theory = course.theoryItems.filter((t) => t.plannedWeek > week && t.isWatched).length;
  const exercises = course.series
    .filter((s) => s.plannedWeek > week)
    .flatMap((s) => s.exercises)
    .filter((e) => !e.isBonus && e.countsAsDone)
    .length;
  return theory + exercises;
}

/** « À jour », « 3 en retard », « 2 d'avance » : l'état d'un cours en mots. */
function standingLabel(late: number, ahead: number): string {
  if (late > 0) return `${late} en retard`;
  if (ahead > 0) return `${ahead} d'avance`;
  return "À jour";
}

function weekProgress(course: Course, week: number): WeeklyProgress {
  const w = new WeeklyProgress(week);

  const videos = course.theoryItems.filter((t) => t.plannedWeek === week);
  w.videoCount = videos.length;
  w.watchedCount = videos.filter((t) => t.isWatched).length;
  w.remainingVideoSeconds = videos.filter((t) => !t.isWatched)
    .reduce((sum, t) => sum + t.durationSeconds, 0);

  const exercises = course.series
    .filter((s) => s.plannedWeek === week)
    .flatMap((s) => s.exercises)
    .filter((e) => !e.isBonus);
  w.exerciseCount = exercises.length;
  w.doneCount = exercises.filter((e) => e.countsAsDone).length;
  w.correctedCount = exercises.filter((e) => e.countsAsDone && e.isCorrected).length;
  w.seriesNumbers = course.series.filter((s) => s.plannedWeek === week).map((s) => s.seriesNumber).sort((a, b) => a - b);
  return w;
}

/** Les semaines du semestre **toutes**, de 1 à la dernière — vides comprises. */
function semesterWeeks(course: Course): WeeklyProgress[] {
  const planned = [...course.theoryItems.map((t) => t.plannedWeek), ...course.series.map((s) => s.plannedWeek)];
  const last = Math.max(course.term?.totalWeeks ?? 14, planned.reduce((max, week) => Math.max(max, week), 0));
  if (!(last > 0)) return [];
  const result: WeeklyProgress[] = [];
  for (let week = 1; week <= last; week++) result.push(weekProgress(course, week));
  return result;
}

/** Éléments de théorie sans semaine (importés sans calendrier). */
function unplannedTheory(course: Course): TheoryItem[] {
  return course.sortedTheoryItems.filter((t) => t.plannedWeek <= 0);
}

/** Vidéos restantes pour une semaine, triées. */
function remainingVideos(course: Course, week: number): TheoryItem[] {
  return course.sortedTheoryItems.filter((t) => t.plannedWeek === week && !t.isWatched);
}

/** Exercices restants pour une semaine donnée. */
function remainingExercises(course: Course, week: number): Exercise[] {
  return course.sortedSeries
    .filter((s) => s.plannedWeek === week)
    .flatMap((s) => s.sortedExercises)
    .filter((e) => !e.countsAsDone);
}

export const ProgressEngine = {
  CourseProgress,
  WeeklyProgress,
  CorrectionsDue,
  progress,
  lateCount,
  correctionsDue,
  aheadCount,
  standingLabel,
  weekProgress,
  semesterWeeks,
  unplannedTheory,
  remainingVideos,
  remainingExercises,
};

/** Ce qu'une ligne de cours affiche, calculé une fois par rendu d'« Aujourd'hui ». */
export class WeekCourseSummary {
  course: Course;
  week: WeeklyProgress;
  late: number;
  ahead: number;
  corrections: CorrectionsDue;

  constructor(course: Course, now: Date = new Date()) {
    this.course = course;
    this.week = weekProgress(course, course.currentWeek);
    this.late = lateCount(course, null, now);
    this.ahead = aheadCount(course);
    this.corrections = correctionsDue(course, null, now);
  }
}
