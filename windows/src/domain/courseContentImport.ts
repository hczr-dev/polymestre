// Les sources d'un cours et le brouillon relu avant écriture
// (Polymestre/Domain/CourseContentImport.swift).
//
// L'EPFL ne donne **aucun** accès API aux étudiant·e·s. Le contenu arrive par la
// page elle-même : Moodle et Courseware s'ouvrent dans un navigateur intégré, puis
// l'app lit la page du cours. Botafogo (le polycopié en ligne d'Analyse de
// S. Friedli) est public : il se lit directement, sans connexion.

import { ExamKind, TheoryKind } from "../models/enums.ts";
import { decodeList, encodeList, type ContentLink as ModelContentLink } from "../models/jsonTypes.ts";
import { swiftInt } from "../services/seriesPDFParser.ts";
import { trimAll, trimWhitespaces } from "../models/util.ts";
import { DateUtils } from "./dateUtils.ts";
import { icuRegExp } from "./icuRegExp.ts";
import { Institution } from "./institution.ts";
import { NuxtPayload } from "./nuxtPayload.ts";
import { BotafogoLinks } from "./botafogoProgram.ts";
import { TextRepair } from "./textRepair.ts";

// MARK: - Sources

export type ContentSource = "moodle" | "courseware" | "botafogo";

export const ContentSource = {
  allCases: ["moodle", "courseware", "botafogo"] as readonly ContentSource[],
  fromRaw(raw: string | null | undefined): ContentSource | undefined {
    return raw === "moodle" || raw === "courseware" || raw === "botafogo" ? raw : undefined;
  },

  label(source: ContentSource): string {
    switch (source) {
      case "moodle": return "Moodle";
      case "courseware": return "Courseware";
      case "botafogo": return "Botafogo";
    }
  },

  /** Ce que la source apporte, en une ligne. */
  detail(source: ContentSource): string {
    switch (source) {
      case "moodle": return "Semaines, vidéos, supports et séries du cours";
      case "courseware": return "Chapitres et leçons d'un MOOC EPFL";
      case "botafogo": return "Polycopié d'Analyse en ligne (S. Friedli), avec ses vidéos";
    }
  },

  icon(source: ContentSource): string {
    switch (source) {
      case "moodle": return "graduationcap";
      case "courseware": return "play.rectangle.on.rectangle";
      case "botafogo": return "function";
    }
  },

  /** La page d'arrivée du navigateur intégré. */
  homeURL(source: ContentSource): URL {
    switch (source) {
      case "moodle":
        return Institution.current.moodleURL("/my/courses.php") ?? new URL("https://moodle.epfl.ch/my/courses.php");
      case "courseware":
        return Institution.current.coursewareURL("/dashboard") ?? new URL("https://courseware.epfl.ch/dashboard");
      case "botafogo":
        return new URL((Institution.current.extras["botafogo"] ?? "https://botafogo.epfl.ch") + "/");
    }
  },

  requiresLogin(source: ContentSource): boolean { return source !== "botafogo"; },

  /** La source d'une adresse, d'après son hôte. */
  detect(host: string | null): ContentSource | null {
    const value = host?.toLowerCase();
    if (value === undefined || value === null) return null;
    if (value.includes("moodle")) return "moodle";
    if (value.includes("courseware") || value.includes("openedx")) return "courseware";
    if (value.includes("botafogo")) return "botafogo";
    return null;
  },
};

// MARK: - Ce que la page a donné

/// Un élément tel que lu sur la page, avant toute interprétation.
///
/// Le script injecté dans la page ne décide de rien : il rapporte des titres, des
/// liens et un type technique. Tout ce qui ressemble à une règle vit ici, en
/// TypeScript pur.
export interface ScrapedItem {
  title: string;
  url: string;
  type: string;
  videoCount?: number;
  id?: string;
  blockIDs?: string[];
  links?: ModelContentLink[];
}

export const ScrapedItem = {
  make(title: string, o: Partial<Omit<ScrapedItem, "title">> = {}): ScrapedItem {
    return { title, url: "", type: "", ...o };
  },
};

export interface ScrapedSection {
  title: string;
  items: ScrapedItem[];
  id?: string;
}

export const ScrapedSection = {
  make(title: string, items: ScrapedItem[] = [], id?: string): ScrapedSection {
    return { title, items, ...(id === undefined ? {} : { id }) };
  },
};

export interface ScrapedCourse {
  source: string;
  title: string;
  url: string;
  sections: ScrapedSection[];
}

export const ScrapedCourse = {
  make(source: string, title: string, url: string, sections: ScrapedSection[] = []): ScrapedCourse {
    return { source, title, url, sections };
  },
};

// MARK: - Brouillon à relire

export type ContentItemKind = "theory" | "series" | "deadline" | "pastExam" | "resource" | "ignore";

