// Aujourd'hui — le tableau de bord de la semaine (MacTodayView.swift,
// Polymestre/Views/Home/TodayView.swift + TodayWeekCard.swift).
//
// On y lit le `ModelStore` via `useData()` et on laisse le domaine calculer :
// `StudyTime` pour les heures, `ProgressEngine` pour la théorie / les séries /
// les corrigés, `Deadline` pour les échéances. L'écran ne recompte rien.

import { readCounting, toggleChecked } from "../../domain/studyCounting.ts";
import { useData } from "../../data/dataContext.tsx";
import { MoodleNewsCard } from "./home/moodleNewsCard.tsx";
import { Course, LinkedTask } from "../../models/index.ts";
import { DateUtils } from "../../domain/dateUtils.ts";
import { PageHeader, Section, Card, EmptyState } from "../kit.tsx";
import { buildHomeData } from "./home/todayModel.ts";
import { WeekTimeCard, WeekCourseRow } from "./home/weekCard.tsx";
import { DeadlineRow, GoalRing, NextActionCard, PlanRow, SessionRow, TaskRow } from "./home/todayParts.tsx";
import { RunningNowCard } from "./home/runningNow.tsx";
import { timerController } from "../timerController.ts";
import { useSyncExternalStore } from "react";
import "./home/today.css";

const subscribeTimer = timerController.subscribe;
const timerRunning = () => timerController.snapshot().state !== null;

export function TodayScreen({ onOpenCourse, onOpenFocus, onEnterStudyMode }: {
  /** `item` : l'élément à montrer ; le cours lui-même ouvre « À rattraper ». */
  onOpenCourse: (id: string, item?: string | null) => void;
  onOpenFocus?: () => void;
  onEnterStudyMode?: (courseID?: string) => void;
}) {
  const { store, save } = useData();
  const timing = useSyncExternalStore(subscribeTimer, timerRunning);
  const now = new Date();
  if (!store) return null;

  const courses = store.fetch(Course).sort((a, b) => a.code.localeCompare(b.code));
  const data = buildHomeData(store, courses, now);
  const {
    term, summaries, weekStart, days, weekTotal, theory, series, corrections, late,
    weeklyGoal, dailyGoal, todayTotal, todaySessions, todayItems, deadlines, nextAction,
  } = data;

  // Les tâches ouvertes des fournisseurs reliés, dues dans la semaine ou en retard (8 au plus).
  const soon = DateUtils.addDays(7, DateUtils.startOfDay(now));
  const tasks = store.fetch(LinkedTask)
    .filter((task) => !task.isDone && task.dueDate !== null && task.dueDate.getTime() < soon.getTime())
    .sort((a, b) => a.dueDate!.getTime() - b.dueDate!.getTime())
    .slice(0, 8);

  const termLine = term
    ? term.hasEnded
      ? "semestre terminé"
      : term.hasNotStarted
        ? "semestre à venir"
        : `semaine ${term.currentWeek} sur ${term.totalWeeks}`
    : null;
  const weekTitle = term?.isRunning ? `Semaine ${term.currentWeek}` : "Cette semaine";
  const sessionsTotal = todaySessions.reduce((sum, session) => sum + session.durationSeconds, 0);

  const headerActions = (
    <div className="t-total">
      <div className="t-total-text">
        <div className="mono t-total-value">{DateUtils.hoursLabel(todayTotal)}</div>
        <div className="t-total-sub">
          sur {DateUtils.hoursLabel(dailyGoal)} · {DateUtils.hoursLabel(weekTotal)} cette semaine
        </div>
      </div>
      <GoalRing seconds={todayTotal} goal={dailyGoal} />
    </div>
  );

  return (
    <>
      <PageHeader
        title="Aujourd'hui"
        subtitle={[DateUtils.fullDayLabel(now), termLine].filter((part): part is string => part !== null).join(" · ")}
        actions={headerActions}
      />

      {summaries.length === 0 ? (
        <Card>
          <EmptyState icon="books.vertical" title="Aucun cours suivi">
            Séries, vidéos et échéances, lues sur Moodle. Ajoute un cours depuis l'écran Cours.
          </EmptyState>
        </Card>
      ) : (
        <>
          {timing && <div style={{ marginBottom: 28 }}><RunningNowCard onOpenFocus={onOpenFocus} onEnterStudyMode={() => onEnterStudyMode?.()} /></div>}
          <div className="t-grid">
            <div className="t-col">
              <NextActionCard action={nextAction} onOpen={onOpenCourse} />
              <MoodleNewsCard onOpenCourse={onOpenCourse} />

              <Section title={weekTitle}>
                <WeekTimeCard
                  days={days}
                  weekStart={weekStart}
                  theory={theory}
                  series={series}
                  corrections={corrections}
                  late={late}
                  goal={weeklyGoal}
                  now={now}
                />
              </Section>

              <Section title={`${weekTitle} · cours suivis`}>
                <div className="t-cards">
                  {summaries.map((summary) => (
                    <WeekCourseRow key={summary.course.id} summary={summary} onOpen={onOpenCourse}
                      onOpenLate={(id) => onOpenCourse(id, id)} />
                  ))}
                </div>
              </Section>

              {tasks.length > 0 && (
                <Section title="Tâches">
                  <Card className="t-list">
                    {tasks.map((task) => <TaskRow key={task.id} task={task} />)}
                  </Card>
                </Section>
              )}
            </div>

            <div className="t-col">
              <Section title="Horaire du jour">
                <Card className="t-list">
                  {todayItems.length === 0 ? (
                    <div className="t-empty">Rien à l'horaire.</div>
                  ) : (
                    <>
                      {todayItems.slice(0, 8).map((item) => (
                        <PlanRow key={item.id} item={item} now={now} onOpen={onOpenCourse}
                          onToggle={(event) => { toggleChecked(readCounting(), event, now); void save?.(event); }} />
                      ))}
                      {todayItems.length > 8 && <div className="t-more">+ {todayItems.length - 8} autres</div>}
                    </>
                  )}
                </Card>
              </Section>

              {deadlines.length > 0 && (
                <Section title="Échéances" action={<span className="faint" style={{ fontSize: 11 }}>14 jours</span>}>
                  <Card className="t-list">
                    {deadlines.map((deadline) => (
                      <DeadlineRow key={deadline.id} item={deadline} onOpen={onOpenCourse} />
                    ))}
                  </Card>
                </Section>
              )}

              <Section title="Sessions du jour"
                action={todaySessions.length > 0
                  ? <span className="mono muted" style={{ fontSize: 12 }}>{DateUtils.hoursLabel(sessionsTotal)}</span>
                  : undefined}>
                <Card className="t-list">
                  {todaySessions.length === 0 ? (
                    <div className="t-empty">{timing ? "Session en cours." : "Pas encore de session."}</div>
                  ) : todaySessions.map((session) => <SessionRow key={session.id} session={session} />)}
                </Card>
              </Section>
            </div>
          </div>
        </>
      )}
    </>
  );
}
