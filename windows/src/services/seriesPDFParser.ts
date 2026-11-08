// Repère les séries et les exercices dans le texte d'un PDF EPFL
// (Polymestre/Services/SeriesPDFParser.swift).
//
// `NSRegularExpression` devient `RegExp` (voir icuRegExp.ts) ; les positions sont des
// indices UTF-16, comme les `NSRange` ; `Character.count` est compté en graphèmes.

import { icuRegExp } from "../domain/icuRegExp.ts";
import { SeriesLayoutParser } from "../domain/seriesLayout.ts";
import { characters } from "../domain/textRepair.ts";
import type { SubQuestionKind } from "../models/enums.ts";
import { newId } from "../models/relations.ts";
import { localizedStandardCompare, trimAll, trimWhitespaces } from "../models/util.ts";

// MARK: Types

/// Une sous-question repérée sous un exercice : « 1. », « 2. », « (a) ».
///
/// Deux niveaux : « 1) » porte ses points « (a) (b) » dans `children`.
export interface DetectedSubQuestion {
  /// L'étiquette telle qu'elle apparaît : « 1 », « a », « ii ». Vide pour une
  /// partie sans numéro (« Ensuite, … »).
  label: string;
  /// L'énoncé court, s'il a pu être lu. Souvent vide : une sous-question est
  /// fréquemment une seule formule.
  text: string;
  kind: SubQuestionKind;
  children: DetectedSubQuestion[];
  /// Identité d'édition, propre à l'écran de relecture : deux parties sans
  /// étiquette doivent rester deux lignes distinctes. Hors de l'égalité.
  id: string;
}

export const DetectedSubQuestion = {
  /// `DetectedSubQuestion(label:text:kind:children:)`.
  make(label: string, o: { text?: string; kind?: SubQuestionKind; children?: DetectedSubQuestion[] } = {}): DetectedSubQuestion {
    return { label, text: o.text ?? "", kind: o.kind ?? "question", children: o.children ?? [], id: newId() };
  },

  /// `==` : l'identité d'édition n'y entre pas.
  equals(a: DetectedSubQuestion, b: DetectedSubQuestion): boolean {
    return a.label === b.label && a.text === b.text && a.kind === b.kind
      && a.children.length === b.children.length
      && a.children.every((child, index) => DetectedSubQuestion.equals(child, b.children[index]));
  },

  /// Les cases réelles : une question à points compte par ses points.
  leafCount(q: DetectedSubQuestion): number {
    return q.children.length === 0 ? 1 : q.children.length;
  },

  /// Arbre lisible pour les tests et le diagnostic : « 1(a,b),2,part ».
  outline(questions: DetectedSubQuestion[]): string {
    return questions.map((question) => {
      const head = question.kind === "part" ? "part" : question.label;
      return question.children.length === 0 ? head : `${head}(${question.children.map((c) => c.label).join(",")})`;
    }).join(",");
  },
};

/// Un exercice repéré dans le texte d'un PDF de série.
export interface DetectedExercise {
  /// Numéro tel qu'il sera créé : « 2.1 ».
  number: string;
  /// Ce qui suit le numéro sur la même ligne, s'il y a quelque chose.
  title: string;
  isBonus: boolean;
  /// Ce que l'exercice demande, en une phrase — lu par le modèle.
  statement: string;
  /// Les questions regroupées sous ce numéro, dans l'ordre du polycopié.
  ///
  /// Un polycopié qui écrit « Calculer : 1. … 2. … » ne propose pas deux
  /// exercices : il en propose un, en deux questions. Les séparer gonfle la
  /// liste et coupe le travail en morceaux qui se rendent ensemble.
  subQuestions: DetectedSubQuestion[];
  /// Le repère était-il sans ambiguïté (« Exercice 3 », « Ex-02-01 ») ?
  ///
  /// Un numéro nu (« 1.2 ») peut être une section de cours ou une ligne de
  /// démonstration : quand l'IA ne le confirme pas, la fusion l'écarte.
  isConfident: boolean;
  /// Où l'exercice commence dans le PDF, pour l'aperçu de la relecture.
  /// Page (0…) et position verticale (0 = haut, 1 = bas).
  pageIndex?: number;
  verticalPosition?: number;
}

