/**
 * Database layer — PostgreSQL connection and batched record operations.
 */

import pg from "pg";

const { Pool } = pg;

let pool: pg.Pool | null = null;

export function getPool(): pg.Pool {
  if (!pool) {
    pool = new Pool({
      connectionString: process.env.DATABASE_URL,
      // ponytail: 8 conns covers 1 batch flush + a few concurrent reads; bump if
      // getRecordCount + upsert start blocking each other under load.
      max: 8,
      idleTimeoutMillis: 30000,
    });
  }
  return pool;
}

export interface RecordRow {
  uri: string;
  did: string;
  collection: string;
  rkey: string;
  cid?: string;
  record: object;
}

/**
 * Batch upsert. Uses multi-VALUES INSERT so N rows = 1 round-trip + 1 parse.
 * On conflict, refreshes cid, record, indexed_at (same behavior as single upsert).
 * ponytail: parameterized VALUES capped at ~5k rows implicit — Postgres param
 * limit is 65535, we have 6 params/row → ~10k row max. Callers batch <=1k.
 */
export async function upsertRecords(rows: RecordRow[]): Promise<void> {
  if (rows.length === 0) return;
  const pool = getPool();
  const values: string[] = [];
  const params: unknown[] = [];
  rows.forEach((r, i) => {
    const b = i * 6;
    values.push(`($${b+1}, $${b+2}, $${b+3}, $${b+4}, $${b+5}, $${b+6}, NOW())`);
    params.push(r.uri, r.did, r.collection, r.rkey, r.cid ?? null, JSON.stringify(r.record));
  });
  await pool.query(
    `INSERT INTO atproto.records (uri, did, collection, rkey, cid, record, indexed_at)
     VALUES ${values.join(",")}
     ON CONFLICT (uri) DO UPDATE SET
       cid = EXCLUDED.cid,
       record = EXCLUDED.record,
       indexed_at = NOW()`,
    params
  );
}

/** Batch delete. Empty array is a no-op. */
export async function deleteRecords(uris: string[]): Promise<void> {
  if (uris.length === 0) return;
  const pool = getPool();
  await pool.query("DELETE FROM atproto.records WHERE uri = ANY($1)", [uris]);
}

export async function getRecordCount(): Promise<Record<string, number>> {
  const pool = getPool();
  const res = await pool.query(
    "SELECT collection, count(*)::int as count FROM atproto.records GROUP BY collection ORDER BY collection"
  );
  const counts: Record<string, number> = {};
  for (const row of res.rows) counts[row.collection] = row.count;
  return counts;
}
