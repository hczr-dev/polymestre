import { beforeEach, describe, expect, it } from "vitest";
import { DatabaseSync } from "node:sqlite";
import { LocalStore, type Db, type Row, type Value } from "../src/sync/store.ts";
import { SyncEngine, rewind, type Transport } from "../src/sync/engine.ts";

/** node:sqlite derrière l'interface `Db` de l'app. */
function memoryDb(): Db {
  const db = new DatabaseSync(":memory:");
  return {
    async execute(sql: string, params: Value[] = []) { db.prepare(sql).run(...params); },
    async select<T>(sql: string, params: Value[] = []) { return db.prepare(sql).all(...params) as T[]; },
  };
}

/**
 * Serveur simulé, avec les règles de `sync_guard` (vérifiées contre Postgres par
 * scripts/test-migration.sh) : la plus récente écriture gagne, le serveur pose
 * server_updated_at, la réponse porte la version gardée.
 */
class FakeServer implements Transport {
  data = new Map<string, Map<string, Row>>();
  private clock = Date.parse("2026-10-30T10:00:00Z");
  pushes = 0;

  private table(name: string) {
    if (!this.data.has(name)) this.data.set(name, new Map());
    return this.data.get(name)!;
  }

  /** Microsecondes et « +00:00 », comme PostgREST. */
  private stamp(): string {
    this.clock += 1;
    return new Date(this.clock).toISOString().replace("Z", "123+00:00");
  }

  async push(table: string, rows: Row[]): Promise<Row[]> {
    this.pushes++;
    const t = this.table(table);
    return rows.map((r) => {
      const old = t.get(String(r.id));
      if (old && String(r.updated_at) < String(old.updated_at)) return old;
      const kept = { ...old, ...r, updated_at: String(r.updated_at).replace("Z", "+00:00"), server_updated_at: this.stamp() };
      t.set(String(r.id), kept);
      return kept;
    });
  }

  async pull(table: string, since: string | null, afterId: string | null, limit: number) {
    const key = (r: Row) => [new Date(String(r.server_updated_at)).getTime(), String(r.id)] as const;
    const after = (r: Row) => {
      if (!since) return true;
      const [ts, id] = key(r);
      const s = new Date(since).getTime();
      return ts > s || (ts === s && afterId !== null && id > afterId);
    };
    const rows = [...this.table(table).values()].filter(after)
      .sort((a, b) => key(a)[0] - key(b)[0] || key(a)[1].localeCompare(key(b)[1]))
      .slice(0, limit);
    return { rows };
  }
}

async function device(server: FakeServer, batch = 200) {
  const store = new LocalStore(memoryDb());
  await store.migrate();
  return { store, engine: new SyncEngine(store, server, batch) };
}

