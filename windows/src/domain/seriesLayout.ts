// Repère séries et exercices d'après la mise en page d'un PDF (Polymestre/Domain/SeriesLayout.swift).
//
// `NSRegularExpression` devient `RegExp` (voir icuRegExp.ts) ; les positions sont des indices
// UTF-16 comme les `NSRange` ; les décomptes de `Character` (`.count`, `.prefix`) se font en
// graphèmes. Les types imbriqués Swift (`SeriesLayoutParser.QuestionMark`…) sont exportés à côté.

import type { SubQuestionKind } from "../models/enums.ts";
import { localizedStandardCompare, trimAll, trimWhitespaces } from "../models/util.ts";
import {
  DetectedSeries, DetectedSubQuestion, SeriesPDFParser, swiftInt,
  type DetectedExercise,
} from "../services/seriesPDFParser.ts";
import { icuRegExp } from "./icuRegExp.ts";
import { SeriesIdentity, type SeriesKey } from "./seriesIdentity.ts";
import { characters, isNumber } from "./textRepair.ts";

/// Une ligne de PDF, avec ce que sa **mise en page** dit d'elle.
///
/// L'extraction précédente faisait `page.string` : tout le document devenait un
/// seul bloc de texte, et la distinction entre un titre et un énoncé disparaissait.
/// C'est de là que venaient « solution générale. » sous l'exercice 1 ou
/// « tions change. » sous le 3 — des morceaux de phrase pris pour des intitulés.
export interface PDFLayoutLine {
  text: string;
  /// Taille de police dominante de la ligne. `0` quand le PDF n'en expose pas.
  fontSize: number;
  isBold: boolean;
  pageIndex: number;
  /// Retrait depuis le bord gauche de la page, en points. `0` quand inconnu.
  ///
  /// C'est le signal qui distingue un exercice (aligné à gauche) de ses
  /// questions (décalées vers la droite) — et que l'IA ne pouvait pas voir tant
  /// que le texte lui arrivait aplati.
  indent: number;
  /// La ligne **commence** en gras : un titre « en ligne », typique de LaTeX
  /// (« **Exercice 1.** Soit f… »), dont la police dominante reste celle du corps.
  startsBold: boolean;
  /// Position verticale sur la page, de 0 (haut) à 1 (bas). Absente quand inconnue.
  ///
  /// L'ordre des lignes ne suffit pas à reconnaître un pied de page : PDFKit
  /// rend une seconde colonne **après** lui.
  verticalPosition?: number;
}

export const PDFLayoutLine = {
  /// `PDFLayoutLine(text:fontSize:isBold:pageIndex:indent:startsBold:verticalPosition:)`.
  make(text: string, o: Partial<Omit<PDFLayoutLine, "text">> = {}): PDFLayoutLine {
    return {
      text,
      fontSize: o.fontSize ?? 0,
      isBold: o.isBold ?? false,
      pageIndex: o.pageIndex ?? 0,
      indent: o.indent ?? 0,
      startsBold: o.startsBold ?? false,
      verticalPosition: o.verticalPosition,
    };
  },

  trimmed(line: PDFLayoutLine): string {
    return trimAll(line.text);
  },

  isEmpty(line: PDFLayoutLine): boolean {
    return trimAll(line.text) === "";
  },
};

const trimmed = PDFLayoutLine.trimmed;
const isEmptyLine = PDFLayoutLine.isEmpty;

/// `SeriesLayoutParser.QuestionMark` : une étiquette de question, avec le retrait de sa ligne.
export interface QuestionMark {
  label: string;
  indent: number;
  /// « ) », « . », « () » : « 1. » et « 1) » ne sont pas la même liste.
  delimiter: string;
  /// Ce qui suit l'étiquette sur la ligne.
  text: string;
}

/// `QuestionMark(label:indent:delimiter:text:)` (les deux derniers ont une valeur par défaut).
export function makeQuestionMark(label: string, indent: number, delimiter = "", text = ""): QuestionMark {
  return { label, indent, delimiter, text };
}

/// `SeriesLayoutParser.QuestionEvent` : une ligne sous un exercice, des étiquettes de question, ou du texte.
export interface QuestionEvent {
  marks: QuestionMark[];
  text: string;
  /// Alignée sur la marge gauche du document.
  nearMargin: boolean;
}

/// `SeriesLayoutParser.LabelStyle`.
export type LabelStyle = "number" | "letter" | "roman";

/// `SeriesLayoutParser.ExerciseMarker.Kind`.
export type ExerciseMarkerKind = "dashed" | "keyword" | "question" | "numeric";

/// `SeriesLayoutParser.ExerciseMarker`.
export interface ExerciseMarker {
  number: string;
  /// Série déduite du numéro lui-même (« Ex-02-04 » → 2), sinon `null`.
  series: number | null;
  remainder: string;
  kind: ExerciseMarkerKind;
}

// MARK: Motifs

/// Les mots qui annoncent un exercice, en français, anglais et allemand : les
/// cours de master sont souvent en anglais, et un polycopié « Exercise 3 »
/// n'était tout simplement pas vu.
const exerciseKeywords = String.raw`exercices?|exercises?|exo|ex|probl[eè]mes?|problems?|aufgabe`;

const seriesPattern = icuRegExp(
  String.raw`^[ \t]*s[ée]rie[ \t]*(?:n[°o][ \t]*)?(\d{1,2})(?:(?:[ \t]*[-.(][ \t]*)?([a-f])\)?)?\b[ \t]*[–—:.\-]?[ \t]*(.*)$`, "i");

