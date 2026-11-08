// Généré par windows/scripts/gen-schema.ts depuis src/models/schema.ts — ne pas modifier à la main.

/** AcademicTerm (table sync_academic_terms). */
export interface AcademicTermRow {
  id: string;
  year: number;
  season_raw: string;
  start_date: string;
  end_date: string;
  total_weeks: number;
  name: string;
  updated_at: string;
  deleted_at: string | null;
}

/** Course (table sync_courses). */
export interface CourseRow {
  id: string;
  code: string;
  name: string;
  short_name: string;
  credits: number;
  color_hex: string;
  icon_name: string;
  weekly_lecture_hours: number;
  weekly_exercise_hours: number;
  weekly_self_study_hours: number | null;
  has_lectures: boolean;
  section_code: string;
  is_tracked: boolean;
  is_active: boolean;
  lecturer: string;
  moodle_url_string: string;
  notes: string;
  content_sources_raw: string;
  content_ignored_raw: string;
  documents_raw: string;
  week_guide_raw: string;
  revision_sheet_raw: string;
  study_map_raw: string;
  term_id: string | null;
  updated_at: string;
  deleted_at: string | null;
}

/** TheoryItem (table sync_theory_items). */
export interface TheoryItemRow {
  id: string;
  section_number: number;
  number: string;
  title: string;
  duration_seconds: number;
  planned_week: number;
  sort_order: number;
  kind_raw: string;
  watched_at: string | null;
  summarized_at: string | null;
  summary_text: string | null;
  url_string: string;
  video_count: number;
  section_title: string;
  source_raw: string;
  links_raw: string;
  course_id: string | null;
  updated_at: string;
  deleted_at: string | null;
}

/** ExerciseSeries (table sync_exercise_series). */
export interface ExerciseSeriesRow {
  id: string;
  series_number: number;
  title: string;
  planned_week: number;
  published_at: string | null;
  due_date: string | null;
  url_string: string;
  topic: string;
  solutions_at: string | null;
  solution_url_string: string;
  needs_reread: boolean;
  label: string;
  course_id: string | null;
  updated_at: string;
  deleted_at: string | null;
}

/** Exercise (table sync_exercises). */
export interface ExerciseRow {
  id: string;
  exercise_number: string;
  title: string;
  statement: string;
  is_bonus: boolean;
  sort_order: number;
  statement_url_string: string;
  hint: string;
  solution: string;
  done_at: string | null;
  confidence_raw: string | null;
  corrected_at: string | null;
  correctness_raw: string | null;
  redo_required: boolean;
  correction_note: string | null;
  score: number | null;
  max_score: number | null;
  redo_pass: number | null;
  redo_due_at: string | null;
  redo_why: string;
  redo_first_move: string;
  redo_failures: number;
  redo_last_result_raw: string | null;
  redo_cleared_at: string | null;
  hint_level: number;
  hint_log: string;
  series_id: string | null;
  updated_at: string;
  deleted_at: string | null;
}

/** SubQuestion (table sync_sub_questions). */
export interface SubQuestionRow {
  id: string;
  label: string;
  text: string;
  kind_raw: string;
  is_done: boolean;
  done_at: string | null;
  sort_order: number;
  exercise_id: string | null;
  parent_id: string | null;
  updated_at: string;
  deleted_at: string | null;
}

/** StudySession (table sync_study_sessions). */
export interface StudySessionRow {
  id: string;
  task_type_raw: string;
  started_at: string;
  duration_seconds: number;
  is_manual: boolean;
  note: string;
  created_at: string;
  source_raw: string;
  external_key: string;
  course_id: string | null;
  exercise_id: string | null;
  theory_item_id: string | null;
  updated_at: string;
  deleted_at: string | null;
}

/** Exam (table sync_exams). */
export interface ExamRow {
  id: string;
  kind_raw: string;
  title: string;
  date: string;
  weight_percent: number | null;
  location: string;
  url_string: string;
  notes: string;
  external_calendar_event_id: string | null;
  course_id: string | null;
  updated_at: string;
  deleted_at: string | null;
}

/** PlannedSession (table sync_planned_sessions). */
export interface PlannedSessionRow {
  id: string;
  group_remote_id: string | null;
  group_name: string;
  title: string;
  starts_at: string;
  duration_minutes: number;
  location: string;
  created_by_user_id: string;
  going_count: number;
  maybe_count: number;
  my_rsvp: string;
  external_calendar_event_id: string;
  course_id: string | null;
  updated_at: string;
  deleted_at: string | null;
}

/** LinkedTask (table sync_linked_tasks). */
export interface LinkedTaskRow {
  id: string;
  provider_raw: string;
  external_id: string | null;
  title: string;
  note: string;
  due_date: string | null;
  is_done: boolean;
  priority: number;
  task_updated_at: string;
  last_synced_at: string | null;
  course_id: string | null;
  video_id: string | null;
  exercise_id: string | null;
  updated_at: string;
  deleted_at: string | null;
}

/** LinkedCalendarEvent (table sync_linked_calendar_events). */
export interface LinkedCalendarEventRow {
  id: string;
  external_event_id: string | null;
  source_calendar_id: string | null;
  title: string;
  starts_at: string;
  ends_at: string;
  location: string;
  kind_raw: string;
  is_attended: boolean;
  is_skipped: boolean;
  kind_is_manual: boolean;
  notes: string;
  last_synced_at: string | null;
  course_id: string | null;
  updated_at: string;
  deleted_at: string | null;
}

/** AcademicMilestone (table sync_academic_milestones). */
export interface AcademicMilestoneRow {
  id: string;
  external_id: string;
  title: string;
  date: string;
  kind_raw: string;
  is_important: boolean;
  is_approximate: boolean;
  term_label: string;
  is_official: boolean;
  notes: string;
  added_at: string;
  confirmed_at: string;
  updated_at: string;
  deleted_at: string | null;
}

/** PastExam (table sync_past_exams). */
export interface PastExamRow {
  id: string;
  title: string;
  year: number;
  kind_raw: string;
  url_string: string;
  solution_url_string: string;
  confidence_raw: string | null;
  worked_at: string | null;
  notes: string;
  added_at: string;
  course_id: string | null;
  updated_at: string;
  deleted_at: string | null;
}

/** Mistake (table sync_mistakes). */
export interface MistakeRow {
  id: string;
  created_at: string;
  summary: string;
  kind_raw: string;
  correction: string;
  notion: string;
  source: string;
  exercise_id: string | null;
  updated_at: string;
  deleted_at: string | null;
}

/** SavedResource (table sync_saved_resources). */
export interface SavedResourceRow {
  id: string;
  title: string;
  address: string;
  kind_raw: string;
  file_name: string;
  added_at: string;
  is_pinned: boolean;
  course_id: string | null;
  updated_at: string;
  deleted_at: string | null;
}

export interface Rows {
  sync_academic_terms: AcademicTermRow;
  sync_courses: CourseRow;
  sync_theory_items: TheoryItemRow;
  sync_exercise_series: ExerciseSeriesRow;
  sync_exercises: ExerciseRow;
  sync_sub_questions: SubQuestionRow;
  sync_study_sessions: StudySessionRow;
  sync_exams: ExamRow;
  sync_planned_sessions: PlannedSessionRow;
  sync_linked_tasks: LinkedTaskRow;
  sync_linked_calendar_events: LinkedCalendarEventRow;
  sync_academic_milestones: AcademicMilestoneRow;
  sync_past_exams: PastExamRow;
  sync_mistakes: MistakeRow;
  sync_saved_resources: SavedResourceRow;
}

export type TableName = keyof Rows;