export const ContentItemKind = {
  allCases: ["theory", "series", "deadline", "pastExam", "resource", "ignore"] as readonly ContentItemKind[],

  label(kind: ContentItemKind): string {
    switch (kind) {
      case "theory": return "Théorie";
      case "series": return "Série";
      case "deadline": return "Échéance";
      case "pastExam": return "Annale";
      case "resource": return "Document";
      case "ignore": return "Ignorer";
    }
  },
};

/** Une sous-question repérée sous un exercice (Services/SeriesPDFParser.swift). */
export type { DetectedSubQuestion } from "../services/seriesPDFParser.ts";

/** Un exercice prêt à écrire, venu d'une source qui publie les exercices (Botafogo). */
export interface ContentExerciseDraft {
  number: string;
  title: string;
  statement: string;
  hint: string;
  solution: string;
  url: string;
  isBonus: boolean;
  questions: import("../services/seriesPDFParser.ts").DetectedSubQuestion[];
}

export interface ContentDraftItemInit {
  id?: string;
  kind: ContentItemKind;
  /** « 3.2 » pour la théorie ; le numéro de série est `seriesNumber`. */
  number: string;
  title: string;
  url: string;
  videoCount: number;
  seriesNumber: number | null;
  theoryKind: TheoryKind;
  seriesLabel?: string;
  week?: number | null;
  exercises?: ContentExerciseDraft[];
  pdfURL?: string;
  solutionsAt?: Date | null;
  solutionURL?: string;
  links?: ModelContentLink[];
  date?: Date | null;
  examKind?: ExamKind;
  group?: string;
}

export class ContentDraftItem {
  id: string;
  kind: ContentItemKind;
  number: string;
  title: string;
  url: string;
  videoCount: number;
  seriesNumber: number | null;
  theoryKind: TheoryKind;
  /** L'étiquette d'une série (« b », « mardi ») quand deux séries partagent un numéro. */
  seriesLabel: string;
  /** La semaine **de l'élément**, quand elle diffère de celle de sa section. */
  week: number | null;
  exercises: ContentExerciseDraft[];
  pdfURL: string;
  solutionsAt: Date | null;
  solutionURL: string;
  links: ModelContentLink[];
  date: Date | null;
  examKind: ExamKind;
  group: string;

  constructor(o: ContentDraftItemInit) {
    this.id = o.id ?? crypto.randomUUID();
    this.kind = o.kind;
    this.number = o.number;
    this.title = o.title;
    this.url = o.url;
    this.videoCount = o.videoCount;
    this.seriesNumber = o.seriesNumber;
    this.theoryKind = o.theoryKind;
    this.seriesLabel = o.seriesLabel ?? "";
    this.week = o.week ?? null;
    this.exercises = o.exercises ?? [];
    this.pdfURL = o.pdfURL ?? "";
    this.solutionsAt = o.solutionsAt ?? null;
    this.solutionURL = o.solutionURL ?? "";
    this.links = o.links ?? [];
    this.date = o.date ?? null;
    this.examKind = o.examKind ?? "assignment";
    this.group = o.group ?? "";
  }

  /** La semaine à écrire. */
  plannedWeek(section: ContentDraftSection): number {
    return this.week ?? section.week;
  }

  /** La sémantique de valeur des `struct` Swift : une copie ne partage rien de mutable. */
  clone(): ContentDraftItem {
    return new ContentDraftItem({
      ...this,
      exercises: this.exercises.map((exercise) => ({
        ...exercise, questions: exercise.questions.map((question) => structuredClone(question)),
      })),
      links: this.links.map((link) => ({ ...link })),
      solutionsAt: this.solutionsAt === null ? null : new Date(this.solutionsAt.getTime()),
      date: this.date === null ? null : new Date(this.date.getTime()),
    });
  }
}

export interface ContentDraftSectionInit {
  id?: string;
  title: string;
  /** Semaine du semestre ; `0` = non planifié. */
  week: number;
  weekIsInferred: boolean;
  isIncluded: boolean;
  items: ContentDraftItem[];
}

export class ContentDraftSection {
  id: string;
  title: string;
  week: number;
  weekIsInferred: boolean;
  isIncluded: boolean;
  items: ContentDraftItem[];

  constructor(o: ContentDraftSectionInit) {
    this.id = o.id ?? crypto.randomUUID();
    this.title = o.title;
    this.week = o.week;
    this.weekIsInferred = o.weekIsInferred;
    this.isIncluded = o.isIncluded;
    this.items = o.items;
  }

  get theoryCount(): number { return this.items.filter((i) => i.kind === "theory").length; }
  get deadlineCount(): number { return this.items.filter((i) => i.kind === "deadline").length; }
  get resourceCount(): number { return this.items.filter((i) => i.kind === "resource" || i.kind === "pastExam").length; }

  /** « Semaine 3 », ou « Semaines 3–5 » quand les éléments s'étalent. */
  get weekRange(): { lower: number; upper: number } | null {
    const weeks = this.items.filter((i) => i.kind !== "ignore").map((i) => i.plannedWeek(this)).filter((w) => w > 0);
    if (weeks.length === 0) return null;
    return { lower: Math.min(...weeks), upper: Math.max(...weeks) };
  }