/// « Exercice », « Exercise — Titre », « Exercice (Rosen 1.2) » : le mot seul, sans numéro.
const unnumberedPattern = icuRegExp(
  String.raw`^[ \t]*(?:exercice|exercise|probl[eè]me|problem|aufgabe)[ \t]*\*?[ \t]*(?:[:.\-–—][ \t]*(.*)|\(([^)]*)\)[ \t]*(.*)|)$`, "i");

function unnumberedHeading(text: string): string | null {
  const match = unnumberedPattern.exec(text);
  if (!match) return null;
  return match.slice(1).filter((part): part is string => part !== undefined)
    .map((part) => part.trim()).filter((part) => part !== "").join(" ");
}

const dashedPattern = icuRegExp(
  String.raw`\bEx[ .\-]?(\d{1,2})[.\-](\d{1,2})\b[ \t]*[:.\-–—]?[ \t]*(.*)$`);

const barePattern = icuRegExp(
  String.raw`^[ \t]*(?:` + exerciseKeywords + String.raw`)[ \t]*\.?[ \t]*(?:n[°o][ \t]*)?(\d{1,2})\b(?!\.\d)[ \t]*\*?[ \t]*[:.\-–—]?[ \t]*(.*)$`, "i");

const keywordNumberedPattern = icuRegExp(
  String.raw`^[ \t]*(?:` + exerciseKeywords + String.raw`)[ \t]*\.?[ \t]*(?:n[°o][ \t]*)?(\d{1,2})[.\-·](\d{1,2})\b[ \t]*\*?[ \t]*[–—:.\-)]?[ \t]*(.*)$`, "i");

const questionHeadingPattern = icuRegExp(
  String.raw`^[ \t]*question[ \t]*(?:n[°o][ \t]*)?(\d{1,2})\b(?!\.\d)[ \t]*[:.\-–—]?[ \t]*(.*)$`, "i");

const numberedPattern = icuRegExp(
  String.raw`^[ \t]*(\d{1,2})[.\-·](\d{1,2})\b(?![.,]\d)[ \t]*[–—:.\-)]?[ \t]*(.*)$`);

/// « 3. Titre » ou « 3) » : un numéro seul, qui n'est un exercice que mis en forme.
const singleNumberPattern = icuRegExp(String.raw`^[ \t]*(\d{1,2})[.)](?!\d)[ \t]*(.*)$`);

const questionPattern = icuRegExp(
  String.raw`^[ \t]*(?:\(([a-hA-H]|[ivx]{1,4}|\d{1,2})\)|([a-hA-H]|[ivx]{1,4})\)|([a-h])\.[ \t]|(\d{1,2})([.)])[ \t])`);

const transitionPattern = icuRegExp(
  String.raw`^(Ensuite|Puis|Enfin|Finalement|De plus|Then|Next|Finally|Afterwards)\b`, "i");

const imperativePattern = icuRegExp(
  String.raw`\b(Calculer|Montrer|Démontrer|Déterminer|Prouver|Trouver|Étudier|Donner|Résoudre|Vérifier|Compute|Show|Prove|Find|Determine|Solve)\b[^.]*?(?=[.;]?\s*(Ensuite|Puis|Then|Next)\b)`, "i");

const conditionPatterns = [
  icuRegExp(String.raw`(conditions?|hypoth[eè]ses?|propri[eé]t[eé]s?|axiomes?)\s+suivant`),
  icuRegExp(String.raw`following\s+(conditions?|properties|assumptions)`),
  icuRegExp(String.raw`satisf\w*\s.*suivant`),
];

/// Nombre de lignes explorées après un titre pour trouver « bonus », « facultatif ».
const bonusLookahead = 12;

// MARK: Corps de texte

/// Taille du corps : la plus fréquente, **pondérée par le nombre de caractères**.
///
/// Compter les lignes ne suffit pas — un document peut avoir trente titres
/// courts et dix paragraphes longs. Ce qu'on lit, ce sont les caractères.
function bodyFontSize(lines: PDFLayoutLine[]): number | null {
  const weight = new Map<number, number>();
  for (const line of lines) {
    if (!(line.fontSize > 0)) continue;
    weight.set(line.fontSize, (weight.get(line.fontSize) ?? 0) + Math.max(1, characters(trimmed(line)).length));
  }
  // À poids égal, la plus petite taille l'emporte (`max` avec `lhs.key > rhs.key`).
  let best: number | null = null;
  let bestWeight = 0;
  for (const [size, value] of weight) {
    if (best === null || value > bestWeight || (value === bestWeight && size < best)) {
      best = size;
      bestWeight = value;
    }
  }
  return best;
}

/// Le corps est-il en gras ? Sur un jeu de diapositives, tout l'est : le gras
/// ne distingue alors plus rien et ne doit pas servir de signal.
function bodyIsBold(lines: PDFLayoutLine[]): boolean {
  const body = lines.filter((line) => !isEmptyLine(line));
  if (body.length === 0) return false;
  const bold = body.filter((line) => line.isBold).length;
  return bold * 2 > body.length;
}

/// La ligne se détache-t-elle du corps du texte ?
function isHeading(line: PDFLayoutLine, body: number | null, boldBody: boolean): boolean {
  if (isEmptyLine(line)) return false;
  if (body !== null && line.fontSize > 0) {
    if (line.fontSize >= body * 1.06) return true;
    // Tailles identiques : le gras prend le relais, s'il est rare.
    if (!boldBody && line.isBold && line.fontSize >= body * 0.98) return true;
    return false;
  }
  return false;
}