export const DetectedExercise = {
  /// `DetectedExercise(number:title:isBonus:…)`.
  make(o: Pick<DetectedExercise, "number" | "title" | "isBonus"> & Partial<DetectedExercise>): DetectedExercise {
    return {
      statement: "", subQuestions: [], isConfident: true,
      ...o,
    };
  },

  /// `id` : le numéro.
  id(e: DetectedExercise): string {
    return e.number;
  },

  hasSubQuestions(e: DetectedExercise): boolean {
    return e.subQuestions.length > 0;
  },

  leafQuestionCount(e: DetectedExercise): number {
    return e.subQuestions.reduce((total, q) => total + DetectedSubQuestion.leafCount(q), 0);
  },
};

/// Une série repérée, avec ses exercices.
export interface DetectedSeries {
  number: number;
  /// Intitulé trouvé après « Série 3 », s'il y en a un.
  title: string;
  exercises: DetectedExercise[];
  /// « b » pour « Série 5b » : deux séries de même numéro (`SeriesIdentity`).
  label?: string;
}

export const DetectedSeries = {
  /// Toute une série « bonus », ce n'est pas une série : c'est une note de
  /// page (« les exercices étoilés sont facultatifs ») lue sous chaque titre,
  /// ou un modèle qui a généralisé. Les 20 exercices de la série 6 d'algèbre
  /// linéaire arrivaient tous en bonus — rien n'était plus à faire.
  withoutBlanketBonus(series: DetectedSeries[]): DetectedSeries[] {
    return series.map((item) => {
      if (!(item.exercises.length >= 3 && item.exercises.every((e) => e.isBonus))) return item;
      return { ...item, exercises: item.exercises.map((e) => ({ ...e, isBonus: false })) };
    });
  },
};

// MARK: Motifs

/// `Ex-02-01:` — le numéro porte la série **et** l'exercice.
///
/// Le titre s'arrête avant l'exercice suivant : l'extraction aplatit la mise en
/// page et colle parfois deux exercices sur une ligne
/// (« Ex-02-08: Ex-02-09: Montrer que… »). Sans la borne, le premier match
/// consommait toute la ligne et le second n'était jamais vu.
const dashed = () => icuRegExp(
  String.raw`\bEx[ .\-]?(\d{1,2})[.\-](\d{1,2})\b[ \t]*[:.\-–—]?[ \t]*([^\n]*?)(?=\s*Ex[ .\-]?\d{1,2}[.\-]\d{1,2}\b|$)`, "gm");

/// « Exercice 1.2 », ou simplement « 1.2 », avec un intitulé facultatif.
const numbered = () => icuRegExp(
  String.raw`^[ \t]*(?:(?:exercices?|exercises?|exo|ex|probl[eè]mes?|problems?|aufgabe|question)[ \t]*\.?[ \t]*(?:n[°o][ \t]*)?)?(\d{1,2})[.\-·](\d{1,2})\b[ \t]*[–—:.\-)]?[ \t]*(.*)$`, "gim");

/// « Exercice 3 » — seul, ou suivi d'un intitulé sur la même ligne.
///
/// `(?!\.\d)` est essentiel : sans lui, « Exercice 3.1 » serait aussi lu comme
/// l'exercice « 3 », et un exercice fantôme apparaîtrait dans la série.
const bare = () => icuRegExp(
  String.raw`^[ \t]*(?:exercices?|exercises?|exo|ex|probl[eè]mes?|problems?|aufgabe|question)[ \t]*\.?[ \t]*(?:n[°o][ \t]*)?(\d{1,2})\b(?!\.\d)[ \t]*[:.\-–—]?[ \t]*(.*)$`, "gim");

/// « Série 3 », « Série n° 3 », « Série 02 (Nombres R) ».
const header = () => icuRegExp(
  String.raw`^[ \t]*s[ée]rie[ \t]*(?:n[°o][ \t]*)?(\d{1,2})\b[ \t]*[–—:.\-]?[ \t]*(.*)$`, "gim");

const bonus = icuRegExp(String.raw`\bbonus\b|\bétoile\b|\bfacultatif\b|\boptionnel\b|\boptional\b|\bfreiwillig\b`, "i");

/// Métadonnées de mise en page EPFL qui se retrouvent collées au titre.
const metadata = icuRegExp(String.raw`\s*(?:Type|Défi|Objectifs?|Rubrique)\s*:`, "i");

/// Un exercice suivant, sur la même ligne (l'extraction aplatit la mise en page).
/// `\s*` et non `\s+` : le séparateur a déjà été consommé par le motif appelant.
const nextExercise = icuRegExp(String.raw`\s*Ex[ .\-]?\d{1,2}[.\-]\d{1,2}\b`);

const keywordLine = /^\s*(exercices?|exercises?|exo|ex|probl[eè]mes?|problems?|aufgabe|question)/u;

