// La partie **pure** de l'extraction assistée par un modèle de langage :
// préparer le texte, relire la réponse JSON, fusionner avec l'heuristique
// (Polymestre/Domain/SeriesAIParsing.swift).
//
// Rien ici ne touche au réseau ni au modèle : tout est testable sur des chaînes.

import { SeriesIdentity } from "./seriesIdentity.ts";
import { DetectedSeries, DetectedSubQuestion, SeriesPDFParser } from "../services/seriesPDFParser.ts";
import type { DetectedExercise } from "../services/seriesPDFParser.ts";
import { characters, isNumber } from "./textRepair.ts";
import { icuRegExp } from "./icuRegExp.ts";
import { SeriesLayoutParser, type PDFLayoutLine } from "./seriesLayout.ts";
import { SeriesDocumentInference } from "./seriesDocumentInference.ts";
import { localizedStandardCompare, trimAll, trimWhitespaces } from "../models/util.ts";

// MARK: Préparation

/// Limite de texte envoyée au modèle. Le modèle embarqué a un contexte court ;
/// un polycopié de dix pages le dépasse largement.
export const maxCharacters = 7_000;

/// Réduit le texte d'un PDF à ce qui peut porter une structure : les lignes qui
/// ressemblent à un en-tête de série ou d'exercice, avec leur voisine
/// suivante (où vit souvent l'intitulé). Le reste — énoncés, formules,
/// consignes — n'apprend rien au modèle et lui coûte son contexte.
export function prepare(text: string): string {
  const cleaned = text.split("\u{00A0}").join(" ").split("\r").join("");
  if (characters(cleaned).length <= maxCharacters) return cleaned;

  const lines = cleaned.split("\n");
  const keep = new Set<number>();
  lines.forEach((line, index) => {
    if (!looksStructural(line)) return;
    keep.add(index);
    if (index + 1 < lines.length) keep.add(index + 1);
  });
  let result = [...keep].sort((a, b) => a - b).map((index) => trimWhitespaces(lines[index]))
    .filter((line) => line !== "")
    .join("\n");
  if (characters(result).length > maxCharacters) {
    result = characters(result).slice(0, maxCharacters).join("");
  }
  return result === "" ? characters(cleaned).slice(0, maxCharacters).join("") : result;
}

/// Limite du texte **mis en forme** envoyé à la fonction partagée, qui coupe
/// au-delà de 6 000 caractères. Couper nous-mêmes, en gardant la structure de
/// tout le document, vaut mieux que de laisser le serveur tronquer la fin :
/// c'est ce qui faisait disparaître les derniers exercices, un import sur deux.
export const layoutBudget = 5_800;

interface LayoutEntry {
  text: string;
  structural: boolean;
  page: number;
}