/// Un titre, ou un titre « en ligne » qui commence en gras.
function isMarkedUp(line: PDFLayoutLine, body: number | null, boldBody: boolean): boolean {
  return isHeading(line, body, boldBody) || (!boldBody && line.startsBold);
}

// MARK: Analyse

/// Repère les séries et leurs exercices.
///
/// `defaultSeries` est la série que le **document** annonce ailleurs qu'en
/// tête de ligne — un en-tête « Analyse I — Série 4 », le nom du fichier.
/// Sans lui, un polycopié sans « Série N » en début de ligne rangeait tous ses
/// exercices dans la série 1, et l'IA, qui lisait bien 4, en créait une seconde.
///
/// Quand aucun PDF n'expose de police (texte collé, PDF sans fontes), on
/// retombe sur `SeriesPDFParser` : le comportement précédent, sans régression.
function parse(lines: PDFLayoutLine[], defaultSeries: number | null = null): DetectedSeries[] {
  if (!lines.some((line) => line.fontSize > 0)) {
    return SeriesPDFParser.parse(lines.map((line) => line.text).join("\n"), defaultSeries);
  }

  const body = bodyFontSize(lines);
  const boldBody = bodyIsBold(lines);
  const fallback = defaultSeries ?? 1;
  // Le document écrit-il « Exercice » (ou « Exercise », « Problème »…) ?
  // Alors « Question 2 » ou un « 1. » en gras sont des **questions** de
  // l'exercice courant, pas des exercices.
  const usesKeywords = lines.some((line) => {
    const marker = exerciseMarker(trimmed(line), 1);
    if (!marker) return false;
    return marker.kind === "keyword" || marker.kind === "dashed";
  });
  const indents = lines.filter((line) => !isEmptyLine(line) && line.indent > 0).map((line) => line.indent);
  const leftMargin = indents.length === 0 ? 0 : Math.min(...indents);
  const plainHeadings = usesKeywords ? new Set<number>() : plainNumberedHeadings(lines, leftMargin);
  // Des exercices titrés « Exercice » **sans numéro** : seulement dans un document
  // qui n'en numérote aucun, et qui en a au moins deux.
  const unnumberedHeadings = !usesKeywords && plainHeadings.size === 0
    && lines.filter((line) => unnumberedHeading(trimmed(line)) !== null && (line.isBold || isHeading(line, body, boldBody))).length >= 2;

  // Une série = son numéro et son étiquette : « Série 5a » et « 5b » restent deux séries.
  // Les cartes sont indexées par `SeriesIdentity.id`.
  const keys = new Map<string, SeriesKey>();
  const remember = (key: SeriesKey): string => { const id = SeriesIdentity.id(key); keys.set(id, key); return id; };
  const seriesTitles = new Map<string, string>();
  const groups = new Map<string, DetectedExercise[]>();
  const seen = new Set<string>();
  let currentSeries: SeriesKey | null = null;
  const order: string[] = [];
  const unnumberedCount = new Map<string, number>();
  /// Position de l'exercice en cours, pour y rattacher ses questions.
  let current: { series: string; index: number } | null = null;
  /// Les lignes de l'exercice en cours, dans l'ordre : questions et texte.
  let events: QuestionEvent[] = [];

  const closeExercise = () => {
    if (current) {
      const list = groups.get(current.series);
      if (list) list[current.index].subQuestions = questionTree(events);
    }
    current = null;
    events = [];
  };

  for (let index = 0; index < lines.length; index++) {
    const line = lines[index];
    const text = trimmed(line);
    if (text === "") continue;

    // 1. En-tête de série.
    const header = seriesHeader(text);
    if (header) {
      closeExercise();
      const { remainder } = header;
      currentSeries = SeriesIdentity.key(header.number, header.label);
      const number = remember(currentSeries);
      if (!order.includes(number)) order.push(number);
      if (!seriesTitles.has(number)) {
        let title = SeriesPDFParser.cleanTitle(remainder);
        // Un titre de série peut tenir sur la ligne suivante quand
        // celle-ci est **du même niveau** que l'en-tête.
        if (title === ""
          && index + 1 < lines.length
          && isHeading(lines[index + 1], body, boldBody)
          && seriesHeader(trimmed(lines[index + 1])) === null
          && exerciseMarker(trimmed(lines[index + 1]), 1) === null) {
          title = SeriesPDFParser.cleanTitle(trimmed(lines[index + 1]));
        }
        seriesTitles.set(number, SeriesPDFParser.looksLikeTitle(title) ? title : "");
      }
      continue;
    }

    const markedUp = isMarkedUp(line, body, boldBody);
    const nearMargin = line.indent <= leftMargin + 18;

    // 2. Exercice.
    const seriesNow: SeriesKey = currentSeries ?? SeriesIdentity.key(fallback);
    let marker = exerciseMarker(text, seriesNow.number);
    let plainHeading = plainHeadings.has(index);
    // « Exercice » sans numéro : un titre mis en forme, numéroté dans l'ordre.
    const bare = marker === null && unnumberedHeadings ? unnumberedHeading(text) : null;
    if (bare !== null && (markedUp || (nearMargin && line.isBold))) {
      const nowID = SeriesIdentity.id(seriesNow);
      const next = (unnumberedCount.get(nowID) ?? 0) + 1;
      unnumberedCount.set(nowID, next);
      marker = { number: `${seriesNow.number}.${next}`, series: null, remainder: bare, kind: "keyword" };
      plainHeading = true;
    }
    if (marker && (plainHeading || accepts(marker, markedUp, nearMargin, usesKeywords))) {
      const resolvedKey = marker.series === null ? seriesNow
        : marker.series === seriesNow.number ? seriesNow : SeriesIdentity.key(marker.series);
      const seenKey = resolvedKey.label + "|" + marker.number;
      if (seen.has(seenKey)) {
        // Un doublon (corrigé à la suite de l'énoncé, rappel en pied de
        // page) clôt l'exercice précédent sans en créer un nouveau.
        closeExercise();
        continue;
      }
      seen.add(seenKey);
      closeExercise();
      const resolvedSeries = remember(resolvedKey);
      if (!order.includes(resolvedSeries)) order.push(resolvedSeries);

      const list = groups.get(resolvedSeries) ?? [];
      groups.set(resolvedSeries, list);
      list.push({
        number: marker.number,
        title: title(marker, line, nextLine(lines, index), body, boldBody),
        isBonus: bonus(lines, index, body, boldBody),
        statement: "",
        subQuestions: [],
        isConfident: marker.kind !== "numeric" || plainHeading,
        pageIndex: line.pageIndex,
        verticalPosition: line.verticalPosition,
      });
      current = { series: resolvedSeries, index: list.length - 1 };
      events = [{ marks: [], text: marker.remainder, nearMargin: true }];
      continue;
    }

    // 3. Question d'un exercice : « a) », « (b) », « 1. » décalé — ou texte.
    if (current === null) continue;
    events.push({
      marks: questionMark(text, usesKeywords || plainHeadings.size > 0, line.indent) ?? [],
      text,
      nearMargin,
    });
  }
  closeExercise();

  const byKey = (a: string, b: string) => SeriesIdentity.compare(keys.get(a)!, keys.get(b)!);
  const result: DetectedSeries[] = [...order].sort(byKey).map((id) => ({
    number: keys.get(id)!.number,
    label: keys.get(id)!.label,
    title: seriesTitles.get(id) ?? "",
    exercises: [...(groups.get(id) ?? [])].sort((a, b) => localizedStandardCompare(a.number, b.number)),
  }));

  // Une série annoncée sans exercice reconnu est **conservée** : mieux vaut
  // une carte vide à compléter à la main qu'un import qui ne trouve rien.
  for (const [id, title] of seriesTitles) {
    if (!groups.has(id) && !order.includes(id)) result.push({ number: keys.get(id)!.number, label: keys.get(id)!.label, title, exercises: [] });
  }
  return DetectedSeries.withoutBlanketBonus(result.sort((a, b) =>
    SeriesIdentity.compare(SeriesIdentity.key(a.number, a.label ?? ""), SeriesIdentity.key(b.number, b.label ?? ""))));
}

