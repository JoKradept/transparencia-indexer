-- ============================================================================
-- dof read-model: typed projection of atproto.records for DOF (Diario Oficial)
-- ----------------------------------------------------------------------------
-- Mirrors the shape of schema_news.sql for the four DOF-related lexicons:
--   tech.transparencia.document.source      → dof.sources
--   tech.transparencia.document.item        → dof.items
--   tech.transparencia.document.mxdof.note  → dof.notes
--   tech.transparencia.document.mxdof.note.enrichment → dof.enrichments
--                                             + dof.note_locations
--                                             + dof.note_entities
--
-- Same design principles: atproto.records is the source of truth, dof.* is
-- disposable (`select dof.rebuild_all();`), a trigger keeps everything in sync
-- incrementally, and a projection failure NEVER aborts the base insert.
--
-- Tracking motivation: 'muestrame todo lo que salió en el DOF sobre X sector /
-- tema / autoridad' hits a GIN index on dof.enrichments.topics/sector; without
-- this, the app scans jsonb on every note.
-- ============================================================================

create schema if not exists dof;

-- ─── Supporting index on the source table (non-destructive) ─────────────────
create index if not exists idx_dof_enr_note_uri
  on atproto.records ((record->'note'->>'uri'))
  where collection = 'tech.transparencia.document.mxdof.note.enrichment';

create index if not exists idx_dof_note_item_uri
  on atproto.records ((record->'item'->>'uri'))
  where collection = 'tech.transparencia.document.mxdof.note';

-- ─── Tables ─────────────────────────────────────────────────────────────────

create table if not exists dof.sources (
  uri          text primary key,
  did          text not null,
  cid          text,
  name         text,
  display_name text,
  base_url     text,
  country      text,
  language     text,
  record       jsonb not null,
  indexed_at   timestamptz
);

-- Canonical document.item: the DOF publication entry (before mxdof-specific parsing).
create table if not exists dof.items (
  uri            text primary key,
  did            text not null,
  rkey           text,
  cid            text,
  source_uri     text,
  title          text,
  subtitle       text,
  description    text,
  document_type  text,
  language       text,
  country        text,
  jurisdiction   text,
  published_at   timestamptz,
  issued_at      timestamptz,
  effective_at   timestamptz,
  domains        text[],
  topics         text[],
  retrieval_url  text,
  canonical_url  text,
  html_url       text,
  pdf_url        text,
  mime_type      text,
  sha256         text,
  size_bytes     bigint,
  access_type    text,
  retrieved_at   timestamptz,
  issuing_bodies jsonb,   -- array of {name, entityId, entityIdType, role, sector}
  identifiers    jsonb,   -- array of {type, value, url}
  created_at     timestamptz,
  record         jsonb not null,
  indexed_at     timestamptz
);

-- DOF-specific mxdof.note (parsed per-nota metadata extracted from an item).
create table if not exists dof.notes (
  uri                    text primary key,
  did                    text not null,
  rkey                   text,
  cid                    text,
  item_uri               text,
  cod_nota               bigint,
  cod_diario             bigint,
  edition                text,        -- 'matutina' | 'vespertina' | 'especial'
  cod_seccion            text,
  dependencia            text,
  organismo              text,
  issuing_authority      text,
  authority_level        text,
  tipo_nota              text,
  document_class         text,
  page                   int,
  page_until             int,
  order_num              text,        -- source uses "2.5" style strings
  has_html               boolean,
  has_pdf                boolean,
  has_doc                boolean,
  has_image              boolean,
  content_text_available boolean,
  pdf_storage_path       text,
  raw_imported_at        timestamptz,
  created_at             timestamptz,
  record                 jsonb not null,
  indexed_at             timestamptz
);

