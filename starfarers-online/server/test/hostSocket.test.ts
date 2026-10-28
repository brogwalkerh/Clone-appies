/**
 * Host controls over Socket.IO (HANDOFF §8.3): kick (the kicked socket hears
 * `kicked` and its token no longer resumes; non-host and started-game kicks
 * are refused), transfer (non-host refused, works in game), the automatic
 * hand-over on a fake clock, and the lobby's expiry fields.
 */

import type { ClientToServerEvents, LobbyView, ServerToClientEvents } from '@starfarers/shared';
import { createServer, type Server as HttpServer } from 'node:http';
import type { AddressInfo } from 'node:net';
import { Server } from 'socket.io';
import { io as connect, type Socket } from 'socket.io-client';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { RoomStore } from '../src/rooms.js';
import { attachSockets, type AttachedSockets, type GameServer } from '../src/socket.js';
import { Clock, FakeScheduler } from './fakeClock.js';

type Client = Socket<ServerToClientEvents, ClientToServerEvents>;

const HANDOVER = 120_000;
const IDLE = 3_600_000;
let http: HttpServer;
let url = '';
let store: RoomStore;
let attached: AttachedSockets;
const clock = new Clock();
const scheduler = new FakeScheduler(clock);
const clients: Client[] = [];

beforeAll(async () => {
  http = createServer();
  const io: GameServer = new Server(http);
  store = new RoomStore({ seedFactory: () => 'host-socket-seed', now: clock.now, handoverMs: HANDOVER, idleMs: IDLE });
  attached = attachSockets(io, store, { scheduler });
  await new Promise<void>((r) => http.listen(0, '127.0.0.1', () => r()));
  url = `http://127.0.0.1:${(http.address() as AddressInfo).port}`;
});

afterAll(async () => {
  for (const c of clients) c.disconnect();
  await new Promise<void>((r) => http.close(() => r()));
});

function client(): Client {
  const c: Client = connect(url, { transports: ['websocket'], forceNew: true });
  clients.push(c);
  return c;
}

function call<E extends keyof ClientToServerEvents>(c: Client, event: E, payload: Parameters<ClientToServerEvents[E]>[0]) {
  type Reply = Parameters<Parameters<ClientToServerEvents[E]>[1]>[0];
  return new Promise<Reply>((resolve) => {
    (c.emit as (ev: string, p: unknown, ack: (r: Reply) => void) => void)(event, payload, resolve);
  });
}

function once<E extends keyof ServerToClientEvents>(c: Client, event: E) {
  type Arg = Parameters<ServerToClientEvents[E]>[0];
  return new Promise<Arg>((resolve) => {
    (c.once as (ev: string, fn: (a: Arg) => void) => void)(event, resolve);
  });
}

function expectOk<T>(reply: { ok: true; value: T } | { ok: false; error: { message: string } }): T {
  if (!reply.ok) throw new Error(`expected ok, got ${reply.error.message}`);
  return reply.value;
}

const until = async (cond: () => boolean, what: string) => {
  // A wall-clock budget, not a count of 10 ms polls: under load each poll can take far longer than 10 ms.
  const end = Date.now() + 10_000;
  while (!cond() && Date.now() < end) await new Promise((r) => setTimeout(r, 10));
  if (!cond()) throw new Error(`timed out waiting for ${what}`);
};

async function room(n: number) {
  const cs = Array.from({ length: n }, () => client());
  const names = ['Ann', 'Bob', 'Cid', 'Dee'];
  const host = expectOk(await call(cs[0]!, 'createRoom', { roomName: 'Hosts', playerName: 'Ann' }));
  const code = host.session.roomCode;
  const replies = [host];
  for (let i = 1; i < n; i++) {
    clock.t += 1; // distinct connection times, in seat order
    replies.push(expectOk(await call(cs[i]!, 'joinRoom', { code, playerName: names[i]! })));
  }
  return { cs, code, replies };
}

