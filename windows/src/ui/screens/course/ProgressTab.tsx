// Progression d'un cours (ProgressTabView.swift).
//
// **Où j'en suis**, le semestre semaine par semaine, et le temps passé cette
// semaine. Ce qui traîne a son propre volet, « À rattraper » (LateTab) : la liste
// que cette page tenait comptait autrement que le badge « N en retard ».

import { useEffect, useState } from "react";
import type { Course } from "../../../models/course.ts";
import type { Exercise } from "../../../models/exercise.ts";
import type { TheoryItem } from "../../../models/theoryItem.ts";
import { TaskType, Correctness } from "../../../models/enums.ts";
import { DateUtils } from "../../../domain/dateUtils.ts";
import { Plural } from "../../../domain/plural.ts";
import { ExerciseStage } from "../../../domain/exerciseFlow.ts";
import { ProgressEngine, type WeeklyProgress } from "../../../domain/progressEngine.ts";
import { lateSummary, lateWork } from "../../../domain/lateWork.ts";
import { WorkloadEngine } from "../../../domain/workloadEngine.ts";
import { Card, EmptyState, Icon, ProgressBar, Section, cx } from "../../kit.tsx";
import { CheckCircle, HOURS_PER_CREDIT, theoryDetail } from "./common.tsx";
import "./course.css";

interface ProgressTabProps {
  course: Course;
  saveAll: (objects: object[]) => Promise<void>;
}

