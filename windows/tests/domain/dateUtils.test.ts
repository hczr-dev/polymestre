import { describe, expect, it } from "vitest";
import { DateUtils, capitalizedFirst } from "../../src/domain/dateUtils.ts";
import { Plural, setPreferredLanguage } from "../../src/domain/plural.ts";

// Tests propres au port (DateUtils n'a pas de section dédiée dans Validation/main.swift :
// les semaines sont couvertes par models.test.ts, ceci couvre les formats et le parsing).

describe("DateUtils.parse", () => {
  it("date seule : minuit à Zurich", () => {
    const d = DateUtils.parse("2025-02-17")!;
    expect(d.toISOString()).toBe("2025-02-16T23:00:00.000Z");
    expect(DateUtils.parse("2025-07-01")!.toISOString()).toBe("2025-06-30T22:00:00.000Z");
  });

  it("date et heure UTC, avec ou sans fraction", () => {
    expect(DateUtils.parse("2025-02-17T08:00:00Z")!.toISOString()).toBe("2025-02-17T08:00:00.000Z");
    expect(DateUtils.parse("2025-02-17T08:00:00.250Z")!.toISOString()).toBe("2025-02-17T08:00:00.250Z");
    expect(DateUtils.parse("2025-02-17T09:00:00+01:00")!.toISOString()).toBe("2025-02-17T08:00:00.000Z");
  });

  it("espaces retirés ; vide ou illisible : null", () => {
    expect(DateUtils.parse("  2025-02-17  ")).not.toBeNull();
    expect(DateUtils.parse("")).toBeNull();
    expect(DateUtils.parse("   ")).toBeNull();
    expect(DateUtils.parse("hier")).toBeNull();
    expect(DateUtils.parse("2025-13-45")).toBeNull();
  });

  it("dateOnly écrit à Zurich", () => {
    expect(DateUtils.dateOnly(new Date("2025-02-16T23:00:00Z"))).toBe("2025-02-17");
  });
});

describe("DateUtils : semaines et jours", () => {
  it("startOfWeek : le lundi, à minuit", () => {
    const wed = new Date(2026, 8, 30, 15, 30);
    const monday = DateUtils.startOfWeek(wed);
    expect([monday.getFullYear(), monday.getMonth(), monday.getDate(), monday.getHours()]).toEqual([2026, 8, 28, 0]);
    expect(DateUtils.startOfWeek(new Date(2026, 8, 27)).getDate()).toBe(21); // un dimanche
  });

  it("addDays traverse le changement d'heure sans décaler l'heure murale", () => {
    const before = new Date(2026, 9, 24, 8, 15); // veille du passage à l'heure d'hiver
    const after = DateUtils.addDays(2, before);
    expect([after.getDate(), after.getHours(), after.getMinutes()]).toEqual([26, 8, 15]);
    expect(DateUtils.daysBetween(before, after)).toBe(2);
  });

  it("daysBetween compte des jours civils", () => {
    expect(DateUtils.daysBetween(new Date(2026, 9, 30, 23, 59), new Date(2026, 9, 31, 0, 1))).toBe(1);
    expect(DateUtils.daysBetween(new Date(2026, 9, 31), new Date(2026, 9, 30))).toBe(-1);
  });

  it("dateRange : les `days` derniers jours, fin exclusive", () => {
    const { start, end } = DateUtils.dateRange(7, new Date(2026, 9, 30, 12));
    expect(start.getDate()).toBe(24);
    expect(end.getDate()).toBe(31);
  });

  it("la pause d'automne ne compte pas dans les numéros de semaine", () => {
    const autumn = DateUtils.autumnStart(2026);
    const pauses = DateUtils.teachingBreaks();
    expect(pauses.some((p) => p.start.getMonth() === 9 && p.start.getDate() === 19)).toBe(true);
    expect(DateUtils.breakWeeks(autumn, DateUtils.addDays(49, autumn))).toBe(1);
    // Pendant la pause : la dernière semaine de cours.
    expect(DateUtils.weekNumber(autumn, DateUtils.addDays(42, autumn))).toBe(6);
    expect(DateUtils.weekNumber(autumn, DateUtils.addDays(-30, autumn))).toBe(1);
  });

  it("currentAutumnOrSpringStart : la saison suit le mois", () => {
    expect(DateUtils.currentAutumnOrSpringStart(new Date(2026, 9, 1)).season).toBe("autumn");
    expect(DateUtils.currentAutumnOrSpringStart(new Date(2027, 0, 15)).season).toBe("autumn");
    const spring = DateUtils.currentAutumnOrSpringStart(new Date(2027, 3, 1));
    expect(spring.season).toBe("spring");
    expect([spring.start.getMonth(), spring.start.getDate()]).toEqual([1, 17]);
  });
});

