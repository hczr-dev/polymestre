// Ce qui manquait aux groupes de Windows pour être ceux de l'iPhone :
//   • l'entraide **chiffrée de bout en bout** (GroupEncryption.swift) : mon identité X25519 publiée
//     (`member_keys`), la clé du groupe créée par le premier membre (`group_key_epochs`), reçue
//     scellée pour moi (`group_key_shares`) et scellée à mon tour pour les membres qui ne l'ont
//     pas encore ; les messages scellés AES-GCM (`group_posts.ciphertext`) — jamais de texte en clair ;
//   • la **session ensemble** (GroupSessionService.swift) : une horloge commune sur le serveur
//     (`group_sessions.clock`, JSON de Swift : dates en secondes depuis 2001), suivie par mon chrono ;
//   • les **sessions prévues** (`planned_sessions`) ;
//   • l'**avancement** série par série et par matière (`item_completion`, `series_completion`),
//     que je publie aussi (seulement les matières du groupe).
// Les identités et clés de groupe restent au coffre de Windows (`polymestre.groups.keys`).

import { syncService } from "./syncService.ts";
import { SupabaseError, type SupabaseClient } from "./supabase.ts";
import { appStorage } from "../native/secrets.ts";
import { GroupCrypto, type Identity } from "../domain/groupCrypto.ts";
import { GroupClock, decodeFocusTimerState, type GroupSessionLink } from "../domain/focusTimerState.ts";
import { swiftJSON } from "./timerLinkClient.ts";
import { timerController } from "../ui/timerController.ts";
import type { Course } from "../models/index.ts";

/* eslint-disable @typescript-eslint/no-explicit-any */

async function client(): Promise<{ api: SupabaseClient; me: string }> {
  const api = syncService.supabase;
  if (!api) throw new Error("Ce build n'a pas de serveur.");
  const me = await api.userId();
  if (!me) throw new Error("Connecte-toi d'abord (Réglages › Comptes).");
  return { api, me: me.toLowerCase() };
}

// MARK: - Coffre des clés

const VAULT = "polymestre.groups.keys";
interface Vault { identities: Record<string, { priv: string; pub: string }>; groups: Record<string, Record<string, string>> }

function readVault(): Vault {
  try {
    const parsed = JSON.parse(appStorage.getItem(VAULT) ?? "") as Vault;
    return { identities: parsed.identities ?? {}, groups: parsed.groups ?? {} };
  } catch {
    return { identities: {}, groups: {} };
  }
}
function writeVault(vault: Vault): void { appStorage.setItem(VAULT, JSON.stringify(vault)); }

async function identity(userID: string): Promise<Identity> {
  const vault = readVault();
  const saved = vault.identities[userID];
  if (saved) {
    const priv = GroupCrypto.decodeKey(saved.priv);
    const pub = GroupCrypto.publicKey(saved.pub);
    if (priv && pub) return { privateKey: priv, publicKey: pub };
  }
  const fresh = await GroupCrypto.newIdentity();
  vault.identities[userID] = { priv: GroupCrypto.encode(fresh.privateKey), pub: GroupCrypto.publicKeyString(fresh.publicKey) };
  writeVault(vault);
  return fresh;
}

function savedGroupKey(groupID: string, keyID: string): Uint8Array | null {
  const text = readVault().groups[groupID]?.[keyID];
  return text ? GroupCrypto.decodeKey(text) : null;
}

async function saveGroupKey(groupID: string, key: Uint8Array): Promise<string> {
  const id = await GroupCrypto.keyID(key);
  const vault = readVault();
  vault.groups[groupID] = { ...(vault.groups[groupID] ?? {}), [id]: GroupCrypto.encode(key) };
  writeVault(vault);
  return id;
}

// MARK: - Chiffrement de l'entraide

export type EncryptionState = "ready" | "waitingForKey" | "unavailable";

const active = new Map<string, { id: string; key: Uint8Array }>();
const lastDistribution = new Map<string, number>();
let publishedFor: string | null = null;

async function publishIdentity(api: SupabaseClient, me: string, mine: Identity): Promise<void> {
  if (publishedFor === me) return;
  await api.request("/rest/v1/member_keys?on_conflict=user_id,public_key", {
    method: "POST", body: [{ user_id: me, public_key: GroupCrypto.publicKeyString(mine.publicKey) }],
    prefer: "resolution=ignore-duplicates,return=minimal",
  });
  publishedFor = me;
}

