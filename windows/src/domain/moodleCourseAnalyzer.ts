// Comprend un cours Moodle comme un·e étudiant·e le lit
// (Polymestre/Domain/MoodleCourseAnalyzer.swift).
//
// Une page Moodle est une liste d'activités posées par l'enseignant·e, dans ses
// mots. L'analyse **regroupe** ce qui va ensemble, **distingue** ce qu'on suit de
// ce qui a une date, et **range** chaque élément à sa semaine.

import { ExamKind } from "../models/enums.ts";
import { decodeList, encodeList, type ContentLinkKind } from "../models/jsonTypes.ts";
import { swiftInt } from "../services/seriesPDFParser.ts";
import { trimWhitespaces } from "../models/util.ts";
import { capitalizedFirst } from "./dateUtils.ts";
import { icuRegExp } from "./icuRegExp.ts";
import { MoodleLinks } from "./botafogoProgram.ts";
import { SeriesIdentity, type SeriesKey } from "./seriesIdentity.ts";

type SeriesGroup = { key: SeriesKey; statement: MoodleActivity[]; solution: MoodleActivity[] };
import {
  ContentDraft, ContentDraftBuilder, ContentDraftItem, ContentDraftSection,
} from "./courseContentImport.ts";

export type { ContentLinkKind };

/** Un lien d'un élément : la vidéo d'un cours, ses transparents, un corrigé. */
export interface ContentLink {
  title: string;
  url: string;
  kind: ContentLinkKind;
}

export const ContentLink = {
  icon(kind: ContentLinkKind): string {
    switch (kind) {
      case "video": return "play.rectangle";
      case "slides": return "rectangle.on.rectangle";
      case "notes": return "pencil.and.scribble";
      case "pdf": return "doc.richtext";
      case "page": return "safari";
      case "solution": return "checkmark.seal";
    }
  },

  decodeList(raw: string): ContentLink[] {
    return decodeList<ContentLink>(raw);
  },

  encodeList(links: ContentLink[]): string {
    return encodeList(links);
  },
};

/** Un document d'un cours, gardé comme lien : ni théorie ni série. */
export interface CourseDocument {
  title: string;
  url: string;
  group: string;
  kind: ContentLinkKind;
}

export const CourseDocument = {
  id(document: CourseDocument): string { return document.url + document.title; },
  decodeList(raw: string): CourseDocument[] { return decodeList<CourseDocument>(raw); },
  encodeList(documents: CourseDocument[]): string { return encodeList(documents); },
};

// MARK: - Ce que Moodle donne d'un cours

export interface MoodleActivityInit {
  id: string;
  name: string;
  module: string;
  url: string;
  target?: string | null;
  dueDate?: Date | null;
  solutionTarget?: string | null;
  isVisible?: boolean;
  destination?: string | null;
  preview?: string | null;
}

/** Une activité d'un cours Moodle, telle que l'app l'a lue. */
export class MoodleActivity {
  id: string;
  name: string;
  module: string;
  /** La page de l'activité sur Moodle. */
  url: string;
  /** Où mène vraiment une activité « lien ». */
  target: string | null;
  /** L'échéance d'un devoir, lue sur sa page. */
  dueDate: Date | null;
  /** Le corrigé posé à côté de l'énoncé. */
  solutionTarget: string | null;
  isVisible: boolean;
  /** Ce que la cible est vraiment : `pdf`, `page`, `video`, `mooc`, `dossier`… */
  destination: string | null;
  /** Le début de son texte : ce qu'un·e étudiant·e verrait en l'ouvrant. */
  preview: string | null;

  constructor(o: MoodleActivityInit) {
    this.id = o.id;
    this.name = o.name;
    this.module = o.module;
    this.url = o.url;
    this.target = o.target ?? null;
    this.dueDate = o.dueDate ?? null;
    this.solutionTarget = o.solutionTarget ?? null;
    this.isVisible = o.isVisible ?? true;
    this.destination = o.destination ?? null;
    this.preview = o.preview ?? null;
  }

  /** L'adresse à ouvrir : la cible réelle quand on la connaît. */
  get link(): string {
    return this.target !== null && this.target !== "" ? this.target : this.url;
  }
}

/** Un lien Moodle vers un cours Courseware, et la section où il apparaît. */
export class MoocReference {
  url: string;
  title: string;
  /** Le numéro de la section Moodle. */
  sectionNumber: number | null;

  constructor(o: { url: string; title: string; sectionNumber?: number | null }) {
    this.url = o.url;
    this.title = o.title;
    this.sectionNumber = o.sectionNumber ?? null;
  }

  /** `course-v1:EPFL+AlgebreLineaire+2026`. */
  get courseKey(): string | null { return MoocReference.courseKey(this.url); }

