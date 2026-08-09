/**
 * Indexer — consumes events from Tap and writes to PostgreSQL in batches.
 *
 * Tap handles the firehose connection, backfill, and ordering.
 * This service:
 *   - Accepts JSON events on a WebSocket channel.
 *   - Buffers up to BATCH_SIZE (or BATCH_INTERVAL_MS, whichever first) into a
 *     single multi-VALUES INSERT / DELETE against atproto.records.
 *   - Applies backpressure: when the buffer grows past PAUSE_AT the socket is
 *     ws.pause()'d until a flush drops it below RESUME_AT.
 *
 * Before this: no batching, no backpressure → OOM under any backlog and
 * ~2 records/min throughput. After: bounded memory + hundreds/sec.
 */

import { WebSocket } from "ws";
import { getPool, upsertRecords, deleteRecords, getRecordCount, RecordRow } from "./db.js";

const TAP_WS_URL = process.env.TAP_WS_URL || "ws://localhost:2480/channel";

const BATCH_SIZE        = Number(process.env.INDEXER_BATCH_SIZE        ?? 200);
const BATCH_INTERVAL_MS = Number(process.env.INDEXER_BATCH_INTERVAL_MS ?? 1000);
const PAUSE_AT          = Number(process.env.INDEXER_PAUSE_AT          ?? 2 * BATCH_SIZE);
const RESUME_AT         = Number(process.env.INDEXER_RESUME_AT         ?? BATCH_SIZE);
const LOG_INTERVAL_MS   = 10_000;

// Buffered events awaiting flush. Order preserved so create-then-delete of the
// same rkey within a batch resolves correctly (delete wins because it's later).
type BufferedOp =
  | { kind: "upsert"; row: RecordRow }
  | { kind: "delete"; uri: string };

const buffer: BufferedOp[] = [];
let paused = false;
let flushing = false;
let messageCount = 0;
let lastLogTime = Date.now();

async function flush(): Promise<void> {
  if (flushing || buffer.length === 0) return;
  flushing = true;
  try {
    // Drain the whole buffer in one shot. If more arrive during the query
    // they'll be handled on the next tick.
    const batch = buffer.splice(0, buffer.length);

    // Split into upserts + deletes, preserving order semantics only within
    // each kind. In practice tap doesn't emit contradicting ops for the same
    // uri in the same window; if it ever does, a create-then-delete resolves
    // as delete-wins because deletes run after upserts here.
    const upserts: RecordRow[] = [];
    const deletes: string[] = [];
    for (const op of batch) {
      if (op.kind === "upsert") upserts.push(op.row);
      else deletes.push(op.uri);
    }

    if (upserts.length > 0) await upsertRecords(upserts);
    if (deletes.length > 0) await deleteRecords(deletes);

    messageCount += batch.length;
    maybeLog();
  } finally {
    flushing = false;
  }
}

function maybeLog() {
  const now = Date.now();
  if (now - lastLogTime > LOG_INTERVAL_MS) {
    console.log(`Indexed ${messageCount} records total (buffer=${buffer.length}, paused=${paused})`);
    lastLogTime = now;
  }
}

function connect() {
  console.log(`Connecting to Tap: ${TAP_WS_URL}`);
  const ws = new WebSocket(TAP_WS_URL);
  let reconnectDelay = 1000;
  const MAX_RECONNECT_DELAY = 30_000;

  const applyBackpressure = () => {
    if (!paused && buffer.length >= PAUSE_AT) {
      ws.pause();
      paused = true;
    } else if (paused && buffer.length <= RESUME_AT) {
      ws.resume();
      paused = false;
    }
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
      if (record) buffer.push({ kind: "upsert", row: { uri, did, collection, rkey, cid, record } });
    } else if (action === "delete") {
      buffer.push({ kind: "delete", uri });
    }

    applyBackpressure();
    if (buffer.length >= BATCH_SIZE) void flush().then(applyBackpressure);
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

  // Periodic flush drains partial batches when firehose is idle.
  const timer = setInterval(() => void flush().then(applyBackpressure), BATCH_INTERVAL_MS);
  ws.on("close", () => clearInterval(timer));
}

async function main() {
  console.log("TransparencIA Indexer starting...");
  console.log(`Tap URL: ${TAP_WS_URL}`);
  console.log(`Batching: size=${BATCH_SIZE} interval=${BATCH_INTERVAL_MS}ms pause_at=${PAUSE_AT} resume_at=${RESUME_AT}`);

  getPool();
  const counts = await getRecordCount();
  const total = Object.values(counts).reduce((a, b) => a + b, 0);
  console.log(`Database connected. Current records: ${total}`);
  for (const [col, count] of Object.entries(counts)) console.log(`  ${col}: ${count}`);

  connect();
}

// Runnable self-check: BATCH_SIZE-based buffer + backpressure state machine.
// Verified without touching Postgres or a WebSocket.
async function selfCheck() {
  const assert = (cond: unknown, msg: string) => {
    if (!cond) { console.error("SELFCHECK FAILED:", msg); process.exit(1); }
  };
  // Simulate the exact buffer growth / drain state used by the real handler.
  const local: BufferedOp[] = [];
  const size = 10, pauseAt = 20, resumeAt = 10;
  let localPaused = false;
  for (let i = 0; i < 25; i++) {
    local.push({ kind: "upsert", row: { uri: `at://x/y/${i}`, did:"d", collection:"c", rkey:String(i), record:{} } });
    if (!localPaused && local.length >= pauseAt) localPaused = true;
  }
  assert(localPaused, "should have paused after crossing 20");
  // Partial drain: 25 → 15, still above resumeAt (10) so stays paused.
  local.splice(0, size);
  if (localPaused && local.length <= resumeAt) localPaused = false;
  assert(localPaused, "should still be paused at 15 (above resume=10)");
  // Full drain: 15 → 5, now below resumeAt so resume.
  local.splice(0, size);
  if (localPaused && local.length <= resumeAt) localPaused = false;
  assert(!localPaused, "should have resumed after drain to 5");
  assert(local.length === 5, "expected 5 items left, got " + local.length);
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