describe("DateUtils : formats", () => {
  it("durationLabel", () => {
    expect(DateUtils.durationLabel(45 * 60)).toBe("45 min");
    expect(DateUtils.durationLabel(90 * 60)).toBe("1 h 30");
    expect(DateUtils.durationLabel(3 * 3600)).toBe("3 h");
    expect(DateUtils.durationLabel(3600 + 5 * 60)).toBe("1 h 05");
    expect(DateUtils.durationLabel(-10)).toBe("0 min");
  });

  it("hoursLabel : une décimale quand elle compte, virgule suisse, arrondi pair sur les égalités exactes", () => {
    expect(DateUtils.hoursLabel(9000)).toBe("2,5 h");
    expect(DateUtils.hoursLabel(0)).toBe("0 h");
    expect(DateUtils.hoursLabel(7200)).toBe("2 h");
    expect(DateUtils.hoursLabel(900)).toBe("0,2 h"); // 0,25 → printf arrondit au pair
    expect(DateUtils.hoursLabel(2700)).toBe("0,8 h"); // 0,75
    expect(DateUtils.hoursLabelFromHours(1.5)).toBe("1,5 h");
  });

  it("fullDayLabel : seule l'initiale en capitale", () => {
    expect(DateUtils.fullDayLabel(new Date(2026, 9, 19))).toBe("Lundi 19 octobre");
    expect(capitalizedFirst("lundi 28 septembre")).toBe("Lundi 28 septembre");
    expect(capitalizedFirst("")).toBe("");
  });

  it("relativeLabel et countdownLabel", () => {
    const now = new Date();
    expect(DateUtils.relativeLabel(now)).toBe("Aujourd'hui");
    expect(DateUtils.relativeLabel(DateUtils.addDays(1, now))).toBe("Demain");
    expect(DateUtils.relativeLabel(DateUtils.addDays(-1, now))).toBe("Hier");
    expect(DateUtils.relativeLabel(DateUtils.addDays(3, now))).toBe("Dans 3 j");
    expect(DateUtils.relativeLabel(DateUtils.addDays(-3, now))).toBe("Il y a 3 j");
    expect(DateUtils.countdownLabel(DateUtils.addDays(12, now))).toBe("J-12");
    expect(DateUtils.countdownLabel(now)).toBe("Aujourd'hui");
    expect(DateUtils.countdownLabel(DateUtils.addDays(-2, now))).toBe("Passé");
  });

  it("time : HH:mm", () => {
    expect(DateUtils.time(new Date(2026, 0, 1, 8, 5))).toBe("08:05");
  });
});

describe("Plural et langue", () => {
  it("la langue choisie commande la virgule décimale et le pluriel", () => {
    expect(Plural.count(0, "0 série", "0 séries")).toBe("0 série");
    expect(Plural.count(2, "2 série", "2 séries")).toBe("2 séries");
    setPreferredLanguage("en");
    try {
      expect(Plural.count(0, "0 series", "0 seriess")).toBe("0 seriess");
      expect(DateUtils.hoursLabel(9000)).toBe("2.5 h");
    } finally {
      setPreferredLanguage("fr");
    }
  });
});
