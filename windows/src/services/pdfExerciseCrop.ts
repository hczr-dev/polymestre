// Un PDF de série réduit à **un** exercice : de son titre au titre du suivant, sur
// une ou plusieurs pages (StudyKit/PDFExerciseCrop.swift).
//
// Plus besoin de chercher 6.9 dans six pages d'énoncé — ni dans le corrigé.
//
// PDFKit cherche une chaîne et rend des bornes de glyphes ; ici la recherche
// porte sur les **lignes** de la mise en page (`pdfLayoutExtractor`), dont la
// position verticale (0 haut → 1 bas) tient lieu de bornes. Une zone est donc
// exprimée en fractions de page, comme les bandes de `SeriesPDFStore`. Le PDF
// réduit lui-même n'est pas écrit : le lecteur montre la bande par découpe.

import type { PDFLayoutLine } from "../domain/seriesLayout.ts";
import { ExerciseRegions } from "../domain/focusTargets.ts";

/** Ce que l'exercice demande à retrouver : numéro, titre, et la série qui le porte. */
export interface CropExercise {
  exerciseNumber: string;
  title: string;
  displayNumber: string;
  seriesNumber: number | null;
  /** Son rang dans la série (0…) : retrouve un exercice sans numéro imprimé. */
  rank?: number | null;
}

/// Où un titre a été trouvé : sa page et sa position (fraction du haut).
export interface Place {
  page: number;
  top: number;
}

/// Une zone par page, de son titre au titre suivant (fractions de page).
export interface CropRegion {
  parts: { page: number; top: number; bottom: number }[];
}

/// Une page, deux chiffres : `String(format: "%02d")`.
function pad2(value: number): string {
  return value < 10 ? `0${value}` : String(value);
}

/// Les mots qui retrouvent un exercice dans un PDF, du plus sûr au moins sûr :
/// « Ex-03-02 », « Exercice 2 », « Problem 2 »… puis son **titre** (« Center of
/// mass of a rod ») — beaucoup de séries numérotent « 1. Titre » sans le mot
/// « Exercice ».
export function terms(exercise: CropExercise): string[] {
  const number = exercise.exerciseNumber;
  const parts = number.split(".").filter((part) => part !== "");
  const last = parts.length > 0 ? parts[parts.length - 1] : number;
  const result = [`Exercice ${number}`, `Exercice ${last}`, `Exercise ${last}`, `Ex. ${last}`,
    `Problème ${last}`, `Problem ${last}`];
  if (exercise.seriesNumber !== null && /^[+-]?\d+$/.test(last)) {
    const n = Number(last);
    result.unshift(`Ex-${pad2(exercise.seriesNumber)}-${pad2(n)}`);
    result.push(`Exercice ${exercise.seriesNumber}.${n}`);
  }
  const title = exercise.title.trim();
  if ([...title].length >= 4 && title !== exercise.displayNumber) result.push(title);
  return result;
}

/// `folding(options: [.caseInsensitive, .diacriticInsensitive])`, espaces repliés.
function fold(text: string): string {
  return text.normalize("NFD").replace(/\p{M}/gu, "").toLowerCase()
    .replace(/\s+/g, " ").trim();
}

/// La ligne est-elle le **titre** cherché ? Elle doit commencer par le mot (après
/// un éventuel numéro « 1. »), sinon « utilise l'Exercise 1 » dans l'énoncé du 2
/// serait pris pour le titre du 1. Et « Exercice 1 » ne trouve pas « Exercice 10 ».
export function isHeading(line: string, term: string): boolean {
  let text = fold(line);
  const wanted = fold(term);
  // « 1. Titre », « 1) Titre », « (1) Titre », « 1 Titre » : le numéro s'ôte.
  if (!text.startsWith(wanted)) {
    text = text.replace(/^\(?\d{1,2}[.)]?\)?\s*/, "");
  }
  if (!text.startsWith(wanted)) return false;
  const rest = text.slice(wanted.length);
  const lastIsDigit = /\p{N}$/u.test(term);
  return !lastIsDigit || !/^\p{N}/u.test(rest);
}

