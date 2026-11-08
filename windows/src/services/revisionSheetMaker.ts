// La fiche de révision d'un cours, faite sur le PC et rangée dans le cours (synchronisée)
// — RevisionSheetMaker du Mac :
//   • cours Botafogo : chaque section du polycopié est lue, ses énoncés repris tels quels
//     (sans IA) ; Claude, s'il est là, y ajoute les méthodes et les pièges des séries ;
//   • autres cours : Claude (par l'abonnement) lit tout le matériel — documents PDF, séries,
//     corrigés — et écrit la fiche.

import type { Course } from "../models/course.ts";
import { RevisionSheet, RevisionSheetAI, RevisionSheetBuilder } from "../domain/revisionSheet.ts";
import type { BotafogoBlock } from "../domain/botafogoPage.ts";
import { botafogoBook, isBotafogo } from "./botafogoBook.ts";
import { askClaude, claudeSetup } from "./claudeConversation.ts";
import { askTutor } from "./freeTutor.ts";
import { SeriesPDFStore } from "./seriesPDFStore.ts";
import { linesFromData, plainText } from "./pdfLayoutExtractor.ts";

type Material = { title: string; text: string }[];

function site(course: Course): string | null {
  return course.contentSources.find(isBotafogo) ?? null;
}

/** Peut-on faire la fiche de ce cours ici ? (le polycopié, ou Claude pour le reste) */
export async function canMakeSheet(_course: Course): Promise<boolean> {
  return true;
}

/** Claude s'il est là (l'abonnement), sinon le modèle gratuit du serveur. */
async function write(instructions: string, mode: "sheet" | "sheetMethods", prompt: string, progress: (text: string) => void): Promise<string> {
  if ((await claudeSetup())?.found) return askClaude(instructions, prompt, progress);
  return (await askTutor(mode, [{ role: "user", content: prompt }])).text;
}

async function pdfText(address: string): Promise<string | null> {
  let url: URL;
  try { url = new URL(address); } catch { return null; }
  try {
    const bytes = await SeriesPDFStore.download(url);
    const text = plainText(await linesFromData(bytes));
    return text.trim().length > 40 ? text : null;
  } catch {
    return null;
  }
}

const isPDFAddress = (address: string) => /^https?:/i.test(address) && (/\.pdf($|[?#])/i.test(address) || /pluginfile\.php|\/mod\/resource\//.test(address));

async function seriesMaterial(course: Course, progress: (text: string) => void): Promise<Material> {
  const result: Material = [];
  for (const series of course.sortedSeries.filter((s) => s.exercises.length > 0)) {
    const name = series.title ? `${series.displayName} · ${series.title}` : series.displayName;
    const lines: string[] = [];
    for (const exercise of series.sortedExercises) {
      lines.push(`— ${exercise.displayNumber}${exercise.title ? " · " + exercise.title : ""}`);
      if (exercise.statement) lines.push(exercise.statement);
      if (exercise.hint) lines.push("Indication : " + exercise.hint);
      if (exercise.solution) lines.push("Corrigé : " + exercise.solution);
    }
    if (isPDFAddress(series.solutionURLString)) {
      progress(`Lecture du corrigé · ${name}`);
      const text = await pdfText(series.solutionURLString);
      if (text) lines.push("Corrigé (PDF) :\n" + text);
    }
    result.push({ title: name, text: lines.join("\n") });
  }
  return result;
}

async function allMaterial(course: Course, progress: (text: string) => void): Promise<Material> {
  const result: Material = [];
  const outline = course.sortedTheoryItems.map((item) => `Semaine ${item.plannedWeek} · ${item.numberAndTitle}${item.summaryText ? " — " + item.summaryText : ""}`);
  if (outline.length > 0) result.push({ title: "Plan du cours", text: outline.join("\n") });
  const seen = new Set<string>();
  const documents: { title: string; url: string }[] = [];
  const add = (title: string, url: string) => { if (isPDFAddress(url) && !seen.has(url)) { seen.add(url); documents.push({ title, url }); } };
  for (const item of course.sortedTheoryItems) {
    add(`Semaine ${item.plannedWeek} · ${item.numberAndTitle}`, item.urlString);
    for (const link of item.links) add(`Semaine ${item.plannedWeek} · ${link.title || item.numberAndTitle}`, link.url);
  }
  for (const document of course.documents) add(document.title, document.url);
  for (const series of course.sortedSeries) add(`Énoncé · ${series.displayName}`, series.urlString);
  for (const [index, document] of documents.entries()) {
    progress(`Lecture des documents… ${index + 1}/${documents.length}`);
    const text = await pdfText(document.url);
    if (text) result.push({ title: document.title, text });
  }
  result.push(...await seriesMaterial(course, progress));
  return result;
}

async function handoutSheet(address: string, progress: (text: string) => void): Promise<RevisionSheet> {
  const book = botafogoBook(address);
  progress("Lecture du polycopié…");
  await book.load();
  const sections = book.chapters.flatMap((chapter) => chapter.sections);
  if (sections.length === 0) throw new Error("Le polycopié de ce cours est introuvable.");
  const pages: Record<string, BotafogoBlock[]> = {};
  for (let index = 0; index < sections.length; index += 6) {
    const batch = sections.slice(index, index + 6);
    const read = await Promise.all(batch.map((section) => book.page(section.path)));
    batch.forEach((section, i) => { const blocks = read[i]; if (blocks) pages[section.path] = blocks; });
    progress(`Lecture du polycopié… ${Math.min(index + 6, sections.length)}/${sections.length}`);
  }
  return RevisionSheetBuilder.sheet(book.chapters, pages);
}

/** Fait la fiche et la range dans le cours (à sauvegarder par l'appelant). */
export async function makeRevisionSheet(course: Course, progress: (text: string) => void): Promise<RevisionSheet> {
  const handout = site(course);
  let sheet: RevisionSheet;
  if (handout) {
    sheet = await handoutSheet(handout, progress);
    {
      const material = await seriesMaterial(course, progress);
      if (material.length > 0) {
        progress("Écriture des méthodes des séries…");
        try {
          const answer = await write(RevisionSheetAI.methodsInstructions, "sheetMethods", RevisionSheetAI.prompt(course.name, material, 200_000), progress);
          const methods = RevisionSheetAI.sheet(answer);
          if (methods) {
            for (const chapter of methods.chapters) chapter.title = "Méthodes · " + chapter.title;
            sheet.chapters.push(...methods.chapters);
          }
        } catch {
          // La fiche du polycopié reste, sans les méthodes.
        }
      }
    }
  } else {
    const material = await allMaterial(course, progress);
    if (material.length === 0) throw new Error("Aucun document lisible dans ce cours.");
    const pages = Math.round(material.reduce((sum, item) => sum + item.text.length, 0) / 2500);
    progress(`Écriture de la fiche (${material.length} documents, ~${pages} pages)…`);
    const written = RevisionSheetAI.sheet(await write(RevisionSheetAI.instructions, "sheet", RevisionSheetAI.prompt(course.name, material, 200_000), progress));
    if (!written) throw new Error("Le modèle n'a pas rendu de fiche lisible. Réessaie.");
    sheet = written;
  }
  if (sheet.entries.length === 0) throw new Error("Rien à mettre sur la fiche.");
  course.revisionSheet = sheet;
  return sheet;
}
