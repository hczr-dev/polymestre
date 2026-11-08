// Port de Polymestre/Domain/AssistantExport.swift : un instantané de l'état
// d'étude, lisible par un **assistant**. C'est la source du serveur MCP. Aucune
// donnée de compte, aucun jeton, aucune adhésion de groupe : un fichier qu'on
// partage ne doit pas transporter d'identités.

import type { AcademicMilestone } from "../models/academicMilestone.ts";
import type { Course } from "../models/course.ts";
import type { StudySession } from "../models/studySession.ts";
import type { StudyGroup } from "../models/studyGroup.ts";
import { ExerciseStage } from "./exerciseFlow.ts";
import { NotebookExport } from "./notebookExport.ts";
import type { RevisionSheet } from "./revisionSheet.ts";
import type { StudyMap } from "./studyMap.ts";

export interface AssistantExportInit {
  courses: Course[];
  sessions: StudySession[];
  milestones: AcademicMilestone[];
  groups: StudyGroup[];
  hoursPerCredit: number;
  displayName: string;
  includeContent?: boolean;
  /** L'index des fichiers que l'app enverra (`AssistantFiles`) ; ignoré sans `includeContent`. */
  files?: Record<string, unknown>[];
}

export const AssistantExport = {
  fileName: "polymestre-assistant.json",
  /** v2 : identifiants partout et étape de chaque exercice. v3 : contenu sur demande. */
  formatVersion: 3,

  /** Au-delà, un texte est tronqué : l'instantané voyage à chaque synchronisation. */
  notesLimit: 60_000,
  sheetLimit: 120_000,
  solutionLimit: 6_000,

  /** Construit l'instantané (`includeContent` : notes, fiche, corrigés rédigés, adresses). */
  make(o: AssistantExportInit): Record<string, unknown> {
    const includeContent = o.includeContent ?? false;
    const tracked = o.courses.filter((course) => course.isTracked);

    const payload: Record<string, unknown> = {
      format: "polymestre.assistant",
      version: AssistantExport.formatVersion,
      generatedAt: iso8601(new Date()),
    };
    payload["settings"] = { hoursPerCredit: o.hoursPerCredit, displayName: o.displayName };
    payload["sharing"] = { files: includeContent };
    if (includeContent) payload["files"] = o.files ?? [];

    payload["courses"] = tracked.map((course) => coursePayload(course, includeContent));

    payload["sessions"] = o.sessions.slice(0, 2000).map((session) => {
      const entry: Record<string, unknown> = {
        id: session.id,
        taskType: session.taskTypeRaw,
        startedAt: iso8601(session.startedAt),
        durationSeconds: session.durationSeconds,
        manual: session.isManual,
      };
      if (session.course !== null) entry["course"] = session.course.displayCode;
      if (session.targetLabel !== null) entry["target"] = session.targetLabel;
      if (session.exercise !== null) entry["exerciseId"] = session.exercise.id;
      if (session.theoryItem !== null) entry["theoryId"] = session.theoryItem.id;
      if (session.sourceRaw !== "") entry["source"] = session.sourceRaw;
      if (session.note !== "") entry["note"] = session.note;
      return entry;
    });

    payload["calendar"] = o.milestones.map((milestone) => ({
      title: milestone.title,
      date: iso8601(milestone.date),
      kind: milestone.kindRaw,
      approximate: milestone.isApproximate,
      term: milestone.termLabel,
    }));

    payload["groups"] = o.groups.map((group) => ({
      name: group.name,
      subjects: group.subjectCodes,
      members: group.members.length,
    }));

    return payload;
  },

  /** L'instantané sérialisé, prêt à être partagé (`Data` de Swift : une chaîne ici). */
  data(o: AssistantExportInit): string | null {
    const payload = AssistantExport.make(o);
    try {
      return JSON.stringify(payload, null, 2);
    } catch {
      return null;
    }
  },
};