/// Le texte d'un PDF **avec sa mise en page**, pour le modèle.
///
/// Le modèle recevait un texte aplati alors que sa consigne lui demande de
/// juger l'indentation : il devinait. Ici chaque titre est préfixé de « # »,
/// chaque ligne garde son retrait (deux espaces par cran), et les pages sont
/// séparées. Les lignes de corps sont raccourcies avant les lignes de
/// structure, pour que **tout** le document tienne dans le budget.
export function prepareLayout(lines: PDFLayoutLine[], seriesHint: number | null, language: string | null = null): string {
  const body = SeriesLayoutParser.bodyFontSize(lines);
  const boldBody = SeriesLayoutParser.bodyIsBold(lines);
  const indents = lines.filter((line) => !isEmptyLine(line) && line.indent > 0).map((line) => line.indent);
  const margin = indents.length === 0 ? 0 : Math.min(...indents);

  const entries: LayoutEntry[] = [];
  // Pieds et en-têtes de page répétés (« Compilation : … », numéro de page)
  // n'apprennent rien au modèle et mangent son budget.
  const pagesByText = new Map<string, Set<number>>();
  for (const line of lines) {
    if (isEmptyLine(line)) continue;
    const key = trimmed(line);
    const pages = pagesByText.get(key) ?? new Set<number>();
    pages.add(line.pageIndex);
    pagesByText.set(key, pages);
  }
  for (const line of lines) {
    if (isEmptyLine(line)) continue;
    const text = trimmed(line);
    const isPageNumber = characters(text).length <= 3 && [...characters(text)].every((c) => isNumber(c))
      && isFooterOrHeader(line, lines);
    // Une ligne répétée sur plusieurs pages est un pied ou un en-tête — sauf
    // si elle porte le numéro de série, qui reste un repère utile.
    const isRunning = (pagesByText.get(text)?.size ?? 0) >= 2
      && isFooterOrHeader(line, lines)
      && SeriesDocumentInference.seriesNumberInDocument([line]) === null;
    if (isRunning || isPageNumber) continue;
    const heading = SeriesLayoutParser.isHeading(line, body, boldBody)
      || (!boldBody && line.startsBold);
    // Arrondi par défaut, avec une tolérance : 104,6 et 105,9 pt sont le
    // même retrait. `rounded()` les mettait de part et d'autre d'un cran.
    const level = Math.min(8, Math.max(0, Math.trunc((line.indent - margin + 4) / 14)));
    const indent = "  ".repeat(level);
    const cleaned = text.split("\u{00A0}").join(" ");
    const structural = heading || looksStructural(cleaned)
      || SeriesLayoutParser.questionLabel(cleaned, true) !== null;
    entries.push({
      text: indent + (heading ? "# " : "") + cleaned,
      structural,
      page: line.pageIndex,
    });
  }

  const render = (bodyLimit: number | null): string => {
    const output: string[] = [];
    if (seriesHint !== null) output.push(`[Indice : ce document semble être la série ${seriesHint}]`);
    const hint = SeriesDocumentInference.languageHint(language);
    if (hint !== null) output.push(hint);
    let page = -1;
    let bodyRun = 0;
    for (const entry of entries) {
      if (entry.page !== page) {
        page = entry.page;
        output.push(`--- page ${page + 1} ---`);
      }
      if (entry.structural) {
        output.push(entry.text);
        bodyRun = 0;
        continue;
      }
      if (bodyLimit === null) {
        output.push(entry.text);
        continue;
      }
      // Au plus deux lignes d'énoncé par bloc : de quoi voir « Calculer : »
      // ou « (facultatif) », pas de quoi noyer la structure.
      bodyRun += 1;
      if (bodyLimit === 0 || bodyRun > 2) continue;
      output.push(characters(entry.text).length > bodyLimit
        ? characters(entry.text).slice(0, bodyLimit).join("") + "…"
        : entry.text);
    }
    return output.join("\n");
  };

  for (const limit of [null, 90, 50, 0] as (number | null)[]) {
    const rendered = render(limit);
    if (characters(rendered).length <= layoutBudget) return rendered;
  }
  return characters(render(0)).slice(0, layoutBudget).join("");
}

/// Une ligne isolée tout en haut ou tout en bas de sa page.
function isFooterOrHeader(line: PDFLayoutLine, lines: PDFLayoutLine[]): boolean {
  if (line.verticalPosition !== undefined) return line.verticalPosition < 0.1 || line.verticalPosition > 0.9;
  const page = lines.filter((candidate) => candidate.pageIndex === line.pageIndex && !isEmptyLine(candidate));
  const index = page.indexOf(line);
  if (index < 0) return false;
  return index < 2 || index >= page.length - 2;
}

const trimmed = (line: PDFLayoutLine): string => trimAll(line.text);
const isEmptyLine = (line: PDFLayoutLine): boolean => trimAll(line.text) === "";

const structural = icuRegExp(
  String.raw`\b(s[ée]ries?|exercices?|exercises?|exo|ex[ .\-]?\d|probl[eè]mes?|problems?|aufgabe|question|bonus|facultatif|optionnel|optional)\b|^\s*\d{1,2}[.\-·]\d{1,2}\b`, "i");

export function looksStructural(line: string): boolean {
  return structural.test(line);
}

// MARK: Consigne