-- 1 row per note = most recent enrichment.
create table if not exists dof.enrichments (
  note_uri               text primary key,
  enrichment_uri         text not null,
  did                    text,
  cid                    text,
  summary                text,
  neutral_headline       text,
  tipo_acto              text,
  document_class         text,
  sector                 text,
  impact_level           int,
  impact_reasoning       text,
  legal_effects          text[],
  obligations            jsonb,       -- text[] flat, but stored as JSONB for future struct upgrade
  compliance_items       jsonb,       -- [{kind, text, responsibleEntity, dueDateText, dueDate, ...}]
  effective_date         timestamptz,
  effective_date_text    text,
  topics                 text[],
  target_entities        text[],
  related_references     jsonb,       -- [{title, relationType, referenceKind, publicationDateText}]
  structured_refs        jsonb,       -- [{type, value}]
  timeline               jsonb,       -- [{event, startDate, startDateText, endDate?}]
  content_domain         text,
  event_type             text,
  region                 text,
  geographic_scope       text,
  source_authority_level text,
  reading_level          text,
  language               text,
  model_used             text,
  model_version          text,
  input_tokens           int,
  output_tokens          int,
  cost_usd               numeric,
  created_at             timestamptz,
  published_at           timestamptz, -- denormalized from dof.notes for fast feed sort
  record                 jsonb not null,
  indexed_at             timestamptz
);

-- Denormalized locations from enrichment.locations[] → map/geo queries.
create table if not exists dof.note_locations (
  note_uri     text not null,
  idx          int  not null,
  name         text,
  state        text,
  country      text,
  country_code text,
  relevance    text,
  lat          double precision,
  lng          double precision,
  primary key (note_uri, idx)
);

-- Denormalized entities from enrichment.people[] + organizationEntities[] → actor graphs.
create table if not exists dof.note_entities (
  note_uri        text not null,
  kind            text not null,   -- 'organization' | 'person'
  idx             int  not null,
  name            text,
  entity_id       text,
  entity_id_type  text,
  role            text,
  sector          text,
  relevance       text,
  sentiment       text,
  sentiment_score numeric,
  primary key (note_uri, kind, idx)
);

-- ─── Indexes (read paths) ───────────────────────────────────────────────────
create index if not exists idx_dof_items_source      on dof.items (source_uri);
create index if not exists idx_dof_items_published   on dof.items (published_at desc);
create index if not exists idx_dof_items_effective   on dof.items (effective_at desc nulls last);
create index if not exists idx_dof_items_type        on dof.items (document_type);
create index if not exists idx_dof_items_domains     on dof.items using gin (domains);
create index if not exists idx_dof_items_topics      on dof.items using gin (topics);

create index if not exists idx_dof_notes_item        on dof.notes (item_uri);
create index if not exists idx_dof_notes_dep         on dof.notes (dependencia);
create index if not exists idx_dof_notes_org         on dof.notes (organismo);
create index if not exists idx_dof_notes_auth        on dof.notes (issuing_authority);
create index if not exists idx_dof_notes_diario      on dof.notes (cod_diario);
create index if not exists idx_dof_notes_created     on dof.notes (created_at desc);

create index if not exists idx_dof_enr_topics        on dof.enrichments using gin (topics);
create index if not exists idx_dof_enr_sector        on dof.enrichments (sector);
create index if not exists idx_dof_enr_event_type    on dof.enrichments (event_type);
create index if not exists idx_dof_enr_domain        on dof.enrichments (content_domain);
create index if not exists idx_dof_enr_impact        on dof.enrichments (impact_level);
create index if not exists idx_dof_enr_region        on dof.enrichments (region);
create index if not exists idx_dof_enr_effective     on dof.enrichments (effective_date desc nulls last);
create index if not exists idx_dof_enr_published     on dof.enrichments (published_at desc nulls last);
create index if not exists idx_dof_enr_indexed_at    on dof.enrichments (indexed_at desc nulls last);
create index if not exists idx_dof_enr_people_gin
  on dof.enrichments using gin ((record->'people') jsonb_path_ops);
create index if not exists idx_dof_enr_orgs_gin
  on dof.enrichments using gin ((record->'organizationEntities') jsonb_path_ops);
create index if not exists idx_dof_enr_fts_es on dof.enrichments
  using gin (to_tsvector('spanish', coalesce(summary, '')))
  where language like 'es%';