async function fetchEpoch(api: SupabaseClient, groupID: string): Promise<string | null> {
  const rows = await api.request<any[]>(`/rest/v1/group_key_epochs?group_id=eq.${groupID}&select=key_id`);
  return rows?.[0]?.key_id ?? null;
}

/** Prépare la clé d'un groupe sur ce PC (la crée, la reçoit, la transmet aux nouveaux). */
export async function prepareEncryption(rawGroupID: string, forceDistribution = false): Promise<EncryptionState> {
  const groupID = rawGroupID.toLowerCase();
  try {
    const { api, me } = await client();
    const mine = await identity(me);
    await publishIdentity(api, me, mine);
    let epoch = await fetchEpoch(api, groupID);
    if (!epoch) {
      // Aucun membre n'a encore créé de clé : je la crée (le premier arrivé l'emporte).
      const fresh = GroupCrypto.newGroupKey();
      const freshID = await saveGroupKey(groupID, fresh);
      await api.request("/rest/v1/group_key_epochs?on_conflict=group_id", {
        method: "POST", body: [{ group_id: groupID, key_id: freshID, created_by: me }], prefer: "resolution=ignore-duplicates,return=minimal",
      });
      epoch = await fetchEpoch(api, groupID);
    }
    if (!epoch) return "waitingForKey";
    if (active.get(groupID)?.id !== epoch) {
      const stored = savedGroupKey(groupID, epoch);
      if (stored) active.set(groupID, { id: epoch, key: stored });
      else {
        const received = await openShare(api, groupID, epoch, mine);
        if (received) { await saveGroupKey(groupID, received); active.set(groupID, { id: epoch, key: received }); }
      }
    }
    const current = active.get(groupID);
    if (!current) return "waitingForKey";
    const last = lastDistribution.get(groupID) ?? 0;
    if (forceDistribution || Date.now() - last > 120_000) {
      await distribute(api, me, groupID, current, mine);
      lastDistribution.set(groupID, Date.now());
    }
    return "ready";
  } catch (error) {
    if (error instanceof SupabaseError && (error.status === 404 || /PGRST205|42P01/.test(error.message))) return "unavailable";
    return active.has(groupID) ? "ready" : "waitingForKey";
  }
}

async function openShare(api: SupabaseClient, groupID: string, keyID: string, mine: Identity): Promise<Uint8Array | null> {
  const recipient = encodeURIComponent(GroupCrypto.publicKeyString(mine.publicKey));
  const rows = await api.request<any[]>(`/rest/v1/group_key_shares?group_id=eq.${groupID}&key_id=eq.${keyID}&recipient_key=eq.${recipient}&select=sender_key,sealed`);
  for (const row of rows ?? []) {
    const sender = GroupCrypto.publicKey(row.sender_key ?? "");
    if (!sender || typeof row.sealed !== "string") continue;
    try {
      const key = await GroupCrypto.unwrap(row.sealed, mine.privateKey, sender, groupID);
      if (await GroupCrypto.keyID(key) === keyID) return key;
    } catch { /* enveloppe d'un autre */ }
  }
  return null;
}

async function distribute(api: SupabaseClient, me: string, groupID: string, current: { id: string; key: Uint8Array }, mine: Identity): Promise<void> {
  const memberRows = await api.request<any[]>(`/rest/v1/group_members?group_id=eq.${groupID}&select=user_id`);
  const members = new Set((memberRows ?? []).map((row) => String(row.user_id).toLowerCase()));
  if (members.size === 0) return;
  const keyRows = await api.request<any[]>(`/rest/v1/member_keys?user_id=in.(${[...members].sort().join(",")})&select=user_id,public_key`);
  const published = (keyRows ?? []).map((row) => ({ userID: String(row.user_id).toLowerCase(), key: String(row.public_key) }));
  const servedRows = await api.request<any[]>(`/rest/v1/group_key_shares?group_id=eq.${groupID}&key_id=eq.${current.id}&select=recipient_key`);
  const served = new Set((servedRows ?? []).map((row) => String(row.recipient_key)));
  const missing = GroupCrypto.missingRecipients(members, published, served);
  if (missing.length === 0) return;
  const senderKey = GroupCrypto.publicKeyString(mine.publicKey);
  const rows = [];
  for (const entry of missing) {
    const recipient = GroupCrypto.publicKey(entry.key);
    if (!recipient) continue;
    rows.push({
      group_id: groupID, key_id: current.id, recipient_id: entry.userID, recipient_key: entry.key,
      sender_id: me, sender_key: senderKey, sealed: await GroupCrypto.wrap(current.key, mine.privateKey, recipient, groupID),
    });
  }
  if (rows.length > 0) {
    await api.request("/rest/v1/group_key_shares?on_conflict=group_id,key_id,recipient_key", { method: "POST", body: rows, prefer: "resolution=ignore-duplicates,return=minimal" });
  }
}

