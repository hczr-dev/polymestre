// Supabase Edge Function : le serveur MCP de StudyTrack.
//
// Un assistant (Claude, ChatGPT, tout client MCP) y lit l'état d'étude et y
// **demande** des modifications. Transport : MCP « Streamable HTTP », réponses
// JSON (pas de flux SSE : chaque outil répond en une fois).
//
//   https://<projet>.supabase.co/functions/v1/mcp/<jeton>        ← l'assistant
//   https://<projet>.supabase.co/functions/v1/mcp/<jeton>/sync   ← l'app
//
// Le **jeton** est un secret de 256 bits tiré par l'app (Profil › Assistant IA).
// Il est dans l'adresse parce que les connecteurs de Claude.ai et de ChatGPT
// n'acceptent qu'une adresse — pas d'en-tête. La base n'en garde que le
// SHA-256 : une fuite de la table ne donne accès à rien.
//
// Pourquoi l'app applique elle-même les modifications : les données vivent
// dans SwiftData, sur le téléphone. L'assistant dépose une commande ; l'app la
// récupère à sa prochaine synchronisation (ouverture, retour au premier plan,
// chaque enregistrement), l'applique avec les règles de l'interface, et renvoie
// le compte rendu. En attendant, l'instantané est mis à jour **tout de suite**
// pour que l'assistant lise ce qu'il vient d'écrire.
//
// Déploiement :
//   supabase db push                       # tables assistant_links / assistant_commands
//   supabase functions deploy mcp --no-verify-jwt
// (`--no-verify-jwt` : l'accès se fait par le jeton de l'adresse, pas par un
// JWT Supabase. SUPABASE_URL et SUPABASE_SERVICE_ROLE_KEY sont fournis par
// la plateforme.)

declare const Deno: {
  env: { get(key: string): string | undefined };
  serve(handler: (request: Request) => Response | Promise<Response>): void;
};

const SERVER_INFO = { name: "polymestre", title: "Polymestre", version: "3.0.0" };
const PROTOCOLS = ["2025-06-18", "2025-03-26", "2024-11-05"];
// L'instantané porte maintenant les notes et les fiches : de la marge.
const MAX_BODY = 8 * 1024 * 1024;
// Une réponse MCP plafonne à 16 Mo, base64 (×4/3) compris — vérifié avec Claude
// Code : un PDF de 12 Mo est refusé en entier. 10 Mo de fichier en font 13,4.
const MAX_FILE = 10 * 1024 * 1024;
const BUCKET = "assistant-files";
const SHA = /^[0-9a-f]{64}$/;

const INSTRUCTIONS = `Polymestre suit les études d'un·e étudiant·e de l'EPFL : cours, séries d'exercices (avec sous-questions et correction vert/orange/rouge), théorie (vidéos, sections de polycopié), évaluations et temps de travail.

- Commence par get_overview. Pour agir sur un exercice précis, lis d'abord get_course : il donne les identifiants (id) à passer aux outils d'écriture.
- Les fichiers : list_files donne les énoncés et corrigés (PDF), les notes de cours, la fiche de révision, les corrigés rédigés et les fichiers ajoutés ; read_file(id) les rend (texte, ou PDF/image à ouvrir avec Read). Un fichier « pas disponible » n'est pas encore passé par l'app : la raison est donnée.
- Les outils d'écriture sont appliqués par l'app à sa prochaine ouverture ; la lecture reflète le changement immédiatement. list_pending_changes dit ce qui attend et ce qui a échoué.
- Étapes d'un exercice : à faire → en cours (questions) → fait, à corriger → corrigé vert (juste), orange (moyen) ou rouge (faux, donc « à refaire »).
- Le code vert/orange/rouge est celui de la CORRECTION. Sois honnête : une correction se constate (avec l'étudiant·e ou en comparant au corrigé), elle ne s'invente pas.`;

// ─────────────────────────────────────────────────────────────── Base ────

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

async function db(path: string, init: RequestInit = {}): Promise<any> {
  const response = await fetch(`${SUPABASE_URL}/rest/v1/${path}`, {
    ...init,
    headers: {
      apikey: SERVICE_KEY,
      Authorization: `Bearer ${SERVICE_KEY}`,
      "Content-Type": "application/json",
      Prefer: "return=representation",
      ...(init.headers ?? {}),
    },
  });
  const text = await response.text();
  if (!response.ok) throw new Error(`base : ${response.status} ${text.slice(0, 200)}`);
  return text ? JSON.parse(text) : null;
}

interface Link {
  token_hash: string;
  snapshot: any;
  snapshot_at: string | null;
}

interface Command {
  id: string;
  kind: string;
  payload: Record<string, unknown>;
  status: string;
  result: string | null;
  summary: string | null;
  created_at: string;
  applied_at: string | null;
}

async function getLink(hash: string): Promise<Link | null> {
  const rows = await db(`assistant_links?token_hash=eq.${hash}&select=token_hash,snapshot,snapshot_at`);
  return rows?.[0] ?? null;
}

async function saveSnapshot(hash: string, snapshot: unknown, touchTime = true): Promise<void> {
  const row: Record<string, unknown> = { token_hash: hash, snapshot, last_used_at: new Date().toISOString() };
  if (touchTime) row.snapshot_at = new Date().toISOString();
  await db("assistant_links?on_conflict=token_hash", {
    method: "POST",
    headers: { Prefer: "resolution=merge-duplicates,return=minimal" },
    body: JSON.stringify(row),
  });
}