create index if not exists idx_dof_loc_country       on dof.note_locations (country_code);
create index if not exists idx_dof_loc_state         on dof.note_locations (lower(state));
create index if not exists idx_dof_loc_relevance     on dof.note_locations (relevance);

create index if not exists idx_dof_ent_entity_id     on dof.note_entities (entity_id);
create index if not exists idx_dof_ent_name          on dof.note_entities (lower(name));
create index if not exists idx_dof_ent_kind          on dof.note_entities (kind);

-- ─── Projection helpers ──────────────────────────────────────────────────────

create or replace function dof.upsert_source(p_uri text)
returns void language sql as $$
  insert into dof.sources (uri, did, cid, name, display_name, base_url,
                           country, language, record, indexed_at)
  select r.uri, r.did, r.cid,
         r.record->>'name', r.record->>'displayName', r.record->>'baseUrl',
         r.record->>'country', r.record->>'language',
         r.record, r.indexed_at
  from atproto.records r
  where r.uri = p_uri
  on conflict (uri) do update set
    did=excluded.did, cid=excluded.cid, name=excluded.name,
    display_name=excluded.display_name, base_url=excluded.base_url,
    country=excluded.country, language=excluded.language,
    record=excluded.record, indexed_at=excluded.indexed_at;
$$;

create or replace function dof.upsert_item(p_uri text)
returns void language sql as $$
  insert into dof.items (uri, did, rkey, cid, source_uri, title, subtitle,
    description, document_type, language, country, jurisdiction,
    published_at, issued_at, effective_at, domains, topics,
    retrieval_url, canonical_url, html_url, pdf_url, mime_type, sha256,
    size_bytes, access_type, retrieved_at, issuing_bodies, identifiers,
    created_at, record, indexed_at)
  select r.uri, r.did, r.rkey, r.cid,
    r.record->'source'->>'uri',
    r.record->>'title', r.record->>'subtitle', r.record->>'description',
    r.record->>'documentType', r.record->>'language', r.record->>'country',
    r.record->>'jurisdiction',
    nullif(r.record->>'publishedAt','')::timestamptz,
    nullif(r.record->>'issuedAt','')::timestamptz,
    nullif(r.record->>'effectiveAt','')::timestamptz,
    case when jsonb_typeof(r.record->'domains')='array'
         then array(select jsonb_array_elements_text(r.record->'domains')) end,
    case when jsonb_typeof(r.record->'topics')='array'
         then array(select jsonb_array_elements_text(r.record->'topics')) end,
    r.record->'retrieval'->>'url', r.record->'retrieval'->>'canonicalUrl',
    r.record->'retrieval'->>'htmlUrl', r.record->'retrieval'->>'pdfUrl',
    r.record->'retrieval'->>'mimeType', r.record->'retrieval'->>'sha256',
    nullif(r.record->'retrieval'->>'sizeBytes','')::bigint,
    r.record->'retrieval'->>'accessType',
    nullif(r.record->'retrieval'->>'retrievedAt','')::timestamptz,
    case when jsonb_typeof(r.record->'issuingBodies')='array' then r.record->'issuingBodies' end,
    case when jsonb_typeof(r.record->'identifiers')='array' then r.record->'identifiers' end,
    nullif(r.record->>'createdAt','')::timestamptz,
    r.record, r.indexed_at
  from atproto.records r
  where r.uri = p_uri
  on conflict (uri) do update set
    did=excluded.did, rkey=excluded.rkey, cid=excluded.cid,
    source_uri=excluded.source_uri, title=excluded.title, subtitle=excluded.subtitle,
    description=excluded.description, document_type=excluded.document_type,
    language=excluded.language, country=excluded.country, jurisdiction=excluded.jurisdiction,
    published_at=excluded.published_at, issued_at=excluded.issued_at,
    effective_at=excluded.effective_at, domains=excluded.domains, topics=excluded.topics,
    retrieval_url=excluded.retrieval_url, canonical_url=excluded.canonical_url,
    html_url=excluded.html_url, pdf_url=excluded.pdf_url, mime_type=excluded.mime_type,
    sha256=excluded.sha256, size_bytes=excluded.size_bytes, access_type=excluded.access_type,
    retrieved_at=excluded.retrieved_at, issuing_bodies=excluded.issuing_bodies,
    identifiers=excluded.identifiers, created_at=excluded.created_at,
    record=excluded.record, indexed_at=excluded.indexed_at;
