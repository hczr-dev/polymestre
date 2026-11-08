-- Généré par windows/scripts/gen-schema.ts depuis src/models/schema.ts — ne pas modifier à la main.
--
-- Synchronisation des données personnelles entre l'iPhone, le Mac et Windows.
--
-- Une table par `@Model` de SchemaV1 (hors copies locales des groupes). Chaque
-- ligne appartient à `user_id` ; seule sa propriétaire la lit et l'écrit.
--
-- Trois horodatages :
--   updated_at         heure de la modification, posée par l'appareil : c'est
--                      elle qui départage deux écritures (la plus récente gagne) ;
--   deleted_at         pierre tombale : une suppression se propage comme une
--                      écriture, et un appareil hors ligne l'apprend au retour ;
--   server_updated_at  posée ici, à chaque écriture acceptée : le curseur des
--                      lectures incrémentales (l'horloge d'un appareil ne peut
--                      pas en servir). Les clients relisent avec une marge, une
--                      transaction pouvant valider après une autre plus récente.
--
-- Pas de clés étrangères entre ces tables : un appareil resté hors ligne peut
-- envoyer l'enfant d'un parent supprimé ailleurs, et cet envoi ne doit pas
-- échouer. Les règles de suppression (cascade / mise à nul) sont appliquées par
-- les clients, telles que SwiftData les déclare.

create or replace function public.sync_guard()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'UPDATE' then
    if new.user_id is distinct from old.user_id then
      raise exception 'une ligne ne change pas de propriétaire' using errcode = '42501';
    end if;
    -- Écriture plus ancienne que la ligne : ignorée, la version récente reste.
    if new.updated_at < old.updated_at then
      return old;
    end if;
  end if;
  new.server_updated_at := clock_timestamp();
  return new;
end;
$$;

-- AcademicTerm
create table if not exists public.sync_academic_terms (
  id                uuid primary key,
  user_id           uuid not null default auth.uid() references auth.users(id) on delete cascade,
  year bigint not null default 0,
  season_raw text not null default '',
  start_date timestamptz not null default now(),
  end_date timestamptz not null default now(),
  total_weeks bigint not null default 0,
  name text not null default '',
  updated_at        timestamptz not null default now(),
  deleted_at        timestamptz,
  server_updated_at timestamptz not null default now()
);

create index if not exists sync_academic_terms_pull_idx on public.sync_academic_terms (user_id, server_updated_at);

alter table public.sync_academic_terms enable row level security;

drop policy if exists sync_academic_terms_owner on public.sync_academic_terms;
create policy sync_academic_terms_owner on public.sync_academic_terms
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

drop trigger if exists sync_academic_terms_guard on public.sync_academic_terms;
create trigger sync_academic_terms_guard before insert or update on public.sync_academic_terms
  for each row execute function public.sync_guard();

-- Course
create table if not exists public.sync_courses (
  id                uuid primary key,
  user_id           uuid not null default auth.uid() references auth.users(id) on delete cascade,
  code text not null default '',
  name text not null default '',
  short_name text not null default '',
  credits double precision not null default 0,
  color_hex text not null default '',
  icon_name text not null default '',
  weekly_lecture_hours double precision not null default 0,
  weekly_exercise_hours double precision not null default 0,
  weekly_self_study_hours double precision,
  has_lectures boolean not null default false,
  section_code text not null default '',
  is_tracked boolean not null default false,
  is_active boolean not null default false,
  lecturer text not null default '',
  moodle_url_string text not null default '',
  notes text not null default '',
  content_sources_raw text not null default '',
  content_ignored_raw text not null default '',
  documents_raw text not null default '',
  week_guide_raw text not null default '',
  revision_sheet_raw text not null default '',
  study_map_raw text not null default '',
  term_id uuid,
  updated_at        timestamptz not null default now(),
  deleted_at        timestamptz,
  server_updated_at timestamptz not null default now()
);

create index if not exists sync_courses_pull_idx on public.sync_courses (user_id, server_updated_at);
create index if not exists sync_courses_term_id_idx on public.sync_courses (term_id);

alter table public.sync_courses enable row level security;

drop policy if exists sync_courses_owner on public.sync_courses;
create policy sync_courses_owner on public.sync_courses
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

drop trigger if exists sync_courses_guard on public.sync_courses;
create trigger sync_courses_guard before insert or update on public.sync_courses
  for each row execute function public.sync_guard();