// MARK: Outils de chaîne

/// `Int(String)` de Swift : un entier signé en décimal, rien d'autre.
export function swiftInt(text: string): number | null {
  return /^[+-]?\d+$/.test(text) ? Number(text) : null;
}

const lineTerminators = "\n\r\u0085  ";

/// `NSString.lineRange(for:)` : les lignes entières, terminateur compris, qui contiennent la plage.
export function lineRange(text: string, location: number, length: number): { start: number; end: number } {
  let start = location;
  while (start > 0 && !lineTerminators.includes(text[start - 1])) start--;
  // Une plage non vide se termine avec sa dernière lettre ; une plage vide, là où elle est.
  let end = length > 0 ? location + length - 1 : location;
  while (end < text.length && !lineTerminators.includes(text[end])) end++;
  if (end < text.length) {
    end += text[end] === "\r" && text[end + 1] === "\n" ? 2 : 1;
  }
  return { start, end };
}

// MARK: Analyse

/// Repère les séries et les exercices dans le texte d'un PDF EPFL.
///
/// Fonction **pure** : elle ne lit aucun fichier et ne touche à aucun modèle, donc
/// elle se teste sur de vrais extraits de texte sans PDF ni simulateur.
///
/// Trois formats réels sont reconnus, relevés sur des polycopiés de l'EPFL :
///   • `Ex-02-01:` — Analyse 1 inversée, série et exercice dans le numéro ;
///   • `Exercice 3 Type : … Défi : ⋆⋆` — Algèbre linéaire inversée, où le
///     numéro est qualifié par sa série (« Exercice 1 » en Série 2 → « 2.1 ») ;
///   • `1.2` ou `Exercice 1.2` — le format historique du projet.
///
/// La détection ne sera jamais parfaite — un PDF scanné ne contient aucun texte, et
/// l'extraction aplatit la mise en page, collant parfois deux exercices sur une
/// ligne. C'est pourquoi l'import passe **toujours** par un écran de relecture :
/// le parseur propose, l'étudiant·e dispose.
export const SeriesPDFParser = {
  parse,
  majorComponent,
  exerciseTitle,
  looksLikeTitle,
  looksLikeGeneratedTitle,
  containsBonusMarker,
  cleanTitle,
};

