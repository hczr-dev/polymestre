// Supabase Edge Function : extraction des séries d'exercices par un LLM.
//
// Pourquoi ici et pas dans l'app : la clé du fournisseur (Groq, OpenRouter,
// Mistral, OpenAI…) reste **côté serveur**. L'étudiant·e n'a rien à saisir —
// l'app appelle cette fonction avec la clé `anon` déjà compilée, et le texte du
// PDF ne transite que vers le fournisseur choisi ici.
//
// Déploiement (une fois, par le mainteneur du projet Supabase) :
//
//   cd <racine du dépôt>            # la CLI cherche supabase/functions/<nom>/index.ts
//   supabase functions deploy extract-series
//   supabase secrets set LLM_API_KEY=gsk_…                       # clé du fournisseur
//
// Facultatifs — mais **les deux ensemble** : le modèle par défaut n'existe que chez
// Groq, et l'envoyer ailleurs donne un « model_not_found » obscur.
//
//   supabase secrets set LLM_BASE_URL=https://openrouter.ai/api/v1
//   supabase secrets set LLM_MODEL=meta-llama/llama-3.1-8b-instruct:free
//
// Mode vision (pages envoyées en image, `{"images":[base64…]}`) : le modèle par
// défaut chez Groq est `qwen/qwen3.8-27b` (`llama-4-scout` n'y est plus). Ailleurs :
//
//   supabase secrets set LLM_VISION_MODEL=google/gemini-2.5-flash
//
// La vision peut aussi passer par **un autre fournisseur** que le texte :
//
//   supabase secrets set LLM_VISION_BASE_URL=https://generativelanguage.googleapis.com/v1beta/openai
//   supabase secrets set LLM_VISION_API_KEY=<clé Google AI Studio>
//   supabase secrets set LLM_VISION_MODEL=gemini-2.5-flash
//
// Repli **OpenRouter** quand c'est trop long : si aucun modèle n'a répondu après
// OPENROUTER_AFTER_MS (10 s par défaut) — ou dès que tous ont échoué —,
// DeepSeek v4.1 Flash rejoint la course, et le premier qui répond gagne.
//
//   supabase secrets set OPENROUTER_API_KEY=sk-or-…
//   supabase secrets set OPENROUTER_MODEL=deepseek/deepseek-v4.1-flash   # défaut
//   supabase secrets set OPENROUTER_AFTER_MS=10000                       # défaut
//
// Groq offre un palier gratuit largement suffisant pour des PDF de séries.
// N'importe quelle API compatible OpenAI convient (OpenRouter : LLM_BASE_URL=
// https://openrouter.ai/api/v1 et un modèle « :free »).

// Consigne **courte**, et ce n'est pas un détail : le palier gratuit de Groq
// plafonne à 8 000 jetons par minute. Une consigne bavarde consommait à elle seule
// la moitié du quota, et chaque import se soldait par une erreur 429.
//
// Les questions ne portent que leur **étiquette** (« 1 », « 2 », « a »), jamais
// leur énoncé. Recopier des formules mathématiques dans une chaîne JSON produisait
// régulièrement du JSON invalide — guillemets et sauts de ligne non échappés — et
// la réponse entière était perdue. L'étiquette suffit : l'énoncé est dans le PDF.
const INSTRUCTIONS = `Tu extrais la structure d'une série d'exercices depuis le texte brut d'un PDF.
Réponds UNIQUEMENT par un objet JSON :
{"series":[{"number":2,"title":"Sommes","exercises":[{"number":"2.1","title":"Comparer des bornes","isBonus":false,"questions":["1","2"]}]}]}

- Langue : les titres dans la langue du PDF (« [Langue du document : …] » la donne). Ne traduis JAMAIS : un PDF anglais donne des titres anglais, même si cette consigne est en français.
- « exercises » = les EXERCICES, jamais les questions. Un exercice = un numéro du polycopié.
- Format du texte : « # » en début de ligne marque un TITRE du PDF (plus gros ou en gras) ; les espaces de tête reproduisent le RETRAIT réel ; « --- page N --- » sépare les pages ; « [Indice : … série N] » donne le numéro de série lu dans l'en-tête ou le nom du fichier — utilise-le. Une ligne d'en-tête répétée à chaque page n'est pas un exercice.
- Numéros : recopie le numéro IMPRIMÉ de chaque exercice (« Ex-04-07 » → « 4.7 », « 3. Banked turn » → « 4.3 » dans la série 4). Ne renumérote pas, ne saute aucun exercice, et ne promeus jamais une question (« 1. Find … », décalée) en exercice.
- L'INDENTATION est le signal principal. Des numéros alignés au même niveau sont des EXERCICES, même sous un titre de section commun. Des numéros **décalés vers la droite** sous un numéro d'exercice sont ses QUESTIONS.
- Exemple : un numéro qui se termine par « … telle que : » puis, plus à droite, « 1. … ; 2. … » → cet exercice, avec deux questions. Les numéros voisins, alignés à gauche, restent des exercices.
- Autre cas : « Calculer : » puis « 1. la somme … ; 2. la somme … » au même niveau → UN exercice dont ces numéros sont les questions, parce qu'ils suivent une introduction terminée par deux points et se présentent comme des fragments.
- « questions » ne contient que les étiquettes, en texte court : « 1 », « 2 », « a », « ii ». Jamais l'énoncé, jamais de formule. Omets « questions » s'il n'y en a qu'une.
- « number » de série est un entier ; « label » distingue deux séries de même numéro, sinon "" (« Série 02a » → number 2, label "a" ; « Série 5 — mardi » → label "mardi"). Numéro d'exercice : « série.exercice », même si le PDF recommence à 1 dans chaque section. Un exercice sans numéro imprimé (« Exercice » seul, ou un intitulé seul) prend le suivant dans l'ordre du document. N'invente aucun exercice.
- « title » toujours rempli, et **court** : 2 à 6 mots, jamais une phrase, jamais le nom du cours. Si le PDF imprime un intitulé à côté du numéro (« 3. Banked turn »), recopie-le TEL QUEL, sans le traduire ni le reformuler. Sinon nomme la tâche toi-même, à partir du titre de section ou de l'objet (« Comparer des bornes supérieures », « Somme des parties entières »). **Ne recopie jamais l'énoncé** : il commence par un verbe à l'infinitif ou à l'impératif et se termine par un point, ce n'est pas un titre.
- « isBonus » : true si bonus, facultatif, optionnel ou étoilé.
- Aucune série : {"series":[]}.`;