/// La consigne donnée au modèle. Elle demande du JSON strict et interdit
/// d'inventer : un numéro absent du texte ne doit pas apparaître.
export const instructions = `Tu extrais la structure d'une série d'exercices d'un cours EPFL à partir du texte brut d'un PDF.
Réponds UNIQUEMENT avec un objet JSON de la forme :
{"series":[{"number":3,"title":"Récurrences","exercises":[{"number":"3.1","title":"Tri fusion","isBonus":false,"questions":[{"label":"1","text":"Montrer la borne"},{"label":"2","text":"Cas d'égalité"}]}]}]}
Format du texte : « # » en début de ligne marque un titre du PDF ; les espaces de tête reproduisent le retrait (une question est décalée sous son exercice) ; « --- page N --- » sépare les pages ; « [Indice : … série N] » donne le numéro de série à utiliser.
Langue : écris « title » et le texte des questions dans la langue du PDF — « [Langue du document : …] » la donne quand elle est connue. Ne traduis JAMAIS : un PDF anglais donne des titres anglais.
Questions en liste à puces (•, –, ◦) sans étiquette : ce sont des questions, numérote-les « 1 », « 2 », « 3 » dans l'ordre ; des puces sous une question numérotée sont ses points (« a », « b »). Une liste de conditions ou d'hypothèses en puces n'est pas une liste de questions.
Exercices et questions : « exercises » contient les EXERCICES, pas les questions. Un exercice peut poser plusieurs questions — elles vont dans « questions ». Si le PDF introduit une liste par une phrase suivie de deux points (« Calculer : », « Déterminer : ») puis numérote 1., 2., ce sont les questions d'un même exercice. Si chaque numéro est une consigne autonome, ce sont des exercices distincts.
Numérotation : « number » de la série est un entier ; « label » est ce qui distingue deux séries de même numéro, sinon "" (« Série 02a » → number 2, label "a" ; « Série 5 — mardi » → label "mardi" ; « Série 5, partie 2 » → label "partie 2") ; le numéro d'un exercice s'écrit toujours « série.exercice » (« 3.2 »), même si le PDF recommence à 1 dans chaque section ; un exercice sans numéro imprimé (titré « Exercice » seul, ou seulement par son intitulé) prend le numéro suivant dans l'ordre du document. N'invente aucun exercice absent du texte.
Titre : « title » est TOUJOURS rempli, jamais vide. Reprends l'intitulé court s'il existe ; sinon écris toi-même 2 à 6 mots qui nomment la tâche, en t'appuyant sur le titre de la section ou sur l'objet de l'exercice. Ne recopie jamais l'énoncé complet.
« isBonus » vaut true si l'exercice est marqué bonus, facultatif, optionnel ou étoilé. S'il n'y a aucune série, renvoie {"series":[]}.`;

// MARK: Lecture de la réponse

/// Une valeur que le modèle peut écrire de plusieurs façons.
///
/// Le JSON d'un modèle de langage **n'est pas un contrat** : il écrit `2` là où
/// on attend `"2"`, `"02a"` là où on attend un entier, `"oui"` là où on attend
/// un booléen. Un décodeur strict rejette alors **toute** la réponse pour un
/// seul champ — et l'utilisateur voit une extraction vide sans savoir pourquoi.
/// On lit donc souplement, et on ne refuse que ce qui n'a vraiment aucun sens.
const Flexible = {
  int(value: unknown): number | null {
    if (typeof value === "number" && Number.isFinite(value)) return Math.trunc(value);
    if (typeof value === "string") return leadingInt(value);
    return null;
  },

  string(value: unknown): string | null {
    if (typeof value === "string") return value;
    if (typeof value === "number" && Number.isFinite(value)) {
      return Number.isInteger(value) ? String(value) : swiftDoubleString(value);
    }
    return null;
  },

  bool(value: unknown): boolean | null {
    if (typeof value === "boolean") return value;
    if (typeof value !== "string") return null;
    switch (trimWhitespaces(value).toLowerCase()) {
      case "true": case "oui": case "yes": case "vrai": case "1": return true;
      case "false": case "non": case "no": case "faux": case "0": return false;
      default: return null;
    }
  },
};

/// `String(Double)` de Swift : un entier s'écrit avec « .0 ».
function swiftDoubleString(value: number): string {
  if (Number.isInteger(value)) return `${value}.0`;
  return String(value);
}