async function sha256(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

// ─────────────────────────────────────────────────────────── Outils ────

const course = { type: "string", description: "Code du cours (ex. MATH-101) ou son nom" };
const exerciseTarget = {
  exercise_id: { type: "string", description: "Identifiant de l'exercice (get_course)" },
  course,
  exercise: { type: "string", description: "Numéro de l'exercice (ex. 3.4), avec course" },
};

const FILE_TYPES = ["enonce", "corrige", "corrige-texte", "notes", "fiche", "notes-examen", "ressource"];

const TOOLS = [
  {
    name: "get_overview",
    title: "Vue d'ensemble",
    description: "Où en est l'étudiant·e : semaine du semestre, avancement par cours, ce qu'il reste à faire en priorité, prochaines évaluations, temps de travail des 7 derniers jours. À appeler en premier.",
    inputSchema: { type: "object", properties: {} },
    annotations: { readOnlyHint: true },
  },
  {
    name: "list_courses",
    title: "Cours suivis",
    description: "Les cours suivis : crédits, semaine actuelle, avancement en exercices, corrections et théorie.",
    inputSchema: { type: "object", properties: { course } },
    annotations: { readOnlyHint: true },
  },
  {
    name: "get_course",
    title: "Détail d'un cours",
    description: "Tout un cours : séries et exercices (id, étape, correction, remarque, questions), théorie (id, semaine, vu, résumé), évaluations, temps passé par exercice. Donne les identifiants nécessaires aux outils d'écriture.",
    inputSchema: {
      type: "object",
      properties: { course, series: { type: "number", description: "Limiter à une série" } },
      required: ["course"],
    },
    annotations: { readOnlyHint: true },
  },
  {
    name: "what_to_do",
    title: "À faire",
    description: "Ce qui reste, par urgence : séries en retard, exercices à refaire, à juger, à corriger, théorie à voir ou à résumer.",
    inputSchema: {
      type: "object",
      properties: { course, limit: { type: "number", description: "Nombre maximal (20 par défaut)" } },
    },
    annotations: { readOnlyHint: true },
  },
  {
    name: "search",
    title: "Chercher",
    description: "Cherche dans les cours, exercices (titre, énoncé, remarque de correction) et la théorie (titre, résumé).",
    inputSchema: { type: "object", properties: { query: { type: "string" } }, required: ["query"] },
    annotations: { readOnlyHint: true },
  },
  {
    name: "upcoming_dates",
    title: "Échéances",
    description: "Évaluations des cours et dates du calendrier académique EPFL à venir.",
    inputSchema: { type: "object", properties: { days: { type: "number", description: "Horizon en jours (120 par défaut)" } } },
    annotations: { readOnlyHint: true },
  },
  {
    name: "study_time",
    title: "Temps de travail",
    description: "Temps de travail par cours, par type et par jour sur les N derniers jours.",
    inputSchema: { type: "object", properties: { days: { type: "number" }, course } },
    annotations: { readOnlyHint: true },
  },
  {
    name: "list_files",
    title: "Fichiers",
    description: "Les fichiers du cours que l'assistant peut lire : énoncés et corrigés de séries (PDF), notes de cours, fiche de révision, corrigés rédigés, fichiers ajoutés. Chacun a un identifiant pour read_file, et dit s'il est disponible.",
    inputSchema: {
      type: "object",
      properties: {
        course,
        type: { type: "string", enum: FILE_TYPES, description: "enonce, corrige (PDF de la série), corrige-texte (corrigés rédigés), notes, fiche, notes-examen, ressource" },
        series: { type: "number", description: "Numéro de série" },
      },
    },
    annotations: { readOnlyHint: true },
  },
  {
    name: "read_file",
    title: "Lire un fichier",
    description: "Le contenu d'un fichier de list_files. Texte et Markdown reviennent en texte ; un PDF revient en pièce jointe que l'assistant enregistre et ouvre avec son outil de lecture (les formules y sont intactes) ; une image, en image.",
    inputSchema: { type: "object", properties: { id: { type: "string", description: "Identifiant donné par list_files" } }, required: ["id"] },
    annotations: { readOnlyHint: true },
  },
  {
    name: "list_pending_changes",
    title: "Modifications en attente",
    description: "Les modifications demandées par un assistant : en attente d'application par l'app, appliquées, ou échouées (avec la raison).",
    inputSchema: { type: "object", properties: {} },
    annotations: { readOnlyHint: true },
  },
  {
    name: "update_exercise",
    title: "Mettre à jour un exercice",
    description: "Marque un exercice fait / à faire, enregistre sa correction (correct = vert, partial = orange, wrong = rouge, qui le marque à refaire), « à refaire », ou une remarque. Corriger un exercice le marque fait.",
    inputSchema: {
      type: "object",
      properties: {
        ...exerciseTarget,
        done: { type: "boolean" },
        correctness: { type: "string", enum: ["correct", "partial", "wrong"], description: "vert, orange, rouge" },
        redo: { type: "boolean" },
        note: { type: "string", description: "Remarque de correction (ce qu'il faut retenir)" },
      },
    },
    annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true },
  },
  {
    name: "check_questions",
    title: "Cocher des questions",
    description: "Coche (ou décoche) des sous-questions d'un exercice, par étiquette (« a », « 1.b ») ; sans liste, toutes. L'exercice est fait quand toutes le sont.",
    inputSchema: {
      type: "object",
      properties: {
        ...exerciseTarget,
        questions: { type: "array", items: { type: "string" } },
        done: { type: "boolean", description: "false pour décocher (true par défaut)" },
      },
    },
    annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true },
  },
  {
    name: "update_theory",
    title: "Mettre à jour la théorie",
    description: "Marque un élément de théorie vu / pas vu, ou enregistre son résumé (ce qui le marque vu).",
    inputSchema: {
      type: "object",
      properties: {
        theory_id: { type: "string" },
        course,
        theory: { type: "string", description: "Numéro (ex. 3.2), avec course" },
        watched: { type: "boolean" },
        summary: { type: "string" },
      },
    },
    annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true },
  },
  {
    name: "log_study_session",
    title: "Enregistrer une session",
    description: "Ajoute une session de travail passée au journal (ex. « 45 min d'exercices sur MATH-101 hier soir »).",
    inputSchema: {
      type: "object",
      properties: {
        course,
        type: { type: "string", enum: ["theory", "exercise", "correction", "other"] },
        minutes: { type: "number" },
        started_at: { type: "string", description: "Début, ISO 8601 (par défaut : se termine maintenant)" },
        exercise: { type: "string", description: "Numéro d'exercice visé, facultatif" },
        theory: { type: "string", description: "Numéro de théorie visé, facultatif" },
        note: { type: "string" },
      },
      required: ["type", "minutes"],
    },
    annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false },
  },
  {
    name: "add_series",
    title: "Ajouter une série",
    description: "Ajoute (ou complète) une série d'exercices, avec ses exercices et leurs sous-questions. N'efface jamais un exercice existant.",
    inputSchema: {
      type: "object",
      properties: {
        course,
        number: { type: "number", description: "Numéro de la série ; sans numéro, celui de sa semaine" },
        label: { type: "string", description: "Ce qui distingue deux séries de même numéro (« b », « mardi »), sinon vide" },
        week: { type: "number", description: "Semaine du semestre" },
        title: { type: "string" },
        exercises: {
          type: "array",
          items: {
            type: "object",
            properties: {
              number: { type: "string", description: "ex. 4.2" },
              title: { type: "string" },
              statement: { type: "string", description: "Ce que l'exercice demande, en une phrase" },
              bonus: { type: "boolean" },
              questions: { type: "array", items: { type: "string" }, description: "Étiquettes : a, b, c…" },
            },
            required: ["number"],
          },
        },
      },
      required: ["course", "number"],
    },
    annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true },
  },
  {
    name: "add_exam",
    title: "Ajouter une évaluation",
    description: "Ajoute un midterm, un examen, un quiz ou un rendu à un cours.",
    inputSchema: {
      type: "object",
      properties: {
        course,
        title: { type: "string" },
        date: { type: "string", description: "ISO 8601 (date ou date et heure)" },
        kind: { type: "string", enum: ["midterm", "exam", "quiz", "project", "assignment", "other"] },
        location: { type: "string" },
      },
      required: ["course", "date"],
    },
    annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false },
  },
];

