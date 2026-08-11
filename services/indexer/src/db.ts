/**
 * Database layer — PostgreSQL connection + batched routing to typed schemas.
 *
 * Router: each typed collection has a dedicated upsert/delete function that
 * calls the corresponding SQL `*_json` helper. Unknown collections fall back
 * to atproto.records so future/unmapped lexicons still get indexed somewhere.
 *
 * Batching strategy: for a batch of N rows of the same kind, we do one query
 * that calls the `*_json` function N times via UNNEST — 1 round-trip, N calls.
 * Each row is still parsed by the SQL function, so field-mapping stays in the
 * single SQL source of truth (schema_news.sql / schema_dof.sql).
 */

import pg from "pg";

const { Pool } = pg;

let pool: pg.Pool | null = null;

export function getPool(): pg.Pool {
  if (!pool) {
    pool = new Pool({
      connectionString: process.env.DATABASE_URL,
      // 8 conns covers 1 batch flush + a few concurrent reads.
      max: 8,
      idleTimeoutMillis: 30000,
    });
  }
  return pool;
}

// ─── Types ──────────────────────────────────────────────────────────────────

export interface RecordRow {
  uri: string;
  did: string;
  collection: string;
  rkey: string;
  cid?: string;
  record: object;
}

/** Row of a create/update event (from tap firehose) with routing metadata. */
export interface TypedUpsertRow {
  uri: string;
  did: string;
  rkey: string;
  cid: string | null;
  record: object;
  indexedAt: string; // ISO
}

/** Known typed collection kinds. */
export const NEWS_SOURCE       = "tech.transparencia.news.source";
export const NEWS_ARTICLE      = "tech.transparencia.news.article";
export const NEWS_ENRICHMENT   = "tech.transparencia.news.enrichment";
export const DOF_SOURCE        = "tech.transparencia.document.source";
export const DOF_ITEM          = "tech.transparencia.document.item";
export const DOF_NOTE          = "tech.transparencia.document.mxdof.note";
export const DOF_ENRICHMENT    = "tech.transparencia.document.mxdof.note.enrichment";

export const TYPED_COLLECTIONS = new Set<string>([
  NEWS_SOURCE, NEWS_ARTICLE, NEWS_ENRICHMENT,
  DOF_SOURCE, DOF_ITEM, DOF_NOTE, DOF_ENRICHMENT,
]);

// ─── Legacy fallback: atproto.records (for unknown collections) ─────────────

export async function upsertRecords(rows: RecordRow[]): Promise<void> {
  if (rows.length === 0) return;
  const p = getPool();
  const values: string[] = [];
  const params: unknown[] = [];
  rows.forEach((r, i) => {
    const b = i * 6;
    values.push(`($${b+1}, $${b+2}, $${b+3}, $${b+4}, $${b+5}, $${b+6}, NOW())`);
    params.push(r.uri, r.did, r.collection, r.rkey, r.cid ?? null, JSON.stringify(r.record));
  });
  await p.query(
    `INSERT INTO atproto.records (uri, did, collection, rkey, cid, record, indexed_at)
     VALUES ${values.join(",")}
     ON CONFLICT (uri) DO UPDATE SET
       cid = EXCLUDED.cid,
       record = EXCLUDED.record,
       indexed_at = NOW()`,
    params
  );
}

export async function deleteRecords(uris: string[]): Promise<void> {
  if (uris.length === 0) return;
  await getPool().query("DELETE FROM atproto.records WHERE uri = ANY($1)", [uris]);
}

// ─── Typed upsert helpers ───────────────────────────────────────────────────
//
// Shared pattern: UNNEST arrays into a rowset, apply the `_json` function per
// row. Each caller passes rows already extracted from the tap event.

