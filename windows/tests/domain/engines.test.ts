// Port des sections de Validation/main.swift qui portent sur les moteurs de
// progression et de charge, le temps d'étude et les totaux de sessions.
// Un `it` par `check` Swift, même libellé.

import { describe, expect, it } from "vitest";
import {
  Course, Exercise, ExerciseSeries, LinkedCalendarEvent, ModelStore, SeedData, StudySession, TheoryItem,
} from "../../src/models/index.ts";
import { DateUtils } from "../../src/domain/dateUtils.ts";
import { CourseProgress, ProgressEngine } from "../../src/domain/progressEngine.ts";
import { WorkloadEngine } from "../../src/domain/workloadEngine.ts";
import { StudyTime } from "../../src/domain/studyTime.ts";
import { SessionStats } from "../../src/domain/sessionStats.ts";

function check(condition: boolean, label: string): void {
  it(label, () => { expect(condition).toBe(true); });
}

const add = (date: Date, seconds: number): Date => new Date(date.getTime() + seconds * 1000);
const byCode = (a: Course, b: Course): number => (a.code < b.code ? -1 : a.code > b.code ? 1 : 0);

const store = new ModelStore();
SeedData.seed(store);
const courses = store.fetch(Course);
const sessions = store.fetch(StudySession);
const cs = courses.find((course) => course.code === "CS-250")!;

describe("ProgressEngine", () => {
  for (const course of [...courses].sort(byCode)) {
    const p = ProgressEngine.progress(course);
    check(p.theoryPercent >= 0 && p.theoryPercent <= 1, `${course.code} théorie ∈ [0,1]`);
    check(p.exercisePercent >= 0 && p.exercisePercent <= 1, `${course.code} exos ∈ [0,1]`);
    check(p.correctionPercent >= 0 && p.correctionPercent <= 1, `${course.code} corrections ∈ [0,1]`);
    check(p.exerciseCount === course.allExercises.filter((exercise) => !exercise.isBonus).length,
      `${course.code} : les bonus sont exclus du dénominateur`);
  }
});

describe("WorkloadEngine (EPFL)", () => {
  for (const course of [...courses].sort(byCode)) {
    const d = WorkloadEngine.delta(course, 30);
    check(d.expectedSeconds > 0, `${course.code} charge attendue > 0`);
    check(d.lectureSeconds + d.exerciseSeconds === d.expectedSeconds, `${course.code} split cours+perso = attendu`);
    check(d.actualSeconds >= WorkloadEngine.studySeconds(course), `${course.code} le réel inclut les heures de cours`);
    check(Math.abs(d.expectedSeconds - Math.round(course.credits * 30 * 3600)) <= 1, `${course.code} formule crédits × 30 h`);
  }
  const aggregate = WorkloadEngine.aggregate(courses, 30);

  describe("Charge attendue hebdomadaire", () => {
    for (const course of courses) {
      const framed = WorkloadEngine.framedWeeklyHours(course);
      const personal = WorkloadEngine.weeklySelfStudyHours(course, 30);
      const weekly = WorkloadEngine.expectedWeeklySeconds(course, 30);
      check(weekly > 0, `${course.code} : attendu hebdo > 0 (${Math.trunc(weekly / 3600)} h)`);
      check(Math.abs(weekly - (framed + personal) * 3600) < 1, `${course.code} : attendu hebdo = encadré (${framed} h) + personnel (${personal} h)`);
      check(personal >= 0, `${course.code} : travail personnel ≥ 0`);
    }
    const weekStart = DateUtils.startOfWeek(new Date());
    const weeklyAggregate = WorkloadEngine.aggregateWeekly(courses, 30, weekStart, DateUtils.addWeeks(1, weekStart));
    check(weeklyAggregate.expectedSeconds === courses.reduce((sum, course) =>
      sum + WorkloadEngine.expectedWeeklySeconds(course, 30), 0), "agrégat hebdo = somme des attendus par cours");
    check(weeklyAggregate.lectureSeconds + weeklyAggregate.exerciseSeconds === weeklyAggregate.expectedSeconds,
      "agrégat hebdo : amphi + personnel = total");
    check(weeklyAggregate.expectedSeconds < aggregate.expectedSeconds,
      `l'attendu hebdo est bien plus petit que le total semestriel (${Math.trunc(weeklyAggregate.expectedSeconds / 3600)} h vs ${Math.trunc(aggregate.expectedSeconds / 3600)} h)`);

    const sample = courses[0];
    const implied = WorkloadEngine.weeklySelfStudyHours(sample, 30);
    const saved = sample.weeklySelfStudyHours;
    sample.weeklySelfStudyHours = implied + 3;
    check(Math.abs(WorkloadEngine.weeklySelfStudyHours(sample, 30) - (implied + 3)) < 0.001,
      `${sample.code} : l'objectif explicite remplace la déduction ECTS`);
    const expected = Math.round((WorkloadEngine.framedWeeklyHours(sample) + implied + 3) * 3600);
    check(WorkloadEngine.expectedWeeklySeconds(sample, 30) === expected, `${sample.code} : l'attendu hebdo suit l'objectif explicite`);
    sample.weeklySelfStudyHours = saved;

    check(aggregate.expectedSeconds > 0 && aggregate.actualSeconds > 0,
      `agrégat : attendu ${aggregate.expectedLabel} / réel ${aggregate.actualLabel}`);
  });
});