  /** Décale la section **et** ses éléments : corriger la semaine d'un chapitre étalé ne doit pas écraser son étalement. */
  shiftWeeks(by: number, totalWeeks: number): void {
    if (by === 0) return;
    for (const item of this.items) {
      if (item.week !== null) item.week = Math.min(Math.max(1, item.week + by), Math.max(totalWeeks, 1));
    }
  }

  get seriesCount(): number { return this.items.filter((i) => i.kind === "series").length; }
  get videoCount(): number { return this.items.filter((i) => i.kind === "theory").reduce((n, i) => n + i.videoCount, 0); }

  clone(): ContentDraftSection {
    return new ContentDraftSection({
      id: this.id, title: this.title, week: this.week, weekIsInferred: this.weekIsInferred,
      isIncluded: this.isIncluded, items: this.items.map((item) => item.clone()),
    });
  }
}

export interface ContentDraftInit {
  source: ContentSource;
  courseTitle: string;
  url: string;
  sections: ContentDraftSection[];
  weekGuide?: Record<number, string>;
}

export class ContentDraft {
  source: ContentSource;
  courseTitle: string;
  url: string;
  sections: ContentDraftSection[];
  /** Ce qu'il faut faire chaque semaine, en une phrase. */
  weekGuide: Record<number, string>;

  constructor(o: ContentDraftInit) {
    this.source = o.source;
    this.courseTitle = o.courseTitle;
    this.url = o.url;
    this.sections = o.sections;
    this.weekGuide = o.weekGuide ?? {};
  }

  get includedSections(): ContentDraftSection[] { return this.sections.filter((s) => s.isIncluded); }
  get theoryCount(): number { return this.includedSections.reduce((n, s) => n + s.theoryCount, 0); }
  get seriesCount(): number { return this.includedSections.reduce((n, s) => n + s.seriesCount, 0); }
  get videoCount(): number { return this.includedSections.reduce((n, s) => n + s.videoCount, 0); }
  get deadlineCount(): number { return this.includedSections.reduce((n, s) => n + s.deadlineCount, 0); }
  get resourceCount(): number { return this.includedSections.reduce((n, s) => n + s.resourceCount, 0); }
  get isEmpty(): boolean {
    return this.theoryCount === 0 && this.seriesCount === 0 && this.deadlineCount === 0 && this.resourceCount === 0;
  }

  /** Le brouillon en quelques lignes, pour le modèle. */
  get outline(): string {
    const lines: string[] = [`# ${this.courseTitle} (${ContentSource.label(this.source)})`];
    for (const section of this.sections.filter((s) => s.isIncluded)) {
      lines.push("## " + section.title + (section.week > 0 ? ` [semaine ${section.week}]` : ""));
      for (const item of section.items.slice(0, 30)) {
        let what: string;
        switch (item.kind) {
          case "series":
            what = `série ${item.seriesNumber ?? 0}` + (item.exercises.length === 0 ? "" : ` (${item.exercises.length} exercices)`);
            break;
          case "theory":
            what = item.videoCount > 0 ? `théorie, ${item.videoCount} vidéo(s)` : "théorie";
            break;
          default:
            what = item.kind;
            break;
        }
        lines.push(`- ${item.number !== "" ? item.number + " " : ""}${item.title} [${what}]`);
      }
    }
    return lines.join("\n");
  }

  /** La sémantique de valeur des `struct` Swift. */
  clone(): ContentDraft {
    return new ContentDraft({
      source: this.source, courseTitle: this.courseTitle, url: this.url,
      sections: this.sections.map((section) => section.clone()), weekGuide: { ...this.weekGuide },
    });
  }

  /** Ce que ce brouillon n'a pas, pris dans un autre : les séries absentes, et la théorie des semaines qui n'en ont pas. */
  completed(withOther: ContentDraft): ContentDraft {
    const result = this.clone();
    const series = new Set(this.sections.flatMap((s) => s.items)
      .filter((i) => i.kind === "series").map((i) => i.seriesNumber)
      .filter((n): n is number => n !== null));
    const theoryWeeks = new Set(this.sections.filter((s) => s.week > 0 && s.theoryCount > 0).map((s) => s.week));
    for (const section of withOther.sections.filter((s) => s.week > 0)) {
      const extra = section.items.filter((item) =>
        (item.kind === "series" && !series.has(item.seriesNumber ?? -1))
        || (item.kind === "theory" && !theoryWeeks.has(section.week)));
      if (extra.length === 0) continue;
      const index = result.sections.findIndex((s) => s.week === section.week);
      if (index >= 0) {
        result.sections[index].items.push(...extra);
      } else {
        result.sections.push(new ContentDraftSection({
          title: section.title, week: section.week, weekIsInferred: section.weekIsInferred,
          isIncluded: section.isIncluded, items: [...extra],
        }));
      }
    }
    result.sections.sort((lhs, rhs) => {
      if (lhs.week === 0 || rhs.week === 0) return lhs.week !== 0 && rhs.week === 0 ? -1 : 1;
      return lhs.week - rhs.week;
    });
    return result;
  }
}