async function callPerRow(
  fnCall: string, // e.g. "news.upsert_source_json(u, d, c, rec::jsonb, ia::timestamptz)"
  columns: string, // "u, d, c, rec, ia"
  types: string[], // matches columns
  cols: unknown[][], // one array per column, all same length
): Promise<void> {
  if (cols[0].length === 0) return;
  const unnestArgs = types.map((t, i) => `$${i + 1}::${t}`).join(", ");
  await getPool().query(
    `SELECT ${fnCall} FROM UNNEST(${unnestArgs}) AS t(${columns})`,
    cols
  );
}

export async function upsertNewsSource(rows: TypedUpsertRow[]): Promise<void> {
  await callPerRow(
    "news.upsert_source_json(t.u, t.d, t.c, t.rec::jsonb, t.ia::timestamptz)",
    "u, d, c, rec, ia",
    ["text[]", "text[]", "text[]", "text[]", "text[]"],
    [
      rows.map(r => r.uri),
      rows.map(r => r.did),
      rows.map(r => r.cid),
      rows.map(r => JSON.stringify(r.record)),
      rows.map(r => r.indexedAt),
    ],
  );
}

export async function upsertNewsArticle(rows: TypedUpsertRow[]): Promise<void> {
  await callPerRow(
    "news.upsert_article_json(t.u, t.d, t.rk, t.c, t.rec::jsonb, t.ia::timestamptz)",
    "u, d, rk, c, rec, ia",
    ["text[]", "text[]", "text[]", "text[]", "text[]", "text[]"],
    [
      rows.map(r => r.uri),
      rows.map(r => r.did),
      rows.map(r => r.rkey),
      rows.map(r => r.cid),
      rows.map(r => JSON.stringify(r.record)),
      rows.map(r => r.indexedAt),
    ],
  );
}

/**
 * Enrichment refresh: keyed by the ARTICLE uri (extracted from record.article.uri).
 * Rows whose record has no article link are skipped.
 */
export async function refreshNewsEnrichment(rows: TypedUpsertRow[]): Promise<void> {
  const valid = rows.filter(r => {
    const rec = r.record as { article?: { uri?: string } };
    return typeof rec?.article?.uri === "string";
  });
  await callPerRow(
    "news.refresh_article_enrichment_json(t.au, t.eu, t.d, t.c, t.rec::jsonb, t.ia::timestamptz)",
    "au, eu, d, c, rec, ia",
    ["text[]", "text[]", "text[]", "text[]", "text[]", "text[]"],
    [
      valid.map(r => (r.record as { article: { uri: string } }).article.uri),
      valid.map(r => r.uri),
      valid.map(r => r.did),
      valid.map(r => r.cid),
      valid.map(r => JSON.stringify(r.record)),
      valid.map(r => r.indexedAt),
    ],
  );
}

export async function upsertDofSource(rows: TypedUpsertRow[]): Promise<void> {
  await callPerRow(
    "dof.upsert_source_json(t.u, t.d, t.c, t.rec::jsonb, t.ia::timestamptz)",
    "u, d, c, rec, ia",
    ["text[]", "text[]", "text[]", "text[]", "text[]"],
    [
      rows.map(r => r.uri),
      rows.map(r => r.did),
      rows.map(r => r.cid),
      rows.map(r => JSON.stringify(r.record)),
      rows.map(r => r.indexedAt),
    ],
  );
}

export async function upsertDofItem(rows: TypedUpsertRow[]): Promise<void> {
  await callPerRow(
    "dof.upsert_item_json(t.u, t.d, t.rk, t.c, t.rec::jsonb, t.ia::timestamptz)",
    "u, d, rk, c, rec, ia",
    ["text[]", "text[]", "text[]", "text[]", "text[]", "text[]"],
    [
      rows.map(r => r.uri),
      rows.map(r => r.did),
      rows.map(r => r.rkey),
      rows.map(r => r.cid),
      rows.map(r => JSON.stringify(r.record)),
      rows.map(r => r.indexedAt),
    ],
  );
}

