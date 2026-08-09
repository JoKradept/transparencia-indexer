-- ============================================================================
-- news read-model: typed projection of atproto.records for fast tracking queries
-- ----------------------------------------------------------------------------
-- Ported from transparencia-web-v2/migrations/2026-06-04-news-readmodel.sql
-- (originally designed for Supabase). Adapted for the indexer's Postgres:
--   - Dropped SECURITY DEFINER + search_path (no Supabase Auth here).
--   - Dropped RLS + anon/authenticated grants (single-tenant DB).
--   - Dropped postgis geom column + geo indexes (base postgres:16 image has
--     no postgis; lat/lng columns remain for future geo upgrade).
--
-- atproto.records (fed by the indexer from the AT Protocol firehose) is the
-- source of truth today. Everything in schema `news` is derived and disposable:
-- if it drifts, run `select news.rebuild_all();`. A defensive trigger keeps it
-- in sync incrementally; a projection failure NEVER aborts the base insert.
--
-- Benchmark from the Supabase original (globe/map query, no filters, es + primary):
--   jsonb runtime extraction on atproto.records .......................... 27,469 ms
--   flat indexed read-model ................................................ 182 ms
-- ============================================================================

create schema if not exists news;

-- ─── Supporting index on the source table (non-destructive) ─────────────────
-- Lets news.refresh_article_enrichment() find an article's latest enrichment
-- without scanning all 26k enrichment records.
create index if not exists idx_enr_article_uri
  on atproto.records ((record->'article'->>'uri'))
  where collection = 'tech.transparencia.news.enrichment';

-- ─── Tables ─────────────────────────────────────────────────────────────────

create table if not exists news.sources (
  uri          text primary key,
  did          text not null,
  cid          text,
  name         text,
  display_name text,
  base_url     text,
  country      text,
  language     text,
  cms          text,
  feed_urls    jsonb,
  created_at   timestamptz,
  record       jsonb not null,
  indexed_at   timestamptz
);

create table if not exists news.articles (
  uri           text primary key,
  did           text not null,
  rkey          text,
  cid           text,
  source_uri    text,
  title         text,
  url           text,
  guid          text,
  author        text,
  image_url     text,
  language      text,
  feed_category text,
  tags          jsonb,
  published_at  timestamptz,
  created_at    timestamptz,
  record        jsonb not null,   -- keeps full fidelity (content HTML, etc.)
  indexed_at    timestamptz
);

-- One row per article = its most recent enrichment (kills the DISTINCT ON).
create table if not exists news.enrichments (
  article_uri            text primary key,
  enrichment_uri         text not null,
  did                    text,
  cid                    text,
  summary                text,
  neutral_headline       text,
  political_orientation  text,
  orientation_confidence numeric,
  emotional_tone         text,
  impact_level           int,
  clickbait_score        int,
  fact_checkability      int,
  content_domain         text,
  event_type             text,
  region                 text,
  reading_level          text,
  language               text,
  topics                 text[],
  model_used             text,
  cost_usd               numeric,
  created_at             timestamptz,
  record                 jsonb not null,
  indexed_at             timestamptz
);

-- locations[] pre-exploded → globe / map
create table if not exists news.article_locations (
  article_uri  text not null,
  idx          int  not null,
  name         text,
  state        text,
  country      text,
  country_code text,
  relevance    text,
  lat          double precision,
  lng          double precision,
  primary key (article_uri, idx)
);

-- organizationEntities[] + people[] pre-exploded → actor graphs / coverage
create table if not exists news.article_entities (
  article_uri     text not null,
  kind            text not null,           -- 'organization' | 'person'
  idx             int  not null,
  name            text,
  entity_id       text,
  entity_id_type  text,
  role            text,
  sector          text,
  relevance       text,
  sentiment       text,
  sentiment_score numeric,
  primary key (article_uri, kind, idx)
);

-- ─── Indexes (read paths) ───────────────────────────────────────────────────
create index if not exists idx_news_articles_source     on news.articles (source_uri);
create index if not exists idx_news_articles_published   on news.articles (published_at desc);
create index if not exists idx_news_articles_language    on news.articles (language);

create index if not exists idx_news_enr_orientation      on news.enrichments (political_orientation);
create index if not exists idx_news_enr_domain           on news.enrichments (content_domain);
create index if not exists idx_news_enr_event_type       on news.enrichments (event_type);
create index if not exists idx_news_enr_impact           on news.enrichments (impact_level);
create index if not exists idx_news_enr_region           on news.enrichments (region);
create index if not exists idx_news_enr_lang_pat         on news.enrichments (language text_pattern_ops);
create index if not exists idx_news_enr_topics           on news.enrichments using gin (topics);

create index if not exists idx_news_loc_country          on news.article_locations (country_code);
create index if not exists idx_news_loc_state            on news.article_locations (lower(state));
create index if not exists idx_news_loc_relevance        on news.article_locations (relevance);

create index if not exists idx_news_ent_entity_id        on news.article_entities (entity_id);
create index if not exists idx_news_ent_name             on news.article_entities (lower(name));
create index if not exists idx_news_ent_kind             on news.article_entities (kind);

