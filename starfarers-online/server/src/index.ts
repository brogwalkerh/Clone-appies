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
 *   DATA_DIR             default `data` (resolved against the working directory); one JSON
 *                        file per room is written there after every change and read back on
 *                        boot. Set to an empty string (DATA_DIR=) to keep rooms in memory only.
 *   ROOM_IDLE_HOURS      default 24; rooms with no activity for this long are deleted
 *   ROOM_FINISHED_HOURS  default 24; finished games are deleted this long after their last activity
 *
 * Expiry runs on boot (after the rooms are restored) and every 10 minutes;
 * a room with a connected player is never expired.
 */

import { createServer } from 'node:http';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { Server } from 'socket.io';
import { FileRoomPersistence } from './persist.js';
import { RoomStore } from './rooms.js';
import { attachSockets, type GameServer } from './socket.js';
import { createStaticHandler } from './static.js';

const here = dirname(fileURLToPath(import.meta.url));
const port = Number(process.env.PORT ?? 3000);
const host = process.env.HOST ?? '0.0.0.0';
const staticDir = process.env.STATIC_DIR ?? resolve(here, '..', '..', 'client', 'dist');
const corsOrigin = process.env.CORS_ORIGIN;
const dataDirEnv = process.env.DATA_DIR;
const dataDir = dataDirEnv === '' ? null : resolve(process.cwd(), dataDirEnv ?? 'data');
const HOUR_MS = 60 * 60 * 1000;
const SWEEP_EVERY_MS = 10 * 60 * 1000;

function hoursEnv(name: string, fallback: number): number {
  const raw = process.env[name];
  if (raw === undefined || raw === '') return fallback;
  const value = Number(raw);
  if (!Number.isFinite(value) || value <= 0) {
    console.warn(`${name}=${raw} is not a positive number of hours; using ${fallback}`);
    return fallback;
  }
  return value;
}
const idleHours = hoursEnv('ROOM_IDLE_HOURS', 24);
const finishedHours = hoursEnv('ROOM_FINISHED_HOURS', 24);

const serveStatic = createStaticHandler(staticDir);
const http = createServer((req, res) => {
  if (req.url === '/healthz') {
    res.writeHead(200, { 'content-type': 'application/json' }).end(JSON.stringify({ ok: true, rooms: store.size }));
    return;
  }
  serveStatic(req, res);
});

const io: GameServer = new Server(http, corsOrigin ? { cors: { origin: corsOrigin } } : {});
const store = new RoomStore({
  ...(dataDir ? { persistence: new FileRoomPersistence(dataDir) } : {}),
  idleMs: idleHours * HOUR_MS,
  finishedMs: finishedHours * HOUR_MS,
});

const restored = await store.restoreAll();
const swept = store.sweep();
console.log(
  dataDir
    ? `Rooms: ${restored} restored from ${dataDir}, ${swept.length} expired (idle ${idleHours} h, finished ${finishedHours} h)`
    : `Rooms: in memory only (DATA_DIR is empty); expiry idle ${idleHours} h, finished ${finishedHours} h`,
);
setInterval(() => {
  const removed = store.sweep();
  if (removed.length > 0) console.log(`Expired ${removed.length} room(s): ${removed.join(', ')}`);
}, SWEEP_EVERY_MS).unref();

attachSockets(io, store, { log: (m) => console.log(`[socket] ${m}`) });

http.listen(port, host, () => {
  console.log(`Starfarers Online server on http://${host}:${port} (static: ${staticDir})`);
});

// Finish pending room writes before exiting (node as PID 1 in Docker has no default SIGTERM handler).
for (const signal of ['SIGINT', 'SIGTERM'] as const) {
  process.once(signal, () => {
    void store.flush().finally(() => process.exit(0));
  });
}