$$;

create or replace function dof.upsert_note(p_uri text)
returns void language plpgsql as $$
begin
  insert into dof.notes (uri, did, rkey, cid, item_uri, cod_nota, cod_diario,
    edition, cod_seccion, dependencia, organismo, issuing_authority, authority_level,
    tipo_nota, document_class, page, page_until, order_num,
    has_html, has_pdf, has_doc, has_image, content_text_available,
    pdf_storage_path, raw_imported_at, created_at, record, indexed_at)
  select r.uri, r.did, r.rkey, r.cid,
    r.record->'item'->>'uri',
    nullif(r.record->>'codNota','')::bigint,
    nullif(r.record->>'codDiario','')::bigint,
    r.record->>'edition', r.record->>'codSeccion',
    r.record->>'dependencia', r.record->>'organismo',
    r.record->>'issuingAuthority', r.record->>'authorityLevel',
    r.record->>'tipoNota', r.record->>'documentClass',
    nullif(r.record->>'page','')::int, nullif(r.record->>'pageUntil','')::int,
    r.record->>'order',
    nullif(r.record->>'hasHtml','')::boolean,
    nullif(r.record->>'hasPdf','')::boolean,
    nullif(r.record->>'hasDoc','')::boolean,
    nullif(r.record->>'hasImage','')::boolean,
    nullif(r.record->>'contentTextAvailable','')::boolean,
    r.record->>'pdfStoragePath',
    nullif(r.record->>'rawImportedAt','')::timestamptz,
    nullif(r.record->>'createdAt','')::timestamptz,
    r.record, r.indexed_at
  from atproto.records r
  where r.uri = p_uri
  on conflict (uri) do update set
    did=excluded.did, rkey=excluded.rkey, cid=excluded.cid, item_uri=excluded.item_uri,
    cod_nota=excluded.cod_nota, cod_diario=excluded.cod_diario, edition=excluded.edition,
    cod_seccion=excluded.cod_seccion, dependencia=excluded.dependencia,
    organismo=excluded.organismo, issuing_authority=excluded.issuing_authority,
    authority_level=excluded.authority_level, tipo_nota=excluded.tipo_nota,
    document_class=excluded.document_class, page=excluded.page, page_until=excluded.page_until,
    order_num=excluded.order_num, has_html=excluded.has_html, has_pdf=excluded.has_pdf,
    has_doc=excluded.has_doc, has_image=excluded.has_image,
    content_text_available=excluded.content_text_available,
    pdf_storage_path=excluded.pdf_storage_path, raw_imported_at=excluded.raw_imported_at,
    created_at=excluded.created_at, record=excluded.record, indexed_at=excluded.indexed_at;
  update dof.enrichments e set published_at = n.created_at
  from dof.notes n where n.uri = e.note_uri and e.note_uri = p_uri;
end $$;

create or replace function dof.refresh_note_enrichment(p_note_uri text)
returns void language plpgsql as $$
declare
  v_uri text; v_rec jsonb; v_indexed timestamptz; v_did text; v_cid text; v_pub timestamptz;
