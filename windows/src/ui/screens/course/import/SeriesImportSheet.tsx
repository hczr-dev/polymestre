// Import d'une série en trois temps : **choisir**, **analyser**, **relire**
// (StudyKit/SeriesImportSheet.swift).
//
// La version précédente affichait la lecture rapide tout de suite, puis la remplaçait
// quand l'IA répondait : la liste changeait sous le doigt, pendant qu'on la corrigeait.
// L'analyse a maintenant son écran, avec ses étapes et un « Continuer sans attendre » ;
// la relecture n'apparaît qu'une fois la lecture choisie, et elle utilise le même
// formulaire que « Modifier la série ».

import { useEffect, useMemo, useRef, useState } from "react";
import { Course } from "../../../../models/course.ts";
import { useData } from "../../../../data/dataContext.tsx";
import { Button, EmptyState, Icon, IconButton, Select, cx } from "../../../kit.tsx";
import { Plural } from "../../../../domain/plural.ts";
import { ExerciseDraft, SeriesDraft, SeriesDraftWriter } from "../../../../domain/seriesDraft.ts";
import { SeriesAIParsing } from "../../../../domain/seriesAIParsing.ts";
import type { DetectedSeries } from "../../../../services/seriesPDFParser.ts";
import { readAIExtraction } from "../../../../native/settings.ts";
import { pickPDFs, type PickedFile } from "../../../../native/files.ts";
import { SeriesAIExtractor, SeriesExtractionSource } from "../../../../services/seriesAIExtractor.ts";
import { SeriesImportFlow, type CourseChoice } from "../../../../services/seriesImportFlow.ts";
import { readPDFs } from "../../../../services/seriesImportReader.ts";
import { SeriesPDFStore } from "../../../../services/seriesPDFStore.ts";
import { AppLog } from "../../../../domain/appLog.ts";
import { SeriesDraftForm } from "./SeriesDraftForm.tsx";
import { SourcePreview, type SourcePreviewTarget } from "./SourcePreview.tsx";
import "./import.css";

type Phase = { name: "source" | "reading" | "analyzing" | "review" | "noText" } | { name: "failed"; message: string };

type AIState =
  | { name: "idle" | "unavailable" | "running" }
  | { name: "applied" | "pending" | "failed"; detail: string };

