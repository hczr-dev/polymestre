// Port de Validation/LateWorkTests.swift : la page « À rattraper » et le badge
// « N en retard » lisent la même liste.

import { describe, expect, it } from "vitest";
import "../../src/domain/exerciseFlow.ts";
import { AcademicTerm, Course, Exercise, ExerciseSeries, ModelStore, SubQuestion, TheoryItem } from "../../src/models/index.ts";
import { ExerciseStage } from "../../src/domain/exerciseFlow.ts";
import { DateUtils } from "../../src/domain/dateUtils.ts";
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

describe("Ce qui est dû, et quand", () => {
  const store = new ModelStore();
  const now = new Date();
  const day = 86_400_000;
  const course = new Course({ code: "TST-301", name: "Échéances" });
  store.insert(course);
  const ex = (series: ExerciseSeries, number: string, order: number) => {
    const e = new Exercise({ series, exerciseNumber: number, sortOrder: order });
    store.insert(e);
    return e;
  };

  it("une reprise espacée n'est en retard qu'à son palier", () => {
    const s1 = new ExerciseSeries({ course, seriesNumber: 9, plannedWeek: 1 });
    store.insert(s1);
    const spaced = ex(s1, "9.1", 1);
    spaced.correct("partial");
    spaced.redoRequired = true;
    spaced.redoPass = 1;
    spaced.redoDueAt = new Date(now.getTime() + 10 * day);
    const today = lateWork(course, 4, now);
    expect(today.redo).toEqual([]);
    expect(today.toCorrect).toEqual([]);
    expect(lateWork(course, 4, new Date(now.getTime() + 11 * day)).redo.map((e) => e.exerciseNumber)).toEqual(["9.1"]);
    spaced.redoDueAt = null;
    expect(lateWork(course, 4, now).redo).toEqual([]);
    store.delete(s1);
  });

  it("l'échéance fait foi, pas la semaine", () => {
    const thursday = new ExerciseSeries({ course, seriesNumber: 1, plannedWeek: 2 });
    thursday.dueDate = new Date(now.getTime() + 3 * day);
    const passed = new ExerciseSeries({ course, seriesNumber: 2, plannedWeek: 3 });
    passed.dueDate = new Date(now.getTime() - 3_600_000);
    [thursday, passed].forEach((s) => store.insert(s));
    ex(thursday, "1.1", 1);
    ex(thursday, "1.2", 2).setDone(true);
    ex(passed, "2.1", 1);
    expect(lateWork(course, 3, now).series.map((g) => g.series.seriesNumber)).toEqual([2]);
    expect(ProgressEngine.correctionsDue(course, 3, now).toCorrect).toBe(1);
    expect(lateWork(course, 3, new Date(now.getTime() + 4 * day)).total).toBe(3);
  });

  it("après le semestre, la dernière semaine est échue", () => {
    const start = DateUtils.startOfWeek(DateUtils.addDays(-20 * 7, now));
    const term = new AcademicTerm({ year: 2020, season: "autumn", startDate: start, endDate: DateUtils.addDays(14 * 7, start), totalWeeks: 14 });
    store.insert(term);
    const finished = new Course({ code: "TST-302", name: "Fini" });
    store.insert(finished);
    finished.term = term;
    store.insert(new TheoryItem({ course: finished, sectionNumber: 14, number: "14", title: "T14", kind: "video", plannedWeek: 14, sortOrder: 1, urlString: "" }));
    expect(finished.currentWeek).toBe(14);
    expect(finished.dueWeek(now)).toBeGreaterThan(14);
    expect(lateWork(finished, null, now).theoryCount).toBe(1);
  });

  it("décocher une question efface la correction", () => {
    const s = new ExerciseSeries({ course, seriesNumber: 5, plannedWeek: 5 });
    store.insert(s);
    const parted = ex(s, "5.1", 1);
    const a = new SubQuestion({ exercise: parted, label: "a", sortOrder: 0 });
    const b = new SubQuestion({ exercise: parted, label: "b", sortOrder: 1 });
    parted.subQuestions = [a, b];
    parted.correct("correct");
    a.toggle();
    expect(parted.isDone).toBe(false);
    expect(parted.isCorrected).toBe(false);
    expect(ExerciseStage(parted)).toEqual({ kind: "inProgress", done: 1, total: 2 });
  });

  it("progression : à refaire n'est pas fait, corrigés ⩽ faits", () => {
    const graded = new Course({ code: "TST-303", name: "Progression" });
    store.insert(graded);
    const gs = new ExerciseSeries({ course: graded, seriesNumber: 1, plannedWeek: 1 });
    store.insert(gs);
    ex(gs, "1.1", 1).correct("correct");
    ex(gs, "1.2", 2).correct("wrong");
    const stale = ex(gs, "1.3", 3);
    stale.correctedAt = now;
    stale.correctnessRaw = "correct";
    const p = ProgressEngine.progress(graded);
    expect([p.doneCount, p.correctedCount]).toEqual([1, 1]);
    expect(p.correctionPercent).toBeLessThanOrEqual(1);
  });
});