/// Un repère est-il crédible **à cet endroit** de la mise en page ?
///
/// Un mot-clé (« Exercice 3 ») est presque toujours un titre, sauf quand il
/// est cité (« Exercice 2 de la série précédente… »). Un numéro nu (« 1.5 »,
/// « 2. ») ne l'est que s'il est **mis en forme** comme un titre : sans cette
/// règle, la première ligne d'une démonstration numérotée devenait un
/// exercice fantôme.
function accepts(marker: ExerciseMarker, markedUp: boolean, nearMargin: boolean, usesKeywords: boolean): boolean {
  switch (marker.kind) {
    case "dashed":
      return true;
    case "keyword":
      return markedUp || !isReference(marker.remainder);
    case "question":
      // « Question 1 » n'est un exercice que dans un document qui n'en
      // nomme aucun autrement.
      return !usesKeywords && (markedUp || !isReference(marker.remainder));
    case "numeric":
      return markedUp && nearMargin && !usesKeywords;
  }
}

/// Les titres « 1. Rotating space station » que la police ne distingue pas.
///
/// Certains PDF LaTeX (PHYS-101) embarquent des polices que PDFKit ne sait pas
/// nommer : tout sort en « Helvetica » corps 10, titres en gras compris. Un
/// numéro nu n'était alors jamais « mis en forme », et l'import ne trouvait
/// **aucun** exercice — l'IA restait seule, sans rien pour la contredire.
///
/// La mise en page suffit pourtant : des lignes courtes, **exactement** sur la
/// marge, numérotées 1, 2, 3… dans l'ordre, sans ponctuation de phrase. Les
/// questions « 1. Find … », décalées de quelques points, n'en font pas partie.
function plainNumberedHeadings(lines: PDFLayoutLine[], leftMargin: number): Set<number> {
  if (!(leftMargin > 0)) return new Set();
  const candidates: { index: number; value: number }[] = [];
  lines.forEach((line, index) => {
    if (isEmptyLine(line) || !(Math.abs(line.indent - leftMargin) <= 3)) return;
    const match = singleNumberPattern.exec(trimmed(line));
    if (!match) return;
    const value = swiftInt(match[1]);
    if (value === null) return;
    const remainder = trimWhitespaces(match[2]);
    const length = characters(remainder).length;
    if (!(length >= 2 && length <= 60)) return;
    if (!/^\p{Uppercase}/u.test(remainder)) return;
    if (remainder.endsWith(".") || remainder.endsWith(";") || remainder.endsWith(",")) return;
    candidates.push({ index, value });
  });
  // 1, 2, 3… sans trou ni retour en arrière : une liste de titres, pas des
  // lignes numérotées éparses.
  if (!(candidates.length >= 2 && candidates.every((c, offset) => c.value === offset + 1))) return new Set();
  return new Set(candidates.map((c) => c.index));
}

/// « Exercice 2 **de la série** précédente » : une citation, pas un titre.
function isReference(remainder: string): boolean {
  const value = trimWhitespaces(remainder).toLowerCase();
  const prefixes = ["de la ", "du ", "de l'", "de l’", "des ", "et ", "à ", ", ", "ci-dessus", "précédent",
    "of ", "from ", "in ", "and ", "above", "der ", "aus ", "und "];
  return prefixes.some((prefix) => value.startsWith(prefix));
}

