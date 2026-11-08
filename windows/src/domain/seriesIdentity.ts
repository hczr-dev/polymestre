// Ce qui distingue une série d'une autre dans un même cours : son numéro et,
// quand le cours en publie deux par semaine, son étiquette.
//
// Pendant de Polymestre/Domain/SeriesIdentity.swift. Deux séries la même
// semaine — « Série 5a » et « 5b », « Exercices du mardi » et « du jeudi »,
// « Série 5 — partie 2 » — fusionnaient quand on ne gardait que le numéro.
// Une série sans numéro prend celui de la semaine où Moodle la pose ;
// l'étiquette départage deux séries de la même semaine. Vide : rien ne change.

export interface SeriesKey { number: number; label: string }

export const DAYS = ["lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi"];
const DAY_ALIASES: Record<string, string> = {
  monday: "lundi", tuesday: "mardi", wednesday: "mercredi", thursday: "jeudi", friday: "vendredi", saturday: "samedi",
  lundi: "lundi", mardi: "mardi", mercredi: "mercredi", jeudi: "jeudi", vendredi: "vendredi", samedi: "samedi",
};

const fold = (text: string): string =>
  text.normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase();

export const SeriesIdentity = {
  key(number: number, label = ""): SeriesKey {
    return { number, label: SeriesIdentity.normalized(label) };
  },

  same(a: SeriesKey, b: SeriesKey): boolean {
    return a.number === b.number && a.label === b.label;
  },

  id(key: SeriesKey): string { return `${key.number}|${key.label}`; },

  normalized(label: string): string { return fold(label).trim(); },

  /** Les jours dans l'ordre de la semaine, le reste dans l'ordre naturel ; sans étiquette d'abord. */
  labelPrecedes(a: string, b: string): boolean {
    if (a === b) return false;
    if (a === "") return true;
    if (b === "") return false;
    const da = DAYS.indexOf(a), db = DAYS.indexOf(b);
    if (da >= 0 && db >= 0) return da < db;
    if (da >= 0) return false;
    if (db >= 0) return true;
    return a.localeCompare(b, undefined, { numeric: true }) < 0;
  },

  compare(a: SeriesKey, b: SeriesKey): number {
    if (a.number !== b.number) return a.number - b.number;
    if (a.label === b.label) return 0;
    return SeriesIdentity.labelPrecedes(a.label, b.label) ? -1 : 1;
  },

  /** « b » collé, « .2 » pour un chiffre, « · mardi » pour un mot. */
  suffix(label: string): string {
    const l = SeriesIdentity.normalized(label);
    if (l === "") return "";
    if (l.length === 1 && /\p{L}/u.test(l)) return l;
    if (/^\d+$/.test(l)) return "." + l;
    return " · " + l;
  },

  /** « Série 5 », « Série 5b », « Série 5.2 », « Série 5 · mardi ». */
  displayName(number: number, label = ""): string {
    return `Série ${number}` + SeriesIdentity.suffix(label);
  },

  /**
   * L'étiquette qu'un nom de série porte à côté (ou à la place) de son numéro.
   * Le jour d'une échéance (« à rendre avant mardi ») n'en est pas une.
   */
  label(name: string): string {
    const text = fold(name).replace(/_/g, " ");
    const lead = "(?:series?|problem ?sets?|exercise sets?|feuilles?|td|tp|homework|exercices?|exercises?|exos?)";
    let m = text.match(new RegExp(lead + String.raw`\s*[-#.:]?\s*(?:n[o°]\s*)?0*\d{1,2}(?:\s*[-.(]\s*)?([a-f])\b(?!['’])(?!\s*(?:rendre|remettre|faire)\b)`));
    if (m) return m[1];
    m = text.match(new RegExp(lead + String.raw`\s*[-#.:]?\s*(?:n[o°]\s*)?0*\d{1,2}\s*[./]\s*([1-4])\b(?![.,]\d)`));
    if (m) return m[1];
    const romans: Record<string, string> = { i: "1", ii: "2", iii: "3", iv: "4" };
    m = text.match(/\b(?:partie|part|teil)\s*[-#:]?\s*(\d|i{1,3}|iv)\b/);
    if (m) return "partie " + (romans[m[1]] ?? m[1]);
    m = text.match(/\b(\d)\s*(?:e|eme|nd|rd|th)?\s+partie\b/);
    if (m) return "partie " + m[1];
    if (!/\b(avant|before|until|jusqu|due|rendre|deadline|pour le|by)\b/.test(text)) {
      for (const [alias, day] of Object.entries(DAY_ALIASES)) {
        if (new RegExp(String.raw`\b${alias}\b`).test(text)) return day;
      }
    }
    m = text.match(new RegExp(lead + String.raw`\s*[-#:]?\s*([a-f])\s*$`));
    if (m) return m[1];
    return "";
  },
};
