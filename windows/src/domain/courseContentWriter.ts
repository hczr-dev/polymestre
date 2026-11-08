// Écrit un brouillon relu dans un cours (Polymestre/Domain/CourseContentWriter.swift).
//
// **Ne supprime jamais rien** : réimporter Moodle en semaine 8 doit ajouter la
// série 8, pas effacer l'avancement des sept premières. Un élément déjà présent
// est mis à jour et garde ce qui a été coché.

import { Exam, ExerciseSeries, PastExam, TheoryItem, type Course } from "../models/index.ts";
import type { ModelStore } from "../models/store.ts";
import { CourseDocument } from "./moodleCourseAnalyzer.ts";
import { Plural } from "./plural.ts";
import { swiftInt } from "../services/seriesPDFParser.ts";
import { BotafogoLinks } from "./botafogoProgram.ts";
import { ContentDraft, ContentDraftBuilder, ContentDraftItem } from "./courseContentImport.ts";
import { ExerciseDraft, SeriesDraft, SeriesDraftWriter } from "./seriesDraft.ts";
import { SeriesIdentity } from "./seriesIdentity.ts";

/** Ce qu'un import a changé, pour le dire en une phrase. */
export class ContentImportResult {
  theoryAdded = 0;
  theoryUpdated = 0;
  seriesAdded = 0;
  seriesUpdated = 0;
  exercisesAdded = 0;
  deadlinesAdded = 0;
  pastExamsAdded = 0;
  documentsAdded = 0;

  get isEmpty(): boolean {
    return this.theoryAdded + this.theoryUpdated + this.seriesAdded + this.seriesUpdated
      + this.deadlinesAdded + this.pastExamsAdded + this.documentsAdded === 0;
  }

  get message(): string {
    const parts: string[] = [];
    if (this.theoryAdded > 0) parts.push(`${Plural.count(this.theoryAdded, `${this.theoryAdded} élément`, `${this.theoryAdded} éléments`)} de théorie`);
    if (this.seriesAdded > 0) parts.push(Plural.count(this.seriesAdded, `${this.seriesAdded} série`, `${this.seriesAdded} séries`));
    if (this.exercisesAdded > 0) parts.push(Plural.count(this.exercisesAdded, `${this.exercisesAdded} exercice`, `${this.exercisesAdded} exercices`));
    if (this.deadlinesAdded > 0) parts.push(Plural.count(this.deadlinesAdded, `${this.deadlinesAdded} échéance`, `${this.deadlinesAdded} échéances`));
    if (this.pastExamsAdded > 0) parts.push(Plural.count(this.pastExamsAdded, `${this.pastExamsAdded} ancien examen`, `${this.pastExamsAdded} anciens examens`));
    if (this.documentsAdded > 0) parts.push(Plural.count(this.documentsAdded, `${this.documentsAdded} document`, `${this.documentsAdded} documents`));
    const updated = this.theoryUpdated + this.seriesUpdated;
    if (parts.length === 0) {
      return updated > 0
        ? `Déjà à jour · ${Plural.count(updated, `${updated} élément rafraîchi`, `${updated} éléments rafraîchis`)}.`
        : "Rien de nouveau.";
    }
    return "Ajouté : " + parts.join(" et ") + (updated > 0 ? ` · ${updated} mis à jour.` : ".");
  }
}