export async function upsertDofNote(rows: TypedUpsertRow[]): Promise<void> {
  await callPerRow(
    "dof.upsert_note_json(t.u, t.d, t.rk, t.c, t.rec::jsonb, t.ia::timestamptz)",
    "u, d, rk, c, rec, ia",
    ["text[]", "text[]", "text[]", "text[]", "text[]", "text[]"],
    [
      rows.map(r => r.uri),
      rows.map(r => r.did),
      rows.map(r => r.rkey),
      rows.map(r => r.cid),
      rows.map(r => JSON.stringify(r.record)),
      rows.map(r => r.indexedAt),
    ],
  );
}

export async function refreshDofNoteEnrichment(rows: TypedUpsertRow[]): Promise<void> {
  const valid = rows.filter(r => {
    const rec = r.record as { note?: { uri?: string } };
    return typeof rec?.note?.uri === "string";
  });
  await callPerRow(
    "dof.refresh_note_enrichment_json(t.nu, t.eu, t.d, t.c, t.rec::jsonb, t.ia::timestamptz)",
    "nu, eu, d, c, rec, ia",
    ["text[]", "text[]", "text[]", "text[]", "text[]", "text[]"],
    [
      valid.map(r => (r.record as { note: { uri: string } }).note.uri),
      valid.map(r => r.uri),
      valid.map(r => r.did),
      valid.map(r => r.cid),
      valid.map(r => JSON.stringify(r.record)),
      valid.map(r => r.indexedAt),
    ],
  );
}

// ─── Typed delete helpers ───────────────────────────────────────────────────

async function callDelete(fnCall: string, uris: string[]): Promise<void> {
  if (uris.length === 0) return;
  await getPool().query(
    `SELECT ${fnCall} FROM UNNEST($1::text[]) AS t(u)`,
    [uris]
  );
}

export const deleteNewsSource     = (uris: string[]) => callDelete("news.delete_source_json(t.u)", uris);
export const deleteNewsArticle    = (uris: string[]) => callDelete("news.delete_article_json(t.u)", uris);
export const deleteNewsEnrichment = (enrichmentUris: string[]) => callDelete("news.delete_enrichment_json(t.u)", enrichmentUris);
export const deleteDofSource      = (uris: string[]) => callDelete("dof.delete_source_json(t.u)", uris);
export const deleteDofItem        = (uris: string[]) => callDelete("dof.delete_item_json(t.u)", uris);
export const deleteDofNote        = (uris: string[]) => callDelete("dof.delete_note_json(t.u)", uris);
export const deleteDofEnrichment  = (enrichmentUris: string[]) => callDelete("dof.delete_note_enrichment_json(t.u)", enrichmentUris);

// ─── Info ────────────────────────────────────────────────────────────────────

export async function getRecordCount(): Promise<Record<string, number>> {
  const p = getPool();
  const [atp, news, dof] = await Promise.all([
    p.query("SELECT collection, count(*)::int as count FROM atproto.records GROUP BY collection"),
    p.query(`
      SELECT 'news.sources' AS c, count(*)::int as count FROM news.sources
      UNION ALL SELECT 'news.articles',    count(*)::int FROM news.articles
      UNION ALL SELECT 'news.enrichments', count(*)::int FROM news.enrichments
    `),
    p.query(`
      SELECT 'dof.sources' AS c, count(*)::int as count FROM dof.sources
      UNION ALL SELECT 'dof.items',       count(*)::int FROM dof.items
      UNION ALL SELECT 'dof.notes',       count(*)::int FROM dof.notes
      UNION ALL SELECT 'dof.enrichments', count(*)::int FROM dof.enrichments
    `),
  ]);
  const counts: Record<string, number> = {};
  for (const row of atp.rows)  counts[`atproto:${row.collection}`] = row.count;
  for (const row of news.rows) counts[row.c] = row.count;
  for (const row of dof.rows)  counts[row.c] = row.count;
  return counts;
}
