# transparencia-indexer

AT Protocol indexer + GraphQL API for [TransparencIA](https://transparencia.tech).

Consumes records from an AT Protocol PDS via [Tap](https://github.com/bluesky-social/indigo/tree/main/cmd/tap), routes them into typed Postgres tables per lexicon, and exposes them through an auto-generated GraphQL API using [lex-gql](https://tangled.org/chadtmiller.com/lex-gql).

## Architecture

```
PDS (pds.transparencia.tech)
  │
  │ com.atproto.sync.subscribeRepos
  ▼
┌─────────────────────────────────────┐
│  Tap                                │
│  Firehose consumer + backfill       │
│  JSON events → ws://tap:2480/channel│
└──────────────┬──────────────────────┘
               │
               ▼
┌─────────────────────────────────────┐
│  Indexer (Node.js)                  │
│  - Buffered + backpressured WS      │
│  - Router by collection:            │
│    · Known lexicons → typed tables  │
│      via *_json SQL functions       │
│    · Unknown → atproto.records      │
└──────────────┬──────────────────────┘
               │
               ▼
┌─────────────────────────────────────┐
│  PostgreSQL (self-hosted, postgres:16) │
│  - news.{sources, articles,         │
│         enrichments, article_*}     │
│  - dof.{sources, items, notes,      │
│        enrichments, note_*}         │
│  - atproto.records (fallback)       │
│  - atproto.article_story + stories  │
│    (clusterer output, materialized) │
└──────────────┬──────────────────────┘
               │
               ▼
┌─────────────────────────────────────┐
│  GraphQL API (lex-gql adapter)      │
│  Routes known collections to typed  │
│  tables; falls back to atproto.records │
└─────────────────────────────────────┘

Systemd timer every 10 min:
  atproto.cluster_stories()  →  refreshes article_story + rebuild_stories()
```

## Quick Start

```bash
git clone --recurse-submodules https://github.com/TransparencIA-MX/transparencia-indexer.git
cd transparencia-indexer

cp .env.example .env
# Edit .env with Postgres + AT Protocol credentials

# Migration: creates atproto/news/dof schemas + typed tables + _json functions
docker compose build migrate indexer graphql
docker compose run --rm migrate

# One-shot backfill (only needed first time, or after schema drift)
docker compose exec -T postgres psql -U transparencia -d transparencia -c \
  "SELECT news.rebuild_all(); SELECT dof.rebuild_all();"

# Start all services
docker compose up -d

# Seed Tap with the DID (triggers backfill from PDS)
docker compose --profile tools run --rm seed

# Story clustering (optional — needs services/story-clusterer/*.{service,timer})
sudo cp services/story-clusterer/story-clusterer.{service,timer} /etc/systemd/system/
sudo systemctl enable --now story-clusterer.timer

# Health
curl http://localhost:2480/health           # Tap
curl -X POST http://localhost:4000/graphql -H 'Content-Type: application/json' \
     -d '{"query":"{ techTransparenciaNewsArticle(first:1){ edges { node { uri title } } } }"}'
```

## Services

### Tap
[bluesky-social/indigo/tap](https://github.com/bluesky-social/indigo/tree/main/cmd/tap): firehose sync utility. Handles backfill, verification, and forwards events over WebSocket. Runs with `TAP_DISABLE_ACKS=true` (fire-and-forget mode). Known gotcha: outbox events accumulate if the client is briefly disconnected — see `scripts/drain_outbox.sh` for the manual drain if `outbox_buffers` grows.

### Indexer
Node.js WebSocket client. Buffers events into per-collection batches, flushes on size (`INDEXER_BATCH_SIZE`, default 200) or interval (`INDEXER_BATCH_INTERVAL_MS`, default 1000ms). Applies WebSocket backpressure at `PAUSE_AT`/`RESUME_AT` thresholds so the buffer stays bounded even under backlog. Router in `src/db.ts`:
- **Typed collections** (`news.*`, DOF): call the matching `*_json` SQL function → direct write to `news.*` / `dof.*`. Skips `atproto.records`.
- **Unknown collections**: fall back to `atproto.records` (bucket for future lexicons).

Run `node dist/index.js --selfcheck` to assert the router + backpressure state machine without touching Postgres or a WebSocket.

### GraphQL API
Auto-generated from AT Protocol lexicons via [lex-gql](https://tangled.org/chadtmiller.com/lex-gql). The `adapter.ts` in `services/graphql/src/` implements lex-gql's `query` port against Postgres: routes each `findMany`/`aggregate` to the appropriate typed table (`news.articles`, `dof.notes`, etc.) or falls back to `atproto.records` for unknown collections. `enrichment_uri` is used as the AT-URI column on enrichment tables (their PK is `article_uri`/`note_uri`).

### Story clusterer
plpgsql-only. `atproto.cluster_stories()` reads `news.enrichments`, computes an entity bag (topics ∪ people.name ∪ organizationEntities.name ∪ relatedKeywords, normalized), and groups articles by Jaccard similarity ≥ 0.35 in a rolling 72h window. Writes to `atproto.article_story`. Then calls `atproto.rebuild_stories()` which materializes `atproto.stories` (one row per story with pre-aggregated size, timeline, top titles, top topics) so downstream consumers get an indexed read path. See `services/story-clusterer/README.md` for tuning + upgrade path (embeddings + pgvector).

## Schemas

| Schema | Contents | Fed by |
|---|---|---|
| `news` | `sources`, `articles`, `enrichments`, `article_locations`, `article_entities` | Router → `news.upsert_*_json()` |
| `dof` | `sources`, `items`, `notes`, `enrichments`, `note_locations`, `note_entities` | Router → `dof.upsert_*_json()` |
| `atproto` | `records` (fallback for unknown collections), `article_story`, `stories`, `actors`, `metadata` | Router fallback + clusterer |

Typed tables keep the full `record jsonb` alongside extracted columns so no data is lost. Rebuild from a clean slate: `SELECT news.rebuild_all(); SELECT dof.rebuild_all(); SELECT atproto.rebuild_stories();`

## Configuration

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `DATABASE_URL` | Yes | — | PostgreSQL connection string |
| `ATPROTO_DID` | Yes | — | DID to track (drives the seed job) |
| `TAP_RELAY_URL` | No | `bsky.network` | AT Protocol relay |
| `TAP_COLLECTION_FILTERS` | No | — | Collections to index (comma-separated) |
| `TAP_DISABLE_ACKS` | No | `true` | Fire-and-forget mode |
| `TAP_WS_URL` | No | `ws://tap:2480/channel` | Indexer's Tap connection |
| `INDEXER_BATCH_SIZE` | No | `200` | Events per flush |
| `INDEXER_BATCH_INTERVAL_MS` | No | `1000` | Timer-triggered flush interval |
| `INDEXER_PAUSE_AT` | No | `400` | Buffer size to `ws.pause()` |
| `INDEXER_RESUME_AT` | No | `200` | Buffer size to `ws.resume()` |
| `GRAPHQL_PORT` | No | `4000` | GraphQL server port |
| `GRAPHQL_API_KEY` | No | — | API key for authenticated access |

## Adding a new lexicon

1. Drop the lexicon JSON into `lexicons/` submodule
2. Add table + `*_json` functions in `services/indexer/schema_<domain>.sql` (mirror the `news` / `dof` shape)
3. Extend `migrate.ts` to load the new schema file
4. Add the collection to `TYPED_COLLECTIONS` in `services/indexer/src/db.ts` + a routing case
5. Add the mapping in `TYPED_TABLES` in `services/graphql/src/adapter.ts`
6. Load the lexicon in `services/graphql/src/adapter.ts` `loadLexicons()`
7. `docker compose build migrate indexer graphql && docker compose run --rm migrate`
8. Redeploy `indexer` and `graphql`

## License

AGPL-3.0
