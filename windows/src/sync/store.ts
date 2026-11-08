// Base locale : SQLite, décrite par ddl.generated.ts.
//
// L'accès passe par `Db`, assez petit pour être servi par tauri-plugin-sql dans
// l'app et par node:sqlite dans les tests. Les paramètres sont des `?`, compris
// des deux.

import { ddl } from "../models/ddl.generated.ts";
import { tables, fieldColumn, refColumn, type Table } from "../models/schema.ts";

export type Value = string | number | null;
export type Row = Record<string, unknown>;

export interface Db {
  execute(sql: string, params?: Value[]): Promise<void>;
  select<T = Row>(sql: string, params?: Value[]): Promise<T[]>;
}

export const tableByName = (name: string): Table => {
  const t = tables.find((x) => x.name === name);
  if (!t) throw new Error(`table inconnue : ${name}`);
  return t;
};

/** Horodatage canonique : ISO 8601 en UTC à la milliseconde, « Z » final. */
export const isoNow = (): string => new Date().toISOString();
export const canonicalDate = (v: unknown): string | null =>
  v === null || v === undefined || v === "" ? null : new Date(String(v)).toISOString();

/** Ligne venue du serveur (JSON PostgREST) → valeurs SQLite. */
export function fromRemote(t: Table, r: Row): Record<string, Value> {
  const out: Record<string, Value> = { id: String(r.id) };
  if (r._tombstone === true) {
    // Pierre tombale chiffrée : le serveur n'a pas de champs. On ne touche qu'aux
    // colonnes de synchronisation ; le contenu local (s'il y en a) reste.
    out.updated_at = canonicalDate(r.updated_at);
    out.deleted_at = canonicalDate(r.deleted_at);
    out.server_updated_at = (r.server_updated_at as string | null) ?? null;
    return out;
  }
  for (const f of t.fields) {
    const v = r[fieldColumn(f)];
    if (v === null || v === undefined) { out[fieldColumn(f)] = null; continue; }
    switch (f.type) {
      case "bool": out[fieldColumn(f)] = v ? 1 : 0; break;
      case "date": out[fieldColumn(f)] = canonicalDate(v); break;
      case "int": case "double": out[fieldColumn(f)] = Number(v); break;
      default: out[fieldColumn(f)] = String(v);
    }
  }
  for (const ref of t.refs) out[refColumn(ref)] = (r[refColumn(ref)] as string | null) ?? null;
  out.updated_at = canonicalDate(r.updated_at);
  out.deleted_at = canonicalDate(r.deleted_at);
  // Gardé tel quel (microsecondes) : il ne sert qu'à relancer le serveur.
  out.server_updated_at = (r.server_updated_at as string | null) ?? null;
  return out;
}

/** Ligne locale → corps JSON envoyé au serveur (sans les colonnes locales). */
export function toRemote(t: Table, r: Row): Row {
  const out: Row = { id: r.id };
  for (const f of t.fields) {
    const v = r[fieldColumn(f)];
    out[fieldColumn(f)] = v === null || v === undefined ? null : f.type === "bool" ? v === 1 || v === true : v;
  }
  for (const ref of t.refs) out[refColumn(ref)] = r[refColumn(ref)] ?? null;
  out.updated_at = r.updated_at;
  out.deleted_at = r.deleted_at ?? null;
  return out;
}

export class LocalStore {
  constructor(readonly db: Db) {}

  async migrate(): Promise<void> {
    for (const stmt of ddl) await this.db.execute(stmt);
    await this.addMissingColumns();
  }

  /**
   * Un champ ajouté au schéma (`label` des séries) : `CREATE TABLE IF NOT EXISTS`
   * ne touche pas une table déjà là, et toute écriture échouait alors sur une
   * colonne inconnue. Les colonnes absentes s'ajoutent ici, avec leur défaut.
   */
  private async addMissingColumns(): Promise<void> {
    for (const stmt of ddl) {
      const head = stmt.match(/^CREATE TABLE IF NOT EXISTS (\w+) \(\n([\s\S]*)\n\)$/);
      if (!head) continue;
      const [, table, body] = head;
      const present = new Set((await this.db.select<{ name: string }>(`PRAGMA table_info(${table})`)).map((c) => c.name));
      for (const line of body.split("\n")) {
        const def = line.trim().replace(/,$/, "");
        const name = def.split(/\s+/)[0];
        if (!name || present.has(name) || /PRIMARY KEY/.test(def)) continue;
        await this.db.execute(`ALTER TABLE ${table} ADD COLUMN ${def}`);
      }
    }
  }

  /** Écriture locale : la ligne devient « à envoyer ». */
  async write(table: string, values: Record<string, Value> & { id: string }): Promise<void> {
    const t = tableByName(table);
    const allowed = new Set(["id", ...t.fields.map(fieldColumn), ...t.refs.map(refColumn), "deleted_at"]);
    const cols = Object.keys(values).filter((c) => allowed.has(c));
    for (const c of Object.keys(values)) if (!allowed.has(c)) throw new Error(`${table}.${c} : colonne inconnue`);
    const all = [...cols, "updated_at", "dirty"];
    const params: Value[] = [...cols.map((c) => values[c]), isoNow(), 1];
    const updates = all.filter((c) => c !== "id").map((c) => `${c} = excluded.${c}`).join(", ");
    await this.db.execute(
      `INSERT INTO ${table} (${all.join(", ")}) VALUES (${all.map(() => "?").join(", ")}) ON CONFLICT(id) DO UPDATE SET ${updates}`,
      params,
    );
  }