-- Covering indexes for the globe/map hot path: let the 3-way join run as
-- index-only scans (Heap Fetches: 0), so it never touches the fat `record`
-- jsonb heap rows. Brings the query from ~1.5s (cold pkey heap lookups) to ~230ms.
create index if not exists idx_news_articles_card on news.articles (uri)
  include (title, url, image_url, published_at, source_uri, language, feed_category);
create index if not exists idx_news_enr_card on news.enrichments (language text_pattern_ops)
  include (article_uri, political_orientation, emotional_tone, content_domain,
           event_type, impact_level, fact_checkability, region);
create index if not exists idx_news_loc_primary on news.article_locations (relevance)
  include (article_uri, lat, lng, name, state, country, country_code);

-- ─── Projection helpers (SECURITY DEFINER so trigger writes bypass RLS) ──────

create or replace function news.upsert_source(p_uri text)
returns void language sql as $$
  insert into news.sources (uri, did, cid, name, display_name, base_url,
                            country, language, cms, feed_urls, created_at, record, indexed_at)
  select r.uri, r.did, r.cid,
         r.record->>'name', r.record->>'displayName', r.record->>'baseUrl',
         r.record->>'country', r.record->>'language', r.record->>'cms',
         r.record->'feedUrls',
         nullif(r.record->>'createdAt','')::timestamptz,
         r.record, r.indexed_at
  from atproto.records r
  where r.uri = p_uri
  on conflict (uri) do update set
    did=excluded.did, cid=excluded.cid, name=excluded.name,
    display_name=excluded.display_name, base_url=excluded.base_url,
    country=excluded.country, language=excluded.language, cms=excluded.cms,
    feed_urls=excluded.feed_urls, created_at=excluded.created_at,
    record=excluded.record, indexed_at=excluded.indexed_at;
$$;

create or replace function news.upsert_article(p_uri text)
returns void language sql as $$
  insert into news.articles (uri, did, rkey, cid, source_uri, title, url, guid,
                             author, image_url, language, feed_category, tags,
                             published_at, created_at, record, indexed_at)
  select r.uri, r.did, r.rkey, r.cid,
         r.record->'source'->>'uri',
         r.record->>'title', r.record->>'url', r.record->>'guid',
         r.record->>'author', r.record->>'imageUrl', r.record->>'language',
         r.record->>'feedCategory',
         case when jsonb_typeof(r.record->'tags')='array' then r.record->'tags' end,
         nullif(r.record->>'publishedAt','')::timestamptz,
         nullif(r.record->>'createdAt','')::timestamptz,
         r.record, r.indexed_at
  from atproto.records r
  where r.uri = p_uri
  on conflict (uri) do update set
    did=excluded.did, rkey=excluded.rkey, cid=excluded.cid,
    source_uri=excluded.source_uri, title=excluded.title, url=excluded.url,
    guid=excluded.guid, author=excluded.author, image_url=excluded.image_url,
    language=excluded.language, feed_category=excluded.feed_category,
    tags=excluded.tags, published_at=excluded.published_at,
    created_at=excluded.created_at, record=excluded.record, indexed_at=excluded.indexed_at;
$$;

-- Recompute the projected enrichment + child rows for one article, always from
-- the source of truth (picks the most recent enrichment record). Idempotent.
create or replace function news.refresh_article_enrichment(p_article_uri text)
returns void language plpgsql as $$
declare
  v_uri text; v_rec jsonb; v_indexed timestamptz; v_did text; v_cid text;