describe("Théorie typée (cours sans vidéo) : théorie restante", () => {
  const projectCourse = courses.find((course) => course.code === "PROJ-101");
  if (projectCourse) {
    const chapter = projectCourse.theoryItems[0];
    if (chapter) {
      check(ProgressEngine.remainingVideos(projectCourse, chapter.plannedWeek).length === 1, "un chapitre compte comme théorie restante");
    }
  }
});

describe("Durée de vidéo par semaine", () => {
  check(ProgressEngine.remainingVideos(cs, 2).length !== 0,
    `CS-250 semaine 2 : vidéos restantes (${ProgressEngine.remainingVideos(cs, 2).length})`);
});

describe("Avancement d'un cours en un nombre", () => {
  const p = new CourseProgress();
  p.videoCount = 4;
  p.watchedCount = 2;
  p.exerciseCount = 6;
  p.doneCount = 3;
  p.correctedCount = 0;
  check(Math.abs(p.completion - 0.5) < 0.001, "l'avancement d'un cours : (2 vues + 3 faits) / (4 + 6) = 50 %");
  check(new CourseProgress().completion === 0, "un cours vide est à 0 %, pas NaN");
});

describe("Rythme d'un cours", () => {
  const paced = new Course({ code: "TEST-777", name: "Rythme" });
  store.insert(paced);
  for (const [week, watched] of [[1, false], [2, true], [3, false], [5, true]] as [number, boolean][]) {
    const item = new TheoryItem({
      course: paced, sectionNumber: 1, number: `1.${week}`, title: `t${week}`, kind: "video",
      plannedWeek: week, sortOrder: week, urlString: "",
    });
    if (watched) item.watchedAt = new Date();
    store.insert(item);
  }
  check(ProgressEngine.lateCount(paced, 3) === 1, "une vidéo de la semaine 1 non vue : 1 en retard");
  check(ProgressEngine.aheadCount(paced, 3) === 1, "une vidéo de la semaine 5 déjà vue : 1 d'avance");

  const graded = new Course({ code: "TEST-778", name: "Corrections" });
  store.insert(graded);
  const pastSeries = new ExerciseSeries({ course: graded, seriesNumber: 1, plannedWeek: 1 });
  const lockedSeries = new ExerciseSeries({ course: graded, seriesNumber: 2, plannedWeek: 2 });
  lockedSeries.solutionsAt = new Date(Date.now() + 86_400_000);
  store.insert(pastSeries);
  store.insert(lockedSeries);
  const doneUncorrected = new Exercise({ series: pastSeries, exerciseNumber: "1.1", sortOrder: 1 });
  doneUncorrected.doneAt = new Date();
  const redo = new Exercise({ series: pastSeries, exerciseNumber: "1.2", sortOrder: 2 });
  redo.doneAt = new Date();
  redo.correctedAt = new Date();
  redo.correctnessRaw = "wrong";
  redo.redoRequired = true;
  const waiting = new Exercise({ series: lockedSeries, exerciseNumber: "2.1", sortOrder: 1 });
  waiting.doneAt = new Date();
  for (const exercise of [doneUncorrected, redo, waiting]) store.insert(exercise);
  const gradedDue = ProgressEngine.correctionsDue(graded, 3);
  check(gradedDue.toCorrect === 0,
    "hors retard : la correction de la série 1 (échue) est déjà dans le retard, celle de la série 2 attend son corrigé");
  check(ProgressEngine.lateCount(graded, 3) === 2,
    `en retard : la correction d'une semaine passée et l'exercice à refaire (${ProgressEngine.lateCount(graded, 3)})`);
});

describe("Libellé d'un cours en mots", () => {
  check(ProgressEngine.standingLabel(3, 2) === "3 en retard", "le retard passe avant l'avance");
  check(ProgressEngine.standingLabel(0, 2) === "2 d'avance", "de l'avance");
  check(ProgressEngine.standingLabel(0, 0) === "À jour", "à jour");
});

