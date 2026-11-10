// Petites mises en forme du bilan, copiées des helpers Swift
// (`String(format:)`, `Plural`, `Correctness.lineLabel`).

import { DateUtils } from "../../../domain/dateUtils.ts";
import { Plural } from "../../../domain/plural.ts";
import type { Correctness } from "../../../models/enums.ts";

/** `Int((Double(part) / Double(total) * 100).rounded())`. */
export function percent(part: number, total: number): string {
  return total === 0 ? "—" : `${Math.round((part / total) * 100)} %`;
}

/**
 * `Correctness.lineLabel` : le mot d'une ligne d'exercice — les mêmes trois mots
 * que partout ailleurs (« juste », « moyen », « faux »). « à revoir » se
 * confondait avec « à refaire », qui est autre chose.
 */
export function lineLabel(correctness: Correctness): string {
  switch (correctness) {
    case "correct": return "juste";
    case "partial": return "moyen";
    case "wrong": return "faux";
  }
}

/**
 * `String(format: "%.1f", hours)` : arrondi pair sur les égalités exactes, puis
 * la virgule suisse. Sert aux moyennes horaires, pas à `hoursLabel` (déjà porté).
 */
export function hoursValue(hours: number): string {
  const quarter = hours * 4;
  let formatted: string;
  if (Number.isInteger(quarter) && Math.abs(quarter) % 2 === 1) {
    const tenths = Math.floor(hours * 10);
    formatted = ((tenths % 2 === 0 ? tenths : tenths + 1) / 10).toFixed(1);
  } else {
    formatted = hours.toFixed(1);
  }
  return formatted.replace(".", DateUtils.usesDecimalComma() ? "," : ".");
}

/** `Plural.count` pour les libellés du bilan. */
export function sessionsCount(count: number): string {
  return Plural.count(count, `${count} session`, `${count} sessions`);
}

export function coursesCount(count: number): string {
  return Plural.count(count, `${count} cours`, `${count} cours`);
}

export function activeDaysLabel(days: number): string {
  return Plural.count(days, `${days} jour actif`, `${days} jours actifs`);
}

export function exercisesCount(count: number): string {
  return Plural.count(count, `${count} exercice`, `${count} exercices`);
}