  static courseKey(url: string): string | null {
    const text = safeDecode(url);
    const range = /course-v1:[^/?#]+/.exec(text);
    return range === null ? null : range[0];
  }

  /** Le bloc visé (`block-v1:…`), quand le lien pointe dans le cours. */
  get blockID(): string | null {
    const text = safeDecode(this.url);
    const range = /block-v1:[^/?#]+/.exec(text);
    return range === null ? null : range[0];
  }
}

export interface MoodleSectionInit {
  number: number;
  title: string;
  activities: MoodleActivity[];
  text?: string;
  links?: ContentLink[];
}

export class MoodleSection {
  number: number;
  title: string;
  activities: MoodleActivity[];
  /** Le texte de la section (résumé, étiquettes) : souvent la consigne de la semaine. */
  text: string;
  /** Les liens de ce texte. */
  links: ContentLink[];

  constructor(o: MoodleSectionInit) {
    this.number = o.number;
    this.title = o.title;
    this.activities = o.activities;
    this.text = o.text ?? "";
    this.links = o.links ?? [];
  }
}

export interface MoodleCourseSnapshotInit {
  title: string;
  url: string;
  sections: MoodleSection[];
  moocLinks?: MoocReference[];
  unopened?: number;
}

export class MoodleCourseSnapshot {
  title: string;
  url: string;
  sections: MoodleSection[];
  /** Les liens vers un MOOC trouvés dans le cours. */
  moocLinks: MoocReference[];
  /** Les activités qui n'ont pas été ouvertes. */
  unopened: number;

  constructor(o: MoodleCourseSnapshotInit) {
    this.title = o.title;
    this.url = o.url;
    this.sections = o.sections;
    this.moocLinks = o.moocLinks ?? [];
    this.unopened = o.unopened ?? 0;
  }

  get activityCount(): number { return this.sections.reduce((n, s) => n + s.activities.length, 0); }
}

// MARK: - L'analyse

export type ActivityKind = "lecture" | "series" | "solution" | "deadline" | "document" | "ignore";

export const ActivityKind = {
  allCases: ["lecture", "series", "solution", "deadline", "document", "ignore"] as readonly ActivityKind[],
};

export type SectionRole = "content" | "general" | "exam" | "pastExams" | "project";

export const SectionRole = {
  allCases: ["content", "general", "exam", "pastExams", "project"] as readonly SectionRole[],
};

const matches = (text: string, pattern: string): boolean => icuRegExp(pattern, "i").test(text);

function firstMatch(text: string, pattern: string): string | null {
  const match = icuRegExp(pattern, "i").exec(text);
  return match && match[1] !== undefined ? match[1] : null;
}

function matchesAll(text: string, pattern: string): string[] {
  const result: string[] = [];
  for (const match of text.matchAll(icuRegExp(pattern, "g"))) if (match[1] !== undefined) result.push(match[1]);
  return result;
}

function safeDecode(text: string): string {
  try {
    return decodeURIComponent(text);
  } catch {
    return text;
  }
}

const pathExtension = (pathname: string): string => {
  const last = pathname.split("/").filter((p) => p !== "").pop() ?? "";
  const dot = last.lastIndexOf(".");
  return dot > 0 ? last.slice(dot + 1).toLowerCase() : "";
};

const sortedSections = (left: ContentDraftSection, right: ContentDraftSection): number => {
  if (left.week === 0 || right.week === 0) return left.week !== 0 && right.week === 0 ? -1 : 1;
  return left.week - right.week;
};

export const MoodleCourseAnalyzer = {
  /** `MoodleCourseAnalyzer.ActivityKind` / `SectionRole` (Validation/main.swift). */
  ActivityKind,
  SectionRole,

  /** « Semaine 3 : Structures de contrôle (semaine courante) » : la mention du moment n'est pas le titre. */
  sectionTitle(section: MoodleSection): string {
    return ContentDraftBuilder.cleanTitle(section.title)
      .replace(/\s*\((semaine courante|current week|cette semaine|this week)\)/gi, "");
  },

  /** La semaine d'une section, lue dans son titre (numéro ou dates). */
  week(section: MoodleSection, termStart: Date | null, totalWeeks = 14): number | null {
    const value = ContentDraftBuilder.week(MoodleCourseAnalyzer.sectionTitle(section), termStart);
    return value === null ? null : Math.min(value, Math.max(totalWeeks, 1));
  },

  draft(from: MoodleCourseSnapshot, termStart: Date | null, totalWeeks = 14,
        hints: Record<string, { kind?: ActivityKind | null; week?: number | null; seriesNumber?: number | null }> = {}): ContentDraft {
    // Ce que le modèle a compris d'activités aux noms inattendus.
    const snapshot = MoodleCourseAnalyzer.relocate(from, hints, termStart, totalWeeks);
    const classify = (activity: MoodleActivity, inWeek: boolean): ActivityKind => {
      // Le modèle, qui a lu la cible et les consignes, tranche.
      if (hints[activity.id]?.kind !== undefined && hints[activity.id]?.kind !== null) return hints[activity.id].kind!;
      const kind = MoodleCourseAnalyzer.classify(activity, inWeek);
      // Sans lui, un lien vers un MOOC n'est pas une série du cours.
      if ((kind === "series" || kind === "solution")
          && (activity.destination === "mooc" || MoocReference.courseKey(activity.link) !== null)) {
        return "document";
      }
      return kind;
    };
    const sections: ContentDraftSection[] = [];
    const documents: ContentDraftItem[] = [];
    const pastExams: ContentDraftItem[] = [];
    const deadlines: ContentDraftItem[] = [];
    // Les séries posées hors de leur semaine.
    // Clé : numéro et étiquette (« 5a », « 5b ») — `SeriesIdentity.id`.
    const loose = new Map<string, { key: SeriesKey; statement: MoodleActivity[]; solution: MoodleActivity[] }>();
    const addLoose = (activity: MoodleActivity, number: number, solution: boolean) => {
      const key = SeriesIdentity.key(number, SeriesIdentity.label(activity.name));
      const entry = loose.get(SeriesIdentity.id(key)) ?? { key, statement: [], solution: [] };
      if (solution) entry.solution.push(activity);
      else entry.statement.push(activity);
      loose.set(SeriesIdentity.id(key), entry);
    };

    for (const section of snapshot.sections) {
      const title = MoodleCourseAnalyzer.sectionTitle(section);
      const role = MoodleCourseAnalyzer.role(title, section.number);
      const week = MoodleCourseAnalyzer.week(section, termStart, totalWeeks);
      const visible = section.activities.filter((a) => a.isVisible);

      switch (role) {
        case "exam": {
          const date = MoodleCourseAnalyzer.examDate(title, termStart);
          if (date !== null) {
            deadlines.push(MoodleCourseAnalyzer.deadlineItem(
              MoodleCourseAnalyzer.examTitle(title), date, "exam", snapshot.url));
          }
          documents.push(...visible.map((activity) => MoodleCourseAnalyzer.document(activity, title)));
          continue;
        }
        case "pastExams":
          pastExams.push(...MoodleCourseAnalyzer.pastExamItems(visible));
          continue;
        case "general": {
          for (const activity of visible) {
            const kind = classify(activity, false);
            const number = MoodleCourseAnalyzer.seriesNumber(activity.name) ?? hints[activity.id]?.seriesNumber ?? null;
            switch (kind) {
              case "deadline":
                deadlines.push(MoodleCourseAnalyzer.deadline(activity));
                break;
              case "ignore":
                continue;
              case "series":
                if (number !== null) { addLoose(activity, number, false); continue; }
                documents.push(MoodleCourseAnalyzer.document(activity, title));
                break;
              case "solution":
                if (number !== null && !MoodleCourseAnalyzer.isDeliverableSolution(activity.name)) {
                  addLoose(activity, number, true);
                  continue;
                }
                documents.push(MoodleCourseAnalyzer.document(activity, title));
                break;
              default:
                documents.push(MoodleCourseAnalyzer.document(activity, title));
                break;
            }
          }
          continue;
        }
        case "project": {
          for (const activity of visible) {
            const item = MoodleCourseAnalyzer.projectDeadline(activity, title, termStart);
            if (item !== null) deadlines.push(item);
            else if (classify(activity, false) !== "ignore") documents.push(MoodleCourseAnalyzer.document(activity, title));
          }
          continue;
        }
        case "content":
          break;
      }

      const items: ContentDraftItem[] = [];
      const lectureGroups: { key: string; activities: MoodleActivity[] }[] = [];
      const seriesGroups: SeriesGroup[] = [];

      // Deux séries la même semaine : le numéro, et l'étiquette qui les sépare.
      const addToSeries = (key: SeriesKey, statement: MoodleActivity | null = null, solution: MoodleActivity | null = null) => {
        const index = seriesGroups.findIndex((g) => SeriesIdentity.same(g.key, key));
        if (index >= 0) {
          if (statement !== null) seriesGroups[index].statement.push(statement);
          if (solution !== null) seriesGroups[index].solution.push(solution);
        } else {
          seriesGroups.push({
            key,
            statement: statement !== null ? [statement] : [],
            solution: solution !== null ? [solution] : [],
          });
        }
      };

      // Un dossier déplié qui porte plusieurs séries numérotées.
      const folderNumbers = new Set(visible
        .filter((a) => MoodleCourseAnalyzer.isFromFolder(a) && classify(a, true) === "series")
        .map((a) => MoodleCourseAnalyzer.seriesNumber(a.name))
        .filter((n): n is number => n !== null));
      const spreadsFolder = folderNumbers.size >= 2;

      // Les corrigés d'abord mis de côté : ils se rattachent à leur série.
      const pendingSolutions: MoodleActivity[] = [];
      // Les énoncés sans numéro ni étiquette : une série de la semaine, ou plusieurs.
      const unnumbered: MoodleActivity[] = [];
      for (const activity of visible) {
        const kind = classify(activity, true);
        if (spreadsFolder && MoodleCourseAnalyzer.isFromFolder(activity)) {
          const number = MoodleCourseAnalyzer.seriesNumber(activity.name);
          if (number !== null && (kind === "series" || (kind === "solution" && !MoodleCourseAnalyzer.isDeliverableSolution(activity.name)))) {
            addLoose(activity, number, kind === "solution");
            continue;
          }
        }
        switch (kind) {
          case "series": {
            // Sans numéro, la série prend celui de la semaine où Moodle la pose.
            const explicit = MoodleCourseAnalyzer.seriesNumber(activity.name) ?? hints[activity.id]?.seriesNumber ?? null;
            const number = explicit ?? week ?? section.number;
            const key = SeriesIdentity.key(number, SeriesIdentity.label(activity.name));
            if (explicit === null && key.label === "" && MoodleCourseAnalyzer.isStatementDocument(activity)) {
              unnumbered.push(activity);
              break;
            }
            // « Enoncé/Corrigé de la série 4 » : l'énoncé et le corrigé à la même adresse.
            const both = ContentDraftBuilder.fold(activity.name).includes("corrig")
              && ContentDraftBuilder.fold(activity.name).includes("enonc");
            addToSeries(key, activity, both ? activity : null);
            break;
          }
          case "solution":
            pendingSolutions.push(activity);
            break;
          case "lecture": {
            // **Un élément par semaine** : le cours du mardi, celui du mercredi,
            // leurs enregistrements et leurs transparents sont le travail de la semaine.
            const key = week !== null ? `w${week}` : MoodleCourseAnalyzer.lectureKey(activity.name);
            const index = lectureGroups.findIndex((g) => g.key === key);
            if (index >= 0) lectureGroups[index].activities.push(activity);
            else lectureGroups.push({ key, activities: [activity] });
            break;
          }
          case "deadline":
            deadlines.push(MoodleCourseAnalyzer.deadline(activity));
            break;
          case "document":
            documents.push(MoodleCourseAnalyzer.document(activity, title));
            break;
          case "ignore":
            continue;
        }
      }
      // Deux PDF d'énoncé sans numéro ni jour la même semaine : deux séries,
      // « 1 » et « 2 » dans l'ordre de Moodle. Un seul : la série de la semaine.
      const distinctNames = new Set(unnumbered.map((a) => ContentDraftBuilder.fold(a.name)));
      unnumbered.forEach((activity, rank) => {
        const label = unnumbered.length > 1 && distinctNames.size === unnumbered.length ? String(rank + 1) : "";
        addToSeries(SeriesIdentity.key(week ?? section.number, label), activity);
      });
      for (const solution of pendingSolutions) {
        const explicit = MoodleCourseAnalyzer.seriesNumber(solution.name);
        const label = SeriesIdentity.normalized(SeriesIdentity.label(solution.name));
        const sameNumber = seriesGroups.filter((g) => explicit === null || g.key.number === explicit);
        const sameLabel = sameNumber.filter((g) => g.key.label === label);
        const closest = MoodleCourseAnalyzer.closestByName(solution, sameNumber);
        if (MoodleCourseAnalyzer.isDeliverableSolution(solution.name)) {
          // « rendu02 sol » : le corrigé d'un rendu noté, un document.
          documents.push(MoodleCourseAnalyzer.document(solution, title));
        } else if (sameLabel.length > 0 && (sameLabel.length === 1 || explicit !== null)) {
          addToSeries(sameLabel[0].key, null, solution);
        } else if (sameNumber.length === 1) {
          addToSeries(sameNumber[0].key, null, solution);
        } else if (closest !== null) {
          // « Corrigé — Suites » pour « Exercices — Suites » : le nom les relie.
          addToSeries(closest, null, solution);
        } else if (label === "" && explicit !== null && sameNumber.length > 0) {
          // « Corrigé série 5 » pour « 5a » et « 5b » : le même corrigé pour les deux.
          for (const group of sameNumber) addToSeries(group.key, null, solution);
        } else if (explicit !== null || week !== null) {
          addToSeries(SeriesIdentity.key(explicit ?? week!, label), null, solution);
        }
      }

      lectureGroups.forEach((group, index) => {
        items.push(MoodleCourseAnalyzer.lectureItem(group.activities, group.key, index + 1,
                                                    title, week ?? 0, lectureGroups.length));
      });
      for (const group of [...seriesGroups].sort((a, b) => SeriesIdentity.compare(a.key, b.key))) {
        items.push(MoodleCourseAnalyzer.seriesItem(group.key, group.statement, group.solution));
      }
      if (items.length === 0) continue;
      sections.push(new ContentDraftSection({
        title, week: week ?? 0, weekIsInferred: week === null, isIncluded: true, items,
      }));
    }

    // Des sections sans semaine lisible (un plan par thème) : une par semaine, dans l'ordre.
    if (sections.some((s) => s.weekIsInferred) && !sections.some((s) => !s.weekIsInferred)) {
      sections.forEach((section, offset) => {
        section.week = Math.min(offset + 1, Math.max(totalWeeks, 1));
      });
    }
    // Les séries hors de leur semaine : la semaine de leur numéro.
    // « Corrigé série 5 » posé à part, pour « 5a » et « 5b » : il va aux deux.
    for (const [id, entry] of [...loose.entries()]) {
      if (entry.key.label !== "" || entry.statement.length > 0) continue;
      const siblings = [...loose.values()].filter((e) => e.key.number === entry.key.number && e.key.label !== "" && e.statement.length > 0);
      if (siblings.length === 0) continue;
      for (const sibling of siblings) sibling.solution.push(...entry.solution);
      loose.delete(id);
    }
    for (const entry of [...loose.values()].sort((a, b) => SeriesIdentity.compare(a.key, b.key))) {
      const number = entry.key.number;
      const item = MoodleCourseAnalyzer.seriesItem(entry.key, entry.statement, entry.solution);
      const week = Math.min(Math.max(number, 1), Math.max(totalWeeks, 1));
      const index = sections.findIndex((s) => s.week === week);
      if (index >= 0) sections[index].items.push(item);
      else {
        sections.push(new ContentDraftSection({
          title: `Semaine ${week}`, week, weekIsInferred: true, isIncluded: true, items: [item],
        }));
      }
    }
    MoodleCourseAnalyzer.joinStraySolutions(sections);

    // Semaines d'un cours rangées à l'envers : on les remet dans l'ordre.
    sections.sort(sortedSections);

    if (deadlines.length > 0) {
      sections.push(new ContentDraftSection({
        title: "Échéances : rendus, projet, examen", week: 0, weekIsInferred: false, isIncluded: true,
        items: deadlines.sort((a, b) => (a.date?.getTime() ?? Number.POSITIVE_INFINITY)
          - (b.date?.getTime() ?? Number.POSITIVE_INFINITY)),
      }));
    }
    if (pastExams.length > 0) {
      sections.push(new ContentDraftSection({
        title: "Anciens examens", week: 0, weekIsInferred: false, isIncluded: true, items: pastExams,
      }));
    }
    if (documents.length > 0) {
      sections.push(new ContentDraftSection({
        title: "Documents du cours (non suivis)", week: 0, weekIsInferred: false, isIncluded: true, items: documents,
      }));
    }

    return new ContentDraft({ source: "moodle", courseTitle: snapshot.title, url: snapshot.url, sections });
  },

  // MARK: Ce que le modèle a compris

  /** Applique au brouillon ce que le modèle a compris du cours entier. */
  apply(answer: import("./moodleAIHint.ts").MoodleCourseAIAnswer, original: ContentDraft,
        snapshot: MoodleCourseSnapshot, totalWeeks: number): ContentDraft {
    const draft = original.clone();
    const refs = MoodleCourseAIReferences(snapshot);
    const inWeeks = (week: number): boolean => week >= 1 && week <= Math.max(totalWeeks, 1);
    draft.weekGuide = {};
    for (const [week, text] of Object.entries(answer.guide)) {
      if (inWeeks(Number(week))) draft.weekGuide[Number(week)] = text;
    }

    for (const plan of answer.series) {
      const statementRef = plan.statement !== null ? refs.get(plan.statement) : undefined;
      const statement = statementRef?.url ?? null;
      let solution: string | null = null;
      if (plan.solution !== null) {
        const reference = refs.get(plan.solution);
        solution = reference?.solution ?? reference?.url ?? null;
      }
      if (solution === null && plan.statement !== null) {
        solution = refs.get(plan.statement)?.solution ?? null;
      }
      const week = plan.week !== null && inWeeks(plan.week) ? plan.week : null;
      let item: ContentDraftItem;
      let from: { section: number; item: number } | null = null;
      // Le modèle ne voit que des numéros : « 5a » et « 5b » restent où elles sont.
      if (draft.sections.flatMap((sec) => sec.items).filter((it) => it.kind === "series" && it.seriesNumber === plan.number).length > 1) continue;
      for (let s = 0; s < draft.sections.length; s += 1) {
        const i = draft.sections[s].items.findIndex((it) => it.kind === "series" && it.seriesNumber === plan.number);
        if (i >= 0) {
          from = { section: s, item: i };
          break;
        }
      }
      if (from !== null) {
        item = draft.sections[from.section].items[from.item];
      } else {
        // Une série que les activités ne montraient pas : créée si son énoncé est connu.
        if (statement === null) continue;
        item = new ContentDraftItem({
          kind: "series", number: String(plan.number), title: `Série ${plan.number}`,
          url: statement, videoCount: 0, seriesNumber: plan.number, theoryKind: "reading",
        });
      }
      if (statement !== null && statement !== item.url && statement !== item.pdfURL) {
        item.url = statement;
        let isDocument = MoodleLinks.isDocument(statement);
        try {
          isDocument = isDocument || pathExtension(new URL(statement).pathname) === "pdf";
        } catch {
          // adresse illisible : on garde le test de document
        }
        item.pdfURL = isDocument ? statement : "";
        if (!item.links.some((link) => link.url === statement)) {
          item.links.unshift({ title: "Énoncé", url: statement, kind: "pdf" });
        }
      }
      if (solution !== null && solution !== "") item.solutionURL = solution;
      const target = week ?? (from !== null
        ? (draft.sections[from.section].items[from.item].week ?? draft.sections[from.section].week) : 0);
      if (from !== null) draft.sections[from.section].items.splice(from.item, 1);
      item.week = null;
      const index = draft.sections.findIndex((s) => s.week === target
        && !s.title.startsWith("Échéances") && !s.title.startsWith("Documents") && !s.title.startsWith("Anciens"));
      if (index >= 0) draft.sections[index].items.push(item);
      else {
        draft.sections.push(new ContentDraftSection({
          title: target > 0 ? `Semaine ${target}` : "Séries", week: target,
          weekIsInferred: false, isIncluded: true, items: [item],
        }));
      }
    }
    MoodleCourseAnalyzer.joinStraySolutions(draft.sections);
    draft.sections = draft.sections.filter((s) => s.items.length > 0);
    draft.sections.sort(sortedSections);
    return draft;
  },

  /** Un corrigé publié une autre semaine que son énoncé rejoint la série qui a un énoncé. */
  joinStraySolutions(sections: ContentDraftSection[]): void {
    const hasStatement = (item: ContentDraftItem): boolean =>
      item.pdfURL !== "" || (item.url !== "" && item.url !== item.solutionURL);
    const stray: { section: number; item: number }[] = [];
    sections.forEach((section, s) => {
      section.items.forEach((item, i) => {
        if (item.kind === "series" && !hasStatement(item) && item.seriesNumber !== null) stray.push({ section: s, item: i });
      });
    });
    const removed: { section: number; item: number }[] = [];
    for (const position of stray) {
      const orphan = sections[position.section].items[position.item];
      let target: { section: number; item: number } | null = null;
      for (let s = 0; s < sections.length; s += 1) {
        const i = sections[s].items.findIndex((item) =>
          item.kind === "series" && item.seriesNumber === orphan.seriesNumber
          && (orphan.seriesLabel === "" || item.seriesLabel === orphan.seriesLabel) && hasStatement(item));
        if (i >= 0) {
          target = { section: s, item: i };
          break;
        }
      }
      if (target === null) continue;
      const item = sections[target.section].items[target.item];
      if (item.solutionURL === "") item.solutionURL = orphan.solutionURL;
      for (const link of orphan.links) {
        if (!item.links.some((existing) => existing.url === link.url)) item.links.push(link);
      }
      sections[target.section].items[target.item] = item;
      removed.push(position);
    }
    removed.sort((a, b) => (b.section - a.section) || (b.item - a.item));
    for (const position of removed) sections[position.section].items.splice(position.item, 1);
    for (const section of [...sections]) if (section.items.length === 0) sections.splice(sections.indexOf(section), 1);
  },

  /** Une activité née d'un dossier déplié : son identifiant est celui du dossier, suivi de son rang. */
  isFromFolder(activity: MoodleActivity): boolean {
    return activity.id.includes("-");
  },

  // MARK: Rôle d'une section

  role(title: string, number: number): SectionRole {
    const lower = ContentDraftBuilder.fold(title);
    if (matches(lower, String.raw`\b(anciens? examens?|examens? des annees|previous (final )?exams?|past exams?|annales)\b`)) return "pastExams";
    if (matches(lower, String.raw`^(examen|exam|final exam|examen final|midterm)\b`)) return "exam";
    if (matches(lower, String.raw`\b(mini-?projets?|projets?|projects?)\b`) && !matches(lower, String.raw`\b(semaine|week)\s*\d`)) return "project";
    if (ContentDraftBuilder.week(title, null) !== null) return "content";
    if (number === 0) return "general";
    if (matches(lower, String.raw`^(informations?|general|generalites|course information|horaires?|salles|calendrier|calendar|ressources|resources|references|evaluation|grading|fora|forums?|communication|room assignment|weekly quizzes|questionnaires?|cheat ?sheet|description|organisation|organization|contact|faq|liens|links|annonces)\b`)) {
      return "general";
    }
    return "content";
  },

  // MARK: Une activité

  ignoredModules: new Set([
    "forum", "lti", "label", "choice", "choicegroup", "questionnaire", "feedback", "attendance",
    "chat", "wiki", "glossary", "survey", "data", "workshop", "bigbluebuttonbn", "zoom", "subsection",
  ]),

  classify(activity: MoodleActivity, inWeek: boolean): ActivityKind {
    const name = ContentDraftBuilder.fold(activity.name);
    const module = activity.module.toLowerCase();
    if (module === "assign") return "deadline";
    if (MoodleCourseAnalyzer.ignoredModules.has(module)) return "ignore";
    // Ce qui accompagne les études sans en être.
    if (matches(name, String.raw`(apprendre a etudier|learning companion|compagnon|contrat|equipe et comportements|comportements?|instructions?|qcm amc|initiative|mieux comprendre|cheat ?sheet|aide-memoire|formula sheet|formulaire|math review|exoset|plan du cours|syllabus|organisation du cours|pedagogie|room|salles|horaires|students-|^cm-\d|test enonce|test reponses|examen blanc|impression|ressources utiles|categorisation|explique|mooc apprendre)`)) {
      return "document";
    }
    if (module === "quiz") return "document";
    if (matches(name, String.raw`\b(rendus?|devoirs? note|graded|homework submission)\b`) && !MoodleCourseAnalyzer.isSolution(name)) {
      return "deadline";
    }
    if (MoodleCourseAnalyzer.isSolution(name) && !(name.includes("enonc") && name.includes("corrig"))) return "solution";
    if (MoodleCourseAnalyzer.isSeries(name)) return "series";
    if (inWeek && matches(name, String.raw`^(exercises?|exercices?|exos?)$`)) return "series";
    if (MoodleCourseAnalyzer.isLecture(name)) return inWeek ? "lecture" : "document";
    if (module === "folder") return "document";
    return inWeek ? "lecture" : "document";
  },

  isSolution(folded: string): boolean {
    return matches(folded, String.raw`(\bcorrig|\bsolutions?\b|\bsols?\b|\bcorrections?\b|\bloesung|\banswers?\b|\breponses\b)`);
  },

  isSeries(folded: string): boolean {
    return matches(folded, String.raw`(\bseries?\s*[-_#.:]?\s*0*\d|\bserie\d|\bproblem ?sets?\b|\bexercise sets?\b|\bexercises?\b|\bexercices?\b|\bfeuilles? d.exercices|\btd\s*\d|\bhomework\s*\d|enonce/corrige|\bla serie\b)`)
      && !matches(folded, String.raw`\bseries (numeriques|entieres|de fourier|de taylor|geometriques?)\b`);
  },

  isLecture(folded: string): boolean {
    return matches(folded, String.raw`(\blectures?\b|\bcours\b|transparents?|slides?|diapos?|\bnotes?\b|enregistrement|recording|\bvideos?\b|chapitres?|chapters?|polycopie|^\d{1,2}[-_ ][a-z])`);
  },

  /** Un énoncé à lire (un PDF), pas une page ou un dossier qui l'accompagne. */
  isStatementDocument(activity: MoodleActivity): boolean {
    return activity.module === "resource" || MoodleLinks.isDocument(activity.link)
      || /\.pdf$/i.test(new URL(activity.link, "https://x").pathname);
  },

  /** La série dont l'énoncé partage le plus de mots avec le nom du corrigé — `null` sans gagnant net. */
  closestByName(solution: MoodleActivity, groups: SeriesGroup[]): SeriesKey | null {
    const noise = new Set(["corrige", "corriges", "corrigee", "solution", "solutions", "sol", "correction", "corrections",
      "serie", "series", "exercices", "exercice", "exercises", "exercise", "de", "du", "la", "le", "des", "et", "pdf"]);
    const words = (name: string) => new Set(ContentDraftBuilder.fold(name).split(/[^\p{L}\p{N}]+/u)
      .filter((w) => w.length > 1 && !noise.has(w) && !/^\d+$/.test(w)));
    const wanted = words(solution.name);
    if (wanted.size === 0) return null;
    const scored = groups.map((g) => ({
      key: g.key,
      score: Math.max(0, ...g.statement.map((a) => [...words(a.name)].filter((w) => wanted.has(w)).length)),
    })).sort((a, b) => b.score - a.score);
    const best = scored[0];
    if (!best || best.score === 0 || (scored.length > 1 && scored[1].score >= best.score)) return null;
    return best.key;
  },

  isDeliverableSolution(name: string): boolean {
    return matches(ContentDraftBuilder.fold(name), String.raw`\brendus?\s*\d*`);
  },

  /** « Série 3 », « serie04 », « Problème Set 1 ». */
  seriesNumber(name: string): number | null {
    const lower = ContentDraftBuilder.fold(name);
    const pattern = String.raw`(?:series?|problem ?sets?|exercise sets?|feuilles?|td|homework|week)\s*[-_#.:]?\s*(?:n[o°]\s*)?0*(\d{1,2})(?!\d)`;
    const match = firstMatch(lower, pattern);
    return match === null ? null : swiftInt(match);
  },

  // MARK: Cours (théorie)

  /** Ce qui relie les activités d'un même cours. */
  lectureKey(name: string): string {
    const lower = ContentDraftBuilder.fold(name);
    const numbered = firstMatch(lower, String.raw`(?:lecture|cours|chapitre|chapter|lesson|lecon)\s*(?:notes?\s*)?0*(\d+[a-z]?)\b`);
    if (numbered !== null) return "n" + numbered;
    const leading = firstMatch(lower, String.raw`^0*(\d{1,2})[-_ ]`);
    if (leading !== null) return "n" + leading;
    // Le jour ne relie que des supports **de cours**.
    const days = new Map([
      ["monday", "lundi"], ["tuesday", "mardi"], ["wednesday", "mercredi"], ["thursday", "jeudi"], ["friday", "vendredi"],
      ["lundi", "lundi"], ["mardi", "mardi"], ["mercredi", "mercredi"], ["jeudi", "jeudi"], ["vendredi", "vendredi"],
    ]);
    if (matches(lower, String.raw`\b(lectures?|cours|notes?|slides?|transparents?)\b`) && !matches(lower, String.raw`\b(avant|before|until|jusqu)\b`)) {
      for (const [day, canonical] of days) if (lower.includes(day)) return "d" + canonical;
    }
    // Un sujet entre parenthèses — pas une mise en page, un état, ni une consigne datée.
    const layout = String.raw`^(\d+ pages? sur \d+|\d+ pages? per \d+|blank|annotated|annotees?|annotes?|vierges?|complet|full|print|imprimable|\d+ par page)$`;
    const parentheticals = matchesAll(lower, String.raw`\(([^)]+)\)`).map((x) => trimWhitespaces(x));
    const topic = parentheticals.find((value) => !matches(value, layout)
      && !matches(value, String.raw`\d|avant|before|devait|due`)
      && value.split(" ").filter((p) => p !== "").length <= 4);
    if (topic !== undefined) return "t" + topic;
    return "section";
  },

  lectureItem(activities: MoodleActivity[], key: string, index: number,
              sectionTitle: string, week: number, groups: number): ContentDraftItem {
    const links = activities.map((activity) => MoodleCourseAnalyzer.linkFor(activity));
    const hasVideo = links.some((link) => link.kind === "video");
    let title: string;
    if (key.startsWith("n")) {
      const number = key.slice(1);
      const named = activities.map((activity) => {
        const parts = activity.name.split(":");
        return parts.length >= 2 ? trimWhitespaces(parts.slice(1).join(":")) : null;
      }).find((value) => value !== null) ?? null;
      const chapter = activities.find((activity) => firstMatch(ContentDraftBuilder.fold(activity.name), String.raw`^0*(\d{1,2})[-_ ]`) !== null);
      if (chapter !== undefined) {
        title = MoodleCourseAnalyzer.prettifyFileName(chapter.name);
      } else if (named !== null) {
        title = named;
      } else {
        const topic = activities.map((activity) => MoodleCourseAnalyzer.videoTopic(activity.link)).find((t) => t !== null) ?? null;
        title = topic ?? `Cours ${number}`;
      }
    } else if (key.startsWith("w")) {
      title = MoodleCourseAnalyzer.weekTitle(activities, sectionTitle, week);
    } else if (key.startsWith("d")) {
      title = `Cours du ${key.slice(1)}`;
    } else if (key.startsWith("t")) {
      title = capitalizedFirst(key.slice(1));
    } else {
      // Le seul cours de la semaine prend le sujet de la section — sauf si ce
      // « sujet » n'est qu'une plage de dates.
      const topicParts = sectionTitle.split(":");
      const topic = topicParts.length > 1 ? trimWhitespaces(topicParts.slice(1).join(":")) : "";
      const topicIsDate = ContentDraftBuilder.week(topic, new Date()) !== null
        || matches(ContentDraftBuilder.fold(topic), String.raw`\b\d{1,2}\s+[a-z]+\b`);
      if (groups === 1 && topic !== "" && !topicIsDate) title = topic;
      else title = MoodleCourseAnalyzer.prettifyFileName(activities[0]?.name ?? "");
    }
    let number: string;
    if (key.startsWith("n")) {
      const raw = key.slice(1);
      number = week > 0 && ![...raw].every((c) => /\p{N}/u.test(c)) ? raw
        : (week > 0 && groups > 1 ? `${week}.${index}` : raw);
    } else {
      number = week > 0 ? (groups > 1 ? `${week}.${index}` : `${week}`) : `${index}`;
    }
    if (number === "") number = `${index}`;
    const primary = links.find((link) => link.kind === "notes") ?? links.find((link) => link.kind === "slides")
      ?? links.find((link) => link.kind === "pdf") ?? links[0];
    const item = new ContentDraftItem({
      kind: "theory", number, title: ContentDraftBuilder.cleanTitle(title),
      url: primary?.url ?? "", videoCount: links.filter((link) => link.kind === "video").length,
      seriesNumber: null,
      theoryKind: hasVideo ? "video" : (links.some((link) => link.kind === "slides") ? "slides" : "reading"),
    });
    item.links = links;
    return item;
  },

  /** Le titre de la semaine : le sujet de la section, sinon les sujets des enregistrements, sinon les supports. */
  weekTitle(activities: MoodleActivity[], sectionTitle: string, week = 0): string {
    const parts = sectionTitle.split(":");
    const topic = parts.length > 1 ? trimWhitespaces(parts.slice(1).join(":")) : "";
    const topicIsDate = topic === "" || ContentDraftBuilder.week(topic, new Date()) !== null
      || matches(ContentDraftBuilder.fold(topic), String.raw`\b\d{1,2}\s+[a-z]+\b`);
    if (!topicIsDate) return topic;
    const topics: string[] = [];
    for (const activity of activities) {
      const video = MoodleCourseAnalyzer.videoTopic(activity.link);
      if (video !== null && !topics.includes(video)) topics.push(video);
    }
    if (topics.length > 0) return topics.slice(0, 3).join(" · ");
    // Des supports aux noms génériques ne disent rien du sujet.
    const generic = activities.every((activity) => MoodleCourseAnalyzer.isLecture(ContentDraftBuilder.fold(activity.name)));
    if (generic) return week > 0 ? `Cours de la semaine ${week}` : "Cours";
    const names: string[] = [];
    for (const activity of activities) {
      const name = MoodleCourseAnalyzer.prettifyFileName(activity.name)
        .replace(/\s*\((?:blank|annotated|annot[ée]e?s?|vierges?|\d+ pages? (?:sur|per) \d+)\)/gi, "")
        .replace(/\s*(?:recording|enregistrement)s?\b/gi, "")
        .trim();
      const key = ContentDraftBuilder.fold(name);
      if (name !== "" && !names.some((existing) => ContentDraftBuilder.fold(existing) === key)) names.push(name);
    }
    return names.length === 0 ? (activities[0]?.name ?? "Cours") : names.slice(0, 3).join(" · ");
  },

  /** Déplace dans leur semaine les activités que le modèle y range. */
  relocate(snapshot: MoodleCourseSnapshot, hints: Record<string, { kind?: ActivityKind | null; week?: number | null }>,
           termStart: Date | null, totalWeeks: number): MoodleCourseSnapshot {
    if (Object.keys(hints).length === 0) return snapshot;
    const result = new MoodleCourseSnapshot({
      title: snapshot.title, url: snapshot.url,
      sections: snapshot.sections.map((section) => new MoodleSection({
        number: section.number, title: section.title, activities: [...section.activities],
        text: section.text, links: [...section.links],
      })),
      moocLinks: snapshot.moocLinks, unopened: snapshot.unopened,
    });
    const moved: { week: number; activity: MoodleActivity }[] = [];
    for (const section of result.sections) {
      const current = MoodleCourseAnalyzer.week(section, termStart, totalWeeks);
      section.activities = section.activities.filter((activity) => {
        const hint = hints[activity.id];
        if (hint === undefined || hint.week === null || hint.week === undefined || hint.week <= 0 || hint.week === current) return true;
        const kind = hint.kind ?? null;
        if (kind === null || !["lecture", "series", "solution"].includes(kind)) return true;
        moved.push({ week: Math.min(hint.week, Math.max(totalWeeks, 1)), activity });
        return false;
      });
    }
    for (const { week, activity } of moved) {
      const index = result.sections.findIndex((section) =>
        MoodleCourseAnalyzer.week(section, termStart, totalWeeks) === week);
      if (index >= 0) result.sections[index].activities.push(activity);
      else {
        result.sections.push(new MoodleSection({
          number: 1000 + week, title: `Semaine ${week}`, activities: [activity],
        }));
      }
    }
    return result;
  },

  /** Le sujet d'un enregistrement MediaSpace, lu dans son adresse. */
  videoTopic(link: string): string | null {
    let url: URL;
    try {
      url = new URL(link);
    } catch {
      return null;
    }
    if (!url.hostname.includes("mediaspace")) return null;
    const parts = url.pathname.split("/").filter((p) => p !== "");
    const index = parts.indexOf("media");
    if (index < 0 || index + 1 >= parts.length) return null;
    const raw = safeDecode(parts[index + 1]).split("+").join(" ");
    if ([...raw].length <= 3 || raw.startsWith("0_") || raw === "t") return null;
    const colon = raw.indexOf(":");
    if (colon < 0) return null;
    const topic = trimWhitespaces(raw.slice(colon + 1));
    return topic === "" ? null : topic;
  },

  /** « 01-Systemes-lineaires » → « Systemes lineaires » ; un vrai titre reste tel quel. */
  prettifyFileName(name: string): string {
    const looksLikeFile = !name.includes(" ") && (name.includes("-") || name.includes("_"));
    if (!(looksLikeFile || firstMatch(ContentDraftBuilder.fold(name), String.raw`^0*(\d{1,2})[-_ ]`) !== null)) return name;
    let text = name.replace(/^0*\d{1,2}[-_ ]+/, "");
    text = text.replace(/\.pdf$/i, "");
    text = text.split("-").join(" ").split("_").join(" ");
    // « introduction 2026 » : l'année d'un fichier n'est pas un titre.
    text = text.replace(/\s+20\d{2}$/, "");
    return capitalizedFirst(text);
  },

  linkFor(activity: MoodleActivity): ContentLink {
    const name = ContentDraftBuilder.fold(activity.name);
    const target = ContentDraftBuilder.fold(activity.link);
    let kind: ContentLinkKind;
    if (matches(target, String.raw`(mediaspace|youtube|youtu\.be|vimeo|tube\.switch|kaltura|video)`)
        || matches(name, String.raw`(recording|enregistrement|video|vodcast)`)) {
      kind = "video";
    } else if (MoodleCourseAnalyzer.isSolution(name)) {
      kind = "solution";
    } else if (matches(name, String.raw`(transparents?|slides?|diapos?)`) || matches(target, String.raw`slides?`)) {
      kind = "slides";
    } else if (matches(name, String.raw`(notes?|annot|polycop)`)) {
      kind = "notes";
    } else if (activity.module === "resource" || pathExtension(safePath(activity.link)) === "pdf") {
      kind = "pdf";
    } else {
      kind = "page";
    }
    return { title: ContentDraftBuilder.cleanTitle(activity.name), url: activity.link, kind };
  },

  // MARK: Séries

  seriesItem(key: SeriesKey, statement: MoodleActivity[], solution: MoodleActivity[]): ContentDraftItem {
    const number = key.number;
    const name = SeriesIdentity.displayName(number, key.label);
    const main = statement[0];
    const titleSource = main?.name ?? name;
    // « Problem Set 1: Motion in 1D » → le thème, « Motion in 1D ».
    const parts = titleSource.split(":");
    const topic = parts.length > 1 ? trimWhitespaces(parts.slice(1).join(":")) : "";
    const item = new ContentDraftItem({
      kind: "series", number: String(number),
      title: topic === "" ? name : ContentDraftBuilder.cleanTitle(topic),
      url: main?.link ?? "", videoCount: 0, seriesNumber: number, theoryKind: "reading", seriesLabel: key.label,
    });
    if (main !== undefined) {
      // Un PDF : un fichier Moodle, ou la cible lue dans une page, un dossier ou un lien.
      if (main.module === "resource" || MoodleLinks.isDocument(main.link)) item.pdfURL = main.link;
    }
    if (solution.length > 0) item.solutionURL = solution[0].link;
    else {
      const paired = statement.map((s) => s.solutionTarget).find((value) => value !== null);
      if (paired !== undefined && paired !== null) item.solutionURL = paired;
    }
    // Pas d'énoncé à part, mais un corrigé qui est une page web : c'est la page de la série.
    if (item.url === "" && item.pdfURL === "" && item.solutionURL !== ""
        && !MoodleLinks.isDocument(item.solutionURL)
        && pathExtension(safePath(item.solutionURL)) !== "pdf") {
      item.url = item.solutionURL;
    }
    item.links = [...statement, ...solution.filter((s) => !statement.includes(s))]
      .map((activity) => MoodleCourseAnalyzer.linkFor(activity));
    return item;
  },

  // MARK: Échéances

  deadline(activity: MoodleActivity): ContentDraftItem {
    const name = ContentDraftBuilder.fold(activity.name);
    const kind: ExamKind = matches(name, String.raw`(projet|project)`) ? "project" : "assignment";
    let title = ContentDraftBuilder.cleanTitle(activity.name);
    if (matches(name, String.raw`\ben groupe\b|\bgroup\b`) && !title.toLowerCase().includes("groupe")) title += " (en groupe)";
    return MoodleCourseAnalyzer.deadlineItem(title, activity.dueDate, kind, activity.link);
  },

  deadlineItem(title: string, date: Date | null, kind: ExamKind, url: string): ContentDraftItem {
    const item = new ContentDraftItem({
      kind: "deadline", number: "", title, url, videoCount: 0, seriesNumber: null, theoryKind: "reading",
    });
    item.date = date;
    item.examKind = kind;
    return item;
  },

  /** Dans une section « projet », ce qui a une date est une échéance. */
  projectDeadline(activity: MoodleActivity, section: string, termStart: Date | null): ContentDraftItem | null {
    if (activity.module === "assign") {
      const item = MoodleCourseAnalyzer.deadline(activity);
      item.examKind = "project";
      return item;
    }
    const date = MoodleCourseAnalyzer.shortDate(activity.name, termStart);
    if (date === null) return null;
    const clean = ContentDraftBuilder.cleanTitle(activity.name)
      .replace(/[⚠️]/g, "")
      .replace(/\s*\((?:délai|delai|deadline|due)[^)]*\)/gi, "")
      .trim();
    return MoodleCourseAnalyzer.deadlineItem(`${section} : ${clean}`, date, "project", activity.link);
  },

  /** « Examen Final (samedi 12.12, 09:00-12:00) » → le 12 décembre à 9 h. */
  examDate(title: string, termStart: Date | null): Date | null {
    return MoodleCourseAnalyzer.shortDate(title, termStart);
  },

  examTitle(title: string): string {
    return trimWhitespaces(title.replace(/\s*\([^)]*\)/g, ""));
  },