// MARK: - Interprétation

const equalIgnoringCase = (a: string, b: string): boolean => a.toLowerCase() === b.toLowerCase();

/** `NSRegularExpression` : premier groupe capturé. */
function firstMatch(text: string, pattern: string): string | null {
  const regex = icuRegExp(pattern, "i");
  const match = regex.exec(text);
  return match && match[1] !== undefined ? match[1] : null;
}

function matches(text: string, pattern: string): boolean {
  return icuRegExp(pattern, "i").test(text);
}

/** `.count` / `.prefix` d'un `Character` Swift : des graphèmes. */
const graphemes = (text: string): string[] => [...text];
const graphemeCount = (text: string): number => graphemes(text).length;

export const ContentDraftBuilder = {
  /** Transforme une page lue en brouillon : types, numéros, semaines. */
  draft(from: ScrapedCourse, source: ContentSource, termStart: Date | null,
        totalWeeks = 14): ContentDraft {
    const sections: ContentDraftSection[] = [];
    const seriesSeen = new Set<number>();
    let nextSeries = 1;
    let chapterIndex = 0;

    for (const scraped of from.sections) {
      const sectionTitle = ContentDraftBuilder.cleanTitle(scraped.title);
      const explicitWeek = ContentDraftBuilder.week(sectionTitle, termStart);
      // Une section datée (« 7 septembre - 13 septembre ») n'a pas de numéro de
      // chapitre : son « 7 » est un jour.
      const chapter = explicitWeek === null
        ? (() => {
          const lead = ContentDraftBuilder.leadingNumber(sectionTitle);
          const value = lead ? swiftInt(lead.number) : null;
          return value;
        })()
        : null;
      const items: ContentDraftItem[] = [];
      let theoryIndex = 0;
      const isContentChapter = chapter !== null || explicitWeek !== null;

      if (isContentChapter || scraped.items.length > 0) chapterIndex += 1;
      const chapterLabel = chapter ?? explicitWeek ?? chapterIndex;

      for (const raw of scraped.items) {
        const title = ContentDraftBuilder.cleanTitle(raw.title);
        if (title === "") continue;
        const kind = ContentDraftBuilder.classify(raw, title, source);
        if (kind === "series") {
          let number = ContentDraftBuilder.seriesNumber(title) ?? nextSeries;
          // Un même numéro vu deux fois (« Série 3 », « Série 3 (PDF) ») : c'est la même série.
          if (seriesSeen.has(number)) {
            if (ContentDraftBuilder.seriesNumber(title) !== null) continue;
            while (seriesSeen.has(number)) number += 1;
          }
          seriesSeen.add(number);
          nextSeries = Math.max(nextSeries, number + 1);
          items.push(new ContentDraftItem({
            kind: "series", number: String(number), title, url: raw.url, videoCount: 0,
            seriesNumber: number, theoryKind: "reading",
          }));
        } else {
          theoryIndex += 1;
          if (raw.type === "recording") {
            // L'enregistrement d'un cours : sa semaine est celle de sa date.
            const index = firstMatch(ContentDraftBuilder.fold(title), String.raw`^cours\s*0*(\d{1,3})\b`);
            const n = index !== null ? swiftInt(index) : null;
            const week = ContentDraftBuilder.week(title, termStart);
            items.push(new ContentDraftItem({
              kind: "theory", number: `C${n ?? theoryIndex}`, title, url: raw.url, videoCount: 1,
              seriesNumber: null, theoryKind: "video",
              week: week === null ? null : Math.min(week, Math.max(totalWeeks, 1)),
            }));
            continue;
          }
          const lead = ContentDraftBuilder.leadingNumber(title);
          const number = lead?.number ?? `${chapterLabel}.${theoryIndex}`;
          const videos = raw.videoCount ?? (ContentDraftBuilder.isVideo(raw) ? 1 : 0);
          const item = new ContentDraftItem({
            kind, number,
            title: lead ? (lead.rest === "" ? title : lead.rest) : title,
            url: raw.url, videoCount: videos, seriesNumber: null,
            theoryKind: ContentDraftBuilder.theoryKind(raw, title, videos),
          });
          // Chaque vidéo d'une leçon Courseware, liée directement.
          item.links = (raw.links ?? []).map((link) => ({
            title: link.title === "" ? title : ContentDraftBuilder.cleanTitle(link.title),
            url: link.url, kind: link.kind,
          }));
          items.push(item);
        }
      }

      if (items.length === 0) continue;
      const useful = items.some((i) => i.kind !== "ignore");
      const dated = items.length > 0 && items.every((i) => i.week !== null);
      const weeks = items.map((i) => i.week).filter((w): w is number => w !== null);
      sections.push(new ContentDraftSection({
        title: sectionTitle,
        week: explicitWeek ?? (dated ? (weeks.length > 0 ? Math.min(...weeks) : 0) : 0),
        weekIsInferred: explicitWeek === null && !dated,
        isIncluded: useful && !ContentDraftBuilder.isFrontMatter(sectionTitle),
        items,
      }));
    }

    if (source === "botafogo") {
      // Un polycopié n'a pas de semaines : on étale la matière à proportion de son volume.
      ContentDraftBuilder.spreadByVolume(sections, totalWeeks);
    } else if (!sections.some((s) => !s.weekIsInferred)) {
      // Aucune semaine lue sur la page : une section par semaine, dans l'ordre.
      let week = 0;
      for (const section of sections) {
        if (!section.isIncluded) continue;
        week += 1;
        section.week = Math.min(week, Math.max(totalWeeks, 1));
      }
    }

    return new ContentDraft({
      source, courseTitle: ContentDraftBuilder.cleanTitle(from.title), url: from.url, sections,
    });
  },

  /** Répartit les éléments de théorie des sections incluses sur `totalWeeks` semaines, chacun pesant `1 + vidéos`. */
  spreadByVolume(sections: ContentDraftSection[], totalWeeks: number): void {
    const weeks = Math.max(totalWeeks, 1);
    const slots: { section: number; item: number; weight: number }[] = [];
    sections.forEach((section, s) => {
      if (!section.isIncluded || !section.weekIsInferred) return;
      section.items.forEach((item, i) => {
        if (item.kind === "theory" && item.week === null) slots.push({ section: s, item: i, weight: 1 + item.videoCount });
      });
    });
    const total = slots.reduce((n, s) => n + s.weight, 0);
    if (!(total > 0)) return;
    let cumulative = 0;
    for (const slot of slots) {
      const week = Math.min(weeks, Math.trunc((cumulative / total) * weeks) + 1);
      sections[slot.section].items[slot.item].week = week;
      cumulative += slot.weight;
    }
    sections.forEach((section) => {
      if (section.isIncluded && section.weekIsInferred) section.week = section.weekRange?.lower ?? 0;
    });
  },

  // MARK: Règles

  ignoredTypes: new Set([
    "forum", "label", "choice", "feedback", "questionnaire", "attendance",
    "zoom", "chat", "wiki", "glossary", "survey", "data", "lti", "bigbluebuttonbn",
    "quiz", "workshop", "subsection",
  ]),

  /** Théorie, série, ou rien. */
  classify(item: ScrapedItem, title: string, source: ContentSource): ContentItemKind {
    const lower = ContentDraftBuilder.fold(title);
    const type = item.type.toLowerCase();
    if (ContentDraftBuilder.ignoredTypes.has(type)) return "ignore";
    if (matches(lower, String.raw`\b(annonces?|announcements?|news|forum|discussion|sondage|feedback|informations? generales?)\b`)) {
      return "ignore";
    }
    // Un corrigé accompagne une série ; ce n'est pas une série de plus.
    if (matches(lower, String.raw`\b(corrige|corriges|correction|corrections|solutions?|loesung|answers?)\b`)) {
      return "ignore";
    }
    if (matches(lower, String.raw`\b(series?|exercices?|exercises?|problem ?sets?|td|homeworks?|devoirs?|assignments?|feuilles? d.exercices)\b`)
        && !matches(lower, String.raw`\b(series (numeriques|entieres|de fourier|de taylor|telescopiques|geometriques?))\b`)
        && source !== "botafogo") {
      return "series";
    }
    if (type === "assign") return "series";
    return "theory";
  },

  isVideo(item: ScrapedItem): boolean {
    const type = item.type.toLowerCase();
    if (["kalvidres", "mediaspace", "video", "kalturavideo", "hvp"].includes(type)) return true;
    const haystack = ContentDraftBuilder.fold(item.title + " " + item.url);
    return matches(haystack, String.raw`(youtube|youtu\.be|vimeo|mediaspace|tube\.switch|kaltura|\bvideos?\b)`);
  },

  theoryKind(item: ScrapedItem, title: string, videos: number): TheoryKind {
    const lower = ContentDraftBuilder.fold(title);
    if (matches(lower, String.raw`\b(slides?|diapos?|diapositives?|transparents?)\b`)) return "slides";
    if (videos > 0 || ContentDraftBuilder.isVideo(item)) return "video";
    if (matches(lower, String.raw`\b(chapitre|chapter)\b`)) return "chapter";
    return "reading";
  },

  /** Préface, avant-propos, outils : pas de la matière à planifier. */
  isFrontMatter(title: string): boolean {
    const lower = ContentDraftBuilder.fold(title);
    return matches(lower, String.raw`\b(preface|avant-propos|foreword|generalites du cours|informations generales|general|outils graphiques)\b`);
  },

  // MARK: Numéros

  /** Le numéro de série d'un titre : « Série 3 », « Serie_03 », « Exercise set 4 ». */
  seriesNumber(title: string): number | null {
    const lower = ContentDraftBuilder.fold(title);
    const pattern = String.raw`(?:series?|(?:exercices?|exercises?)(?:\s+sets?)?|problem ?sets?|td|homeworks?|devoirs?|assignments?|feuilles?)[\s_#.:-]*(?:n[o°]?\s*)?0*(\d{1,2})\b`;
    const match = firstMatch(lower, pattern);
    return match === null ? null : swiftInt(match);
  },

  /** Le numéro en tête d'un titre : « 3.2 Limite » → (3.2, Limite), « II.4 Trigonométrie » → (II.4, …). */
  leadingNumber(title: string): { number: string; rest: string } | null {
    const trimmed = trimWhitespaces(title);
    const patterns = [
      String.raw`^(?:chapitre|chapter|ch\.|section|lecon|leçon|lesson|module|partie|part|cours|lecture|vid[ée]o|video|th[ée]orie)\s*(\d+(?:\.\d+)*)\s*[:.\-–—]?\s*(.*)$`,
      String.raw`^(\d+(?:\.\d+)+|\d+)[.)]?\s+(.*)$`,
      String.raw`^([IVX]+\.\d+)\s+(.*)$`,
    ];
    for (const pattern of patterns) {
      const regex = icuRegExp(pattern, "i");
      const match = regex.exec(trimmed);
      if (!match) continue;
      const rest = match[2] ?? "";
      const number = match[1].replace(/^\.+|\.+$/g, "");
      // « 2025 Examen » n'est pas un chapitre 2025.
      const value = swiftInt(number);
      if (value !== null && value > 60) return null;
      return { number, rest: trimWhitespaces(rest) };
    }
    return null;
  },

  // MARK: Semaines

  months: new Map<string, number>(Object.entries({
    janvier: 1, janv: 1, january: 1, jan: 1,
    fevrier: 2, fevr: 2, february: 2, feb: 2,
    mars: 3, march: 3, mar: 3,
    avril: 4, april: 4, apr: 4, avr: 4,
    mai: 5, may: 5,
    juin: 6, june: 6, jun: 6,
    juillet: 7, july: 7, jul: 7, juil: 7,
    aout: 8, august: 8, aug: 8,
    septembre: 9, september: 9, sept: 9, sep: 9,
    octobre: 10, october: 10, oct: 10,
    novembre: 11, november: 11, nov: 11,
    decembre: 12, december: 12, dec: 12,
  })),

  /** La semaine qu'un titre de section annonce. */
  week(title: string, termStart: Date | null): number | null {
    const lower = ContentDraftBuilder.fold(title);
    const explicit = firstMatch(lower, String.raw`\b(?:semaine|week|sem\.?|wk)\s*0*(\d{1,2})\b`);
    if (explicit !== null) {
      const week = swiftInt(explicit);
      if (week !== null && week > 0) return week;
    }
    const short = firstMatch(lower, String.raw`^s0*(\d{1,2})\b`);
    if (short !== null) {
      const week = swiftInt(short);
      if (week !== null && week > 0) return week;
    }
    if (termStart === null) return null;
    const regex = icuRegExp(String.raw`\b(\d{1,2})\.?\s+([a-z]+)\.?`, "g");
    for (const match of lower.matchAll(regex)) {
      const day = swiftInt(match[1]);
      const month = ContentDraftBuilder.months.get(match[2]);
      if (day === null || month === undefined) continue;
      const startYear = termStart.getFullYear();
      const startMonth = termStart.getMonth() + 1;
      // Un semestre d'automne déborde sur janvier de l'année suivante.
      const year = month < startMonth - 2 ? startYear + 1 : startYear;
      const date = new Date(year, month - 1, day);
      if (Number.isNaN(date.getTime())) continue;
      const startOfDay = new Date(termStart.getFullYear(), termStart.getMonth(), termStart.getDate());
      const days = DateUtils.daysBetween(startOfDay, date);
      if (!(days > -7)) return null;
      // La semaine d'enseignement, pause d'automne déduite.
      return DateUtils.weekNumber(termStart, date);
    }
    return null;
  },

  // MARK: Texte

  /** Espaces normalisés, délimiteurs LaTeX retirés, suffixes techniques de Moodle ôtés. */
  cleanTitle(rawText: string): string {
    // Les macros d'ensembles de Botafogo : « Nombres \bR » → « Nombres ℝ ».
    let raw = rawText;
    for (const [macro, symbol] of [["\\bR", "ℝ"], ["\\bC", "ℂ"], ["\\bN", "ℕ"], ["\\bZ", "ℤ"], ["\\bQ", "ℚ"]]) {
      raw = raw.split(macro).join(symbol);
    }
    // Un saut de ligne LaTeX (`\\`, deux caractères) sépare deux parties.
    let text = raw.split("\\\\").join(" · ");
    for (const token of ["\\(", "\\)", "\\[", "\\]", "$"]) text = text.split(token).join("");
    // Le code dans les titres du polycopié d'ICS.
    text = text.replace(/\\htmlTag\{[^}]*\}\{\\htmlAttr\{[^}]*\}\{[^}]*\}([^}]*)\}/g, "$1");
    for (const suffix of [" Fichier", " File", " URL", " Page", " Dossier", " Folder", " Devoir", " Assignment"]) {
      if (text.endsWith(suffix)) text = text.slice(0, text.length - suffix.length);
    }
    return text.split(/\s+/u).filter((part) => part !== "").join(" ");
  },

  /** Minuscules sans accents : « Série » et « serie » sont le même mot. */
  fold(text: string): string {
    return text.normalize("NFD").replace(/\p{M}+/gu, "").toLowerCase();
  },

  equalIgnoringCase,
};

