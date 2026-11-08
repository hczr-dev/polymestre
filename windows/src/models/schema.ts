// Schéma synchronisé : la copie, champ pour champ, de `SchemaV1`
// (Polymestre/Models/PolymestreSchema.swift).
//
// C'est la **seule** description des données côté Windows : la migration Supabase
// et la base SQLite locale en sont générées (scripts/gen-schema.ts), et
// scripts/check-schema.ts refuse toute différence avec les `@Model` Swift — un
// champ ajouté d'un côté seulement fait échouer la CI au lieu de se perdre.
//
// Noms de colonnes : le nom Swift en snake_case (`kindRaw` → `kind_raw`), pour que
// la correspondance reste mécanique. Une relation « un » devient `<nom>_id`.

export type FieldType = "uuid" | "text" | "int" | "double" | "bool" | "date";

export interface Field {
  /** Nom de la propriété Swift. */
  swift: string;
  type: FieldType;
  /** Optionnel en Swift (`Type?`) : colonne nullable, sans défaut. */
  optional?: boolean;
  /** Défaut non vide en Swift (sinon : "", 0, false, maintenant). */
  default?: string | number | boolean;
  /** Nom de colonne imposé, quand le snake_case heurte une colonne de synchronisation. */
  column?: string;
}

export interface Ref {
  /** Nom de la propriété Swift (relation « un »). */
  swift: string;
  table: string;
  /**
   * Règle de suppression côté parent, recopiée des `@Relationship(deleteRule:)`.
   * Appliquée par les clients au moment de la suppression (pierre tombale des
   * enfants, ou mise à nul) : le serveur n'a pas de clés étrangères, parce qu'un
   * appareil resté hors ligne peut légitimement envoyer un enfant dont le parent
   * a été supprimé ailleurs, et ce envoi ne doit pas échouer.
   */
  onDelete: "cascade" | "nullify";
}

export interface Table {
  /** Nom de la classe `@Model`. */
  model: string;
  /** Nom de la table, Supabase comme SQLite. */
  name: string;
  fields: Field[];
  refs: Ref[];
}

/**
 * Modèles de `SchemaV1` volontairement **absents** de la synchronisation, avec la
 * raison. check-schema.ts exige que tout `@Model` soit soit ici, soit dans `tables`.
 */
export const excludedModels: Record<string, string> = {
  StudyGroup: "copie locale de public.study_groups, lue directement sur le serveur",
  GroupMember: "copie locale des membres d'un groupe, lue sur le serveur",
  GroupSeriesCompletion: "copie locale de l'avancement du groupe, lue sur le serveur",
  GroupItemCompletion: "copie locale de l'avancement du groupe, lue sur le serveur",
  RelayBeacon: "inutilisé (voir RelayBeacon.swift) ; le chrono passe par le relais",
};

/** Propriétés stockées non synchronisées en colonne, avec la raison. */
export const excludedFields: Record<string, string> = {
  "SavedResource.fileData": "fichier joint : Supabase Storage (phase 4), pas une colonne",
};

const t = (swift: string, extra: Partial<Field> = {}): Field => ({ swift, type: "text", ...extra });
const i = (swift: string, extra: Partial<Field> = {}): Field => ({ swift, type: "int", ...extra });
const d = (swift: string, extra: Partial<Field> = {}): Field => ({ swift, type: "double", ...extra });
const b = (swift: string, extra: Partial<Field> = {}): Field => ({ swift, type: "bool", ...extra });
const dt = (swift: string, extra: Partial<Field> = {}): Field => ({ swift, type: "date", ...extra });
const opt = { optional: true };

