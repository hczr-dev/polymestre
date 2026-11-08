// Les groupes d'étude (GroupsView + GroupHubView de l'iPhone, réduits à l'essentiel) : mes
// groupes, en créer un ou en rejoindre un par son code ; dans un groupe, qui travaille en ce
// moment, le classement de la semaine, les membres et le code à partager.

import { useCallback, useEffect, useState, useSyncExternalStore } from "react";
import { Course, StudySession } from "../../models/index.ts";
import { useData } from "../../data/dataContext.tsx";
import { countsSession, readCounting } from "../../domain/studyCounting.ts";
import { DateUtils } from "../../domain/dateUtils.ts";
import { Groups, type Group, type LeaderboardRow, type Member, type Presence } from "../../services/groupsService.ts";
import { readGroupsDisplayName, refreshMyGroups, writeGroupsDisplayName } from "../groups/groupPresence.ts";
import { Button, Card, EmptyState, PageHeader, Section } from "../kit.tsx";
import { syncService } from "../../services/syncService.ts";
import { SyncAccount } from "./settings/SyncAccount.tsx";
import { Icon, type IconName } from "../icons.tsx";
import { timerController } from "../timerController.ts";
import { TaskType } from "../../models/enums.ts";
import {
  createPlanned, createPost, fetchCompletions, fetchLiveSession, fetchPlanned, fetchPosts, groupSessions, myUserID, postTarget,
  prepareEncryption, pushMyProgress, seriesBoards, setPostResolved, subjectRows,
  type Completions, type EncryptionState, type LiveSession, type PlannedGroupSession, type Post,
} from "../../services/groupFeatures.ts";

const hours = (seconds: number) => {
  const h = Math.floor(seconds / 3600);
  const m = Math.round((seconds % 3600) / 60);
  return h > 0 ? `${h} h ${String(m).padStart(2, "0")}` : `${m} min`;
};

export function GroupsScreen() {
  const [groups, setGroups] = useState<Group[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [open, setOpen] = useState<Group | null>(null);
  const [form, setForm] = useState<"create" | "join" | null>(null);
  // Connecté·e ou non (comme l'iPhone et le Mac : sans compte, la page dit ce que donnent les
  // groupes et propose la connexion, pas des boutons qui échoueraient). `null` : on relit.
  const [signedIn, setSignedIn] = useState<boolean | null>(null);
  useEffect(() => {
    const refresh = () => { void syncService.status().then((status) => setSignedIn(status.signedIn)); };
    refresh();
    return syncService.subscribe(refresh);
  }, []);
  const load = useCallback(async () => {
    setError(null);
    try { setGroups(await refreshMyGroups()); } catch (e) { setError(e instanceof Error ? e.message : String(e)); setGroups([]); }
  }, []);
  useEffect(() => { if (signedIn) void load(); }, [load, signedIn]);

  if (signedIn === false) return <GroupsSignIn />;
  if (open) return <GroupPage group={open} back={() => { setOpen(null); void load(); }} />;
  return (
    <div className="page">
      <PageHeader title="Groupes"
        actions={signedIn ? <>
          <Button icon="plus" onClick={() => setForm("create")}>Créer</Button>
          <Button variant="primary" icon="person.2" onClick={() => setForm("join")}>Rejoindre</Button>
        </> : undefined} />
      {error && <p className="settings-error">{error}</p>}
      {form && <GroupForm mode={form} done={(group) => { setForm(null); if (group) setOpen(group); void load(); }} />}
      {groups === null ? <p className="faint">Chargement…</p> : groups.length === 0 && !error ? (
        <Card><EmptyState icon="person.2" title="Pas encore de groupe">Crée-en un et partage son code, ou rejoins celui d'un·e camarade.</EmptyState></Card>
      ) : (
        <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fill, minmax(260px, 1fr))", gap: 12 }}>
          {groups.map((group) => (
            <Card key={group.id} onClick={() => setOpen(group)}>
              <div className="serif" style={{ fontSize: 18 }}>{group.name}</div>
              <div className="faint" style={{ fontSize: 12 }}>{group.courses.join(" · ") || "Toutes matières"}</div>
              <div className="mono faint" style={{ fontSize: 11, marginTop: 6 }}>{group.inviteCode}{group.role === "admin" ? " · admin" : ""}</div>
            </Card>
          ))}
        </div>
      )}
    </div>
  );
}