-- TheoryItem
create table if not exists public.sync_theory_items (
  id                uuid primary key,
  user_id           uuid not null default auth.uid() references auth.users(id) on delete cascade,
  section_number bigint not null default 0,
  number text not null default '',
  title text not null default '',
  duration_seconds bigint not null default 0,
  planned_week bigint not null default 0,
  sort_order bigint not null default 0,
  kind_raw text not null default '',
  watched_at timestamptz,
  summarized_at timestamptz,
  summary_text text,
  url_string text not null default '',
  video_count bigint not null default 0,
  section_title text not null default '',
  source_raw text not null default '',
  links_raw text not null default '',
  course_id uuid,
  updated_at        timestamptz not null default now(),
  deleted_at        timestamptz,
  server_updated_at timestamptz not null default now()
);

create index if not exists sync_theory_items_pull_idx on public.sync_theory_items (user_id, server_updated_at);
create index if not exists sync_theory_items_course_id_idx on public.sync_theory_items (course_id);

alter table public.sync_theory_items enable row level security;

drop policy if exists sync_theory_items_owner on public.sync_theory_items;
create policy sync_theory_items_owner on public.sync_theory_items
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

drop trigger if exists sync_theory_items_guard on public.sync_theory_items;
create trigger sync_theory_items_guard before insert or update on public.sync_theory_items
  for each row execute function public.sync_guard();

-- ExerciseSeries
create table if not exists public.sync_exercise_series (
  id                uuid primary key,
  user_id           uuid not null default auth.uid() references auth.users(id) on delete cascade,
  series_number bigint not null default 0,
  title text not null default '',
  planned_week bigint not null default 0,
  published_at timestamptz,
  due_date timestamptz,
  url_string text not null default '',
  topic text not null default '',
  solutions_at timestamptz,
  solution_url_string text not null default '',
  needs_reread boolean not null default false,
  label text not null default '',
  course_id uuid,
  updated_at        timestamptz not null default now(),
  deleted_at        timestamptz,
  server_updated_at timestamptz not null default now()
);

create index if not exists sync_exercise_series_pull_idx on public.sync_exercise_series (user_id, server_updated_at);
create index if not exists sync_exercise_series_course_id_idx on public.sync_exercise_series (course_id);

alter table public.sync_exercise_series enable row level security;

drop policy if exists sync_exercise_series_owner on public.sync_exercise_series;
create policy sync_exercise_series_owner on public.sync_exercise_series
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

drop trigger if exists sync_exercise_series_guard on public.sync_exercise_series;
create trigger sync_exercise_series_guard before insert or update on public.sync_exercise_series
  for each row execute function public.sync_guard();

-- Exercise
create table if not exists public.sync_exercises (
  id                uuid primary key,
  user_id           uuid not null default auth.uid() references auth.users(id) on delete cascade,
  exercise_number text not null default '',
  title text not null default '',
  statement text not null default '',
  is_bonus boolean not null default false,
  sort_order bigint not null default 0,
  statement_url_string text not null default '',
  hint text not null default '',
  solution text not null default '',
  done_at timestamptz,
  confidence_raw text,
  corrected_at timestamptz,
  correctness_raw text,
  redo_required boolean not null default false,
  correction_note text,
  score double precision,
  max_score double precision,
  redo_pass bigint,
  redo_due_at timestamptz,
  redo_why text not null default '',
  redo_first_move text not null default '',
  redo_failures bigint not null default 0,
  redo_last_result_raw text,
  redo_cleared_at timestamptz,
  hint_level bigint not null default 0,
  hint_log text not null default '',
  series_id uuid,
  updated_at        timestamptz not null default now(),
  deleted_at        timestamptz,
  server_updated_at timestamptz not null default now()
);

create index if not exists sync_exercises_pull_idx on public.sync_exercises (user_id, server_updated_at);
create index if not exists sync_exercises_series_id_idx on public.sync_exercises (series_id);

alter table public.sync_exercises enable row level security;

drop policy if exists sync_exercises_owner on public.sync_exercises;
create policy sync_exercises_owner on public.sync_exercises
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

drop trigger if exists sync_exercises_guard on public.sync_exercises;
create trigger sync_exercises_guard before insert or update on public.sync_exercises
  for each row execute function public.sync_guard();

-- SubQuestion
create table if not exists public.sync_sub_questions (
  id                uuid primary key,
  user_id           uuid not null default auth.uid() references auth.users(id) on delete cascade,
  label text not null default '',
  text text not null default '',
  kind_raw text not null default 'question',
  is_done boolean not null default false,
  done_at timestamptz,
  sort_order bigint not null default 0,
  exercise_id uuid,
  parent_id uuid,
  updated_at        timestamptz not null default now(),
  deleted_at        timestamptz,
  server_updated_at timestamptz not null default now()
);