// MARK: Questions

/// Les questions d'une ligne, avec leur texte et leur ponctuation.
///
/// Une ligne peut en porter plusieurs quand le polycopié les met côte à côte
/// (« 1) aₙ = … 2) aₙ = … 3) aₙ = … ») : on les sépare, mais seulement si
/// elles **se suivent** et ont la même ponctuation — « (aₙ) » au milieu d'une
/// phrase n'est pas une question.
/// L'étiquette provisoire d'une puce, avant sa numérotation.
const BULLET = "•";

/// Le texte après une puce de liste (`itemize`, listes Word), ou `null`.
/// « - » et « * » demandent une espace : « -1 » est un nombre.
function bulletRemainder(text: string): string | null {
  const trimmed = text.trim();
  if (trimmed === "" || !"•◦▪‣∙●○■□–—-*·".includes(trimmed[0])) return null;
  if (trimmed[1] !== " " && trimmed[1] !== "\t") return null;
  const value = trimmed.slice(1).trim();
  return value === "" ? null : value;
}

/// Les puces numérotées dans l'ordre (SeriesLayout.swift › resolvingBullets).
function resolvingBullets(events: QuestionEvent[]): QuestionEvent[] {
  const all = events.flatMap((event) => event.marks);
  if (!all.some((mark) => mark.delimiter === BULLET)) return events;
  const labeled = all.filter((mark) => mark.delimiter !== BULLET);
  const topIndent = Math.min(...all.filter((mark) => mark.delimiter === BULLET).map((mark) => mark.indent));
  const romans = ["i", "ii", "iii", "iv", "v", "vi", "vii", "viii", "ix", "x", "xi", "xii"];
  const topStyle = labeled.length > 0 ? style(labeled[0].label) : null;
  const child = (n: number) => topStyle === "letter" ? romans[Math.min(n, romans.length) - 1] : String.fromCharCode(96 + Math.min(n, 26));
  let top = 0;
  let children = 0;
  let sawLabeled = false;
  return events.map((event) => ({
    ...event,
    marks: event.marks.flatMap((mark): QuestionMark[] => {
      if (mark.delimiter !== BULLET) { sawLabeled = true; children = 0; return [mark]; }
      if (labeled.length === 0 && mark.indent <= topIndent + 6) {
        top += 1; children = 0;
        return [{ ...mark, label: String(top), delimiter: BULLET }];
      }
      if (labeled.length === 0 ? top > 0 : sawLabeled) {
        children += 1;
        return [{ ...mark, label: child(children), delimiter: BULLET + "·" }];
      }
      return [];
    }),
  }));
}

function questionMark(text: string, allowNumbers: boolean, indent: number): QuestionMark[] | null {
  // Une puce : une question sans étiquette, numérotée plus tard dans l'ordre.
  const bullet = bulletRemainder(text);
  if (bullet !== null) return [{ label: BULLET, indent, delimiter: BULLET, text: bullet }];
  const match = questionPattern.exec(text);
  if (!match) return null;
  const label = questionLabel(text, allowNumbers);
  if (label === null) return null;
  let delimiter: string;
  if (match[1] !== undefined) delimiter = "()";
  else if (match[2] !== undefined) delimiter = ")";
  else if (match[3] !== undefined) delimiter = ".";
  else delimiter = match[5];
  const rest = trimWhitespaces(text.slice(match.index + match[0].length));

  const marks = [makeQuestionMark(label, indent, delimiter, rest)];
  // Suivantes sur la même ligne : « 2) », « 3) »… dans l'ordre.
  const first = swiftInt(label);
  if (first === null || delimiter !== ")") return marks;
  let expected = first + 1;
  let remaining = rest;
  for (;;) {
    const next = new RegExp(String.raw`(?:^|\s)${expected}\)\s`, "u").exec(remaining);
    if (!next) break;
    const before = trimWhitespaces(remaining.slice(0, next.index));
    marks[marks.length - 1].text = before;
    remaining = remaining.slice(next.index + next[0].length);
    marks.push(makeQuestionMark(String(expected), indent, ")", remaining));
    expected += 1;
  }
  return marks;
}

/// L'étiquette d'une question en tête de ligne : « a) », « (ii) », « 3. ».
function questionLabel(text: string, allowNumbers: boolean): string | null {
  const match = questionPattern.exec(text);
  if (!match) return null;
  for (let group = 1; group <= 4; group++) {
    if (match[group] === undefined) continue;
    const label = match[group].toLowerCase();
    const head = characters(label)[0];
    if (head !== undefined && isNumber(head) && !allowNumbers && group === 4) return null;
    return label;
  }
  return null;
}

function style(label: string): LabelStyle {
  const chars = characters(label);
  if (chars.every((c) => isNumber(c))) return "number";
  if ((chars.length > 1 || ["i", "v", "x"].includes(label)) && chars.every((c) => "ivx".includes(c))) {
    // « i » seul est ambigu : c'est un romain s'il ouvre la liste, une
    // lettre s'il suit « h ». On tranche au niveau de la liste.
    return "roman";
  }
  return "letter";
}

/// Les étiquettes du premier niveau, dans l'ordre de leur numéro.
function topLevelQuestions(marks: QuestionMark[]): string[] {
  return questionTreeOfMarks(marks).filter((q) => q.kind === "question").map((q) => q.label);
}

