// Les couleurs des graphiques du bilan, dans la langue du papier.
//
// `Carnet.tint` (StudyKit/CarnetCore.swift) adoucit une teinte de cours pour la
// feuille : même teinte, saturation et luminosité ramenées vers l'encre ; plus
// claire la nuit. On recalcule la même chose ici, en clair **et** en sombre,
// pour que les SVG suivent l'apparence sans hex en dur dans les écrans.

import { useEffect, useState } from "react";
import { Correctness, TaskType } from "../../../models/enums.ts";

const clamp01 = (value: number): number => Math.min(1, Math.max(0, value));

function parseHex(hex: string): [number, number, number] | null {
  const value = hex.trim().replace(/^#/, "");
  if (value.length === 3) {
    return [
      parseInt(value[0] + value[0], 16) / 255,
      parseInt(value[1] + value[1], 16) / 255,
      parseInt(value[2] + value[2], 16) / 255,
    ];
  }
  if (value.length === 6) {
    return [
      parseInt(value.slice(0, 2), 16) / 255,
      parseInt(value.slice(2, 4), 16) / 255,
      parseInt(value.slice(4, 6), 16) / 255,
    ];
  }
  return null;
}

/** `getHue(_:saturation:brightness:alpha:)` : h, s, b dans 0…1. */
function rgbToHsb(r: number, g: number, b: number): [number, number, number] {
  const max = Math.max(r, g, b);
  const min = Math.min(r, g, b);
  const delta = max - min;
  let hue = 0;
  if (delta !== 0) {
    if (max === r) hue = (g - b) / delta + (g < b ? 6 : 0);
    else if (max === g) hue = (b - r) / delta + 2;
    else hue = (r - g) / delta + 4;
    hue /= 6;
  }
  return [hue, max === 0 ? 0 : delta / max, max];
}

function hsbToRgb(hue: number, saturation: number, brightness: number): [number, number, number] {
  const h = ((hue % 1) + 1) % 1;
  const sector = h * 6;
  const index = Math.floor(sector);
  const fraction = sector - index;
  const p = brightness * (1 - saturation);
  const q = brightness * (1 - saturation * fraction);
  const t = brightness * (1 - saturation * (1 - fraction));
  switch (index % 6) {
    case 0: return [brightness, t, p];
    case 1: return [q, brightness, p];
    case 2: return [p, brightness, t];
    case 3: return [p, q, brightness];
    case 4: return [t, p, brightness];
    default: return [brightness, p, q];
  }
}

function toHex(r: number, g: number, b: number): string {
  const byte = (value: number): string =>
    Math.round(clamp01(value) * 255).toString(16).padStart(2, "0");
  return `#${byte(r)}${byte(g)}${byte(b)}`;
}

/**
 * La teinte d'un cours pour le papier. `light-dark` n'est pas nécessaire : on
 * connaît l'apparence courante et on rend une seule couleur, donc les SVG et les
 * pastilles restent simples.
 */
export function carnetTint(hex: string, dark: boolean): string {
  const rgb = parseHex(hex);
  if (!rgb) return dark ? "#A89F8D" : "#6B655A";
  const [hue, saturation, brightness] = rgbToHsb(rgb[0], rgb[1], rgb[2]);
  const nextSaturation = dark ? Math.min(saturation, 0.45) : Math.min(saturation * 0.62, 0.62);
  const nextBrightness = dark ? Math.max(brightness, 0.82) : Math.min(brightness * 0.74, 0.62);
  return toHex(...hsbToRgb(hue, nextSaturation, nextBrightness));
}

/** Les teintes de `TaskType.tint` (StudyKit/CarnetCore.swift), avant `Carnet.tint`. */
function baseCategoryHex(type: TaskType): string {
  switch (TaskType.canonical(type)) {
    case "theory": return "#4F6FB8";
    // Sa propre teinte, pas le gris d'« Autre » : comme sur l'iPhone et le Mac.
    case "lecture": return "#3E8E96";
    case "exercise": return "#C08A2E";
    case "correction": return "#5E9A6A";
    case "flashcards": return "#A0567E";
    default: return "#7A7468";
  }
}

/** La couleur d'une nature de travail, adoucie pour l'apparence courante. */
export function taskColor(type: TaskType, dark: boolean): string {
  return carnetTint(baseCategoryHex(type), dark);
}

/** La teinte de l'amphi : celle de `TaskType.lecture.tint`, la même sur les trois plateformes. */
export function lectureColor(dark: boolean): string {
  return taskColor("lecture", dark);
}

/** Vert / ambre / rouge, les seuls verdicts de correction. */
export function correctnessColor(correctness: Correctness): string {
  switch (correctness) {
    case "correct": return "var(--correct)";
    case "partial": return "var(--review)";
    case "wrong": return "var(--wrong)";
  }
}

/** L'apparence suit le système (et `[data-theme]` si l'app en pose un). */
export function useDarkMode(): boolean {
  const read = (): boolean => {
    if (typeof window === "undefined") return false;
    const override = document.documentElement.dataset.theme;
    if (override === "dark") return true;
    if (override === "light") return false;
    return window.matchMedia?.("(prefers-color-scheme: dark)").matches ?? false;
  };

  const [dark, setDark] = useState(read);

  useEffect(() => {
    const query = window.matchMedia?.("(prefers-color-scheme: dark)");
    const update = (): void => setDark(read());
    query?.addEventListener("change", update);
    const observer = new MutationObserver(update);
    observer.observe(document.documentElement, { attributes: true, attributeFilter: ["data-theme"] });
    return () => {
      query?.removeEventListener("change", update);
      observer.disconnect();
    };
  }, []);

  return dark;
}