export function ProgressTab({ course, saveAll }: ProgressTabProps) {
  const current = course.isTermRunning ? course.currentWeek : 0;
  const [expanded, setExpanded] = useState<Set<number>>(() => new Set(current > 0 ? [current] : []));

  useEffect(() => {
    if (current <= 0) return;
    setExpanded((previous) => previous.has(current) ? previous : new Set([...previous, current]));
  }, [current]);

  const progress = ProgressEngine.progress(course);
  const weeks = ProgressEngine.semesterWeeks(course);
  const lateNow = lateWork(course);
  const unplanned = ProgressEngine.unplannedTheory(course).slice(0, 8);

  const toggleTheory = async (item: TheoryItem) => {
    item.watchedAt = item.isWatched ? null : new Date();
    await saveAll([item]);
  };

  const toggleExercise = async (exercise: Exercise) => {
    exercise.setDone(!exercise.isDone);
    await saveAll([exercise, ...exercise.subQuestions]);
  };

  const late = lateNow.total;
  const ahead = ProgressEngine.aheadCount(course);
  const sentence = late > 0
    ? Plural.count(late, "1 élément à rattraper", `${late} éléments à rattraper`)
    : ahead > 0
      ? `À jour, et ${ahead} d'avance`
      : "À jour";

  const toggleWeek = (week: number) => {
    setExpanded((previous) => {
      const next = new Set(previous);
      if (next.has(week)) next.delete(week); else next.add(week);
      return next;
    });
  };

  const weekStart = DateUtils.startOfWeek(new Date());
  const weekly = WorkloadEngine.weeklyDelta(course, HOURS_PER_CREDIT, weekStart, new Date());
  const byType = new Map<TaskType, number>();
  for (const session of course.sessions) {
    if (session.startedAt < weekStart) continue;
    const type = TaskType.canonical(session.taskType);
    byType.set(type, (byType.get(type) ?? 0) + session.durationSeconds);
  }
  const shownWeeks = weeks.filter((week) => week.hasItems || week.week === current);

  return (
    <div className="cs-col">
      {/* Où tu en es */}
      <Card className="cs-where" flat>
        <div className="caps" style={{ marginBottom: 6 }}>
          {current > 0 ? `Semaine ${current} sur ${course.term?.totalWeeks ?? 14}` : "Semestre"}
        </div>
        <div className="big">
          <Icon name={late > 0 ? "exclamationmark.triangle" : "checkmark.circle"} size={20}
            color={late > 0 ? "var(--review)" : "var(--correct)"} />
          <span className="serif">{sentence}</span>
        </div>
        {late > 0 && (
          <p className="muted" style={{ margin: "5px 0 0", fontSize: 13 }}>
            {lateSummary(lateNow).charAt(0).toUpperCase() + lateSummary(lateNow).slice(1)}.
          </p>
        )}

        <div className="cs-axes">
          <Axis title="Théorie" done={progress.watchedCount} total={progress.videoCount} />
          <Axis title="Séries" done={progress.doneCount} total={progress.exerciseCount} />
          <Axis title="Corrigés" done={progress.correctedCount} total={progress.doneCount} />
        </div>

        {progress.wrongOrRedoCount > 0 && (
          <div className="cs-redo">
            <Icon name="arrow.counterclockwise" size={14} strokeWidth={2.25} />
            {Plural.count(progress.wrongOrRedoCount,
              `${progress.wrongOrRedoCount} exercice`, `${progress.wrongOrRedoCount} exercices`)} à refaire
          </div>
        )}
      </Card>

      {/* Semaine par semaine */}
      <Section title="Semaine par semaine" style={{ marginBottom: 0 }}>
        {weeks.every((week) => !week.hasItems) ? (
          <EmptyState icon="calendar" title="Rien de planifié">Importe la théorie et les séries du cours.</EmptyState>
        ) : (
          <Card className="cs-list" flat>
            {shownWeeks.map((week) => (
              <WeekRow
                key={week.week}
                week={week}
                current={current}
                isOpen={expanded.has(week.week)}
                onToggle={() => toggleWeek(week.week)}
                theory={course.sortedTheoryItems.filter((item) => item.plannedWeek === week.week)}
                exercises={course.sortedSeries
                  .filter((series) => series.plannedWeek === week.week)
                  .flatMap((series) => series.sortedExercises)}
                onToggleTheory={(item) => void toggleTheory(item)}
                onToggleExercise={(exercise) => void toggleExercise(exercise)}
              />
            ))}
          </Card>
        )}
      </Section>

      {/* Sans semaine */}
      {unplanned.length > 0 && (
        <Section title={`Sans semaine · ${ProgressEngine.unplannedTheory(course).length}`} style={{ marginBottom: 0 }}>
          <Card className="cs-list" flat>
            {unplanned.map((item) => (
              <LateLine
                key={item.id}
                done={item.isWatched}
                week={0}
                title={item.title === "" ? item.number : item.title}
                detail="Ouvre-le pour lui donner une semaine"
                onToggle={() => void toggleTheory(item)}
              />
            ))}
          </Card>
        </Section>
      )}

      {/* Ton temps cette semaine */}
      <Section title="Ton temps cette semaine" style={{ marginBottom: 0 }}>
        <Card flat>
          <div className="hstack" style={{ alignItems: "baseline", flexWrap: "wrap" }}>
            <span className="serif" style={{ fontSize: 21 }}>{weekly.actualLabel}</span>
            <span className="muted" style={{ fontSize: 13 }}>sur {weekly.expectedLabel} attendues</span>
          </div>
          <div style={{ marginTop: 10 }}>
            <ProgressBar value={weekly.completion} color={weekly.isBehind ? "var(--review)" : "var(--course)"} />
          </div>
          {byType.size > 0 && (
            <div className="cs-time">
              {TaskType.reportCategories.filter((type) => byType.has(type)).map((type) => (
                <div key={type}>
                  <small>{TaskType.shortLabel(type)}</small>
                  <span className="mono" style={{ fontSize: 13, fontWeight: 600 }}>{DateUtils.durationLabel(byType.get(type) ?? 0)}</span>
                </div>
              ))}
            </div>
          )}
          <p className="muted" style={{ fontSize: 11, margin: "12px 0 0" }}>
            Attendu : {Math.trunc(HOURS_PER_CREDIT)} h par crédit ECTS, amphi compris.
          </p>
        </Card>
      </Section>
    </div>
  );
}

function Axis({ title, done, total }: { title: string; done: number; total: number }) {
  return (
    <div className="cs-axis">
      <small>{title}</small>
      <div className="v">
        <b style={total > 0 && done === total ? { color: "var(--correct)" } : undefined}>{total === 0 ? "—" : done}</b>
        {total > 0 && <i>/{total}</i>}
      </div>
      <div style={{ opacity: total === 0 ? 0.3 : 1 }}>
        <ProgressBar value={total === 0 ? 0 : done / total} color="var(--course)" />
      </div>
    </div>
  );
}