// Consigne du mode **vision** : le modèle voit les pages rendues en image.
//
// Le texte d'un PDF LaTeX est inutilisable pour les sous-questions : « ≤ » et
// « ⩾ » disparaissent, les fractions éclatent sur trois lignes, les indices
// réordonnent les lignes, et deux colonnes de questions se mélangent. L'image,
// elle, montre la structure telle qu'on la lit. Chaque règle ci-dessous vient
// d'un cas réel (Analyse I, série 03).
const VISION_INSTRUCTIONS = `Tu lis des pages d'une série d'exercices (images) et tu en extrais la STRUCTURE.
Réponds UNIQUEMENT par un objet JSON :
{"series":[{"number":3,"title":"Suites","exercises":[{"number":"3.1","title":"Ensembles d'indices","statement":"Lire sur les graphes de (x_n) et (y_n) des ensembles d'indices et un rang N","isBonus":false,"page":1,"parts":[{"label":"1","kind":"question","text":"Suite (x_n) du graphe","children":[{"label":"a","kind":"question","text":"A = {n : x_n < 0}"}]}]},{"number":"3.2","title":"Monotonie d'une suite homographique","statement":"Montrer que x_n = \\\\frac{an+b}{cn+d} est croissante ⇔ ad − bc ≥ 0","isBonus":false,"page":2}]}]}

Règles :
- LANGUE : écris « title », « statement » et « text » dans la langue des pages. Ne traduis JAMAIS — une page anglaise donne des champs anglais, même si cette consigne est en français.
- « exercises » = les EXERCICES (Ex-03-01, Exercice 2, « 3. Banked turn » en gras…). « number » = « série.exercice », avec le numéro IMPRIMÉ : ne renumérote pas, ne saute rien, et une question numérotée « 1. » sous un exercice n'est jamais un exercice. Un exercice SANS numéro imprimé (titré « Exercice » seul, ou par son seul intitulé en gras) prend le numéro suivant dans l'ordre des pages.
- Série : « number » entier ; « label » ce qui distingue deux séries de même numéro, sinon "" (« Série 5b » → number 5, label "b" ; « Série 5 — mardi » → label "mardi").
- « parts » = le travail à cocher dans l'exercice, sur DEUX niveaux au plus : une question numérotée « 1) » avec ses points « (a) (b) » dans « children ».
- Deux colonnes (« 1) … 3) » sur une ligne, « 2) … 4) » sur la suivante) : range par numéro, 1, 2, 3, 4.
- Plusieurs questions sur une même ligne (« 1) … 2) … 3) ») : ce sont des questions séparées.
- Une consigne à faire AVANT la liste et séparée d'elle (« Calculer lim aₙ. Ensuite, calculer : 1) 2) 3) ») → une partie {"label":null,"kind":"part","text":"…"} en tête.
- Une consigne APRÈS la liste (« Ensuite, pour la suite … donner … ») → une partie {"label":null,"kind":"part"} en fin.
- Une liste de CONDITIONS ou d'hypothèses (« satisfait les conditions suivantes : 1) … 2) … ») n'est PAS du travail : pas de « parts ».
- Des questions en liste à PUCES (•, –, ◦) sans étiquette : ce sont des questions, « label » "1", "2", "3" dans l'ordre ; des puces sous une question numérotée sont ses points « children » ("a", "b"). Une liste de conditions en puces n'est pas du travail.
- Un exercice sans question numérotée ni à puces : omets « parts ».
- « text » : court (≤ 80 caractères), dans la langue du PDF. N'invente rien.
- Formules (dans « text » et « statement ») : LaTeX léger SANS $ : indices « x_n », « a_{2k+1} », exposants « n^2 », fractions « \\frac{an+b}{cn+d} », racines « \\sqrt{n^2+2} », « \\lim_{n \\to \\infty} », et les symboles en Unicode (≤ ≥ ≠ ∈ ∞ ℕ ℝ ε ℓ ⇔). Dans le JSON, chaque barre oblique inverse est doublée (« \\\\frac »).
- « title » : l'intitulé imprimé à côté du numéro, recopié TEL QUEL s'il existe ; sinon 2 à 6 mots qui nomment la tâche, jamais l'énoncé recopié.
- « statement » : TOUJOURS rempli, ≤ 140 caractères : ce que l'exercice demande de faire (en français : verbe à l'infinitif ; en anglais : à l'impératif), avec les objets mathématiques essentiels (« Montrer que x_n = \\frac{an+b}{cn+d} est croissante ⇔ ad − bc ≥ 0 »). C'est la seule description d'un exercice sans questions : ne le laisse jamais vide.
- Si un « Texte extrait » est fourni, sers-t'en pour les numéros et le vocabulaire exacts ; ses formules sont souvent abîmées (symboles ≤ ≥ perdus, fractions éclatées) : pour les formules, fie-toi à l'image.
- « page » : la page (1, 2, …) où l'exercice commence, dans l'ordre des images reçues.
- « isBonus » : true si bonus, facultatif, optionnel ou étoilé.
- Aucune série : {"series":[]}.`;

/** Groq accepte 5 images par requête : au-delà, on découpe. */
const MAX_IMAGES_PER_CALL = 5;
const MAX_PAGES = 20;

