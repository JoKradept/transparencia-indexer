# TransparencIA Indexer — Agent Guide

This document tells an AI coding/query agent (Claude, Gemini, Cursor, Aider, …) everything it needs to **query** the TransparencIA news index and **maintain** the indexer codebase.

## What is this?

A GraphQL API over a real-time index of Mexican news articles published to the AT Protocol. The index contains:

- **~31,000 articles** from ~143 sources
- **~3,000 AI-generated enrichments** per article (political orientation, topics, entities, clickbait score, etc.)
- Updated in real time as new articles are published

### Architecture

```
PDS (pds.transparencia.tech)
   │ com.atproto.sync.subscribeRepos
   ▼
Tap (Bluesky firehose sync)            ← official AT Protocol sync utility
   │ ws://tap:2480/channel
   ▼
Indexer (Node.js, services/indexer/)   ← consumes events, UPSERTs to DB
   │
   ▼
PostgreSQL (Supabase, atproto.records JSONB)
   │
   ▼
GraphQL API (services/graphql/, deployed to Vercel)
   • Auto-generated from lexicons via lex-gql
   • Adapter in services/graphql/src/adapter.ts maps to Postgres
```

### Sister repos

| Repo | Role |
|---|---|
| `TransparencIA-MX/transparencia-lexicons` | ATProto Lexicon JSON schemas, vendored here as the `lexicons/` submodule. `lex-gql` reads these to generate the GraphQL types. |
| `TransparencIA-MX/news_fetcher` | The ingester that writes new articles to the PDS — the upstream of the firehose this indexer consumes. |

## Endpoint

```
POST http://100.81.242.36:4000/graphql
Content-Type: application/json
X-API-Key: <api-key>
```

All queries are POST requests with a JSON body `{ "query": "..." }`.

---

## Data model

### Article (`techTransparenciaNewsArticle`)

A news article as published by a source.

| Field | Type | Description |
|---|---|---|
| `uri` | String | AT Protocol record URI |
| `title` | String | Article headline |
| `url` | String | Original URL |
| `author` | String | Byline |
| `description` | String | Short summary (no body fallback — body lives in `content`) |
| `content` | String | Full HTML body when the feed exposes one |
| `imageUrl` | String | Hero image |
| `mediaCaption` | String | Caption for the hero image |
| `tags` | [String] | All categories the feed provided |
| `feedCategory` | String | **DEPRECATED** — equals `tags[0]`, kept for back-compat |
| `publishedAt` | String | ISO 8601 publish date |
| `updatedAt` | String | ISO 8601 last-edit date (when distinct from `publishedAt`) |
| `originalSource` | Object | `{name?, url?}` — when syndicated from another outlet |
| `language` | String | `es`, `en`, etc. |
| `indexedAt` | String | When indexed |

### Source (`techTransparenciaNewsSource`)

A news outlet.

| Field | Type | Description |
|---|---|---|
| `name` | String | Internal identifier |
| `displayName` | String | Human-readable name |
| `baseUrl` | String | Homepage URL |
| `country` | String | Country code |
| `language` | String | Primary language |
| `cms` | String | CMS platform |
| `description` | String | About the outlet |

### Enrichment (`techTransparenciaNewsEnrichment`)

AI-generated analysis of an article. One enrichment per article.

| Field | Type | Description |
|---|---|---|
| `summary` | String | Neutral summary |
| `neutralHeadline` | String | Rewritten headline without bias |
| `politicalOrientation` | String | `left`, `center-left`, `center`, `center-right`, `right` |
| `orientationConfidence` | String | Confidence score (0–1) |
| `orientationReasoning` | String | Explanation of orientation |
| `emotionalTone` | String | `neutral`, `alarming`, `hopeful`, `outraged`, etc. |
| `impactLevel` | Int | 1–5 civic impact score |
| `impactReasoning` | String | Why this impact level |
| `eventType` | String | `political`, `economic`, `crime`, `social`, etc. |
| `readingLevel` | String | `basic`, `intermediate`, `advanced` |
| `factCheckability` | Int | 1–5 (5 = highly verifiable) |
| `clickbaitScore` | Int | 1–5 (5 = very clickbait) |
| `clickbaitReasoning` | String | Why this score |
| `topics` | Array | Topic tags |
| `people` | Array | Named people mentioned |
| `organizationEntities` | Array | Organizations mentioned |
| `locations` | Array | Geographic locations |
| `claims` | Array | Factual claims made |
| `relatedKeywords` | Array | Keywords |
| `region` | String | Geographic region |
| `contentDomain` | String | Subject domain |
| `modelUsed` | String | AI model that generated this |
| `costUsd` | String | Cost to generate |

