// Port de Validation/LateWorkTests.swift : la page « À rattraper » et le badge
// « N en retard » lisent la même liste.

import { describe, expect, it } from "vitest";
import "../../src/domain/exerciseFlow.ts";
import { Course, Exercise, ExerciseSeries, ModelStore, TheoryItem } from "../../src/models/index.ts";
import { lateSummary, lateWork } from "../../src/domain/lateWork.ts";
import { ProgressEngine } from "../../src/domain/progressEngine.ts";

describe("À rattraper", () => {
  const store = new ModelStore();
  const course = new Course({ code: "TST-300", name: "Retard" });
  store.insert(course);
  const s1 = new ExerciseSeries({ course, seriesNumber: 1, plannedWeek: 1 });
  const s2 = new ExerciseSeries({ course, seriesNumber: 2, plannedWeek: 2 });
  s2.solutionsAt = new Date(Date.now() + 86_400_000);
  const s4 = new ExerciseSeries({ course, seriesNumber: 4, plannedWeek: 4 });
  [s1, s2, s4].forEach((s) => store.insert(s));
  const ex = (series: ExerciseSeries, number: string, order: number) => {
    const e = new Exercise({ series, exerciseNumber: number, sortOrder: order });
    store.insert(e);
    return e;
  };
  ex(s1, "1.1", 1).setDone(true);
  ex(s1, "1.2", 2);
  ex(s1, "1.3", 3).redoRequired = true;
  ex(s1, "1.4", 4).isBonus = true;
  ex(s1, "1.5", 5).correct("correct");
  ex(s2, "2.1", 1).setDone(true);
  ex(s2, "2.2", 2);
  ex(s4, "4.1", 1);
  for (const [week, n] of [[1, "1"], [2, "2a"], [2, "2b"], [4, "4"]] as [number, string][]) {
    store.insert(new TheoryItem({ course, sectionNumber: week, number: n, title: `T${n}`, kind: "video", plannedWeek: week, sortOrder: week, urlString: "" }));
  }
  const late = lateWork(course, 4);

  it("à refaire : 1.3", () => { expect(late.redo.map((e) => e.exerciseNumber)).toEqual(["1.3"]); });
  it("à corriger : 1.1 seulement", () => { expect(late.toCorrect.map((e) => e.exerciseNumber)).toEqual(["1.1"]); });
  it("à faire, série par série", () => {
    expect(late.series.map((g) => g.exercises.map((e) => e.exerciseNumber))).toEqual([["1.2"], ["2.2"]]);
  });
  it("théorie groupée par semaine", () => { expect(late.theory.map((g) => `${g.week}:${g.items.length}`)).toEqual(["1:1", "2:2"]); });
  it("le badge et la page disent le même nombre", () => {
    expect(late.total).toBe(7);
    expect(ProgressEngine.lateCount(course, 4)).toBe(7);
  });
  it("résumé", () => { expect(lateSummary(late)).toBe("1 à refaire, 1 à corriger, 2 exercices à faire et 3 éléments de théorie"); });
  it("en semaine 1, seul l'exercice à refaire", () => { expect(lateWork(course, 1).total).toBe(1); });
});