/// Le premier entier d'un texte : « 02a » → 2, « Série 3 » → 3.
function leadingInt(text: string): number | null {
  const chars = characters(text);
  let start = 0;
  while (start < chars.length && !isNumber(chars[start])) start++;
  let end = start;
  while (end < chars.length && isNumber(chars[end])) end++;
  const digits = chars.slice(start, end).join("");
  if (digits === "" || !/^[0-9]+$/.test(digits)) return null;
  return Number(digits);
}

interface RawQuestion {
  label: string | null;
  text: string | null;
  kind: string | null;
  children: RawQuestion[] | null;
}

interface RawExercise {
  number: string | null;
  title: string | null;
  isBonus: boolean | null;
  questions: RawQuestion[] | null;
  page: number | null;
  statement: string | null;
}

interface RawSeries {
  number: number | null;
  label: string | null;
  title: string | null;
  exercises: RawExercise[];
}

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value);

/// Une question, écrite de deux façons selon le modèle.
function decodeQuestion(value: unknown): RawQuestion | null {
  if (typeof value === "string") return { label: value, text: "", kind: null, children: null };
  if (!isRecord(value)) return null;
  const children = decodeQuestions(value.children)
    ?? decodeQuestions(value.parts)
    ?? decodeQuestions(value.questions);
  return {
    label: Flexible.string(value.label),
    text: Flexible.string(value.text),
    kind: Flexible.string(value.kind),
    children,
  };
}

/// Une liste de questions, ou `null` si elle est absente ou d'un type inattendu
/// (le `try?` Swift : on essaie la clé suivante).
function decodeQuestions(value: unknown): RawQuestion[] | null {
  if (!Array.isArray(value)) return null;
  const result: RawQuestion[] = [];
  for (const item of value) {
    const question = decodeQuestion(item);
    if (question === null) return null;
    result.push(question);
  }
  return result;
}

function decodeExercise(value: unknown): RawExercise | null {
  if (!isRecord(value)) return null;
  return {
    number: Flexible.string(value.number),
    title: Flexible.string(value.title),
    isBonus: Flexible.bool(value.isBonus),
    page: Flexible.int(value.page),
    statement: Flexible.string(value.statement),
    questions: decodeQuestions(value.parts) ?? decodeQuestions(value.questions) ?? [],
  };
}

function decodeSeries(value: unknown): RawSeries | null {
  if (!isRecord(value)) return null;
  let exercises: RawExercise[] = [];
  if (Array.isArray(value.exercises)) {
    const decoded: RawExercise[] = [];
    let valid = true;
    for (const item of value.exercises) {
      const exercise = decodeExercise(item);
      if (exercise === null) { valid = false; break; }
      decoded.push(exercise);
    }
    // Une liste absente ou d'un type inattendu ne doit pas faire perdre la
    // série : on la remplace par une liste vide.
    if (valid) exercises = decoded;
  }
  // « number » écrit « 5b » malgré la consigne : le numéro et l'étiquette.
  let label = Flexible.string(value.label);
  if (typeof value.number === "string" && (label ?? "") === "") {
    const m = value.number.match(/^\s*0*\d{1,2}(.*)$/);
    const rest = m ? m[1].replace(/^[\s\-.()]+|[\s\-.()]+$/g, "") : "";
    if (rest !== "") label = rest;
  }
  return {
    number: Flexible.int(value.number),
    label,
    title: Flexible.string(value.title),
    exercises,
  };
}

/// Lit la réponse du modèle, tolérante aux bavardages autour du JSON.
///
/// Un modèle répond parfois « Voici le JSON : {…} » ou entoure de ```json.
/// On isole le premier objet, et on refuse tout ce qui n'a pas la forme
/// attendue plutôt que de deviner.
export function parse(raw: string): DetectedSeries[] {
  const start = raw.indexOf("{");
  const end = raw.lastIndexOf("}");
  if (start < 0 || end < 0 || start >= end) return [];
  const json = raw.slice(start, end + 1);
  let payload: unknown;
  try {
    payload = JSON.parse(json);
  } catch {
    return [];
  }
  if (!isRecord(payload)) return [];
  let series: RawSeries[] | null = [];
  if (Array.isArray(payload.series)) {
    const decoded: RawSeries[] = [];
    let valid = true;
    for (const item of payload.series) {
      const itemSeries = decodeSeries(item);
      if (itemSeries === null) { valid = false; break; }
      decoded.push(itemSeries);
    }
    series = valid ? decoded : [];
  }
  return normalize(series ?? []);
}