import { allowed, isEvaluation } from "../_shared/limits.ts";
import { recordUsage } from "../_shared/usage.ts";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const MAX_CHARACTERS = 6000;

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: CORS });
  }
  if (request.method !== "POST") {
    return json({ error: "POST attendu" }, 405);
  }
  // La clé `anon` est publique : un plafond par adresse et par jour.
  const evaluation = isEvaluation(request);
  if (!evaluation) {
    const gate = await allowed(request, { name: "extract-series", perInstallPerHour: 120, globalPerDay: 4000 });
    if (!gate.ok) return json({ error: gate.reason }, 429);
  }

  const apiKey = Deno.env.get("LLM_API_KEY");
  if (!apiKey) {
    return json({ error: "LLM_API_KEY manquante : `supabase secrets set LLM_API_KEY=…`" }, 503);
  }

  const GROQ = GROQ_URL;
  const configured = Deno.env.get("LLM_BASE_URL")?.trim();
  const baseURL = (configured && configured.length > 0 ? configured : GROQ).replace(/\/$/, "");
  const usesGroq = baseURL === GROQ;

  // Le modèle par défaut est un modèle **Groq**. L'envoyer à un autre fournisseur
  // donne « The model … does not exist or you do not have access to it » — un
  // message exact mais qui ne dit pas qu'il vient d'un défaut mal placé.
  const configuredModel = Deno.env.get("LLM_MODEL")?.trim();
  if (!configuredModel && !usesGroq) {
    return json({
      error: "LLM_MODEL manquant : un fournisseur autre que Groq a besoin de son propre nom de modèle. "
        + "`supabase secrets set LLM_MODEL=<modèle>` — la liste est sur la page « Models » du fournisseur. "
        + `Fournisseur actuel : ${baseURL}`,
    }, 503);
  }
  // `llama-3.1-8b-instant` est passé en offre **Enterprise** chez Groq : une clé
  // gratuite n'y a plus accès. Le défaut est donc un modèle ouvert à tous.
  const model = configuredModel || "openai/gpt-oss-20b";

  let text = "";
  let images: string[] = [];
  let seriesHint: number | null = null;
  let language: string | null = null;
  let listOnly = false;
  /** Diagnostic : `"only": "backup"` n'interroge que le repli OpenRouter. */
  let onlyBackup = false;
  let evalModel: string | null = null;
  try {
    const body = await request.json();
    text = typeof body?.text === "string" ? body.text : "";
    images = Array.isArray(body?.images)
      ? body.images.filter((image: unknown) => typeof image === "string" && image.length > 0)
      : [];
    seriesHint = typeof body?.seriesHint === "number" ? body.seriesHint : null;
    // Un nom de langue court (« anglais »), jamais un texte libre injecté tel quel.
    language = typeof body?.language === "string" && /^[\p{L} ]{2,20}$/u.test(body.language.trim())
      ? body.language.trim() : null;
    listOnly = body?.listModels === true;
    onlyBackup = body?.only === "backup";
    evalModel = evaluation && typeof body?.model === "string" ? body.model : null;
  } catch {
    return json({ error: "corps JSON attendu : {\"text\": …} ou {\"images\": [...]}" }, 400);
  }
  text = text.slice(0, MAX_CHARACTERS).trim();

  // Évaluation (jeton secret) : un seul modèle OpenRouter lit les pages, sans
  // course ni repli — pour comparer les modèles sur de vrais énoncés.
  if (evalModel && images.length > 0) {
    const key = Deno.env.get("OPENROUTER_API_KEY")?.trim();
    if (!key) return json({ error: "OPENROUTER_API_KEY manquante" }, 503);
    const pages = images.slice(0, MAX_PAGES);
    const started = Date.now();
    const outcome = await readWith({ base: OPENROUTER_URL, key, model: evalModel }, pages, 0, pages.length,
                                   seriesHint, language, text, new AbortController().signal);
    return json({ ...outcome, ms: Date.now() - started });
  }

  // ── Diagnostic : les modèles que les clés peuvent utiliser (identifiants
  // seulement, jamais de secret). Sert à choisir LLM_VISION_MODEL.
  if (listOnly) {
    const visionBase = (Deno.env.get("LLM_VISION_BASE_URL")?.trim() || baseURL).replace(/\/$/, "");
    const visionKey = Deno.env.get("LLM_VISION_API_KEY")?.trim() || apiKey;
    return json({
      text: { baseURL, model, models: await listModels(baseURL, apiKey) },
      vision: { baseURL: visionBase, model: Deno.env.get("LLM_VISION_MODEL")?.trim() ?? null,
                models: await listModels(visionBase, visionKey) },
    });
  }

  // ── Mode vision : les pages en image, découpées par paquets. ──────────────
  if (images.length > 0) {
    // La vision peut avoir **son propre fournisseur** : le texte reste sur un
    // palier gratuit (Groq), les pages vont à un modèle qui les lit vraiment
    // bien (Gemini, Claude, GPT-4.1 — toute API compatible OpenAI).
    const visionBase = (Deno.env.get("LLM_VISION_BASE_URL")?.trim() || baseURL).replace(/\/$/, "");
    const visionKey = Deno.env.get("LLM_VISION_API_KEY")?.trim() || apiKey;
    const explicitVisionModel = Deno.env.get("LLM_VISION_MODEL")?.trim();
    if (!explicitVisionModel && Deno.env.get("LLM_VISION_BASE_URL")?.trim() && visionBase !== GROQ) {
      return json({ error: "LLM_VISION_BASE_URL est posé sans LLM_VISION_MODEL : "
        + "`supabase secrets set LLM_VISION_MODEL=<modèle de ce fournisseur>`." }, 503);
    }

    // La chaîne de secours. Un modèle servi est parfois **saturé** (Gemini :
    // « high demand », 503) ou **sans quota** (429) : ce n'est pas une raison
    // de rendre la main. On essaie, dans l'ordre : le modèle choisi, les autres
    // modèles de vision récents du même fournisseur, puis Qwen chez Groq.
    const candidates: Candidate[] = [];
    const add = (candidate: Candidate) => {
      if (!candidates.some((c) => c.base === candidate.base && c.model === candidate.model)) candidates.push(candidate);
    };
    // Le modèle retenu au banc d'essai (SERIES_VISION_MODEL, chez OpenRouter)
    // passe devant : le meilleur lecteur d'énoncés, et ~8 fois moins cher que
    // Gemini Flash au tarif payant. Les modèles du fournisseur de vision restent
    // en secours.
    const preferredVision = Deno.env.get("SERIES_VISION_MODEL")?.trim();
    const openRouterKey = Deno.env.get("OPENROUTER_API_KEY")?.trim();
    if (preferredVision && openRouterKey) add({ base: OPENROUTER_URL, key: openRouterKey, model: preferredVision });
    add({ base: visionBase, key: visionKey,
          model: explicitVisionModel || (visionBase === GROQ ? GROQ_VISION : configuredModel!) });
    const available = await listModels(visionBase, visionKey);
    for (const model of pickVisionModels(available)) add({ base: visionBase, key: visionKey, model });
    if (usesGroq) add({ base: GROQ, key: apiKey, model: GROQ_VISION });

    const pages = images.slice(0, MAX_PAGES);
    const backup = openRouterCandidate();
    const failures: string[] = [];
    const timings: string[] = [];
    const began = Date.now();

    // Le modèle qui a répondu la dernière fois passe devant ; ceux qui viennent
    // d'être saturés (503) ou sans quota (429) attendent leur tour.
    const ordered = rankCandidates(candidates);

    // Un paquet de pages, lu par **plusieurs** modèles en même temps : le premier
    // qui répond gagne, les autres sont annulés. Chaque modèle Gemini a son propre
    // quota gratuit : la course ne coûte rien, et le temps devient celui du plus
    // rapide des modèles disponibles. Attendre qu'un modèle saturé réponde 503,
    // puis le suivant, puis le suivant, coûtait l'essentiel des 45 s.
    const readPrimary = async (first: number, count: number, outer: AbortSignal): Promise<Outcome & { model?: string }> => {
      let index = 0;
      while (index < ordered.length) {
        if (outer.aborted) return { error: "annulé" };
        const pair = ordered.slice(index, index + raceWidth());
        index += pair.length;
        const controllers = pair.map(() => new AbortController());
        const stop = () => controllers.forEach((controller) => controller.abort());
        outer.addEventListener("abort", stop, { once: true });
        const attempts = pair.map((candidate, slot) => (async () => {
          // Les modèles « Lite » lisent moins bien (conditions prises pour des
          // questions, consigne d'ouverture oubliée) : ils partent après les
          // modèles complets, et seulement si aucun n'a encore répondu.
          if (/lite/i.test(candidate.model) && pair.some((other) => !/lite/i.test(other.model))) {
            await new Promise((resolve) => setTimeout(resolve, LITE_HEAD_START_MS));
            if (controllers[slot].signal.aborted) throw new Error("annulé");
          }
          const start = Date.now();
          const outcome = await readWith(candidate, pages, first, count, seriesHint, language, text, controllers[slot].signal);
          const ms = Date.now() - start;
          if ("error" in outcome) {
            if (!controllers[slot].signal.aborted) {
              failures.push(`${candidate.model} (${ms} ms) : ${outcome.error.slice(0, 140)}`);
              markUnhealthy(candidate, outcome.error);
            }
            throw new Error(outcome.error);
          }
          timings.push(`${candidate.model} : ${ms} ms`);
          markHealthy(candidate);
          controllers.forEach((controller, other) => { if (other !== slot) controller.abort(); });
          return { ...outcome, model: candidate.model };
        })());
        try {
          return await Promise.any(attempts);
        } catch {
          // Tous ont échoué : groupe suivant.
        } finally {
          outer.removeEventListener("abort", stop);
        }
      }
      return { error: "aucun modèle de vision n'a répondu" };
    };

    // Le repli OpenRouter entre dans la course si la chaîne principale traîne.
    const readChunk = (first: number, count: number) =>
      raceWithBackup(
        (signal) => onlyBackup && backup
          ? Promise.resolve({ error: "chaîne principale sautée (diagnostic)" })
          : readPrimary(first, count, signal),
        backup ? (signal) => readWith(backup, pages, first, count, seriesHint, language, text, signal) : null,
        backup?.model ?? "",
        failures,
        timings,
      );

    // Les paquets partent **ensemble** (un PDF de dix pages = deux paquets).
    const starts: number[] = [];
    for (let start = 0; start < pages.length; start += MAX_IMAGES_PER_CALL) starts.push(start);
    const results = await Promise.all(starts.map((start) =>
      readChunk(start, Math.min(MAX_IMAGES_PER_CALL, pages.length - start))));
    const failed = results.find((result) => "error" in result);
    if (failed && "error" in failed) {
      return json({ error: `vision : ${failed.error}. Essais : ${failures.join(" | ")}` }, 502);
    }
    const collected = results.flatMap((result) => ("series" in result ? result.series : []));
    const usedModel = results.map((result) => result.model).find(Boolean) ?? ordered[0].model;
    return json({ series: mergeSeries(collected), model: usedModel, mode: "vision",
                  ms: Date.now() - began, timings, backup: backup?.model,
                  fallbacks: failures.length > 0 ? failures : undefined });
  }

  if (!text) {
    return json({ series: [] });
  }

  // Le rappel de langue est **répété en fin de message** : un modèle suit
  // nettement mieux une consigne placée juste avant de répondre qu'une consigne
  // noyée dans un long texte système. Sans lui, un PDF français ressortait avec
  // des titres anglais.
  //
  // La langue n'est **plus écrite en dur** : « (ici, en français) » faisait
  // traduire les séries anglaises (PHYS-101(en)). L'app la détecte et l'envoie.
  const messages = [
    { role: "system", content: INSTRUCTIONS },
    {
      role: "user",
      content: `Texte du PDF :\n\n${text}\n\n`
        + "Rappel : tous les « title » doivent être écrits dans la langue du document ci-dessus "
        + (language ? `(ici, en ${language}) ` : "")
        + "— ne traduis rien —, et chaque exercice doit en avoir un.",
    },
  ];

  // Même course qu'en vision : le fournisseur principal part seul, OpenRouter le
  // rejoint s'il traîne (un 429 de Groq fait attendre jusqu'à une minute).
  const backup = openRouterCandidate();
  const failures: string[] = [];
  const timings: string[] = [];
  const began = Date.now();
  const outcome = await raceWithBackup(
    async (signal) => {
      if (onlyBackup && backup) return { error: "chaîne principale sautée (diagnostic)" };
      const start = Date.now();
      const result = await complete(baseURL, apiKey, model, usesGroq, messages, preferredModels, 4096, signal);
      if (!("error" in result)) timings.push(`${result.model} : ${Date.now() - start} ms`);
      return result;
    },
    backup ? (signal) => complete(backup.base, backup.key, backup.model, false, messages, [], 4096, signal) : null,
    backup?.model ?? "",
    failures,
    timings,
  );
  if ("error" in outcome) {
    return json({ error: failures.length > 0 ? `${outcome.error}. Essais : ${failures.join(" | ")}` : outcome.error }, 502);
  }
  return json({ series: outcome.series, model: outcome.model, structured: outcome.structured,
                ms: Date.now() - began, timings, fallbacks: failures.length > 0 ? failures : undefined });
});

