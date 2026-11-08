import { DateUtils } from "../domain/dateUtils.ts";
import { courseCodecs, type RevisionSheetLike, type StudyMapLike } from "./hooks.ts";
import { decodeList, encodeList, type CourseDocument } from "./jsonTypes.ts";
import { defineToMany, defineToOne, newId } from "./relations.ts";
import { ExamKind } from "./enums.ts";
import { localizedStandardCompare, makeURL, splitLines, trimAll } from "./util.ts";
import type { AcademicTerm } from "./academicTerm.ts";
import type { Exam } from "./exam.ts";
import type { Exercise, ExerciseSeries } from "./exercise.ts";
import { SeriesIdentity } from "../domain/seriesIdentity.ts";
import type { LinkedCalendarEvent } from "./linkedCalendarEvent.ts";
import type { LinkedTask } from "./linkedTask.ts";
import type { PastExam } from "./pastExam.ts";
import type { PlannedSession } from "./plannedSession.ts";
import type { SavedResource } from "./savedResource.ts";
import type { StudySession } from "./studySession.ts";
import type { TheoryItem } from "./theoryItem.ts";

export interface CourseInit {
  id?: string;
  code: string;
  name: string;
  shortName?: string;
  credits?: number;
  colorHex?: string;
  iconName?: string;
  term?: AcademicTerm | null;
  weeklyLectureHours?: number;
  weeklyExerciseHours?: number;
  weeklySelfStudyHours?: number | null;
  hasLectures?: boolean;
  sectionCode?: string;
  isTracked?: boolean;
  lecturer?: string;
  moodleURLString?: string;
  notes?: string;
}

/** La source d'une adresse d'après son hôte (`ContentSource.detect(host:)`), pour le lien Moodle. */
const isMoodleHost = (host: string | null): boolean => host !== null && host.toLowerCase().includes("moodle");

/** Cours EPFL. Racine de la décomposition théorie / exercices. */
export class Course {
  static readonly modelName = "Course";

  id: string;
  /** Code officiel EPFL (« CS-250 »). */
  code: string;
  name: string;
  /**
   * Abréviation choisie par l'étudiant·e, affichée partout où la place manque
   * (« ALGO », « Ana I »). Le code officiel reste `code`, et rien ne l'écrase.
   */
  shortName: string;
  credits: number;
  colorHex: string;
  iconName: string;
  declare term: AcademicTerm | null;

  /** Heures de **cours magistral** (amphi) par semaine. */
  weeklyLectureHours: number;
  /** Heures d'**exercices** (séances) par semaine. */
  weeklyExerciseHours: number;

  /**
   * Objectif de travail **personnel** hebdomadaire, en heures. `null` = déduit de la
   * charge ECTS : ce qui reste une fois les heures encadrées (amphi + exos) retirées.
   */
  weeklySelfStudyHours: number | null;

  /**
   * Le cours a-t-il réellement des heures de cours (amphi) ? Certains cours n'ont que
   * des séries d'exercices : alors la charge attendue ne réserve aucune heure d'amphi,
   * et le suivi de présence est masqué.
   */
  hasLectures: boolean;
  /** Section EPFL du cours (« IN », « MA », …). */
  sectionCode: string;
  /** Cours suivi ce semestre (les autres sont archivés). */
  isTracked: boolean;

  /** **Inutilisé** : doublon de `isTracked`, gardé dans le schéma. */
  isActive = false;
  lecturer: string;
  /**
   * Le lien Moodle saisi à la main (formulaire du cours). Le lien d'un cours importé
   * est dans `contentSources` ; `moodleLink` choisit.
   */
  moodleURLString: string;
  notes: string;

  /** Pages d'où le contenu du cours a été importé, une par ligne. */
  contentSourcesRaw = "";

  /**
   * Les adresses d'éléments **écartés** à la relecture d'un import. La mise à jour
   * automatique ne les réajoute pas. Une adresse par ligne.
   */
  contentIgnoredRaw = "";

  /** Les documents du cours qui ne se suivent pas, gardés comme liens (JSON de `CourseDocument`). */
  documentsRaw = "";

  /** Ce qu'il faut faire chaque semaine (JSON `{"3": "Regarder…"}`). */
  weekGuideRaw = "";

  /** La fiche de révision (JSON de `RevisionSheet`) : vide tant qu'elle n'est pas faite. */
  revisionSheetRaw = "";

  /** Liens entre les notions, schémas, ressources NotebookLM… (JSON de `StudyMap`). */
  studyMapRaw = "";

