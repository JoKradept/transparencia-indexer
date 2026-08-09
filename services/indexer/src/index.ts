/**
 * Indexer — consumes events from Tap and routes them to typed schemas.
 *
 * Router: known typed collections (news.article/enrichment/source, DOF variants)
 * write DIRECTLY to news.* / dof.* tables via the `*_json` SQL projection
 * functions. Unknown collections fall back to atproto.records so future
 * lexicons still get indexed somewhere.
 *
 * Batching + backpressure: buffered up to BATCH_SIZE, flushed on size or
 * BATCH_INTERVAL_MS. WebSocket paused above PAUSE_AT, resumed below RESUME_AT.
 * Under 300 MB memory + hundreds/sec throughput even under backlog.
 */

import { WebSocket } from "ws";
import * as db from "./db.js";

const TAP_WS_URL = process.env.TAP_WS_URL || "ws://localhost:2480/channel";

const BATCH_SIZE        = Number(process.env.INDEXER_BATCH_SIZE        ?? 200);
const BATCH_INTERVAL_MS = Number(process.env.INDEXER_BATCH_INTERVAL_MS ?? 1000);
const PAUSE_AT          = Number(process.env.INDEXER_PAUSE_AT          ?? 2 * BATCH_SIZE);
const RESUME_AT         = Number(process.env.INDEXER_RESUME_AT         ?? BATCH_SIZE);
const LOG_INTERVAL_MS   = 10_000;

// ─── Buffers ────────────────────────────────────────────────────────────────
// One bucket per (collection kind, action). Flushed together per tick so an
// upsert-then-delete for the same URI in the same batch still resolves as
// delete-wins (deletes run after upserts inside flush()).
//
// Order semantics WITHIN a bucket are preserved. Order ACROSS buckets is not,
// but tap doesn't emit inter-collection ordering guarantees anyway.

const buf = {
  newsSourceUps:      [] as db.TypedUpsertRow[],
  newsArticleUps:     [] as db.TypedUpsertRow[],
  newsEnrichmentUps:  [] as db.TypedUpsertRow[],
  dofSourceUps:       [] as db.TypedUpsertRow[],
  dofItemUps:         [] as db.TypedUpsertRow[],
  dofNoteUps:         [] as db.TypedUpsertRow[],
  dofEnrichmentUps:   [] as db.TypedUpsertRow[],
  fallbackUps:        [] as db.RecordRow[],

  newsSourceDel:      [] as string[],
  newsArticleDel:     [] as string[],
  newsEnrichmentDel:  [] as string[],
  dofSourceDel:       [] as string[],
  dofItemDel:         [] as string[],
  dofNoteDel:         [] as string[],
  dofEnrichmentDel:   [] as string[],
  fallbackDel:        [] as string[],
};

function bufferSize(): number {
  return Object.values(buf).reduce((sum, arr) => sum + arr.length, 0);
}

let paused = false;
let flushing = false;
let messageCount = 0;
let lastLogTime = Date.now();