export function SeriesImportSheet({ course, initialFiles, initialText, onClose }: {
  /** Cours d'où l'import est lancé : `null` depuis l'accueil, le PDF le désigne alors souvent lui-même. */
  course: Course | null;
  initialFiles?: PickedFile[];
  initialText?: string;
  onClose: () => void;
}) {
  const { store, saveMany } = useData();
  const courses = useMemo(() => (store?.fetch(Course) ?? []).filter((c) => c.isTracked)
    .sort((a, b) => a.code.localeCompare(b.code)), [store]);
  const [, bump] = useState(0);
  const touch = () => bump((value) => value + 1);

  const [selectedCourseID, setSelectedCourseID] = useState<string | null>(course?.id ?? null);
  const [courseWasDetected, setCourseWasDetected] = useState(false);
  const [phase, setPhase] = useState<Phase>({ name: "source" });
  const [sourceName, setSourceName] = useState("");
  const [pageCount, setPageCount] = useState(0);
  const [drafts, setDrafts] = useState<SeriesDraft[]>([]);
  const [lastApplied, setLastApplied] = useState("");
  const [localResult, setLocalResult] = useState<DetectedSeries[]>([]);
  const [aiResult, setAIResult] = useState<DetectedSeries[] | null>(null);
  const [preferredSeries, setPreferredSeries] = useState<number | null>(null);
  const [aiInput, setAIInput] = useState("");
  const [language, setLanguage] = useState<string | null>(null);
  const [pageImages, setPageImages] = useState<Uint8Array[]>([]);
  const [ai, setAI] = useState<AIState>({ name: "idle" });
  const [previewing, setPreviewing] = useState<SourcePreviewTarget | null>(null);
  const [pasting, setPasting] = useState(false);
  const [pastedText, setPastedText] = useState("");
  const [saveError, setSaveError] = useState<string | null>(null);
  const [sourceFiles, setSourceFiles] = useState<PickedFile[]>([]);
  const run = useRef(0);
  const abort = useRef<AbortController | null>(null);

  const selectedCourse = courses.find((c) => c.id === selectedCourseID) ?? null;
  const weekContext = selectedCourse
    ? { totalWeeks: selectedCourse.term?.totalWeeks ?? null, currentWeek: selectedCourse.currentWeek, name: selectedCourse.name, code: selectedCourse.code }
    : null;
  const exerciseCount = drafts.reduce((total, draft) => total + draft.exercises.length, 0);
  const hasEdited = SeriesImportFlow.fingerprint(drafts) !== lastApplied;
  const problems = drafts.flatMap((draft) => draft.problems([]));
  const reviewing = phase.name === "review";

  // Une fermeture protège les corrections non importées.
  const close = () => {
    if (reviewing && hasEdited && !window.confirm("Abandonner tes corrections ?")) return;
    abort.current?.abort();
    run.current++;
    onClose();
  };

  useEffect(() => {
    const key = (event: KeyboardEvent) => { if (event.key === "Escape" && !previewing && !pasting) close(); };
    window.addEventListener("keydown", key);
    return () => window.removeEventListener("keydown", key);
  });

  useEffect(() => {
    // `read` / `analyze` ne se lancent qu'une fois, à l'ouverture (`.task`).
    if (initialFiles && initialFiles.length > 0) void read(initialFiles);
    else if (initialText && initialText !== "") analyze(SeriesImportFlow.linesFromText(initialText), null, 0, []);
    return () => { abort.current?.abort(); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // MARK: Lecture

  async function chooseFiles() {
    const files = await pickPDFs(true);
    if (files.length > 0) void read(files);
  }

  /** Lit un ou plusieurs PDF en conservant leur mise en page. */
  async function read(files: PickedFile[]) {
    abort.current?.abort();
    const token = ++run.current;
    setSourceFiles(files);
    setPhase({ name: "reading" });
    setAI({ name: "idle" });
    setSourceName(files.length === 1 ? files[0].name : `${files.length} documents`);
    const result = await readPDFs(files);
    if (token !== run.current) return;
    setPageImages(result.pages);
    setPageCount(result.pages.length);
    if (result.lines.every((line) => line.text.trim() === "")) {
      if (result.unreadable === files.length) {
        setPhase({ name: "failed", message: files.length === 1
          ? "Ce fichier n'a pas pu être ouvert comme PDF."
          : "Aucun de ces fichiers n'a pu être ouvert comme PDF." });
      } else {
        setDrafts([]);
        setPhase({ name: "noText" });
      }
      return;
    }
    analyze(result.lines, files[0]?.name ?? null, result.pages.length, result.pages);
  }

  /** Le pipeline commun : ce que le document dit de lui, motifs tout de suite, IA ensuite, relecture toujours. */
  function analyze(lines: Parameters<typeof SeriesImportFlow.analyzeLines>[0], filename: string | null, pages: number, images: Uint8Array[]) {
    if (!lines.some((line) => line.text.trim() !== "")) {
      setDrafts([]);
      setPhase({ name: "noText" });
      return;
    }
    const candidates: CourseChoice[] = courses.map((c) => ({ id: c.id, code: c.code, name: c.name }));
    const analysis = SeriesImportFlow.analyzeLines(lines, filename, candidates, course === null || selectedCourseID === null);
    setPreferredSeries(analysis.preferredSeries);
    let chosen = selectedCourse;
    if (analysis.detectedCourse) {
      chosen = courses.find((c) => c.id === analysis.detectedCourse) ?? chosen;
      setSelectedCourseID(analysis.detectedCourse);
      setCourseWasDetected(true);
    }
    setLocalResult(analysis.parsed);
    setAIResult(null);
    const context = chosen
      ? { totalWeeks: chosen.term?.totalWeeks ?? null, currentWeek: chosen.currentWeek, name: chosen.name, code: chosen.code } : null;
    let next = SeriesImportFlow.draftsFrom(analysis.parsed, context);
    let applied = SeriesImportFlow.fingerprint(next);
    if (next.length === 0 && analysis.preferredSeries !== null) {
      // Rien de reconnu, mais le numéro est connu : une série vide à remplir.
      next = [new SeriesDraft({ number: analysis.preferredSeries, title: "", plannedWeek: SeriesImportFlow.defaultWeek(analysis.preferredSeries, context), exercises: [] })];
      applied = SeriesImportFlow.fingerprint(next);
    }
    setDrafts(next);
    setLastApplied(applied);
    setLanguage(analysis.language);
    setAIInput(analysis.aiInput);
    if (pages === 0) { setPageImages([]); setPageCount(0); }
    if (readAIExtraction() && SeriesAIExtractor.plannedSource(true) !== null) {
      setPhase({ name: "analyzing" });
      runAI(analysis.aiInput, analysis.parsed, analysis.preferredSeries, analysis.language, images, next, applied);
    } else {
      setAI({ name: "unavailable" });
      setPhase({ name: "review" });
    }
  }

  /** Applique une lecture aux brouillons : ce qui est appliqué en dernier, c'est ce dont on s'écarte en corrigeant. */
  function apply(series: DetectedSeries[]) {
    const next = SeriesImportFlow.draftsFrom(series, weekContext);
    setDrafts(next);
    setLastApplied(SeriesImportFlow.fingerprint(next));
  }

  /** Demande au modèle de lire le document : les exercices sûrs restent, les repères douteux doivent être confirmés. */
  function runAI(input = aiInput, base = localResult, preferred = preferredSeries, lang = language,
    images = pageImages, current = drafts, applied = lastApplied) {
    if (input === "") return;
    abort.current?.abort();
    const controller = new AbortController();
    abort.current = controller;
    const token = ++run.current;
    setAI({ name: "running" });
    const pages = images.length > 0 && images.every((page) => page.length > 0) ? images : [];
    SeriesAIExtractor.extract(input, { pageImages: pages, seriesHint: preferred, language: lang, aiExtractionEnabled: readAIExtraction(), signal: controller.signal })
      .then((result) => {
        if (token !== run.current) return;
        const merged = SeriesAIParsing.merge(base, result.series, preferred, SeriesExtractionSource.readsLayout(result.source));
        setAIResult(merged);
        const detail = SeriesImportFlow.summary(base, merged, result.source);
        const edited = SeriesImportFlow.fingerprint(current) !== applied;
        if (phaseRef.current === "review" && edited) {
          const same = JSON.stringify(merged) === JSON.stringify(base);
          setAI({ name: same ? "applied" : "pending", detail });
        } else {
          apply(merged);
          setAI({ name: "applied", detail });
        }
        setPhase({ name: "review" });
      })
      .catch((error: unknown) => {
        if (token !== run.current) return;
        // La lecture locale reste valable : on la garde, et on dit pourquoi le modèle n'a rien ajouté.
        const message = error instanceof Error ? error.message : String(error);
        setAI({ name: "failed", detail: message });
        setPhase({ name: "review" });
        void AppLog.record("warning", AppLog.Category.ai, "Analyse IA sans résultat", message);
      });
  }
  const phaseRef = useRef(phase.name);
  phaseRef.current = phase.name;

  /** L'IA continue ; son résultat sera proposé, pas imposé. */
  const continueWithoutWaiting = () => setPhase({ name: "review" });

  const cancelAnalysis = () => {
    abort.current?.abort();
    run.current++;
    setAI({ name: "failed", detail: "Analyse arrêtée." });
    setPhase({ name: "review" });
  };

  // MARK: Création

  async function create() {
    if (!selectedCourse || !store) return;
    try {
      const filled = drafts.filter((draft) => draft.exercises.length > 0);
      const touched: object[] = [];
      for (const draft of filled) {
        const written = SeriesDraftWriter.write(draft, selectedCourse, "importMerge", store);
        touched.push(written.series, ...written.series.exercises);
        // Le PDF d'une seule série est gardé : le chrono et la fiche en montrent l'énoncé exercice par exercice.
        if (filled.length === 1 && sourceFiles.length === 1) await SeriesPDFStore.keep(sourceFiles[0].bytes, written.series.id);
      }
      await saveMany(touched);
      onClose();
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      void AppLog.record("error", AppLog.Category.storage, "Import de série non enregistré", message);
      setSaveError(`L'enregistrement a échoué : ${message}`);
    }
  }

  const title = phase.name === "review" ? "Vérifier l'import"
    : phase.name === "reading" || phase.name === "analyzing" ? "Analyse" : "Importer une série";

  const addSeries = () => {
    const next = (drafts.length > 0 ? Math.max(...drafts.map((d) => d.number)) : (preferredSeries !== null ? preferredSeries - 1 : 0)) + 1;
    const draft = new SeriesDraft({ number: next, title: "", plannedWeek: SeriesImportFlow.defaultWeek(next, weekContext), exercises: [] });
    draft.addExercise();
    setDrafts([...drafts, draft]);
  };

  const manualSeries = () => {
    const number = preferredSeries ?? 1;
    const draft = new SeriesDraft({ number, title: "", plannedWeek: SeriesImportFlow.defaultWeek(number, weekContext), exercises: [] });
    draft.addExercise();
    setDrafts([draft]);
    setLastApplied("");
    setPhase({ name: "review" });
  };

  const showSource = (draft: SeriesDraft) => (exercise: ExerciseDraft) => {
    const page = exercise.pageIndex;
    if (page === undefined || page >= pageImages.length || pageImages[page].length === 0) return;
    setPreviewing({ title: `Exercice ${draft.number}.${exercise.minor}`, page, top: exercise.top, bottom: exercise.bottom });
  };

  return (
    <div className="overlay imp-overlay" onMouseDown={(event) => { if (event.target === event.currentTarget) close(); }}>
      <div className="dialog imp-dialog" role="dialog" aria-modal="true" aria-label={title}>
        <div className="cs-dialog-head">
          <h2 className="serif">{title}</h2>
          <IconButton icon="xmark" label="Annuler" onClick={close} />
        </div>

        <div className="imp-body">
          {phase.name === "source" && (
            <div className="imp-source">
              <button type="button" className="imp-choice" onClick={() => void chooseFiles()}>
                <Icon name="doc.badge.plus" size={22} />
                <span><strong>Choisir un PDF</strong><small>Une série ou plusieurs à la fois, depuis tes fichiers.</small></span>
                <Icon name="chevron.right" size={14} />
              </button>
              <button type="button" className="imp-choice" onClick={() => { setPastedText(""); setPasting(true); }}>
                <Icon name="doc.on.clipboard" size={22} />
                <span><strong>Coller l'énoncé</strong><small>Depuis Moodle, un mail ou une page web.</small></span>
                <Icon name="chevron.right" size={14} />
              </button>
              {course && <p className="imp-foot">Cours : {course.displayCode} · {course.name}</p>}
            </div>
          )}

          {(phase.name === "reading" || phase.name === "analyzing") && (
            <div className="imp-steps">
              <Step done={phase.name === "analyzing"} running={phase.name === "reading"} title="Lecture du document"
                detail={phase.name === "reading" ? sourceName
                  : `${sourceName}${pageCount > 0 ? ` · ${Plural.count(pageCount, `${pageCount} page`, `${pageCount} pages`)}` : ""} · ${SeriesImportFlow.localSummary(localResult)}`} />
              {phase.name === "analyzing" && (
                <Step done={false} running title={pageImages.length === 0 ? "Vérification par l'IA" : "Lecture des pages par l'IA"}
                  detail={pageImages.length === 0 ? "Structure, intitulés et bonus." : "Environ 5 à 20 s."} />
              )}
              {phase.name === "analyzing" && (
                <div className="imp-actions">
                  <Button icon="forward.fill" onClick={continueWithoutWaiting}>Continuer sans attendre</Button>
                  <Button variant="danger" icon="stop.fill" onClick={cancelAnalysis}>Arrêter l'IA</Button>
                </div>
              )}
            </div>
          )}

          {phase.name === "review" && (
            <div className="imp-review">
              <section className="imp-block">
                <label className="imp-field"><span>Cours</span>
                  <Select ariaLabel="Cours" value={selectedCourseID ?? ""}
                    options={[...(selectedCourseID === null ? [{ value: "", label: "Choisir…" }] : []),
                      ...courses.map((c) => ({ value: c.id, label: `${c.displayCode} · ${c.name}` }))]}
                    onChange={(value) => { setSelectedCourseID(value === "" ? null : value); setCourseWasDetected(false); }} />
                </label>
                <AnalysisStatus ai={ai} onRetry={() => runAI()} onStop={cancelAnalysis}
                  onRevert={() => { apply(localResult); setAI({ name: "idle" }); }}
                  onUseAI={() => { if (aiResult) apply(aiResult); if (ai.name === "pending") setAI({ name: "applied", detail: ai.detail }); }} />
                {selectedCourse === null ? <p className="imp-warn">Choisis le cours auquel ajouter cette série.</p>
                  : courseWasDetected ? <p className="imp-foot">Cours reconnu dans le document.</p> : null}
              </section>
              {drafts.map((draft) => (
                <SeriesDraftForm key={draft.id} draft={draft} maxWeek={selectedCourse?.term?.totalWeeks ?? 14}
                  mergesInto={(() => {
                    const same = selectedCourse?.seriesWith(draft.number, draft.label) ?? null;
                    return same ? { seriesNumber: same.seriesNumber, exerciseCount: same.exercises.length } : null;
                  })()}
                  onChange={touch} showSource={pageImages.length === 0 ? undefined : showSource(draft)} />
              ))}
              <div className="imp-actions">
                <Button icon="plus.rectangle.on.rectangle" onClick={addSeries}>
                  {drafts.length === 0 ? "Ajouter une série à la main" : "Ajouter une autre série"}
                </Button>
              </div>
              {saveError && <p className="imp-warn">{saveError}</p>}
            </div>
          )}

          {phase.name === "noText" && (
            <div className="imp-source">
              <EmptyState icon="doc.text.magnifyingglass" title="Aucun texte lisible">
                Document scanné : crée la série à la main, avec le plan « 1(a-d) 2 3 ».
              </EmptyState>
              <div className="imp-actions center">
                <Button icon="plus.rectangle.on.rectangle" onClick={manualSeries}>Créer la série à la main</Button>
                <Button onClick={() => void chooseFiles()}>Choisir un autre fichier</Button>
              </div>
            </div>
          )}

          {phase.name === "failed" && (
            <div className="imp-source">
              <p className="imp-warn"><Icon name="exclamationmark.triangle.fill" size={14} /> {phase.message}</p>
              <div className="imp-actions"><Button onClick={() => void chooseFiles()}>Choisir un autre fichier</Button></div>
            </div>
          )}
        </div>

        <div className="cs-dialog-foot">
          <span className="spacer" />
          <Button onClick={close}>Annuler</Button>
          {phase.name === "review" && (
            <Button variant="primary" disabled={exerciseCount === 0 || selectedCourse === null || problems.length > 0}
              onClick={() => void create()}>
              {exerciseCount > 0 ? `Importer (${exerciseCount})` : "Importer"}
            </Button>
          )}
        </div>
      </div>

      {pasting && (
        <div className="overlay imp-preview-overlay" onMouseDown={(event) => { if (event.target === event.currentTarget) setPasting(false); }}>
          <div className="dialog imp-paste" role="dialog" aria-modal="true" aria-label="Coller un énoncé">
            <div className="cs-dialog-head">
              <h2 className="serif">Coller un énoncé</h2>
              <IconButton icon="xmark" label="Fermer" onClick={() => setPasting(false)} />
            </div>
            <div className="cs-dialog-body">
              <textarea className="field mono" autoFocus rows={10} value={pastedText} spellCheck={false}
                onChange={(e) => setPastedText(e.target.value)} />
              <p className="imp-foot">Colle l'énoncé tel quel.</p>
            </div>
            <div className="cs-dialog-foot">
              <span className="spacer" />
              <Button onClick={() => setPasting(false)}>Annuler</Button>
              <Button variant="primary" disabled={pastedText.trim() === ""} onClick={() => {
                setPasting(false);
                setSourceName("Texte collé");
                setSourceFiles([]);
                setPageImages([]);
                analyze(SeriesImportFlow.linesFromText(pastedText), null, 0, []);
              }}>Analyser</Button>
            </div>
          </div>
        </div>
      )}
      {previewing && <SourcePreview preview={previewing} pages={pageImages} onClose={() => setPreviewing(null)} />}
    </div>
  );
}

function Step({ done, running, title, detail }: { done: boolean; running: boolean; title: string; detail: string }) {
  return (
    <div className="imp-step">
      <span className="imp-step-mark">
        {running ? <span className="imp-spinner" role="progressbar" aria-label="En cours" />
          : <Icon name={done ? "checkmark.circle.fill" : "circle"} size={18} />}
      </span>
      <span><strong>{title}</strong><small>{detail}</small></span>
    </div>
  );
}

/** Qui a lu le document, en une ligne — et ce qu'on peut y faire. */
function AnalysisStatus({ ai, onRetry, onStop, onRevert, onUseAI }: {
  ai: AIState; onRetry: () => void; onStop: () => void; onRevert: () => void; onUseAI: () => void;
}) {
  const row = (icon: Parameters<typeof Icon>[0]["name"], tone: string, title: string, detail: string) => (
    <div className={cx("imp-status", tone)}>
      <Icon name={icon} size={16} />
      <span><strong>{title}</strong>{detail !== "" && <small>{detail}</small>}</span>
    </div>
  );
  switch (ai.name) {
    case "idle":
    case "unavailable":
      return row("text.magnifyingglass", "", "Lecture rapide",
        ai.name === "unavailable" ? "IA désactivée (Réglages › IA de lecture). Vérifie les questions." : "");
    case "running":
      return (
        <div className="imp-status">
          <span className="imp-spinner" role="progressbar" aria-label="En cours" />
          <span><strong>L'IA lit encore les pages…</strong></span>
          <span className="spacer" />
          <Button size="sm" variant="ghost" onClick={onStop}>Arrêter</Button>
        </div>
      );
    case "applied":
      return (<>{row("checkmark.seal.fill", "ok", "Lu par l'IA", ai.detail)}
        <Button size="sm" variant="ghost" onClick={onRevert}>Revenir à la lecture rapide</Button></>);
    case "pending":
      return (<>{row("sparkles", "ai", "L'IA propose une autre lecture", ai.detail)}
        <Button size="sm" onClick={onUseAI}>Utiliser la lecture de l'IA (remplace tes corrections)</Button></>);
    case "failed":
      return (<>{row("exclamationmark.triangle.fill", "warn", "Lecture rapide — l'IA n'a pas abouti", ai.detail)}
        <Button size="sm" variant="ghost" onClick={onRetry}>Réessayer l'IA</Button></>);
  }
}