  /** Une date courte (« 12.12, 09:00 ») rapportée à l'année du semestre ; l'heure si elle est donnée. */
  shortDate(text: string, termStart: Date | null): Date | null {
    const match = icuRegExp(String.raw`\b(\d{1,2})\.(\d{1,2})(?:\.(\d{2,4}))?\b(?:[^\d]{0,6}(\d{1,2})[:h](\d{2}))?`).exec(text);
    if (match === null) return null;
    const group = (index: number): number | null => match[index] !== undefined ? swiftInt(match[index]) : null;
    const day = group(1);
    const month = group(2);
    if (day === null || month === null || !(day >= 1 && day <= 31) || !(month >= 1 && month <= 12)) return null;
    // « Projet 1.2 », « Partie 3.1 » : un numéro, pas une date.
    const start = match.index;
    const before = ContentDraftBuilder.fold(text.slice(Math.max(0, start - 28), start));
    if (icuRegExp(String.raw`\b(projets?|projects?|parties?|parts?|chapitres?|chapters?|exercices?|exercises?|version|v|tp|td|series?|questions?|sections?|lectures?|cours|modules?|semaines?|weeks?)\s*$`).test(before)) return null;
    const announced = icuRegExp(String.raw`(\(|\b(delai|deadline|due|rendu|remise|avant|until|before|le|du|jusqu|date|lundi|mardi|mercredi|jeudi|vendredi|samedi|dimanche|monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b)[^()]*$`).test(before);
    if (group(3) === null && group(4) === null && !announced) return null;
    const base = termStart ?? new Date();
    let year = group(3) ?? base.getFullYear();
    if (year < 100) year += 2000;
    if (group(3) === null && termStart !== null) {
      const startMonth = termStart.getMonth() + 1;
      if (month < startMonth - 2) year += 1;
    }
    return new Date(year, month - 1, day, group(4) ?? 9, group(5) ?? 0);
  },

