// La semaine en un coup d'œil (Polymestre/Views/Home/TodayWeekCard.swift) :
// les heures depuis lundi, jour par jour, et l'avancement de la semaine — théorie,
// séries, corrigés, tous cours confondus. Puis une carte par cours suivi.

import { DateUtils } from "../../../domain/dateUtils.ts";
import { ExamKind } from "../../../models/enums.ts";
import type { WeekCourseSummary } from "../../../domain/progressEngine.ts";
import { Plural } from "../../../domain/plural.ts";
import { Card, Icon, ProgressBar, cx } from "../../kit.tsx";
import "./today.css";

/** Pastille d'un cours : un point de couleur et son code, comme `CourseTag`. */
export function CourseTag({ code, tint, size = 12 }:
  { code: string; tint: string; size?: number }) {
  return (
    <span className="t-tag" style={{ color: tint, fontSize: size }}>
      <i style={{ background: tint }} />
      <span className="t-ellipsis">{code}</span>
    </span>
  );
}

/** Une barre « fait / prévu », avec son libellé et son compte. */
export function ProgressAxis({ label, done, total, tint, height = 4, small }:
  { label: string; done: number; total: number; tint: string; height?: number; small?: boolean }) {
  const ratio = total <= 0 ? 0 : Math.min(1, done / total);
  const complete = total > 0 && done === total;
  return (
    <div className={cx("t-axis", small && "small", total === 0 && "empty-axis")} style={{ minWidth: 0 }}>
      <div className="t-axis-head">
        <span className="t-axis-label t-ellipsis">{label}</span>
        <span className={cx("mono t-axis-count", complete && "complete")}>{total === 0 ? "—" : `${done}/${total}`}</span>
      </div>
      <ProgressBar value={ratio} color={tint} height={height} />
    </div>
  );
}

interface AxisValue { done: number; total: number }

/** Les sept jours de la semaine, du lundi au dimanche (barres + initiale). */
function DayStrip({ days, weekStart, now }: { days: number[]; weekStart: Date; now: Date }) {
  const todayIndex = Math.min(Math.max(DateUtils.daysBetween(weekStart, now), 0), 6);
  const peak = Math.max(...days, 3600);
  return (
    <div className="t-days" role="img" aria-label="Heures par jour de la semaine">
      {Array.from({ length: 7 }, (_, index) => {
        const seconds = days[index] ?? 0;
        const isToday = index === todayIndex;
        const height = seconds === 0 ? 0 : Math.max(3, (44 * seconds) / peak);
        return (
          <div key={index} className="t-day"
            title={`${DateUtils.shortDay(DateUtils.addDays(index, weekStart))} · ${DateUtils.hoursLabel(seconds)}`}>
            <div className={cx("t-day-track", index > todayIndex && "future")}>
              <div className={cx("t-day-fill", isToday && "today")} style={{ height }} />
            </div>
            <span className={cx("mono t-day-label", isToday && "today")}>
              {DateUtils.weekdayInitial(DateUtils.addDays(index, weekStart))}
            </span>
          </div>
        );
      })}
    </div>
  );
}

/**
 * « Depuis lundi » : le total, le jour même, la bande des sept jours et les trois
 * axes de la semaine. Un total attendu comparé à un mercredi ne dit rien d'utile :
 * ce qui compte est ce qui est fait, d'où des barres et pas un retard.
 */
export function WeekTimeCard({ days, weekStart, theory, series, corrections, late, goal, now }:
  {
    days: number[]; weekStart: Date; theory: AxisValue; series: AxisValue;
    corrections: AxisValue; late: number; goal: number; now: Date;
  }) {
  const total = days.reduce((sum, value) => sum + value, 0);
  const todayIndex = Math.min(Math.max(DateUtils.daysBetween(weekStart, now), 0), 6);
  const today = days[todayIndex] ?? 0;
  return (
    <Card className="t-week">
      <div className="t-week-head">
        <span className="t-kicker">Depuis lundi</span>
        <span className="faint" style={{ fontSize: 11 }}>
          {today > 0 ? `dont ${DateUtils.durationLabel(today)} aujourd'hui` : "rien encore aujourd'hui"}
        </span>
      </div>

      <div className="t-week-main">
        <div className="stack" style={{ gap: 2 }}>
          <div className="t-week-total">
            <span className="serif big">{DateUtils.hoursLabel(total)}</span>
            {goal > 0 && (
              <span style={{ fontSize: 13, color: total >= goal ? "var(--correct)" : "var(--ink-secondary)" }}>
                / {DateUtils.hoursLabel(goal)}
              </span>
            )}
          </div>
          <span className="t-sub">cette semaine · lundi → dimanche</span>
        </div>
        <DayStrip days={days} weekStart={weekStart} now={now} />
      </div>

      <hr className="divider" />

      <div className="t-week-axes">
        <ProgressAxis label="Théorie" done={theory.done} total={theory.total} tint="var(--ink)" height={5} />
        <ProgressAxis label="Séries" done={series.done} total={series.total} tint="var(--ink)" height={5} />
        <ProgressAxis label="Corrigés" done={corrections.done} total={corrections.total} tint="var(--ink)" height={5} />
      </div>

      {late > 0 && (
        <div className="t-late">
          <Icon name="exclamationmark.triangle" size={14} />
          <span>{Plural.count(late, "1 élément des semaines passées à rattraper", `${late} éléments des semaines passées à rattraper`)}</span>
        </div>
      )}
    </Card>
  );
}