// ─────────────────────────────────────────────────────── Lectures ────

const fold = (value: unknown) =>
  String(value ?? "").normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase().trim();

const hours = (seconds: number) => `${Math.round((seconds / 3600) * 10) / 10} h`;
const daysAgo = (iso: string, days: number) => Date.now() - new Date(iso).getTime() <= days * 86400000;

function findCourse(data: any, query: unknown): any {
  const needle = fold(query);
  if (!needle) return null;
  const courses = data.courses ?? [];
  return courses.find((c: any) => c.id === query)
    ?? courses.find((c: any) => fold(c.code) === needle || fold(c.officialCode) === needle)
    ?? courses.find((c: any) => fold(c.name) === needle)
    ?? courses.find((c: any) => fold(c.officialCode).startsWith(needle) || fold(c.name).includes(needle))
    ?? null;
}

function allExercises(course: any): any[] {
  return (course.series ?? []).flatMap((s: any) => (s.exercises ?? []).map((e: any) => ({ ...e, seriesNumber: s.number })));
}

function exerciseSeconds(data: any): Record<string, number> {
  const totals: Record<string, number> = {};
  for (const s of data.sessions ?? []) {
    if (s.exerciseId) totals[s.exerciseId] = (totals[s.exerciseId] ?? 0) + s.durationSeconds;
  }
  return totals;
}

function courseProgress(c: any) {
  const exercises = allExercises(c).filter((e) => !e.bonus);
  const theory = c.theory ?? [];
  return {
    code: c.code,
    nom: c.name,
    credits: c.credits,
    semaine: c.currentWeek,
    exercices: `${exercises.filter((e) => e.done).length}/${exercises.length} faits, ${exercises.filter((e) => e.corrected).length} corrigés`,
    theorie: `${theory.filter((t: any) => t.watched).length}/${theory.length} vus`,
    aRefaire: exercises.filter((e) => e.redo).length,
  };
}

function whatToDo(data: any, args: any) {
  const filter = args.course ? findCourse(data, args.course) : null;
  const limit = Number.isFinite(args.limit) ? args.limit : 20;
  const items: any[] = [];
  const rank: Record<string, number> = { "série en retard": 0, "à refaire": 1, "à corriger": 3, "série de la semaine": 4, "théorie à voir": 5, "à résumer": 6 };
  for (const c of data.courses ?? []) {
    if (filter && c.id !== filter.id) continue;
    const week = c.currentWeek || 1;
    for (const series of c.series ?? []) {
      const pending = (series.exercises ?? []).filter((e: any) => !e.done && !e.bonus);
      if (pending.length && series.plannedWeek <= week) {
        items.push({
          urgence: series.plannedWeek < week ? "série en retard" : "série de la semaine",
          cours: c.code, quoi: `Série ${series.number}`, reste: pending.map((e: any) => e.number).join(", "),
        });
      }
      for (const e of series.exercises ?? []) {
        if (e.redo) items.push({ urgence: "à refaire", cours: c.code, quoi: `Exercice ${e.number}`, id: e.id, note: e.correctionNote });
        else if (e.done && !e.corrected) items.push({ urgence: "à corriger", cours: c.code, quoi: `Exercice ${e.number}`, id: e.id });
      }
    }
    for (const t of c.theory ?? []) {
      if (t.plannedWeek > week) continue;
      if (!t.watched) items.push({ urgence: "théorie à voir", cours: c.code, quoi: `${t.number} ${t.title}`, id: t.id, semaine: t.plannedWeek });
    }
  }
  items.sort((a, b) => (rank[a.urgence] ?? 9) - (rank[b.urgence] ?? 9));
  return { total: items.length, elements: items.slice(0, limit) };
}

function upcomingDates(data: any, args: any) {
  const horizon = Number.isFinite(args.days) ? args.days : 120;
  const now = Date.now();
  const limit = now + horizon * 86400000;
  const inWindow = (iso: string) => { const t = new Date(iso).getTime(); return t >= now - 86400000 && t <= limit; };
  return {
    evaluations: (data.courses ?? []).flatMap((c: any) => (c.exams ?? [])
      .filter((e: any) => inWindow(e.date))
      .map((e: any) => ({ date: e.date.slice(0, 16), cours: c.code, titre: e.title, nature: e.kind, lieu: e.location, poids: e.weightPercent })))
      .sort((a: any, b: any) => a.date.localeCompare(b.date)),
    calendrierEPFL: (data.calendar ?? []).filter((m: any) => inWindow(m.date))
      .map((m: any) => ({ date: m.date.slice(0, 10), titre: m.title, approximatif: m.approximate || undefined })),
  };
}

function studyTime(data: any, args: any) {
  const days = Number.isFinite(args.days) ? args.days : 7;
  const filter = args.course ? findCourse(data, args.course) : null;
  const byCourse: Record<string, number> = {};
  const byType: Record<string, number> = {};
  const byDay: Record<string, number> = {};
  for (const s of (data.sessions ?? []).filter((s: any) => daysAgo(s.startedAt, days))) {
    if (filter && s.course !== filter.code) continue;
    byCourse[s.course ?? "sans cours"] = (byCourse[s.course ?? "sans cours"] ?? 0) + s.durationSeconds;
    const type = s.source === "anki" ? "anki" : s.taskType;
    byType[type] = (byType[type] ?? 0) + s.durationSeconds;
    const day = s.startedAt.slice(0, 10);
    byDay[day] = (byDay[day] ?? 0) + s.durationSeconds;
  }
  const sorted = (o: Record<string, number>) => Object.entries(o).sort((a, b) => b[1] - a[1]);
  return {
    jours: days,
    total: hours(Object.values(byCourse).reduce((a, b) => a + b, 0)),
    parCours: sorted(byCourse).map(([k, v]) => ({ cours: k, temps: hours(v) })),
    parType: sorted(byType).map(([k, v]) => ({ type: k, temps: hours(v) })),
    parJour: Object.entries(byDay).sort().map(([k, v]) => ({ jour: k, temps: hours(v) })),
  };
}