begin
  if p_article_uri is null then return; end if;

  select r.uri, r.record, r.indexed_at, r.did, r.cid
    into v_uri, v_rec, v_indexed, v_did, v_cid
  from atproto.records r
  where r.collection = 'tech.transparencia.news.enrichment'
    and r.record->'article'->>'uri' = p_article_uri
  order by r.indexed_at desc nulls last
  limit 1;

  delete from news.article_locations where article_uri = p_article_uri;
  delete from news.article_entities  where article_uri = p_article_uri;

  if v_uri is null then
    delete from news.enrichments where article_uri = p_article_uri;
    return;
  end if;

  insert into news.enrichments (article_uri, enrichment_uri, did, cid, summary,
    neutral_headline, political_orientation, orientation_confidence, emotional_tone,
    impact_level, clickbait_score, fact_checkability, content_domain, event_type,
    region, reading_level, language, topics, model_used, cost_usd, created_at,
    record, indexed_at)
  values (p_article_uri, v_uri, v_did, v_cid, v_rec->>'summary',
    v_rec->>'neutralHeadline', v_rec->>'politicalOrientation',
    nullif(v_rec->>'orientationConfidence','')::numeric, v_rec->>'emotionalTone',
    nullif(v_rec->>'impactLevel','')::int, nullif(v_rec->>'clickbaitScore','')::int,
    nullif(v_rec->>'factCheckability','')::int, v_rec->>'contentDomain',
    v_rec->>'eventType', v_rec->>'region', v_rec->>'readingLevel', v_rec->>'language',
    case when jsonb_typeof(v_rec->'topics')='array'
         then array(select jsonb_array_elements_text(v_rec->'topics')) end,
    v_rec->>'modelUsed', nullif(v_rec->>'costUsd','')::numeric,
    nullif(v_rec->>'createdAt','')::timestamptz, v_rec, v_indexed)
  on conflict (article_uri) do update set
    enrichment_uri=excluded.enrichment_uri, did=excluded.did, cid=excluded.cid,
    summary=excluded.summary, neutral_headline=excluded.neutral_headline,
    political_orientation=excluded.political_orientation,
    orientation_confidence=excluded.orientation_confidence,
    emotional_tone=excluded.emotional_tone, impact_level=excluded.impact_level,
    clickbait_score=excluded.clickbait_score, fact_checkability=excluded.fact_checkability,
    content_domain=excluded.content_domain, event_type=excluded.event_type,
    region=excluded.region, reading_level=excluded.reading_level,
    language=excluded.language, topics=excluded.topics, model_used=excluded.model_used,
    cost_usd=excluded.cost_usd, created_at=excluded.created_at,
    record=excluded.record, indexed_at=excluded.indexed_at;

  insert into news.article_locations (article_uri, idx, name, state, country,
    country_code, relevance, lat, lng)
  select p_article_uri, (ord-1)::int, loc->>'name', loc->>'state', loc->>'country',
    upper(nullif(loc->>'countryCode','')), loc->>'relevance',
    nullif(loc->>'lat','')::double precision, nullif(loc->>'lng','')::double precision
  from jsonb_array_elements(v_rec->'locations') with ordinality as t(loc, ord)
  where jsonb_typeof(v_rec->'locations') = 'array';

  insert into news.article_entities (article_uri, kind, idx, name, entity_id,
    entity_id_type, role, sector, relevance, sentiment, sentiment_score)
  select p_article_uri, 'organization', (ord-1)::int, e->>'name', e->>'entityId',
    e->>'entityIdType', e->>'role', e->>'sector', e->>'relevance', e->>'sentiment',
    nullif(e->>'sentimentScore','')::numeric
  from jsonb_array_elements(v_rec->'organizationEntities') with ordinality as t(e, ord)
  where jsonb_typeof(v_rec->'organizationEntities') = 'array';

  insert into news.article_entities (article_uri, kind, idx, name, entity_id,
    entity_id_type, role, sector, relevance, sentiment, sentiment_score)
  select p_article_uri, 'person', (ord-1)::int, e->>'name', e->>'entityId',
    e->>'entityIdType', e->>'role', e->>'sector', e->>'relevance', e->>'sentiment',
    nullif(e->>'sentimentScore','')::numeric
  from jsonb_array_elements(v_rec->'people') with ordinality as t(e, ord)
  where jsonb_typeof(v_rec->'people') = 'array';
end $$;

-- ─── Dispatch trigger (defensive: never aborts the base firehose write) ──────

create or replace function news.project_record()
returns trigger language plpgsql as $$
begin
  if tg_op = 'DELETE' then
    if old.collection = 'tech.transparencia.news.article' then
      delete from news.articles          where uri = old.uri;
      delete from news.enrichments       where article_uri = old.uri;
      delete from news.article_locations where article_uri = old.uri;
      delete from news.article_entities  where article_uri = old.uri;
    elsif old.collection = 'tech.transparencia.news.source' then
      delete from news.sources where uri = old.uri;
    elsif old.collection = 'tech.transparencia.news.enrichment' then
      perform news.refresh_article_enrichment(old.record->'article'->>'uri');
    end if;
    return old;
  end if;

  if new.collection = 'tech.transparencia.news.article' then
    perform news.upsert_article(new.uri);
  elsif new.collection = 'tech.transparencia.news.source' then
    perform news.upsert_source(new.uri);
  elsif new.collection = 'tech.transparencia.news.enrichment' then
    perform news.refresh_article_enrichment(new.record->'article'->>'uri');
  end if;
  return new;
exception when others then
  raise warning 'news.project_record % failed for %: %',
    tg_op, coalesce(new.uri, old.uri), sqlerrm;
  return coalesce(new, old);
end $$;

drop trigger if exists trg_project_record on atproto.records;
create trigger trg_project_record
  after insert or update or delete on atproto.records
  for each row execute function news.project_record();

-- ─── Full rebuild (backfill / disaster recovery) ─────────────────────────────
-- Set-based; far cheaper than firing the trigger per row. Safe to re-run.

