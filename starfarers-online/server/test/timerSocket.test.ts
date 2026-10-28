/**
 * Turn timer over Socket.IO (HANDOFF §8.2): `deadlineAt` reaches every
 * client in the `state` payload and the lobby, and an expired turn is played
 * out by the server and broadcast like any other actions, with a "timer: …"
 * chat line. The clock and the timeouts are fake; the sockets are real.
 */

import type { ChatMessage, ClientToServerEvents, LobbyView, ServerToClientEvents } from '@starfarers/shared';
import { createServer, type Server as HttpServer } from 'node:http';
import type { AddressInfo } from 'node:net';
import { Server } from 'socket.io';
import { io as connect, type Socket } from 'socket.io-client';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { RoomStore } from '../src/rooms.js';
import { attachSockets, type AttachedSockets, type GameServer } from '../src/socket.js';
import { Clock, FakeScheduler } from './fakeClock.js';

type Client = Socket<ServerToClientEvents, ClientToServerEvents>;
type StatePayload = Parameters<ServerToClientEvents['state']>[0];

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
  store = new RoomStore({ seedFactory: () => 'timer-socket-seed', now: clock.now });
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
  for (let i = 0; i < 200 && !cond(); i++) await new Promise((r) => setTimeout(r, 10));
  if (!cond()) throw new Error(`timed out waiting for ${what}`);
};

describe('turn timer over sockets', () => {
  it('configureRoom sets it, deadlineAt rides on state and lobby, expiry broadcasts the automatic turn', async () => {
    const a = client();
    const b = client();
    const c = client();
    const ra = expectOk(await call(a, 'createRoom', { roomName: 'Timer', playerName: 'Ann' }));
    const code = ra.session.roomCode;
    expectOk(await call(b, 'joinRoom', { code, playerName: 'Bob' }));
    expectOk(await call(c, 'joinRoom', { code, playerName: 'Cid' }));

    expect(await call(b, 'configureRoom', { turnTimerSeconds: 30 })).toMatchObject({ ok: false, error: { code: 'notHost' } });
    expect(await call(a, 'configureRoom', { turnTimerSeconds: 45 })).toMatchObject({ ok: false, error: { code: 'badRequest' } });
    const lobbyB = once(b, 'lobby');
    expectOk(await call(a, 'configureRoom', { turnTimerSeconds: 30 }));
    expect((await lobbyB).config.turnTimerSeconds).toBe(30);

    const states = Promise.all([once(a, 'state'), once(b, 'state'), once(c, 'state')]);
    const lobbies: LobbyView[] = [];
    c.on('lobby', (l) => lobbies.push(l));
    expectOk(await call(a, 'startGame', {}));
    const start = clock.t;
    const first = await states;
    for (const s of first) {
      expect(s.deadlineAt).toBe(start + 30_000);
      expect(s.serverNow).toBe(start);
    }
    await until(() => lobbies.some((l) => l.started), 'the started lobby');
    expect(lobbies.find((l) => l.started)!.deadlineAt).toBe(start + 30_000);
    const room = store.getRoom(code)!;
    expect(attached.timers.armedAt(code)).toBe(start + 30_000);

    // Nobody acts: the deadline passes and the server plays the turn out.
    const received: StatePayload[] = [];
    const chats: ChatMessage[] = [];
    b.on('state', (p) => received.push(p));
    b.on('chat', (m) => chats.push(m));
    const active = room.game!.activePlayer;
    scheduler.advance(30_000);
    await until(() => chats.length > 0, 'the timer chat line');
    await until(() => received.length === room.actions.length, 'every automatic state');
    expect(room.game!.activePlayer).not.toBe(active);
    expect(received.map((p) => p.action?.type)).toEqual(room.actions.map((x) => x.type));
    expect(received[0]!.action).toEqual({ type: 'rollDice', playerId: active });
    expect(received.at(-1)!.action?.type).toBe('endTurn');
    expect(received.at(-1)!.deadlineAt).toBe(clock.t + 30_000);
    expect(chats[0]!.text).toMatch(/^timer: \w+ ran out of time; rolled/);
    expect(attached.timers.armedAt(code)).toBe(clock.t + 30_000);

    // A timely action by the next player keeps that deadline (same turn) and is broadcast with it.
    const next = room.game!.activePlayer;
    const sender = [a, b, c][room.players.findIndex((p) => p.id === next)]!;
    const deadline = room.deadlineAt;
    clock.t += 5_000;
    const roll = once(sender, 'state');
    expectOk(await call(sender, 'action', { action: { type: 'rollDice', playerId: next } }));
    expect((await roll).deadlineAt).toBe(deadline);
  });
});
