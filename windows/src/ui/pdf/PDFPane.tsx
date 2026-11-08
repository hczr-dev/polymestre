// Un PDF dans l'app (StudyKit/PDFPane.swift et PDFExerciseCrop.swift › ExercisePDFView).
//
// Lecteur à défilement continu : les pages se rendent quand elles approchent de
// l'écran (rien ne tourne au repos). Un exercice peut être montré : ouvert à sa
// place, sa zone surlignée — ou, comme l'énoncé du chrono, réduit à sa seule bande.
// Rendu par pdf.js ; la mémoire de la page lue (`ReadingMemory`) relève de la
// lecture de contenu et n'est pas portée ici.

import { useEffect, useRef, useState } from "react";
import { Button } from "../kit.tsx";
import { openPDF, renderBand, type OpenPDF } from "../../services/pdfPages.ts";
import { linesFromData } from "../../services/pdfLayoutExtractor.ts";
import { PDFExerciseCrop, type CropExercise, type CropRegion } from "../../services/pdfExerciseCrop.ts";
import type { PDFLayoutLine } from "../../domain/seriesLayout.ts";
import "./pdf.css";

/** Ouvre un PDF le temps de la vue. */
function useOpenPDF(bytes: Uint8Array): { pdf: OpenPDF | null; error: boolean } {
  const [state, setState] = useState<{ pdf: OpenPDF | null; error: boolean }>({ pdf: null, error: false });
  useEffect(() => {
    let alive = true;
    let opened: OpenPDF | null = null;
    setState({ pdf: null, error: false });
    openPDF(bytes).then((pdf) => {
      if (!alive) { pdf.destroy(); return; }
      opened = pdf;
      setState({ pdf, error: false });
    }).catch(() => { if (alive) setState({ pdf: null, error: true }); });
    return () => { alive = false; opened?.destroy(); };
  }, [bytes]);
  return state;
}

/** Une page rendue quand elle devient visible. */
function PageCanvas({ pdf, index, width, top = 0, bottom = 1, highlight, anchor }: {
  pdf: OpenPDF; index: number; width: number; top?: number; bottom?: number;
  highlight?: { top: number; bottom: number } | null; anchor?: boolean;
}) {
  const host = useRef<HTMLDivElement>(null);
  const [visible, setVisible] = useState(false);
  const [canvas, setCanvas] = useState<HTMLCanvasElement | null>(null);
  const ratio = typeof window === "undefined" ? 1 : Math.min(window.devicePixelRatio || 1, 2);

  useEffect(() => {
    const node = host.current;
    if (!node) return;
    const observer = new IntersectionObserver((entries) => { if (entries.some((e) => e.isIntersecting)) setVisible(true); },
      { rootMargin: "600px 0px" });
    observer.observe(node);
    return () => observer.disconnect();
  }, []);

  useEffect(() => {
    if (!visible || width <= 0) return;
    let alive = true;
    renderBand(pdf, index, Math.round(width * ratio), top, bottom).then((next) => { if (alive) setCanvas(next); }).catch(() => {});
    return () => { alive = false; };
  }, [visible, pdf, index, width, top, bottom, ratio]);

  useEffect(() => {
    if (anchor && canvas) host.current?.scrollIntoView({ block: "start" });
  }, [anchor, canvas]);

  const span = bottom - top;
  return (
    <div ref={host} className="pdf-page" data-page={index}
      style={{ width, minHeight: canvas ? undefined : Math.round(width * 1.4 * span) }}>
      {canvas && (
        <canvas ref={(node) => {
          if (!node || !canvas) return;
          node.width = canvas.width; node.height = canvas.height;
          node.getContext("2d")?.drawImage(canvas, 0, 0);
        }} style={{ width, height: Math.round(canvas.height / ratio) }} />
      )}
      {highlight && canvas && (
        <div className="pdf-mark" style={{
          top: `${((highlight.top - top) / span) * 100}%`,
          height: `${((highlight.bottom - highlight.top) / span) * 100}%`,
        }} />
      )}
    </div>
  );
}

function useWidth(): [React.RefObject<HTMLDivElement | null>, number] {
  const ref = useRef<HTMLDivElement>(null);
  const [width, setWidth] = useState(0);
  useEffect(() => {
    const node = ref.current;
    if (!node) return;
    const measure = () => setWidth(Math.max(0, Math.floor(node.clientWidth - 24)));
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(node);
    return () => observer.disconnect();
  }, []);
  return [ref, width];
}