create index if not exists sync_sub_questions_pull_idx on public.sync_sub_questions (user_id, server_updated_at);
create index if not exists sync_sub_questions_exercise_id_idx on public.sync_sub_questions (exercise_id);
create index if not exists sync_sub_questions_parent_id_idx on public.sync_sub_questions (parent_id);

alter table public.sync_sub_questions enable row level security;

drop policy if exists sync_sub_questions_owner on public.sync_sub_questions;
create policy sync_sub_questions_owner on public.sync_sub_questions
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

drop trigger if exists sync_sub_questions_guard on public.sync_sub_questions;
create trigger sync_sub_questions_guard before insert or update on public.sync_sub_questions
  for each row execute function public.sync_guard();

-- StudySession
create table if not exists public.sync_study_sessions (
  id                uuid primary key,
  user_id           uuid not null default auth.uid() references auth.users(id) on delete cascade,
  task_type_raw text not null default '',
  started_at timestamptz not null default now(),
  duration_seconds bigint not null default 0,
  is_manual boolean not null default false,
  note text not null default '',
  created_at timestamptz not null default now(),
  source_raw text not null default '',
  external_key text not null default '',
  course_id uuid,
  exercise_id uuid,
  theory_item_id uuid,
  updated_at        timestamptz not null default now(),
  deleted_at        timestamptz,
  server_updated_at timestamptz not null default now()
);

create index if not exists sync_study_sessions_pull_idx on public.sync_study_sessions (user_id, server_updated_at);
create index if not exists sync_study_sessions_course_id_idx on public.sync_study_sessions (course_id);
create index if not exists sync_study_sessions_exercise_id_idx on public.sync_study_sessions (exercise_id);
create index if not exists sync_study_sessions_theory_item_id_idx on public.sync_study_sessions (theory_item_id);

alter table public.sync_study_sessions enable row level security;

drop policy if exists sync_study_sessions_owner on public.sync_study_sessions;
create policy sync_study_sessions_owner on public.sync_study_sessions
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

drop trigger if exists sync_study_sessions_guard on public.sync_study_sessions;
create trigger sync_study_sessions_guard before insert or update on public.sync_study_sessions
  for each row execute function public.sync_guard();

-- Exam
create table if not exists public.sync_exams (
  id                uuid primary key,
  user_id           uuid not null default auth.uid() references auth.users(id) on delete cascade,
  kind_raw text not null default '',
  title text not null default '',
  date timestamptz not null default now(),
  weight_percent double precision,
  location text not null default '',
  url_string text not null default '',
  notes text not null default '',
  external_calendar_event_id text,
  course_id uuid,
  updated_at        timestamptz not null default now(),
  deleted_at        timestamptz,
  server_updated_at timestamptz not null default now()
);

create index if not exists sync_exams_pull_idx on public.sync_exams (user_id, server_updated_at);
create index if not exists sync_exams_course_id_idx on public.sync_exams (course_id);

alter table public.sync_exams enable row level security;

drop policy if exists sync_exams_owner on public.sync_exams;
create policy sync_exams_owner on public.sync_exams
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

drop trigger if exists sync_exams_guard on public.sync_exams;
create trigger sync_exams_guard before insert or update on public.sync_exams
  for each row execute function public.sync_guard();

-- PlannedSession
create table if not exists public.sync_planned_sessions (
  id                uuid primary key,
  user_id           uuid not null default auth.uid() references auth.users(id) on delete cascade,
  group_remote_id text,
  group_name text not null default '',
  title text not null default '',
  starts_at timestamptz not null default now(),
  duration_minutes bigint not null default 0,
  location text not null default '',
  created_by_user_id text not null default '',
  going_count bigint not null default 0,
  maybe_count bigint not null default 0,
  my_rsvp text not null default '',
  external_calendar_event_id text not null default '',
  course_id uuid,
  updated_at        timestamptz not null default now(),
  deleted_at        timestamptz,
  server_updated_at timestamptz not null default now()
);

create index if not exists sync_planned_sessions_pull_idx on public.sync_planned_sessions (user_id, server_updated_at);
create index if not exists sync_planned_sessions_course_id_idx on public.sync_planned_sessions (course_id);

alter table public.sync_planned_sessions enable row level security;

drop policy if exists sync_planned_sessions_owner on public.sync_planned_sessions;
create policy sync_planned_sessions_owner on public.sync_planned_sessions
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