---

## Queries

### 1. List articles

```graphql
{
  techTransparenciaNewsArticle(first: 10) {
    edges {
      node {
        uri
        title
        url
        publishedAt
        language
      }
    }
    pageInfo {
      hasNextPage
      endCursor
    }
  }
}
```

### 2. Filter articles

```graphql
{
  techTransparenciaNewsArticle(
    where: { language: { eq: "es" } }
    sortBy: [{ field: "publishedAt", dir: "desc" }]
    first: 20
  ) {
    edges {
      node { title url publishedAt }
    }
  }
}
```

### 3. Search articles by keyword

```graphql
{
  techTransparenciaNewsArticle(
    where: { title: { contains: "AMLO" } }
    first: 10
  ) {
    edges {
      node { title url publishedAt }
    }
  }
}
```

### 4. Get article with its enrichment

```graphql
{
  techTransparenciaNewsArticle(
    where: { title: { contains: "elecciones" } }
    first: 5
  ) {
    edges {
      node {
        title
        url
        publishedAt
        techTransparenciaNewsEnrichmentViaArticle {
          edges {
            node {
              summary
              neutralHeadline
              politicalOrientation
              orientationConfidence
              emotionalTone
              impactLevel
              clickbaitScore
              topics
              people
              locations
            }
          }
        }
      }
    }
  }
}
```

### 5. Get enrichments filtered by political orientation

```graphql
{
  techTransparenciaNewsEnrichment(
    where: { politicalOrientation: { eq: "right" } }
    sortBy: [{ field: "createdAt", dir: "desc" }]
    first: 10
  ) {
    edges {
      node {
        neutralHeadline
        politicalOrientation
        orientationConfidence
        orientationReasoning
        emotionalTone
        techTransparenciaNewsArticleByDid {
          title
          url
          publishedAt
        }
      }
    }
  }
}
```

### 6. Get high-impact articles

```graphql
{
  techTransparenciaNewsEnrichment(
    where: { impactLevel: { gte: 4 } }
    sortBy: [{ field: "createdAt", dir: "desc" }]
    first: 10
  ) {
    edges {
      node {
        impactLevel
        impactReasoning
        summary
        topics
        techTransparenciaNewsArticleByDid {
          title
          url
        }
      }
    }
  }
}
```

### 7. Get clickbait articles

```graphql
{
  techTransparenciaNewsEnrichment(
    where: { clickbaitScore: { gte: 4 } }
    first: 10
  ) {
    edges {
      node {
        clickbaitScore
        clickbaitReasoning
        neutralHeadline
        techTransparenciaNewsArticleByDid {
          title
          url
        }
      }
    }
  }
}
```

### 8. Aggregate — count articles by tag

```graphql
{
  techTransparenciaNewsArticleAggregate(
    groupBy: [tags]
    orderBy: COUNT_DESC
    limit: 20
  ) {
    count
    groups {
      tags
      count
    }
  }
}
```

> `feedCategory` was renamed to `tags[]` in lexicon v2. For back-compat the field
> `feedCategory` still exists (it equals `tags[0]`) but new code should
> aggregate by `tags`.

### 9. Aggregate — political orientation breakdown

```graphql
{
  techTransparenciaNewsEnrichmentAggregate(
    groupBy: [politicalOrientation]
    orderBy: COUNT_DESC
  ) {
    count
    groups {
      politicalOrientation
      count
    }
  }
}
```