describe("Tâches, calendrier, sessions planifiées : heures d'amphi", () => {
  const event = new LinkedCalendarEvent({
    title: "CS-250 Cours",
    startsAt: new Date(Date.now() - 3 * 3600_000 - 7 * 86_400_000),
    endsAt: new Date(Date.now() - 2 * 3600_000 - 7 * 86_400_000),
    kind: "lecture",
  });
  event.isAttended = true;
  event.course = cs;
  store.insert(event);
  const classSeconds = WorkloadEngine.classSeconds(cs);
  check(classSeconds > 0, `les heures d'amphi entrent dans le réel : ${DateUtils.durationLabel(classSeconds)}`);
});

describe("Cours sans heures de cours (« a un cours » = non)", () => {
  const project = courses.find((course) => course.code === "PROJ-101");
  if (project) {
    check(!project.hasLectures, "PROJ-101 déclaré sans amphi");
    const projectWorkload = WorkloadEngine.delta(project, 30);
    check(projectWorkload.lectureSeconds === 0, "aucune heure d'amphi attendue pour un cours sans cours");
    check(projectWorkload.exerciseSeconds === projectWorkload.expectedSeconds,
      `tout est en travail personnel (${DateUtils.hoursLabel(projectWorkload.exerciseSeconds)})`);
  } else {
    check(false, "PROJ-101 présent dans les données d'exemple");
  }
});

describe("SessionStats : totaux par jour", () => {
  const today = DateUtils.startOfDay(new Date());
  const totals = SessionStats.dailyTotals(sessions, 14, new Date());
  check(totals.length === 14, `14 colonnes, jours vides compris (${totals.length})`);
  check(totals[totals.length - 1]?.day.getTime() === today.getTime(), "la dernière colonne est aujourd'hui");
  check(totals[0].day < totals[totals.length - 1].day, "du plus ancien au plus récent");
  const sum = totals.reduce((total, day) => total + day.seconds, 0);
  const threshold = DateUtils.addDays(-13, today);
  const expected = sessions.filter((session) => session.startedAt >= threshold)
    .reduce((total, session) => total + session.durationSeconds, 0);
  check(sum === expected, `somme des colonnes = sessions des 14 derniers jours (${Math.trunc(sum / 60)} min)`);
  const groups = SessionStats.groupedByDay(sessions);
  check(groups.length === 10, `10 jours de sessions dans l'exemple (${groups.length})`);
  check(groups[0].day > groups[groups.length - 1].day, "le plus récent d'abord");
  check(groups.every((group) => group.sessions.every((session) => DateUtils.isSameDay(session.startedAt, group.day))),
    "chaque session est dans le bon jour");
});

describe("Temps d'étude : cours automatiques, exercices chronométrés (StudyTime)", () => {
  const t0 = new Date(1_790_000_000 * 1000);
  const at = (minutes: number): Date => add(t0, minutes * 60);
  check(StudyTime.lectureSeconds(at(0), at(105), []) === 105 * 60,
    "un cours de 1 h 45 compte 1 h 45 sans rien lancer");
  check(StudyTime.lectureSeconds(at(0), at(105), [{ start: at(30), end: at(60) }]) === 75 * 60,
    "un chrono de 30 min pendant le cours n'est pas compté deux fois");
  check(StudyTime.lectureSeconds(at(0), at(105), [{ start: at(-10), end: at(40) }, { start: at(20), end: at(50) }]) === 55 * 60,
    "deux chronos qui se chevauchent ne retirent pas deux fois la même minute");
  check(StudyTime.lectureSeconds(at(0), at(24 * 60), []) === 0,
    "une « séance » de 24 h (journée, échéance) ne compte pas comme cours");

  const course = new Course({ code: "MATH-101", name: "Analyse I" });
  store.insert(course);
  const lecture = new LinkedCalendarEvent({ title: "Analyse I", startsAt: at(-3000), endsAt: at(-2895), kind: "lecture" });
  lecture.course = course;
  const exercises = new LinkedCalendarEvent({ title: "Analyse I", startsAt: at(-2880), endsAt: at(-2760), kind: "exerciseSession" });
  exercises.course = course;
  const chrono = new StudySession({ course, taskType: "exercise", startedAt: at(-2870), durationSeconds: 50 * 60 });
  store.insert(lecture);
  store.insert(exercises);
  store.insert(chrono);
  const blocks = StudyTime.blocks([lecture, exercises], [chrono]);
  check(blocks.reduce((sum, block) => sum + block.seconds, 0) === (105 + 50) * 60,
    "séance d'exercices de 2 h : seules les 50 min chronométrées comptent ; le cours compte seul");
  check(blocks.some((block) => block.taskType === "lecture" && block.courseCode === "MATH-101"),
    "le cours part dans les groupes avec son code et la nature « lecture »");
});
