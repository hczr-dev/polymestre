// Le formulaire d'une série en brouillon (StudyKit/SeriesEditing.swift › SeriesDraftForm,
// ExerciseDraftSummary, ExerciseDraftEditor).
//
// Sert à relire un import : mêmes gestes que sur le Mac — ouvrir un exercice pour le
// corriger, le marquer bonus, le supprimer, le déplacer. Le glisser du tactile devient
// des boutons ; les brouillons sont mutés sur place puis `onChange` relance l'affichage.

import { useState } from "react";
import type { SeriesKey } from "../../../../domain/seriesIdentity.ts";
import { Button, Icon, IconButton, Stepper, Switch, cx, useContextMenu } from "../../../kit.tsx";
import { ExerciseDraft, SeriesDraft, SubQuestionTree } from "../../../../domain/seriesDraft.ts";
import { DetectedSubQuestion } from "../../../../services/seriesPDFParser.ts";
import { Plural } from "../../../../domain/plural.ts";
import { MathText } from "../common.tsx";

const pad = (value: number) => String(value).padStart(2, "0");
function toDateTimeInput(date: Date): string {
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}T${pad(date.getHours())}:${pad(date.getMinutes())}`;
}

const cases = (n: number) => Plural.count(n, `${n} case`, `${n} cases`);

export function SeriesDraftForm({ draft, taken, maxWeek, mergesInto, onChange, showSource }: {
  draft: SeriesDraft;
  /** Numéros et étiquettes des autres séries du cours. */
  taken?: readonly SeriesKey[];
  maxWeek: number;
  /** Série du même numéro déjà présente (import seulement). */
  mergesInto: { seriesNumber: number; exerciseCount: number } | null;
  onChange: () => void;
  /** Ouvre l'aperçu d'un exercice dans le PDF importé. */
  showSource?: (exercise: ExerciseDraft) => void;
}) {
  const [open, setOpen] = useState<string | null>(null);
  const menu = useContextMenu();
  const problems = draft.problems(taken ?? []);
  const mutate = (change: () => void) => { change(); onChange(); };
  const add = (count: number) => mutate(() => { for (let i = 0; i < count; i++) draft.addExercise(); });

  const addMenu = (event: React.MouseEvent<HTMLButtonElement>) => {
    const rect = event.currentTarget.getBoundingClientRect();
    menu.openAt(rect.left, rect.bottom + 4, [
      { label: "1 exercice", action: () => add(1) },
      { label: "3 exercices", action: () => add(3) },
      { label: "5 exercices", action: () => add(5) },
      { label: "10 exercices", action: () => add(10) },
      ...(draft.exercises.length > 1 ? [
        "divider" as const,
        { label: `Renuméroter ${draft.number}.1, ${draft.number}.2…`, icon: "list.number" as const,
          action: () => mutate(() => draft.renumberExercises()) },
      ] : []),
    ]);
  };

  const move = (index: number, delta: number) => mutate(() => {
    const target = index + delta;
    if (target < 0 || target >= draft.exercises.length) return;
    const [item] = draft.exercises.splice(index, 1);
    draft.exercises.splice(target, 0, item);
  });

  return (
    <section className="imp-block">
      <div className="imp-grid">
        <label className="imp-field"><span>Série</span>
          <Stepper label="la série" value={draft.number} min={1} max={60} onChange={(value) => mutate(() => { draft.number = value; })} />
        </label>
        <label className="imp-field"><span>Semaine prévue</span>
          <Stepper label="la semaine prévue" value={draft.plannedWeek} min={1} max={Math.max(maxWeek, draft.plannedWeek)}
            onChange={(value) => mutate(() => { draft.plannedWeek = value; })} />
        </label>
        <label className="imp-field"><span>Étiquette (facultatif)</span>
          {/* Deux séries la même semaine : « a » et « b », « mardi » et « jeudi ». */}
          <input className="field" value={draft.label} placeholder="b, jeudi…"
            onChange={(e) => mutate(() => { draft.label = e.target.value; })} />
        </label>
        <label className="imp-field imp-wide"><span>Titre (facultatif)</span>
          <input className="field" value={draft.title} onChange={(e) => mutate(() => { draft.title = e.target.value; })} />
        </label>
        <div className="imp-field imp-wide">
          <Switch checked={draft.dueDate !== null} label="À rendre"
            onChange={(on) => mutate(() => {
              draft.dueDate = on ? (draft.dueDate ?? new Date(Date.now() + 7 * 86_400_000)) : null;
            })} />
          {draft.dueDate && (
            <input className="field" type="datetime-local" aria-label="Échéance" value={toDateTimeInput(draft.dueDate)}
              onChange={(e) => mutate(() => { const d = new Date(e.target.value); if (!Number.isNaN(d.getTime())) draft.dueDate = d; })} />
          )}
        </div>
      </div>
      {mergesInto && (
        <p className="imp-foot">
          {`La série ${mergesInto.seriesNumber} existe déjà (${mergesInto.exerciseCount} exercices) : les exercices de même numéro sont mis à jour, les autres ajoutés. Tes coches sont conservées.`}
        </p>
      )}

      <div className="imp-subhead">
        <span>Exercices</span>
        <span className="mono">{draft.exercises.length} · {cases(draft.leafCount)}</span>
      </div>
      <div className="imp-exercises">
        {draft.exercises.map((exercise, index) => (
          <div key={exercise.id} className="imp-ex">
            <div className="imp-ex-row">
              <button type="button" className="imp-ex-main" aria-expanded={open === exercise.id}
                onClick={() => setOpen(open === exercise.id ? null : exercise.id)}>
                <Icon name={open === exercise.id ? "chevron.down" : "chevron.right"} size={13} />
                <ExerciseSummary exercise={exercise} seriesNumber={draft.number}
                  canShowSource={showSource !== undefined && exercise.pageIndex !== undefined} />
              </button>
              <IconButton size="sm" icon="chevron.up" label="Monter" disabled={index === 0} onClick={() => move(index, -1)} />
              <IconButton size="sm" icon="chevron.down" label="Descendre" disabled={index === draft.exercises.length - 1} onClick={() => move(index, 1)} />
              <IconButton size="sm" icon={exercise.isBonus ? "star.slash" : "star"} label={exercise.isBonus ? "Obligatoire" : "Bonus"}
                onClick={() => mutate(() => { exercise.isBonus = !exercise.isBonus; })} />
              <IconButton size="sm" icon="trash" label="Supprimer"
                onClick={() => mutate(() => { draft.exercises.splice(index, 1); })} />
            </div>
            {open === exercise.id && (
              <ExerciseEditor exercise={exercise} seriesNumber={draft.number} onChange={onChange}
                showSource={showSource ? () => showSource(exercise) : undefined} />
            )}
          </div>
        ))}
      </div>
      <div className="imp-actions">
        <Button size="sm" icon="plus.circle.fill" trailingIcon="chevron.down" onClick={addMenu} aria-haspopup="menu">
          Ajouter des exercices
        </Button>
      </div>
      {problems.length > 0 ? (
        <p className="imp-warn"><Icon name="exclamationmark.triangle.fill" size={14} /> {problems.join(" ")}</p>
      ) : draft.exercises.length === 0 ? <p className="imp-foot">Aucun exercice.</p> : null}
    </section>
  );
}

/** Une ligne d'exercice en brouillon : numéro, intitulé, structure des questions. */
function ExerciseSummary({ exercise, seriesNumber, canShowSource }: { exercise: ExerciseDraft; seriesNumber: number; canShowSource: boolean }) {
  return (
    <span className="imp-sum">
      <span className={cx("imp-num mono", exercise.minor === "" && "warn")}>{seriesNumber}.{exercise.minor === "" ? "?" : exercise.minor}</span>
      <span className="imp-sum-text">
        <span className="imp-sum-title">
          <span className={exercise.title === "" ? "faint" : undefined}>
            {exercise.title === "" ? "Sans titre" : <MathText text={exercise.title} />}
          </span>
          {exercise.isBonus && <Icon name="star.fill" size={12} />}
          {exercise.isDone && <Icon name="checkmark.circle.fill" size={12} />}
        </span>
        {exercise.statement !== "" && <span className="imp-sum-statement"><MathText text={exercise.statement} /></span>}
        <span className="imp-sum-outline faint">
          {exercise.subQuestions.length === 0
            ? "Un bloc, sans sous-question"
            : `${cases(exercise.leafCount)} · ${SubQuestionTree.outline(exercise.subQuestions)}`}
        </span>
      </span>
      {canShowSource && <Icon name="doc.viewfinder" size={14} />}
    </span>
  );
}

/**
 * Un exercice, en entier : identité, plan, questions. Les questions s'éditent à
 * plat — une ligne par question ou point —, et la structure se change par des
 * gestes ; le plan en une ligne (« 1(a-d) 2(a-e) + ») reconstruit tout l'arbre.
 */
function ExerciseEditor({ exercise, seriesNumber, onChange, showSource }: {
  exercise: ExerciseDraft; seriesNumber: number; onChange: () => void; showSource?: () => void;
}) {
  const [outline, setOutline] = useState(() => SubQuestionTree.outline(exercise.subQuestions));
  const [outlineError, setOutlineError] = useState(false);
  const [focused, setFocused] = useState(false);
  const mutate = (change: () => void) => {
    change();
    if (!focused) setOutline(SubQuestionTree.outline(exercise.subQuestions));
    onChange();
  };
  const apply = () => {
    const parsed = SubQuestionTree.parse(outline, exercise.subQuestions);
    if (!parsed) { setOutlineError(true); return; }
    setOutlineError(false);
    exercise.subQuestions = parsed;
    setOutline(SubQuestionTree.outline(parsed));
    onChange();
  };
  const rows = SubQuestionTree.rows(exercise.subQuestions);

  return (
    <div className="imp-editor">
      <div className="imp-grid">
        <label className="imp-field"><span>Numéro</span>
          <span className="imp-number mono">{seriesNumber}.
            <input className="field" value={exercise.minor} placeholder="n°" aria-label="Numéro de l'exercice"
              onChange={(e) => mutate(() => { exercise.minor = e.target.value; })} />
          </span>
        </label>
        <label className="imp-field"><span>Intitulé (facultatif)</span>
          <input className="field" value={exercise.title} onChange={(e) => mutate(() => { exercise.title = e.target.value; })} />
        </label>
        <label className="imp-field imp-wide"><span>Énoncé : ce qu'il faut faire</span>
          <textarea className="field" rows={2} value={exercise.statement}
            onChange={(e) => mutate(() => { exercise.statement = e.target.value; })} />
        </label>
        <div className="imp-field imp-wide imp-inline">
          <Switch checked={exercise.isBonus} label="Bonus" onChange={(value) => mutate(() => { exercise.isBonus = value; })} />
          {showSource && <Button size="sm" icon="doc.viewfinder" onClick={showSource}>Voir dans le PDF</Button>}
        </div>
      </div>

      <label className="imp-field"><span>Plan rapide</span>
        <span className="imp-outline">
          <input className="field mono" value={outline} placeholder="1(a-d) 2(a-e) 3 +" spellCheck={false} autoCapitalize="off"
            onFocus={() => setFocused(true)} onBlur={() => setFocused(false)}
            onChange={(e) => setOutline(e.target.value)}
            onKeyDown={(e) => { if (e.key === "Enter") { e.preventDefault(); apply(); } }} />
          <Button size="sm" onClick={apply}>Appliquer</Button>
        </span>
      </label>
      <p className={outlineError ? "imp-warn" : "imp-foot"}>
        {outlineError
          ? "Plan illisible. Exemples : « 1-4 », « 1(a-c) 2 3(a,b) », « + » pour une partie sans numéro."
          : "Comme sur la feuille : « 1(a-d) 2 3(a,b) »."}
      </p>

      <div className="imp-subhead">
        <span>Questions</span>
        {exercise.subQuestions.length > 0 && <span className="mono">{cases(exercise.leafCount)}</span>}
      </div>
      {rows.map((row) => (
        <div key={row.id} className={cx("imp-q", row.depth === 1 && "child")}>
          {row.question.kind === "part" ? (
            <span className="imp-q-part" title="Partie sans numéro"><Icon name="text.alignleft" size={14} /></span>
          ) : (
            <input className="field imp-q-label mono" value={row.question.label} placeholder="n°"
              aria-label={row.depth === 0 ? "Étiquette de la question" : "Étiquette du point"}
              onChange={(e) => mutate(() => SubQuestionTree.update(row.id, exercise.subQuestions, (q) => { q.label = e.target.value; }))} />
          )}
          <input className="field imp-q-text" value={row.question.text}
            placeholder={row.question.kind === "part" ? "Consigne (ex. Ensuite, représenter…)" : "Énoncé (facultatif)"}
            onChange={(e) => mutate(() => SubQuestionTree.update(row.id, exercise.subQuestions, (q) => { q.text = e.target.value; }))} />
          {row.depth === 0 && row.question.kind === "question" && (
            <IconButton size="sm" icon="plus" label="Ajouter un point"
              onClick={() => mutate(() => SubQuestionTree.addChild(row.id, exercise.subQuestions))} />
          )}
          {row.canIndent && (
            <IconButton size="sm" icon="increase.indent" label="Point de la question précédente"
              onClick={() => mutate(() => SubQuestionTree.indent(row.id, exercise.subQuestions))} />
          )}
          {row.canOutdent && (
            <IconButton size="sm" icon="decrease.indent" label="Remonter en question"
              onClick={() => mutate(() => SubQuestionTree.outdent(row.id, exercise.subQuestions))} />
          )}
          <IconButton size="sm" icon="trash" label="Supprimer"
            onClick={() => mutate(() => SubQuestionTree.remove(row.id, exercise.subQuestions))} />
        </div>
      ))}
      <div className="imp-actions">
        <Button size="sm" icon="plus.circle.fill" onClick={() => mutate(() => SubQuestionTree.addQuestion(exercise.subQuestions))}>Question</Button>
        <Button size="sm" icon="text.badge.plus"
          onClick={() => mutate(() => { exercise.subQuestions.push(DetectedSubQuestion.make("", { kind: "part" })); })}>Partie</Button>
        {exercise.subQuestions.length > 1 && (
          <IconButton size="sm" icon="list.number" label="Renuméroter 1, 2, 3 et a, b, c"
            onClick={() => mutate(() => SubQuestionTree.relabel(exercise.subQuestions))} />
        )}
      </div>
      {exercise.subQuestions.length === 0 && <p className="imp-foot">Sans sous-question, l'exercice se coche d'un bloc.</p>}
    </div>
  );
}