/** Sans compte : ce que donnent les groupes, et la connexion (la même que dans les réglages). */
function GroupsSignIn() {
  const benefits: [IconName, string][] = [
    ["person.2", "Qui travaille en ce moment"],
    ["checklist", "Qui en est où, série par série"],
    ["questionmark", "Entraide sur un exercice"],
    ["calendar", "Sessions ensemble"],
  ];
  return (
    <div className="page" style={{ maxWidth: 560 }}>
      <PageHeader title="Travailler ensemble" />
      <Card>
        {benefits.map(([icon, label]) => (
          <div key={label} style={{ display: "flex", alignItems: "center", gap: 12, padding: "8px 0" }}>
            <Icon name={icon} size={18} />
            <span>{label}</span>
          </div>
        ))}
      </Card>
      <Card style={{ marginTop: 12 }}><SyncAccount /></Card>
    </div>
  );
}

function GroupForm({ mode, done }: { mode: "create" | "join"; done: (group: Group | null) => void }) {
  const { store } = useData();
  const tracked = store ? store.fetch(Course).filter((c) => c.isTracked).map((c) => c.displayCode) : [];
  const [name, setName] = useState("");
  const [code, setCode] = useState("");
  const [subjects, setSubjects] = useState<string[]>([]);
  const [displayName, setDisplayName] = useState(readGroupsDisplayName);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const submit = async () => {
    setBusy(true);
    setError(null);
    try {
      writeGroupsDisplayName(displayName);
      done(mode === "create" ? await Groups.create(name, subjects, displayName) : await Groups.join(code, displayName));
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };
  const ready = displayName.trim() !== "" && (mode === "create" ? name.trim() !== "" : code.trim() !== "");
  return (
    <Card style={{ marginBottom: 16 }}>
      <div style={{ display: "flex", flexDirection: "column", gap: 10, maxWidth: 520 }}>
        <span className="serif" style={{ fontSize: 18 }}>{mode === "create" ? "Nouveau groupe" : "Rejoindre un groupe"}</span>
        {mode === "create"
          ? <input className="field" placeholder="Nom du groupe (« Révisions Analyse »)" value={name} onChange={(e) => setName(e.target.value)} />
          : <input className="field mono" placeholder="Code reçu (EPFL-7K2Q)" value={code} onChange={(e) => setCode(e.target.value)} />}
        <input className="field" placeholder="Ton prénom, tel que le groupe le verra" value={displayName} onChange={(e) => setDisplayName(e.target.value)} />
        {mode === "create" && tracked.length > 0 && (
          <div style={{ display: "flex", flexWrap: "wrap", gap: 6 }}>
            {tracked.map((c) => (
              <button key={c} type="button" className="chip" aria-pressed={subjects.includes(c)}
                onClick={() => setSubjects(subjects.includes(c) ? subjects.filter((s) => s !== c) : [...subjects, c])}>{c}</button>
            ))}
          </div>
        )}
        {error && <span className="settings-error">{error}</span>}
        <div style={{ display: "flex", gap: 8, justifyContent: "flex-end" }}>
          <Button onClick={() => done(null)}>Annuler</Button>
          <Button variant="primary" disabled={busy || !ready} onClick={() => { void submit(); }}>{busy ? "…" : mode === "create" ? "Créer" : "Rejoindre"}</Button>
        </div>
      </div>
    </Card>
  );
}

function GroupPage({ group, back }: { group: Group; back: () => void }) {
  const { store } = useData();
  const timer = useSyncExternalStore(timerController.subscribe, timerController.snapshot);
  const [presence, setPresence] = useState<Presence[]>([]);
  const [board, setBoard] = useState<LeaderboardRow[]>([]);
  const [members, setMembers] = useState<Member[]>([]);
  const [posts, setPosts] = useState<Post[]>([]);
  const [planned, setPlanned] = useState<PlannedGroupSession[]>([]);
  const [completions, setCompletions] = useState<Completions>({ items: [], series: [] });
  const [live, setLive] = useState<LiveSession | null>(null);
  const [encryption, setEncryption] = useState<EncryptionState | null>(null);
  const [me, setMe] = useState<string>("");
  const [error, setError] = useState<string | null>(null);
  const [copied, setCopied] = useState(false);
  const [now, setNow] = useState(() => new Date());
  const [composing, setComposing] = useState(false);
  const [thread, setThread] = useState<Post | null>(null);
  const [planning, setPlanning] = useState(false);
  const [busy, setBusy] = useState(false);
  const courses = store ? store.fetch(Course).filter((c) => c.isTracked) : [];
  const subjects = group.courses.length > 0 ? group.courses : courses.map((c) => c.code);

  const load = useCallback(async () => {
    try {
      // Mon temps des deux dernières semaines et mon avancement (matières du groupe seulement).
      if (store) {
        const subjectSet = new Set(group.courses);
        const counting = readCounting();
        const logs = store.fetch(StudySession)
          .filter((s) => s.course && countsSession(counting, s) && (subjectSet.size === 0 || subjectSet.has(s.course.code) || subjectSet.has(s.course.displayCode)))
          .map((s) => ({ courseCode: s.course?.code ?? "", taskType: s.taskTypeRaw, startedAt: s.startedAt, durationSeconds: s.durationSeconds }));
        await Groups.replaceStudyLogs(group.id, logs).catch(() => {});
        await pushMyProgress(group.id, group.courses, store.fetch(Course).filter((c) => c.isTracked)).catch(() => {});
      }
      const [p, b, m, po, pl, co, li, id] = await Promise.all([
        Groups.presence(group.id), Groups.leaderboard(group.id).catch(() => []), Groups.members(group.id),
        fetchPosts(group.id).catch(() => [] as Post[]), fetchPlanned(group.id).catch(() => []),
        fetchCompletions(group.id).catch(() => ({ items: [], series: [] })), fetchLiveSession(group.id).catch(() => null), myUserID(),
      ]);
      setPresence(p); setBoard(b); setMembers(m); setPosts(po); setPlanned(pl); setCompletions(co); setLive(li); setMe(id ?? ""); setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
  }, [group, store]);
  useEffect(() => {
    void prepareEncryption(group.id).then(setEncryption);
    void load();
    // Relu toutes les 30 s tant que la page est ouverte (rien quand elle est fermée).
    const id = window.setInterval(() => { setNow(new Date()); void load(); }, 30_000);
    return () => window.clearInterval(id);
  }, [load, group.id]);

  const linked = timer.state?.groupSession?.groupID === group.id;
  const questions = posts.filter((post) => post.parentID === null);
  const run = (work: () => Promise<unknown>) => {
    setBusy(true);
    work().then(() => load(), (e: unknown) => setError(e instanceof Error ? e.message : String(e))).finally(() => setBusy(false));
  };
  const joinWork = (entry: Presence) => {
    const course = courses.find((c) => c.code.toUpperCase() === entry.courseCode.toUpperCase() || c.displayCode === entry.courseCode);
    const type = TaskType.choices.find((t) => TaskType.label(t) === entry.taskLabel) ?? "exercise";
    timerController.retarget(course?.id, type, undefined);
    timerController.start();
  };

  return (
    <div className="page">
      <PageHeader title={group.name} subtitle={group.courses.join(" · ") || "Toutes matières"}
        actions={<>
          <Button icon="chevron.left" onClick={back}>Groupes</Button>
          <Button icon="doc.on.doc" onClick={() => { void navigator.clipboard?.writeText(`Rejoins « ${group.name} » sur Polymestre avec le code ${group.inviteCode}.`); setCopied(true); }}>
            {copied ? "Copié" : `Code ${group.inviteCode}`}
          </Button>
        </>} />
      {error && <p className="settings-error">{error}</p>}
      <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(340px, 1fr))", gap: 16, alignItems: "start" }}>
        <div style={{ display: "flex", flexDirection: "column", gap: 16 }}>
          <Section title="En ce moment">
            <Card>
              {presence.length === 0 ? <p className="faint" style={{ margin: 0 }}>Personne ne travaille en ce moment.</p> : presence.map((entry) => (
                <div key={entry.userID} style={{ display: "flex", alignItems: "center", gap: 10, padding: "6px 0" }}>
                  <span style={{ width: 8, height: 8, borderRadius: 4, background: "var(--correct)" }} />
                  <span style={{ fontWeight: 600 }}>{entry.isMe ? "Toi" : entry.displayName}</span>
                  <span className="faint" style={{ flex: 1 }}>{[entry.courseCode, entry.taskLabel, entry.target].filter(Boolean).join(" · ") || "Travail en cours"}</span>
                  <span className="mono faint">{hours((now.getTime() - entry.startedAt.getTime()) / 1000)}</span>
                  {!entry.isMe && entry.courseCode && <Button size="sm" onClick={() => joinWork(entry)}>Rejoindre</Button>}
                </div>
              ))}
            </Card>
          </Section>
          <Section title="Session ensemble">
            <Card>
              <p className="faint" style={{ margin: "0 0 10px", fontSize: 12 }}>Un chrono commun : les pauses tombent au même moment pour tout le monde, chacun sur son travail.</p>
              {live ? (
                <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
                  <span style={{ fontWeight: 600 }}>{live.present.map((p) => (p.userID === me ? "toi" : p.name)).join(", ") || "En cours"}</span>
                  <div style={{ display: "flex", gap: 8, flexWrap: "wrap" }}>
                    {linked ? <span style={{ color: "var(--correct)" }}>Ton chrono suit le groupe.</span>
                      : <Button variant="primary" disabled={busy} onClick={() => run(() => groupSessions.join(live, group.name))}>Rejoindre la session</Button>}
                    {live.hostID === me && <Button disabled={busy} onClick={() => run(() => groupSessions.endForEveryone(live))}>Terminer pour tous</Button>}
                  </div>
                </div>
              ) : (
                <Button variant="primary" disabled={busy} onClick={() => run(() => groupSessions.startSession(group.id, group.name))}>
                  {timer.state ? "Partager mon chrono avec le groupe" : "Lancer une session ensemble"}
                </Button>
              )}
            </Card>
          </Section>
          <Section title="Cette semaine">
            <Card>
              {board.length === 0 ? <p className="faint" style={{ margin: 0 }}>Pas encore de temps compté cette semaine.</p> : board.map((row, index) => (
                <div key={row.userID} style={{ display: "flex", alignItems: "center", gap: 10, padding: "6px 0" }}>
                  <span className="mono faint" style={{ width: 20 }}>{index + 1}</span>
                  <span style={{ flex: 1, fontWeight: row.userID === me ? 600 : 400 }}>{row.userID === me ? "Toi" : row.displayName}</span>
                  {row.seriesCompleted > 0 && <span className="faint" style={{ fontSize: 12 }}>{row.seriesCompleted} séries</span>}
                  <span className="mono">{hours(row.weeklySeconds)}</span>
                </div>
              ))}
            </Card>
          </Section>
        </div>
        <div style={{ display: "flex", flexDirection: "column", gap: 16 }}>
          <Section title="Entraide" action={<Button size="sm" icon="plus" disabled={encryption === "waitingForKey"} onClick={() => setComposing(true)}>Demander</Button>}>
            {encryption === "waitingForKey" && <p className="faint" style={{ fontSize: 12 }}>En attente de la clé du groupe : elle arrive dès qu'un membre ouvre l'app.</p>}
            <Card>
              {questions.length === 0 ? <p className="faint" style={{ margin: 0 }}>Pas encore de question.</p> : questions.slice(0, 8).map((post) => (
                <button key={post.id} type="button" onClick={() => setThread(post)}
                  style={{ all: "unset", display: "flex", flexDirection: "column", gap: 2, padding: "8px 0", cursor: "pointer", borderBottom: "1px solid var(--rule)" }}>
                  <span style={{ fontSize: 13 }}><b>{post.authorID === me ? "Toi" : post.authorName}</b> <span className="faint">{postTarget(post)}</span>
                    {post.resolved && <span style={{ color: "var(--correct)" }}> · résolu</span>}</span>
                  <span style={{ fontSize: 14, color: post.locked ? "var(--ink-secondary)" : "var(--ink)" }}>{post.body}</span>
                  <span className="faint" style={{ fontSize: 12 }}>{posts.filter((p) => p.parentID === post.id).length} réponses</span>
                </button>
              ))}
            </Card>
          </Section>
          <Section title="Sessions" action={<Button size="sm" icon="plus" onClick={() => setPlanning(true)}>Planifier</Button>}>
            <Card>
              {planned.length === 0 ? <p className="faint" style={{ margin: 0 }}>Aucune session prévue.</p> : planned.slice(0, 5).map((session) => (
                <div key={session.id} style={{ padding: "6px 0" }}>
                  <div style={{ fontWeight: 600 }}>{session.title}</div>
                  <div className="faint" style={{ fontSize: 12 }}>{[DateUtils.fullDayLabel(session.startsAt), DateUtils.time(session.startsAt), session.courseCode, session.location].filter(Boolean).join(" · ")}</div>
                </div>
              ))}
            </Card>
          </Section>
          <Section title={`Membres · ${members.length}`}>
            <Card>
              {members.map((member) => (
                <div key={member.userID} style={{ display: "flex", gap: 8, padding: "4px 0" }}>
                  <Icon name="person" size={14} />
                  <span style={{ flex: 1 }}>{member.userID.toLowerCase() === me ? "Toi" : member.displayName}</span>
                  {member.role === "admin" && <span className="faint" style={{ fontSize: 12 }}>admin</span>}
                </div>
              ))}
            </Card>
          </Section>
        </div>
      </div>
      {subjects.length > 0 && members.length > 0 && (
        <Section title="Qui en est où">
          {subjects.map((code) => {
            const course = courses.find((c) => c.code.toUpperCase() === code.toUpperCase());
            const rows = subjectRows(code, completions, members, me);
            const boards = course ? seriesBoards(course, completions, members, me) : [];
            return (
              <Card key={code} style={{ marginBottom: 12 }}>
                <div className="serif" style={{ fontSize: 16, marginBottom: 6, color: course?.colorHex ?? "var(--ink)" }}>{code}</div>
                {rows.map((row) => (
                  <div key={row.userID} style={{ display: "flex", gap: 10, fontSize: 13, padding: "2px 0" }}>
                    <span style={{ flex: 1, fontWeight: row.isMe ? 600 : 400 }}>{row.isMe ? "Toi" : row.name}</span>
                    <span className="faint">{row.series} séries · {row.exercises} ex. · {row.theory} théorie</span>
                    {!row.isMe && <span className="mono" style={{ width: 60, textAlign: "right", color: row.gap > 0 ? "var(--review)" : "var(--ink-secondary)" }}>{row.gap === 0 ? "=" : row.gap > 0 ? `+${row.gap}` : row.gap}</span>}
                  </div>
                ))}
                {boards.length > 0 && (
                  <div style={{ display: "flex", gap: 14, overflowX: "auto", marginTop: 10 }}>
                    {boards.map((b) => (
                      <div key={`${b.seriesNumber}|${b.label}`} style={{ flex: "none", padding: 8, borderRadius: 8, background: "var(--ground)" }}>
                        <div style={{ fontSize: 12, fontWeight: 600, marginBottom: 4 }}>{b.displayName}</div>
                        {b.rows.slice(0, 8).map((row) => (
                          <div key={row.userID} style={{ display: "flex", alignItems: "center", gap: 3, marginBottom: 3 }}>
                            <span style={{ width: 54, fontSize: 11, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{row.isMe ? "Toi" : row.name}</span>
                            {b.exercises.map((n) => (
                              <span key={n} title={n} style={{ width: 10, height: 10, borderRadius: 3, background: row.complete || row.done.has(n) ? (course?.colorHex ?? "var(--ink)") : "var(--rule)" }} />
                            ))}
                          </div>
                        ))}
                      </div>
                    ))}
                  </div>
                )}
              </Card>
            );
          })}
        </Section>
      )}
      <Button icon="rectangle.portrait.and.arrow.right" onClick={() => {
        if (!window.confirm(`Quitter « ${group.name} » ?`)) return;
        void Groups.leave(group.id).then(back, (e: unknown) => setError(e instanceof Error ? e.message : String(e)));
      }}>Quitter le groupe</Button>
      <p className="faint" style={{ fontSize: 12, marginTop: 12 }}>Mis à jour {DateUtils.time(now)}.</p>
      {composing && <HelpComposer group={group} subjects={subjects} close={() => setComposing(false)} sent={() => { setComposing(false); void load(); }} />}
      {thread && <HelpThread group={group} question={thread} replies={posts.filter((p) => p.parentID === thread.id)} me={me} close={() => { setThread(null); void load(); }} />}
      {planning && <PlanForm group={group} courses={courses} close={() => { setPlanning(false); void load(); }} />}
    </div>
  );
}

function Modal({ title, children, close }: { title: string; children: React.ReactNode; close: () => void }) {
  return (
    <div role="dialog" aria-label={title} onClick={close}
      style={{ position: "fixed", inset: 0, background: "var(--scrim)", display: "grid", placeItems: "center", zIndex: 50 }}>
      <div onClick={(e) => e.stopPropagation()} style={{ width: "min(520px, 92vw)", background: "var(--sheet)", borderRadius: 14, padding: 20, display: "flex", flexDirection: "column", gap: 12 }}>
        <div style={{ display: "flex", alignItems: "center" }}>
          <span className="serif" style={{ fontSize: 20, flex: 1 }}>{title}</span>
          <Button size="sm" onClick={close}>Fermer</Button>
        </div>
        {children}
      </div>
    </div>
  );
}

function HelpComposer({ group, subjects, close, sent }: { group: Group; subjects: string[]; close: () => void; sent: () => void }) {
  const [subject, setSubject] = useState(subjects[0] ?? "");
  const [series, setSeries] = useState("");
  const [exercise, setExercise] = useState("");
  const [text, setText] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const send = async () => {
    setBusy(true);
    try {
      await createPost(group.id, readGroupsDisplayName() || "Moi", text, { courseCode: subject, seriesNumber: series ? Number(series) : null, exerciseNumber: exercise });
      sent();
    } catch (e) { setError(e instanceof Error ? e.message : String(e)); } finally { setBusy(false); }
  };
  return (
    <Modal title="Demander au groupe" close={close}>
      <div style={{ display: "flex", gap: 8 }}>
        <select className="field" value={subject} onChange={(e) => setSubject(e.target.value)} aria-label="Matière">
          <option value="">—</option>
          {subjects.map((code) => <option key={code} value={code}>{code}</option>)}
        </select>
        <input className="field" style={{ width: 80 }} placeholder="Série" value={series} onChange={(e) => setSeries(e.target.value.replace(/\D/g, ""))} />
        <input className="field" style={{ width: 100 }} placeholder="Exercice" value={exercise} onChange={(e) => setExercise(e.target.value)} />
      </div>
      <textarea className="field" rows={5} value={text} onChange={(e) => setText(e.target.value)} placeholder="Ta question" />
      <span className="faint" style={{ fontSize: 12 }}>Chiffré : seuls les membres du groupe peuvent lire.</span>
      {error && <span className="settings-error">{error}</span>}
      <Button variant="primary" disabled={busy || !text.trim()} onClick={() => { void send(); }}>{busy ? "…" : "Envoyer"}</Button>
    </Modal>
  );
}

function HelpThread({ group, question, replies, me, close }: { group: Group; question: Post; replies: Post[]; me: string; close: () => void }) {
  const [list, setList] = useState(replies);
  const [text, setText] = useState("");
  const [resolved, setResolved] = useState(question.resolved);
  const [error, setError] = useState<string | null>(null);
  const reply = async () => {
    try {
      const post = await createPost(group.id, readGroupsDisplayName() || "Moi", text, { parentID: question.id });
      setList([...list, post]);
      setText("");
    } catch (e) { setError(e instanceof Error ? e.message : String(e)); }
  };
  const bubble = (post: Post) => (
    <div key={post.id} style={{ padding: 10, borderRadius: 8, background: post.authorID === me ? "var(--selection)" : "var(--ground)" }}>
      <div className="faint" style={{ fontSize: 12 }}>{post.authorID === me ? "Toi" : post.authorName} · {DateUtils.time(post.createdAt)}</div>
      <div style={{ whiteSpace: "pre-wrap" }}>{post.body}</div>
    </div>
  );
  return (
    <Modal title={postTarget(question) || "Question"} close={close}>
      <div style={{ display: "flex", flexDirection: "column", gap: 8, maxHeight: 340, overflowY: "auto" }}>
        {bubble(question)}
        {[...list].sort((a, b) => a.createdAt.getTime() - b.createdAt.getTime()).map(bubble)}
      </div>
      <div style={{ display: "flex", gap: 8 }}>
        <input className="field" style={{ flex: 1 }} placeholder="Répondre…" value={text} onChange={(e) => setText(e.target.value)}
          onKeyDown={(e) => { if (e.key === "Enter" && text.trim()) void reply(); }} />
        <Button variant="primary" disabled={!text.trim()} onClick={() => { void reply(); }}>Envoyer</Button>
      </div>
      {question.authorID === me && (
        <Button onClick={() => { void setPostResolved(question.id, !resolved).then(() => setResolved(!resolved), (e: unknown) => setError(String(e))); }}>
          {resolved ? "Rouvrir" : "Marquer résolu"}
        </Button>
      )}
      {error && <span className="settings-error">{error}</span>}
    </Modal>
  );
}

function PlanForm({ group, courses, close }: { group: Group; courses: Course[]; close: () => void }) {
  const tomorrow = new Date(Date.now() + 86_400_000);
  tomorrow.setMinutes(0, 0, 0);
  const pad = (n: number) => String(n).padStart(2, "0");
  const [title, setTitle] = useState("");
  const [code, setCode] = useState("");
  const [when, setWhen] = useState(`${tomorrow.getFullYear()}-${pad(tomorrow.getMonth() + 1)}-${pad(tomorrow.getDate())}T${pad(tomorrow.getHours())}:00`);
  const [minutes, setMinutes] = useState(90);
  const [location, setLocation] = useState("");
  const [error, setError] = useState<string | null>(null);
  const save = async () => {
    try {
      await createPlanned(group.id, { title: title.trim() || "Session d'étude", courseCode: code, startsAt: new Date(when), durationMinutes: minutes, location });
      close();
    } catch (e) { setError(e instanceof Error ? e.message : String(e)); }
  };
  return (
    <Modal title="Planifier une session" close={close}>
      <input className="field" placeholder="Session d'étude" value={title} onChange={(e) => setTitle(e.target.value)} />
      <select className="field" value={code} onChange={(e) => setCode(e.target.value)} aria-label="Cours">
        <option value="">Aucun cours</option>
        {courses.map((c) => <option key={c.id} value={c.code}>{c.displayCode}</option>)}
      </select>
      <input className="field" type="datetime-local" value={when} onChange={(e) => setWhen(e.target.value)} />
      <div style={{ display: "flex", gap: 8, alignItems: "center" }}>
        <span>Durée</span>
        <input className="field" type="number" min={15} max={480} step={15} value={minutes} onChange={(e) => setMinutes(Number(e.target.value))} style={{ width: 90 }} />
        <span>min</span>
      </div>
      <input className="field" placeholder="Lieu" value={location} onChange={(e) => setLocation(e.target.value)} />
      {error && <span className="settings-error">{error}</span>}
      <Button variant="primary" onClick={() => { void save(); }}>Planifier</Button>
    </Modal>
  );
}