export const ContentDraftWriter = {
  /** Ajoute un document à la liste du cours s'il n'y est pas ; rend 1 s'il est nouveau. */
  addDocument(item: ContentDraftItem, course: Course): number {
    if (item.url === "") return 0;
    const documents = course.documents;
    if (documents.some((document) => document.url === item.url)) return 0;
    documents.push({
      title: item.title, url: item.url, group: item.group,
      kind: item.links[0]?.kind ?? "page",
    } satisfies CourseDocument);
    course.documents = documents;
    return 1;
  },

  /** Le thème, le corrigé et les exercices d'une série, quand la source les donne. */
  writeDetails(item: ContentDraftItem, series: ExerciseSeries, course: Course,
               context: ModelStore, complete = false): number {
    const topic = item.title.trim();
    if (topic !== "" && topic !== `Série ${series.seriesNumber}` && topic !== series.displayName
        && (ContentDraftBuilder.seriesNumber(topic) === null || [...topic].length > 12)) {
      series.topic = topic;
    }
    if (item.solutionsAt !== null) series.solutionsAt = item.solutionsAt;
    if (item.solutionURL !== "") series.solutionURLString = item.solutionURL;
    if (item.exercises.length === 0) return 0;
    const before = series.exercises.length;
    const draft = new SeriesDraft({
      existingID: series.id,
      number: series.seriesNumber,
      label: series.label,
      title: "",
      plannedWeek: series.plannedWeek,
      exercises: item.exercises.map((spec) => {
        const parts = spec.number.split(".");
        const draftExercise = new ExerciseDraft({
          minor: parts[parts.length - 1] ?? spec.number,
          title: spec.title,
          isBonus: spec.isBonus,
          subQuestions: spec.questions,
        });
        draftExercise.statement = spec.statement;
        return draftExercise;
      }),
    });
    SeriesDraftWriter.write(draft, course, "importMerge", context);
    for (const spec of item.exercises) {
      const exercise = series.exercises.find((candidate) => candidate.exerciseNumber === spec.number);
      if (exercise === undefined) continue;
      if (spec.hint !== "") exercise.hint = spec.hint;
      if (spec.solution !== "") exercise.solution = spec.solution;
      if (spec.url !== "") exercise.statementURLString = spec.url;
    }
    // Une source qui liste **toute** la série fait foi : un exercice qu'elle ne
    // cite plus, jamais commencé, s'en va.
    if (complete) {
      const cited = new Set(item.exercises.map((spec) => spec.number));
      for (const exercise of [...series.exercises]) {
        if (cited.has(exercise.exerciseNumber)) continue;
        if (exercise.isDone || exercise.subQuestionDoneCount !== 0 || exercise.score !== null) continue;
        if ((exercise.correctionNote ?? "") !== "") continue;
        if (exercise.hintLog !== "" || exercise.redoDueAt !== null) continue;
        series.exercises = series.exercises.filter((candidate) => candidate.id !== exercise.id);
        context.delete(exercise);
      }
    }
    return Math.max(0, series.exercises.length - before);
  },

  /** Écrit un brouillon relu dans un cours. */
  apply(draft: ContentDraft, course: Course, context: ModelStore, updateWeeks = true): ContentImportResult {
    const result = new ContentImportResult();
    let nextSort = (course.theoryItems.map((item) => item.sortOrder).reduce((a, b) => Math.max(a, b), -1)) + 1;
    // Les vidéos déjà vues : un chapitre réparti autrement reste vu là où ses vidéos l'étaient.
    const watchedVideos = new Set(course.theoryItems.filter((item) => item.isWatched)
      .flatMap((item) => item.links.filter((link) => link.kind === "video").map((link) => link.url)));

    // Ce qui a été écarté à une relecture reste écarté.
    const ignored = course.contentIgnored;
    if (updateWeeks) {
      for (const section of draft.sections) {
        for (const item of section.items) {
          if (item.url === "") continue;
          if (section.isIncluded && item.kind !== "ignore") ignored.delete(item.url);
          else ignored.add(item.url);
        }
      }
      course.contentIgnored = ignored;
    }

    draft.sections.forEach((section, sectionIndex) => {
      if (!section.isIncluded) return;
      const lead = ContentDraftBuilder.leadingNumber(section.title);
      const chapter = lead !== null ? swiftInt(lead.number) : null;
      for (const item of section.items) {
        if (!updateWeeks && item.url !== "" && ignored.has(item.url)) continue;
        switch (item.kind) {
          case "ignore":
            continue;
          case "deadline": {
            // Une échéance est une évaluation du cours : retrouvée par son titre, jamais doublée.
            const title = item.title.trim();
            const existing = course.exams.find((exam) => exam.title.toLowerCase() === title.toLowerCase());
            if (existing !== undefined) {
              if (item.date !== null && existing.date.getTime() !== item.date.getTime()) existing.date = item.date;
              if (existing.urlString === "") existing.urlString = item.url;
            } else if (item.date !== null) {
              const exam = new Exam({ course, kind: item.examKind, title, date: item.date });
              exam.urlString = item.url;
              context.insert(exam);
              result.deadlinesAdded += 1;
            } else {
              // Sans date, c'est un document : on garde le lien.
              result.documentsAdded += ContentDraftWriter.addDocument(item, course);
            }
            break;
          }
          case "pastExam": {
            const year = swiftInt(item.number) ?? new Date().getFullYear();
            const existing = course.pastExams.find((past) => past.urlString === item.url || past.title === item.title);
            if (existing !== undefined) {
              if (existing.solutionURLString === "") existing.solutionURLString = item.solutionURL;
            } else {
              const past = new PastExam({
                course, title: item.title, year, kind: "exam",
                urlString: item.url, solutionURLString: item.solutionURL,
              });
              context.insert(past);
              result.pastExamsAdded += 1;
            }
            break;
          }
          case "resource":
            result.documentsAdded += ContentDraftWriter.addDocument(item, course);
            break;
          case "theory": {
            const existing = course.theoryItems.find((candidate) =>
              (item.url !== "" && candidate.urlString === item.url) || candidate.number === item.number);
            const firstPart = item.number.split(".")[0];
            const sectionNumber = swiftInt(firstPart) ?? chapter ?? (sectionIndex + 1);
            if (existing !== undefined) {
              existing.title = item.title;
              // La semaine d'un chapitre de MOOC vient du plan du cours : elle suit chaque mise à jour.
              const derived = item.title.startsWith("MOOC · ");
              if (updateWeeks || existing.plannedWeek === 0 || derived) existing.plannedWeek = item.plannedWeek(section);
              if (derived) existing.number = item.number;
              existing.videoCount = item.videoCount;
              existing.sectionTitle = section.title;
              existing.kind = item.theoryKind;
              if (existing.urlString === "") existing.urlString = item.url;
              if (item.links.length > 0) existing.links = item.links;
              existing.sourceRaw = draft.source;
              result.theoryUpdated += 1;
            } else {
              const theory = new TheoryItem({
                course, sectionNumber, number: item.number, title: item.title, kind: item.theoryKind,
                plannedWeek: item.plannedWeek(section), sortOrder: nextSort, urlString: item.url,
              });
              theory.videoCount = item.videoCount;
              theory.sectionTitle = section.title;
              theory.sourceRaw = draft.source;
              theory.links = item.links;
              const videos = item.links.filter((link) => link.kind === "video").map((link) => link.url);
              if (item.title.startsWith("MOOC · ") && videos.length > 0 && videos.every((url) => watchedVideos.has(url))) {
                theory.watchedAt = new Date();
              }
              context.insert(theory);
              nextSort += 1;
              result.theoryAdded += 1;
            }
            // L'élément d'une semaine (numéro « 4 ») absorbe les éléments qu'un
            // import précédent avait créés pour chacun de ses cours (« 4.1 », « 4.2 »).
            if (item.number !== "" && [...item.number].every((c) => /\p{N}/u.test(c))) {
              const target = course.theoryItems.find((candidate) =>
                candidate.number === item.number || (item.url !== "" && candidate.urlString === item.url));
              if (target !== undefined) {
                target.number = item.number;
                const urls = new Set([...item.links.map((link) => link.url), item.url]);
                const absorbed = course.theoryItems.filter((other) =>
                  other !== target && other.plannedWeek === target!.plannedWeek
                  && other.urlString !== "" && urls.has(other.urlString));
                if (absorbed.length > 0) {
                  const all = [target, ...absorbed];
                  target.watchedAt = all.every((entry) => entry.isWatched)
                    ? new Date(Math.max(...all.map((entry) => entry.watchedAt?.getTime() ?? 0))) : null;
                  for (const other of absorbed) context.delete(other);
                  result.theoryUpdated += absorbed.length;
                }
              }
            }
            break;
          }
          case "series": {
            const number = item.seriesNumber ?? swiftInt(item.number);
            if (number === null) continue;
            let series: ExerciseSeries;
            // Seule à ce numéro, ou la première de ses sœurs (« 5a » avant « 5b ») :
            // elle reprend la série enregistrée sans étiquette, et son avancement.
            const siblings = draft.sections.flatMap((s) => s.items)
              .filter((other) => other.kind === "series" && (other.seriesNumber ?? swiftInt(other.number)) === number);
            const firstLabel = siblings.map((other) => SeriesIdentity.normalized(other.seriesLabel))
              .sort((a, b) => a === b ? 0 : SeriesIdentity.labelPrecedes(a, b) ? -1 : 1)[0];
            const sole = siblings.length <= 1 || SeriesIdentity.normalized(item.seriesLabel) === firstLabel;
            const existing = course.seriesWith(number, item.seriesLabel, sole) ?? undefined;
            if (existing !== undefined && existing.label === "" && item.seriesLabel !== "") {
              // Une étiquette apparue (« mardi ») se pose sur la série d'avant.
              if (existing.title === existing.displayName) existing.title = SeriesIdentity.displayName(number, item.seriesLabel);
              existing.label = SeriesIdentity.normalized(item.seriesLabel);
            }
            if (existing !== undefined) {
              // Un corrigé seul (sans énoncé) ne déplace jamais sa série.
              const carriesStatement = item.url !== "" || item.pdfURL !== "";
              if ((updateWeeks && carriesStatement) || existing.plannedWeek === 0) {
                existing.plannedWeek = item.plannedWeek(section);
              }
              // L'adresse de l'énoncé est remplacée quand l'ancienne n'a rien donné,
              // ou quand elle pointe sur le MOOC alors que le cours a sa page.
              const fresh = item.pdfURL === "" ? item.url : item.pdfURL;
              let staleMOOC = false;
              try {
                staleMOOC = (new URL(existing.urlString).hostname.includes("courseware"))
                  && !(fresh !== "" && new URL(fresh).hostname.includes("courseware"));
              } catch {
                staleMOOC = false;
              }
              if (existing.urlString === ""
                  || (fresh !== "" && fresh !== existing.urlString && (existing.exercises.length === 0 || staleMOOC))) {
                existing.urlString = fresh;
                if (staleMOOC) {
                  for (const exercise of existing.exercises) {
                    try {
                      if (new URL(exercise.statementURLString).hostname.includes("courseware")) {
                        exercise.statementURLString = "";
                      }
                    } catch {
                      // adresse illisible : rien à corriger
                    }
                  }
                  existing.needsReread = true;
                }
              }
              if (existing.solutionURLString === "" && item.solutionURL !== "") {
                existing.solutionURLString = item.solutionURL;
              }
              series = existing;
              result.seriesUpdated += 1;
            } else {
              series = new ExerciseSeries({
                course, seriesNumber: number, label: item.seriesLabel, plannedWeek: item.plannedWeek(section),
                urlString: item.pdfURL === "" ? item.url : item.pdfURL,
              });
              context.insert(series);
              result.seriesAdded += 1;
            }
            result.exercisesAdded += ContentDraftWriter.writeDetails(item, series, course, context,
              BotafogoLinks.isPage(item.url) && item.exercises.length > 0);
            break;
          }
        }
      }
    });

    if (draft.source === "moodle") ContentDraftWriter.cleanUpMOOC(course, draft, context);
    if (Object.keys(draft.weekGuide).length > 0) course.weekGuide = draft.weekGuide;

    const sources = course.contentSources;
    if (draft.url !== "" && !sources.includes(draft.url)) {
      sources.push(draft.url);
      course.contentSources = sources;
    }
    return result;
  },

  /** Ce que d'anciens imports du MOOC ont laissé, une fois le cours rangé par Moodle. */
  cleanUpMOOC(course: Course, draft: ContentDraft, context: ModelStore): void {
    const isMOOC = (address: string): boolean => address.includes("courseware.epfl.ch");

    for (const series of [...course.series]) {
      if (!isMOOC(series.urlString)) continue;
      const started = series.exercises.some((exercise) => exercise.isDone || exercise.subQuestionDoneCount > 0);
      if (!started) context.delete(series);
    }

    // Les éléments « MOOC · » que le brouillon ne contient plus disparaissent.
    const draftedMOOC = new Set(draft.sections.flatMap((section) => section.items)
      .filter((item) => item.title.startsWith("MOOC · ")).map((item) => item.number));
    if (draftedMOOC.size > 0) {
      for (const stale of [...course.theoryItems]) {
        if (stale.title.startsWith("MOOC · ") && !draftedMOOC.has(stale.number)) context.delete(stale);
      }
    }

    const chapters = course.theoryItems.filter((item) =>
      item.title.startsWith("MOOC · ") && item.plannedWeek > 0 && draftedMOOC.has(item.number));
    if (chapters.length === 0) return;
    const drafted = new Set(draft.sections.flatMap((section) => section.items.map((item) => item.url)));
    const leftovers = course.theoryItems.filter((item) => {
      // Une leçon sans semaine, ou un bloc d'un ancien import fait seulement de liens vers le MOOC.
      const onlyMOOC = isMOOC(item.urlString) && item.links.every((link) => isMOOC(link.url));
      return (item.plannedWeek === 0 || onlyMOOC) && isMOOC(item.urlString) && !drafted.has(item.urlString)
        && !item.title.startsWith("MOOC · ");
    });
    if (leftovers.length === 0) return;
    for (const chapter of chapters) {
      if (chapter.isWatched) continue;
      // Les leçons d'un chapitre : leur titre commence ses liens (« Variables — Vidéo 1 »).
      const lessonTitles = new Set(chapter.links.map((link) => link.title.split(" — ")[0]));
      const lessons = leftovers.filter((item) => lessonTitles.has(item.title) && item.videoCount > 0);
      if (lessons.length > 0 && lessons.every((lesson) => lesson.isWatched)) {
        chapter.watchedAt = new Date(Math.max(...lessons.map((lesson) => lesson.watchedAt?.getTime() ?? 0)));
      }
    }
    for (const item of leftovers) context.delete(item);
  },
};