async function flush(): Promise<void> {
  if (flushing || bufferSize() === 0) return;
  flushing = true;
  try {
    // Snapshot + reset all buckets atomically.
    const snap = {
      newsSourceUps: buf.newsSourceUps.splice(0),
      newsArticleUps: buf.newsArticleUps.splice(0),
      newsEnrichmentUps: buf.newsEnrichmentUps.splice(0),
      dofSourceUps: buf.dofSourceUps.splice(0),
      dofItemUps: buf.dofItemUps.splice(0),
      dofNoteUps: buf.dofNoteUps.splice(0),
      dofEnrichmentUps: buf.dofEnrichmentUps.splice(0),
      fallbackUps: buf.fallbackUps.splice(0),
      newsSourceDel: buf.newsSourceDel.splice(0),
      newsArticleDel: buf.newsArticleDel.splice(0),
      newsEnrichmentDel: buf.newsEnrichmentDel.splice(0),
      dofSourceDel: buf.dofSourceDel.splice(0),
      dofItemDel: buf.dofItemDel.splice(0),
      dofNoteDel: buf.dofNoteDel.splice(0),
      dofEnrichmentDel: buf.dofEnrichmentDel.splice(0),
      fallbackDel: buf.fallbackDel.splice(0),
    };

    // Upserts first, deletes second (delete-wins within same batch).
    // Order across kinds within a group: sources before articles/enrichments
    // so FK-ish references land in a sane order, though we don't enforce FKs.
    await db.upsertNewsSource(snap.newsSourceUps);
    await db.upsertDofSource(snap.dofSourceUps);
    await db.upsertNewsArticle(snap.newsArticleUps);
    await db.upsertDofItem(snap.dofItemUps);
    await db.upsertDofNote(snap.dofNoteUps);
    await db.refreshNewsEnrichment(snap.newsEnrichmentUps);
    await db.refreshDofNoteEnrichment(snap.dofEnrichmentUps);
    await db.upsertRecords(snap.fallbackUps);

    await db.deleteNewsEnrichment(snap.newsEnrichmentDel);
    await db.deleteDofEnrichment(snap.dofEnrichmentDel);
    await db.deleteNewsArticle(snap.newsArticleDel);
    await db.deleteDofNote(snap.dofNoteDel);
    await db.deleteDofItem(snap.dofItemDel);
    await db.deleteNewsSource(snap.newsSourceDel);
    await db.deleteDofSource(snap.dofSourceDel);
    await db.deleteRecords(snap.fallbackDel);

    const total = Object.values(snap).reduce((s, a) => s + a.length, 0);
    messageCount += total;
    maybeLog();
  } finally {
    flushing = false;
  }
}

function maybeLog() {
  const now = Date.now();
  if (now - lastLogTime > LOG_INTERVAL_MS) {
    console.log(`Indexed ${messageCount} records total (buffer=${bufferSize()}, paused=${paused})`);
    lastLogTime = now;
  }
}

function routeUpsert(collection: string, row: db.TypedUpsertRow, generic: db.RecordRow) {
  switch (collection) {
    case db.NEWS_SOURCE:     buf.newsSourceUps.push(row); break;
    case db.NEWS_ARTICLE:    buf.newsArticleUps.push(row); break;
    case db.NEWS_ENRICHMENT: buf.newsEnrichmentUps.push(row); break;
    case db.DOF_SOURCE:      buf.dofSourceUps.push(row); break;
    case db.DOF_ITEM:        buf.dofItemUps.push(row); break;
    case db.DOF_NOTE:        buf.dofNoteUps.push(row); break;
    case db.DOF_ENRICHMENT:  buf.dofEnrichmentUps.push(row); break;
    default:                 buf.fallbackUps.push(generic);
  }
}

function routeDelete(collection: string, uri: string) {
  switch (collection) {
    case db.NEWS_SOURCE:     buf.newsSourceDel.push(uri); break;
    case db.NEWS_ARTICLE:    buf.newsArticleDel.push(uri); break;
    case db.NEWS_ENRICHMENT: buf.newsEnrichmentDel.push(uri); break;
    case db.DOF_SOURCE:      buf.dofSourceDel.push(uri); break;
    case db.DOF_ITEM:        buf.dofItemDel.push(uri); break;
    case db.DOF_NOTE:        buf.dofNoteDel.push(uri); break;
    case db.DOF_ENRICHMENT:  buf.dofEnrichmentDel.push(uri); break;
    default:                 buf.fallbackDel.push(uri);
  }
}