function parse(text: string, defaultSeries: number | null = null): DetectedSeries[] {
  const fallback = defaultSeries ?? 1;
  const normalized = normalize(text);

  const headers: { location: number; number: number }[] = [];
  const titles = new Map<number, string>();
  for (const match of normalized.matchAll(header())) {
    const number = swiftInt(match[1]);
    if (number === null) continue;
    headers.push({ location: match.index!, number });
    if (!titles.has(number)) titles.set(number, cleanTitle(match[2]));
  }

  // L'ordre du document compte : c'est lui qui donne l'ordre des exercices.
  // `series` vaut `null` quand le numéro ne dit pas la série (voir plus bas).
  const entries: { location: number; exercise: DetectedExercise; series: number | null }[] = [];
  const seen = new Set<string>();

  /// Ajoute un exercice si son numéro n'a pas déjà été vu.
  const append = (number: string, title: string, context: string, series: number | null, location: number,
    confident = true) => {
    if (seen.has(number)) return;
    seen.add(number);
    entries.push({
      location,
      exercise: DetectedExercise.make({
        number, title: exerciseTitle(title), isBonus: isBonus(context), isConfident: confident,
      }),
      series,
    });
  };
  const lastHeaderBefore = (location: number) => {
    for (let i = headers.length - 1; i >= 0; i--) if (headers[i].location < location) return headers[i].number;
    return undefined;
  };

  // 1. « Ex-02-01: » — série et exercice dans le numéro.
  for (const match of normalized.matchAll(dashed())) {
    const major = swiftInt(match[1]);
    const minor = swiftInt(match[2]);
    if (major === null || minor === null) continue;
    append(`${major}.${minor}`, match[3], lineContext(normalized, match.index!, match[0].length),
      major, match.index!);
  }

  // 2. « 1.2 » ou « Exercice 1.2 ».
  for (const match of normalized.matchAll(numbered())) {
    const number = `${match[1]}.${match[2]}`;
    // Sans mot-clé, « 1.2 » peut aussi être une section ou une valeur :
    // le repère est gardé, mais marqué comme incertain.
    const range = lineRange(normalized, match.index!, match[0].length);
    const line = normalized.slice(range.start, range.end).toLowerCase();
    const hasKeyword = keywordLine.test(line);
    append(number, match[3], lineContext(normalized, match.index!, match[0].length),
      majorComponent(number), match.index!, hasKeyword);
  }

  // 3. « Exercice 3 » — un numéro simple est un numéro d'**exercice**, pas de
  //    série : « Exercice 1 » et « Exercice 2 » appartiennent à la même série.
  //    C'est l'en-tête précédent qui la donne, à défaut la série 1.
  //
  //    Le numéro est **qualifié par sa série** : « Exercice 1 » dans la
  //    Série 2 devient « 2.1 ». Sans ça l'exercice s'appelait « 1 », ce qui
  //    ne correspond ni à la convention EPFL, ni au numéro utilisé par
  //    l'analyse par mise en page, ni à celui que partagent les groupes —
  //    et réimporter le même document par les deux chemins créait des
  //    doublons.
  for (const match of normalized.matchAll(bare())) {
    const value = match[1];
    const resolved = lastHeaderBefore(match.index!) ?? fallback;
    append(`${resolved}.${value}`, match[2], lineContext(normalized, match.index!, match[0].length),
      resolved, match.index!);
  }

  const groups = new Map<number, DetectedExercise[]>();
  for (const entry of [...entries].sort((a, b) => a.location - b.location)) {
    const series = entry.series ?? lastHeaderBefore(entry.location) ?? fallback;
    const list = groups.get(series);
    if (list) list.push(entry.exercise);
    else groups.set(series, [entry.exercise]);
  }

  const result: DetectedSeries[] = [...groups.keys()].sort((a, b) => a - b).map((series) => ({
    number: series,
    title: titles.get(series) ?? "",
    exercises: sortedExercises(groups.get(series) ?? []),
  }));

  // Une série **annoncée** mais dont aucun exercice n'a été reconnu est
  // conservée, avec une liste vide. C'est ce qui rend le parseur robuste à une
  // mise en page inconnue : au lieu d'un import qui ne trouve rien et laisse
  // l'étudiant·e sans recours, la série apparaît dans l'écran de relecture et
  // les exercices s'ajoutent à la main.
  for (const [number, title] of titles) {
    if (!groups.has(number)) result.push({ number, title, exercises: [] });
  }
  return result.sort((a, b) => a.number - b.number);
}

// MARK: Outils

/// Numéro de série d'un numéro d'exercice : « 2.3 » → 2.
function majorComponent(number: string): number | null {
  const first = number.split(".").filter((part) => part !== "")[0];
  return first === undefined ? null : swiftInt(first);
}

function sortedExercises(exercises: DetectedExercise[]): DetectedExercise[] {
  return [...exercises].sort((lhs, rhs) => localizedStandardCompare(lhs.number, rhs.number));
}

/// L'intitulé d'un exercice, ou rien.
///
/// L'extraction d'un PDF aplatit la mise en page : « Exercice 1 solution
/// générale. » n'est presque jamais « l'exercice 1, intitulé *solution
/// générale* » — c'est le numéro suivi de la **première phrase de l'énoncé**.
/// Afficher ça sous l'exercice invente une information, et c'est exactement ce
/// que l'étudiant·e voit de travers dans l'écran de relecture.
///
/// On ne garde donc que ce qui a la forme d'un intitulé. Dans le doute, on
/// préfère **rien** : le numéro suffit à identifier l'exercice, et un titre
/// absent ne trompe personne.
function exerciseTitle(raw: string): string {
  const value = cleanTitle(raw);
  if (value === "") return "";
  return looksLikeTitle(value) ? value : "";
}

/// Les mots qui ouvrent un énoncé, jamais un intitulé.
const statementOpeners = new Set([
  "soit", "soient", "montrer", "démontrer", "calculer", "déterminer", "trouver", "résoudre",
  "prouver", "vérifier", "considérons", "considérer", "on", "étant", "supposons", "écrire",
  "let", "show", "prove", "compute", "determine", "find", "consider", "suppose", "given", "assume",
  "sei", "seien", "zeigen", "berechnen", "bestimmen",
]);

/// Les ouvertures d'une hypothèse : jamais un titre, même court.
const hypothesisOpeners = new Set(["soit", "soient", "let", "sei", "seien", "on", "étant"]);

