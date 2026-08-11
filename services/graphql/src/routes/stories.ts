// GET /api/stories?q=&limit=          → { stats, stories: [...] }
// GET /api/stories/<story_id>          → { story_id, articles: [...] }
//
// Cheap HTTP endpoint over the materialized atproto.stories table so front-ends
// don't open Postgres connections per request (Vercel/serverless killer). The
// data behind these routes only changes when the systemd timer refreshes the
// stories table (every 10 min), so aggressive HTTP caching is safe:
//   s-maxage=600 = CDN keeps it 10 min (matches rebuild cadence)
//   stale-while-revalidate=60 = one stale hit while refresh happens
//
// Public CORS. If the endpoint ever grows a private surface, split it.

import type { IncomingMessage, ServerResponse } from "node:http";
import type pg from "pg";

const CACHE_HEADER = "public, s-maxage=600, stale-while-revalidate=60";

function json(res: ServerResponse, body: unknown, status = 200, extraHeaders: Record<string, string> = {}) {
  res.writeHead(status, {
    "Content-Type": "application/json; charset=utf-8",
    "Access-Control-Allow-Origin": "*",
    "Cache-Control": status === 200 ? CACHE_HEADER : "no-store",
    ...extraHeaders,
  });
  res.end(JSON.stringify(body));
}

async function listStories(pool: pg.Pool, q: string | undefined, limit: number, offset: number) {
  // No size filter — surfacing singletons too so the user can browse past the
  // "most-covered" head. Sort keeps multi-article stories first naturally.
  const params: (string | number)[] = [];
  const clauses: string[] = [];
  if (q) {
    params.push(`%${q}%`);
    clauses.push(`(best_title ILIKE $${params.length} OR EXISTS (SELECT 1 FROM unnest(top_topics) t WHERE t ILIKE $${params.length}))`);
  }
  params.push(limit);
  const limitPh = `$${params.length}`;
  params.push(offset);
  const offsetPh = `$${params.length}`;
  const { rows } = await pool.query(
    `SELECT story_id, size, first_seen, last_seen, sample_titles, best_title, top_topics
       FROM atproto.stories
      ${clauses.length ? `WHERE ${clauses.join(" AND ")}` : ""}
      ORDER BY size DESC, last_seen DESC
      LIMIT ${limitPh} OFFSET ${offsetPh}`,
    params,
  );
  return rows;
}

async function stats(pool: pg.Pool) {
  const { rows } = await pool.query(
    `SELECT COALESCE(SUM(size), 0)::int                            AS articles,
            COUNT(*)::int                                          AS stories,
            COALESCE(SUM(size) FILTER (WHERE size > 1), 0)::int    AS multi
       FROM atproto.stories`,
  );
  return rows[0];
}

async function storyDetail(pool: pg.Pool, storyId: string) {
  const [{ rows: [head] }, { rows: articles }] = await Promise.all([
    pool.query(
      `SELECT story_id, size, first_seen, last_seen, sample_titles, best_title, top_topics
         FROM atproto.stories WHERE story_id = $1`,
      [storyId],
    ),
    pool.query(
      `SELECT s.article_uri,
              a.title,
              a.url,
              a.source_uri,
              a.published_at,
              s.jaccard_score,
              s.created_at
         FROM atproto.article_story s
         JOIN news.articles a ON a.uri = s.article_uri
        WHERE s.story_id = $1
        ORDER BY s.created_at ASC`,
      [storyId],
    ),
  ]);
  if (!head) return null;
  return { ...head, articles };
}

export async function handleStoriesRoute(
  req: IncomingMessage,
  res: ServerResponse,
  pool: pg.Pool,
): Promise<void> {
  if (req.method === "OPTIONS") {
    res.writeHead(204, {
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Methods": "GET, OPTIONS",
      "Access-Control-Allow-Headers": "Content-Type",
    });
    res.end();
    return;
  }
  if (req.method !== "GET") return json(res, { error: "method not allowed" }, 405);

  try {
    const url = new URL(req.url ?? "/", `http://${req.headers.host ?? "localhost"}`);
    const parts = url.pathname.replace(/\/+$/, "").split("/").filter(Boolean);
    // ["api", "stories"] → list; ["api", "stories", "<id>"] → detail
    const id = parts[2];

    if (id) {
      const detail = await storyDetail(pool, id);
      if (!detail) return json(res, { error: "not found" }, 404);
      return json(res, detail);
    }

    const q = url.searchParams.get("q")?.trim() || undefined;
    const limitRaw = Number(url.searchParams.get("limit") ?? 50);
    const limit = Math.min(200, Math.max(1, Number.isFinite(limitRaw) ? limitRaw : 50));
    const offsetRaw = Number(url.searchParams.get("offset") ?? 0);
    const offset = Math.max(0, Number.isFinite(offsetRaw) ? offsetRaw : 0);

    const [statsRow, stories] = await Promise.all([stats(pool), listStories(pool, q, limit, offset)]);
    return json(res, { stats: statsRow, stories, limit, offset });
  } catch (err) {
    json(res, { error: (err as Error).message }, 500);
  }
}