function getCourse(data: any, args: any) {
  const c = findCourse(data, args.course);
  if (!c) throw new UserError(`Cours « ${args.course} » introuvable. Cours suivis : ${(data.courses ?? []).map((x: any) => x.code).join(", ")}.`);
  const seconds = exerciseSeconds(data);
  const series = (c.series ?? []).filter((s: any) => !Number.isFinite(args.series) || s.number === args.series);
  return {
    id: c.id, code: c.code, nom: c.name, credits: c.credits, semaine: c.currentWeek, enseignant: c.lecturer,
    fichiers: fileIndex(data).filter((e) => e.courseId === c.id).map((e) => ({ id: e.id, type: e.type, titre: e.titre, serie: e.serie })),
    series: series.map((s: any) => ({
      id: s.id, numero: s.number, etiquette: s.label || undefined, titre: s.title, semaine: s.plannedWeek, terminee: s.complete,
      sujet: s.topic || undefined, adresse: s.url || undefined, adresseCorrige: s.solutionUrl || undefined,
      exercices: (s.exercises ?? []).map((e: any) => ({
        id: e.id, numero: e.number, titre: e.title || undefined, enonce: e.statement, etape: e.stage,
        bonus: e.bonus || undefined, correction: e.correctness, remarque: e.correctionNote,
        indice: e.hint || undefined, corrige: e.solution || undefined,
        questions: e.questions?.map((q: any) => `${q.done ? "☑" : "☐"} ${q.path}${q.text ? " " + q.text : ""}`),
        tempsPasse: seconds[e.id] ? hours(seconds[e.id]) : undefined,
      })),
    })),
    theorie: Number.isFinite(args.series) ? undefined : (c.theory ?? []).map((t: any) => ({
      id: t.id, numero: t.number, titre: t.title, semaine: t.plannedWeek, vu: t.watched, resume: t.summary,
    })),
    evaluations: (c.exams ?? []).map((e: any) => ({ id: e.id, titre: e.title, date: e.date, nature: e.kind, passee: e.past })),
    anciensExamens: Number.isFinite(args.series) ? undefined : (c.pastExams ?? []).map((e: any) => ({
      id: e.id, titre: e.title, annee: e.year, nature: e.kind, adresse: e.url || undefined, adresseCorrige: e.solutionUrl || undefined,
    })),
    documents: Number.isFinite(args.series) ? undefined : (c.documents ?? []).map((d: any) => ({ titre: d.title, groupe: d.group || undefined, adresse: d.url })),
    ressources: Number.isFinite(args.series) ? undefined : (c.resources ?? []).map((r: any) => ({ id: r.id, titre: r.title, nature: r.kind, adresse: r.address || undefined, fichier: r.fileName || undefined })),
  };
}

function search(data: any, args: any) {
  const needle = fold(args.query);
  if (!needle) throw new UserError("Requête vide.");
  const hits: any[] = [];
  for (const c of data.courses ?? []) {
    if (fold(`${c.code} ${c.name} ${c.lecturer ?? ""}`).includes(needle)) hits.push({ type: "cours", cours: c.code, texte: c.name });
    for (const e of allExercises(c)) {
      if (fold(`${e.number} ${e.title} ${e.statement ?? ""} ${e.correctionNote ?? ""}`).includes(needle)) {
        hits.push({ type: "exercice", cours: c.code, id: e.id, texte: `Exercice ${e.number}${e.title ? " — " + e.title : ""}`, etape: e.stage, remarque: e.correctionNote });
      }
    }
    for (const t of c.theory ?? []) {
      if (fold(`${t.number} ${t.title} ${t.summary ?? ""}`).includes(needle)) {
        hits.push({ type: "théorie", cours: c.code, id: t.id, texte: `${t.number} ${t.title}`, resume: t.summary });
      }
    }
  }
  for (const f of fileIndex(data)) {
    if (f.text === undefined) continue;
    const at = fold(f.text).indexOf(needle);
    if (at < 0) continue;
    const extrait = f.text.slice(Math.max(0, at - 80), at + needle.length + 120).replace(/\s+/g, " ").trim();
    hits.push({ type: f.type, cours: f.cours, fichier: f.id, texte: f.titre, extrait });
  }
  return { requete: args.query, total: hits.length, resultats: hits.slice(0, 40) };
}

function overview(data: any, snapshotAt: string | null) {
  const week = (data.sessions ?? []).filter((s: any) => daysAgo(s.startedAt, 7));
  return {
    instantane: snapshotAt ? `synchronisé le ${snapshotAt.slice(0, 16).replace("T", " ")} (UTC)` : "jamais synchronisé",
    semaine: data.courses?.[0]?.currentWeek,
    tempsSur7Jours: hours(week.reduce((a: number, s: any) => a + s.durationSeconds, 0)),
    cours: (data.courses ?? []).map(courseProgress),
    priorites: whatToDo(data, { limit: 8 }).elements,
    prochainesEvaluations: upcomingDates(data, { days: 60 }).evaluations.slice(0, 5),
  };
}

// ─────────────────────────────────────────────────────── Fichiers ────

/// Un fichier que l'assistant peut lire. Deux origines : un **texte** tiré de
/// l'instantané (notes, fiche, corrigés rédigés), ou un fichier **envoyé par
/// l'app** et gardé dans le stockage, désigné par son SHA-256.
interface FileEntry {
  id: string;
  courseId: string;
  cours: string;
  type: string;
  titre: string;
  serie?: number;
  nom: string;
  mime: string;
  text?: string;
  sha?: string;
  bytes?: number;
  adresse?: string;
  skipped?: string;
}

const slug = (value: unknown) => fold(value).replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "") || "fichier";

function fileIndex(data: any): FileEntry[] {
  const entries: FileEntry[] = [];
  for (const c of data.courses ?? []) {
    const base = { courseId: c.id, cours: c.code };
    if (typeof c.notes === "string" && c.notes.trim()) {
      entries.push({ ...base, id: `notes:${c.id}`, type: "notes", titre: `Notes — ${c.name}`, nom: `${slug(c.code)}-notes.md`, mime: "text/markdown", text: c.notes });
    }
    if (typeof c.revisionSheet === "string" && c.revisionSheet.trim()) {
      entries.push({ ...base, id: `fiche:${c.id}`, type: "fiche", titre: `Fiche de révision — ${c.name}`, nom: `${slug(c.code)}-fiche.md`, mime: "text/markdown", text: c.revisionSheet });
    }
    for (const s of c.series ?? []) {
      const solved = (s.exercises ?? []).filter((e: any) => typeof e.solution === "string" && e.solution.trim());
      if (!solved.length) continue;
      const text = [`# Corrigé — ${c.code}, série ${s.number}`, ...solved.map((e: any) => `## Exercice ${e.number}${e.title ? " — " + e.title : ""}\n\n${e.solution}`)].join("\n\n");
      entries.push({ ...base, id: `corrige-texte:${s.id}`, type: "corrige-texte", titre: `Corrigé rédigé — série ${s.number}`, serie: s.number, nom: `${slug(c.code)}-serie-${s.number}-corrige.md`, mime: "text/markdown", text });
    }
    for (const e of c.pastExams ?? []) {
      if (typeof e.notes === "string" && e.notes.trim()) {
        entries.push({ ...base, id: `notes-examen:${e.id}`, type: "notes-examen", titre: `Notes — ${e.title}`, nom: `${slug(c.code)}-${slug(e.title)}-notes.md`, mime: "text/markdown", text: e.notes });
      }
    }
  }
  for (const f of data.files ?? []) {
    if (typeof f?.id !== "string" || (f.sha !== undefined && !SHA.test(f.sha))) continue;
    entries.push({
      id: f.id, courseId: f.courseId, cours: f.course ?? "", type: f.kind, titre: f.title ?? f.name, serie: f.seriesNumber,
      nom: f.name, mime: f.mime || "application/octet-stream", sha: f.sha, bytes: f.bytes, adresse: f.address, skipped: f.skipped,
    });
  }
  return entries;
}