/// `split(whereSeparator: { $0 == " " || $0 == "'" || $0 == "’" })` : les mots, sans vides.
const wordsOf = (value: string): string[] => value.split(/[ '’]/).filter((word) => word !== "");

/// Un intitulé est court, ne ponctue pas comme une phrase, et commence par une
/// majuscule — un fragment coupé au milieu d'un mot commence par une minuscule.
function looksLikeTitle(raw: string): boolean {
  const value = trimAll(raw);
  if (value === "") return false;
  // Au-delà, c'est une phrase d'énoncé recopiée sur une seule ligne.
  if (!(characters(value).length <= 60)) return false;
  // Ponctuation finale de phrase.
  if (value.endsWith(".") || value.endsWith(";") || value.endsWith(":")) return false;
  // Un fragment de mot (« tions change. »), une suite d'énoncé
  // (« ou contre-exemple. ») ou une énumération (« 1) Si x alors y ») ne
  // commence pas par une majuscule.
  if (!/^[\p{Lu}\p{Lt}]/u.test(value)) return false;
  // Une consigne commence par son verbe ou par « Soit » : c'est la première
  // phrase de l'énoncé, même sans point final (« Soit f une fonction… »).
  const firstWord = (wordsOf(value)[0] ?? "").toLowerCase();
  if (statementOpeners.has(firstWord)) return false;
  // « Ex-03-01 », « Exercice 3 », « Problem 2 » : le numéro, pas un intitulé.
  // Le modèle le renvoie volontiers comme titre quand le PDF n'en a pas.
  const marker = SeriesLayoutParser.exerciseMarker(value, 1);
  if (marker && cleanTitle(marker.remainder) === "") return false;
  return true;
}

/// Un intitulé **proposé par le modèle**, jugé moins sévèrement.
///
/// La consigne lui demande de nommer la tâche en 2 à 6 mots : « Calculer les
/// sommes » est alors un bon titre, et le PDF lui-même en donne qui
/// commencent par un verbe (« Find the error: Sliding block »). Le filtre
/// des lignes de PDF les effaçait. On ne rejette ici que l'énoncé recopié :
/// long, ponctué comme une phrase, ouvert par « Soit » / « Let », ou réduit
/// au numéro.
function looksLikeGeneratedTitle(raw: string): boolean {
  const value = trimAll(raw);
  if (value === "" || !(characters(value).length <= 60)) return false;
  if (value.endsWith(".") || value.endsWith(";") || value.endsWith(":")) return false;
  const words = wordsOf(value);
  if (!(words.length <= 8)) return false;
  const firstWord = (words[0] ?? "").toLowerCase();
  if (hypothesisOpeners.has(firstWord)) return false;
  const marker = SeriesLayoutParser.exerciseMarker(value, 1);
  if (marker && cleanTitle(marker.remainder) === "") return false;
  return true;
}

function normalize(text: string): string {
  return text.split(" ").join(" ").split("\r\n").join("\n").split("\r").join("\n");
}

/// La ligne du numéro **et la suivante** : « (bonus) » ou « facultatif » est
/// souvent en dessous.
function lineContext(text: string, location: number, length: number): string {
  const range = lineRange(text, location, length);
  const after = range.end;
  if (!(after < text.length)) return text.slice(range.start, range.end);
  const next = lineRange(text, after, 0);
  return text.slice(range.start, range.end) + "\n" + text.slice(next.start, next.end);
}

/// Vrai si le texte contient une mention de bonus, d'étoile ou de caractère
/// facultatif. Exposé pour que l'analyse par mise en page applique exactement
/// les mêmes règles que l'analyse par motifs.
function containsBonusMarker(text: string): boolean {
  return isBonus(text);
}

function isBonus(context: string): boolean {
  return bonus.test(context);
}

/// Nettoie un titre : séparateurs de tête, parenthèses d'en-tête, métadonnées
/// EPFL, et l'exercice suivant quand l'extraction les a collés.
function cleanTitle(raw: string): string {
  let value = trimAll(raw);

  // « (Nombres R) » → « Nombres R »
  if (value.startsWith("(") && value.endsWith(")") && characters(value).length > 2) {
    value = characters(value).slice(1, -1).join("");
  }
  // Retirer les séparateurs de tête.
  for (;;) {
    const first = characters(value)[0];
    if (first === undefined || !"–—:-.·)»".includes(first)) break;
    value = trimWhitespaces(value.slice(first.length));
  }

  // Couper avant l'exercice suivant collé sur la même ligne.
  const next = nextExercise.exec(value);
  if (next) value = value.slice(0, next.index);
  // Couper avant les métadonnées de mise en page (« Type : Technique »).
  const meta = metadata.exec(value);
  if (meta) value = value.slice(0, meta.index);
  return trimAll(value);
}