  declare theoryItems: TheoryItem[];
  declare theoryItemsStore: TheoryItem[];
  declare series: ExerciseSeries[];
  declare seriesStore: ExerciseSeries[];
  declare sessions: StudySession[];
  declare sessionsStore: StudySession[];
  declare exams: Exam[];
  declare examsStore: Exam[];
  declare pastExams: PastExam[];
  declare pastExamsStore: PastExam[];
  /** Les ressources gardées sous la main (fiches-résumés, formulaires, liens). */
  declare savedResources: SavedResource[];
  declare savedResourcesStore: SavedResource[];
  declare linkedTasks: LinkedTask[];
  declare linkedTasksStore: LinkedTask[];
  /** Les sessions de groupe prévues pour ce cours. Inverse de `PlannedSession.course`. */
  declare plannedSessionsStore: PlannedSession[];
  declare linkedEvents: LinkedCalendarEvent[];
  declare linkedEventsStore: LinkedCalendarEvent[];

  constructor(o: CourseInit) {
    this.id = o.id ?? newId();
    this.code = o.code;
    this.name = o.name;
    this.shortName = o.shortName ?? "";
    this.credits = o.credits ?? 4;
    this.colorHex = o.colorHex ?? "#4F46E5";
    this.iconName = o.iconName ?? "book.closed.fill";
    this.term = o.term ?? null;
    this.weeklyLectureHours = o.weeklyLectureHours ?? 2;
    this.weeklyExerciseHours = o.weeklyExerciseHours ?? 1;
    this.weeklySelfStudyHours = o.weeklySelfStudyHours ?? null;
    this.hasLectures = o.hasLectures ?? true;
    this.sectionCode = o.sectionCode ?? "";
    this.isTracked = o.isTracked ?? true;
    this.lecturer = o.lecturer ?? "";
    this.moodleURLString = o.moodleURLString ?? "";
    this.notes = o.notes ?? "";
  }

  /** Le lien Moodle du cours : celui saisi à la main, sinon celui de l'import. */
  get moodleLink(): URL | null {
    if (this.moodleURLString !== "") {
      const url = makeURL(this.moodleURLString);
      if (url) return url;
    }
    for (const source of this.contentSources) {
      const url = makeURL(source);
      if (url && isMoodleHost(url.hostname || null)) return url;
    }
    return null;
  }

  get documents(): CourseDocument[] {
    return this.documentsRaw === "" ? [] : decodeList<CourseDocument>(this.documentsRaw);
  }
  set documents(value: CourseDocument[]) {
    this.documentsRaw = encodeList(value);
  }

  get contentIgnored(): Set<string> {
    return new Set(splitLines(this.contentIgnoredRaw));
  }
  set contentIgnored(value: Set<string>) {
    this.contentIgnoredRaw = [...value].sort().join("\n");
  }

  get contentSources(): string[] {
    return splitLines(this.contentSourcesRaw);
  }
  set contentSources(value: string[]) {
    this.contentSourcesRaw = value.join("\n");
  }

  get weekGuide(): Record<number, string> {
    // La plupart des cours n'en ont pas : ne pas lancer de décodeur pour rien.
    if (this.weekGuideRaw === "") return {};
    let raw: unknown;
    try {
      raw = JSON.parse(this.weekGuideRaw);
    } catch {
      return {};
    }
    if (raw === null || typeof raw !== "object" || Array.isArray(raw)) return {};
    const entries = Object.entries(raw as Record<string, unknown>);
    if (!entries.every(([, v]) => typeof v === "string")) return {};
    const result: Record<number, string> = {};
    for (const [key, value] of entries) {
      if (!/^[+-]?\d+$/.test(key)) continue;
      const n = Number(key);
      if (!(n in result)) result[n] = value as string;
    }
    return result;
  }
  set weekGuide(value: Record<number, string>) {
    const raw: Record<string, string> = {};
    for (const key of Object.keys(value).map(Number).sort((a, b) => a - b)) raw[String(key)] = value[key];
    this.weekGuideRaw = JSON.stringify(raw);
  }

  get revisionSheet(): RevisionSheetLike | null {
    return courseCodecs().decodeRevisionSheet(this.revisionSheetRaw);
  }
  set revisionSheet(value: RevisionSheetLike | null) {
    this.revisionSheetRaw = value?.encoded() ?? "";
  }

  get studyMap(): StudyMapLike {
    return courseCodecs().decodeStudyMap(this.studyMapRaw);
  }
  set studyMap(value: StudyMapLike) {
    this.studyMapRaw = value.isEmpty && (value.enrichedAt ?? null) === null ? "" : value.encoded();
  }

  /** Épinglées d'abord, puis les plus récentes. */
  get sortedResources(): SavedResource[] {
    return [...this.savedResources].sort((a, b) => {
      const pa = a.isPinned ? 0 : 1;
      const pb = b.isPinned ? 0 : 1;
      return pa !== pb ? pa - pb : b.addedAt.getTime() - a.addedAt.getTime();
    });
  }