drop trigger if exists sync_planned_sessions_guard on public.sync_planned_sessions;
create trigger sync_planned_sessions_guard before insert or update on public.sync_planned_sessions
  for each row execute function public.sync_guard();

-- LinkedTask
create table if not exists public.sync_linked_tasks (
  id                uuid primary key,
  user_id           uuid not null default auth.uid() references auth.users(id) on delete cascade,
  provider_raw text not null default '',
  external_id text,
  title text not null default '',
  note text not null default '',
  due_date timestamptz,
  is_done boolean not null default false,
  priority bigint not null default 0,
  task_updated_at timestamptz not null default now(),
  last_synced_at timestamptz,
  course_id uuid,
  video_id uuid,
  exercise_id uuid,
  updated_at        timestamptz not null default now(),
  deleted_at        timestamptz,
  server_updated_at timestamptz not null default now()
);

create index if not exists sync_linked_tasks_pull_idx on public.sync_linked_tasks (user_id, server_updated_at);
create index if not exists sync_linked_tasks_course_id_idx on public.sync_linked_tasks (course_id);
create index if not exists sync_linked_tasks_video_id_idx on public.sync_linked_tasks (video_id);
create index if not exists sync_linked_tasks_exercise_id_idx on public.sync_linked_tasks (exercise_id);

alter table public.sync_linked_tasks enable row level security;

drop policy if exists sync_linked_tasks_owner on public.sync_linked_tasks;
create policy sync_linked_tasks_owner on public.sync_linked_tasks
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

drop trigger if exists sync_linked_tasks_guard on public.sync_linked_tasks;
create trigger sync_linked_tasks_guard before insert or update on public.sync_linked_tasks
  for each row execute function public.sync_guard();

-- LinkedCalendarEvent
create table if not exists public.sync_linked_calendar_events (
  id                uuid primary key,
  user_id           uuid not null default auth.uid() references auth.users(id) on delete cascade,
  external_event_id text,
  source_calendar_id text,
  title text not null default '',
  starts_at timestamptz not null default now(),
  ends_at timestamptz not null default now(),
  location text not null default '',
  kind_raw text not null default '',
  is_attended boolean not null default false,
  is_skipped boolean not null default false,
  kind_is_manual boolean not null default false,
  notes text not null default '',
  last_synced_at timestamptz,
  course_id uuid,
  updated_at        timestamptz not null default now(),
  deleted_at        timestamptz,
  server_updated_at timestamptz not null default now()
);

create index if not exists sync_linked_calendar_events_pull_idx on public.sync_linked_calendar_events (user_id, server_updated_at);
create index if not exists sync_linked_calendar_events_course_id_idx on public.sync_linked_calendar_events (course_id);

alter table public.sync_linked_calendar_events enable row level security;

drop policy if exists sync_linked_calendar_events_owner on public.sync_linked_calendar_events;
create policy sync_linked_calendar_events_owner on public.sync_linked_calendar_events
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

drop trigger if exists sync_linked_calendar_events_guard on public.sync_linked_calendar_events;
create trigger sync_linked_calendar_events_guard before insert or update on public.sync_linked_calendar_events
  for each row execute function public.sync_guard();

-- AcademicMilestone
create table if not exists public.sync_academic_milestones (
  id                uuid primary key,
  user_id           uuid not null default auth.uid() references auth.users(id) on delete cascade,
  external_id text not null default '',
  title text not null default '',
  date timestamptz not null default now(),
  kind_raw text not null default '',
  is_important boolean not null default false,
  is_approximate boolean not null default false,
  term_label text not null default '',
  is_official boolean not null default false,
  notes text not null default '',
  added_at timestamptz not null default now(),
  confirmed_at timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  deleted_at        timestamptz,
  server_updated_at timestamptz not null default now()
);

create index if not exists sync_academic_milestones_pull_idx on public.sync_academic_milestones (user_id, server_updated_at);

alter table public.sync_academic_milestones enable row level security;

drop policy if exists sync_academic_milestones_owner on public.sync_academic_milestones;
create policy sync_academic_milestones_owner on public.sync_academic_milestones
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

drop trigger if exists sync_academic_milestones_guard on public.sync_academic_milestones;
create trigger sync_academic_milestones_guard before insert or update on public.sync_academic_milestones
  for each row execute function public.sync_guard();

