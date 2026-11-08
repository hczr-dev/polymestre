// Utilitaires de dates, semaines et formats (Polymestre/Domain/DateUtils.swift).
//
// `Calendar.current` devient l'heure locale de la machine ; les semaines sont celles
// d'ISO 8601 (lundi d'abord), comme `startOfWeek` côté Swift. Les tests tournent à
// Europe/Zurich (tests/setup.ts), comme Validation/main.swift.

import { EPFLCalendarSnapshot } from "./epflCalendarSnapshot.ts";
import { getPreferredLanguage } from "./plural.ts";
import type { TermSeason } from "../models/enums.ts";

/** Ce que `DateUtils` demande à un semestre (`AcademicTerm`) : évite l'import circulaire. */
export interface TermLike {
  startDate: Date;
  totalWeeks: number;
}

const DAY_MS = 86_400_000;

// MARK: Parsing

const isoFull = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(\.\d+)?(Z|[+-]\d{2}:?\d{2})$/;
const isoDateOnly = /^(\d{4})-(\d{2})-(\d{2})$/;

/** Décalage de `Europe/Zurich` à cet instant, en millisecondes (le fuseau du `dateOnly` Swift). */
function zurichOffset(at: number): number {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: "Europe/Zurich", hourCycle: "h23",
    year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", second: "2-digit",
  }).formatToParts(new Date(at));
  const get = (type: string) => Number(parts.find((p) => p.type === type)!.value);
  const asUTC = Date.UTC(get("year"), get("month") - 1, get("day"), get("hour"), get("minute"), get("second"));
  return asUTC - Math.floor(at / 1000) * 1000;
}

/** Minuit à Zurich du jour civil donné. */
function zurichMidnight(year: number, month: number, day: number): Date | null {
  const wall = Date.UTC(year, month - 1, day);
  const check = new Date(wall);
  if (check.getUTCFullYear() !== year || check.getUTCMonth() !== month - 1 || check.getUTCDate() !== day) return null;
  let guess = wall - zurichOffset(wall);
  guess = wall - zurichOffset(guess);
  return new Date(guess);
}

/** Parse « 2025-02-17 », « 2025-02-17T08:00:00Z » ou avec fraction de seconde. */
function parse(raw: string): Date | null {
  const value = raw.trim();
  if (value === "") return null;
  const full = isoFull.exec(value);
  if (full) {
    const zone = full[8] === "Z" || full[8].includes(":") ? full[8] : `${full[8].slice(0, 3)}:${full[8].slice(3)}`;
    const t = Date.parse(`${full[1]}-${full[2]}-${full[3]}T${full[4]}:${full[5]}:${full[6]}${full[7] ?? ""}${zone}`);
    if (!Number.isNaN(t)) return new Date(t);
  }
  const only = isoDateOnly.exec(value);
  if (only) return zurichMidnight(Number(only[1]), Number(only[2]), Number(only[3]));
  return null;
}

// MARK: Semaines

function startOfDay(date: Date): Date {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate());
}

/** Lundi de la semaine de `date`. */
function startOfWeek(date: Date): Date {
  const sinceMonday = (date.getDay() + 6) % 7;
  return new Date(date.getFullYear(), date.getMonth(), date.getDate() - sinceMonday);
}

/**
 * Début du semestre d'**automne** : le premier lundi dès le 7 septembre.
 *
 * L'EPFL fait commencer le semestre d'automne à cette date pour tout le monde.
 * La date **publiée** par l'EPFL prime sur la règle : si l'école décale une
 * rentrée, l'app suit sans qu'on touche au code.
 */
function autumnStart(year: number): Date {
  const official = EPFLCalendarSnapshot.autumnTeachingStart(year);
  if (official) return official;
  const seventh = new Date(year, 8, 7);
  // Premier lundi (weekday 2) à partir du 7.
  return new Date(year, 8, 7 + ((8 - seventh.getDay()) % 7));
}