/** Une carte de cours dans sa semaine : les trois axes, le retard en mots, l'examen proche. */
export function WeekCourseRow({ summary, onOpen, onOpenLate }:
  { summary: WeekCourseSummary; onOpen: (id: string) => void; onOpenLate?: (id: string) => void }) {
  const course = summary.course;
  const week = summary.week;
  const tint = course.colorHex;
  const nextExam = course.nextExam;
  const examDays = nextExam ? DateUtils.daysBetween(new Date(), nextExam.date) : null;
  const examSoon = nextExam !== null && examDays !== null && examDays <= 14;
  return (
    <button type="button" className="t-course" style={{ ["--course-tint" as string]: tint }}
      onClick={() => onOpen(course.id)}>
      <span className="t-course-top">
        <CourseTag code={course.displayCode} tint={tint} />
        <StandingLabel late={summary.late} ahead={summary.ahead} complete={week.isComplete}
          onLate={onOpenLate ? () => onOpenLate(course.id) : undefined} />
      </span>
      <span className="serif t-course-name">{course.name === "" ? course.displayCode : course.name}</span>
      {week.hasItems ? (
        <span className="t-course-axes">
          <ProgressAxis label="Théorie" done={week.watchedCount} total={week.videoCount} tint={tint} small />
          <ProgressAxis label="Exercices" done={week.doneCount} total={week.exerciseCount} tint={tint} small />
          {week.doneCount > 0 && (
            <ProgressAxis label="Corrigés" done={week.correctedCount} total={week.doneCount} tint={tint} small />
          )}
        </span>
      ) : (
        <span className="t-sub">{summary.late > 0 ? "Rien de nouveau cette semaine : le moment de rattraper" : "Rien de prévu cette semaine"}</span>
      )}
      {!summary.corrections.isEmpty && (
        <span className="t-sub-xs">{correctionsLine(summary)}</span>
      )}
      {examSoon && nextExam && (
        <span className={cx("t-sub-xs", examDays !== null && examDays <= 3 && "urgent")} style={{ fontWeight: 500 }}>
          {ExamKind.label(nextExam.kind)} {DateUtils.countdownLabel(nextExam.date).toLowerCase()}
        </span>
      )}
    </button>
  );
}

function StandingLabel({ late, ahead, complete, onLate }: { late: number; ahead: number; complete: boolean; onLate?: () => void }) {
  if (late > 0) {
    // Dans la carte (un bouton) : un élément cliquable, pas un second bouton.
    return onLate
      ? <span className="t-standing late t-late-link" role="link" tabIndex={0} title="Ce qui est à rattraper"
          onClick={(event) => { event.stopPropagation(); onLate(); }}
          onKeyDown={(event) => { if (event.key === "Enter") { event.stopPropagation(); onLate(); } }}>
          {late} en retard ›
        </span>
      : <span className="t-standing late">{late} en retard</span>;
  }
  if (complete) return <span className="t-standing ok"><Icon name="checkmark" size={12} strokeWidth={2.5} />semaine faite</span>;
  if (ahead > 0) return <span className="t-standing ok">{ahead} d'avance</span>;
  return <span className="t-standing quiet"><Icon name="checkmark" size={12} />À jour</span>;
}

function correctionsLine(summary: WeekCourseSummary): string {
  // Hors retard : celles des séries échues sont déjà dans « N en retard ».
  return `${summary.corrections.toCorrect} à corriger cette semaine`;
}
