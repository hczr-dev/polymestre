// Les chiffres du bilan (StatsView.swift), calculés une fois par rendu :
// fenêtre de période, temps d'étude et d'amphi, barres par jour, parts par
// matière, tendance hebdomadaire, avancement et corrections.
//
// Rien n'est recalculé à la main : `StudyTime` compte l'amphi comme partout
// (une heure suivie moins ce que le chrono du même cours recouvre), et
// `SessionStats` regroupe le journal par jour.

import { countsSession, readCounting } from "../../../domain/studyCounting.ts";
import { DateUtils } from "../../../domain/dateUtils.ts";
import { ProgressEngine, type CourseProgress } from "../../../domain/progressEngine.ts";
import { SessionStats } from "../../../domain/sessionStats.ts";
import { StudyTime } from "../../../domain/studyTime.ts";
import type { DayGroup } from "../../../domain/sessionStats.ts";
import {
  AcademicTerm, Correctness, Course, LinkedCalendarEvent, StudySession, TaskType,
} from "../../../models/index.ts";
import type { ModelStore } from "../../../models/store.ts";
import { carnetTint, lectureColor, taskColor } from "./palette.ts";

export type Period = "week" | "month" | "semester";

export const PERIOD_LABELS: Record<Period, string> = {
  week: "Semaine",
  month: "30 jours",
  semester: "Semestre",
};

/** « Amphi » n'est pas un `TaskType` : c'est le nom de la catégorie des cours suivis. */
export const LECTURE_CATEGORY = "Amphi";

export interface DateRange {
  start: Date;
  end: Date;
}

export interface LectureSlot {
  date: Date;
  seconds: number;
  course: Course | null;
}

export interface TimeBar {
  bin: Date;
  category: string;
  seconds: number;
}

export interface CategoryStyle {
  color: string;
  opacity: number;
}

/** Une part du temps : une nature de travail ou un cours. */
export interface TimeSlice {
  name: string;
  detail: string;
  seconds: number;
  color: string;
  opacity: number;
}

export interface WeekPoint {
  week: Date;
  series: "Étude" | "Amphi";
  hours: number;
}

export interface DonePoint {
  week: Date;
  series: "Théorie" | "Exercices";
  count: number;
}

export interface PaceRow {
  code: string;
  color: string;
  /** Part du cours faite (théorie vue + exercices faits), 0…1. */
  done: number;
  /** Part du programme prévue jusqu'à cette semaine, 0…1. */
  expected: number;
}

export interface VerdictRow {
  result: Correctness;
  count: number;
  start: number;
}

export interface CourseProgressRow {
  course: Course;
  color: string;
  late: number;
  progress: CourseProgress;
}

export interface StatsSnapshot {
  period: Period;
  weekOffset: number;
  range: DateRange;
  rangeLabel: string;
  binsByWeek: boolean;
  term: AcademicTerm | null;
  courses: Course[];
  tracked: Course[];
  sessions: StudySession[];
  sessionsInRange: StudySession[];
  studySessions: StudySession[];
  lectures: LectureSlot[];
  studySeconds: number;
  lectureSeconds: number;
  timeBars: TimeBar[];
  categoryOrder: string[];
  categoryStyles: Record<string, CategoryStyle>;
  bins: Date[];
  splitSlices: TimeSlice[];
  courseSlices: TimeSlice[];
  weeklyPoints: WeekPoint[];
  weeks: Date[];
  studyAverage: number;
  donePoints: DonePoint[];
  paceRows: PaceRow[];
  verdicts: VerdictRow[];
  redoCount: number;
  activeDays: number;
  progressRows: CourseProgressRow[];
}

/** Le jour (ou le lundi de la semaine) auquel une date se rattache. */
export function binOf(date: Date, binsByWeek: boolean): Date {
  return binsByWeek ? DateUtils.startOfWeek(date) : DateUtils.startOfDay(date);
}

/** `S12` quand le semestre est connu, sinon le jour court. */
export function weekLabel(term: AcademicTerm | null, date: Date): string {
  if (term) {
    // +12 h : un lundi à minuit appartient bien à sa semaine, pas à la précédente.
    return `S${DateUtils.clampedWeek(new Date(date.getTime() + 43_200_000), term)}`;
  }
  return DateUtils.shortDay(date);
}