const NOT_SENT = "pas encore envoyé par l'app : ouvre Polymestre sur le téléphone (il envoie les fichiers à l'ouverture), puis réessaie.";

function unavailableReason(data: any, entry: FileEntry): string {
  if (entry.skipped) return entry.skipped;
  return data.sharing?.files === false ? "l'envoi des fichiers est désactivé dans Polymestre (Profil › Assistant IA › Fichiers et notes)." : NOT_SENT;
}

function describeFile(entry: FileEntry, stored: Map<string, number> | null, data: any) {
  const available = entry.text !== undefined || (!!entry.sha && !!stored?.has(entry.sha));
  const bytes = entry.text !== undefined ? new TextEncoder().encode(entry.text).length : (stored?.get(entry.sha ?? "") || entry.bytes);
  return {
    id: entry.id, cours: entry.cours, type: entry.type, titre: entry.titre, serie: entry.serie, nom: entry.nom,
    taille: bytes ? `${Math.max(1, Math.round(bytes / 1024))} ko` : undefined,
    disponible: available,
    raison: available ? undefined : unavailableReason(data, entry),
    adresse: entry.adresse || undefined,
  };
}

function listFiles(data: any, stored: Map<string, number>, args: any) {
  const filter = args.course ? findCourse(data, args.course) : null;
  if (args.course && !filter) throw new UserError(`Cours « ${args.course} » introuvable.`);
  const files = fileIndex(data)
    .filter((e) => !filter || e.courseId === filter.id)
    .filter((e) => !args.type || e.type === args.type)
    .filter((e) => !Number.isFinite(args.series) || e.serie === args.series)
    .map((e) => describeFile(e, stored, data));
  return {
    total: files.length,
    disponibles: files.filter((f) => f.disponible).length,
    avis: !files.length && data.sharing?.files === false
      ? "L'envoi des fichiers et des notes est désactivé : Polymestre (Profil › Assistant IA › Fichiers et notes) l'active."
      : undefined,
    fichiers: files,
  };
}

// Le stockage est la seule source de vérité de ce qui est arrivé : pas de table
// à garder en phase. L'app ne se range pas dans la base pour un fichier.

async function storage(path: string, init: RequestInit = {}): Promise<Response> {
  return await fetch(`${SUPABASE_URL}/storage/v1/${path}`, {
    ...init,
    headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}`, ...(init.headers ?? {}) },
  });
}

/// SHA-256 → taille de ce que le serveur garde pour ce jeton.
async function storedFiles(hash: string): Promise<Map<string, number>> {
  const found = new Map<string, number>();
  for (let offset = 0; ; offset += 1000) {
    const response = await storage(`object/list/${BUCKET}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ prefix: hash, limit: 1000, offset }),
    });
    if (!response.ok) throw new Error(`stockage : ${response.status} ${(await response.text()).slice(0, 200)}`);
    const page: any[] = await response.json();
    for (const item of page) if (SHA.test(item.name)) found.set(item.name, Number(item.metadata?.size ?? 0));
    if (page.length < 1000) return found;
  }
}

/// Le stockage en panne (migration pas encore appliquée, réseau) ne doit jamais
/// casser la synchronisation, la lecture des cours ni la déconnexion.
async function storedFilesOrNone(hash: string): Promise<Map<string, number>> {
  try { return await storedFiles(hash); } catch { return new Map(); }
}

async function removeStored(hash: string, shas: string[]): Promise<void> {
  for (let i = 0; i < shas.length; i += 100) {
    const response = await storage(`object/${BUCKET}`, {
      method: "DELETE",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ prefixes: shas.slice(i, i + 100).map((sha) => `${hash}/${sha}`) }),
    });
    if (!response.ok) throw new Error(`stockage : ${response.status} ${(await response.text()).slice(0, 200)}`);
  }
}

async function sha256Bytes(bytes: ArrayBuffer): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

function toBase64(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(binary);
}

const fileURI = (id: string) => `polymestre://file/${encodeURIComponent(id)}`;

/// Le contenu d'un fichier : du texte, ou les octets en base64.
async function loadFile(hash: string, data: any, id: string): Promise<{ entry: FileEntry; text?: string; base64?: string }> {
  const entry = fileIndex(data).find((e) => e.id === id);
  if (!entry) throw new UserError("Fichier inconnu : list_files donne les identifiants.");
  if (entry.text !== undefined) return { entry, text: entry.text };
  if (!entry.sha) throw new UserError(`« ${entry.titre} » n'est pas disponible : ${unavailableReason(data, entry)}`);
  const response = await storage(`object/${BUCKET}/${hash}/${entry.sha}`);
  if (response.status === 404 || response.status === 400) {
    throw new UserError(`« ${entry.titre} » n'est pas disponible : ${unavailableReason(data, entry)}`);
  }
  if (!response.ok) throw new Error(`stockage : ${response.status}`);
  const bytes = new Uint8Array(await response.arrayBuffer());
  if (bytes.length > MAX_FILE) throw new UserError(`« ${entry.titre} » pèse ${Math.round(bytes.length / 1048576)} Mo : trop pour une réponse MCP (10 Mo au plus).`);
  return { entry, base64: toBase64(bytes) };
}

async function readFileTool(hash: string, data: any, args: any) {
  const { entry, text, base64 } = await loadFile(hash, data, String(args.id ?? ""));
  if (text !== undefined) return { content: [{ type: "text", text }] };
  const note = { type: "text", text: `${entry.titre} (${entry.mime}, ${Math.round((base64!.length * 3) / 4 / 1024)} ko)` };
  if (entry.mime.startsWith("image/")) return { content: [note, { type: "image", data: base64, mimeType: entry.mime }] };
  return { content: [note, { type: "resource", resource: { uri: fileURI(entry.id), mimeType: entry.mime, blob: base64 } }] };
}

async function listResources(hash: string) {
  const link = await getLink(hash);
  if (!link?.snapshot) return [];
  const stored = await storedFilesOrNone(hash);
  return fileIndex(link.snapshot)
    .filter((e) => e.text !== undefined || (e.sha && stored.has(e.sha)))
    .slice(0, 500)
    .map((e) => ({ uri: fileURI(e.id), name: e.nom, title: `${e.cours} · ${e.titre}`, mimeType: e.mime }));
}

