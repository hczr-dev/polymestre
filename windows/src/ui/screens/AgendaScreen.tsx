// Agenda — la semaine en colonnes, les échéances du jour et ce qui vient.
//
// Port de MacAgendaView (la grille horaire) avec les apports d'AgendaView :
// sessions planifiées dans la grille, numéro de semaine du semestre, et le seul
// geste de présence autorisé côté Swift — marquer un cours magistral terminé
// « manqué » (`isSkipped.toggle()` puis `save()`).

import { readCounting, toggleChecked } from "../../domain/studyCounting.ts";
import { OpenCourseContext, type OpenCourse } from "./agenda/openCourse.ts";
import { useEffect, useMemo, useState } from "react";
import { useData } from "../../data/dataContext.tsx";
import { Deadline } from "../../domain/deadline.ts";
import { DateUtils } from "../../domain/dateUtils.ts";
import { AcademicTerm, Course, LinkedCalendarEvent, PlannedSession } from "../../models/index.ts";
import { Button, IconButton, PageHeader } from "../kit.tsx";
import "./agenda/agenda.css";
import { UpcomingList } from "./agenda/UpcomingList.tsx";
import { WeekGrid } from "./agenda/WeekGrid.tsx";
import {
  buildWeekEntries, fallbackWeekNumber, visibleWeekDays, weekDays, weekLabel, weekNumberFor,
} from "./agenda/weekModel.ts";

export function AgendaScreen({ onOpenCourse }: { onOpenCourse?: OpenCourse } = {}) {
  const { store, save, version } = useData();
  const [weekOffset, setWeekOffset] = useState(0);
  const [now, setNow] = useState(() => new Date());

  // La ligne « maintenant » et l'état passé/futur des cours suivent l'horloge.
  useEffect(() => {
    const timer = setInterval(() => setNow(new Date()), 60_000);
    return () => clearInterval(timer);
  }, []);

  // ⌘/Ctrl + ← → : le raccourci du Mac pour changer de semaine.
  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (!event.metaKey && !event.ctrlKey) return;
      if (event.key !== "ArrowLeft" && event.key !== "ArrowRight") return;
      event.preventDefault();
      setWeekOffset((offset) => offset + (event.key === "ArrowRight" ? 1 : -1));
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  const tracked = useMemo(
    () => store!.fetch(Course).filter((course) => course.isTracked).sort((a, b) => a.code.localeCompare(b.code)),
    [store, version],
  );
  const allEvents = useMemo(
    () => store!.fetch(LinkedCalendarEvent).slice().sort((a, b) => a.startsAt.getTime() - b.startsAt.getTime()),
    [store, version],
  );
  const plannedSessions = useMemo(
    () => store!.fetch(PlannedSession).slice().sort((a, b) => a.startsAt.getTime() - b.startsAt.getTime()),
    [store, version],
  );

  // Le week-end, la semaine qui vient : celle qui finit n'a plus rien à faire.
  const baseOffset = now.getDay() === 0 || now.getDay() === 6 ? 1 : 0;
  const weekStart = DateUtils.addWeeks(weekOffset + baseOffset, DateUtils.startOfWeek(now));
  const weekEnd = DateUtils.addDays(7, weekStart);
  const term = AcademicTerm.resolve(
    tracked.map((course) => course.term).filter((value): value is AcademicTerm => value !== null),
    now,
  );
  const weekNumber = weekNumberFor(weekStart, term)
    ?? (term === null && tracked.length > 0 ? fallbackWeekNumber(weekStart, now) : null);

  const entries = buildWeekEntries(allEvents, plannedSessions, weekStart, weekEnd);
  const deadlines = Deadline.between(tracked, weekStart, weekEnd);
  const coming = Deadline.upcoming(tracked, 30);
  const days = visibleWeekDays(weekDays(weekStart), entries, deadlines);

  // La coche : « J'y étais » / « manqué », selon ce qui compte (Réglages › Chrono).
  const toggleSkipped = (event: LinkedCalendarEvent) => {
    toggleChecked(readCounting(), event);
    void save(event);
  };

  const weekKicker = weekNumber !== null ? `Semaine ${weekNumber}` : "Hors semestre";

  return (
    <div className="agenda">
      <PageHeader
        title="Agenda"
        subtitle={<><span className="agenda-kicker">{weekKicker}</span> · {weekLabel(weekStart)}</>}
        actions={(
          <>
            <IconButton icon="chevron.left" label="Semaine précédente" bordered
              onClick={() => setWeekOffset((offset) => offset - 1)} />
            <Button disabled={weekOffset === 0} title="Revenir à cette semaine" onClick={() => setWeekOffset(0)}>
              Aujourd'hui
            </Button>
            <IconButton icon="chevron.right" label="Semaine suivante" bordered
              onClick={() => setWeekOffset((offset) => offset + 1)} />
          </>
        )}
      />

      <div style={{ marginBottom: 28 }}>
        <OpenCourseContext.Provider value={onOpenCourse ?? null}>
          <WeekGrid days={days} entries={entries} deadlines={deadlines} now={now} onToggleSkipped={toggleSkipped} />
        </OpenCourseContext.Provider>
      </div>

      <OpenCourseContext.Provider value={onOpenCourse ?? null}>
        <UpcomingList items={coming} />
      </OpenCourseContext.Provider>
    </div>
  );
}