export function buildStats(
  store: ModelStore,
  period: Period,
  weekOffset: number,
  now: Date,
  dark: boolean,
): StatsSnapshot {
  const courses = store.fetch(Course).slice().sort((a, b) => a.code.localeCompare(b.code));
  const sessions = store.fetch(StudySession).slice()
    .sort((a, b) => b.startedAt.getTime() - a.startedAt.getTime());
  const events = store.fetch(LinkedCalendarEvent);
  const tracked = courses.filter((course) => course.isTracked);
  const term = AcademicTerm.resolve(
    tracked.map((course) => course.term).filter((value): value is AcademicTerm => value !== null),
    now,
  );

  const today = DateUtils.startOfDay(now);
  let start: Date;
  let end: Date;
  switch (period) {
    case "week":
      start = DateUtils.addWeeks(weekOffset, DateUtils.startOfWeek(now));
      end = DateUtils.addDays(7, start);
      break;
    case "month":
      start = DateUtils.addDays(-29, today);
      end = DateUtils.addDays(1, today);
      break;
    case "semester":
      start = term
        ? DateUtils.startOfWeek(term.startDate)
        : DateUtils.addWeeks(-13, DateUtils.startOfWeek(now));
      end = DateUtils.addDays(1, today);
      break;
  }
  const range: DateRange = { start, end };
  const binsByWeek = period === "semester";

  const last = DateUtils.addDays(-1, end);
  let rangeLabel: string;
  switch (period) {
    case "week":
      rangeLabel = weekOffset === 0
        ? "Cette semaine"
        : weekOffset === -1
          ? "La semaine dernière"
          : `${DateUtils.shortDay(start)} – ${DateUtils.shortDay(last)}`;
      break;
    case "month":
      rangeLabel = `${DateUtils.shortDay(start)} – aujourd'hui`;
      break;
    case "semester":
      rangeLabel = term?.displayName ?? "Depuis le début du semestre";
      break;
  }

  const inRange = (date: Date): boolean =>
    date.getTime() >= range.start.getTime() && date.getTime() < range.end.getTime();

  // Une session « Cours en amphi » n'est pas de l'étude : elle rejoint l'amphi.
  const counting = readCounting();
  const studySessions = sessions.filter(
    (session) => inRange(session.startedAt) && TaskType.canonical(session.taskType) !== "lecture" && countsSession(counting, session),
  );

  const byCode = new Map(courses.map((course) => [course.code, course]));
  const lectures: LectureSlot[] = StudyTime
    .lectureBlocks(events.filter((event) => inRange(event.startsAt)), sessions)
    .map((block) => ({
      date: block.start,
      seconds: block.seconds,
      course: block.courseCode ? byCode.get(block.courseCode) ?? null : null,
    }));
  for (const session of sessions) {
    if (inRange(session.startedAt) && TaskType.canonical(session.taskType) === "lecture" && countsSession(counting, session)) {
      lectures.push({ date: session.startedAt, seconds: session.durationSeconds, course: session.course });
    }
  }

  const studySeconds = studySessions.reduce((sum, session) => sum + session.durationSeconds, 0);
  const lectureSeconds = lectures.reduce((sum, slot) => sum + slot.seconds, 0);

  // Une barre du graphique du temps : un jour (ou une semaine), une catégorie.
  const totals = new Map<number, Map<string, number>>();
  const add = (date: Date, category: string, seconds: number): void => {
    const key = binOf(date, binsByWeek).getTime();
    const buckets = totals.get(key) ?? new Map<string, number>();
    buckets.set(category, (buckets.get(category) ?? 0) + seconds);
    totals.set(key, buckets);
  };
  for (const session of studySessions) {
    add(session.startedAt, TaskType.label(session.taskType), session.durationSeconds);
  }
  for (const slot of lectures) add(slot.date, LECTURE_CATEGORY, slot.seconds);

  const timeBars: TimeBar[] = [];
  for (const [key, buckets] of totals) {
    for (const [category, seconds] of buckets) {
      timeBars.push({ bin: new Date(key), category, seconds });
    }
  }
  timeBars.sort((a, b) => a.bin.getTime() - b.bin.getTime()
    || LECTURE_CATEGORY.localeCompare(b.category));

  // L'étude d'abord, l'amphi en haut.
  const categoryOrder = TaskType.reportCategories
    .filter((type) => type !== "lecture")
    .map((type) => TaskType.label(type))
    .concat(LECTURE_CATEGORY);
  const categoryStyles: Record<string, CategoryStyle> = {};
  for (const type of TaskType.reportCategories) {
    if (type === "lecture") continue;
    const label = TaskType.label(type);
    categoryStyles[label] = { color: taskColor(type, dark), opacity: 1 };
  }
  categoryStyles[LECTURE_CATEGORY] = { color: lectureColor(dark), opacity: 1 };

  // Les cases du graphique : une par jour, ou une par semaine en semestre.
  const bins: Date[] = [];
  let cursor = binOf(range.start, binsByWeek);
  const stop = period === "week"
    ? range.end
    : new Date(Math.min(range.end.getTime(), DateUtils.addDays(1, today).getTime()));
  while (cursor.getTime() < stop.getTime()) {
    bins.push(cursor);
    cursor = binsByWeek ? DateUtils.addWeeks(1, cursor) : DateUtils.addDays(1, cursor);
  }

  // Répartition : amphi, puis chaque nature de travail.
  const splitSlices: TimeSlice[] = [];
  if (lectureSeconds > 0) {
    splitSlices.push({
      name: LECTURE_CATEGORY,
      detail: "cours magistraux suivis",
      seconds: lectureSeconds,
      color: lectureColor(dark),
      opacity: 1,
    });
  }
  for (const type of TaskType.reportCategories) {
    if (type === "lecture") continue;
    const seconds = studySessions
      .filter((session) => TaskType.canonical(session.taskType) === type)
      .reduce((sum, session) => sum + session.durationSeconds, 0);
    if (seconds > 0) {
      splitSlices.push({
        name: TaskType.label(type),
        detail: "",
        seconds,
        color: taskColor(type, dark),
        opacity: 1,
      });
    }
  }

  // Par matière : étude et amphi confondus, du plus lourd au plus léger.
  const studyByCode = new Map<string, number>();
  const lectureByCode = new Map<string, number>();
  const colorByCode = new Map<string, string>();
  for (const session of studySessions) {
    const code = session.course?.displayCode ?? "Sans cours";
    studyByCode.set(code, (studyByCode.get(code) ?? 0) + session.durationSeconds);
    colorByCode.set(code, session.course ? carnetTint(session.course.colorHex, dark) : "var(--ink-tertiary)");
  }
  for (const slot of lectures) {
    const code = slot.course?.displayCode ?? "Sans cours";
    lectureByCode.set(code, (lectureByCode.get(code) ?? 0) + slot.seconds);
    colorByCode.set(code, slot.course ? carnetTint(slot.course.colorHex, dark) : "var(--ink-tertiary)");
  }
  const courseSlices: TimeSlice[] = [...new Set([...studyByCode.keys(), ...lectureByCode.keys()])]
    .map((code) => ({
      name: code,
      detail: `${DateUtils.durationLabel(studyByCode.get(code) ?? 0)} d'étude, `
        + `${DateUtils.durationLabel(lectureByCode.get(code) ?? 0)} d'amphi`,
      seconds: (studyByCode.get(code) ?? 0) + (lectureByCode.get(code) ?? 0),
      color: colorByCode.get(code) ?? "var(--ink)",
      opacity: 1,
    }))
    .sort((a, b) => b.seconds - a.seconds);

  // Tendance semaine par semaine, sur tout le semestre.
  const semesterStart = term
    ? DateUtils.startOfWeek(term.startDate)
    : DateUtils.addWeeks(-13, DateUtils.startOfWeek(now));
  const weeklyStudy = new Map<number, number>();
  const weeklyLecture = new Map<number, number>();
  const addWeek = (map: Map<number, number>, date: Date, seconds: number): void => {
    const key = DateUtils.startOfWeek(date).getTime();
    map.set(key, (map.get(key) ?? 0) + seconds);
  };
  for (const session of sessions) {
    if (session.startedAt.getTime() < semesterStart.getTime() || !countsSession(counting, session)) continue;
    if (TaskType.canonical(session.taskType) === "lecture") {
      addWeek(weeklyLecture, session.startedAt, session.durationSeconds);
    } else {
      addWeek(weeklyStudy, session.startedAt, session.durationSeconds);
    }
  }
  for (const block of StudyTime.lectureBlocks(
    events.filter((event) => event.startsAt.getTime() >= semesterStart.getTime()),
    sessions,
  )) {
    addWeek(weeklyLecture, block.start, block.seconds);
  }

  const weeks: Date[] = [];
  cursor = semesterStart;
  while (cursor.getTime() <= now.getTime()) {
    weeks.push(cursor);
    cursor = DateUtils.addWeeks(1, cursor);
  }
  const weeklyPoints: WeekPoint[] = [];
  for (const week of weeks) {
    weeklyPoints.push({
      week, series: "Étude", hours: (weeklyStudy.get(week.getTime()) ?? 0) / 3600,
    });
    weeklyPoints.push({
      week, series: "Amphi", hours: (weeklyLecture.get(week.getTime()) ?? 0) / 3600,
    });
  }
  const activeStudyWeeks = weeklyPoints.filter((point) => point.series === "Étude" && point.hours > 0);
  const studyAverage = activeStudyWeeks.length === 0
    ? 0
    : activeStudyWeeks.reduce((sum, point) => sum + point.hours, 0) / activeStudyWeeks.length;

  // Ce que le temps a produit : théorie vue et exercices faits, par semaine.
  const doneTheory = new Map<number, number>();
  const doneExercises = new Map<number, number>();
  for (const course of tracked) {
    for (const item of course.theoryItems) {
      if (item.watchedAt && item.watchedAt.getTime() >= semesterStart.getTime()) {
        addWeek(doneTheory, item.watchedAt, 1);
      }
    }
    for (const exercise of course.allExercises) {
      if (exercise.doneAt && exercise.doneAt.getTime() >= semesterStart.getTime()) {
        addWeek(doneExercises, exercise.doneAt, 1);
      }
    }
  }
  const donePoints: DonePoint[] = [];
  for (const week of weeks) {
    donePoints.push({ week, series: "Théorie", count: doneTheory.get(week.getTime()) ?? 0 });
    donePoints.push({ week, series: "Exercices", count: doneExercises.get(week.getTime()) ?? 0 });
  }

  // Fait contre prévu : la théorie vue et les exercices faits, jusqu'à cette semaine.
  const paceRows: PaceRow[] = [];
  for (const course of tracked) {
    const week = course.currentWeek;
    const theory = course.theoryItems;
    const exercises = course.series.flatMap((series) => series.exercises).filter((exercise) => !exercise.isBonus);
    const total = theory.length + exercises.length;
    if (total === 0) continue;
    const due = theory.filter((item) => item.plannedWeek > 0 && item.plannedWeek <= week).length
      + course.series
        .filter((series) => series.plannedWeek > 0 && series.plannedWeek <= week)
        .flatMap((series) => series.exercises)
        .filter((exercise) => !exercise.isBonus).length;
    const done = theory.filter((item) => item.isWatched).length
      + exercises.filter((exercise) => exercise.isDone).length;
    paceRows.push({
      code: course.displayCode,
      color: carnetTint(course.colorHex, dark),
      done: done / total,
      expected: due / total,
    });
  }

  // Corrections : les exercices corrigés, dans l'ordre des verdicts.
  const corrected = tracked
    .flatMap((course) => course.allExercises)
    .map((exercise) => exercise.correctness)
    .filter((value): value is Correctness => value !== null);
  const verdicts: VerdictRow[] = [];
  let verdictStart = 0;
  for (const result of Correctness.allCases) {
    const count = corrected.filter((value) => value === result).length;
    if (count === 0) continue;
    verdicts.push({ result, count, start: verdictStart });
    verdictStart += count;
  }
  const redoCount = tracked
    .flatMap((course) => course.allExercises)
    .filter((exercise) => exercise.redoRequired).length;

  // Avancement, cours par cours (le même calcul que la page du cours).
  const progressRows: CourseProgressRow[] = tracked.map((course) => ({
    course,
    color: carnetTint(course.colorHex, dark),
    late: ProgressEngine.lateCount(course),
    progress: ProgressEngine.progress(course),
  }));

  const activeDays = new Set(
    studySessions.map((session) => DateUtils.startOfDay(session.startedAt).getTime()),
  ).size;

  return {
    period,
    weekOffset,
    range,
    rangeLabel,
    binsByWeek,
    term,
    courses,
    tracked,
    sessions,
    sessionsInRange: sessions.filter((session) => inRange(session.startedAt)),
    studySessions,
    lectures,
    studySeconds,
    lectureSeconds,
    timeBars,
    categoryOrder,
    categoryStyles,
    bins,
    splitSlices,
    courseSlices,
    weeklyPoints,
    weeks,
    studyAverage,
    donePoints,
    paceRows,
    verdicts,
    redoCount,
    activeDays,
    progressRows,
  };
}

/** Les sessions du jour (ou de la semaine) épinglé, sinon toute la période. */
export function journalSessions(
  snapshot: StatsSnapshot,
  pinnedBin: Date | null,
): StudySession[] {
  if (pinnedBin === null) return snapshot.sessionsInRange;
  const key = pinnedBin.getTime();
  return snapshot.sessionsInRange.filter(
    (session) => binOf(session.startedAt, snapshot.binsByWeek).getTime() === key,
  );
}

export function journalGroups(sessions: StudySession[]): DayGroup[] {
  return SessionStats.groupedByDay(sessions);
}