### 10. List sources

```graphql
{
  techTransparenciaNewsSource(first: 50) {
    edges {
      node {
        displayName
        baseUrl
        country
        language
      }
    }
  }
}
```

---

## Pagination

The API uses cursor-based pagination.

```graphql
# First page
{
  techTransparenciaNewsArticle(first: 20) {
    edges { node { title } }
    pageInfo {
      hasNextPage
      endCursor
    }
  }
}

# Next page — pass endCursor as `after`
{
  techTransparenciaNewsArticle(first: 20, after: "<endCursor>") {
    edges { node { title } }
    pageInfo {
      hasNextPage
      endCursor
    }
  }
}
```

---

## Filter operators

| Operator | Meaning |
|---|---|
| `eq` | Equals |
| `in` | In list |
| `contains` | ILIKE `%value%` |
| `gt` / `gte` | Greater than / or equal |
| `lt` / `lte` | Less than / or equal |

---

## Relationship traversal

Each type has reverse-join fields to navigate related records:

- `Article.techTransparenciaNewsEnrichmentViaArticle` → enrichments for this article
- `Enrichment.techTransparenciaNewsArticleByDid` → the article this enrichment belongs to
- `Source.techTransparenciaNewsArticleViaSource` → all articles from this source
- `Article.techTransparenciaNewsSourceByDid` → the source of this article

---

## Suggested agent workflows

**"What are the most important news stories today?"**
→ Query enrichments with `impactLevel >= 4`, sorted by `createdAt desc`, get `summary` and `topics`.

**"Is coverage of topic X biased?"**
→ Query enrichments where `topics contains X`, aggregate by `politicalOrientation`.

**"Find all articles about a person"**
→ Query enrichments where `people contains <name>`, traverse to articles for URLs.

**"Which sources publish the most clickbait?"**
→ Query enrichments with `clickbaitScore >= 4`, traverse to articles, then to sources, aggregate by `displayName`.

**"Summarize today's news on a topic"**
→ Query articles with `title contains <keyword>` and `publishedAt gte <today>`, get `summary` and `neutralHeadline` from enrichments.

---

## For any AI coding agent (Claude, Gemini, Cursor, Aider, …)

This file is **model-agnostic** — the conventions apply regardless of which agent edits the repo.

### When querying

- Always pass `X-API-Key` (the public API key is rate-limited per agent).
- Prefer the v2 fields (`content`, `tags`, `updatedAt`, `originalSource`, `mediaCaption`) over the deprecated `feedCategory`.
- Records before 2026-05 use hex rkeys and lack v2 fields — they will return `null` for those fields, not an error.

### When maintaining the code

- Conversation language is **Spanish** (maintainer is in Mexico). Commits are in English.
- Commit style: conventional commits (`feat:`, `fix:`, `docs:`, `deps:`, `ops:`).
- The `lexicons/` directory is a **git submodule** pointing at `TransparencIA-MX/transparencia-lexicons`. Do not edit JSON files in it directly — the source of truth lives in the sister repo. Bump the submodule pointer (`git submodule update --remote lexicons && git add lexicons`) when a new schema version is released.
- The maintainer's GitHub account (`JoKradept`) has **read-only** access to this repo. Open PRs from `JoKradept/transparencia-indexer` fork; the project lead (Diego) merges. Same pattern for `transparencia-lexicons`.
- Production lives on Vercel; merges to `main` trigger an auto-rebuild that regenerates the GraphQL schema from the current submodule pointer. Never push directly to `main` — go through PR review.

### Surfacing changes

When a code change is non-trivial (more than a typo fix), include in the PR description:

- Which lexicon fields are affected
- Whether the GraphQL schema changes (rebuilds happen automatically; consumers may need to update queries)
- Whether the indexer needs to backfill any column / index

Ask the maintainer before any operation that affects production data: schema migrations, backfills, deletes, or anything in the `atproto.records` Supabase table.