type Outcome =
  | { series: unknown[]; model: string; structured: boolean }
  | { error: string };

/**
 * Une complétion, avec ses trois replis — modèle introuvable, limite de débit,
 * garantie JSON refusée — et la lecture tolérante de la réponse.
 */
async function complete(
  baseURL: string,
  apiKey: string,
  model: string,
  usesGroq: boolean,
  messages: Array<{ role: string; content: unknown }>,
  fallbackModels: string[],
  maxTokens = 4096,
  signal?: AbortSignal,
): Promise<Outcome> {
  let usedModel = model;
  let structured = true;
  let detail = "";
  const began = Date.now();
  const attempt = async (): Promise<Response> => {
    // Bride **dès le premier essai** : `failed_generation` montrait un JSON
    // tronqué en pleine chaîne, parce que le raisonnement avait consommé le
    // budget de sortie. Seuls les modèles qui raisonnent (`gpt-oss`) acceptent
    // ce paramètre ; un modèle de vision le refuserait.
    // Gemini « réfléchit » par défaut : pour lire une feuille d'exercices,
    // c'est l'essentiel du temps d'attente, sans gain de lecture.
    const reasons = (usesGroq && usedModel.includes("gpt-oss")) || baseURL.includes("googleapis.com");
    const response = await callProvider(baseURL, apiKey, usedModel, messages,
                                        structured, reasons, maxTokens, signal);
    detail = await bodyText(response);
    return response;
  };

  // Le corps d'une `Response` ne se lit **qu'une fois** : le relire lève
  // « Body already used », que rien n'attrape, et la fonction répond alors
  // « Internal Server Error » — masquant le vrai message du fournisseur.
  // `attempt` le lit donc une fois, et le garde dans `detail`.
  let upstream = await attempt();

  // Repli 0 — un modèle qui n'existe qu'avec raisonnement (Gemini 3.6 chez
  // OpenRouter) : retenu, puis relancé avec le raisonnement le plus court.
  if (!upstream.ok && /Reasoning is mandatory/i.test(detail) && !mandatoryReasoning.has(usedModel)) {
    mandatoryReasoning.add(usedModel);
    upstream = await attempt();
  }

  // Repli 1 — le nom du modèle. C'est une donnée **extérieure** au projet : les
  // offres changent, et `llama-3.1-8b-instant` est devenu Enterprise sans que rien
  // ne bouge ici. On demande au fournisseur ce qu'il accepte, puis on réessaie.
  if (!upstream.ok && (upstream.status === 404 || detail.includes("model_not_found"))) {
    const available = await listModels(baseURL, apiKey);
    const fallback = pickModel(available, fallbackModels);
    if (fallback && fallback !== usedModel) {
      usedModel = fallback;
      upstream = await attempt();
    }
  }

  // Repli 2 — la limite de débit. Le palier gratuit plafonne par minute : un
  // import qui en suit un autre est refusé alors que tout est correct. Le
  // fournisseur dit combien de temps attendre ; on l'écoute, une fois.
  if (!upstream.ok && upstream.status === 429) {
    const wait = retryDelay(detail);
    if (wait > 0) {
      await new Promise((resolve) => setTimeout(resolve, wait));
      // Le repli a peut-être déjà répondu pendant l'attente.
      if (signal?.aborted) return { error: "annulé" };
      upstream = await attempt();
    }
  }

  // Repli 3 — la garantie JSON. Le fournisseur peut refuser de certifier la
  // sortie (`json_validate_failed`) alors que le texte contient un objet valide.
  // On retire alors la garantie : la réponse est de toute façon relue en isolant
  // le premier objet, donc rien ne dépend d'elle.
  if (!upstream.ok && (detail.includes("json_validate_failed") || detail.includes("Failed to validate JSON")
    || detail.includes("response_format"))) {
    structured = false;
    upstream = await attempt();
  }

  if (!upstream.ok) {
    // Quand le modèle n'existe pas chez ce fournisseur, on va **chercher** la
    // liste pour la donner : « model_not_found » sans les noms valides oblige à
    // ouvrir un navigateur et à deviner.
    let hint = "";
    if (upstream.status === 404 || detail.includes("model_not_found")) {
      const available = await listModels(baseURL, apiKey);
      if (available.length > 0) {
        hint = ` Modèles disponibles chez ce fournisseur : ${available.slice(0, 8).join(", ")}`
          + (available.length > 8 ? ` (et ${available.length - 8} autres)` : "")
          + ". Corrige avec `supabase secrets set LLM_MODEL=<modèle>` (ou LLM_VISION_MODEL).";
      } else {
        hint = " Vérifie `supabase secrets list`, puis pose `LLM_MODEL` avec un modèle du fournisseur.";
      }
    }
    return { error: `fournisseur : HTTP ${upstream.status} ${detail}${hint}` };
  }

  const payload = await upstream.json();
  // Ce que l'appel a coûté (jetons ; coût annoncé chez OpenRouter).
  recordUsage("extract-series", baseURL, usedModel, payload?.usage, Date.now() - began);
  const message = payload?.choices?.[0]?.message;
  // Certains modèles qui raisonnent laissent `content` vide et écrivent tout dans
  // `reasoning_content`. On regarde les deux avant de conclure à une réponse vide.
  const content = message?.content;
  const reasoning = message?.reasoning_content ?? message?.reasoning;
  const raw = typeof content === "string" && content.trim().length > 0
    ? content
    : (typeof reasoning === "string" ? reasoning : JSON.stringify(content ?? {}));

  // On renvoie l'objet demandé, jamais le texte brut : l'app relit `series`.
  const start = raw.indexOf("{");
  const end = raw.lastIndexOf("}");
  if (start < 0 || end <= start) {
    // Une réponse illisible n'est **pas** « ce PDF n'a pas de série ». Les
    // confondre laissait l'utilisateur devant une extraction vide sans savoir
    // que le modèle avait répondu autre chose — on dit donc ce qu'il a répondu.
    return {
      error: `le modèle n'a pas renvoyé de JSON (modèle ${usedModel}, mode strict ${structured}). `
        + `Début de sa réponse : ${raw.slice(0, 200) || "(vide)"}`,
    };
  }
  try {
    const parsed = JSON.parse(latexSafe(raw.slice(start, end + 1)));
    return { series: Array.isArray(parsed?.series) ? parsed.series : [], model: usedModel, structured };
  } catch (error) {
    // `finish_reason` dit **pourquoi** la réponse s'arrête : « length » signifie
    // une limite de sortie atteinte, et non un modèle qui écrit mal. Sans lui, on
    // chercherait longtemps.
    const finish = payload?.choices?.[0]?.finish_reason ?? "?";
    const usage = payload?.usage;
    return {
      error: `JSON illisible de ${usedModel} (strict ${structured}, fin « ${finish} », `
        + `usage ${JSON.stringify(usage ?? {})}) : ${String(error)}. Début : ${raw.slice(0, 200)}`,
    };
  }
}