  /** « Due: Friday, 2 October 2026, 11:59 PM » — l'échéance d'un devoir sur sa page. */
  dueDate(fromActivityDates: string): Date | null {
    const lower = ContentDraftBuilder.fold(fromActivityDates);
    const range = /(due|a remettre|echeance|date de remise|close[sd]?|ferme)\s*:?/.exec(lower);
    if (range === null) return null;
    const tail = lower.slice(range.index + range[0].length);
    const match = icuRegExp(String.raw`(\d{1,2})\s+([a-z]+)\.?\s+(\d{4})(?:[, ]+(?:a\s+)?(\d{1,2})[:h](\d{2})\s*(am|pm)?)?`).exec(tail);
    if (match === null) return null;
    const months = new Map<string, number>(Object.entries({
      janvier: 1, january: 1, fevrier: 2, february: 2, mars: 3, march: 3, avril: 4, april: 4,
      mai: 5, may: 5, juin: 6, june: 6, juillet: 7, july: 7, aout: 8, august: 8,
      septembre: 9, september: 9, octobre: 10, october: 10, novembre: 11, november: 11,
      decembre: 12, december: 12,
    }));
    const day = match[1] !== undefined ? swiftInt(match[1]) : null;
    const month = match[2] !== undefined ? months.get(match[2]) : undefined;
    const year = match[3] !== undefined ? swiftInt(match[3]) : null;
    if (day === null || month === undefined || year === null) return null;
    let hour = match[4] !== undefined ? swiftInt(match[4]) ?? 23 : 23;
    const minute = match[5] !== undefined ? swiftInt(match[5]) ?? 59 : 59;
    const meridiem = match[6];
    if (meridiem === "pm" && hour < 12) hour += 12;
    if (meridiem === "am" && hour === 12) hour = 0;
    // `Calendar(identifier: .gregorian)` + fuseau Europe/Zurich : les tests tournent à Zurich.
    return new Date(year, month - 1, day, hour, minute);
  },