const byKey = (a: DetectedSeries, b: DetectedSeries) =>
  SeriesIdentity.compare(SeriesIdentity.key(a.number, a.label ?? ""), SeriesIdentity.key(b.number, b.label ?? ""));

function normalize(payload: RawSeries[]): DetectedSeries[] {
  const result: DetectedSeries[] = [];
  for (const series of payload) {
    const number = series.number;
    if (number === null || !(number >= 1 && number <= 60)) continue;
    const label = SeriesIdentity.normalized(series.label ?? "");
    const seen = new Set<string>();
    const exercises: DetectedExercise[] = [];
    let nextIndex = 1;
    for (const exercise of series.exercises) {
      // Un exercice sans numéro n'est pas jeté : beaucoup de polycopiés
      // numérotent leurs exercices 1, 2, 3 **dans chaque section**, et
      // certains n'en donnent aucun. On prend alors le premier numéro
      // libre, ce qui laisse à l'étudiant·e une ligne à cocher plutôt
      // qu'un exercice invisible.
      let candidate = normalizeNumber(exercise.number, number);
      if (candidate === null) {
        while (seen.has(`${number}.${nextIndex}`)) nextIndex += 1;
        candidate = `${number}.${nextIndex}`;
      }
      if (candidate === null || seen.has(candidate)) continue;
      seen.add(candidate);
      nextIndex += 1;
      const title = trimAll(exercise.title ?? "");
      exercises.push({
        number: candidate,
        title: SeriesPDFParser.looksLikeGeneratedTitle(title) ? title : "",
        isBonus: exercise.isBonus ?? false,
        statement: trimAll(exercise.statement ?? ""),
        subQuestions: subQuestions(exercise.questions),
        isConfident: true,
        pageIndex: exercise.page === null ? undefined : Math.max(0, exercise.page - 1),
      });
    }
    exercises.sort((a, b) => localizedStandardCompare(a.number, b.number));
    const existing = result.findIndex((item) => item.number === number && (item.label ?? "") === label);
    if (existing >= 0) {
      const known = new Set(result[existing].exercises.map((exercise) => exercise.number));
      result[existing].exercises = [
        ...result[existing].exercises,
        ...exercises.filter((exercise) => !known.has(exercise.number)),
      ];
    } else {
      result.push({
        number,
        label,
        title: trimAll(series.title ?? ""),
        exercises,
      });
    }
  }
  return result.sort(byKey);
}

/// Les sous-questions d'un exercice, étiquetées et dédoublonnées, sur deux
/// niveaux au plus.
///
/// Une sous-question sans étiquette reçoit son rang — sauf une **partie**
/// (`"kind":"part"`), qui n'a pas de numéro dans le polycopié et n'en reçoit pas.
function subQuestions(raw: RawQuestion[] | null, depth = 0): DetectedSubQuestion[] {
  if (raw === null) return [];
  const hasTree = raw.some((question) => (question.children?.length ?? 0) > 0 || question.kind === "part");
  // Une seule « question », c'est l'exercice lui-même : pas de case à part.
  if (!(raw.length >= 2 || hasTree)) return [];
  const seen = new Set<string>();
  const result: DetectedSubQuestion[] = [];
  let rank = 0;
  for (const question of raw) {
    const isPart = question.kind?.toLowerCase() === "part";
    const label = trimWhitespaces(trimAll(question.label ?? ""))
      .replace(/^[().:]+/, "").replace(/[().:]+$/, "");
    const text = trimAll(question.text ?? "");
    if (isPart) {
      if (text === "") continue;
      result.push(DetectedSubQuestion.make("", { text, kind: "part" }));
      continue;
    }
    rank += 1;
    const resolved = label === "" ? String(rank) : label;
    if (seen.has(resolved)) continue;
    seen.add(resolved);
    const children = depth === 0
      ? subQuestions(question.children, 1).filter((child) => child.kind === "question")
      : [];
    result.push(DetectedSubQuestion.make(resolved, { text, children: children.length >= 2 ? children : [] }));
  }
  // Des parties seules, sans question numérotée : c'est l'exercice lui-même.
  return result.some((question) => question.kind === "question") ? result : [];
}