/**
 * Les séries de plusieurs paquets de pages, réunies.
 *
 * Un exercice à cheval sur deux paquets apparaît deux fois : on garde la version
 * qui porte le plus de questions.
 */
function mergeSeries(chunks: unknown[]): unknown[] {
  type Exercise = { number?: unknown; parts?: unknown[] };
  type Series = { number?: unknown; label?: unknown; title?: unknown; exercises?: Exercise[] };
  const bySeries = new Map<string, Series>();
  for (const item of chunks as Series[]) {
    if (!item || typeof item !== "object") continue;
    // « 5a » et « 5b » lus dans deux morceaux restent deux séries.
    const key = String(item.number ?? "") + "|" + String(item.label ?? "").trim().toLowerCase();
    const existing = bySeries.get(key);
    if (!existing) {
      bySeries.set(key, { ...item, exercises: [...(item.exercises ?? [])] });
      continue;
    }
    if (!existing.title && item.title) existing.title = item.title;
    for (const exercise of item.exercises ?? []) {
      const index = (existing.exercises ?? []).findIndex((e) => String(e.number) === String(exercise.number));
      if (index < 0) {
        existing.exercises!.push(exercise);
      } else if ((exercise.parts?.length ?? 0) > (existing.exercises![index].parts?.length ?? 0)) {
        existing.exercises![index] = exercise;
      }
    }
  }
  return [...bySeries.values()];
}