create or replace function news.rebuild_all()
returns void language plpgsql as $$
begin
  truncate news.sources, news.articles, news.enrichments,
           news.article_locations, news.article_entities;

  insert into news.sources (uri, did, cid, name, display_name, base_url,
                            country, language, cms, feed_urls, created_at, record, indexed_at)
  select r.uri, r.did, r.cid, r.record->>'name', r.record->>'displayName',
         r.record->>'baseUrl', r.record->>'country', r.record->>'language',
         r.record->>'cms', r.record->'feedUrls',
         nullif(r.record->>'createdAt','')::timestamptz, r.record, r.indexed_at
  from atproto.records r
  where r.collection = 'tech.transparencia.news.source';

  insert into news.articles (uri, did, rkey, cid, source_uri, title, url, guid,
                             author, image_url, language, feed_category, tags,
                             published_at, created_at, record, indexed_at)
  select r.uri, r.did, r.rkey, r.cid, r.record->'source'->>'uri',
         r.record->>'title', r.record->>'url', r.record->>'guid', r.record->>'author',
         r.record->>'imageUrl', r.record->>'language', r.record->>'feedCategory',
         case when jsonb_typeof(r.record->'tags')='array' then r.record->'tags' end,
         nullif(r.record->>'publishedAt','')::timestamptz,
         nullif(r.record->>'createdAt','')::timestamptz, r.record, r.indexed_at
  from atproto.records r
  where r.collection = 'tech.transparencia.news.article';

  insert into news.enrichments (article_uri, enrichment_uri, did, cid, summary,
    neutral_headline, political_orientation, orientation_confidence, emotional_tone,
    impact_level, clickbait_score, fact_checkability, content_domain, event_type,
    region, reading_level, language, topics, model_used, cost_usd, created_at,
    record, indexed_at)
  select distinct on (r.record->'article'->>'uri')
    r.record->'article'->>'uri', r.uri, r.did, r.cid, r.record->>'summary',
    r.record->>'neutralHeadline', r.record->>'politicalOrientation',
    nullif(r.record->>'orientationConfidence','')::numeric, r.record->>'emotionalTone',
    nullif(r.record->>'impactLevel','')::int, nullif(r.record->>'clickbaitScore','')::int,
    nullif(r.record->>'factCheckability','')::int, r.record->>'contentDomain',
    r.record->>'eventType', r.record->>'region', r.record->>'readingLevel',
    r.record->>'language',
    case when jsonb_typeof(r.record->'topics')='array'
         then array(select jsonb_array_elements_text(r.record->'topics')) end,
    r.record->>'modelUsed', nullif(r.record->>'costUsd','')::numeric,
    nullif(r.record->>'createdAt','')::timestamptz, r.record, r.indexed_at
  from atproto.records r
  where r.collection = 'tech.transparencia.news.enrichment'
    and r.record->'article'->>'uri' is not null
  order by r.record->'article'->>'uri', r.indexed_at desc nulls last;

  insert into news.article_locations (article_uri, idx, name, state, country,
    country_code, relevance, lat, lng)
  select e.article_uri, (ord-1)::int, loc->>'name', loc->>'state', loc->>'country',
    upper(nullif(loc->>'countryCode','')), loc->>'relevance',
    nullif(loc->>'lat','')::double precision, nullif(loc->>'lng','')::double precision
  from news.enrichments e,
       lateral jsonb_array_elements(e.record->'locations') with ordinality as t(loc, ord)
  where jsonb_typeof(e.record->'locations') = 'array';

  insert into news.article_entities (article_uri, kind, idx, name, entity_id,
    entity_id_type, role, sector, relevance, sentiment, sentiment_score)
  select e.article_uri, 'organization', (ord-1)::int, en->>'name', en->>'entityId',
    en->>'entityIdType', en->>'role', en->>'sector', en->>'relevance', en->>'sentiment',
    nullif(en->>'sentimentScore','')::numeric
  from news.enrichments e,
       lateral jsonb_array_elements(e.record->'organizationEntities') with ordinality as t(en, ord)
  where jsonb_typeof(e.record->'organizationEntities') = 'array';

  insert into news.article_entities (article_uri, kind, idx, name, entity_id,
    entity_id_type, role, sector, relevance, sentiment, sentiment_score)
  select e.article_uri, 'person', (ord-1)::int, en->>'name', en->>'entityId',
    en->>'entityIdType', en->>'role', en->>'sector', en->>'relevance', en->>'sentiment',
    nullif(en->>'sentimentScore','')::numeric
  from news.enrichments e,
       lateral jsonb_array_elements(e.record->'people') with ordinality as t(en, ord)
  where jsonb_typeof(e.record->'people') = 'array';
end $$;

-- ponytail: dropped Supabase RLS + anon/authenticated grants — indexer Postgres
-- has no external clients; reads go through the GraphQL service which uses the
-- shared transparencia role.

-- ============================================================================
-- v2: denormalize published_at onto news.enrichments
-- ----------------------------------------------------------------------------
-- Date-ordered list/feed queries used to drive from the enrichments language
-- filter and then sort all ~25k matched articles by a jsonb-extracted date,
-- reading the fat `record` heap rows for every one (~4.9 s). Storing the
-- article's published_at on the enrichment row + indexing it lets those queries
-- scan the date index, filter, and LIMIT early — touching ~20 rows (~48 ms).
-- These statements are idempotent and override the definitions above, so
-- running this file top-to-bottom yields the final state.
-- ============================================================================

alter table news.enrichments add column if not exists published_at timestamptz;
update news.enrichments e set published_at = a.published_at
  from news.articles a
  where a.uri = e.article_uri and e.published_at is distinct from a.published_at;
create index if not exists idx_news_enr_published
  on news.enrichments (published_at desc nulls last);

-- GIN indexes mirroring atproto's idx_enr_people_gin / idx_enr_orgs_gin so the
-- project CTE's entity anchor push-down (record->'people'/'organizationEntities'
-- @> ...) stays index-driven on news.enrichments instead of scanning all rows.
create index if not exists idx_news_enr_people_gin
  on news.enrichments using gin ((record->'people') jsonb_path_ops);