/**
 * Début du semestre en cours, déduit du mois : septembre à janvier = automne.
 * La saison est renvoyée avec la date : la recalculer à l'appel, c'est se donner
 * l'occasion de se tromper d'un mois au passage du nouvel an.
 */
function currentAutumnOrSpringStart(reference: Date = new Date()): { start: Date; weeks: number; season: TermSeason } {
  const month = reference.getMonth() + 1;
  const year = reference.getFullYear();
  const isAutumn = month >= 8 || month <= 1;
  return isAutumn
    ? { start: autumnStart(year), weeks: 14, season: "autumn" }
    : { start: new Date(year, 1, 17), weeks: 14, season: "spring" };
}

function daysBetween(from: Date, to: Date): number {
  return Math.round((startOfDay(to).getTime() - startOfDay(from).getTime()) / DAY_MS);
}

function addDays(days: number, date: Date): Date {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate() + days,
    date.getHours(), date.getMinutes(), date.getSeconds(), date.getMilliseconds());
}

function addWeeks(weeks: number, date: Date): Date {
  return addDays(weeks * 7, date);
}

/** Une interruption des enseignements : du lundi qui suit la fin des cours au lundi de la reprise. */
export interface TeachingBreak {
  start: Date;
  end: Date;
}

/** Le nombre de semaines d'une pause (`TeachingBreak.weeks`). */
function breakLength(pause: TeachingBreak): number {
  return Math.max(0, Math.trunc((daysBetween(pause.start, pause.end) + 6) / 7));
}

let breaksCache: TeachingBreak[] | null = null;

/**
 * Les pauses du calendrier EPFL embarqué : chaque « Interruption des
 * enseignements » jusqu'à la « Reprise des enseignements » suivante.
 * Calculées à la première demande (le calendrier est un module voisin).
 */
function teachingBreaks(): TeachingBreak[] {
  if (breaksCache) return breaksCache;
  const entries = EPFLCalendarSnapshot.entries
    .filter((e) => e.kind === "break")
    .map((e) => ({ date: new Date(e.year, e.month - 1, e.day), title: e.title.toLowerCase() }))
    .sort((a, b) => a.date.getTime() - b.date.getTime());
  const result: TeachingBreak[] = [];
  let pending: Date | null = null;
  for (const { date, title } of entries) {
    if (title.includes("interruption")) {
      pending = date;
    } else if (title.includes("reprise") && pending) {
      // Les cours s'arrêtent en fin de journée : la pause commence le lundi suivant.
      const monday = startOfWeek(addDays(3, pending));
      if (monday.getTime() < date.getTime()) result.push({ start: monday, end: startOfWeek(date) });
      pending = null;
    }
  }
  breaksCache = result;
  return result;
}

/** Semaines de pause écoulées entre la rentrée et `date`. */
function breakWeeks(from: Date, to: Date, breaks: TeachingBreak[] = teachingBreaks()): number {
  const day = startOfDay(to);
  return breaks.reduce((total, pause) => {
    if (!(pause.start.getTime() >= startOfDay(from).getTime() && pause.start.getTime() <= day.getTime())) return total;
    if (day.getTime() >= pause.end.getTime()) return total + breakLength(pause);
    // En pleine pause : les semaines de pause déjà entamées.
    return total + Math.trunc(daysBetween(pause.start, day) / 7) + 1;
  }, 0);
}

/**
 * Numéro de semaine (1-based) depuis un lundi de semaine 1.
 *
 * Utilisable **sans** `AcademicTerm` : un cours dont le semestre n'est pas
 * renseigné ne doit pas se rabattre sur « semaine 1 », qui est une réponse
 * fausse — et silencieuse. Les semaines **sans cours** ne comptent pas :
 * l'EPFL interrompt les enseignements une semaine en automne et à Pâques.
 */