begin
  if p_note_uri is null then return; end if;

  select r.uri, r.record, r.indexed_at, r.did, r.cid
    into v_uri, v_rec, v_indexed, v_did, v_cid
  from atproto.records r
  where r.collection = 'tech.transparencia.document.mxdof.note.enrichment'
    and r.record->'note'->>'uri' = p_note_uri
  order by r.indexed_at desc nulls last
  limit 1;

  delete from dof.note_locations where note_uri = p_note_uri;
  delete from dof.note_entities  where note_uri = p_note_uri;

  if v_uri is null then
    delete from dof.enrichments where note_uri = p_note_uri;
    return;
  end if;

  select n.created_at into v_pub from dof.notes n where n.uri = p_note_uri;

  insert into dof.enrichments (note_uri, enrichment_uri, did, cid, summary,
    neutral_headline, tipo_acto, document_class, sector, impact_level, impact_reasoning,
    legal_effects, obligations, compliance_items, effective_date, effective_date_text,
    topics, target_entities, related_references, structured_refs, timeline,
    content_domain, event_type, region, geographic_scope, source_authority_level,
    reading_level, language, model_used, model_version, input_tokens, output_tokens,
    cost_usd, created_at, published_at, record, indexed_at)
  values (p_note_uri, v_uri, v_did, v_cid, v_rec->>'summary',
    v_rec->>'neutralHeadline', v_rec->>'tipoActo', v_rec->>'documentClass',
    v_rec->>'sector', nullif(v_rec->>'impactLevel','')::int, v_rec->>'impactReasoning',
    case when jsonb_typeof(v_rec->'legalEffects')='array'
         then array(select jsonb_array_elements_text(v_rec->'legalEffects')) end,
    case when jsonb_typeof(v_rec->'obligations')='array' then v_rec->'obligations' end,
    case when jsonb_typeof(v_rec->'complianceItems')='array' then v_rec->'complianceItems' end,
    nullif(v_rec->>'effectiveDate','')::timestamptz, v_rec->>'effectiveDateText',
    case when jsonb_typeof(v_rec->'topics')='array'
         then array(select jsonb_array_elements_text(v_rec->'topics')) end,
    case when jsonb_typeof(v_rec->'targetEntities')='array'
         then array(select jsonb_array_elements_text(v_rec->'targetEntities')) end,
    case when jsonb_typeof(v_rec->'relatedReferences')='array' then v_rec->'relatedReferences' end,
    case when jsonb_typeof(v_rec->'structuredRefs')='array' then v_rec->'structuredRefs' end,
    case when jsonb_typeof(v_rec->'timeline')='array' then v_rec->'timeline' end,
    v_rec->>'contentDomain', v_rec->>'eventType', v_rec->>'region',
    v_rec->>'geographicScope', v_rec->>'sourceAuthorityLevel', v_rec->>'readingLevel',
    v_rec->>'language', v_rec->>'modelUsed', v_rec->>'modelVersion',
    nullif(v_rec->>'inputTokens','')::int, nullif(v_rec->>'outputTokens','')::int,
    nullif(v_rec->>'costUsd','')::numeric,
    nullif(v_rec->>'createdAt','')::timestamptz, v_pub, v_rec, v_indexed)
  on conflict (note_uri) do update set
    enrichment_uri=excluded.enrichment_uri, did=excluded.did, cid=excluded.cid,
    summary=excluded.summary, neutral_headline=excluded.neutral_headline,
    tipo_acto=excluded.tipo_acto, document_class=excluded.document_class,
    sector=excluded.sector, impact_level=excluded.impact_level,
    impact_reasoning=excluded.impact_reasoning, legal_effects=excluded.legal_effects,
    obligations=excluded.obligations, compliance_items=excluded.compliance_items,
    effective_date=excluded.effective_date, effective_date_text=excluded.effective_date_text,
    topics=excluded.topics, target_entities=excluded.target_entities,
    related_references=excluded.related_references, structured_refs=excluded.structured_refs,
    timeline=excluded.timeline, content_domain=excluded.content_domain,
    event_type=excluded.event_type, region=excluded.region,
    geographic_scope=excluded.geographic_scope,
    source_authority_level=excluded.source_authority_level,
    reading_level=excluded.reading_level, language=excluded.language,
    model_used=excluded.model_used, model_version=excluded.model_version,
    input_tokens=excluded.input_tokens, output_tokens=excluded.output_tokens,
    cost_usd=excluded.cost_usd, created_at=excluded.created_at,
    published_at=excluded.published_at, record=excluded.record, indexed_at=excluded.indexed_at;

  insert into dof.note_locations (note_uri, idx, name, state, country,
    country_code, relevance, lat, lng)
  select p_note_uri, (ord-1)::int, loc->>'name', loc->>'state', loc->>'country',
    upper(nullif(loc->>'countryCode','')), loc->>'relevance',
    nullif(loc->>'lat','')::double precision, nullif(loc->>'lng','')::double precision
  from jsonb_array_elements(v_rec->'locations') with ordinality as t(loc, ord)
  where jsonb_typeof(v_rec->'locations') = 'array';

  insert into dof.note_entities (note_uri, kind, idx, name, entity_id,
    entity_id_type, role, sector, relevance, sentiment, sentiment_score)
  select p_note_uri, 'organization', (ord-1)::int, e->>'name', e->>'entityId',
    e->>'entityIdType', e->>'role', e->>'sector', e->>'relevance', e->>'sentiment',
    nullif(e->>'sentimentScore','')::numeric
  from jsonb_array_elements(v_rec->'organizationEntities') with ordinality as t(e, ord)
  where jsonb_typeof(v_rec->'organizationEntities') = 'array';

  insert into dof.note_entities (note_uri, kind, idx, name, entity_id,
    entity_id_type, role, sector, relevance, sentiment, sentiment_score)
  select p_note_uri, 'person', (ord-1)::int, e->>'name', e->>'entityId',
    e->>'entityIdType', e->>'role', e->>'sector', e->>'relevance', e->>'sentiment',
    nullif(e->>'sentimentScore','')::numeric
  from jsonb_array_elements(v_rec->'people') with ordinality as t(e, ord)
  where jsonb_typeof(v_rec->'people') = 'array';