function orderOf(label: string, labelStyle: LabelStyle): number {
  switch (labelStyle) {
    case "number": return swiftInt(label) ?? 0;
    case "letter": return label.codePointAt(0) ?? 0;
    case "roman": {
      const values: Record<string, number> = { i: 1, v: 5, x: 10 };
      let total = 0;
      let previous = 0;
      for (const character of characters(label).reverse()) {
        const value = values[character] ?? 0;
        total += value < previous ? -value : value;
        previous = Math.max(previous, value);
      }
      return total;
    }
  }
}

/// L'arbre des questions à partir des seules étiquettes (tests, texte collé).
function questionTreeOfMarks(marks: QuestionMark[]): DetectedSubQuestion[] {
  return questionTree(marks.map((mark) => ({ marks: [mark], text: mark.label, nearMargin: false })));
}

/// L'arbre des questions d'un exercice : premier niveau, et ses points.
///
/// « 1) … (a) (b) 2) … (a) (b) (c) » donne 1(a,b) et 2(a,b,c) — la version
/// précédente ne gardait que 1 et 2, et les cases réelles disparaissaient.
/// S'y ajoutent les **parties sans numéro** : une consigne d'ouverture suivie de
/// « Ensuite » (« Calculer lim aₙ. Ensuite, … calculer : 1) 2) 3) »), et un
/// « Ensuite, … » après la liste. Une liste de **conditions** (« satisfait les
/// conditions suivantes : 1) … 2) … ») n'est pas une liste de questions.
function questionTree(input: QuestionEvent[]): DetectedSubQuestion[] {
  const events = resolvingBullets(input);
  const marks = events.flatMap((event) => event.marks);
  const first = marks[0];
  if (!first) return [];

  // Le premier niveau : l'étiquette la plus à gauche, et sa ponctuation.
  const hasLayout = marks.some((mark) => mark.indent > 0);
  const minIndent = Math.min(...marks.map((mark) => mark.indent));
  const anchor = hasLayout ? (marks.find((mark) => mark.indent <= minIndent + 6) ?? first) : first;
  let topStyle = style(anchor.label);
  if (topStyle === "roman" && marks.some((mark) => style(mark.label) === "letter" && mark.label !== "i")) {
    topStyle = "letter";
  }
  let childStyle: LabelStyle | null = null;

  const resolved = (mark: QuestionMark): LabelStyle => {
    const raw = style(mark.label);
    // « i » après « h » reste une lettre.
    if (raw === "roman" && characters(mark.label).length === 1 && (topStyle === "letter" || childStyle === "letter")) return "letter";
    return raw;
  };
  const isTop = (mark: QuestionMark): boolean =>
    resolved(mark) === topStyle && (mark.delimiter === anchor.delimiter || anchor.delimiter === "");

  let intro = "";
  const trailing: string[] = [];
  let extendsTrailing = false;
  const questions: DetectedSubQuestion[] = [];
  for (const event of events) {
    if (questions.length === 0) {
      // Avant la liste : tout est consigne, y compris une étiquette qui
      // n'est pas du premier niveau (« n ⩾ 1. Calculer » lu « 1. Calculer »).
      const top = event.marks.findIndex(isTop);
      if (top >= 0) {
        for (const mark of event.marks.slice(0, top)) intro = joinLines(intro, mark.text);
      } else {
        intro = joinLines(intro, event.marks.length === 0 ? event.text : (event.marks[0]?.text ?? event.text));
        continue;
      }
    }
    if (event.marks.length === 0) {
      if (event.nearMargin && startsWithTransition(event.text)) {
        trailing.push(event.text);
        extendsTrailing = true;
      } else if (extendsTrailing && trailing.length > 0 && characters(trailing[trailing.length - 1]).length < 160) {
        // La suite de la phrase « Ensuite, … » sur la ligne d'après.
        trailing[trailing.length - 1] = joinLines(trailing[trailing.length - 1], event.text);
      }
      continue;
    }
    // Une question interrompt la phrase « Ensuite » — mais ne l'annule pas :
    // PDFKit rend la seconde colonne **après** le texte qui suit la liste.
    extendsTrailing = false;
    for (const mark of event.marks) {
      if (isTop(mark)) {
        if (questions.some((q) => q.label === mark.label)) continue;
        questions.push(DetectedSubQuestion.make(mark.label, { text: shortText(mark.text) }));
      } else if (resolved(mark) !== topStyle && questions.length > 0) {
        const markStyle = resolved(mark);
        if (childStyle === null) childStyle = markStyle;
        if (markStyle !== childStyle) continue;
        // Les points vont à la dernière question **dans l'ordre de lecture**.
        const last = questions[questions.length - 1];
        if (last.children.some((c) => c.label === mark.label)) continue;
        last.children.push(DetectedSubQuestion.make(mark.label, { text: shortText(mark.text) }));
      }
    }
  }

  if (introListsConditions(intro)) return [];

  // Deux colonnes arrivent dans le désordre : on remet l'ordre du numéro.
  questions.sort((a, b) => orderOf(a.label, topStyle) - orderOf(b.label, topStyle));
  for (const question of questions) {
    const childrenStyle: LabelStyle = childStyle ?? "letter";
    question.children.sort((a, b) => orderOf(a.label, childrenStyle) - orderOf(b.label, childrenStyle));
    if (!isQuestionSequence(question.children.map((c) => c.label))) question.children = [];
  }
  if (!isQuestionSequence(questions.map((q) => q.label))) return [];

  const lead = leadingTask(intro);
  if (lead !== null) {
    questions.unshift(DetectedSubQuestion.make("", { text: lead, kind: "part" as SubQuestionKind }));
  }
  for (const text of trailing) {
    questions.push(DetectedSubQuestion.make("", { text: shortText(text), kind: "part" as SubQuestionKind }));
  }
  return questions;
}