-- PastExam
create table if not exists public.sync_past_exams (
  id                uuid primary key,
  user_id           uuid not null default auth.uid() references auth.users(id) on delete cascade,
  title text not null default '',
  year bigint not null default 0,
  kind_raw text not null default '',
  url_string text not null default '',
  solution_url_string text not null default '',
  confidence_raw text,
  worked_at timestamptz,
  notes text not null default '',
  added_at timestamptz not null default now(),
  course_id uuid,
  updated_at        timestamptz not null default now(),
  deleted_at        timestamptz,
  server_updated_at timestamptz not null default now()
);

create index if not exists sync_past_exams_pull_idx on public.sync_past_exams (user_id, server_updated_at);
create index if not exists sync_past_exams_course_id_idx on public.sync_past_exams (course_id);

alter table public.sync_past_exams enable row level security;

drop policy if exists sync_past_exams_owner on public.sync_past_exams;
create policy sync_past_exams_owner on public.sync_past_exams
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

drop trigger if exists sync_past_exams_guard on public.sync_past_exams;
create trigger sync_past_exams_guard before insert or update on public.sync_past_exams
  for each row execute function public.sync_guard();

-- Mistake
create table if not exists public.sync_mistakes (
  id                uuid primary key,
  user_id           uuid not null default auth.uid() references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  summary text not null default '',
  kind_raw text not null default 'method',
  correction text not null default '',
  notion text not null default '',
  source text not null default 'manual',
  exercise_id uuid,
  updated_at        timestamptz not null default now(),
  deleted_at        timestamptz,
  server_updated_at timestamptz not null default now()
);

create index if not exists sync_mistakes_pull_idx on public.sync_mistakes (user_id, server_updated_at);
create index if not exists sync_mistakes_exercise_id_idx on public.sync_mistakes (exercise_id);

alter table public.sync_mistakes enable row level security;

drop policy if exists sync_mistakes_owner on public.sync_mistakes;
create policy sync_mistakes_owner on public.sync_mistakes
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

drop trigger if exists sync_mistakes_guard on public.sync_mistakes;
create trigger sync_mistakes_guard before insert or update on public.sync_mistakes
  for each row execute function public.sync_guard();

-- SavedResource
create table if not exists public.sync_saved_resources (
  id                uuid primary key,
  user_id           uuid not null default auth.uid() references auth.users(id) on delete cascade,
  title text not null default '',
  address text not null default '',
  kind_raw text not null default '',
  file_name text not null default '',
  added_at timestamptz not null default now(),
  is_pinned boolean not null default false,
  course_id uuid,
  updated_at        timestamptz not null default now(),
  deleted_at        timestamptz,
  server_updated_at timestamptz not null default now()
);

create index if not exists sync_saved_resources_pull_idx on public.sync_saved_resources (user_id, server_updated_at);
create index if not exists sync_saved_resources_course_id_idx on public.sync_saved_resources (course_id);

alter table public.sync_saved_resources enable row level security;

drop policy if exists sync_saved_resources_owner on public.sync_saved_resources;
create policy sync_saved_resources_owner on public.sync_saved_resources
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

drop trigger if exists sync_saved_resources_guard on public.sync_saved_resources;
create trigger sync_saved_resources_guard before insert or update on public.sync_saved_resources
  for each row execute function public.sync_guard();

-- Les appareils ouverts apprennent les écritures des autres sans attendre.
do $$
begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'sync_academic_terms') then
    alter publication supabase_realtime add table public.sync_academic_terms;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'sync_courses') then
    alter publication supabase_realtime add table public.sync_courses;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'sync_theory_items') then
    alter publication supabase_realtime add table public.sync_theory_items;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'sync_exercise_series') then
    alter publication supabase_realtime add table public.sync_exercise_series;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'sync_exercises') then
    alter publication supabase_realtime add table public.sync_exercises;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'sync_sub_questions') then
    alter publication supabase_realtime add table public.sync_sub_questions;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'sync_study_sessions') then
    alter publication supabase_realtime add table public.sync_study_sessions;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'sync_exams') then
    alter publication supabase_realtime add table public.sync_exams;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'sync_planned_sessions') then
    alter publication supabase_realtime add table public.sync_planned_sessions;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'sync_linked_tasks') then
    alter publication supabase_realtime add table public.sync_linked_tasks;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'sync_linked_calendar_events') then
    alter publication supabase_realtime add table public.sync_linked_calendar_events;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'sync_academic_milestones') then
    alter publication supabase_realtime add table public.sync_academic_milestones;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'sync_past_exams') then
    alter publication supabase_realtime add table public.sync_past_exams;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'sync_mistakes') then
    alter publication supabase_realtime add table public.sync_mistakes;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'sync_saved_resources') then
    alter publication supabase_realtime add table public.sync_saved_resources;
  end if;
end;
$$;