create index if not exists idx_news_enr_orgs_gin
  on news.enrichments using gin ((record->'organizationEntities') jsonb_path_ops);

-- indexed_at ordering for the news-radar feed / pending list (ORDER BY indexed_at).
create index if not exists idx_news_enr_indexed_at
  on news.enrichments (indexed_at desc nulls last);
create index if not exists idx_news_articles_indexed_at
  on news.articles (indexed_at desc nulls last);

-- upsert_article becomes plpgsql so it can also keep the enrichment's
-- denormalized published_at in sync when an article is (re)projected.
create or replace function news.upsert_article(p_uri text)
returns void language plpgsql as $$
begin
  insert into news.articles (uri, did, rkey, cid, source_uri, title, url, guid,
                             author, image_url, language, feed_category, tags,
                             published_at, created_at, record, indexed_at)
  select r.uri, r.did, r.rkey, r.cid, r.record->'source'->>'uri',
         r.record->>'title', r.record->>'url', r.record->>'guid', r.record->>'author',
         r.record->>'imageUrl', r.record->>'language', r.record->>'feedCategory',
         case when jsonb_typeof(r.record->'tags')='array' then r.record->'tags' end,
         nullif(r.record->>'publishedAt','')::timestamptz,
         nullif(r.record->>'createdAt','')::timestamptz, r.record, r.indexed_at
  from atproto.records r where r.uri = p_uri
  on conflict (uri) do update set
    did=excluded.did, rkey=excluded.rkey, cid=excluded.cid, source_uri=excluded.source_uri,
    title=excluded.title, url=excluded.url, guid=excluded.guid, author=excluded.author,
    image_url=excluded.image_url, language=excluded.language, feed_category=excluded.feed_category,
    tags=excluded.tags, published_at=excluded.published_at, created_at=excluded.created_at,
    record=excluded.record, indexed_at=excluded.indexed_at;
  update news.enrichments e set published_at = a.published_at
  from news.articles a where a.uri = e.article_uri and e.article_uri = p_uri;
end $$;

-- refresh_article_enrichment now also stamps published_at from the article.
create or replace function news.refresh_article_enrichment(p_article_uri text)
returns void language plpgsql as $$
declare v_uri text; v_rec jsonb; v_indexed timestamptz; v_did text; v_cid text; v_pub timestamptz;
begin
  if p_article_uri is null then return; end if;
  select r.uri, r.record, r.indexed_at, r.did, r.cid into v_uri, v_rec, v_indexed, v_did, v_cid
  from atproto.records r
  where r.collection = 'tech.transparencia.news.enrichment' and r.record->'article'->>'uri' = p_article_uri
  order by r.indexed_at desc nulls last limit 1;
  delete from news.article_locations where article_uri = p_article_uri;
  delete from news.article_entities  where article_uri = p_article_uri;
  if v_uri is null then delete from news.enrichments where article_uri = p_article_uri; return; end if;
  select nullif(ar.record->>'publishedAt','')::timestamptz into v_pub
  from atproto.records ar
  where ar.uri = p_article_uri and ar.collection = 'tech.transparencia.news.article';
  insert into news.enrichments (article_uri, enrichment_uri, did, cid, summary, neutral_headline, political_orientation, orientation_confidence, emotional_tone, impact_level, clickbait_score, fact_checkability, content_domain, event_type, region, reading_level, language, topics, model_used, cost_usd, created_at, published_at, record, indexed_at)
  values (p_article_uri, v_uri, v_did, v_cid, v_rec->>'summary', v_rec->>'neutralHeadline', v_rec->>'politicalOrientation', nullif(v_rec->>'orientationConfidence','')::numeric, v_rec->>'emotionalTone', nullif(v_rec->>'impactLevel','')::int, nullif(v_rec->>'clickbaitScore','')::int, nullif(v_rec->>'factCheckability','')::int, v_rec->>'contentDomain', v_rec->>'eventType', v_rec->>'region', v_rec->>'readingLevel', v_rec->>'language', case when jsonb_typeof(v_rec->'topics')='array' then array(select jsonb_array_elements_text(v_rec->'topics')) end, v_rec->>'modelUsed', nullif(v_rec->>'costUsd','')::numeric, nullif(v_rec->>'createdAt','')::timestamptz, v_pub, v_rec, v_indexed)
  on conflict (article_uri) do update set enrichment_uri=excluded.enrichment_uri, did=excluded.did, cid=excluded.cid, summary=excluded.summary, neutral_headline=excluded.neutral_headline, political_orientation=excluded.political_orientation, orientation_confidence=excluded.orientation_confidence, emotional_tone=excluded.emotional_tone, impact_level=excluded.impact_level, clickbait_score=excluded.clickbait_score, fact_checkability=excluded.fact_checkability, content_domain=excluded.content_domain, event_type=excluded.event_type, region=excluded.region, reading_level=excluded.reading_level, language=excluded.language, topics=excluded.topics, model_used=excluded.model_used, cost_usd=excluded.cost_usd, created_at=excluded.created_at, published_at=excluded.published_at, record=excluded.record, indexed_at=excluded.indexed_at;
  insert into news.article_locations (article_uri, idx, name, state, country, country_code, relevance, lat, lng)
  select p_article_uri, (ord-1)::int, loc->>'name', loc->>'state', loc->>'country', upper(nullif(loc->>'countryCode','')), loc->>'relevance', nullif(loc->>'lat','')::double precision, nullif(loc->>'lng','')::double precision
  from jsonb_array_elements(v_rec->'locations') with ordinality as t(loc, ord) where jsonb_typeof(v_rec->'locations') = 'array';
  insert into news.article_entities (article_uri, kind, idx, name, entity_id, entity_id_type, role, sector, relevance, sentiment, sentiment_score)
  select p_article_uri, 'organization', (ord-1)::int, e->>'name', e->>'entityId', e->>'entityIdType', e->>'role', e->>'sector', e->>'relevance', e->>'sentiment', nullif(e->>'sentimentScore','')::numeric
  from jsonb_array_elements(v_rec->'organizationEntities') with ordinality as t(e, ord) where jsonb_typeof(v_rec->'organizationEntities') = 'array';
  insert into news.article_entities (article_uri, kind, idx, name, entity_id, entity_id_type, role, sector, relevance, sentiment, sentiment_score)
  select p_article_uri, 'person', (ord-1)::int, e->>'name', e->>'entityId', e->>'entityIdType', e->>'role', e->>'sector', e->>'relevance', e->>'sentiment', nullif(e->>'sentimentScore','')::numeric
  from jsonb_array_elements(v_rec->'people') with ordinality as t(e, ord) where jsonb_typeof(v_rec->'people') = 'array';
