// « À rattraper » (StudyKit/LateWorkView.swift) : ce que le « N en retard » d'un
// cours recouvre, rangé par ce qu'il y a à faire, dans l'ordre où le reprendre.
//
// Un seul calcul (`lateWork`) donne le nombre et la liste. Rien n'est tronqué.
// Aucune correction ne se coche en masse : une couleur se constate en comparant
// au corrigé, elle ne s'invente pas.

import { useState } from "react";
import type { Course } from "../../../models/course.ts";
import type { Exercise } from "../../../models/exercise.ts";
import type { TheoryItem } from "../../../models/theoryItem.ts";
import { lateSummary, lateWork, type LateSeriesGroup } from "../../../domain/lateWork.ts";
import { Button, Card, Icon, Section } from "../../kit.tsx";
import { CheckCircle, openURL, theoryDetail } from "./common.tsx";
import "./course.css";

interface Undo { exercises: string[]; theory: string[]; label: string }

export function LateTab({ course, saveAll, onOpen }: {
  course: Course;
  saveAll: (objects: object[]) => Promise<void>;
  /** Montrer l'exercice ou la théorie dans son volet. */
  onOpen: (id: string, kind: "exercise" | "theory") => void;
}) {
  const [undo, setUndo] = useState<Undo | null>(null);
  const late = lateWork(course);

  const markDone = async (exercises: Exercise[], label: string) => {
    const changed = exercises.filter((e) => !e.isDone);
    if (changed.length === 0) return;
    changed.forEach((e) => e.setDone(true));
    await saveAll(changed.flatMap((e) => [e, ...e.subQuestions]));
    setUndo({ exercises: changed.map((e) => e.id), theory: [], label });
  };
  const markWatched = async (items: TheoryItem[], label: string) => {
    const changed = items.filter((t) => !t.isWatched);
    if (changed.length === 0) return;
    const now = new Date();
    changed.forEach((t) => { t.watchedAt = now; });
    await saveAll(changed);
    setUndo({ exercises: [], theory: changed.map((t) => t.id), label });
  };
  const revert = async (change: Undo) => {
    const exercises = course.allExercises.filter((e) => change.exercises.includes(e.id));
    const theory = course.theoryItems.filter((t) => change.theory.includes(t.id));
    exercises.forEach((e) => e.setDone(false));
    theory.forEach((t) => { t.watchedAt = null; });
    await saveAll([...exercises.flatMap((e) => [e, ...e.subQuestions]), ...theory]);
    setUndo(null);
  };

  const seriesOf = (e: Exercise) => e.series ? `${e.series.displayName} · semaine ${e.series.plannedWeek}` : "";
  const title = (e: Exercise) => e.displayNumber + (e.title === "" ? "" : ` · ${e.title}`);
  const summary = lateSummary(late);

  return (
    <div className="cs-col">
      <Card className="cs-where" flat>
        <div className="caps" style={{ marginBottom: 6 }}>{`${course.displayCode}${late.currentWeek > 0 ? ` · semaine ${late.currentWeek}` : ""}`}</div>
        <div className="big">
          <Icon name={late.total > 0 ? "exclamationmark.triangle" : "checkmark.circle"} size={20}
            color={late.total > 0 ? "var(--wrong)" : "var(--correct)"} />
          <span className="serif">{late.total > 0 ? `${late.total} à rattraper` : "Rien à rattraper"}</span>
        </div>
        <p className="muted" style={{ margin: "5px 0 0", fontSize: 13 }}>
          {late.total > 0 ? summary.charAt(0).toUpperCase() + summary.slice(1) + "."
            : late.currentWeek > 1 ? `Tout ce qui était prévu avant la semaine ${late.currentWeek} est vu, fait et corrigé, et rien n'est à refaire.`
            : "Le semestre commence : rien ne peut encore être en retard, sauf un exercice à refaire."}
        </p>
      </Card>

      {late.redo.length > 0 && (
        <Group title="À refaire" count={late.redo.length}
          why="Corrigés faux. Reprends-les sans regarder la solution, tant que l'erreur est fraîche.">
          {late.redo.map((e) => (
            <Row key={e.id} mark={<Icon name="arrow.counterclockwise" size={16} color="var(--wrong)" />}
              title={title(e)} detail={seriesOf(e)} onOpen={() => onOpen(e.id, "exercise")} />
          ))}
        </Group>
      )}

      {late.toCorrect.length > 0 && (
        <Group title="À corriger" count={late.toCorrect.length}
          why="Faits, et le corrigé est publié. Compare ta copie au corrigé et donne la couleur : juste, moyen ou faux.">
          {late.toCorrect.map((e) => (
            <Row key={e.id} mark={<Icon name="checkmark.seal" size={16} color="var(--review)" />}
              title={title(e)} detail={seriesOf(e)} onOpen={() => onOpen(e.id, "exercise")}
              trailing={e.series && e.series.solutionURLString !== ""
                ? <Button size="sm" variant="ghost" onClick={(ev) => { ev.stopPropagation(); openURL(e.series!.solutionURLString); }}>Corrigé</Button>
                : undefined} />
          ))}
        </Group>
      )}

      {late.series.length > 0 && (
        <Group title={late.exerciseCount === 1 ? "Exercice à faire" : "Exercices à faire"} count={late.exerciseCount}
          why="Prévus les semaines passées, pas encore faits. Déjà faits sur papier ? Coche-les : ils passeront « à corriger ».">
          {late.series.map((group) => (
            <SeriesBlock key={group.series.id} group={group}
              onAll={() => void markDone(group.exercises, group.series.displayName)}>
              {group.exercises.map((e) => (
                <Row key={e.id}
                  mark={<CheckCircle isOn={e.isDone} tint="var(--course)" label={`Marquer ${e.displayNumber} fait`}
                    onToggle={() => void markDone([e], e.displayNumber)} size={20} />}
                  title={title(e)} detail={e.statement} onOpen={() => onOpen(e.id, "exercise")} />
              ))}
            </SeriesBlock>
          ))}
        </Group>
      )}

      {late.theory.length > 0 && (
        <Group title="Théorie à voir" count={late.theoryCount} why="Vidéos, transparents, sections du polycopié des semaines passées.">
          {late.theory.map((group) => (
            <div key={group.week} className="cs-late-block">
              <div className="cs-late-head">
                <b>Semaine {group.week}</b>
                <span className="spacer" />
                {group.items.length > 1 && (
                  <Button size="sm" variant="ghost" onClick={() => void markWatched(group.items, `semaine ${group.week}`)}>Tout marquer vu</Button>
                )}
              </div>
              {group.items.map((t) => (
                <Row key={t.id}
                  mark={<CheckCircle isOn={t.isWatched} tint="var(--course)" label={`Marquer ${t.title} vu`}
                    onToggle={() => void markWatched([t], t.title === "" ? t.number : t.title)} size={20} />}
                  title={t.title === "" ? t.number : t.title} detail={theoryDetail(t)} onOpen={() => onOpen(t.id, "theory")} />
              ))}
            </div>
          ))}
        </Group>
      )}

      {late.total > 0 && (
        <p className="muted small" style={{ margin: 0 }}>
          Compté dans le retard : ce qui était prévu avant la semaine {late.currentWeek} et n'est pas fait ou pas vu, les exercices
          faits dont le corrigé est publié mais pas encore corrigés, et les exercices à refaire. La semaine en cours n'y entre pas,
          les bonus non plus.
        </p>
      )}

      {undo && (
        <div className="cs-undo">
          <span>Coché : {undo.label}.</span>
          <span className="spacer" />
          <Button size="sm" variant="ghost" icon="arrow.counterclockwise" onClick={() => void revert(undo)}>Annuler</Button>
        </div>
      )}
    </div>
  );
}