  // MARK: Anciens examens

  pastExamItems(activities: MoodleActivity[]): ContentDraftItem[] {
    const exams: { key: string; statement: MoodleActivity | null; solution: MoodleActivity | null }[] = [];
    for (const activity of activities) {
      if (MoodleCourseAnalyzer.classify(activity, false) === "ignore") continue;
      const name = ContentDraftBuilder.fold(activity.name);
      const key = firstMatch(name, String.raw`\b(20\d{2}|19\d{2})\b`) ?? name;
      const isSol = MoodleCourseAnalyzer.isSolution(name);
      const index = exams.findIndex((exam) => exam.key === key);
      if (index >= 0) {
        if (isSol) exams[index].solution = activity;
        else exams[index].statement = activity;
      } else {
        exams.push({ key, statement: isSol ? null : activity, solution: isSol ? activity : null });
      }
    }
    const result: ContentDraftItem[] = [];
    for (const exam of exams) {
      const main = exam.statement ?? exam.solution;
      if (main === null) continue;
      const item = new ContentDraftItem({
        kind: "pastExam", number: [...exam.key].length === 4 ? exam.key : "",
        title: ContentDraftBuilder.cleanTitle(main.name), url: main.link, videoCount: 0,
        seriesNumber: null, theoryKind: "reading",
      });
      item.solutionURL = exam.solution?.link ?? "";
      result.push(item);
    }
    return result;
  },

