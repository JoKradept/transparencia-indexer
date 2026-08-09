/**
 * lex-gql adapter — translates GraphQL operations to SQL.
 *
 * Sources by collection:
 *   - Known typed collections (news.*, DOF)  → typed schema (news.*, dof.*)
 *   - Anything else                          → atproto.records (fallback)
 *
 * Typed tables all carry the full `record jsonb` for fidelity, so where/sort
 * clauses that go through `record->>'field'` still work — only the FROM
 * source changes. The wins are:
 *   - Reads scan a table with only the relevant collection (no LIKE '%.article').
 *   - Native columns exist for hot fields (topics text[], published_at, etc.),
 *     ready to be wired for GIN/btree hits by a future adapter enhancement.
 */

import { readFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import pg from "pg";
// @ts-ignore
import { parseLexicon, createAdapter as createLexGqlAdapter } from "lex-gql";
import type { GraphQLSchema } from "graphql";

const { Pool } = pg;
const __dirname = dirname(fileURLToPath(import.meta.url));

// ─── Collection → typed table routing ──────────────────────────────────────

type TypedSource = {
  /** Fully-qualified table, e.g. "news.articles". */
  from: string;
  /** Which column holds the AT-URI of the record itself (for filters on `uri`). */
  uriColumn: string;
};

// ponytail: keep in sync with services/indexer/src/db.ts (TYPED_COLLECTIONS).
const TYPED_TABLES: Record<string, TypedSource> = {
  "tech.transparencia.news.source":                       { from: "news.sources",     uriColumn: "uri" },
  "tech.transparencia.news.article":                      { from: "news.articles",    uriColumn: "uri" },
  "tech.transparencia.news.enrichment":                   { from: "news.enrichments", uriColumn: "enrichment_uri" },
  "tech.transparencia.document.source":                   { from: "dof.sources",      uriColumn: "uri" },
  "tech.transparencia.document.item":                     { from: "dof.items",        uriColumn: "uri" },
  "tech.transparencia.document.mxdof.note":               { from: "dof.notes",        uriColumn: "uri" },
  "tech.transparencia.document.mxdof.note.enrichment":    { from: "dof.enrichments",  uriColumn: "enrichment_uri" },
};

function loadLexicons(lexiconDir?: string) {
  const dir = lexiconDir ?? join(__dirname, "..", "lexicons", "lexicons", "tech", "transparencia");
  const files = [
    join(dir, "defs.json"),
    join(dir, "news", "article.json"),
    join(dir, "news", "source.json"),
    join(dir, "news", "enrichment.json"),
  ];
  return files.map((f) => {
    console.log(`Loading lexicon: ${f}`);
    return parseLexicon(JSON.parse(readFileSync(f, "utf-8")));
  });
}

/**
 * Build SQL WHERE clause from lex-gql where conditions.
 * `uriCol` is the column that holds the record's AT-URI on the source table
 * (differs on enrichment tables where the PK is article_uri / note_uri).
 */
function buildWhereClause(
  where: any[],
  collection: string | null,
  params: any[],
  usingTyped: boolean,
  uriCol: string
): string {
  const conditions: string[] = [];

  // Fallback path scans a mixed-collection table, so filter by collection here.
  // Typed tables are already single-collection so this is unnecessary.
  if (!usingTyped && collection && collection !== "*") {
    params.push(collection);
    conditions.push(`collection = $${params.length}`);
  }

  const resolveColumn = (field: string): string => {
    if (field === "uri") return uriCol;
    if (field === "did") return "did";
    if (field === "cid") return "cid";
    if (field === "indexedAt") return "indexed_at";
    if (field === "collection") return usingTyped ? `'${collection}'` : "collection";
    return `record->>'${field}'`;
  };

  for (const clause of where) {
    if (clause.op === "and" || clause.op === "or") {
      const subclauses = clause.conditions.map((group: any[]) => {
        const sub = buildWhereClause(group, null, params, usingTyped, uriCol);
        return `(${sub})`;
      });
      conditions.push(`(${subclauses.join(` ${clause.op.toUpperCase()} `)})`);
      continue;
    }

    const { field, op, value } = clause;
    const column = resolveColumn(field);

    switch (op) {
      case "eq":
        params.push(value);
        conditions.push(`${column} = $${params.length}`);
        break;
      case "in":
        params.push(value);
        conditions.push(`${column} = ANY($${params.length})`);
        break;
      case "contains":
        params.push(`%${value}%`);
        conditions.push(`${column} ILIKE $${params.length}`);
        break;
      case "gt":
        params.push(value);
        conditions.push(`${column} > $${params.length}`);
        break;
      case "gte":
        params.push(value);
        conditions.push(`${column} >= $${params.length}`);
        break;
      case "lt":
        params.push(value);
        conditions.push(`${column} < $${params.length}`);
        break;
      case "lte":
        params.push(value);
        conditions.push(`${column} <= $${params.length}`);
        break;
    }
  }

  return conditions.length > 0 ? conditions.join(" AND ") : "TRUE";
}

function buildOrderBy(sort?: any[], usingTyped = false, uriCol = "uri"): string {
  if (!sort || sort.length === 0) return "ORDER BY indexed_at DESC";

  const clauses = sort.map((s) => {
    let column: string;
    if (s.field === "uri") column = uriCol;
    else if (s.field === "indexedAt") column = "indexed_at";
    else if (["did", "cid"].includes(s.field)) column = s.field;
    else if (s.field === "collection" && usingTyped) column = "'*'"; // no-op
    else column = `record->>'${s.field}'`;
    return `${column} ${s.dir === "asc" ? "ASC" : "DESC"}`;
  });
  return `ORDER BY ${clauses.join(", ")}`;
}

/**
 * Transform a database row into the format lex-gql expects.
 * The record JSONB is spread over the top-level system fields.
 * For typed tables where the URI column is aliased, we assemble `uri` from
 * the alias so lex-gql sees a consistent shape.
 */
function transformRow(row: any, collection: string | null, uriCol: string): any {
  const record = typeof row.record === "string" ? JSON.parse(row.record) : row.record;
  const uri = row[uriCol] ?? row.uri ?? row.enrichment_uri;
  return {
    uri,
    cid: row.cid,
    did: row.did,
    collection: row.collection ?? collection,
    indexedAt: row.indexed_at,
    actorHandle: row.handle || null,
    ...record,
  };
}

export async function createAdapter(options?: { lexiconDir?: string }): Promise<{ schema: GraphQLSchema; execute: (query: string, variables?: any) => Promise<any> }> {
  const pool = new Pool({
    connectionString: process.env.DATABASE_URL,
    max: 10,
    idleTimeoutMillis: 30000,
  });

  const res = await pool.query("SELECT count(*)::int as count FROM atproto.records");
  console.log(`Database connected. atproto.records: ${res.rows[0].count}`);
  console.log(`Typed sources: ${Object.keys(TYPED_TABLES).length}`);

  const lexicons = loadLexicons(options?.lexiconDir);
  console.log(`Loaded ${lexicons.length} lexicons`);

  const adapter = createLexGqlAdapter(lexicons, {
    query: async (operation: any) => {
      const { type } = operation;

      if (type === "findMany") {
        const { collection, where = [], sort, pagination = {} } = operation;
        const params: any[] = [];

        const typed = collection ? TYPED_TABLES[collection] : undefined;
        const usingTyped = !!typed;
        const uriCol = typed?.uriColumn ?? "uri";
        const fromClause = typed ? typed.from : "atproto.records";

        const whereClause = buildWhereClause(where, collection, params, usingTyped, uriCol);
        const orderBy = buildOrderBy(sort, usingTyped, uriCol);

        const limit = (pagination.first || pagination.last || 50) + 1;
        params.push(limit);
        const limitClause = `LIMIT $${params.length}`;

        let cursorClause = "";
        if (pagination.after) {
          try {
            const decoded = Buffer.from(pagination.after, "base64").toString("utf-8");
            params.push(decoded);
            cursorClause = `AND ${uriCol} > $${params.length}`;
          } catch {}
        }

        const sql = `
          SELECT r.*, a.handle
          FROM ${fromClause} r
          LEFT JOIN atproto.actors a ON r.did = a.did
          WHERE ${whereClause} ${cursorClause}
          ${orderBy}
          ${limitClause}
        `;

        const result = await pool.query(sql, params);
        const requestedCount = pagination.first || pagination.last || 50;
        const hasNext = result.rows.length > requestedCount;
        const rows = hasNext ? result.rows.slice(0, requestedCount) : result.rows;

        return {
          rows: rows.map((row) => transformRow(row, collection, uriCol)),
          hasNext,
          hasPrev: !!pagination.after,
          totalCount: undefined,
        };
      }

      if (type === "findManyPartitioned") {
        return null;
      }

      if (type === "aggregate") {
        const { collection, where = [], groupBy } = operation;
        const params: any[] = [];
        const typed = collection ? TYPED_TABLES[collection] : undefined;
        const usingTyped = !!typed;
        const uriCol = typed?.uriColumn ?? "uri";
        const fromClause = typed ? typed.from : "atproto.records";
        const whereClause = buildWhereClause(where, collection, params, usingTyped, uriCol);

        if (groupBy && groupBy.length > 0) {
          const groupField = `record->>'${groupBy[0]}'`;
          const sql = `
            SELECT ${groupField} as group_value, count(*)::int as count
            FROM ${fromClause}
            WHERE ${whereClause}
            GROUP BY ${groupField}
            ORDER BY count DESC
          `;
          const result = await pool.query(sql, params);
          const countSql = `SELECT count(*)::int as count FROM ${fromClause} WHERE ${whereClause}`;
          const countResult = await pool.query(countSql, params);

          return {
            count: countResult.rows[0].count,
            groups: result.rows.map((r: any) => ({
              [groupBy[0]]: r.group_value,
              count: r.count,
            })),
          };
        }

        const sql = `SELECT count(*)::int as count FROM ${fromClause} WHERE ${whereClause}`;
        const result = await pool.query(sql, params);
        return { count: result.rows[0].count, groups: [] };
      }

      console.warn(`Unhandled operation type: ${type}`, operation);
      return { rows: [], hasNext: false, hasPrev: false };
    },
  });

  return {
    schema: adapter.schema,
    execute: adapter.execute.bind(adapter),
  };
}