// MARK: - Botafogo

/** Le polycopié en ligne de S. Friedli : une table des matières statique, puis une page par section. */
export const BotafogoParser = {
  /** Les cours listés sur la page d'accueil : (titre, adresse de la version en ligne). */
  catalog(html: string, baseURL: URL): { title: string; url: URL }[] {
    const pattern = String.raw`<span class="link-description">([^<]+)</span>\s*<a href="([^"]+)"`;
    const regex = new RegExp(pattern, "g");
    const result: { title: string; url: URL }[] = [];
    for (const match of html.matchAll(regex)) {
      let resolved: URL | null = null;
      try {
        resolved = new URL(match[2], baseURL);
      } catch {
        continue;
      }
      const title = ContentDraftBuilder.cleanTitle(BotafogoParser.decode(match[1]))
        .replace(/^[:\s]+|[:\s]+$/g, "");
      result.push({ title, url: resolved });
    }
    return result;
  },

  /** La table des matières : un chapitre par `had-nav-toplevel`, une section par `had-nav-link-secondlevel`. */
  parseTOC(html: string, baseURL: URL): ScrapedCourse {
    const titleCapture = BotafogoParser.firstCapture(html, String.raw`<title>\s*([^<|]+)`);
    const title = titleCapture !== null
      ? ContentDraftBuilder.cleanTitle(BotafogoParser.decode(titleCapture)) : "Botafogo";
    const sections: ScrapedSection[] = [];
    const chapters = html.split('<li class="had-nav-toplevel">').slice(1);
    for (const chunk of chapters) {
      const chapterTitle = BotafogoParser.firstCapture(chunk, String.raw`<a href="#[^"]*"[^>]*>([^<]+)</a>`);
      if (chapterTitle === null) continue;
      const items: ScrapedItem[] = [];
      const regex = new RegExp(String.raw`<li class="had-nav-link-secondlevel"[^>]*><a href="([^"]+)">(.*?)</a></li>`, "g");
      for (const match of chunk.matchAll(regex)) {
        const href = match[1];
        let url: string;
        try {
          url = new URL(href, baseURL).toString();
        } catch {
          url = href;
        }
        items.push(ScrapedItem.make(BotafogoParser.decode(BotafogoParser.stripTags(match[2])), { url, type: "section" }));
      }
      sections.push(ScrapedSection.make(BotafogoParser.decode(chapterTitle), items));
    }
    return ScrapedCourse.make("botafogo", title, baseURL.toString(), sections);
  },

  home: new URL("https://botafogo.epfl.ch/"),

  /** `…/analyse-1/resources/sections/x.html` → `…/analyse-1/`. */
  courseRoot(of: URL): URL {
    const parts = of.pathname.split("/").filter((p) => p !== "");
    const first = parts[0];
    if (first === undefined) return BotafogoParser.home;
    try {
      return new URL(`/${first}/`, BotafogoParser.home);
    } catch {
      return BotafogoParser.home;
    }
  },

  // MARK: Polycopiés Nuxt

  /** La page redirige-t-elle ailleurs (`<meta http-equiv="refresh" …>`) ? */
  metaRefresh(html: string, baseURL: URL): URL | null {
    if (graphemeCount(html) >= 4000) return null;
    const target = BotafogoParser.firstCapture(html, String.raw`http-equiv="refresh"[^>]*url=([^"'>]+)`);
    if (target === null) return null;
    try {
      return new URL(trimWhitespaces(target), baseURL);
    } catch {
      return null;
    }
  },

  /** La table des matières d'un polycopié Nuxt (analyse-b, ICS, algèbre linéaire, Analyse I GM et classe inversée). */
  parseNuxt(html: string, pageURL: URL): ScrapedCourse | null {
    const payload = NuxtPayload.fromHTML(html);
    if (payload === null) return null;
    const navigation = payload.navigation();
    const chapters = navigation.chapters;
    if (chapters.length === 0) return null;
    const root = BotafogoParser.siteRoot(html, pageURL);
    const queryRouted = html.includes("?cours=");
    const link = (path: string): string => {
      if (queryRouted) {
        const encoded = encodeURIComponent(path).replace(/%2F/g, "/");
        return BotafogoLinks.polycopieURL(root, encoded);
      }
      const trimmedRoot = root.toString().endsWith("/") ? root.toString().slice(0, -1) : root.toString();
      return trimmedRoot + (path.startsWith("/") ? path : "/" + path);
    };
    const sections = chapters.map((chapter) => ScrapedSection.make(
      BotafogoParser.decode(chapter.title),
      chapter.children.map((child) => ScrapedItem.make(
        BotafogoParser.decode(child.title), { url: link(child.path), type: "section" })),
    ));
    // Le titre de la page est celui de la **section** affichée : le nom du
    // polycopié vient du nœud racine du sommaire, sinon du titre de la page.
    const pageTitleCapture = BotafogoParser.firstCapture(html, String.raw`<title>\s*([^<|]+)`);
    const pageTitle = pageTitleCapture !== null
      ? ContentDraftBuilder.cleanTitle(BotafogoParser.decode(pageTitleCapture)) : null;
    const title = navigation.title !== null
      ? ContentDraftBuilder.cleanTitle(BotafogoParser.decode(navigation.title))
      : (pageTitle !== null && ContentDraftBuilder.leadingNumber(pageTitle) === null ? pageTitle : "Botafogo");
    return ScrapedCourse.make("botafogo", title, root.toString(), sections);
  },

  /** La racine du site : `baseURL` de la configuration Nuxt, sinon le premier segment du chemin. */
  siteRoot(html: string, pageURL: URL): URL {
    const base = BotafogoParser.firstCapture(html, String.raw`baseURL:"([^"]+)"`);
    if (base !== null) {
      const path = base.endsWith("/") ? base : base + "/";
      try {
        return new URL(path, pageURL);
      } catch {
        // continue
      }
    }
    return BotafogoParser.courseRoot(pageURL);
  },

  /** La page « vidéos » d'un site de cours, quand il en a une. */
  videosPage(html: string, root: URL): URL | null {
    const section = BotafogoParser.firstCapture(html, String.raw`\?cours=(sections/[A-Za-z0-9_-]*vid[A-Za-z0-9_-]*)`);
    if (section === null) return null;
    try {
      return new URL(BotafogoLinks.coursURL(root, section));
    } catch {
      return null;
    }
  },

  /** Les enregistrements des cours, avec leur date. Les directs (« Streaming ») n'en sont pas. */
  recordings(html: string): ScrapedItem[] {
    const payload = NuxtPayload.fromHTML(html);
    if (payload === null) return [];
    const strings = payload.strings;
    const items: ScrapedItem[] = [];
    const seen = new Set<string>();
    for (let index = 0; index + 1 < strings.length; index += 1) {
      const value = strings[index];
      if (!/^[01]_[a-z0-9]{8}$/.test(value)) continue;
      const title = trimWhitespaces(BotafogoParser.decode(strings[index + 1]));
      const folded = ContentDraftBuilder.fold(title);
      if (folded.includes("streaming")) continue;
      if (!icuRegExp(String.raw`\b\d{1,2}\.?\s+[a-z]+\.?\s+\d{4}\b`, "i").test(folded)) continue;
      if (seen.has(value)) continue;
      seen.add(value);
      items.push(ScrapedItem.make(title, {
        url: `https://${Institution.current.video?.host ?? "mediaspace.epfl.ch"}/media/${value}`,
        type: "recording", videoCount: 1,
      }));
    }
    return items;
  },

  /** Les vidéos de cours d'une page de section (pas les petites animations). */
  videoTitles(inSection: string): string[] {
    const parts = inSection.split('<div class="video">').slice(1);
    const result: string[] = [];
    for (const part of parts) {
      if (!part.includes("video-plyr")) continue;
      const title = BotafogoParser.firstCapture(part, String.raw`class="video-button"[^>]*>([^<]+)</a>`);
      result.push(title === null ? "Vidéo" : BotafogoParser.decode(title));
    }
    return result;
  },

  // MARK: Outils

  firstCapture(text: string, pattern: string): string | null {
    const regex = icuRegExp(pattern, "s");
    const match = regex.exec(text);
    return match && match[1] !== undefined ? trimAll(match[1]) : null;
  },

  stripTags(text: string): string {
    return text.replace(/<[^>]+>/g, "");
  },

  decode(text: string): string {
    let result = text;
    const entities: [string, string][] = [
      ["&amp;", "&"], ["&lt;", "<"], ["&gt;", ">"], ["&quot;", "\""], ["&#39;", "'"],
      ["&#x27;", "'"], ["&apos;", "'"], ["&nbsp;", " "], ["&#x2F;", "/"], ["&rsquo;", "'"],
    ];
    for (const [entity, value] of entities) result = result.split(entity).join(value);
    // Le reste des entités, un texte relu en Latin-1 en route et les accents détachés.
    return TextRepair.clean(result);
  },
};

// Les types de `ContentLink` restent ceux des modèles (`jsonTypes.ts`).
export type ContentLink = ModelContentLink;
export const ContentLink = { decodeList, encodeList };