  /**
   * Suppression locale, avec les règles de SwiftData : les enfants en cascade
   * reçoivent eux aussi une pierre tombale, les autres perdent la référence.
   */
  async remove(table: string, id: string, now = isoNow()): Promise<void> {
    await this.db.execute(`UPDATE ${table} SET deleted_at = ?, updated_at = ?, dirty = 1 WHERE id = ? AND deleted_at IS NULL`, [now, now, id]);
    for (const child of tables) for (const ref of child.refs) {
      if (ref.table !== table) continue;
      const col = refColumn(ref);
      if (ref.onDelete === "cascade") {
        const kids = await this.db.select<{ id: string }>(`SELECT id FROM ${child.name} WHERE ${col} = ? AND deleted_at IS NULL`, [id]);
        for (const k of kids) await this.remove(child.name, k.id, now);
      } else {
        await this.db.execute(`UPDATE ${child.name} SET ${col} = NULL, updated_at = ?, dirty = 1 WHERE ${col} = ?`, [now, id]);
      }
    }
  }

  async get(table: string, id: string): Promise<Row | undefined> {
    return (await this.db.select(`SELECT * FROM ${table} WHERE id = ?`, [id]))[0];
  }

  async live(table: string): Promise<Row[]> {
    return this.db.select(`SELECT * FROM ${table} WHERE deleted_at IS NULL ORDER BY id`);
  }

  async dirty(table: string, limit = 500): Promise<Row[]> {
    return this.db.select(`SELECT * FROM ${table} WHERE dirty = 1 ORDER BY updated_at LIMIT ?`, [limit]);
  }

  /**
   * Accusé de réception d'un envoi. Ne nettoie que si la ligne n'a pas bougé
   * pendant l'envoi : une modification faite entre-temps reste à envoyer.
   */
  async acknowledge(table: string, sent: Row, server: Record<string, Value>): Promise<void> {
    const t = tableByName(table);
    const current = await this.get(table, String(sent.id));
    if (!current || current.updated_at !== sent.updated_at) return;
    await this.overwrite(t, server);
  }

  /**
   * Version venue du serveur. La plus récente gagne ; à égalité, le serveur.
   * Une ligne locale non envoyée **plus récente** reste, et partira au prochain envoi.
   */
  async applyRemote(table: string, server: Record<string, Value>): Promise<"applied" | "kept-local"> {
    const t = tableByName(table);
    const local = await this.get(table, String(server.id));
    if (local && local.dirty === 1 && String(local.updated_at) > String(server.updated_at)) return "kept-local";
    await this.overwrite(t, server);
    return "applied";
  }

  private async overwrite(t: Table, server: Record<string, Value>): Promise<void> {
    // Seules les colonnes présentes : une pierre tombale chiffrée n'a que celles de synchronisation.
    const cols = ["id", ...t.fields.map(fieldColumn), ...t.refs.map(refColumn), "updated_at", "deleted_at", "server_updated_at"]
      .filter((c) => c in server);
    const all = [...cols, "dirty"];
    const updates = all.filter((c) => c !== "id").map((c) => `${c} = excluded.${c}`).join(", ");
    await this.db.execute(
      `INSERT INTO ${t.name} (${all.join(", ")}) VALUES (${all.map(() => "?").join(", ")}) ON CONFLICT(id) DO UPDATE SET ${updates}`,
      [...cols.map((c) => server[c] ?? null), 0],
    );
  }

  /**
   * Après une lecture : un enfant ajouté ici hors ligne, dont le parent a été
   * supprimé sur un autre appareil, suit la règle de suppression du parent.
   */
  async sweepOrphans(): Promise<number> {
    let swept = 0;
    for (const child of tables) for (const ref of child.refs) {
      const col = refColumn(ref);
      const orphans = await this.db.select<{ id: string }>(
        `SELECT c.id FROM ${child.name} c JOIN ${ref.table} p ON p.id = c.${col}
         WHERE c.deleted_at IS NULL AND p.deleted_at IS NOT NULL`);
      for (const o of orphans) {
        if (ref.onDelete === "cascade") await this.remove(child.name, o.id);
        else await this.db.execute(`UPDATE ${child.name} SET ${col} = NULL, updated_at = ?, dirty = 1 WHERE id = ?`, [isoNow(), o.id]);
        swept++;
      }
    }
    return swept;
  }

  /**
   * Après un changement de clé : les curseurs repartent de zéro (on relit tout avec la
   * nouvelle clé) et, si `markDirty`, chaque ligne est à renvoyer (coffre neuf ou réinitialisé).
   */
  async resetSyncState(markDirty = true): Promise<void> {
    await this.db.execute(`DELETE FROM sync_cursor`);
    if (markDirty) for (const t of tables) await this.db.execute(`UPDATE ${t.name} SET dirty = 1`);
  }

  async cursor(table: string): Promise<string | null> {
    const r = await this.db.select<{ server_updated_at: string }>(`SELECT server_updated_at FROM sync_cursor WHERE table_name = ?`, [table]);
    return r[0]?.server_updated_at ?? null;
  }

  async setCursor(table: string, value: string): Promise<void> {
    await this.db.execute(
      `INSERT INTO sync_cursor (table_name, server_updated_at) VALUES (?, ?) ON CONFLICT(table_name) DO UPDATE SET server_updated_at = excluded.server_updated_at`,
      [table, value]);
  }
}