export const tables: Table[] = [
  {
    model: "AcademicTerm",
    name: "sync_academic_terms",
    fields: [i("year"), t("seasonRaw"), dt("startDate"), dt("endDate"), i("totalWeeks"), t("name")],
    refs: [],
  },
  {
    model: "Course",
    name: "sync_courses",
    fields: [
      t("code"), t("name"), t("shortName"), d("credits"), t("colorHex"), t("iconName"),
      d("weeklyLectureHours"), d("weeklyExerciseHours"), d("weeklySelfStudyHours", opt),
      b("hasLectures"), t("sectionCode"), b("isTracked"), b("isActive"), t("lecturer"),
      t("moodleURLString"), t("notes"), t("contentSourcesRaw"), t("contentIgnoredRaw"),
      t("documentsRaw"), t("weekGuideRaw"), t("revisionSheetRaw"), t("studyMapRaw"),
    ],
    refs: [{ swift: "term", table: "sync_academic_terms", onDelete: "nullify" }],
  },
  {
    model: "TheoryItem",
    name: "sync_theory_items",
    fields: [
      i("sectionNumber"), t("number"), t("title"), i("durationSeconds"), i("plannedWeek"),
      i("sortOrder"), t("kindRaw"), dt("watchedAt", opt), dt("summarizedAt", opt),
      t("summaryText", opt), t("urlString"), i("videoCount"), t("sectionTitle"),
      t("sourceRaw"), t("linksRaw"),
    ],
    refs: [{ swift: "course", table: "sync_courses", onDelete: "cascade" }],
  },
  {
    model: "ExerciseSeries",
    name: "sync_exercise_series",
    fields: [
      i("seriesNumber"), t("title"), i("plannedWeek"), dt("publishedAt", opt), dt("dueDate", opt),
      t("urlString"), t("topic"), dt("solutionsAt", opt), t("solutionURLString"), b("needsReread"), t("label"),
    ],
    refs: [{ swift: "course", table: "sync_courses", onDelete: "cascade" }],
  },
  {
    model: "Exercise",
    name: "sync_exercises",
    fields: [
      t("exerciseNumber"), t("title"), t("statement"), b("isBonus"), i("sortOrder"),
      t("statementURLString"), t("hint"), t("solution"), dt("doneAt", opt), t("confidenceRaw", opt),
      dt("correctedAt", opt), t("correctnessRaw", opt), b("redoRequired"), t("correctionNote", opt),
      d("score", opt), d("maxScore", opt), i("redoPass", opt), dt("redoDueAt", opt), t("redoWhy"),
      t("redoFirstMove"), i("redoFailures"), t("redoLastResultRaw", opt), dt("redoClearedAt", opt),
      i("hintLevel"), t("hintLog"),
    ],
    refs: [{ swift: "series", table: "sync_exercise_series", onDelete: "cascade" }],
  },
  {
    model: "SubQuestion",
    name: "sync_sub_questions",
    fields: [
      t("label"), t("text"), t("kindRaw", { default: "question" }), b("isDone"),
      dt("doneAt", opt), i("sortOrder"),
    ],
    refs: [
      { swift: "exercise", table: "sync_exercises", onDelete: "cascade" },
      { swift: "parent", table: "sync_sub_questions", onDelete: "cascade" },
    ],
  },
  {
    model: "StudySession",
    name: "sync_study_sessions",
    fields: [
      t("taskTypeRaw"), dt("startedAt"), i("durationSeconds"), b("isManual"), t("note"),
      dt("createdAt"), t("sourceRaw"), t("externalKey"),
    ],
    refs: [
      { swift: "course", table: "sync_courses", onDelete: "cascade" },
      { swift: "exercise", table: "sync_exercises", onDelete: "nullify" },
      { swift: "theoryItem", table: "sync_theory_items", onDelete: "nullify" },
    ],
  },
  {
    model: "Exam",
    name: "sync_exams",
    fields: [
      t("kindRaw"), t("title"), dt("date"), d("weightPercent", opt), t("location"),
      t("urlString"), t("notes"), t("externalCalendarEventID", opt),
    ],
    refs: [{ swift: "course", table: "sync_courses", onDelete: "cascade" }],
  },
  {
    model: "PlannedSession",
    name: "sync_planned_sessions",
    fields: [
      t("groupRemoteID", opt), t("groupName"), t("title"), dt("startsAt"), i("durationMinutes"),
      t("location"), t("createdByUserID"), i("goingCount"), i("maybeCount"), t("myRSVP"),
      t("externalCalendarEventID"),
    ],
    refs: [{ swift: "course", table: "sync_courses", onDelete: "nullify" }],
  },
  {
    model: "LinkedTask",
    name: "sync_linked_tasks",
    fields: [
      t("providerRaw"), t("externalID", opt), t("title"), t("note"), dt("dueDate", opt),
      b("isDone"), i("priority"),
      // `updatedAt` est l'heure de modification chez le fournisseur (Todoist…),
      // pas celle de la synchronisation : colonne à part.
      dt("updatedAt", { column: "task_updated_at" }), dt("lastSyncedAt", opt),
    ],
    refs: [
      { swift: "course", table: "sync_courses", onDelete: "cascade" },
      { swift: "video", table: "sync_theory_items", onDelete: "nullify" },
      { swift: "exercise", table: "sync_exercises", onDelete: "nullify" },
    ],
  },
  {
    model: "LinkedCalendarEvent",
    name: "sync_linked_calendar_events",
    fields: [
      t("externalEventID", opt), t("sourceCalendarID", opt), t("title"), dt("startsAt"),
      dt("endsAt"), t("location"), t("kindRaw"), b("isAttended"), b("isSkipped"),
      b("kindIsManual"), t("notes"), dt("lastSyncedAt", opt),
    ],
    refs: [{ swift: "course", table: "sync_courses", onDelete: "cascade" }],
  },
  {
    model: "AcademicMilestone",
    name: "sync_academic_milestones",
    fields: [
      t("externalID"), t("title"), dt("date"), t("kindRaw"), b("isImportant"), b("isApproximate"),
      t("termLabel"), b("isOfficial"), t("notes"), dt("addedAt"), dt("confirmedAt"),
    ],
    refs: [],
  },
  {
    model: "PastExam",
    name: "sync_past_exams",
    fields: [
      t("title"), i("year"), t("kindRaw"), t("urlString"), t("solutionURLString"),
      t("confidenceRaw", opt), dt("workedAt", opt), t("notes"), dt("addedAt"),
    ],
    refs: [{ swift: "course", table: "sync_courses", onDelete: "cascade" }],
  },
  {
    model: "Mistake",
    name: "sync_mistakes",
    fields: [
      dt("createdAt"), t("summary"), t("kindRaw", { default: "method" }), t("correction"),
      t("notion"), t("source", { default: "manual" }),
    ],
    refs: [{ swift: "exercise", table: "sync_exercises", onDelete: "cascade" }],
  },
  {
    model: "SavedResource",
    name: "sync_saved_resources",
    fields: [t("title"), t("address"), t("kindRaw"), t("fileName"), dt("addedAt"), b("isPinned")],
    refs: [{ swift: "course", table: "sync_courses", onDelete: "cascade" }],
  },
];

export const snake = (s: string): string =>
  s.replace(/URL/g, "Url").replace(/ID/g, "Id").replace(/RSVP/g, "Rsvp")
    .replace(/([a-z0-9])([A-Z])/g, "$1_$2").toLowerCase();

export const refColumn = (r: Ref): string => `${snake(r.swift)}_id`;

export const fieldColumn = (f: Field): string => f.column ?? snake(f.swift);

/** Colonnes posées par la synchronisation, interdites aux champs du modèle. */
export const syncColumns = ["id", "user_id", "updated_at", "deleted_at", "server_updated_at", "dirty"];

/** Toutes les colonnes d'une table, dans l'ordre ; lève une erreur sur un doublon. */
export function columnsOf(t: Table): string[] {
  const cols = [...t.fields.map(fieldColumn), ...t.refs.map(refColumn)];
  for (const c of cols) {
    if (syncColumns.includes(c)) throw new Error(`${t.model} : la colonne ${c} est réservée à la synchronisation`);
  }
  const dup = cols.find((c, k) => cols.indexOf(c) !== k);
  if (dup) throw new Error(`${t.model} : colonne ${dup} en double`);
  return cols;
}