async function readResource(hash: string, uri: unknown) {
  const link = await getLink(hash);
  if (!link?.snapshot) throw new UserError("Aucune donnée pour l'instant.");
  // `studytrack://file/` : une adresse donnée avant le changement de nom.
  const prefix = ["polymestre://file/", "studytrack://file/"].find((p) => typeof uri === "string" && uri.startsWith(p));
  if (typeof uri !== "string" || !prefix) throw new UserError("Ressource inconnue.");
  const { entry, text, base64 } = await loadFile(hash, link.snapshot, decodeURIComponent(uri.slice(prefix.length)));
  return { contents: [text !== undefined ? { uri, mimeType: entry.mime, text } : { uri, mimeType: entry.mime, blob: base64 }] };
}

// ─────────────────────────────────────────────────────── Écritures ────

class UserError extends Error {}

function resolveExercise(data: any, args: any): { course: any; exercise: any } {
  if (args.exercise_id) {
    for (const c of data.courses ?? []) {
      for (const s of c.series ?? []) {
        const e = (s.exercises ?? []).find((x: any) => x.id === args.exercise_id);
        if (e) return { course: c, exercise: e };
      }
    }
    throw new UserError("Exercice introuvable : appelle get_course pour les identifiants.");
  }
  const c = findCourse(data, args.course);
  if (!c) throw new UserError(`Cours « ${args.course ?? ""} » introuvable.`);
  const number = String(args.exercise ?? "").replace(/^exercice\s*/i, "").trim();
  for (const s of c.series ?? []) {
    const e = (s.exercises ?? []).find((x: any) => x.number === number);
    if (e) return { course: c, exercise: e };
  }
  throw new UserError(`Exercice « ${number} » introuvable dans ${c.code}.`);
}

function resolveTheory(data: any, args: any): { course: any; item: any } {
  if (args.theory_id) {
    for (const c of data.courses ?? []) {
      const t = (c.theory ?? []).find((x: any) => x.id === args.theory_id);
      if (t) return { course: c, item: t };
    }
    throw new UserError("Élément de théorie introuvable.");
  }
  const c = findCourse(data, args.course);
  if (!c) throw new UserError(`Cours « ${args.course ?? ""} » introuvable.`);
  const t = (c.theory ?? []).find((x: any) => x.number === String(args.theory ?? "").trim());
  if (!t) throw new UserError(`Théorie « ${args.theory ?? ""} » introuvable dans ${c.code}.`);
  return { course: c, item: t };
}

/// Recalcule l'étape affichée d'un exercice modifié dans l'instantané.
function restage(e: any) {
  if (e.redo) e.stage = "à refaire";
  else if (e.corrected && e.correctness) e.stage = ({ correct: "juste", partial: "moyen", wrong: "faux" } as any)[e.correctness];
  else if (e.done) e.stage = "à corriger";
  else {
    const done = (e.questions ?? []).filter((q: any) => q.done).length;
    e.stage = done ? `${done}/${e.questions.length}` : "à faire";
  }
}


/// Valide, traduit en commande pour l'app, et met l'instantané à jour.
function prepareWrite(name: string, args: any, data: any): { kind: string; payload: Record<string, unknown>; summary: string } {
  switch (name) {
    case "update_exercise": {
      const { course: c, exercise: e } = resolveExercise(data, args);
      if (args.correctness && !["correct", "partial", "wrong"].includes(args.correctness)) throw new UserError("correctness : correct, partial ou wrong.");
      const payload: Record<string, unknown> = { exerciseId: e.id, courseId: c.id };
      for (const key of ["done", "correctness", "redo", "note"]) if (args[key] !== undefined) payload[key] = args[key];
      if (Object.keys(payload).length === 2) throw new UserError("Rien à modifier : done, correctness, redo ou note.");
      if (args.done !== undefined) {
        e.done = !!args.done;
        (e.questions ?? []).forEach((q: any) => (q.done = e.done));
        if (!e.done) { delete e.correctness; e.corrected = false; }
      }
      if (args.correctness) { e.done = true; e.corrected = true; e.correctness = args.correctness; if (args.correctness === "wrong") e.redo = true; if (args.correctness === "correct") e.redo = false; }
      if (args.redo !== undefined) e.redo = !!args.redo;
      if (args.note !== undefined) e.correctionNote = args.note;
      restage(e);
      return { kind: "update_exercise", payload, summary: `${c.code} ${e.number} → ${e.stage}` };
    }
    case "check_questions": {
      const { course: c, exercise: e } = resolveExercise(data, args);
      const done = args.done !== false;
      const wanted = new Set((args.questions ?? []).map((q: string) => fold(q).replace(/[().: ]/g, "")));
      const questions = e.questions ?? [];
      const targets = wanted.size ? questions.filter((q: any) => wanted.has(fold(q.path).replace(/[().: ]/g, "")) || wanted.has(fold(q.path.split(".").pop()))) : questions;
      if (questions.length && !targets.length) throw new UserError(`Questions de ${e.number} : ${questions.map((q: any) => q.path).join(", ")}.`);
      targets.forEach((q: any) => (q.done = done));
      if (questions.length) e.done = questions.every((q: any) => q.done); else e.done = done;
      restage(e);
      return { kind: "check_questions", payload: { exerciseId: e.id, courseId: c.id, questions: args.questions ?? [], done }, summary: `${c.code} ${e.number} → ${e.stage}` };
    }
    case "update_theory": {
      const { course: c, item: t } = resolveTheory(data, args);
      const payload: Record<string, unknown> = { theoryId: t.id, courseId: c.id };
      if (args.watched !== undefined) { payload.watched = !!args.watched; t.watched = !!args.watched; }
      if (args.summary !== undefined) { payload.summary = String(args.summary); t.summary = args.summary; t.summarized = !!args.summary; if (args.summary) t.watched = true; }
      if (Object.keys(payload).length === 2) throw new UserError("Rien à modifier : watched ou summary.");
      return { kind: "update_theory", payload, summary: `${c.code} ${t.number} → ${t.watched ? "vu" : "pas vu"}` };
    }
    case "log_study_session": {
      const minutes = Number(args.minutes);
      if (!(minutes > 0 && minutes <= 960)) throw new UserError("minutes : entre 1 et 960.");
      const c = args.course ? findCourse(data, args.course) : null;
      if (args.course && !c) throw new UserError(`Cours « ${args.course} » introuvable.`);
      const payload: Record<string, unknown> = { type: args.type ?? "other", minutes };
      if (c) { payload.courseId = c.id; payload.course = c.code; }
      if (args.started_at) { if (isNaN(Date.parse(args.started_at))) throw new UserError("started_at : ISO 8601."); payload.startedAt = new Date(args.started_at).toISOString(); }
      if (args.exercise) payload.exercise = String(args.exercise);
      if (args.theory) payload.theory = String(args.theory);
      if (args.note) payload.note = String(args.note);
      data.sessions = [{ taskType: payload.type, startedAt: payload.startedAt ?? new Date(Date.now() - minutes * 60000).toISOString(), durationSeconds: Math.round(minutes * 60), course: c?.code, manual: true }, ...(data.sessions ?? [])];
      return { kind: "log_session", payload, summary: `${Math.round(minutes)} min${c ? " sur " + c.code : ""}` };
    }
    case "add_series": {
      const c = findCourse(data, args.course);
      if (!c) throw new UserError(`Cours « ${args.course ?? ""} » introuvable.`);
      const number = Number(args.number);
      if (!(number > 0)) throw new UserError("number : numéro de série.");
      const exercises = (args.exercises ?? []).map((x: any) => ({
        number: String(x.number), title: x.title, statement: x.statement, bonus: !!x.bonus,
        questions: (x.questions ?? []).map(String),
      }));
      const label = String(args.label ?? "").trim().toLowerCase();
      const existing = (c.series ?? []).find((s: any) => s.number === number && String(s.label ?? "") === label);
      if (!existing) {
        c.series = [...(c.series ?? []), {
          id: `en-attente-${crypto.randomUUID()}`, number, label, title: args.title ?? `Série ${number}${label}`, plannedWeek: args.week ?? c.currentWeek, complete: false,
          exercises: exercises.map((x: any) => ({ id: `en-attente-${crypto.randomUUID()}`, number: x.number, title: x.title ?? "", statement: x.statement, bonus: x.bonus, done: false, corrected: false, redo: false, stage: "à faire", questions: x.questions.map((q: string) => ({ path: q, label: q, text: "", done: false })) })),
        }];
      }
      return {
        kind: "add_series",
        payload: { courseId: c.id, number, label, week: args.week, title: args.title, exercises },
        summary: `${c.code} série ${number}${label} (${exercises.length} exercices)`,
      };
    }
    case "add_exam": {
      const c = findCourse(data, args.course);
      if (!c) throw new UserError(`Cours « ${args.course ?? ""} » introuvable.`);
      if (isNaN(Date.parse(args.date))) throw new UserError("date : ISO 8601.");
      const date = String(args.date);
      c.exams = [...(c.exams ?? []), { id: "en-attente", title: args.title ?? args.kind ?? "Examen", date, kind: args.kind ?? "exam", location: args.location, past: false }];
      return {
        kind: "add_exam",
        payload: { courseId: c.id, title: args.title, date, examKind: args.kind, location: args.location },
        summary: `${c.code} ${args.title ?? args.kind ?? "examen"} le ${date.slice(0, 10)}`,
      };
    }
  }
  throw new UserError(`Outil inconnu : ${name}`);
}