function Group({ title, count, why, children }: { title: string; count: number; why: string; children: React.ReactNode }) {
  return (
    <Section title={title} style={{ marginBottom: 0 }} action={<span className="mono muted small">{count}</span>}>
      <p className="muted small" style={{ margin: "0 0 8px" }}>{why}</p>
      <Card className="cs-list" flat>{children}</Card>
    </Section>
  );
}

function SeriesBlock({ group, onAll, children }: { group: LateSeriesGroup; onAll: () => void; children: React.ReactNode }) {
  const s = group.series;
  const name = s.title === "" || s.title === s.displayName ? s.displayName : `${s.displayName} · ${s.title}`;
  return (
    <div className="cs-late-block">
      <div className="cs-late-head">
        <span>
          <b>{name}</b>
          <span className="muted small"> · semaine {s.plannedWeek} · {group.exercises.length} sur {group.requiredCount} à faire</span>
        </span>
        <span className="spacer" />
        {group.exercises.length > 1 && <Button size="sm" variant="ghost" onClick={onAll}>Tout marquer fait</Button>}
      </div>
      {children}
    </div>
  );
}

function Row({ mark, title, detail, onOpen, trailing }: {
  mark: React.ReactNode; title: string; detail: string; onOpen: () => void; trailing?: React.ReactNode;
}) {
  return (
    <div className="cs-late cs-late-open" role="button" tabIndex={0} onClick={onOpen}
      onKeyDown={(event) => { if (event.key === "Enter") onOpen(); }}>
      <span className="cs-late-mark">{mark}</span>
      <div className="grow">
        <div className="t">{title}</div>
        {detail !== "" && <div className="d">{detail}</div>}
      </div>
      {trailing}
      <Icon name="chevron.right" size={12} color="var(--ink-tertiary)" />
    </div>
  );
}