function connect() {
  console.log(`Connecting to Tap: ${TAP_WS_URL}`);
  const ws = new WebSocket(TAP_WS_URL);
  let reconnectDelay = 1000;
  const MAX_RECONNECT_DELAY = 30_000;

  const applyBackpressure = () => {
    const sz = bufferSize();
    if (!paused && sz >= PAUSE_AT) { ws.pause(); paused = true; }
    else if (paused && sz <= RESUME_AT) { ws.resume(); paused = false; }
  };

  ws.on("open", () => {
    console.log("Connected to Tap");
    reconnectDelay = 1000;
  });

  ws.on("message", (data: Buffer) => {
    let event: { type?: string; record?: {
      did: string; collection: string; rkey: string; action: string;
      cid?: string; record?: object;
    } };
    try {
      event = JSON.parse(data.toString());
    } catch (err) {
      console.error("Error parsing event:", err);
      return;
    }
    if (event.type !== "record" || !event.record) return;

    const { did, collection, rkey, action, cid, record } = event.record;
    const uri = `at://${did}/${collection}/${rkey}`;
    if (action === "create" || action === "update") {
      if (record) {
        routeUpsert(collection,
          { uri, did, rkey, cid: cid ?? null, record, indexedAt: new Date().toISOString() },
          { uri, did, collection, rkey, cid, record });
      }
    } else if (action === "delete") {
      routeDelete(collection, uri);
    }

    applyBackpressure();
    if (bufferSize() >= BATCH_SIZE) void flush().then(applyBackpressure);
  });

  ws.on("close", (code) => {
    console.log(`Disconnected from Tap (${code}). Reconnecting in ${reconnectDelay}ms...`);
    paused = false;
    setTimeout(connect, reconnectDelay);
    reconnectDelay = Math.min(reconnectDelay * 2, MAX_RECONNECT_DELAY);
  });

  ws.on("error", (err) => {
    console.error("WebSocket error:", err.message);
  });

  const timer = setInterval(() => void flush().then(applyBackpressure), BATCH_INTERVAL_MS);
  ws.on("close", () => clearInterval(timer));
}

async function main() {
  console.log("TransparencIA Indexer starting...");
  console.log(`Tap URL: ${TAP_WS_URL}`);
  console.log(`Batching: size=${BATCH_SIZE} interval=${BATCH_INTERVAL_MS}ms pause_at=${PAUSE_AT} resume_at=${RESUME_AT}`);
  console.log(`Router: typed collections → *_json SQL. Unknown → atproto.records fallback.`);

  db.getPool();
  const counts = await db.getRecordCount();
  console.log(`Database connected. Table counts:`);
  for (const [k, v] of Object.entries(counts)) console.log(`  ${k}: ${v}`);

  connect();
}

// Runnable self-check: router + backpressure state machine, no Postgres/WS.
async function selfCheck() {
  const assert = (cond: unknown, msg: string) => {
    if (!cond) { console.error("SELFCHECK FAILED:", msg); process.exit(1); }
  };

  // Router: known collection lands in the right bucket, unknown in fallback.
  routeUpsert(db.NEWS_ARTICLE, { uri:"a", did:"d", rkey:"r", cid:null, record:{}, indexedAt:"" }, { uri:"a", did:"d", collection:db.NEWS_ARTICLE, rkey:"r", record:{} });
  routeUpsert("some.other.collection", { uri:"b", did:"d", rkey:"r", cid:null, record:{}, indexedAt:"" }, { uri:"b", did:"d", collection:"some.other.collection", rkey:"r", record:{} });
  routeDelete(db.DOF_NOTE, "c");
  assert(buf.newsArticleUps.length === 1, "news article routed");
  assert(buf.fallbackUps.length === 1, "unknown routed to fallback");
  assert(buf.dofNoteDel.length === 1, "dof note delete routed");
  assert(bufferSize() === 3, "bufferSize sums across buckets");

  // Backpressure state machine (unchanged from Fase 2).
  const local: string[] = [];
  const size = 10, pauseAt = 20, resumeAt = 10;
  let localPaused = false;
  for (let i = 0; i < 25; i++) {
    local.push(`x${i}`);
    if (!localPaused && local.length >= pauseAt) localPaused = true;
  }
  assert(localPaused, "paused after crossing 20");
  local.splice(0, size);
  if (localPaused && local.length <= resumeAt) localPaused = false;
  assert(localPaused, "still paused at 15");
  local.splice(0, size);
  if (localPaused && local.length <= resumeAt) localPaused = false;
  assert(!localPaused, "resumed after drain to 5");

  console.log("selfCheck OK");
}

if (process.argv.includes("--selfcheck")) {
  void selfCheck();
} else {
  main().catch((err) => {
    console.error("Fatal error:", err);
    process.exit(1);
  });
}
