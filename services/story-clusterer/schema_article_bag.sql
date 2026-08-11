-- Prototype: article-bag clustering (no enrichment required).
--
-- Extracts a keyword/phrase bag directly from title + description + content
-- of a news.articles row using a RAKE-lite algorithm:
--   1. Concat + lowercase + strip HTML tags.
--   2. Split into tokens on non-word chars.
--   3. Drop stopwords + tokens < 3 chars.
--   4. Cut into phrases (contiguous non-stopword runs).
--   5. Rank phrases by frequency × length; return top 20.
--
-- ponytail: single-file plpgsql prototype. Doesn't beat AI enrichment for
-- semantic dedup, but works for 100% of news.articles (vs 5% today) and
-- costs zero — no extra containers, no external calls. Upgrade path:
-- embeddings + pgvector (see services/story-clusterer/README.md).

-- ─── Spanish stopwords (compact list, RAE + common noise) ───────────────
CREATE OR REPLACE FUNCTION atproto._spanish_stopwords() RETURNS text[]
LANGUAGE sql IMMUTABLE AS $$
  SELECT ARRAY[
    'de','la','que','el','en','y','a','los','del','se','las','por','un','para',
    'con','no','una','su','al','lo','como','más','pero','sus','le','ya','o',
    'este','sí','porque','esta','entre','cuando','muy','sin','sobre','también',
    'me','hasta','hay','donde','quien','desde','todo','nos','durante','todos',
    'uno','les','ni','contra','otros','ese','eso','ante','ellos','e','esto',
    'mí','antes','algunos','qué','unos','yo','otro','otras','otra','él','tanto',
    'esa','estos','mucho','quienes','nada','muchos','cual','poco','ella','estar',
    'estas','algunas','algo','nosotros','mi','mis','tú','te','ti','tu','tus',
    'ellas','nosotras','vosotros','vosotras','os','mío','mía','míos','mías',
    'tuyo','tuya','tuyos','tuyas','suyo','suya','suyos','suyas','nuestro',
    'nuestra','nuestros','nuestras','vuestro','vuestra','vuestros','vuestras',
    'esos','esas','estoy','estás','está','estamos','estáis','están','esté',
    'estés','estemos','estéis','estén','estaré','estarás','estará','estaremos',
    'estaréis','estarán','estaría','estarías','estaríamos','estaríais','estarían',
    'estaba','estabas','estábamos','estabais','estaban','estuve','estuviste',
    'estuvo','estuvimos','estuvisteis','estuvieron','estuviera','estuvieras',
    'estuviéramos','estuvierais','estuvieran','estuviese','estuvieses',
    'estuviésemos','estuvieseis','estuviesen','estando','estado','estada',
    'estados','estadas','estad','he','has','ha','hemos','habéis','han','haya',
    'hayas','hayamos','hayáis','hayan','habré','habrás','habrá','habremos',
    'habréis','habrán','habría','habrías','habríamos','habríais','habrían',
    'había','habías','habíamos','habíais','habían','hube','hubiste','hubo',
    'hubimos','hubisteis','hubieron','hubiera','hubieras','hubiéramos',
    'hubierais','hubieran','hubiese','hubieses','hubiésemos','hubieseis',
    'hubiesen','habiendo','habido','habida','habidos','habidas','soy','eres',
    'es','somos','sois','son','sea','seas','seamos','seáis','sean','seré',
    'serás','será','seremos','seréis','serán','sería','serías','seríamos',
    'seríais','serían','era','eras','éramos','erais','eran','fui','fuiste',
    'fue','fuimos','fuisteis','fueron','fuera','fueras','fuéramos','fuerais',
    'fueran','fuese','fueses','fuésemos','fueseis','fuesen','siendo','sido',
    'tengo','tienes','tiene','tenemos','tenéis','tienen','tenga','tengas',
    'tengamos','tengáis','tengan','tendré','tendrás','tendrá','tendremos',
    'tendréis','tendrán','tendría','tendrías','tendríamos','tendríais',
    'tendrían','tenía','tenías','teníamos','teníais','tenían','tuve','tuviste',
    'tuvo','tuvimos','tuvisteis','tuvieron','tuviera','tuvieras','tuviéramos',
    'tuvierais','tuvieran','tuviese','tuvieses','tuviésemos','tuvieseis',
    'tuviesen','teniendo','tenido','tenida','tenidos','tenidas','tened',
    -- news-noise
    'según','tras','luego','durante','mediante','ayer','hoy','mañana','año',
    'años','día','días','mes','meses','semana','vez','veces','tiempo','vida',
    'gente','forma','parte','manera','caso','casos','ejemplo','trabajo','país',
    'países','ciudad','estado','estados','gobierno','presidente','ministro',
    'foto','video','imagen','imágenes','crédito','fuente','archivo','nota',
    'noticia','noticias','artículo','artículos','reporte','informe','texto'
  ];