  // MARK: Convenience

  /**
   * Ce qu'on affiche partout où la place manque : l'abréviation si l'étudiant·e en a
   * défini une, sinon le code officiel. Le libellé complet reste `name`.
   */
  get displayCode(): string {
    const trimmed = trimAll(this.shortName);
    return trimmed === "" ? this.code : trimmed;
  }

  get sortedTheoryItems(): TheoryItem[] {
    return [...this.theoryItems].sort((a, b) => {
      if (a.sectionNumber !== b.sectionNumber) return a.sectionNumber - b.sectionNumber;
      return localizedStandardCompare(a.number, b.number);
    });
  }

  get sortedSeries(): ExerciseSeries[] {
    return [...this.series].sort((a, b) => SeriesIdentity.compare(a.key, b.key));
  }

  /**
   * La série de ce numéro et de cette étiquette. Une étiquette apparue (la série
   * enregistrée sans, relue avec « mardi ») retrouve celle de même numéro qui
   * n'en avait pas, quand `soleOfNumber` dit que la source n'en a qu'une.
   */
  seriesWith(number: number, label = "", soleOfNumber = true): ExerciseSeries | null {
    const key = SeriesIdentity.key(number, label);
    const exact = this.series.find((s) => SeriesIdentity.same(s.key, key));
    if (exact) return exact;
    if (!soleOfNumber) return null;
    const same = this.series.filter((s) => s.seriesNumber === number);
    if (key.label === "") return same.length === 1 ? same[0] : null;
    return same.find((s) => s.label === "") ?? null;
  }

  /** Sections de théorie présentes. */
  get theorySections(): number[] {
    return [...new Set(this.theoryItems.map((t) => t.sectionNumber))].sort((a, b) => a - b);
  }

  get allExercises(): Exercise[] {
    return this.series.flatMap((s) => s.exercises);
  }

  get sortedExams(): Exam[] {
    return [...this.exams].sort((a, b) => a.date.getTime() - b.date.getTime());
  }

  /** Annales, de la plus récente à la plus ancienne — l'ordre dans lequel on les travaille. */
  get sortedPastExams(): PastExam[] {
    return [...this.pastExams].sort((a, b) => {
      if (a.year !== b.year) return b.year - a.year;
      return b.addedAt.getTime() - a.addedAt.getTime();
    });
  }

  get nextExam(): Exam | null {
    const now = Date.now();
    return this.sortedExams.find((e) => e.date.getTime() >= now) ?? null;
  }

  /**
   * La prochaine **vraie** épreuve (midterm ou examen) : ni un quiz, ni un devoir, ni
   * une échéance importée de Moodle. C'est elle qui déclenche la révision.
   */
  get nextSitting(): Exam | null {
    const now = Date.now();
    return this.sortedExams.find((e) => e.date.getTime() >= now && ExamKind.isSitting(e.kind)) ?? null;
  }

  /**
   * Semaine courante, bornée à la durée du semestre : un semestre importé dont la date
   * de début est loin dans le passé ne doit pas produire une « semaine 47 ».
   *
   * Sans semestre rattaché, on retombe sur le calendrier académique réel plutôt que
   * sur `1` : « 1 / 14 » en pleine semaine 2 était faux et invisible. Le rattachement
   * est fait à l'import et réparé au lancement (`AcademicTerm.attachOrphanCourses`) ;
   * ceci n'est qu'un dernier filet.
   */
  get currentWeek(): number {
    const term = this.term;
    if (!term) {
      const fallback = DateUtils.currentAutumnOrSpringStart();
      const week = DateUtils.weekNumber(fallback.start);
      return Math.min(Math.max(week, 1), Math.max(fallback.weeks, 1));
    }
    return DateUtils.clampedWeek(new Date(), term);
  }

  /** Le semestre de ce cours est-il en cours ? */
  get isTermRunning(): boolean {
    return this.term ? this.term.isRunning : true;
  }
}

defineToOne(Course, "term", "courses");
defineToMany(Course, "theoryItems", "course", "theoryItemsStore");
defineToMany(Course, "series", "course", "seriesStore");
defineToMany(Course, "sessions", "course", "sessionsStore");
defineToMany(Course, "exams", "course", "examsStore");
defineToMany(Course, "pastExams", "course", "pastExamsStore");
defineToMany(Course, "savedResources", "course", "savedResourcesStore");
defineToMany(Course, "linkedTasks", "course", "linkedTasksStore");
defineToMany(Course, "plannedSessionsStore", "course");
defineToMany(Course, "linkedEvents", "course", "linkedEventsStore");