end $$;

-- rebuild_all stamps published_at after loading articles + enrichments.
create or replace function news.rebuild_all()
returns void language plpgsql as $$
begin
  truncate news.sources, news.articles, news.enrichments, news.article_locations, news.article_entities;
  insert into news.sources (uri, did, cid, name, display_name, base_url, country, language, cms, feed_urls, created_at, record, indexed_at)
  select r.uri, r.did, r.cid, r.record->>'name', r.record->>'displayName', r.record->>'baseUrl', r.record->>'country', r.record->>'language', r.record->>'cms', r.record->'feedUrls', nullif(r.record->>'createdAt','')::timestamptz, r.record, r.indexed_at
  from atproto.records r where r.collection = 'tech.transparencia.news.source';
  insert into news.articles (uri, did, rkey, cid, source_uri, title, url, guid, author, image_url, language, feed_category, tags, published_at, created_at, record, indexed_at)
  select r.uri, r.did, r.rkey, r.cid, r.record->'source'->>'uri', r.record->>'title', r.record->>'url', r.record->>'guid', r.record->>'author', r.record->>'imageUrl', r.record->>'language', r.record->>'feedCategory', case when jsonb_typeof(r.record->'tags')='array' then r.record->'tags' end, nullif(r.record->>'publishedAt','')::timestamptz, nullif(r.record->>'createdAt','')::timestamptz, r.record, r.indexed_at
  from atproto.records r where r.collection = 'tech.transparencia.news.article';
  insert into news.enrichments (article_uri, enrichment_uri, did, cid, summary, neutral_headline, political_orientation, orientation_confidence, emotional_tone, impact_level, clickbait_score, fact_checkability, content_domain, event_type, region, reading_level, language, topics, model_used, cost_usd, created_at, record, indexed_at)
  select distinct on (r.record->'article'->>'uri') r.record->'article'->>'uri', r.uri, r.did, r.cid, r.record->>'summary', r.record->>'neutralHeadline', r.record->>'politicalOrientation', nullif(r.record->>'orientationConfidence','')::numeric, r.record->>'emotionalTone', nullif(r.record->>'impactLevel','')::int, nullif(r.record->>'clickbaitScore','')::int, nullif(r.record->>'factCheckability','')::int, r.record->>'contentDomain', r.record->>'eventType', r.record->>'region', r.record->>'readingLevel', r.record->>'language', case when jsonb_typeof(r.record->'topics')='array' then array(select jsonb_array_elements_text(r.record->'topics')) end, r.record->>'modelUsed', nullif(r.record->>'costUsd','')::numeric, nullif(r.record->>'createdAt','')::timestamptz, r.record, r.indexed_at
  from atproto.records r where r.collection = 'tech.transparencia.news.enrichment' and r.record->'article'->>'uri' is not null
  order by r.record->'article'->>'uri', r.indexed_at desc nulls last;
  update news.enrichments e set published_at = a.published_at from news.articles a where a.uri = e.article_uri;
  insert into news.article_locations (article_uri, idx, name, state, country, country_code, relevance, lat, lng)
  select e.article_uri, (ord-1)::int, loc->>'name', loc->>'state', loc->>'country', upper(nullif(loc->>'countryCode','')), loc->>'relevance', nullif(loc->>'lat','')::double precision, nullif(loc->>'lng','')::double precision
  from news.enrichments e, lateral jsonb_array_elements(e.record->'locations') with ordinality as t(loc, ord) where jsonb_typeof(e.record->'locations') = 'array';
  insert into news.article_entities (article_uri, kind, idx, name, entity_id, entity_id_type, role, sector, relevance, sentiment, sentiment_score)
  select e.article_uri, 'organization', (ord-1)::int, en->>'name', en->>'entityId', en->>'entityIdType', en->>'role', en->>'sector', en->>'relevance', en->>'sentiment', nullif(en->>'sentimentScore','')::numeric
  from news.enrichments e, lateral jsonb_array_elements(e.record->'organizationEntities') with ordinality as t(en, ord) where jsonb_typeof(e.record->'organizationEntities') = 'array';
  insert into news.article_entities (article_uri, kind, idx, name, entity_id, entity_id_type, role, sector, relevance, sentiment, sentiment_score)
  select e.article_uri, 'person', (ord-1)::int, en->>'name', en->>'entityId', en->>'entityIdType', en->>'role', en->>'sector', en->>'relevance', en->>'sentiment', nullif(en->>'sentimentScore','')::numeric
  from news.enrichments e, lateral jsonb_array_elements(e.record->'people') with ordinality as t(en, ord) where jsonb_typeof(e.record->'people') = 'array';