// ───────────────────────────────────────────────────────── MCP ────

function textResult(value: unknown, isError = false) {
  const text = typeof value === "string" ? value : JSON.stringify(value, (_, v) => (v === null ? undefined : v), 2);
  return { content: [{ type: "text", text }], ...(isError ? { isError: true } : {}) };
}

async function callTool(hash: string, name: string, args: any): Promise<unknown> {
  const link = await getLink(hash);
  if (name === "list_pending_changes") {
    const rows: Command[] = await db(`assistant_commands?token_hash=eq.${hash}&select=id,kind,status,result,summary,created_at,applied_at&order=created_at.desc&limit=30`);
    return textResult({
      enAttente: rows.filter((r) => r.status === "pending").map((r) => ({ quoi: r.summary ?? r.kind, depuis: r.created_at })),
      recentes: rows.filter((r) => r.status !== "pending").slice(0, 15).map((r) => ({ quoi: r.summary ?? r.kind, statut: r.status === "applied" ? "appliqué" : "échoué", detail: r.result, le: r.applied_at })),
    });
  }
  if (!link?.snapshot) {
    return textResult("Aucune donnée pour l'instant : ouvre Polymestre sur le téléphone (Profil › Assistant IA) pour synchroniser, puis réessaie.", true);
  }
  const data = link.snapshot;
  try {
    switch (name) {
      case "get_overview": return textResult(overview(data, link.snapshot_at));
      case "list_courses": {
        const filter = args.course ? findCourse(data, args.course) : null;
        return textResult((data.courses ?? []).filter((c: any) => !filter || c.id === filter.id).map(courseProgress));
      }
      case "get_course": return textResult(getCourse(data, args));
      case "what_to_do": return textResult(whatToDo(data, args));
      case "search": return textResult(search(data, args));
      case "upcoming_dates": return textResult(upcomingDates(data, args));
      case "study_time": return textResult(studyTime(data, args));
      case "list_files": return textResult(listFiles(data, await storedFilesOrNone(hash), args));
      case "read_file": return await readFileTool(hash, data, args);
    }
    const write = prepareWrite(name, args, data);
    await db("assistant_commands", {
      method: "POST",
      headers: { Prefer: "return=minimal" },
      body: JSON.stringify({ token_hash: hash, kind: write.kind, payload: write.payload, summary: write.summary }),
    });
    await saveSnapshot(hash, data, false);
    return textResult(`Enregistré : ${write.summary}. Polymestre l'appliquera à sa prochaine ouverture (généralement dans la minute si l'app est ouverte) ; la lecture en tient déjà compte.`);
  } catch (error) {
    if (error instanceof UserError) return textResult(error.message, true);
    throw error;
  }
}

async function handleRPC(hash: string, message: any): Promise<unknown | null> {
  const { id, method, params } = message ?? {};
  const reply = (result: unknown) => ({ jsonrpc: "2.0", id, result });
  const fail = (code: number, text: string) => ({ jsonrpc: "2.0", id: id ?? null, error: { code, message: text } });
  if (id === undefined || id === null) return null; // notification
  switch (method) {
    case "initialize": {
      const asked = params?.protocolVersion;
      return reply({
        protocolVersion: PROTOCOLS.includes(asked) ? asked : PROTOCOLS[0],
        capabilities: { tools: { listChanged: false }, resources: { listChanged: false, subscribe: false } },
        serverInfo: SERVER_INFO,
        instructions: INSTRUCTIONS,
      });
    }
    case "ping": return reply({});
    case "tools/list": return reply({ tools: TOOLS });
    case "resources/list": return reply({ resources: await listResources(hash) });
    case "resources/templates/list": return reply({ resourceTemplates: [] });
    case "resources/read": {
      try {
        return reply(await readResource(hash, params?.uri));
      } catch (error) {
        return fail(error instanceof UserError ? -32002 : -32603, (error as Error).message);
      }
    }
    case "prompts/list": return reply({ prompts: [] });
    case "tools/call": {
      const name = params?.name;
      if (!TOOLS.some((t) => t.name === name)) return fail(-32602, `Outil inconnu : ${name}`);
      try {
        return reply(await callTool(hash, name, params?.arguments ?? {}));
      } catch (error) {
        return reply(textResult(`Erreur du serveur : ${(error as Error).message}`, true));
      }
    }
    default: return fail(-32601, `Méthode inconnue : ${method}`);
  }
}

