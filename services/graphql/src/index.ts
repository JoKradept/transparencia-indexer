/**
 * GraphQL API server — auto-generated from AT Protocol lexicons via lex-gql,
 * plus a small REST surface at /api/stories for consumers that don't want to
 * open a Postgres connection per request (e.g. Vercel serverless).
 */

import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { createYoga } from "graphql-yoga";
import pg from "pg";
import { createAdapter } from "./adapter.js";
import { handleStoriesRoute } from "./routes/stories.js";

const PORT = parseInt(process.env.GRAPHQL_PORT || "4000", 10);
const API_KEY = process.env.GRAPHQL_API_KEY;

async function main() {
  const { schema } = await createAdapter();

  const yoga = createYoga({
    schema,
    graphqlEndpoint: "/graphql",
    landingPage: true,
    cors: { origin: "*", methods: ["POST", "GET", "OPTIONS"] },
  });

  // Shared pool for the REST routes. Pool size covers the CDN's origin traffic
  // (with s-maxage=600, one refresh per 10 min covers thousands of viewers).
  const pool = new pg.Pool({
    connectionString: process.env.DATABASE_URL,
    max: 5,
    idleTimeoutMillis: 30000,
  });

  const server = createServer(async (req: IncomingMessage, res: ServerResponse) => {
    if (req.url?.startsWith("/api/stories")) return handleStoriesRoute(req, res, pool);
    return yoga(req, res);
  });

  server.listen(PORT, () => {
    console.log(`GraphQL API running at http://localhost:${PORT}/graphql`);
    console.log(`Stories REST at   http://localhost:${PORT}/api/stories`);
    console.log(`Auth: ${API_KEY ? "API key required" : "open (no auth)"}`);
  });
}

main().catch((err) => {
  console.error("Failed to start GraphQL server:", err);
  process.exit(1);
});