  // MARK: Documents

  document(activity: MoodleActivity, section: string): ContentDraftItem {
    const item = new ContentDraftItem({
      kind: "resource", number: "", title: ContentDraftBuilder.cleanTitle(activity.name),
      url: activity.link, videoCount: 0, seriesNumber: null, theoryKind: "reading",
    });
    item.links = [MoodleCourseAnalyzer.linkFor(activity)];
    item.group = section;
    return item;
  },

  // MARK: Texte

  fold(text: string): string { return ContentDraftBuilder.fold(text); },
};

/** `URL.path` d'une adresse, ou la chaîne elle-même si elle est illisible. */
function safePath(address: string): string {
  try {
    return new URL(address).pathname;
  } catch {
    return address;
  }
}

// MARK: - Références du modèle

export interface MoodleReferenceValue { url: string; solution: string | null }

/** Les références de liens données au modèle : « a<id> » pour une activité, « L<n> » pour un lien. */
export function MoodleCourseAIReferences(snapshot: MoodleCourseSnapshot): Map<string, MoodleReferenceValue> {
  const result = new Map<string, MoodleReferenceValue>();
  let counter = 0;
  for (const section of snapshot.sections) {
    for (const activity of section.activities) {
      if (activity.isVisible) result.set("a" + activity.id, { url: activity.link, solution: activity.solutionTarget });
    }
    for (const link of section.links) {
      counter += 1;
      result.set(`L${counter}`, { url: link.url, solution: null });
    }
  }
  return result;
}