// ──────────────────────────────────────────────────── Synchronisation ────

/// L'app envoie son instantané et ses comptes rendus, reçoit les commandes.
async function sync(hash: string, body: any): Promise<Response> {
  if (body?.snapshot) {
    if (!["polymestre.assistant", "studytrack.assistant"].includes(body.snapshot.format)) return json({ error: "instantané invalide" }, 400);
    await saveSnapshot(hash, body.snapshot);
  }
  for (const result of body?.results ?? []) {
    if (typeof result?.id !== "string" || !/^[0-9a-f-]{36}$/.test(result.id)) continue;
    await db(`assistant_commands?id=eq.${result.id}&token_hash=eq.${hash}`, {
      method: "PATCH",
      headers: { Prefer: "return=minimal" },
      body: JSON.stringify({
        status: result.status === "applied" ? "applied" : "failed",
        result: String(result.message ?? "").slice(0, 500),
        applied_at: new Date().toISOString(),
      }),
    });
  }
  const pending: Command[] = await db(`assistant_commands?token_hash=eq.${hash}&status=eq.pending&select=id,kind,payload&order=created_at.asc&limit=100`);
  const reply: Record<string, unknown> = { commands: pending.map((c) => ({ id: c.id, kind: c.kind, payload: c.payload })) };
  if (body?.snapshot) {
    // Les fichiers annoncés par l'app, comparés à ceux qui sont arrivés : on
    // lui demande ce qui manque, et on efface ce qu'elle n'annonce plus (le
    // réglage coupé, un cours retiré, un PDF révisé).
    const list = Array.isArray(body.snapshot.files) ? body.snapshot.files : [];
    const announced = new Set<string>(list.map((f: any) => f?.sha).filter((sha: unknown) => typeof sha === "string" && SHA.test(sha)));
    try {
      const stored = await storedFiles(hash);
      const stale = [...stored.keys()].filter((sha) => !announced.has(sha));
      if (stale.length) await removeStored(hash, stale);
      reply.wantedFiles = [...announced].filter((sha) => !stored.has(sha)).slice(0, 25);
    } catch {
      reply.wantedFiles = [];
    }
  }
  return json(reply);
}

/// L'app dépose un fichier qu'elle a annoncé dans son instantané. Rien d'autre
/// n'est accepté : un jeton ne sert pas d'espace de stockage libre.
async function receiveFile(hash: string, sha: string, request: Request): Promise<Response> {
  if (!SHA.test(sha)) return json({ error: "empreinte invalide" }, 400);
  const rows = await db(`assistant_links?token_hash=eq.${hash}&select=files:snapshot->files`);
  const announced = (rows?.[0]?.files ?? []).some((f: any) => f?.sha === sha);
  if (!announced) return json({ error: "fichier non annoncé : synchronise d'abord" }, 404);
  const bytes = await request.arrayBuffer();
  if (bytes.byteLength === 0 || bytes.byteLength > MAX_FILE) return json({ error: "taille refusée (10 Mo au plus)" }, 413);
  if (await sha256Bytes(bytes) !== sha) return json({ error: "empreinte différente du contenu" }, 400);
  const response = await storage(`object/${BUCKET}/${hash}/${sha}`, {
    method: "POST",
    headers: { "Content-Type": "application/octet-stream", "x-upsert": "true" },
    body: bytes,
  });
  if (!response.ok) throw new Error(`stockage : ${response.status} ${(await response.text()).slice(0, 200)}`);
  return json({ ok: true });
}

// ───────────────────────────────────────────────────────── HTTP ────

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, OPTIONS",
  "Access-Control-Allow-Headers": "authorization, content-type, mcp-protocol-version, mcp-session-id, apikey, x-client-info",
};

function json(value: unknown, status = 200, extra: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(value), { status, headers: { ...CORS, "Content-Type": "application/json", ...extra } });
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
  const url = new URL(request.url);
  const parts = url.pathname.split("/").filter(Boolean);
  const at = parts.lastIndexOf("mcp");
  const rest = at >= 0 ? parts.slice(at + 1) : parts;
  const bearer = request.headers.get("authorization")?.replace(/^Bearer\s+/i, "") ?? "";
  const token = rest[0] ?? bearer;
  const action = rest[1] ?? "";

  if (!/^[A-Za-z0-9_-]{32,128}$/.test(token)) {
    return json({ error: "Adresse incomplète : copie l'adresse complète depuis Polymestre (Profil › Assistant IA)." }, 401);
  }
  const hash = await sha256(token);

  try {
    if (action === "sync" && request.method === "POST") {
      const text = await request.text();
      if (text.length > MAX_BODY) return json({ error: "instantané trop volumineux" }, 413);
      return await sync(hash, JSON.parse(text || "{}"));
    }
    if (action === "files" && request.method === "PUT") return await receiveFile(hash, rest[2] ?? "", request);
    if (!action && request.method === "DELETE") {
      // Déconnecter l'assistant efface tout ce que le serveur gardait — les
      // fichiers aussi : la cascade de la base n'atteint pas le stockage.
      await removeStored(hash, [...(await storedFilesOrNone(hash)).keys()]).catch(() => {});
      await db(`assistant_links?token_hash=eq.${hash}`, { method: "DELETE", headers: { Prefer: "return=minimal" } });
      return new Response(null, { status: 204, headers: CORS });
    }
    if (!action && request.method === "GET") {
      // Pas de flux SSE : chaque réponse arrive dans la réponse HTTP.
      return json({ error: "Ce serveur MCP répond en POST (Streamable HTTP)." }, 405, { Allow: "POST, DELETE" });
    }
    if (!action && request.method === "POST") {
      const text = await request.text();
      if (text.length > MAX_BODY) return json({ error: "requête trop volumineuse" }, 413);
      let message: any;
      try { message = JSON.parse(text); } catch { return json({ jsonrpc: "2.0", id: null, error: { code: -32700, message: "JSON illisible" } }, 400); }
      if (Array.isArray(message)) {
        const replies = (await Promise.all(message.map((m) => handleRPC(hash, m)))).filter(Boolean);
        return replies.length ? json(replies) : new Response(null, { status: 202, headers: CORS });
      }
      const reply = await handleRPC(hash, message);
      return reply ? json(reply) : new Response(null, { status: 202, headers: CORS });
    }
    return json({ error: "introuvable" }, 404);
  } catch (error) {
    return json({ error: (error as Error).message }, 500);
  }
});
