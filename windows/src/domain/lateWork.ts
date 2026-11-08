// Ce qu'un cours a en retard, rangé par ce qu'il y a à faire.
// Pendant de Polymestre/Domain/LateWork.swift : le badge « N en retard » et la
// page « À rattraper » lisent cette liste, `total` est le nombre affiché partout.
//
// Quatre groupes disjoints, dans l'ordre où les reprendre : à refaire (toutes
// semaines), à corriger (fait, corrigé publié), exercices à faire (série par
// série), théorie à voir (semaine par semaine). La semaine en cours n'y entre
// pas, les bonus non plus. Une série qui a une échéance compte à son échéance ; une
// reprise espacée, à son palier ; la semaine de référence n'est pas bornée au semestre.

import type { Course } from "../models/course.ts";
import type { Exercise, ExerciseSeries } from "../models/exercise.ts";
import type { TheoryItem } from "../models/theoryItem.ts";
import { Plural } from "./plural.ts";

export interface LateSeriesGroup { series: ExerciseSeries; exercises: Exercise[]; requiredCount: number }
export interface LateTheoryGroup { week: number; items: TheoryItem[] }

export interface LateWork {
  currentWeek: number;
  redo: Exercise[];
  toCorrect: Exercise[];
  series: LateSeriesGroup[];
  theory: LateTheoryGroup[];
  exerciseCount: number;
  theoryCount: number;
  total: number;
}

export function lateWork(course: Course, currentWeek?: number | null, now: Date = new Date()): LateWork {
  const week = currentWeek ?? course.dueWeek(now);
  const ordered = course.sortedSeries;
  const flagged = ordered.flatMap((s) => s.sortedExercises).filter((e) => e.redoRequired && (!e.isBonus || e.isDone));
  const redo = flagged.filter((e) => e.isRedoDue(now));
  const work: LateWork = { currentWeek: currentWeek ?? course.currentWeek, redo, toCorrect: [], series: [], theory: [], exerciseCount: 0, theoryCount: 0, total: redo.length };

  // Une reprise pas encore due reste hors des autres groupes : ni à faire ni à corriger.
  const redoIDs = new Set(flagged.map((e) => e.id));
  for (const series of ordered.filter((s) => s.isDue(week, now))) {
    const published = series.solutionsAt ? series.solutionsAt <= now : true;
    const required = series.sortedExercises.filter((e) => !e.isBonus && !redoIDs.has(e.id));
    if (published) work.toCorrect.push(...required.filter((e) => e.isDone && !e.isCorrected));
    const undone = required.filter((e) => !e.isDone);
    if (undone.length > 0) work.series.push({ series, exercises: undone, requiredCount: series.requiredExercises.length });
  }
  const unseen = course.sortedTheoryItems.filter((t) => t.plannedWeek > 0 && t.plannedWeek < week && !t.isWatched);
  const byWeek = new Map<number, TheoryItem[]>();
  for (const item of unseen) byWeek.set(item.plannedWeek, [...(byWeek.get(item.plannedWeek) ?? []), item]);
  work.theory = [...byWeek.entries()].sort((a, b) => a[0] - b[0]).map(([w, items]) => ({ week: w, items }));
  work.exerciseCount = work.series.reduce((sum, g) => sum + g.exercises.length, 0);
  work.theoryCount = work.theory.reduce((sum, g) => sum + g.items.length, 0);
  work.total = work.redo.length + work.toCorrect.length + work.exerciseCount + work.theoryCount;
  return work;
}

/** « 2 à refaire, 3 à corriger, 5 exercices à faire et 2 éléments de théorie ». */
export function lateSummary(work: LateWork): string {
  const parts: string[] = [];
  if (work.redo.length > 0) parts.push(`${work.redo.length} à refaire`);
  if (work.toCorrect.length > 0) parts.push(`${work.toCorrect.length} à corriger`);
  if (work.exerciseCount > 0) parts.push(Plural.count(work.exerciseCount, `${work.exerciseCount} exercice à faire`, `${work.exerciseCount} exercices à faire`));
  if (work.theoryCount > 0) parts.push(Plural.count(work.theoryCount, `${work.theoryCount} élément de théorie`, `${work.theoryCount} éléments de théorie`));
  if (parts.length <= 1) return parts[0] ?? "";
  return parts.slice(0, -1).join(", ") + " et " + parts[parts.length - 1];
}