export interface Post {
  id: string; authorID: string; authorName: string; parentID: string | null; courseCode: string;
  seriesNumber: number | null; exerciseNumber: string; body: string; resolved: boolean; createdAt: Date; locked: boolean;
}

/** « CS-250 · Série 3 · Ex. 2 » : sur quoi porte une question. */
export function postTarget(post: Post): string {
  return [post.courseCode || null, post.seriesNumber !== null ? `Série ${post.seriesNumber}` : null, post.exerciseNumber ? `Ex. ${post.exerciseNumber}` : null]
    .filter(Boolean).join(" · ");
}

async function decrypt(raw: any, groupID: string): Promise<Post> {
  const post: Post = {
    id: raw.id, authorID: String(raw.author_id).toLowerCase(), authorName: raw.author_name ?? "Membre", parentID: raw.parent_id ?? null,
    courseCode: raw.course_code ?? "", seriesNumber: raw.series_number ?? null, exerciseNumber: raw.exercise_number ?? "",
    body: raw.body ?? "", resolved: raw.resolved === true, createdAt: new Date(raw.created_at), locked: false,
  };
  if (typeof raw.ciphertext !== "string") return post;
  const key = active.get(groupID);
  if (key && (!raw.key_id || raw.key_id === key.id)) {
    try { post.body = await GroupCrypto.open(raw.ciphertext, key.key, groupID, post.authorID); return post; } catch { /* clé d'avant */ }
  }
  post.body = "Message chiffré — la clé du groupe n'est pas encore arrivée sur ce PC.";
  post.locked = true;
  return post;
}

export async function fetchPosts(rawGroupID: string): Promise<Post[]> {
  const groupID = rawGroupID.toLowerCase();
  const { api } = await client();
  const rows = await api.request<any[]>(`/rest/v1/group_posts?group_id=eq.${groupID}&select=*&order=created_at.desc&limit=60`);
  if ((rows ?? []).some((row) => row.ciphertext) && !active.has(groupID)) await prepareEncryption(groupID);
  return Promise.all((rows ?? []).map((row) => decrypt(row, groupID)));
}

/** Une question (ou une réponse) — jamais envoyée en clair : sans clé, on n'envoie pas. */
export async function createPost(rawGroupID: string, authorName: string, body: string,
  options: { parentID?: string; courseCode?: string; seriesNumber?: number | null; exerciseNumber?: string } = {}): Promise<Post> {
  const groupID = rawGroupID.toLowerCase();
  const { api, me } = await client();
  if (!active.has(groupID)) await prepareEncryption(groupID);
  const key = active.get(groupID);
  if (!key) throw new Error("La clé du groupe n'est pas encore arrivée : elle arrive dès qu'un membre ouvre l'app.");
  const payload: Record<string, unknown> = {
    group_id: groupID, author_id: me, author_name: authorName, kind: options.parentID ? "reply" : "help",
    course_code: options.courseCode ?? "", exercise_number: options.exerciseNumber ?? "", body: "",
    ciphertext: await GroupCrypto.seal(body, key.key, groupID, me), key_id: key.id,
  };
  if (options.parentID) payload.parent_id = options.parentID;
  if (options.seriesNumber != null) payload.series_number = options.seriesNumber;
  const rows = await api.request<any[]>("/rest/v1/group_posts", { method: "POST", body: payload, prefer: "return=representation" });
  if (!rows?.[0]) throw new Error("Le serveur n'a pas gardé le message.");
  return decrypt(rows[0], groupID);
}

export async function setPostResolved(postID: string, resolved: boolean): Promise<void> {
  const { api } = await client();
  await api.request(`/rest/v1/group_posts?id=eq.${postID}`, { method: "PATCH", body: { resolved }, prefer: "return=minimal" });
}

// MARK: - Session ensemble

export interface LiveSession { id: string; groupID: string; hostID: string; updatedBy: string; clock: GroupClock; present: { userID: string; name: string }[] }

function clockFromJSON(raw: unknown): GroupClock | null {
  if (!raw || typeof raw !== "object") return null;
  const state = decodeFocusTimerState(JSON.stringify({ ...(raw as object), taskTypeRaw: "other", note: "", contextLabel: "" }));
  return state ? GroupClock.from(state) : null;
}
const clockToJSON = (clock: GroupClock): unknown => JSON.parse(swiftJSON(clock));

