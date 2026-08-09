/**
 * Database migration — creates the atproto schema + typed read-models (news, dof).
 * Run once per schema change: docker compose run --rm migrate
 *
 * Order matters:
 *   1. atproto.records (source of truth)
 *   2. schema_news.sql (typed projection + trigger for news.* collections)
 *   3. schema_dof.sql  (typed projection + trigger for DOF collections)
 *
 * Both schema_*.sql are idempotent so re-running is safe.
 */

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { getPool } from "./db.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
// SQL files sit next to package.json (COPY'd into /app in the container).
const SQL_DIR = join(__dirname, "..");

const BASE_SQL = `
CREATE SCHEMA IF NOT EXISTS atproto;

CREATE TABLE IF NOT EXISTS atproto.records (
  uri TEXT PRIMARY KEY,
  did TEXT NOT NULL,
  collection TEXT NOT NULL,
  rkey TEXT NOT NULL,
  cid TEXT,
  record JSONB NOT NULL,
  indexed_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_records_collection ON atproto.records(collection);
CREATE INDEX IF NOT EXISTS idx_records_did ON atproto.records(did);
CREATE INDEX IF NOT EXISTS idx_records_collection_did ON atproto.records(collection, did);
CREATE INDEX IF NOT EXISTS idx_records_indexed_at ON atproto.records(indexed_at DESC);

-- Legacy jsonb-path indexes retained for collections without a typed read-model.
CREATE INDEX IF NOT EXISTS idx_records_language ON atproto.records((record->>'language'))
  WHERE collection LIKE '%.enrichment';
CREATE INDEX IF NOT EXISTS idx_records_emotional_tone ON atproto.records((record->>'emotionalTone'))
  WHERE collection LIKE '%.enrichment';
CREATE INDEX IF NOT EXISTS idx_records_content_domain ON atproto.records((record->>'contentDomain'))
  WHERE collection LIKE '%.enrichment';
CREATE INDEX IF NOT EXISTS idx_records_published_at ON atproto.records((record->>'publishedAt'))
  WHERE collection LIKE '%.article';

CREATE INDEX IF NOT EXISTS idx_records_fts_es ON atproto.records
  USING gin(to_tsvector('spanish', COALESCE(record->>'summary', '')))
  WHERE collection LIKE '%.enrichment' AND record->>'language' = 'es';
CREATE INDEX IF NOT EXISTS idx_records_fts_en ON atproto.records
  USING gin(to_tsvector('english', COALESCE(record->>'summary', '')))
  WHERE collection LIKE '%.enrichment' AND record->>'language' = 'en';

CREATE TABLE IF NOT EXISTS atproto.actors (
  did TEXT PRIMARY KEY,
  handle TEXT NOT NULL,
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS atproto.metadata (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  updated_at TIMESTAMPTZ DEFAULT NOW()
);
`;

async function runStep(pool: ReturnType<typeof getPool>, label: string, sql: string) {
  console.log(`→ ${label}`);
  await pool.query(sql);
}

async function main() {
  console.log("Running migration...");
  const pool = getPool();

  await runStep(pool, "atproto base", BASE_SQL);
  await runStep(pool, "schema_news.sql", readFileSync(join(SQL_DIR, "schema_news.sql"), "utf8"));
  await runStep(pool, "schema_dof.sql",  readFileSync(join(SQL_DIR, "schema_dof.sql"),  "utf8"));

  const res = await pool.query(
    `SELECT schemaname, indexname FROM pg_indexes
       WHERE schemaname IN ('atproto','news','dof')
       ORDER BY schemaname, indexname`
  );
  console.log(`Indexes across atproto/news/dof: ${res.rows.length}`);
  for (const row of res.rows) console.log(`  - ${row.schemaname}.${row.indexname}`);

  await pool.end();
  console.log("Migration complete.");
}

main().catch((err) => {
  console.error("Migration failed:", err);
  process.exit(1);
});