function startsWithTransition(text: string): boolean {
  return transitionPattern.test(text);
}

/// Une tâche demandée **avant** la liste, et séparée d'elle par « Ensuite ».
function leadingTask(intro: string): string | null {
  const match = imperativePattern.exec(intro);
  if (!match) return null;
  // `.whitespacesAndNewlines.union(.punctuationCharacters)`
  const text = match[0].replace(/^[\s\p{P}]+|[\s\p{P}]+$/gu, "");
  return text === "" ? null : shortText(text);
}

/// « …qui satisfait les deux conditions suivantes : » — la liste qui suit est
/// l'énoncé, pas du travail à cocher.
function introListsConditions(intro: string): boolean {
  const tail = characters(intro.toLowerCase()).slice(-160).join("");
  return conditionPatterns.some((pattern) => pattern.test(tail));
}

/// Recolle deux lignes, sans l'espace d'une césure (« li- » + « mite »).
function joinLines(first: string, second: string): string {
  const a = trimWhitespaces(first);
  const b = trimWhitespaces(second);
  if (a === "") return b;
  if (b === "") return a;
  if (a.endsWith("-")) return a.slice(0, -1) + b;
  return a + " " + b;
}

/// Un énoncé court : la ligne lue, bornée. Le texte d'un PDF LaTeX perd ses
/// symboles mathématiques ; il sert de repère, pas de copie.
function shortText(text: string): string {
  const clean = trimAll(text);
  const chars = characters(clean);
  return chars.length > 90 ? chars.slice(0, 89).join("") + "…" : clean;
}

/// Des étiquettes forment-elles une vraie liste de questions ?
///
/// Deux au moins, et une liste qui **commence** au début (a, 1 ou i) : une
/// ligne isolée « c) » au milieu d'un énoncé n'est pas une question.
function isQuestionSequence(labels: string[]): boolean {
  if (labels.length < 2) return false;
  return ["a", "1", "i"].includes(labels[0]);
}

// MARK: Titres

/// L'intitulé d'un exercice — **jamais** la première ligne de l'énoncé.
///
/// Deux sources seulement : la fin de la ligne du titre, et la ligne suivante
/// **si et seulement si** elle est du même niveau typographique que le titre
/// (un intitulé sur deux lignes). Une ligne de corps de texte n'est jamais un
/// intitulé, c'est ce qui produisait les faux titres.
function title(marker: ExerciseMarker, line: PDFLayoutLine, next: PDFLayoutLine | null,
  body: number | null, boldBody: boolean): string {
  const sameLine = SeriesPDFParser.cleanTitle(marker.remainder);
  if (SeriesPDFParser.looksLikeTitle(sameLine)) return sameLine;

  if (!(next && !isEmptyLine(next)
    && isHeading(next, body, boldBody)
    && next.fontSize <= line.fontSize * 1.02
    && exerciseMarker(trimmed(next), 1) === null
    && seriesHeader(trimmed(next)) === null)) return "";
  const continuation = SeriesPDFParser.cleanTitle(trimmed(next));
  return SeriesPDFParser.looksLikeTitle(continuation) ? continuation : "";
}

function nextLine(lines: PDFLayoutLine[], index: number): PDFLayoutLine | null {
  return index + 1 < lines.length ? lines[index + 1] : null;
}

// MARK: Bonus

/// Cherche « bonus », « facultatif », « optionnel » ou une étoile **dans le
/// corps de l'exercice**.
///
/// L'ancienne version ne regardait que la ligne du titre et la suivante. Sur un
/// vrai polycopié, la mention est souvent deux ou trois lignes plus bas, après
/// l'énoncé — elle était donc manquée.
function bonus(lines: PDFLayoutLine[], index: number, body: number | null, boldBody: boolean): boolean {
  for (let offset = 0; offset <= bonusLookahead; offset++) {
    const position = index + offset;
    if (!(position < lines.length)) break;
    const line = lines[position];
    // Un nouveau titre clôt l'exercice : au-delà, la mention appartient à
    // quelqu'un d'autre.
    if (offset > 0 && isHeading(line, body, boldBody)) break;
    if (offset > 0 && exerciseMarker(trimmed(line), 1)?.kind === "keyword") break;
    if (SeriesPDFParser.containsBonusMarker(trimmed(line))) return true;
  }
  return false;
}

// MARK: Repères

/// « Série 5b — Suites » → (5, « b », « Suites »). « Série 5 à rendre » n'a pas d'étiquette.
function seriesHeader(text: string): { number: number; label: string; remainder: string } | null {
  const match = seriesPattern.exec(text);
  if (!match) return null;
  const number = swiftInt(match[1]);
  if (number === null || !(number >= 1 && number <= 60)) return null;
  const letter = match[2] ?? "";
  let remainder = match[3] ?? "";
  const label = SeriesIdentity.normalized(letter === "" ? SeriesIdentity.label(text) : letter);
  // « Série 5.2 — Suites » : le « 2 » est l'étiquette, pas le titre.
  if (/^\d+$/.test(label) && remainder.startsWith(label) && !/^\d/.test(remainder.slice(label.length))) {
    remainder = remainder.slice(label.length).replace(/^[ \t–—:.-]+|[ \t–—:.-]+$/g, "");
  }
  return { number, label, remainder };
}