/// « 2 » dans la série 3 → « 3.2 » ; « 3.2 » reste ; « Ex 3.2 » → « 3.2 » ;
/// « Ex-04-03 » et « 4-3 » → « 4.3 ».
///
/// Tout ce qui sépare deux groupes de chiffres est un séparateur. Ne garder
/// que les chiffres et les points collait « 4-3 » en « 43 », rangé en 4.43.
export function normalizeNumber(raw: string | null, series: number): string | null {
  if (raw === null) return null;
  const parts = raw.split(/[^\x00-\x7F]|[^0-9]/u).filter((part) => part !== "");
  if (parts.length === 0) return null;
  switch (parts.length) {
    case 1: {
      const value = Number(parts[0]);
      return value >= 1 && value <= 99 ? `${series}.${value}` : null;
    }
    case 2: {
      const major = Number(parts[0]);
      const minor = Number(parts[1]);
      if (!(minor >= 1 && minor <= 99)) return null;
      // Le modèle peut avoir mis le numéro dans une autre série : on suit la
      // série annoncée par l'objet parent, qui fait foi.
      return `${major === series ? major : series}.${minor}`;
    }
    default:
      return null;
  }
}

// MARK: Fusion

/// Fusionne l'heuristique et la réponse du modèle.
///
/// Trois règles, dans l'ordre :
///   1. **Un seul numéro de série.** Quand chaque côté ne voit qu'une série
///      mais pas la même — l'heuristique rangeait tout en série 1 faute
///      d'en-tête, le modèle lisait 4 —, les deux sont ramenés au numéro que le
///      document annonce (`preferredSeries`), à défaut à celui du modèle.
///      Sans ça, l'écran proposait deux séries pour un seul PDF.
///   2. **Le modèle complète**, il n'efface pas ce qui est sûr : un exercice
///      repéré par un mot-clé (« Exercice 3 ») reste, même oublié par le modèle.
///   3. **Un repère douteux doit être confirmé.** Un numéro nu (« 1.5 ») que
///      le modèle ne retrouve pas est écarté : c'était, le plus souvent, une
///      ligne de démonstration.
export function merge(heuristicInput: DetectedSeries[], aiInput: DetectedSeries[],
  preferredSeries: number | null = null, aiReadsLayout = false): DetectedSeries[] {
  if (aiInput.length === 0 || !aiInput.some((series) => series.exercises.length > 0)) return heuristicInput;

  let heuristic = heuristicInput.map(cloneSeries);
  let ai = aiInput.map(cloneSeries);

  if (heuristic.length <= 1 && ai.length === 1) {
    const target = preferredSeries ?? ai[0].number;
    // L'étiquette lue d'un côté vaut pour les deux (« Série 5b » en tête).
    const label = (heuristic[0]?.label ?? "") !== "" ? heuristic[0].label! : (ai[0].label ?? "");
    ai = ai.map((series) => ({ ...renumber(series, target), label }));
    heuristic = heuristic.map((series) => ({ ...renumber(series, target), label }));
  } else if (preferredSeries !== null && heuristic.length === 1 && ai.length > 1
    && !ai.some((series) => series.number === heuristic[0].number)) {
    heuristic = heuristic.map((series) => renumber(series, preferredSeries));
  }

  const result = ai;
  const aiSeriesNumbers = new Set(ai.map((series) => series.number));
  for (const series of heuristic) {
    // La même série : même numéro et même étiquette — ou une étiquette vue
    // d'un seul côté, quand ce numéro n'en désigne qu'une.
    const own = series.label ?? "";
    const sameNumber = result.map((item, i) => ({ item, i })).filter(({ item }) => item.number === series.number);
    const exact = sameNumber.find(({ item }) => (item.label ?? "") === own);
    const found = exact ?? (sameNumber.length === 1 && (own === "" || (sameNumber[0].item.label ?? "") === "") ? sameNumber[0] : undefined);
    if (found && (found.item.label ?? "") === "") found.item.label = own;
    const index = found?.i ?? -1;
    if (index < 0) {
      // Série que le modèle n'a pas vue : on la garde si elle repose sur
      // des repères sûrs.
      const kept = series.exercises.filter((exercise) => exercise.isConfident);
      if (kept.length > 0
        || (series.exercises.length === 0 && !aiSeriesNumbers.has(series.number) && series.title !== "")) {
        result.push({ number: series.number, label: own, title: series.title, exercises: kept });
      }
      continue;
    }
    if (result[index].title === "" && series.title !== "") {
      result[index].title = series.title;
    }
    // Une numérotation **complète** lue sur des repères sûrs (« Ex-04-01 »…
    // « Ex-04-11 », ou 1…6 sur la marge) fait foi : un exercice que le
    // modèle ajoute en dehors est une question promue ou un numéro inventé.
    if (isCompleteSkeleton(series.exercises)) {
      const known = new Set(series.exercises.map((exercise) => exercise.number));
      result[index].exercises = result[index].exercises.filter((exercise) => known.has(exercise.number));
    }
    const selectiveBonus = series.exercises.filter((exercise) => exercise.isBonus).length * 2 < series.exercises.length;
    for (const exercise of series.exercises) {
      const existing = result[index].exercises.findIndex((item) => item.number === exercise.number);
      if (existing >= 0) {
        const merged = { ...result[index].exercises[existing] };
        // L'intitulé **imprimé** dans le PDF l'emporte sur celui que le
        // modèle compose : un modèle qui décale ses exercices d'un cran
        // donnait à 4.3 le titre de 4.4, et rien ne le corrigeait.
        if (exercise.title !== "" && exercise.isConfident) merged.title = exercise.title;
        if (merged.title === "") merged.title = exercise.title;
        if (merged.statement === "") merged.statement = exercise.statement;
        // Le bonus lu localement ne compte que s'il **distingue** :
        // une mention sous un ou deux exercices. Quand il en marque la
        // plupart, c'est une note de page (« facultatif » à moins
        // de douze lignes de chaque titre) : le modèle décide.
        if (exercise.isBonus && selectiveBonus) merged.isBonus = true;
        merged.isConfident = true;
        // Les sous-questions ne s'additionnent pas : c'est le même
        // exercice, décrit deux fois. Un modèle de **texte** se trompe
        // sur les listes en deux colonnes : la lecture de la mise en
        // page l'emporte alors quand elle a trouvé quelque chose. Un
        // modèle qui **voit** les pages (`aiReadsLayout`) lit les
        // colonnes, les points imbriqués et les formules : il l'emporte,
        // et la lecture locale ne comble que son silence.
        if (aiReadsLayout) {
          if (merged.subQuestions.length === 0 || missesQuestions(merged.subQuestions, exercise.subQuestions)) {
            // Le modèle voit les pages, mais un modèle de repli
            // (Qwen) saute parfois une colonne : 3 questions là où
            // la page en porte 6. La lecture locale les a toutes.
            merged.subQuestions = withTexts(exercise.subQuestions, merged.subQuestions);
          } else if (!merged.subQuestions.some((question) => question.kind === "part")) {
            // Le modèle voit les questions, mais oublie parfois la
            // consigne sans numéro (« Calculer lim aₙ. Ensuite… ») que
            // la lecture locale a trouvée : on la remet à sa place.
            const local = exercise.subQuestions;
            const leading: DetectedSubQuestion[] = [];
            for (const question of local) {
              if (question.kind !== "part") break;
              leading.push(question);
            }
            const trailing: DetectedSubQuestion[] = [];
            for (let at = local.length - 1; at >= 0; at--) {
              if (local[at].kind !== "part") break;
              trailing.unshift(local[at]);
            }
            if (leading.length < local.length) {
              merged.subQuestions = [...leading, ...merged.subQuestions, ...trailing];
            }
          }
        } else if (exercise.subQuestions.length > 0) {
          merged.subQuestions = exercise.subQuestions;
        }
        // La position vient de la mise en page lue localement : page et
        // hauteur vont ensemble, le modèle ne donne que la page.
        if (exercise.verticalPosition !== undefined) {
          merged.pageIndex = exercise.pageIndex;
          merged.verticalPosition = exercise.verticalPosition;
        } else if (merged.pageIndex === undefined) {
          merged.pageIndex = exercise.pageIndex;
        }
        result[index].exercises[existing] = merged;
      } else if (exercise.isConfident) {
        result[index].exercises.push(exercise);
      }
    }
    result[index].exercises.sort((a, b) => localizedStandardCompare(a.number, b.number));
  }
  return DetectedSeries.withoutBlanketBonus(result.sort(byKey));
}