$$;

-- ─── article_bag(): the extractor ────────────────────────────────────────
CREATE OR REPLACE FUNCTION atproto.article_bag(
  p_title       text,
  p_description text,
  p_content     text,
  p_max_phrases int DEFAULT 20
) RETURNS text[]
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  v_text      text;
  v_stopwords text[] := atproto._spanish_stopwords();
BEGIN
  v_text := coalesce(p_title,'') || '. ' || coalesce(p_description,'') || '. ' || coalesce(p_content,'');
  -- strip HTML tags + entities
  v_text := regexp_replace(v_text, '<[^>]+>', ' ', 'g');
  v_text := regexp_replace(v_text, '&[a-z]+;', ' ', 'g');
  v_text := lower(v_text);
  -- normalize whitespace
  v_text := regexp_replace(v_text, '\s+', ' ', 'g');

  RETURN ARRAY(
    -- Split into tokens, mark stopwords/short as phrase-breakers (NULL).
    WITH tokens AS (
      SELECT
        w,
        ord,
        CASE WHEN length(w) < 3 OR w = ANY(v_stopwords) OR w ~ '^\d+$'
             THEN NULL ELSE w END AS keep
      FROM regexp_split_to_table(v_text, '[^a-záéíóúñü0-9]+') WITH ORDINALITY AS t(w, ord)
    ),
    -- Group contiguous non-null tokens into a phrase id (grp).
    grouped AS (
      SELECT
        keep,
        ord,
        SUM(CASE WHEN keep IS NULL THEN 1 ELSE 0 END) OVER (ORDER BY ord) AS grp
      FROM tokens
    ),
    phrases AS (
      SELECT
        string_agg(keep, ' ' ORDER BY ord) AS phrase,
        count(*)                            AS wc
      FROM grouped
      WHERE keep IS NOT NULL
      GROUP BY grp
    ),
    scored AS (
      SELECT
        phrase,
        count(*)::int                    AS freq,
        max(wc)::int                     AS word_count,
        count(*)::int * max(wc)::int     AS score
      FROM phrases
      WHERE length(phrase) BETWEEN 3 AND 80
      GROUP BY phrase
    )
    SELECT phrase
    FROM scored
    ORDER BY score DESC, freq DESC, word_count DESC
    LIMIT p_max_phrases
  );
END;
$$;