// MARK: - Dossiers Moodle

/** Un dossier Moodle (`mod/folder`) déplié en ses fichiers. */
export interface MoodleFolderFile {
  title: string;
  url: string;
}

export const MoodleFolderFile = {
  make(title: string, url: string): MoodleFolderFile { return { title, url }; },
};

export const MoodleFolderExpander = {
  /** `MoodleFolderExpander.File(title:url:)`. */
  File: MoodleFolderFile,

  /** Les activités qui remplacent le dossier. */
  expand(folder: MoodleActivity, files: MoodleFolderFile[]): MoodleActivity[] {
    const seen = new Set<string>();
    const unique = files.filter((file) => {
      if (seen.has(file.url)) return false;
      seen.add(file.url);
      return true;
    });
    const statements = unique.filter((file) => !MoodleFolderExpander.isSolution(file));
    const solutions = unique.filter((file) => MoodleFolderExpander.isSolution(file));
    if (!(statements.length > 1 || (statements.length === 0 && solutions.length > 1))) return [folder];

    const unmatched = [...solutions];
    const result: MoodleActivity[] = [];
    statements.forEach((file, index) => {
      const child = MoodleFolderExpander.activity(file, folder, index);
      const number = MoodleFolderExpander.number(file);
      if (number !== null) {
        const match = unmatched.findIndex((solution) => MoodleFolderExpander.number(solution) === number);
        if (match >= 0) {
          child.solutionTarget = unmatched.splice(match, 1)[0].url;
        }
      }
      result.push(child);
    });
    // Un corrigé sans énoncé correspondant reste visible.
    unmatched.forEach((file, offset) => {
      result.push(MoodleFolderExpander.activity(file, folder, statements.length + offset));
    });
    return result;
  },

  activity(file: MoodleFolderFile, folder: MoodleActivity, index: number): MoodleActivity {
    const child = new MoodleActivity({
      id: `${folder.id}-${index + 1}`,
      name: MoodleFolderExpander.displayName(file),
      module: "resource",
      url: folder.url,
      target: file.url,
      isVisible: folder.isVisible,
      dueDate: folder.dueDate,
    });
    child.destination = "pdf";
    return child;
  },

  /** « Serie_03.pdf » → « Serie 03 ». */
  displayName(file: MoodleFolderFile): string {
    let name = file.title.trim();
    if (name === "") {
      let last = "";
      try {
        last = safeDecode(new URL(file.url).pathname.split("/").filter((p) => p !== "").pop() ?? "");
      } catch {
        last = file.url;
      }
      name = last === "" ? file.url : last;
    }
    if (name.toLowerCase().endsWith(".pdf")) name = name.slice(0, -4);
    name = name.split("_").join(" ");
    return name.normalize("NFC");
  },

  isSolution(file: MoodleFolderFile): boolean {
    let last = "";
    try {
      last = safeDecode(new URL(file.url).pathname.split("/").filter((p) => p !== "").pop() ?? "");
    } catch {
      last = file.url;
    }
    const text = (file.title + " " + last).toLowerCase();
    return icuRegExp(String.raw`(corrig|solution|\bsol\b|[_-]sol\b|loesung|lösung|answers?\b|reponses|réponses)`).test(text);
  },

  /** Le numéro d'une série dans un nom de fichier. */
  number(file: MoodleFolderFile): number | null {
    let last = "";
    try {
      last = new URL(file.url).pathname.split("/").filter((p) => p !== "").pop() ?? "";
    } catch {
      last = file.url;
    }
    const text = (MoodleFolderExpander.displayName(file) + " " + last).toLowerCase()
      .normalize("NFD").replace(/\p{M}+/gu, "");
    const keyed = /(?:serie|series|exercices?|exercises?|sheet|week|semaine|ex|tp|td|uebung|ubung)[\s_\-.]*0*(\d{1,2})(?!\d)/.exec(text);
    if (keyed !== null) return swiftInt(keyed[1]);
    const numbers = text.match(/\d+/g) ?? [];
    for (const digits of numbers) {
      const value = swiftInt(digits);
      if (value !== null && value < 100) return value;
    }
    return null;
  },

  /** `MoodleFolderExpander.number(in:)`, nommé comme côté Swift. */
  numberIn(file: MoodleFolderFile): number | null { return MoodleFolderExpander.number(file); },
};