/** Le PDF entier, éventuellement ouvert sur un exercice dont la zone est surlignée. */
export function PDFPane({ bytes, highlight }: { bytes: Uint8Array; highlight?: CropRegion | null }) {
  const { pdf, error } = useOpenPDF(bytes);
  const [ref, width] = useWidth();
  const first = highlight?.parts[0]?.page ?? -1;
  return (
    <div className="pdf-pane" ref={ref}>
      {error && <p className="pdf-note">Ce fichier n'a pas pu être ouvert comme PDF.</p>}
      {pdf && width > 0 && Array.from({ length: pdf.pageCount }, (_, index) => (
        <PageCanvas key={index} pdf={pdf} index={index} width={width} anchor={index === first}
          highlight={highlight?.parts.find((part) => part.page === index) ?? null} />
      ))}
    </div>
  );
}

const lineCache = new WeakMap<Uint8Array, Promise<PDFLayoutLine[]>>();
function layoutOf(bytes: Uint8Array): Promise<PDFLayoutLine[]> {
  let cached = lineCache.get(bytes);
  if (!cached) { cached = linesFromData(bytes); lineCache.set(bytes, cached); }
  return cached;
}

function readCropped(): boolean {
  try { return localStorage.getItem("exercise.cropped") !== "false"; } catch { return true; }
}

/**
 * L'énoncé d'un exercice dans son PDF : l'exercice seul quand on le retrouve ; sur
 * demande, le PDF entier, ouvert à l'exercice et l'exercice surligné.
 */
export function ExercisePDFView({ bytes, exercise, next }: { bytes: Uint8Array; exercise: CropExercise; next: CropExercise | null }) {
  const { pdf, error } = useOpenPDF(bytes);
  const [ref, width] = useWidth();
  const [cropped, setCropped] = useState(readCropped);
  const [region, setRegion] = useState<CropRegion | null | undefined>(undefined);
  const key = `${exercise.exerciseNumber}|${exercise.title}|${exercise.rank ?? ""}|${next?.exerciseNumber ?? ""}`;

  useEffect(() => {
    if (!pdf) return;
    let alive = true;
    setRegion(undefined);
    layoutOf(bytes).then((lines) => {
      if (alive) setRegion(PDFExerciseCrop.regionFor(lines, pdf.pageCount, exercise, next));
    }).catch(() => { if (alive) setRegion(null); });
    return () => { alive = false; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [pdf, bytes, key]);

  const toggle = () => {
    const value = !cropped;
    setCropped(value);
    try { localStorage.setItem("exercise.cropped", String(value)); } catch { /* stockage refusé */ }
  };

  return (
    <div className="pdf-exercise">
      <div className="pdf-pane" ref={ref}>
        {error && <p className="pdf-note">Ce fichier n'a pas pu être ouvert comme PDF.</p>}
        {pdf && width > 0 && region === undefined && <p className="pdf-note">Recherche de l'exercice…</p>}
        {pdf && width > 0 && region && cropped && region.parts.map((part) => (
          <PageCanvas key={`${part.page}-${part.top}`} pdf={pdf} index={part.page} width={width} top={part.top} bottom={part.bottom} />
        ))}
        {pdf && width > 0 && region !== undefined && !(region && cropped) && (
          <>
            {region === null && <p className="pdf-note">L'exercice n'a pas été retrouvé dans le PDF.</p>}
            {Array.from({ length: pdf.pageCount }, (_, index) => (
              <PageCanvas key={index} pdf={pdf} index={index} width={width}
                anchor={region?.parts[0]?.page === index}
                highlight={region?.parts.find((part) => part.page === index) ?? null} />
            ))}
          </>
        )}
      </div>
      {region && (
        <Button size="sm" className="pdf-toggle" onClick={toggle}
          icon={cropped ? "doc.on.doc" : "rectangle.dashed"}
          title={cropped ? "Le PDF entier, l'exercice surligné" : "Ne montrer que cet exercice"}>
          {cropped ? "Tout le PDF" : "Cet exercice seul"}
        </Button>
      )}
    </div>
  );
}