function toSession(row: any): LiveSession | null {
  const clock = clockFromJSON(row.clock);
  if (!clock) return null;
  return {
    id: row.id, groupID: row.group_id, hostID: String(row.host_id).toLowerCase(), updatedBy: String(row.updated_by ?? "").toLowerCase(), clock,
    present: (row.group_session_members ?? []).filter((m: any) => m.left_at == null)
      .map((m: any) => ({ userID: String(m.user_id).toLowerCase(), name: m.profiles?.display_name ?? "Membre" })),
  };
}

export async function fetchLiveSession(groupID: string): Promise<LiveSession | null> {
  const { api } = await client();
  const rows = await api.request<any[]>(`/rest/v1/group_sessions?group_id=eq.${groupID}&ended_at=is.null&select=*,group_session_members(user_id,joined_at,left_at,profiles(display_name))`);
  return rows?.[0] ? toSession(rows[0]) : null;
}

async function joinSessionRow(api: SupabaseClient, me: string, sessionID: string, groupID: string): Promise<void> {
  await api.request("/rest/v1/group_session_members?on_conflict=session_id,user_id", {
    method: "POST", body: [{ session_id: sessionID, group_id: groupID, user_id: me, joined_at: new Date().toISOString(), left_at: null }],
    prefer: "resolution=merge-duplicates,return=minimal",
  });
}

async function updateSession(id: string, clock: GroupClock | null, ended = false): Promise<void> {
  const { api, me } = await client();
  const values: Record<string, unknown> = { updated_by: me, updated_at: new Date().toISOString() };
  if (clock) values.clock = clockToJSON(clock);
  if (ended) values.ended_at = new Date().toISOString();
  await api.request(`/rest/v1/group_sessions?id=eq.${id}`, { method: "PATCH", body: values, prefer: "return=minimal" });
}

async function leaveSession(sessionID: string): Promise<void> {
  const { api, me } = await client();
  await api.request(`/rest/v1/group_session_members?session_id=eq.${sessionID}&user_id=eq.${me}`, { method: "PATCH", body: { left_at: new Date().toISOString() }, prefer: "return=minimal" });
}

/**
 * Mon chrono lié à une session de groupe : mes gestes partent au groupe, les siens arrivent
 * (relus toutes les 10 s **seulement** tant que le chrono y est lié), la fin ferme la session.
 */
class GroupSessions {
  private lastPushed: string | null = null;
  private applying = false;
  private watching: ReturnType<typeof setInterval> | null = null;
  private previous = timerController.snapshot().state;
  private started = false;

  /** Branché une fois (au lancement). */
  start(): void {
    if (this.started) return;
    this.started = true;
    timerController.subscribe(() => this.changed());
    if (this.previous?.groupSession) this.watch();
  }

  async startSession(groupID: string, groupName: string): Promise<void> {
    const { api, me } = await client();
    const snapshot = timerController.snapshot();
    if (!snapshot.state) timerController.start();
    const state = timerController.snapshot().state;
    if (!state) return;
    const clock = GroupClock.from(state);
    let session: LiveSession | null = null;
    try {
      const rows = await api.request<any[]>("/rest/v1/group_sessions", {
        method: "POST", prefer: "return=representation", body: { group_id: groupID, host_id: me, updated_by: me, clock: clockToJSON(clock) },
      });
      session = rows?.[0] ? toSession(rows[0]) : null;
      if (session) await joinSessionRow(api, me, session.id, groupID);
    } catch (error) {
      // Une session est déjà ouverte dans ce groupe : on la rejoint.
      if (!(error instanceof SupabaseError) || !/23505|duplicate/i.test(error.message)) throw error;
    }
    const live = await fetchLiveSession(groupID);
    if (!live) throw new Error("La session n'a pas pu démarrer.");
    const link: GroupSessionLink = { sessionID: live.id, groupID, groupName };
    if (session && live.id === session.id && live.hostID === me) {
      this.applying = true;
      timerController.hostGroupSession(link);
      this.applying = false;
      this.lastPushed = JSON.stringify(clockToJSON(clock));
      this.watch();
    } else {
      await this.join(live, groupName);
    }
  }