-- ─── Cache table so clustering doesn't recompute per run ────────────────
CREATE TABLE IF NOT EXISTS atproto.article_bag_cache (
  article_uri  text PRIMARY KEY,
  bag          text[] NOT NULL,
  created_at   timestamptz NOT NULL,   -- article's published_at
  computed_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_article_bag_cache_created ON atproto.article_bag_cache (created_at);
CREATE INDEX IF NOT EXISTS idx_article_bag_cache_bag_gin ON atproto.article_bag_cache USING GIN (bag);

-- ─── Populate cache incrementally ────────────────────────────────────────
CREATE OR REPLACE FUNCTION atproto.rebuild_article_bags(
  p_batch_size int DEFAULT 1000,
  p_max_batches int DEFAULT 100
) RETURNS TABLE(added int, remaining int)
LANGUAGE plpgsql AS $$
DECLARE
  v_added   int := 0;
  v_last    int := 0;
  v_i       int := 0;
BEGIN
  LOOP
    v_i := v_i + 1;
    EXIT WHEN v_i > p_max_batches;

    WITH candidates AS (
      SELECT a.uri, a.published_at, a.title,
             a.record->>'description' AS description,
             a.record->>'content'     AS content
      FROM news.articles a
      WHERE NOT EXISTS (SELECT 1 FROM atproto.article_bag_cache c WHERE c.article_uri = a.uri)
        AND a.published_at IS NOT NULL
      ORDER BY a.published_at DESC
      LIMIT p_batch_size
    ),
    inserted AS (
      INSERT INTO atproto.article_bag_cache (article_uri, bag, created_at)
      SELECT c.uri,
             atproto.article_bag(c.title, c.description, c.content),
             c.published_at
      FROM candidates c
      ON CONFLICT (article_uri) DO NOTHING
      RETURNING 1
    )
    SELECT count(*) INTO v_last FROM inserted;

    v_added := v_added + v_last;
    EXIT WHEN v_last = 0;
  END LOOP;

  RETURN QUERY SELECT v_added,
                      (SELECT count(*)::int
                         FROM news.articles a
                        WHERE a.published_at IS NOT NULL
                          AND NOT EXISTS (SELECT 1 FROM atproto.article_bag_cache c WHERE c.article_uri = a.uri));
END;
$$;

-- ─── Cluster from article bags (parallel track to enrichment clustering) ─
-- Writes to a SEPARATE table so we can compare the two clusterings side by
-- side without stomping each other's assignments.

CREATE TABLE IF NOT EXISTS atproto.article_story_v2 (
  article_uri   text PRIMARY KEY,
  story_id      text NOT NULL,
  jaccard_score real NOT NULL,
  entity_bag    text[] NOT NULL,
  created_at    timestamptz NOT NULL,
  computed_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_article_story_v2_story    ON atproto.article_story_v2 (story_id);
CREATE INDEX IF NOT EXISTS idx_article_story_v2_created  ON atproto.article_story_v2 (created_at);
CREATE INDEX IF NOT EXISTS idx_article_story_v2_bag_gin  ON atproto.article_story_v2 USING GIN (entity_bag);

CREATE OR REPLACE FUNCTION atproto.cluster_stories_v2(
  since         timestamptz DEFAULT '2000-01-01'::timestamptz,
  min_jaccard   real DEFAULT 0.35,
  min_bag_size  int  DEFAULT 3,
  window_hours  int  DEFAULT 72
) RETURNS TABLE(processed int, skipped_small int, new_clusters int, joined_existing int)
LANGUAGE plpgsql AS $$
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
  FOR r IN
    SELECT c.article_uri, c.created_at AS created, c.bag
    FROM atproto.article_bag_cache c
    WHERE c.created_at >= since
      AND NOT EXISTS (SELECT 1 FROM atproto.article_story_v2 s WHERE s.article_uri = c.article_uri)
    ORDER BY c.created_at ASC
  LOOP
    cnt_processed := cnt_processed + 1;
    IF cardinality(r.bag) < min_bag_size THEN
      cnt_skipped := cnt_skipped + 1;
      CONTINUE;
    END IF;

    SELECT s.story_id, max(atproto.jaccard_text(r.bag, s.entity_bag))
      INTO best_story, best_score
    FROM atproto.article_story_v2 s
    WHERE s.created_at BETWEEN r.created - (window_hours || ' hours')::interval
                           AND r.created + (window_hours || ' hours')::interval
      AND s.entity_bag && r.bag
    GROUP BY s.story_id
    ORDER BY max(atproto.jaccard_text(r.bag, s.entity_bag)) DESC
    LIMIT 1;

    IF best_score IS NOT NULL AND best_score >= min_jaccard THEN
      INSERT INTO atproto.article_story_v2 (article_uri, story_id, jaccard_score, entity_bag, created_at)
      VALUES (r.article_uri, best_story, best_score, r.bag, r.created)
      ON CONFLICT (article_uri) DO NOTHING;
      cnt_joined := cnt_joined + 1;
    ELSE
      new_story := 'story_' || replace(gen_random_uuid()::text, '-', '');
      INSERT INTO atproto.article_story_v2 (article_uri, story_id, jaccard_score, entity_bag, created_at)
      VALUES (r.article_uri, new_story, 1.0, r.bag, r.created)
      ON CONFLICT (article_uri) DO NOTHING;
      cnt_new := cnt_new + 1;
    END IF;
  END LOOP;

  RETURN QUERY SELECT cnt_processed, cnt_skipped, cnt_new, cnt_joined;
END;
$$;