function exerciseMarker(text: string, fallbackSeries: number): ExerciseMarker | null {
  const int = (match: RegExpExecArray, group: number): number | null =>
    match[group] === undefined ? null : swiftInt(match[group]);
  const string = (match: RegExpExecArray, group: number): string => match[group] ?? "";

  let match = dashedPattern.exec(text);
  if (match) {
    const major = int(match, 1), minor = int(match, 2);
    if (major !== null && minor !== null && minor > 0) {
      return { number: `${major}.${minor}`, series: major, remainder: string(match, 3), kind: "dashed" };
    }
  }
  match = keywordNumberedPattern.exec(text);
  if (match) {
    const major = int(match, 1), minor = int(match, 2);
    if (major !== null && minor !== null && minor > 0) {
      return { number: `${major}.${minor}`, series: major, remainder: string(match, 3), kind: "keyword" };
    }
  }
  match = barePattern.exec(text);
  if (match) {
    const value = int(match, 1);
    if (value !== null && value > 0) {
      return { number: `${fallbackSeries}.${value}`, series: null, remainder: string(match, 2), kind: "keyword" };
    }
  }
  match = questionHeadingPattern.exec(text);
  if (match) {
    const value = int(match, 1);
    if (value !== null && value > 0) {
      return { number: `${fallbackSeries}.${value}`, series: null, remainder: string(match, 2), kind: "question" };
    }
  }
  match = numberedPattern.exec(text);
  if (match) {
    const major = int(match, 1), minor = int(match, 2);
    if (major !== null && minor !== null && minor > 0 && major > 0) {
      return { number: `${major}.${minor}`, series: major, remainder: string(match, 3), kind: "numeric" };
    }
  }
  match = singleNumberPattern.exec(text);
  if (match) {
    const value = int(match, 1);
    if (value !== null && value > 0) {
      return { number: `${fallbackSeries}.${value}`, series: null, remainder: string(match, 2), kind: "numeric" };
    }
  }
  return null;
}

// MARK: Énoncés

/// Le texte de chaque exercice : les lignes entre son titre et le suivant,
/// lues dans l'ordre de la page.
///
/// La lecture par la mise en page trouve les numéros mais laisse l'énoncé
/// vide (c'est le modèle de langage qui le résume). Sans texte, une série
/// révisée ne pouvait retrouver ses exercices que par leur numéro — qui
/// est justement ce qui a bougé. Un énoncé vide reçoit ici sa première
/// phrase.
function fillingStatements(detected: DetectedSeries[], lines: PDFLayoutLine[]): DetectedSeries[] {
  /// `(page, y) < (page', y')` : l'ordre lexicographique des tuples Swift.
  const before = (p1: number, y1: number, p2: number, y2: number) => p1 < p2 || (p1 === p2 && y1 < y2);
  const placed = lines.filter((line) => line.verticalPosition !== undefined && !isEmptyLine(line))
    .sort((a, b) => (a.pageIndex === b.pageIndex ? (a.verticalPosition ?? 0) - (b.verticalPosition ?? 0) : a.pageIndex - b.pageIndex));
  if (placed.length === 0) return detected;
  return detected.map((original) => {
    const series: DetectedSeries = { ...original, exercises: original.exercises.map((e) => ({ ...e })) };
    const anchors = original.exercises.map((exercise) =>
      exercise.pageIndex !== undefined && exercise.verticalPosition !== undefined
        ? { page: exercise.pageIndex, y: exercise.verticalPosition }
        : null);
    series.exercises.forEach((exercise, index) => {
      if (exercise.statement !== "") return;
      const start = anchors[index];
      if (!start) return;
      const end = anchors.slice(index + 1).find((anchor) => anchor !== null) ?? null;
      const text = placed.filter((line) => {
        const page = line.pageIndex, y = line.verticalPosition ?? 0;
        return !before(page, y, start.page, start.y - 0.001)
          && (end ? before(page, y, end.page, end.y - 0.001) : true);
      }).map((line) => trimmed(line)).join(" ");
      exercise.statement = firstSentence(text);
    });
    return series;
  });
}

/// « Exercise 5. Adapt the bubble sort… (when the list is sorted). Express… »
/// → « Adapt the bubble sort… (when the list is sorted). »
function firstSentence(body: string): string {
  let text = body;
  const heading = /^\s*(Exercise|Exercice|Exercices?|Problem|Problème|Ex\.?)\s*[\d.]+\s*[.:)]?\s*/iu.exec(text);
  if (heading) text = text.slice(0, heading.index) + text.slice(heading.index + heading[0].length);
  text = trimWhitespaces(text.replace(/\s+/gu, " "));
  const stop = /(?<=[a-z)])\.\s+(?=[A-Z])/u.exec(text);
  if (stop && characters(text.slice(0, stop.index)).length >= 25) {
    text = text.slice(0, stop.index) + ".";
  }
  return characters(text).slice(0, 240).join("");
}

export const SeriesLayoutParser = {
  bonusLookahead,
  exerciseKeywords,
  bodyFontSize,
  bodyIsBold,
  isHeading,
  parse,
  plainNumberedHeadings,
  isReference,
  questionMark,
  questionLabel,
  style,
  topLevelQuestions,
  questionTree: (input: QuestionMark[] | QuestionEvent[]): DetectedSubQuestion[] =>
    (input as Array<QuestionMark | QuestionEvent>).every((item) => "label" in item)
      ? questionTreeOfMarks(input as QuestionMark[])
      : questionTree(input as QuestionEvent[]),
  startsWithTransition,
  leadingTask,
  introListsConditions,
  joinLines,
  shortText,
  isQuestionSequence,
  seriesHeader,
  exerciseMarker,
  fillingStatements,
  firstSentence,
};