function weekNumber(from: Date, to: Date = new Date()): number {
  const days = daysBetween(from, to);
  const raw = Math.trunc(days / 7) + 1;
  return Math.max(1, raw - breakWeeks(from, to));
}

/** `weekNumber(for:term:)`. */
function weekNumberForTerm(date: Date, term: TermLike): number {
  return weekNumber(term.startDate, date);
}

/**
 * `weeks` semaines **de cours** après `start` : la fin d'un semestre de quatorze
 * semaines tombe une semaine plus tard s'il contient une pause.
 */
function addTeachingWeeks(weeks: number, start: Date): Date {
  let end = addWeeks(weeks, start);
  for (const pause of teachingBreaks()) {
    if (pause.start.getTime() >= startOfDay(start).getTime() && pause.start.getTime() < end.getTime()) {
      end = addWeeks(breakLength(pause), end);
    }
  }
  return end;
}

/**
 * Numéro de semaine borné à la durée du semestre. Indispensable pour un semestre
 * importé dont la date de début est ancienne : sans borne, « semaine 47 » et
 * tous les écrans hebdomadaires seraient vides.
 */
function clampedWeek(date: Date, term: TermLike): number {
  const raw = weekNumberForTerm(date, term);
  return Math.min(Math.max(raw, 1), Math.max(term.totalWeeks, 1));
}

function dateRange(days: number, endingAt: Date = new Date()): { start: Date; end: Date } {
  const end = addDays(1, startOfDay(endingAt));
  const start = startOfDay(addDays(-(days - 1), endingAt));
  return { start, end };
}

// MARK: Formats

/** « 45 min », « 1 h 30 », « 3 h ». */
function durationLabel(seconds: number): string {
  const totalMinutes = Math.trunc(Math.max(0, seconds) / 60);
  if (totalMinutes < 60) return `${totalMinutes} min`;
  const hours = Math.trunc(totalMinutes / 60);
  const minutes = totalMinutes % 60;
  return minutes === 0 ? `${hours} h` : `${hours} h ${String(minutes).padStart(2, "0")}`;
}

/** Les dates et les heures suivent la langue de l'interface, avec les formats suisses. */
function appLocale(): string {
  return getPreferredLanguage().startsWith("en") ? "en-CH" : "fr-CH";
}

function usesDecimalComma(): boolean {
  return !getPreferredLanguage().startsWith("en");
}

/** `String(format: "%.1f")` : arrondi pair sur les égalités exactes (x,25 → x,2), comme printf. */
function fixed1(value: number): string {
  const quarter = value * 4;
  if (Number.isInteger(quarter) && Math.abs(quarter) % 2 === 1) {
    const tenths = Math.floor(value * 10);
    return ((tenths % 2 === 0 ? tenths : tenths + 1) / 10).toFixed(1);
  }
  return value.toFixed(1);
}

/** « 2,5 h » (1 décimale, virgule suisse). */
function hoursLabel(seconds: number): string {
  // « 2 h » plutôt que « 2,0 h » : la décimale seulement quand elle dit quelque chose.
  const raw = fixed1(seconds / 3600).replace(/\.0$/, "");
  const formatted = raw.replace(".", usesDecimalComma() ? "," : ".");
  return `${formatted} h`;
}

/** `hoursLabel(hours:)`. */
function hoursLabelFromHours(hours: number): string {
  return hoursLabel(Math.trunc(hours * 3600));
}

function formatParts(date: Date, options: Intl.DateTimeFormatOptions): Record<string, string> {
  const parts = new Intl.DateTimeFormat(appLocale(), options).formatToParts(date);
  const out: Record<string, string> = {};
  for (const p of parts) out[p.type] = p.value;
  return out;
}

/** « lun. 28 sept. » (`EEE d MMM`). */
function shortDay(date: Date): string {
  const p = formatParts(date, { weekday: "short", day: "numeric", month: "short" });
  return `${p.weekday} ${p.day} ${p.month}`;
}