function coursePayload(course: Course, includeContent: boolean): Record<string, unknown> {
  const payload: Record<string, unknown> = {
    id: course.id,
    code: course.displayCode,
    officialCode: course.code,
    name: course.name,
    credits: course.credits,
    hasLectures: course.hasLectures,
    weeklyLectureHours: course.weeklyLectureHours,
    weeklyExerciseHours: course.weeklyExerciseHours,
    currentWeek: course.currentWeek,
  };
  if (course.term !== null) {
    payload["term"] = course.term.displayName;
    payload["termWeeks"] = course.term.totalWeeks;
  }
  if (course.lecturer !== "") payload["lecturer"] = course.lecturer;

  payload["series"] = course.sortedSeries.map((series) => {
    const seriesEntry: Record<string, unknown> = {
      id: series.id,
      number: series.seriesNumber,
      title: series.title,
      plannedWeek: series.plannedWeek,
      complete: series.isComplete,
    };
    if (series.label !== "") seriesEntry["label"] = series.label;
    if (includeContent) {
      if (series.urlString !== "") seriesEntry["url"] = series.urlString;
      if (series.solutionURLString !== "") seriesEntry["solutionUrl"] = series.solutionURLString;
      if (series.topic !== "") seriesEntry["topic"] = series.topic;
    }
    seriesEntry["exercises"] = series.sortedExercises.map((exercise) => {
      const entry: Record<string, unknown> = {
        id: exercise.id,
        number: exercise.exerciseNumber,
        title: exercise.title,
        stage: ExerciseStage.label(ExerciseStage(exercise)),
        bonus: exercise.isBonus,
        done: exercise.isDone,
        corrected: exercise.isCorrected,
        redo: exercise.redoRequired,
      };
      if (exercise.correctness !== null) entry["correctness"] = exercise.correctness;
      if (exercise.correctionNote !== null && exercise.correctionNote !== "") entry["correctionNote"] = exercise.correctionNote;
      if (exercise.statement !== "") entry["statement"] = exercise.statement;
      if (includeContent) {
        if (exercise.solution !== "") entry["solution"] = clip(exercise.solution, AssistantExport.solutionLimit);
        if (exercise.hint !== "") entry["hint"] = exercise.hint;
      }
      if (exercise.hasSubQuestions) {
        entry["questions"] = exercise.leafSubQuestions.map((question) => ({
          path: question.path,
          label: question.parent !== null ? `${question.parent.displayLabel} ${question.displayLabel}` : question.displayLabel,
          text: question.text,
          done: question.isDone,
        }));
      }
      return entry;
    });
    return seriesEntry;
  });

  payload["theory"] = course.sortedTheoryItems.map((item) => {
    const entry: Record<string, unknown> = {
      id: item.id,
      number: item.number,
      title: item.title,
      kind: item.kindRaw,
      watched: item.isWatched,
      summarized: item.isSummarized,
      plannedWeek: item.plannedWeek,
    };
    if (item.durationSeconds > 0) entry["durationSeconds"] = item.durationSeconds;
    if (item.summaryText !== null && item.summaryText !== "") entry["summary"] = item.summaryText;
    return entry;
  });

  payload["exams"] = course.sortedExams.map((exam) => {
    const entry: Record<string, unknown> = {
      id: exam.id,
      title: exam.title,
      kind: exam.kindRaw,
      date: iso8601(exam.date),
      past: exam.isPast,
    };
    if (exam.weightPercent !== null) entry["weightPercent"] = exam.weightPercent;
    if (exam.location !== "") entry["location"] = exam.location;
    return entry;
  });

  if (includeContent) {
    if (course.notes !== "") payload["notes"] = clip(course.notes, AssistantExport.notesLimit);
    const sheet = course.revisionSheet as unknown as RevisionSheet | null;
    if (sheet !== null) {
      const text = NotebookExport.sheetText(course.name, sheet, course.studyMap as unknown as StudyMap);
      if (text !== "") payload["revisionSheet"] = clip(text, AssistantExport.sheetLimit);
    }
    if (course.documents.length !== 0) {
      payload["documents"] = course.documents.map((document) => ({
        title: document.title, url: document.url, group: document.group,
      }));
    }
    payload["pastExams"] = course.pastExams.map((exam) => {
      const entry: Record<string, unknown> = {
        id: exam.id, title: exam.title, year: exam.year, kind: exam.kindRaw,
      };
      if (exam.urlString !== "") entry["url"] = exam.urlString;
      if (exam.solutionURLString !== "") entry["solutionUrl"] = exam.solutionURLString;
      if (exam.notes !== "") entry["notes"] = clip(exam.notes, AssistantExport.notesLimit);
      return entry;
    });
    payload["resources"] = course.sortedResources.map((resource) => {
      const entry: Record<string, unknown> = {
        id: resource.id, title: resource.title, kind: resource.kindRaw,
      };
      if (resource.address !== "") entry["address"] = resource.address;
      if (resource.fileName !== "") entry["fileName"] = resource.fileName;
      return entry;
    });
  }

  return payload;
}

function clip(text: string, limit: number): string {
  return Array.from(text).length > limit ? Array.from(text).slice(0, limit).join("") + "\n\n[…tronqué]" : text;
}

/** `ISO8601DateFormatter` par défaut : sans fractions de seconde. */
function iso8601(date: Date): string {
  return date.toISOString().replace(/\.\d{3}Z$/, "Z");
}