/// Le premier **titre** trouvé (dans l'ordre des mots), après `after`.
export function find(wanted: string[], lines: PDFLayoutLine[], after: Place | null): Place | null {
  for (const term of wanted) {
    for (const line of lines) {
      const top = line.verticalPosition;
      if (top === undefined) continue;
      if (after && (line.pageIndex < after.page || (line.pageIndex === after.page && top <= after.top + 0.002))) continue;
      if (!isHeading(line.text, term)) continue;
      return { page: line.pageIndex, top };
    }
  }
  return null;
}

/// Les titres « Exercice », « Exercise », « Problème », « Problem », dans l'ordre
/// du document — la famille la plus fournie, deux au moins.
export function bareHeadings(lines: PDFLayoutLine[]): Place[] {
  let best: Place[] = [];
  for (const family of ["Exercice", "Exercise", "Problème", "Problem"]) {
    const places: Place[] = [];
    let previous: Place | null = null;
    while (places.length < 40) {
      const place = find([family], lines, previous);
      if (!place) break;
      places.push(place);
      previous = place;
    }
    if (places.length > best.length) best = places;
  }
  return best.length >= 2 ? best : [];
}

/// La zone de l'exercice : par ses mots, sinon — exercice sans numéro imprimé,
/// titré « Exercice » seul — par son **rang** : le n-ième titre du document.
export function regionFor(lines: PDFLayoutLine[], pageCount: number, exercise: CropExercise, next: CropExercise | null): CropRegion | null {
  const found = region(lines, pageCount, terms(exercise), next ? terms(next) : []);
  if (found || exercise.rank === undefined || exercise.rank === null) return found;
  const headings = bareHeadings(lines);
  if (exercise.rank >= headings.length) return null;
  return regionBetween(pageCount, headings[exercise.rank], headings[exercise.rank + 1] ?? null);
}

/// La zone de l'exercice : une partie par page, de son titre au suivant.
export function region(lines: PDFLayoutLine[], pageCount: number, wanted: string[], nextWanted: string[]): CropRegion | null {
  const start = find(wanted, lines, null);
  if (!start) return null;
  return regionBetween(pageCount, start, find(nextWanted, lines, start));
}

function regionBetween(pageCount: number, start: Place, end: Place | null): CropRegion | null {
  const lastPage = end?.page ?? Math.min(start.page + 1, pageCount - 1);
  const parts: CropRegion["parts"] = [];
  for (let page = start.page; page <= lastPage; page++) {
    let top = 0;
    let bottom = 1;
    if (page === start.page) top = Math.max(0, start.top - ExerciseRegions.headingMargin);
    if (end && page === end.page) bottom = Math.min(1, Math.max(0, end.top - ExerciseRegions.endMargin));
    // Moins de 24 pt (≈ 3 % d'une page) : rien à montrer.
    if (bottom - top <= 0.03) continue;
    parts.push({ page, top, bottom });
  }
  return parts.length === 0 ? null : { parts };
}

/// Les parties d'un sujet d'examen : la numérotation qu'il emploie
/// (« Question 1, 2… », « Exercice 1, 2… », « Problème… »), suivie dans l'ordre du
/// document. Au moins deux, sinon rien (le sujet se lit entier).
export function questions(lines: PDFLayoutLine[]): string[] {
  const families = ["Question", "Exercice", "Exercise", "Problème", "Problem", "Partie", "Part"];
  let best: string[] = [];
  for (const family of families) {
    const labels: string[] = [];
    let previous: Place | null = null;
    for (let number = 1; number <= 30; number++) {
      const place = find([`${family} ${number}`], lines, previous);
      if (!place) break;
      labels.push(`${family} ${number}`);
      previous = place;
    }
    if (labels.length > best.length) best = labels;
  }
  return best.length >= 2 ? best : [];
}

export const PDFExerciseCrop = { terms, isHeading, find, region, regionFor, bareHeadings, questions };