/** « lundi 28 septembre » (`EEEE d MMMM`). */
function fullDay(date: Date): string {
  const p = formatParts(date, { weekday: "long", day: "numeric", month: "long" });
  return `${p.weekday} ${p.day} ${p.month}`;
}

/** « 08:15 » (`HH:mm`). */
function time(date: Date): string {
  return `${String(date.getHours()).padStart(2, "0")}:${String(date.getMinutes()).padStart(2, "0")}`;
}

/** « 2025-02-17 » à Zurich (le `dateOnly` Swift, aussi utilisé pour écrire). */
function dateOnly(date: Date): string {
  const p = new Intl.DateTimeFormat("en-CA", {
    timeZone: "Europe/Zurich", year: "numeric", month: "2-digit", day: "2-digit",
  }).formatToParts(date);
  const get = (type: string) => p.find((x) => x.type === type)!.value;
  return `${get("year")}-${get("month")}-${get("day")}`;
}

/**
 * « Lundi 19 octobre » — seule l'initiale en capitale (une capitale à chaque mot,
 * « Lundi 19 Octobre », n'est pas du français).
 */
function fullDayLabel(date: Date): string {
  return capitalizedFirst(fullDay(date));
}

function isSameDay(a: Date, b: Date): boolean {
  return a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate();
}

function relativeLabel(date: Date): string {
  const now = new Date();
  if (isSameDay(date, now)) return "Aujourd'hui";
  if (isSameDay(date, addDays(1, now))) return "Demain";
  if (isSameDay(date, addDays(-1, now))) return "Hier";
  const days = daysBetween(now, date);
  if (days > 0 && days < 7) return `Dans ${days} j`;
  if (days < 0 && days > -7) return `Il y a ${-days} j`;
  return shortDay(date);
}

/** « J-12 », « Aujourd'hui », « Passé ». */
function countdownLabel(date: Date): string {
  const days = daysBetween(new Date(), date);
  if (days === 0) return "Aujourd'hui";
  if (days === 1) return "Demain";
  if (days > 1) return `J-${days}`;
  return "Passé";
}

/** Numéro du mois (1 = janvier). Sert à décider de la saison d'un semestre. */
function monthNumber(date: Date): number {
  return date.getMonth() + 1;
}

function weekdayInitial(date: Date): string {
  return new Intl.DateTimeFormat(appLocale(), { weekday: "narrow" }).format(date).toUpperCase();
}

/** « lundi 28 septembre » → « Lundi 28 septembre » : seule l'initiale. */
export function capitalizedFirst(s: string): string {
  const [first] = s;
  return first === undefined ? s : first.toUpperCase() + s.slice(first.length);
}

export const DateUtils = {
  parse,
  dateOnly,
  startOfDay,
  startOfWeek,
  autumnStart,
  currentAutumnOrSpringStart,
  weekNumber,
  weekNumberForTerm,
  breakLength,
  teachingBreaks,
  breakWeeks,
  addTeachingWeeks,
  clampedWeek,
  daysBetween,
  addDays,
  addWeeks,
  dateRange,
  durationLabel,
  appLocale,
  usesDecimalComma,
  hoursLabel,
  hoursLabelFromHours,
  shortDay,
  fullDay,
  time,
  fullDayLabel,
  relativeLabel,
  countdownLabel,
  monthNumber,
  weekdayInitial,
  isSameDay,
};

export {
  parse, dateOnly, startOfDay, startOfWeek, autumnStart, currentAutumnOrSpringStart, weekNumber,
  weekNumberForTerm, breakLength, teachingBreaks, breakWeeks, addTeachingWeeks, clampedWeek, daysBetween,
  addDays, addWeeks, dateRange, durationLabel, hoursLabel, hoursLabelFromHours, shortDay, fullDay, time,
  fullDayLabel, relativeLabel, countdownLabel, monthNumber, weekdayInitial, isSameDay,
};