function LateLine({ done, week, title, detail, onToggle }:
  { done: boolean; week: number; title: string; detail: string; onToggle: () => void }) {
  return (
    <div className={cx("cs-late", done && "done")}>
      <CheckCircle isOn={done} tint="var(--course)" label={done ? `Marquer ${title} à faire` : `Marquer ${title} fait`}
        onToggle={onToggle} size={20} />
      <div className="grow">
        <div className="t">{title}</div>
        <div className="d">{week > 0 ? `S${week} · ${detail}` : detail}</div>
      </div>
    </div>
  );
}

function WeekRow({ week, current, isOpen, onToggle, theory, exercises, onToggleTheory, onToggleExercise }: {
  week: WeeklyProgress;
  current: number;
  isOpen: boolean;
  onToggle: () => void;
  theory: TheoryItem[];
  exercises: Exercise[];
  onToggleTheory: (item: TheoryItem) => void;
  onToggleExercise: (exercise: Exercise) => void;
}) {
  const isCurrent = week.week === current;
  const isLate = current > 0 && week.week < current && week.remainingCount > 0;
  const total = week.videoCount + week.exerciseCount;
  const done = week.watchedCount + week.doneCount;

  return (
    <div className="cs-wk">
      <button type="button" className="cs-wk-head" disabled={!week.hasItems} onClick={onToggle}
        aria-expanded={week.hasItems ? isOpen : undefined}>
        <span className={cx("cs-wk-badge", isCurrent && "current")}>S{week.week}</span>
        <span className="cs-wk-info">
          <span className="cs-wk-line">
            <span className="grow">{weekSummary(week)}</span>
            {week.isComplete ? (
              <span className="tag ok"><Icon name="checkmark" size={12} strokeWidth={3} /></span>
            ) : isLate ? (
              <span className="tag late">
                {Plural.count(week.remainingCount, `${week.remainingCount} restant`, `${week.remainingCount} restants`)}
              </span>
            ) : isCurrent ? (
              <span className="tag">en cours</span>
            ) : null}
          </span>
          <span style={{ display: "block", opacity: total === 0 ? 0.3 : 1 }}>
            <ProgressBar value={total === 0 ? 0 : done / total} color={week.isComplete ? "var(--correct)" : "var(--course)"} />
          </span>
        </span>
        {week.hasItems && <Icon name="chevron.right" size={14} className={cx("cs-wk-chev", isOpen && "open")} />}
      </button>

      {isOpen && (
        <div className="cs-wk-body">
          {theory.map((item) => (
            <LateLine
              key={item.id}
              done={item.isWatched}
              week={0}
              title={item.title === "" ? item.number : item.title}
              detail={theoryDetail(item)}
              onToggle={() => onToggleTheory(item)}
            />
          ))}
          {exercises.map((exercise) => (
            <LateLine
              key={exercise.id}
              done={exercise.isDone}
              week={0}
              title={exercise.displayNumber + (exercise.isBonus ? " (bonus)" : "")}
              detail={exercise.isCorrected
                ? (exercise.correctness ? Correctness.shortLabel(exercise.correctness) : "corrigé")
                : ExerciseStage.label(ExerciseStage(exercise))}
              onToggle={() => onToggleExercise(exercise)}
            />
          ))}
        </div>
      )}
    </div>
  );
}


/** « Théorie 1/1 · Série 4 : 3/5 ». */
function weekSummary(week: WeeklyProgress): string {
  if (!week.hasItems) return "Rien de prévu";
  const parts: string[] = [];
  if (week.videoCount > 0) parts.push(`Théorie ${week.watchedCount}/${week.videoCount}`);
  if (week.exerciseCount > 0) {
    const name = week.seriesNumbers.length === 0 ? "Séries" : `Série ${week.seriesNumbers.join(", ")}`;
    parts.push(`${name} : ${week.doneCount}/${week.exerciseCount}`);
  }
  return parts.join(" · ");
}