type Candidate = { base: string; key: string; model: string };

const OPENROUTER_URL = "https://openrouter.ai/api/v1";
/** Rapide, lit les images, contexte d'un million de jetons. */
const OPENROUTER_DEFAULT_MODEL = "deepseek/deepseek-v4.1-flash";
/** Au-delà, la chaîne principale « traîne » : le repli démarre. */
const OPENROUTER_DEFAULT_AFTER_MS = 10_000;

/** Le repli OpenRouter, s'il est configuré. */
function openRouterCandidate(): Candidate | null {
  const key = Deno.env.get("OPENROUTER_API_KEY")?.trim();
  if (!key) return null;
  return { base: OPENROUTER_URL, key, model: Deno.env.get("OPENROUTER_MODEL")?.trim() || OPENROUTER_DEFAULT_MODEL };
}

function backupDelay(): number {
  const value = Number(Deno.env.get("OPENROUTER_AFTER_MS"));
  return Number.isFinite(value) && value >= 0 ? value : OPENROUTER_DEFAULT_AFTER_MS;
}

/**
 * La chaîne principale, doublée d'un repli qui part **en retard**.
 *
 * Le repli démarre après `backupDelay()` si rien n'est encore revenu, ou tout
 * de suite si la chaîne principale échoue. Le premier résultat gagne et annule
 * l'autre. Sans repli configuré, c'est la chaîne principale seule, comme avant.
 *
 * Pourquoi une course plutôt qu'un simple « si échec, alors » : un modèle saturé
 * n'échoue pas vite, il **fait attendre** — Gemini en « high demand », ou un 429
 * de Groq suivi d'une pause d'une minute. L'étudiant·e attendait alors une
 * minute pour rien ; ici, au bout de 10 s, un second modèle travaille déjà.
 */
async function raceWithBackup(
  primary: (signal: AbortSignal) => Promise<Outcome & { model?: string }>,
  backup: ((signal: AbortSignal) => Promise<Outcome>) | null,
  backupModel: string,
  failures: string[],
  timings: string[],
): Promise<Outcome & { model?: string }> {
  const primaryControl = new AbortController();
  if (!backup) return primary(primaryControl.signal);

  const backupControl = new AbortController();
  let release!: () => void;
  const gate = new Promise<void>((resolve) => { release = resolve; });
  const timer = setTimeout(() => release(), backupDelay());

  // Une requête annulée **lève** au lieu de rendre une erreur : on la ramène à
  // une erreur ordinaire, sinon le repli n'apprendrait jamais l'échec.
  const settle = (run: () => Promise<Outcome & { model?: string }>) =>
    run().catch((error): Outcome => ({ error: String(error) }));

  const first = settle(() => primary(primaryControl.signal)).then((outcome) => {
    if ("error" in outcome) {
      release();
      throw new Error(outcome.error);
    }
    backupControl.abort();
    return outcome;
  });

  const second = gate.then(async () => {
    if (backupControl.signal.aborted) throw new Error("annulé");
    const start = Date.now();
    const outcome = await settle(() => backup(backupControl.signal));
    const ms = Date.now() - start;
    if ("error" in outcome) {
      if (!backupControl.signal.aborted) failures.push(`${backupModel} (repli, ${ms} ms) : ${outcome.error.slice(0, 140)}`);
      throw new Error(outcome.error);
    }
    timings.push(`${backupModel} (repli) : ${ms} ms`);
    primaryControl.abort();
    return { ...outcome, model: backupModel };
  });

  try {
    return await Promise.any([first, second]);
  } catch (error) {
    const reasons = error instanceof AggregateError ? error.errors.map(String) : [String(error)];
    return { error: `aucun modèle n'a répondu (${reasons.join(" ; ").slice(0, 300)})` };
  } finally {
    clearTimeout(timer);
  }
}

const GROQ_URL = "https://api.groq.com/openai/v1";

