# story-clusterer

Groups articles that cover the same story by comparing the entity bag
(topics ∪ relatedKeywords ∪ people.name ∪ organizationEntities.name) of their
`tech.transparencia.news.enrichment` records with Jaccard similarity, within
a rolling 72h window.

Runs entirely inside the indexer Postgres — plpgsql function invoked by a
systemd timer. No extra containers, no extra deps.

## What it produces

Table `atproto.article_story`:

| column          | meaning                                           |
|-----------------|---------------------------------------------------|
| `article_uri`   | PK, the strongRef URI of the article              |
| `story_id`      | opaque id shared by all articles in the same story|
| `jaccard_score` | similarity to the cluster when joined (1.0 = seed)|
| `entity_bag`    | normalized bag used to compute similarity         |
| `created_at`    | enrichment createdAt (used for the 72h window)    |
| `computed_at`   | when the row was inserted                         |

## Tunables (function args, all optional)

- `min_jaccard` (default `0.35`) — threshold to join an existing cluster.
- `min_bag_size` (default `3`) — enrichments with fewer than N entities are
  skipped (avoids grouping by one generic topic).
- `window_hours` (default `72`) — cluster horizon in either direction.
- `since` (default `'2000-01-01'`) — only consider enrichments after this.

## Deploy from scratch

```bash
# 1. Apply schema (idempotent).
docker cp services/story-clusterer/schema.sql indexer-postgres-1:/tmp/
docker exec indexer-postgres-1 sh -c \
  'psql -U $POSTGRES_USER -d $POSTGRES_DB -f /tmp/schema.sql'

# 2. Initial backfill (whole history).
docker exec indexer-postgres-1 sh -c \
  'psql -U $POSTGRES_USER -d $POSTGRES_DB -c "SELECT * FROM atproto.cluster_stories();"'

# 3. Install systemd timer for ongoing 10-minute passes.
sudo install -o root -g root -m 644 \
  services/story-clusterer/story-clusterer.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now story-clusterer.timer
```

## Ops

```bash
# See when the next pass fires.
sudo systemctl list-timers story-clusterer.timer

# Latest run output (processed / new_clusters / joined_existing counters).
sudo journalctl -u story-clusterer.service -n 20

# Force a pass now.
sudo systemctl start story-clusterer.service
```

## Known limits (ponytail: revisit if user pain is real)

- **Opinion columns with 1-2 word titles + generic entity bags** can false-positive
  into a shared cluster. Raise `min_bag_size` from 3 → 5 to filter, at the cost
  of losing some real short-headline stories.
- **Missed paraphrases** — outlets that rewrite entity names differently (e.g.
  "Claudia Sheinbaum" vs "la presidenta") don't overlap. Upgrade path:
  embeddings on `neutralHeadline + summary` with pgvector.
- **O(N × candidates_per_window)** iteration. Fine at 30k enrichments, budget
  a rewrite in `atproto.cluster_stories` if this grows past ~500k.