  async join(session: LiveSession, groupName: string): Promise<void> {
    const { api, me } = await client();
    await joinSessionRow(api, me, session.id, session.groupID);
    this.applying = true;
    await timerController.joinGroupSession({ sessionID: session.id, groupID: session.groupID, groupName }, session.clock);
    this.applying = false;
    this.lastPushed = JSON.stringify(clockToJSON(session.clock));
    this.previous = timerController.snapshot().state;
    this.watch();
  }

  async endForEveryone(session: LiveSession): Promise<void> {
    await updateSession(session.id, null, true);
  }

  private watch(): void {
    if (this.watching) return;
    this.watching = setInterval(() => { void this.poll(); }, 10_000);
  }

  private unwatch(): void {
    if (this.watching) clearInterval(this.watching);
    this.watching = null;
  }

  private async poll(): Promise<void> {
    const link = timerController.snapshot().state?.groupSession;
    if (!link) { this.unwatch(); return; }
    let session: LiveSession | null = null;
    try { session = await fetchLiveSession(link.groupID); } catch { return; }
    this.applying = true;
    try {
      if (!session || session.id !== link.sessionID) {
        // La session est finie : chacun enregistre son temps (sauf sous verrou : on se détache).
        if (timerController.isLocked) timerController.detachGroup(); else await timerController.finish();
        this.unwatch();
        return;
      }
      const { me } = await client();
      const text = JSON.stringify(clockToJSON(session.clock));
      if (session.updatedBy !== me && text !== this.lastPushed) {
        this.lastPushed = text;
        timerController.applyGroupClock(session.clock);
      }
    } finally {
      this.applying = false;
      this.previous = timerController.snapshot().state;
    }
  }

  private changed(): void {
    const state = timerController.snapshot().state;
    const before = this.previous;
    if (state === before) return;
    this.previous = state;
    if (this.applying) return;
    if (before?.groupSession && (!state || state.groupSession?.sessionID !== before.groupSession.sessionID)) {
      const link = before.groupSession;
      this.unwatch();
      void (async () => {
        try {
          await leaveSession(link.sessionID);
          const live = await fetchLiveSession(link.groupID);
          if (live && live.id === link.sessionID && live.present.length === 0) await updateSession(live.id, null, true);
        } catch { /* hors ligne */ }
      })();
      return;
    }
    if (!state?.groupSession) return;
    const clock = GroupClock.from(state);
    const text = JSON.stringify(clockToJSON(clock));
    if (text === this.lastPushed) return;
    this.lastPushed = text;
    void updateSession(state.groupSession.sessionID, clock).catch(() => {});
  }
}

export const groupSessions = new GroupSessions();

// MARK: - Sessions prévues

export interface PlannedGroupSession { id: string; courseCode: string; title: string; startsAt: Date; durationMinutes: number; location: string }

export async function fetchPlanned(groupID: string): Promise<PlannedGroupSession[]> {
  const { api } = await client();
  const rows = await api.request<any[]>(`/rest/v1/planned_sessions?group_id=eq.${groupID}&select=*&order=starts_at.asc`);
  return (rows ?? []).map((row) => ({
    id: row.id, courseCode: row.course_code ?? "", title: row.title ?? "Session d'étude", startsAt: new Date(row.starts_at),
    durationMinutes: row.duration_minutes ?? 60, location: row.location ?? "",
  })).filter((session) => session.startsAt.getTime() + session.durationMinutes * 60_000 > Date.now());
}

export async function createPlanned(groupID: string, session: Omit<PlannedGroupSession, "id">): Promise<void> {
  const { api, me } = await client();
  await api.request("/rest/v1/planned_sessions", {
    method: "POST", prefer: "return=minimal",
    body: { group_id: groupID, course_code: session.courseCode, title: session.title, starts_at: session.startsAt.toISOString(),
      duration_minutes: session.durationMinutes, location: session.location, created_by: me },
  });
}

// MARK: - Avancement

export interface Completions { items: { userID: string; courseCode: string; kind: string; number: string }[]; series: { userID: string; courseCode: string; seriesNumber: number }[] }

export async function fetchCompletions(groupID: string): Promise<Completions> {
  const { api } = await client();
  const [items, series] = await Promise.all([
    api.request<any[]>(`/rest/v1/item_completion?group_id=eq.${groupID}&select=*`),
    api.request<any[]>(`/rest/v1/series_completion?group_id=eq.${groupID}&select=*`),
  ]);
  return {
    items: (items ?? []).map((r) => ({ userID: String(r.user_id).toLowerCase(), courseCode: String(r.course_code).toUpperCase(), kind: r.item_kind, number: String(r.item_number) })),
    series: (series ?? []).map((r) => ({ userID: String(r.user_id).toLowerCase(), courseCode: String(r.course_code).toUpperCase(), seriesNumber: Number(r.series_number) })),
  };
}