end $$;

-- ─── Dispatch trigger (defensive: never aborts the base firehose write) ─────

create or replace function dof.project_record()
returns trigger language plpgsql as $$
begin
  if tg_op = 'DELETE' then
    if old.collection = 'tech.transparencia.document.source' then
      delete from dof.sources where uri = old.uri;
    elsif old.collection = 'tech.transparencia.document.item' then
      delete from dof.items where uri = old.uri;
    elsif old.collection = 'tech.transparencia.document.mxdof.note' then
      delete from dof.notes          where uri = old.uri;
      delete from dof.enrichments    where note_uri = old.uri;
      delete from dof.note_locations where note_uri = old.uri;
      delete from dof.note_entities  where note_uri = old.uri;
    elsif old.collection = 'tech.transparencia.document.mxdof.note.enrichment' then
      perform dof.refresh_note_enrichment(old.record->'note'->>'uri');
    end if;
    return old;
  end if;

  if new.collection = 'tech.transparencia.document.source' then
    perform dof.upsert_source(new.uri);
  elsif new.collection = 'tech.transparencia.document.item' then
    perform dof.upsert_item(new.uri);
  elsif new.collection = 'tech.transparencia.document.mxdof.note' then
    perform dof.upsert_note(new.uri);
  elsif new.collection = 'tech.transparencia.document.mxdof.note.enrichment' then
    perform dof.refresh_note_enrichment(new.record->'note'->>'uri');
  end if;
  return new;
exception when others then
  raise warning 'dof.project_record % failed for %: %',
    tg_op, coalesce(new.uri, old.uri), sqlerrm;
  return coalesce(new, old);
end $$;

drop trigger if exists trg_dof_project_record on atproto.records;
create trigger trg_dof_project_record
  after insert or update or delete on atproto.records
  for each row execute function dof.project_record();

-- ─── Full rebuild (backfill / disaster recovery) ─────────────────────────────
-- Set-based; safe to re-run.

