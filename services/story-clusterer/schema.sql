-- Story clustering (Strategy A: Jaccard overlap of entity bags, 72h window).
-- Idempotent. Safe to re-run.

CREATE TABLE IF NOT EXISTS atproto.article_story (
  article_uri   text PRIMARY KEY,
  story_id      text NOT NULL,
  jaccard_score real NOT NULL,
  entity_bag    text[] NOT NULL,
  created_at    timestamptz NOT NULL,
  computed_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_article_story_story    ON atproto.article_story (story_id);
CREATE INDEX IF NOT EXISTS idx_article_story_created  ON atproto.article_story (created_at);
CREATE INDEX IF NOT EXISTS idx_article_story_bag_gin  ON atproto.article_story USING GIN (entity_bag);

-- Entity bag: topics ∪ relatedKeywords ∪ people.name ∪ organizationEntities.name,
-- normalized (lower, trimmed, dedup).
CREATE OR REPLACE FUNCTION atproto.enrichment_bag(rec jsonb) RETURNS text[] AS $$
  SELECT COALESCE(
    ARRAY(
      SELECT DISTINCT lower(btrim(x))
      FROM (
        SELECT jsonb_array_elements_text(COALESCE(rec->'topics', '[]'::jsonb)) AS x
        UNION ALL
        SELECT jsonb_array_elements_text(COALESCE(rec->'relatedKeywords', '[]'::jsonb))
        UNION ALL
        SELECT e->>'name' FROM jsonb_array_elements(COALESCE(rec->'people', '[]'::jsonb)) e
        UNION ALL
        SELECT e->>'name' FROM jsonb_array_elements(COALESCE(rec->'organizationEntities', '[]'::jsonb)) e
      ) t
      WHERE x IS NOT NULL AND btrim(x) <> ''
    ),
    '{}'::text[]
  );
$$ LANGUAGE SQL IMMUTABLE;

-- Jaccard similarity between two text arrays.
CREATE OR REPLACE FUNCTION atproto.jaccard_text(a text[], b text[]) RETURNS real AS $$
  SELECT CASE
    WHEN cardinality(a) = 0 OR cardinality(b) = 0 THEN 0::real
    ELSE (
      SELECT count(*)::real FROM (SELECT unnest(a) INTERSECT SELECT unnest(b)) t
    ) / NULLIF(
      (SELECT count(*)::real FROM (SELECT unnest(a) UNION SELECT unnest(b)) t),
      0
    )
  END;
$$ LANGUAGE SQL IMMUTABLE;

-- Greedy clustering pass. Iterates unclustered enrichments in createdAt order,
-- assigns each to the best-matching cluster within a ±window_hours horizon
-- if max jaccard ≥ min_jaccard, otherwise starts a new cluster.
--
-- Prefilter via GIN `entity_bag && r.bag` keeps per-iteration cost low.
CREATE OR REPLACE FUNCTION atproto.cluster_stories(
  since         timestamptz DEFAULT '2000-01-01'::timestamptz,
  min_jaccard   real DEFAULT 0.35,
  min_bag_size  int  DEFAULT 3,
  window_hours  int  DEFAULT 72
) RETURNS TABLE(processed int, skipped_small int, new_clusters int, joined_existing int) AS $$
DECLARE
  r record;
  best_story  text;
  best_score  real;
  new_story   text;
  cnt_processed int := 0;
  cnt_skipped   int := 0;
  cnt_new       int := 0;
  cnt_joined    int := 0;
BEGIN
  -- Reads news.enrichments (typed read-model). Requires the news schema
  -- from services/indexer/schema_news.sql. Under the Fase 3b router,
  -- atproto.records no longer receives enrichment writes, so scanning it
  -- here would miss everything published after the cutover.
  FOR r IN
    SELECT rec.article_uri AS article_uri,
           rec.created_at  AS created,
           atproto.enrichment_bag(rec.record) AS bag
    FROM news.enrichments rec
    WHERE rec.created_at >= since
      AND rec.article_uri IS NOT NULL
      AND NOT EXISTS (
        SELECT 1 FROM atproto.article_story s
        WHERE s.article_uri = rec.article_uri
      )
    ORDER BY rec.created_at ASC
  LOOP
    cnt_processed := cnt_processed + 1;
    IF cardinality(r.bag) < min_bag_size THEN
      cnt_skipped := cnt_skipped + 1;
      CONTINUE;
    END IF;

    -- Best matching existing cluster in window.
    SELECT s.story_id, max(atproto.jaccard_text(r.bag, s.entity_bag))
      INTO best_story, best_score
    FROM atproto.article_story s
    WHERE s.created_at BETWEEN r.created - (window_hours || ' hours')::interval
                           AND r.created + (window_hours || ' hours')::interval
      AND s.entity_bag && r.bag
    GROUP BY s.story_id
    ORDER BY max(atproto.jaccard_text(r.bag, s.entity_bag)) DESC
    LIMIT 1;

    IF best_score IS NOT NULL AND best_score >= min_jaccard THEN
      INSERT INTO atproto.article_story
        (article_uri, story_id, jaccard_score, entity_bag, created_at)
      VALUES (r.article_uri, best_story, best_score, r.bag, r.created)
      ON CONFLICT (article_uri) DO NOTHING;
      cnt_joined := cnt_joined + 1;
    ELSE
      new_story := 'story_' || replace(gen_random_uuid()::text, '-', '');
      INSERT INTO atproto.article_story
        (article_uri, story_id, jaccard_score, entity_bag, created_at)
      VALUES (r.article_uri, new_story, 1.0, r.bag, r.created)
      ON CONFLICT (article_uri) DO NOTHING;
      cnt_new := cnt_new + 1;
    END IF;
  END LOOP;

  RETURN QUERY SELECT cnt_processed, cnt_skipped, cnt_new, cnt_joined;
END;
$$ LANGUAGE plpgsql;