/** Le modèle de vision de Groq (`llama-4-scout` n'y est plus). */
const GROQ_VISION = "qwen/qwen3.8-27b";

// ── Santé des modèles ─────────────────────────────────────────────────────────
//
// Gardée **en mémoire de l'instance** : une fonction Supabase reste chaude
// plusieurs minutes entre deux imports. Le modèle qui a répondu passe devant ;
// un modèle saturé ou sans quota est mis de côté deux minutes au lieu d'être
// réessayé — et attendu — à chaque import.
const COOLDOWN_MS = 2 * 60 * 1000;
/** Modèles lancés ensemble sur un même paquet de pages. */
const RACE_WIDTH = 5;
/**
 * Combien de modèles courent ensemble. 5 quand la vision est un palier gratuit
 * (Gemini : chaque modèle a son quota, la course ne coûte rien) ; 1 — les
 * modèles l'un après l'autre — dès qu'un modèle payant passe devant
 * (SERIES_VISION_MODEL), sinon chaque énoncé serait payé cinq fois.
 */
function raceWidth(): number {
  const configured = Number(Deno.env.get("SERIES_RACE_WIDTH"));
  if (Number.isFinite(configured) && configured >= 1) return configured;
  return Deno.env.get("SERIES_VISION_MODEL") ? 1 : RACE_WIDTH;
}
/** Avance donnée aux modèles complets sur les « Lite ». */
const LITE_HEAD_START_MS = 5000;
const cooldowns = new Map<string, number>();
let lastGood: string | null = null;

function keyOf(candidate: Candidate): string {
  return `${candidate.base}|${candidate.model}`;
}

function markHealthy(candidate: Candidate) {
  lastGood = keyOf(candidate);
  cooldowns.delete(keyOf(candidate));
}

function markUnhealthy(candidate: Candidate, error: string) {
  if (/HTTP (429|5\d\d)|high demand|unavailable|quota|rate limit/i.test(error)) {
    cooldowns.set(keyOf(candidate), Date.now() + COOLDOWN_MS);
  }
}

/** Le dernier modèle qui a répondu d'abord, les modèles au repos à la fin. */
function rankCandidates(candidates: Candidate[]): Candidate[] {
  const now = Date.now();
  const resting = (candidate: Candidate) => (cooldowns.get(keyOf(candidate)) ?? 0) > now;
  const good = candidates.filter((candidate) => keyOf(candidate) === lastGood);
  const ready = candidates.filter((candidate) => keyOf(candidate) !== lastGood && !resting(candidate));
  const tired = candidates.filter((candidate) => keyOf(candidate) !== lastGood && resting(candidate));
  return [...good, ...ready, ...tired];
}

/**
 * Un paquet de pages lu par un modèle. Chez Groq gratuit (7 000 jetons
 * d'entrée par minute), deux pages par appel et sans le texte d'appoint.
 */
async function readWith(candidate: Candidate, pages: string[], first: number, count: number,
                        seriesHint: number | null, language: string | null, text: string,
                        signal: AbortSignal): Promise<Outcome> {
  const onGroq = candidate.base === GROQ_URL;
  const step = onGroq ? 2 : count;
  const series: unknown[] = [];
  for (let start = first; start < first + count; start += step) {
    if (signal.aborted) return { error: "annulé" };
    const slice = pages.slice(start, Math.min(start + step, first + count));
    let outcome: Outcome;
    try {
      outcome = await complete(candidate.base, candidate.key, candidate.model, onGroq,
                               visionMessages(slice, start, seriesHint, language, onGroq ? "" : text), [], 8192, signal);
    } catch (error) {
      return { error: signal.aborted ? "annulé" : String(error) };
    }
    if ("error" in outcome) return outcome;
    series.push(...outcome.series);
  }
  return { series, model: candidate.model, structured: true };
}

/** Les messages d'un paquet de pages : consigne, repères, images. */
function visionMessages(pages: string[], first: number, seriesHint: number | null,
                        language: string | null, text: string) {
  const content: unknown[] = [{
    type: "text",
    text: `Pages ${first + 1} à ${first + pages.length} du document`
      + (seriesHint ? ` (série ${seriesHint} d'après l'en-tête ou le nom du fichier)` : "")
      + ". Numérote « page » à partir de " + (first + 1) + ". Réponds en JSON."
      + (language ? ` Le document est en ${language} : écris tous les champs en ${language}, ne traduis rien.` : "")
      + (text ? `\n\nTexte extrait du PDF (numéros fiables, formules abîmées) :\n${text}` : ""),
  }];
  for (const image of pages) {
    content.push({ type: "image_url", image_url: { url: `data:image/jpeg;base64,${image}` } });
  }
  return [{ role: "system", content: VISION_INSTRUCTIONS }, { role: "user", content }];
}

/**
 * Une erreur qui vaut la peine d'essayer le modèle suivant : saturé, sans
 * quota, inconnu, trop gros pour lui, ou qui ne lit pas les images. Une réponse
 * illisible, elle, ne s'améliorera pas ailleurs — si, en fait : on essaie aussi.
 */
function isRecoverable(error: string): boolean {
  return /HTTP (400|404|408|413|429|5\d\d)|high demand|unavailable|quota|rate limit|too large|not found|does not exist|content must be a string|image|JSON illisible|pas renvoyé de JSON/i.test(error);
}

/**
 * Les modèles de vision **récents** d'un fournisseur, du meilleur au plus léger.
 *
 * Gemini publie des dizaines d'identifiants (audio, TTS, embeddings, robotique,
 * « computer use »…) : prendre « le premier qui contient gemini » avait choisi
 * un aperçu sans quota. On ne garde que les familles qui lisent des pages.
 */