describe("synchronisation", () => {
  let server: FakeServer;
  beforeEach(() => { server = new FakeServer(); });

  it("une écriture faite sur un appareil arrive sur l'autre", async () => {
    const mac = await device(server);
    const pc = await device(server);
    await mac.store.write("sync_courses", { id: "c1", name: "Analyse I", credits: 8, is_active: 1 });
    const r1 = await mac.engine.sync();
    expect(r1.pushed).toBe(1);
    expect((await mac.store.get("sync_courses", "c1"))!.dirty).toBe(0);

    await pc.engine.sync();
    const row = (await pc.store.get("sync_courses", "c1"))!;
    expect(row.name).toBe("Analyse I");
    expect(row.credits).toBe(8);
    expect(row.is_active).toBe(1);
    expect(row.dirty).toBe(0);
  });

  it("la modification la plus récente gagne, des deux côtés", async () => {
    const a = await device(server);
    const b = await device(server);
    await a.store.write("sync_courses", { id: "c1", name: "v1" });
    await a.engine.sync();
    await b.engine.sync();

    await b.store.write("sync_courses", { id: "c1", name: "ancienne (b)" });
    await new Promise((r) => setTimeout(r, 5));
    await a.store.write("sync_courses", { id: "c1", name: "récente (a)" });
    await a.engine.sync(); // a envoie la plus récente
    await b.engine.sync(); // b envoie une version plus ancienne : refusée, il adopte celle de a
    await a.engine.sync();

    expect((await a.store.get("sync_courses", "c1"))!.name).toBe("récente (a)");
    expect((await b.store.get("sync_courses", "c1"))!.name).toBe("récente (a)");
    expect((await b.store.get("sync_courses", "c1"))!.dirty).toBe(0);
  });

  it("une modification locale plus récente que le serveur n'est pas écrasée à la lecture", async () => {
    const a = await device(server);
    await server.push("sync_courses", [{ id: "c1", name: "serveur", updated_at: "2026-10-30T09:00:00.000Z" }]);
    await a.store.write("sync_courses", { id: "c1", name: "locale" });
    // Lecture avant envoi : simulée en appelant applyRemote directement.
    const outcome = await a.store.applyRemote("sync_courses", { id: "c1", name: "serveur", updated_at: "2026-10-30T09:00:00.000Z" });
    expect(outcome).toBe("kept-local");
    expect((await a.store.get("sync_courses", "c1"))!.name).toBe("locale");
  });

  it("supprimer un cours supprime ses séries et exercices, et garde les sessions sans exercice", async () => {
    const a = await device(server);
    const b = await device(server);
    await a.store.write("sync_courses", { id: "c1", name: "Physique" });
    await a.store.write("sync_exercise_series", { id: "s1", course_id: "c1", series_number: 1 });
    await a.store.write("sync_exercises", { id: "e1", series_id: "s1", exercise_number: "1.1" });
    await a.store.write("sync_sub_questions", { id: "q1", exercise_id: "e1", label: "a)" });
    await a.store.write("sync_sub_questions", { id: "q2", parent_id: "q1", label: "i)" });
    await a.store.write("sync_study_sessions", { id: "ss1", course_id: "c2", exercise_id: "e1", duration_seconds: 600 });
    await a.engine.sync();
    await b.engine.sync();

    await a.store.remove("sync_courses", "c1");
    for (const [table, id] of [["sync_courses", "c1"], ["sync_exercise_series", "s1"], ["sync_exercises", "e1"], ["sync_sub_questions", "q1"], ["sync_sub_questions", "q2"]] as const)
      expect((await a.store.get(table, id))!.deleted_at, `${table} ${id}`).not.toBeNull();
    const session = (await a.store.get("sync_study_sessions", "ss1"))!;
    expect(session.deleted_at).toBeNull();
    expect(session.exercise_id).toBeNull();

    await a.engine.sync();
    await b.engine.sync();
    expect(await b.store.live("sync_exercises")).toEqual([]);
    expect((await b.store.get("sync_study_sessions", "ss1"))!.exercise_id).toBeNull();
  });

  it("un exercice ajouté hors ligne dans une série supprimée ailleurs disparaît aussi", async () => {
    const a = await device(server);
    const b = await device(server);
    await a.store.write("sync_exercise_series", { id: "s1", series_number: 2 });
    await a.engine.sync();
    await b.engine.sync();

    await b.store.write("sync_exercises", { id: "e9", series_id: "s1" }); // b hors ligne
    await a.store.remove("sync_exercise_series", "s1");
    await a.engine.sync();
    const report = await b.engine.sync();
    expect(report.orphans).toBe(1);
    expect((await b.store.get("sync_exercises", "e9"))!.deleted_at).not.toBeNull();

    await a.engine.sync();
    expect((await a.store.get("sync_exercises", "e9"))!.deleted_at).not.toBeNull();
  });

  it("lit par pages sans rien perdre ni boucler", async () => {
    const a = await device(server, 7);
    const b = await device(server, 7);
    for (let k = 0; k < 50; k++) await a.store.write("sync_mistakes", { id: `m${String(k).padStart(2, "0")}`, summary: `erreur ${k}` });
    const ra = await a.engine.sync();
    expect(ra.pushed).toBe(50);
    expect(server.pushes).toBeGreaterThanOrEqual(8);
    await b.engine.sync();
    expect((await b.store.live("sync_mistakes")).length).toBe(50);
    const again = await b.engine.sync();
    // Seule la marge de relecture repasse, sans rien changer.
    expect((await b.store.dirty("sync_mistakes")).length).toBe(0);
    expect(again.keptLocal).toBe(0);
  });

  it("une modification faite pendant l'envoi reste à envoyer", async () => {
    const a = await device(server);
    await a.store.write("sync_courses", { id: "c1", name: "avant" });
    const sent = (await a.store.dirty("sync_courses"))[0];
    await new Promise((r) => setTimeout(r, 5));
    await a.store.write("sync_courses", { id: "c1", name: "pendant" });
    await a.store.acknowledge("sync_courses", sent, { id: "c1", name: "avant", updated_at: String(sent.updated_at), server_updated_at: "x" });
    const row = (await a.store.get("sync_courses", "c1"))!;
    expect(row.name).toBe("pendant");
    expect(row.dirty).toBe(1);
  });

  it("deux synchronisations lancées ensemble n'en font qu'une", async () => {
    const a = await device(server);
    await a.store.write("sync_courses", { id: "c1", name: "x" });
    const [r1, r2] = await Promise.all([a.engine.sync(), a.engine.sync()]);
    expect(r1).toBe(r2);
    expect(server.pushes).toBe(1);
  });

  it("refuse une colonne inconnue plutôt que de la perdre", async () => {
    const a = await device(server);
    await expect(a.store.write("sync_courses", { id: "c1", nom: "x" } as never)).rejects.toThrow(/colonne inconnue/);
  });

  it("la marge de relecture recule le curseur", () => {
    expect(rewind("2026-10-30T10:02:00.000+00:00")).toBe("2026-10-30T10:00:00.000Z");
    expect(rewind(null)).toBeNull();
  });
});

describe("Base locale : un champ ajouté au schéma", () => {
  it("une table d'avant (sans `label`) reçoit la colonne, et s'écrit", async () => {
    const db = memoryDb();
    // La table des séries telle qu'une installation d'avant l'a créée.
    await db.execute("CREATE TABLE sync_exercise_series (id TEXT PRIMARY KEY, series_number INTEGER NOT NULL DEFAULT 0, title TEXT NOT NULL DEFAULT '', planned_week INTEGER NOT NULL DEFAULT 0, published_at TEXT, due_date TEXT, url_string TEXT NOT NULL DEFAULT '', topic TEXT NOT NULL DEFAULT '', solutions_at TEXT, solution_url_string TEXT NOT NULL DEFAULT '', needs_reread INTEGER NOT NULL DEFAULT 0, course_id TEXT, updated_at TEXT NOT NULL DEFAULT '', deleted_at TEXT, server_updated_at TEXT, dirty INTEGER NOT NULL DEFAULT 1)");
    await db.execute("INSERT INTO sync_exercise_series (id, series_number) VALUES ('old', 5)");
    const store = new LocalStore(db);
    await store.migrate();
    await store.migrate();
    const old = await db.select<{ label: string }>("SELECT label FROM sync_exercise_series WHERE id = 'old'");
    expect(old[0]?.label).toBe("");
    await store.write("sync_exercise_series", { id: "new", series_number: 5, label: "b" });
    const rows = await db.select<{ label: string }>("SELECT label FROM sync_exercise_series WHERE id = 'new'");
    expect(rows[0]?.label).toBe("b");
  });
});
