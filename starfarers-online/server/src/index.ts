/**
 * Single-process entry point: HTTP server that serves the built client and
 * hosts the Socket.IO game server (HANDOFF §7.7).
 *
 * Environment:
 *   PORT                 default 3000
 *   HOST                 default 0.0.0.0
 *   STATIC_DIR           default ../client/dist relative to this file's package
 *   TURN_TIMER_SECONDS   default unset (no timer); stored in room config only
 *   CORS_ORIGIN          default none (same origin); set for a separately hosted client
 */

import { createServer } from 'node:http';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { Server } from 'socket.io';
import { RoomStore } from './rooms.js';
import { attachSockets, type GameServer } from './socket.js';
import { createStaticHandler } from './static.js';

const here = dirname(fileURLToPath(import.meta.url));
const port = Number(process.env.PORT ?? 3000);
const host = process.env.HOST ?? '0.0.0.0';
const staticDir = process.env.STATIC_DIR ?? resolve(here, '..', '..', 'client', 'dist');
const corsOrigin = process.env.CORS_ORIGIN;

const serveStatic = createStaticHandler(staticDir);
const http = createServer((req, res) => {
  if (req.url === '/healthz') {
    res.writeHead(200, { 'content-type': 'application/json' }).end(JSON.stringify({ ok: true, rooms: store.size }));
    return;
  }
  serveStatic(req, res);
});

const io: GameServer = new Server(http, corsOrigin ? { cors: { origin: corsOrigin } } : {});
const store = new RoomStore();
attachSockets(io, store, { log: (m) => console.log(`[socket] ${m}`) });

http.listen(port, host, () => {
  console.log(`Starfarers Online server on http://${host}:${port} (static: ${staticDir})`);
});