function pickVisionModels(available: string[]): string[] {
  const ids = available.map((id) => id.replace(/^models\//, ""));
  const excluded = /tts|audio|embedding|live|transcribe|robotics|computer-use|image-preview|-image$|-image-|customtools|translate|omni/i;
  const usable = ids.filter((id) => !excluded.test(id));
  const version = (id: string) => Number(id.match(/(\d+(?:\.\d+)?)/)?.[1] ?? 0);
  const flash = usable.filter((id) => /^gemini-\d+(\.\d+)?-flash$/.test(id)).sort((a, b) => version(b) - version(a));
  const pro = usable.filter((id) => /^gemini-\d+(\.\d+)?-pro$/.test(id)).sort((a, b) => version(b) - version(a));
  const lite = usable.filter((id) => /^gemini-\d+(\.\d+)?-flash-lite$/.test(id)).sort((a, b) => version(b) - version(a));
  const others = usable.filter((id) => preferredVisionModels.includes(id));
  // Premier départ : trois Flash récents et deux Flash-Lite — les Lite restent
  // disponibles quand les Flash sont saturés (« high demand »). Pro ensuite.
  return [...flash.slice(0, 3), ...lite.slice(0, 2), ...pro.slice(0, 1), ...others];
}

/** Modèles qui voient les images, du plus accessible au plus capable. */
const preferredVisionModels = [
  "qwen/qwen3.8-27b",
  "meta-llama/llama-4-scout-17b-16e-instruct",
  "meta-llama/llama-4-maverick-17b-128e-instruct",
  "google/gemini-2.5-flash",
  "gpt-4o-mini",
];

/**
 * Double la barre oblique d'une commande LaTeX laissée seule dans le JSON.
 *
 * `"\frac{a}{b}"` écrit avec **une** barre : `\f` est un saut de page pour JSON
 * (« rac{a}{b} » à l'écran), `\s` de `\sqrt` une erreur qui fait perdre toute
 * la réponse. Une barre suivie de deux lettres ou plus est une commande.
 */
function latexSafe(json: string): string {
  return json.replace(/(?<!\\)\\(?=[a-zA-Z]{2,})/g, "\\\\");
}

/** Les modèles à essayer en premier, du plus léger au plus capable. */
const preferredModels = [
  "openai/gpt-oss-20b",
  "openai/gpt-oss-120b",
  "llama-3.3-70b-versatile",
  "meta-llama/llama-4-scout-17b-16e-instruct",
  "mixtral-8x7b-32768",
];

/**
 * Le meilleur modèle **réellement disponible**, ou `null`.
 *
 * On cherche d'abord dans la liste de préférence ; à défaut, on prend le premier
 * modèle proposé — mieux vaut une réponse d'un modèle inattendu que pas de
 * réponse du tout.
 */
function pickModel(available: string[], preferred: string[]): string | null {
  // Liste vide = « pas de repli au hasard » (vision : la chaîne s'en charge).
  if (available.length === 0 || preferred.length === 0) return null;
  for (const candidate of preferred) {
    if (available.includes(candidate)) return candidate;
  }
  return available[0] ?? null;
}

/** Un appel de complétion, isolé pour pouvoir être rejoué avec un autre modèle. */
/** Les modèles qui refusent qu'on coupe leur raisonnement (appris en route). */
const mandatoryReasoning = new Set<string>();

function callProvider(
  baseURL: string,
  apiKey: string,
  model: string,
  messages: Array<{ role: string; content: unknown }>,
  structured = true,
  lowReasoning = false,
  maxTokens = 4096,
  signal?: AbortSignal,
): Promise<Response> {
  const payload: Record<string, unknown> = { model, temperature: 0, messages };
  if (structured) payload.response_format = { type: "json_object" };
  // Une limite explicite : le défaut du fournisseur peut être plus court que la
  // liste d'exercices, et un JSON tronqué est un JSON invalide.
  payload.max_completion_tokens = maxTokens;
  // Les modèles `gpt-oss` **raisonnent** avant de répondre. Sans bride, ils
  // dépensent le quota en raisonnement et rendent parfois un contenu vide : la
  // réponse existe, mais dans `reasoning_content`. « low » suffit largement pour
  // lire une liste d'exercices, et rend le quota au texte utile.
  if (lowReasoning) payload.reasoning_effort = "low";
  // OpenRouter : pas de longue réflexion (c'est un repli, il doit être rapide),
  // et le fournisseur le plus rapide du moment pour ce modèle.
  if (baseURL.includes("openrouter.ai")) {
    // Réflexion **coupée** : avec « effort: low », DeepSeek v4.1 Flash mettait
    // 72 s sur la série 3 (3 pages) — plus lent que la chaîne qu'il remplace.
    payload.reasoning = mandatoryReasoning.has(model) ? { effort: "low" } : { enabled: false };
    payload.provider = { sort: "throughput" };
    payload.usage = { include: true };
  }
  return fetch(`${baseURL}/chat/completions`, {
    signal,
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${apiKey}`,
      ...(baseURL.includes("openrouter.ai") ? { "X-Title": "Polymestre" } : {}),
    },
    body: JSON.stringify(payload),
  });
}

/**
 * Le délai conseillé par le fournisseur, en millisecondes.
 *
 * Groq écrit « Please try again in 9.96s ». On le lit plutôt que d'attendre une
 * durée fixe : trop courte, la reprise échoue ; trop longue, on fait patienter
 * pour rien. Borné à 60 s : le quota de Groq se compte par minute.
 */
function retryDelay(detail: string): number {
  const match = detail.match(/try again in ([0-9.]+)\s*s/i);
  if (!match) return detail.includes("429") ? 5_000 : 0;
  const seconds = Number(match[1]);
  if (!Number.isFinite(seconds)) return 5_000;
  return Math.min(60_000, Math.max(1_000, Math.ceil(seconds * 1000) + 500));
}

/** Le corps d'une réponse en texte, borné — sans jamais lever d'exception. */
async function bodyText(response: Response): Promise<string> {
  if (response.ok) return "";
  try {
    return (await response.text()).slice(0, 300);
  } catch {
    return "(corps illisible)";
  }
}

/** Les identifiants de modèles que la clé peut utiliser, ou une liste vide. */
async function listModels(baseURL: string, apiKey: string): Promise<string[]> {
  try {
    const response = await fetch(`${baseURL}/models`, {
      headers: { Authorization: `Bearer ${apiKey}` },
    });
    if (!response.ok) return [];
    const payload = await response.json();
    const items = Array.isArray(payload?.data) ? payload.data : [];
    return items
      .map((item: { id?: unknown }) => (typeof item?.id === "string" ? item.id : ""))
      .filter((id: string) => id.length > 0)
      .sort();
  } catch {
    return [];
  }
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}