/// Des exercices numérotés 1…n sans trou, tous sur des repères sûrs.
export function isCompleteSkeleton(exercises: DetectedExercise[]): boolean {
  if (!(exercises.length >= 2 && exercises.every((exercise) => exercise.isConfident))) return false;
  const minors = exercises
    .map((exercise) => { const parts = exercise.number.split("."); return parts[parts.length - 1]; })
    .filter((minor): minor is string => minor !== undefined)
    .map((minor) => Number(minor))
    .sort((a, b) => a - b);
  if (minors.some((minor) => !Number.isInteger(minor))) return false;
  return minors.length === exercises.length && minors.every((minor, index) => minor === index + 1);
}

/// Le modèle a-t-il **perdu** des questions que la lecture locale a trouvées ?
///
/// Seulement quand la liste locale est une suite propre (1…n, a…) et que
/// celle du modèle en est un sous-ensemble strict : ailleurs — étiquettes
/// différentes, points imbriqués — le modèle garde la main.
export function missesQuestions(seen: DetectedSubQuestion[], local: DetectedSubQuestion[]): boolean {
  const seenLabels = seen.filter((question) => question.kind === "question").map((question) => question.label);
  const localLabels = local.filter((question) => question.kind === "question").map((question) => question.label);
  if (!SeriesLayoutParser.isQuestionSequence(localLabels)) return false;
  if (!(localLabels.length > seenLabels.length)) return false;
  if (new Set(localLabels).size !== localLabels.length) return false;
  const localSet = new Set(localLabels);
  return seenLabels.every((label) => localSet.has(label));
}