create or replace function dof.rebuild_all()
returns void language plpgsql as $$
begin
  truncate dof.sources, dof.items, dof.notes, dof.enrichments,
           dof.note_locations, dof.note_entities;

  insert into dof.sources (uri, did, cid, name, display_name, base_url,
                           country, language, record, indexed_at)
  select r.uri, r.did, r.cid, r.record->>'name', r.record->>'displayName',
         r.record->>'baseUrl', r.record->>'country', r.record->>'language',
         r.record, r.indexed_at
  from atproto.records r
  where r.collection = 'tech.transparencia.document.source';

  insert into dof.items (uri, did, rkey, cid, source_uri, title, subtitle,
    description, document_type, language, country, jurisdiction,
    published_at, issued_at, effective_at, domains, topics,
    retrieval_url, canonical_url, html_url, pdf_url, mime_type, sha256,
    size_bytes, access_type, retrieved_at, issuing_bodies, identifiers,
    created_at, record, indexed_at)
  select r.uri, r.did, r.rkey, r.cid,
    r.record->'source'->>'uri',
    r.record->>'title', r.record->>'subtitle', r.record->>'description',
    r.record->>'documentType', r.record->>'language', r.record->>'country',
    r.record->>'jurisdiction',
    nullif(r.record->>'publishedAt','')::timestamptz,
    nullif(r.record->>'issuedAt','')::timestamptz,
    nullif(r.record->>'effectiveAt','')::timestamptz,
    case when jsonb_typeof(r.record->'domains')='array'
         then array(select jsonb_array_elements_text(r.record->'domains')) end,
    case when jsonb_typeof(r.record->'topics')='array'
         then array(select jsonb_array_elements_text(r.record->'topics')) end,
    r.record->'retrieval'->>'url', r.record->'retrieval'->>'canonicalUrl',
    r.record->'retrieval'->>'htmlUrl', r.record->'retrieval'->>'pdfUrl',
    r.record->'retrieval'->>'mimeType', r.record->'retrieval'->>'sha256',
    nullif(r.record->'retrieval'->>'sizeBytes','')::bigint,
    r.record->'retrieval'->>'accessType',
    nullif(r.record->'retrieval'->>'retrievedAt','')::timestamptz,
    case when jsonb_typeof(r.record->'issuingBodies')='array' then r.record->'issuingBodies' end,
    case when jsonb_typeof(r.record->'identifiers')='array' then r.record->'identifiers' end,
    nullif(r.record->>'createdAt','')::timestamptz,
    r.record, r.indexed_at
  from atproto.records r
  where r.collection = 'tech.transparencia.document.item';

  insert into dof.notes (uri, did, rkey, cid, item_uri, cod_nota, cod_diario,
    edition, cod_seccion, dependencia, organismo, issuing_authority, authority_level,
    tipo_nota, document_class, page, page_until, order_num,
    has_html, has_pdf, has_doc, has_image, content_text_available,
    pdf_storage_path, raw_imported_at, created_at, record, indexed_at)
  select r.uri, r.did, r.rkey, r.cid,
    r.record->'item'->>'uri',
    nullif(r.record->>'codNota','')::bigint,
    nullif(r.record->>'codDiario','')::bigint,
    r.record->>'edition', r.record->>'codSeccion',
    r.record->>'dependencia', r.record->>'organismo',
    r.record->>'issuingAuthority', r.record->>'authorityLevel',
    r.record->>'tipoNota', r.record->>'documentClass',
    nullif(r.record->>'page','')::int, nullif(r.record->>'pageUntil','')::int,
    r.record->>'order',
    nullif(r.record->>'hasHtml','')::boolean, nullif(r.record->>'hasPdf','')::boolean,
    nullif(r.record->>'hasDoc','')::boolean, nullif(r.record->>'hasImage','')::boolean,
    nullif(r.record->>'contentTextAvailable','')::boolean,
    r.record->>'pdfStoragePath',
    nullif(r.record->>'rawImportedAt','')::timestamptz,
    nullif(r.record->>'createdAt','')::timestamptz,
    r.record, r.indexed_at
  from atproto.records r
  where r.collection = 'tech.transparencia.document.mxdof.note';

  insert into dof.enrichments (note_uri, enrichment_uri, did, cid, summary,
    neutral_headline, tipo_acto, document_class, sector, impact_level, impact_reasoning,
    legal_effects, obligations, compliance_items, effective_date, effective_date_text,
    topics, target_entities, related_references, structured_refs, timeline,
    content_domain, event_type, region, geographic_scope, source_authority_level,
    reading_level, language, model_used, model_version, input_tokens, output_tokens,
    cost_usd, created_at, record, indexed_at)
  select distinct on (r.record->'note'->>'uri')
    r.record->'note'->>'uri', r.uri, r.did, r.cid, r.record->>'summary',
    r.record->>'neutralHeadline', r.record->>'tipoActo', r.record->>'documentClass',
    r.record->>'sector', nullif(r.record->>'impactLevel','')::int, r.record->>'impactReasoning',
    case when jsonb_typeof(r.record->'legalEffects')='array'
         then array(select jsonb_array_elements_text(r.record->'legalEffects')) end,
    case when jsonb_typeof(r.record->'obligations')='array' then r.record->'obligations' end,
    case when jsonb_typeof(r.record->'complianceItems')='array' then r.record->'complianceItems' end,
    nullif(r.record->>'effectiveDate','')::timestamptz, r.record->>'effectiveDateText',
    case when jsonb_typeof(r.record->'topics')='array'
         then array(select jsonb_array_elements_text(r.record->'topics')) end,
    case when jsonb_typeof(r.record->'targetEntities')='array'
         then array(select jsonb_array_elements_text(r.record->'targetEntities')) end,
    case when jsonb_typeof(r.record->'relatedReferences')='array' then r.record->'relatedReferences' end,
    case when jsonb_typeof(r.record->'structuredRefs')='array' then r.record->'structuredRefs' end,
    case when jsonb_typeof(r.record->'timeline')='array' then r.record->'timeline' end,
    r.record->>'contentDomain', r.record->>'eventType', r.record->>'region',
    r.record->>'geographicScope', r.record->>'sourceAuthorityLevel', r.record->>'readingLevel',
    r.record->>'language', r.record->>'modelUsed', r.record->>'modelVersion',
    nullif(r.record->>'inputTokens','')::int, nullif(r.record->>'outputTokens','')::int,
    nullif(r.record->>'costUsd','')::numeric,
    nullif(r.record->>'createdAt','')::timestamptz, r.record, r.indexed_at
  from atproto.records r
  where r.collection = 'tech.transparencia.document.mxdof.note.enrichment'
    and r.record->'note'->>'uri' is not null
  order by r.record->'note'->>'uri', r.indexed_at desc nulls last;

  -- Denormalize published_at (from note.created_at) onto enrichments.
  update dof.enrichments e set published_at = n.created_at
  from dof.notes n where n.uri = e.note_uri;

  insert into dof.note_locations (note_uri, idx, name, state, country,
    country_code, relevance, lat, lng)
  select e.note_uri, (ord-1)::int, loc->>'name', loc->>'state', loc->>'country',
    upper(nullif(loc->>'countryCode','')), loc->>'relevance',
    nullif(loc->>'lat','')::double precision, nullif(loc->>'lng','')::double precision
  from dof.enrichments e,
       lateral jsonb_array_elements(e.record->'locations') with ordinality as t(loc, ord)
  where jsonb_typeof(e.record->'locations') = 'array';

  insert into dof.note_entities (note_uri, kind, idx, name, entity_id,
    entity_id_type, role, sector, relevance, sentiment, sentiment_score)
  select e.note_uri, 'organization', (ord-1)::int, en->>'name', en->>'entityId',
    en->>'entityIdType', en->>'role', en->>'sector', en->>'relevance', en->>'sentiment',
    nullif(en->>'sentimentScore','')::numeric
  from dof.enrichments e,
       lateral jsonb_array_elements(e.record->'organizationEntities') with ordinality as t(en, ord)
  where jsonb_typeof(e.record->'organizationEntities') = 'array';

  insert into dof.note_entities (note_uri, kind, idx, name, entity_id,
    entity_id_type, role, sector, relevance, sentiment, sentiment_score)
  select e.note_uri, 'person', (ord-1)::int, en->>'name', en->>'entityId',
    en->>'entityIdType', en->>'role', en->>'sector', en->>'relevance', en->>'sentiment',
    nullif(en->>'sentimentScore','')::numeric
  from dof.enrichments e,
       lateral jsonb_array_elements(e.record->'people') with ordinality as t(en, ord)
  where jsonb_typeof(e.record->'people') = 'array';
end $$;