end $$;
-- ============================================================================
-- news direct projection: functions that accept the record JSONB as a parameter
-- ----------------------------------------------------------------------------
-- Enables the indexer to project events into the news.* tables WITHOUT first
-- writing to atproto.records. Each _json variant mirrors the extraction logic
-- of the equivalent atproto-reading upsert (single source of truth for how
-- fields map lives in the same file, just duplicated once here vs there).
--
-- Enrichment ordering: refresh_article_enrichment_json only overwrites if the
-- incoming event is >= the currently-stored indexed_at. Out-of-order events
-- from a resync-then-catchup won't downgrade a newer enrichment.
--
-- Deletes: delete_*_json wrap the cascade the trigger used to do, so the
-- indexer can `perform news.delete_article_json(uri)` on a delete event and
-- get children cleaned up in one round-trip.
-- ============================================================================

create or replace function news.upsert_source_json(
  p_uri text, p_did text, p_cid text, p_record jsonb, p_indexed_at timestamptz
) returns void language sql as $$
  insert into news.sources (uri, did, cid, name, display_name, base_url,
                            country, language, cms, feed_urls, created_at, record, indexed_at)
  values (
    p_uri, p_did, p_cid,
    p_record->>'name', p_record->>'displayName', p_record->>'baseUrl',
    p_record->>'country', p_record->>'language', p_record->>'cms',
    p_record->'feedUrls',
    nullif(p_record->>'createdAt','')::timestamptz,
    p_record, p_indexed_at
  )
  on conflict (uri) do update set
    did=excluded.did, cid=excluded.cid, name=excluded.name,
    display_name=excluded.display_name, base_url=excluded.base_url,
    country=excluded.country, language=excluded.language, cms=excluded.cms,
    feed_urls=excluded.feed_urls, created_at=excluded.created_at,
    record=excluded.record, indexed_at=excluded.indexed_at;
$$;

create or replace function news.upsert_article_json(
  p_uri text, p_did text, p_rkey text, p_cid text, p_record jsonb, p_indexed_at timestamptz
) returns void language plpgsql as $$
begin
  insert into news.articles (uri, did, rkey, cid, source_uri, title, url, guid,
                             author, image_url, language, feed_category, tags,
                             published_at, created_at, record, indexed_at)
  values (
    p_uri, p_did, p_rkey, p_cid,
    p_record->'source'->>'uri',
    p_record->>'title', p_record->>'url', p_record->>'guid', p_record->>'author',
    p_record->>'imageUrl', p_record->>'language', p_record->>'feedCategory',
    case when jsonb_typeof(p_record->'tags')='array' then p_record->'tags' end,
    nullif(p_record->>'publishedAt','')::timestamptz,
    nullif(p_record->>'createdAt','')::timestamptz,
    p_record, p_indexed_at
  )
  on conflict (uri) do update set
    did=excluded.did, rkey=excluded.rkey, cid=excluded.cid,
    source_uri=excluded.source_uri, title=excluded.title, url=excluded.url,
    guid=excluded.guid, author=excluded.author, image_url=excluded.image_url,
    language=excluded.language, feed_category=excluded.feed_category,
    tags=excluded.tags, published_at=excluded.published_at,
    created_at=excluded.created_at, record=excluded.record, indexed_at=excluded.indexed_at;
  -- keep denormalized published_at on the enrichment in sync
  update news.enrichments e set published_at = a.published_at
  from news.articles a
  where a.uri = e.article_uri and e.article_uri = p_uri;
end $$;

create or replace function news.refresh_article_enrichment_json(
  p_article_uri text, p_enrichment_uri text, p_did text, p_cid text,
  p_record jsonb, p_indexed_at timestamptz
) returns void language plpgsql as $$
declare
  v_existing_indexed_at timestamptz;
  v_pub timestamptz;