/** Publie mon avancement — seulement sur les matières du groupe (rien d'autre ne sort). */
export async function pushMyProgress(groupID: string, subjects: string[], courses: Course[]): Promise<void> {
  const { api, me } = await client();
  const wanted = new Set(subjects.map((code) => code.toUpperCase()));
  const scoped = courses.filter((course) => wanted.size === 0 || wanted.has(course.code.toUpperCase()));
  const items = scoped.flatMap((course) => [
    ...course.allExercises.filter((exercise) => exercise.isDone)
      .map((exercise) => ({ group_id: groupID, user_id: me, course_code: course.code, item_kind: "exercise", item_number: exercise.groupNumber })),
    ...course.theoryItems.filter((item) => item.isWatched)
      .map((item) => ({ group_id: groupID, user_id: me, course_code: course.code, item_kind: "theory", item_number: item.number })),
  ]);
  // « Série 5 terminée » ne dit pas laquelle de 5a et 5b : une série étiquetée ne se
  // partage qu'exercice par exercice.
  const series = scoped.flatMap((course) => course.sortedSeries.filter((s) => s.isComplete && s.label === "")
    .map((s) => ({ group_id: groupID, user_id: me, course_code: course.code, series_number: s.seriesNumber })));
  if (items.length > 0) await api.request("/rest/v1/item_completion?on_conflict=group_id,user_id,course_code,item_kind,item_number", { method: "POST", body: items, prefer: "resolution=ignore-duplicates,return=minimal" });
  if (series.length > 0) await api.request("/rest/v1/series_completion?on_conflict=group_id,user_id,course_code,series_number", { method: "POST", body: series, prefer: "resolution=ignore-duplicates,return=minimal" });
}

export interface SeriesBoard { seriesNumber: number; label: string; displayName: string; exercises: string[]; rows: { userID: string; name: string; isMe: boolean; done: Set<string>; complete: boolean }[] }

/** Série par série (GroupSeriesEngine) : qui a fait quels exercices obligatoires, d'après mon cours. */
export function seriesBoards(course: Course, completions: Completions, members: { userID: string; displayName: string }[], me: string): SeriesBoard[] {
  const code = course.code.toUpperCase();
  return course.sortedSeries.map((series) => {
    const exercises = series.sortedExercises.filter((exercise) => !exercise.isBonus).map((exercise) => exercise.groupNumber);
    const rows = members.map((member) => {
      const id = member.userID.toLowerCase();
      const done = new Set(completions.items.filter((i) => i.userID === id && i.courseCode === code && i.kind === "exercise" && exercises.includes(i.number)).map((i) => i.number));
      const complete = series.label === "" && completions.series.some((s) => s.userID === id && s.courseCode === code && s.seriesNumber === series.seriesNumber);
      return { userID: id, name: member.displayName, isMe: id === me.toLowerCase(), done, complete };
    }).sort((a, b) => (b.complete ? exercises.length : b.done.size) - (a.complete ? exercises.length : a.done.size) || Number(b.isMe) - Number(a.isMe));
    return { seriesNumber: series.seriesNumber, label: series.label, displayName: series.displayName, exercises, rows };
  }).filter((board) => board.exercises.length > 0);
}

/** Par matière (GroupProgressEngine) : séries, exercices et théorie faits, et l'écart avec moi. */
export function subjectRows(code: string, completions: Completions, members: { userID: string; displayName: string }[], me: string) {
  const upper = code.toUpperCase();
  const rows = members.map((member) => {
    const id = member.userID.toLowerCase();
    const items = completions.items.filter((i) => i.userID === id && i.courseCode === upper);
    return {
      userID: id, name: member.displayName, isMe: id === me.toLowerCase(),
      series: completions.series.filter((s) => s.userID === id && s.courseCode === upper).length,
      exercises: items.filter((i) => i.kind === "exercise").length,
      theory: items.filter((i) => i.kind === "theory").length,
    };
  });
  const mine = rows.find((row) => row.isMe);
  return rows.map((row) => ({ ...row, gap: mine ? row.exercises - mine.exercises : 0 }))
    .sort((a, b) => b.series + b.exercises + b.theory - (a.series + a.exercises + a.theory) || Number(b.isMe) - Number(a.isMe));
}

export async function myUserID(): Promise<string | null> {
  try { return (await client()).me; } catch { return null; }
}