describe('host controls over sockets', () => {
  it('kick: refused for non-hosts; the kicked socket hears it and its token cannot resume', async () => {
    const { cs, code, replies } = await room(4);
    const [a, b, c, d] = cs as [Client, Client, Client, Client];
    expect(await call(b, 'kickPlayer', { playerId: 'p3' })).toMatchObject({ ok: false, error: { code: 'notHost' } });
    expect(await call(a, 'kickPlayer', { playerId: 'p1' })).toMatchObject({ ok: false, error: { code: 'badRequest' } });

    const kicked = once(d, 'kicked');
    const lobbyA = once(a, 'lobby');
    expect(expectOk(await call(a, 'kickPlayer', { playerId: 'p4' }))).toEqual({ kicked: 'p4' });
    expect((await kicked).roomCode).toBe(code);
    const view = await lobbyA;
    expect(view.players.map((p) => p.id)).toEqual(['p1', 'p2', 'p3']);
    expect(view.messages.at(-1)?.from).toBe('room');

    // The kicked socket is out of the room: no more lobby broadcasts, room events refused, the token is dead.
    let laterLobby = false;
    d.on('lobby', () => {
      laterLobby = true;
    });
    expect(await call(d, 'chat', { text: 'still here?' })).toMatchObject({ ok: false, error: { code: 'notInRoom' } });
    expect(await call(d, 'resume', { roomCode: code, playerToken: replies[3]!.session.playerToken })).toMatchObject({ ok: false, error: { code: 'badToken' } });
    expectOk(await call(c, 'chat', { text: 'bye Dee' }));
    expect(laterLobby).toBe(false);

    // A started game keeps every seat.
    expectOk(await call(a, 'startGame', {}));
    expect(await call(a, 'kickPlayer', { playerId: 'p3' })).toMatchObject({ ok: false, error: { code: 'alreadyStarted' } });
    expect(store.getRoom(code)!.players).toHaveLength(3);
  });

  it('transfer: refused for non-hosts; works in the lobby and in game; everyone sees the host', async () => {
    const { cs, code } = await room(3);
    const [a, b, c] = cs as [Client, Client, Client];
    expect(await call(b, 'transferHost', { playerId: 'p2' })).toMatchObject({ ok: false, error: { code: 'notHost' } });
    const lobbyC = once(c, 'lobby');
    expect(expectOk(await call(a, 'transferHost', { playerId: 'p2' }))).toEqual({ hostId: 'p2' });
    expect((await lobbyC).hostId).toBe('p2');
    expect(await call(a, 'startGame', {})).toMatchObject({ ok: false, error: { code: 'notHost' } });
    expectOk(await call(b, 'startGame', {}));
    const seen: LobbyView[] = [];
    a.on('lobby', (l) => seen.push(l));
    expectOk(await call(b, 'transferHost', { playerId: 'p3' }));
    await until(() => seen.at(-1)?.hostId === 'p3', 'the transferred lobby');
    const view = seen.at(-1)!;
    expect(view.started).toBe(true);
    expect(view.players.find((p) => p.isHost)?.id).toBe('p3');
    expect(store.getRoom(code)!.hostId).toBe('p3');
  });

  it('automatic hand-over after HOST_HANDOVER_MS offline, on the fake clock', async () => {
    const { cs, code } = await room(3);
    const [a, b, c] = cs as [Client, Client, Client];
    const r = store.getRoom(code)!;
    const lobbies: LobbyView[] = [];
    c.on('lobby', (l) => lobbies.push(l));
    a.disconnect();
    await until(() => lobbies.some((l) => l.hostHandoverAt != null), 'the pending hand-over in the lobby');
    const due = lobbies.at(-1)!.hostHandoverAt!;
    expect(due).toBe(clock.t + HANDOVER);
    expect(attached.handovers.armedAt(code)).toBe(due);
    scheduler.advance(HANDOVER - 1);
    expect(r.hostId).toBe('p1');
    scheduler.advance(1);
    expect(r.hostId).toBe('p2'); // Bob joined before Cid: the longest-connected
    await until(() => lobbies.at(-1)?.hostId === 'p2', 'the hand-over lobby');
    expect(lobbies.at(-1)!.hostHandoverAt).toBeNull();
    expect(lobbies.at(-1)!.messages.at(-1)?.text).toMatch(/Ann has been offline for 2 min; Bob is now the host/);
    expect(attached.handovers.armedAt(code)).toBeNull();
    expectOk(await call(b, 'transferHost', { playerId: 'p3' }));
  });

  it('the lobby carries expiresAt = last activity + idleMs', async () => {
    const c = client();
    const reply = expectOk(await call(c, 'createRoom', { roomName: 'Exp', playerName: 'Eve' }));
    const r = store.getRoom(reply.session.roomCode)!;
    expect(reply.lobby.idleMs).toBe(IDLE);
    expect(reply.lobby.expiresAt).toBe(r.updatedAt + IDLE);
    clock.t += 1_000;
    const lobby = once(c, 'lobby');
    expectOk(await call(c, 'configureRoom', { variant: 'strategic' }));
    expect((await lobby).expiresAt).toBe(clock.t + IDLE);
  });
});