begin
  if p_article_uri is null then return; end if;

  select indexed_at into v_existing_indexed_at
  from news.enrichments where article_uri = p_article_uri;

  -- Older/equal event: skip. Prevents a resync from downgrading a fresher row.
  if v_existing_indexed_at is not null and v_existing_indexed_at >= p_indexed_at then
    return;
  end if;

  delete from news.article_locations where article_uri = p_article_uri;
  delete from news.article_entities  where article_uri = p_article_uri;

  select published_at into v_pub from news.articles where uri = p_article_uri;

  insert into news.enrichments (article_uri, enrichment_uri, did, cid, summary,
    neutral_headline, political_orientation, orientation_confidence, emotional_tone,
    impact_level, clickbait_score, fact_checkability, content_domain, event_type,
    region, reading_level, language, topics, model_used, cost_usd, created_at,
    published_at, record, indexed_at)
  values (p_article_uri, p_enrichment_uri, p_did, p_cid, p_record->>'summary',
    p_record->>'neutralHeadline', p_record->>'politicalOrientation',
    nullif(p_record->>'orientationConfidence','')::numeric, p_record->>'emotionalTone',
    nullif(p_record->>'impactLevel','')::int, nullif(p_record->>'clickbaitScore','')::int,
    nullif(p_record->>'factCheckability','')::int, p_record->>'contentDomain',
    p_record->>'eventType', p_record->>'region', p_record->>'readingLevel',
    p_record->>'language',
    case when jsonb_typeof(p_record->'topics')='array'
         then array(select jsonb_array_elements_text(p_record->'topics')) end,
    p_record->>'modelUsed', nullif(p_record->>'costUsd','')::numeric,
    nullif(p_record->>'createdAt','')::timestamptz, v_pub, p_record, p_indexed_at)
  on conflict (article_uri) do update set
    enrichment_uri=excluded.enrichment_uri, did=excluded.did, cid=excluded.cid,
    summary=excluded.summary, neutral_headline=excluded.neutral_headline,
    political_orientation=excluded.political_orientation,
    orientation_confidence=excluded.orientation_confidence,
    emotional_tone=excluded.emotional_tone, impact_level=excluded.impact_level,
    clickbait_score=excluded.clickbait_score, fact_checkability=excluded.fact_checkability,
    content_domain=excluded.content_domain, event_type=excluded.event_type,
    region=excluded.region, reading_level=excluded.reading_level,
    language=excluded.language, topics=excluded.topics, model_used=excluded.model_used,
    cost_usd=excluded.cost_usd, created_at=excluded.created_at,
    published_at=excluded.published_at, record=excluded.record, indexed_at=excluded.indexed_at;

  insert into news.article_locations (article_uri, idx, name, state, country,
    country_code, relevance, lat, lng)
  select p_article_uri, (ord-1)::int, loc->>'name', loc->>'state', loc->>'country',
    upper(nullif(loc->>'countryCode','')), loc->>'relevance',
    nullif(loc->>'lat','')::double precision, nullif(loc->>'lng','')::double precision
  from jsonb_array_elements(p_record->'locations') with ordinality as t(loc, ord)
  where jsonb_typeof(p_record->'locations') = 'array';

  insert into news.article_entities (article_uri, kind, idx, name, entity_id,
    entity_id_type, role, sector, relevance, sentiment, sentiment_score)
  select p_article_uri, 'organization', (ord-1)::int, e->>'name', e->>'entityId',
    e->>'entityIdType', e->>'role', e->>'sector', e->>'relevance', e->>'sentiment',
    nullif(e->>'sentimentScore','')::numeric
  from jsonb_array_elements(p_record->'organizationEntities') with ordinality as t(e, ord)
  where jsonb_typeof(p_record->'organizationEntities') = 'array';

  insert into news.article_entities (article_uri, kind, idx, name, entity_id,
    entity_id_type, role, sector, relevance, sentiment, sentiment_score)
  select p_article_uri, 'person', (ord-1)::int, e->>'name', e->>'entityId',
    e->>'entityIdType', e->>'role', e->>'sector', e->>'relevance', e->>'sentiment',
    nullif(e->>'sentimentScore','')::numeric
  from jsonb_array_elements(p_record->'people') with ordinality as t(e, ord)
  where jsonb_typeof(p_record->'people') = 'array';
end $$;

-- Delete helpers: 1 round-trip cascade for the indexer's delete-event handler.

create or replace function news.delete_source_json(p_uri text)
returns void language sql as $$
  delete from news.sources where uri = p_uri;
$$;

create or replace function news.delete_article_json(p_uri text)
returns void language sql as $$
  delete from news.article_locations where article_uri = p_uri;
  delete from news.article_entities  where article_uri = p_uri;
  delete from news.enrichments       where article_uri = p_uri;
  delete from news.articles          where uri = p_uri;
$$;

-- Delete keyed by the enrichment record URI (what tap gives us on a delete
-- event). Resolves to the article_uri via news.enrichments, then removes the
-- projected row and its children.
create or replace function news.delete_enrichment_json(p_enrichment_uri text)
returns void language plpgsql as $$
declare
  v_article_uri text;
begin
  select article_uri into v_article_uri
  from news.enrichments where enrichment_uri = p_enrichment_uri;
  if v_article_uri is null then return; end if;
  delete from news.article_locations where article_uri = v_article_uri;
  delete from news.article_entities  where article_uri = v_article_uri;
  delete from news.enrichments       where article_uri = v_article_uri;
end $$;