/// La structure locale, avec les énoncés — et leurs formules — lus par le
/// modèle là où les étiquettes concordent.
export function withTexts(local: DetectedSubQuestion[], seen: DetectedSubQuestion[]): DetectedSubQuestion[] {
  const byLabel = new Map<string, DetectedSubQuestion>();
  for (const question of seen) {
    if (question.kind !== "question" || byLabel.has(question.label)) continue;
    byLabel.set(question.label, question);
  }
  return local.map((question) => {
    const match = question.kind === "question" ? byLabel.get(question.label) : undefined;
    if (match === undefined) return question;
    const copy = { ...question };
    if (match.text !== "") copy.text = match.text;
    if (match.children.length > 0) copy.children = match.children;
    return copy;
  });
}

/// La même série sous un autre numéro : « 1.3 » devient « 4.3 ».
export function renumber(series: DetectedSeries, number: number): DetectedSeries {
  if (series.number === number) return series;
  return {
    number,
    label: series.label,
    title: series.title,
    exercises: series.exercises.map((exercise) => {
      const parts = exercise.number.split(".");
      const minor = parts[parts.length - 1] ?? exercise.number;
      return { ...exercise, number: `${number}.${minor}` };
    }),
  };
}

function cloneSeries(series: DetectedSeries): DetectedSeries {
  return {
    number: series.number,
    label: series.label,
    title: series.title,
    exercises: series.exercises.map((exercise) => ({ ...exercise, subQuestions: [...exercise.subQuestions] })),
  };
}

export const SeriesAIParsing = {
  maxCharacters,
  layoutBudget,
  instructions,
  prepare,
  prepareLayout,
  looksStructural,
  parse,
  normalizeNumber,
  merge,
  isCompleteSkeleton,
  missesQuestions,
  withTexts,
  renumber,
};
