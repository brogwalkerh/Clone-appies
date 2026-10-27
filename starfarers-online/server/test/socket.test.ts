import { createBeginnerGame, type Action, type ClientToServerEvents, type GameState, type JoinReply, type LobbyView, type ServerToClientEvents } from '@starfarers/shared';
import { createServer, type Server as HttpServer } from 'node:http';
import type { AddressInfo } from 'node:net';
import { Server } from 'socket.io';
import { io as connect, type Socket } from 'socket.io-client';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { RoomStore } from '../src/rooms.js';
import { attachSockets, type GameServer } from '../src/socket.js';
import { botRandom, nextAction } from './bot.js';

type Client = Socket<ServerToClientEvents, ClientToServerEvents>;

let http: HttpServer;
let url = '';
let store: RoomStore;
const clients: Client[] = [];

beforeAll(async () => {
  http = createServer();
  const io: GameServer = new Server(http);
  store = new RoomStore({ seedFactory: () => 'socket-seed' });
  attachSockets(io, store);
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

/** Promisified emit-with-ack. */
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

async function threePlayerRoom() {
  const a = client();
  const b = client();
  const c = client();
  const ra = expectOk(await call(a, 'createRoom', { roomName: 'Sockets', playerName: 'Ann' }));
  const code = ra.session.roomCode;
  const rb = expectOk(await call(b, 'joinRoom', { code, playerName: 'Bob' }));
  const rc = expectOk(await call(c, 'joinRoom', { code, playerName: 'Cid' }));
  return { a, b, c, code, ra, rb, rc };
}

describe('socket transport', () => {
  it('create / join / start: lobby broadcasts and per-socket redacted state', async () => {
    const { a, b, c, code, ra, rb, rc } = await threePlayerRoom();
    expect(ra.session.playerId).toBe('p1');
    expect(rb.session.playerId).toBe('p2');
    expect(rc.lobby.players.map((p) => p.name)).toEqual(['Ann', 'Bob', 'Cid']);
    expect(rc.lobby.players.every((p) => p.connected)).toBe(true);
    expect(rc.state).toBeNull();

    // Only the host may start.
    expect(await call(b, 'startGame', {})).toMatchObject({ ok: false, error: { code: 'notHost' } });

    const states = Promise.all([once(a, 'state'), once(b, 'state'), once(c, 'state')]);
    const lobbies = Promise.all([once(a, 'lobby'), once(b, 'lobby'), once(c, 'lobby')]);
    expectOk(await call(a, 'startGame', {}));
    const [sa, sb, sc] = await states;
    const lobby: LobbyView = (await lobbies)[0];
    expect(lobby.started).toBe(true);
    expect(sa.action).toBeNull();
    // Each socket sees its own hand only.
    for (const [s, me] of [
      [sa.state, 'p1'],
      [sb.state, 'p2'],
      [sc.state, 'p3'],
    ] as const) {
      for (const p of s.players) {
        if (p.id === me) expect(p.hand.length).toBe(p.handCount);
        else expect(p.hand).toEqual([]);
      }
      expect(s.seed).toBe('');
      expect(s.reservePile).toEqual([]);
      expect(s.reservePileCount).toBeGreaterThan(0);
    }
    expect(sa.state.board).toEqual(sb.state.board);
    expect(code).toBe(store.getRoom(code)?.code);
  });

  it('action round trip: accepted actions reach everyone, rejections only the sender', async () => {
    const { a, b, c, code } = await threePlayerRoom();
    await Promise.all([once(a, 'state'), once(b, 'state'), once(c, 'state'), call(a, 'startGame', {})]);
    const room = store.getRoom(code)!;
    const active = room.game!.activePlayer;
    const sockets = { p1: a, p2: b, p3: c } as Record<string, Client>;
    const other = Object.keys(sockets).find((id) => id !== active)!;

    // Wrong player: error to sender only, nobody else gets a state.
    let othersGotState = false;
    for (const s of [a, b, c]) s.once('state', () => (othersGotState = true));
    const errP = once(sockets[other]!, 'error');
    const rej = await call(sockets[other]!, 'action', { action: { type: 'rollDice', playerId: other } });
    expect(rej).toMatchObject({ ok: false, error: { code: 'notYourTurn' } });
    expect((await errP).code).toBe('notYourTurn');
    // Impersonation is refused before the engine sees it.
    expect(await call(sockets[other]!, 'action', { action: { type: 'rollDice', playerId: active } })).toMatchObject({ ok: false, error: { code: 'badRequest' } });
    await new Promise((r) => setTimeout(r, 30));
    expect(othersGotState).toBe(false);
    for (const s of [a, b, c]) s.removeAllListeners('state');

    // Right player: everyone receives the new state with the action attached.
    const states = Promise.all([once(a, 'state'), once(b, 'state'), once(c, 'state')]);
    expectOk(await call(sockets[active]!, 'action', { action: { type: 'rollDice', playerId: active } }));
    const received = await states;
    for (const r of received) {
      expect(r.action?.type).toBe('rollDice');
      expect(r.state.turn.rolled).toBeDefined();
      expect(r.state.log.at(-1)?.message).toBe(room.game!.log.at(-1)?.message);
    }
  });

  it('reconnect with the token re-binds the player and resends the current state', async () => {
    const { a, b, c, code, rb } = await threePlayerRoom();
    await Promise.all([once(a, 'state'), once(b, 'state'), once(c, 'state'), call(a, 'startGame', {})]);
    const lobbyAfterDrop = once(a, 'lobby');
    b.disconnect();
    const dropped = await lobbyAfterDrop;
    expect(dropped.players.find((p) => p.id === 'p2')?.connected).toBe(false);

    const b2 = client();
    expect(await call(b2, 'resume', { roomCode: code, playerToken: 'nonsense' })).toMatchObject({ ok: false, error: { code: 'badToken' } });
    const back = expectOk(await call(b2, 'resume', { roomCode: code, playerToken: rb.session.playerToken }));
    expect(back.session.playerId).toBe('p2');
    expect(back.lobby.players.find((p) => p.id === 'p2')?.connected).toBe(true);
    expect(back.state?.players.find((p) => p.id === 'p2')?.hand.length).toBeGreaterThan(0);
    expect(back.state?.players.find((p) => p.id === 'p1')?.hand).toEqual([]);
    expect(back.actions).toEqual([]);

    // The reconnected socket now receives broadcasts; a stale second tab is evicted.
    const b3 = client();
    const evicted = once(b2, 'error');
    expectOk(await call(b3, 'resume', { roomCode: code, playerToken: rb.session.playerToken }));
    expect((await evicted).code).toBe('badToken');
    expect(c.connected).toBe(true);
  });

  it('chat is broadcast to the room and kept in the lobby view', async () => {
    const { a, b, c, code } = await threePlayerRoom();
    const got = Promise.all([once(a, 'chat'), once(b, 'chat'), once(c, 'chat')]);
    expectOk(await call(b, 'chat', { text: 'gl hf' }));
    const msgs = await got;
    expect(msgs[0]).toMatchObject({ from: 'p2', name: 'Bob', text: 'gl hf' });
    const d = client();
    const rd = expectOk(await call(d, 'joinRoom', { code, playerName: 'Dee' }));
    expect(rd.lobby.messages).toHaveLength(1);
    expect(await call(d, 'chat', { text: '' })).toMatchObject({ ok: false });
  });

  it('plays a full scripted game over sockets with the bot driving each player from its own connection', async () => {
    const { a, b, c } = await threePlayerRoom();
    const sockets: Record<string, Client> = { p1: a, p2: b, p3: c };
    const latest: Record<string, GameState> = {};
    const log: Action[] = [];
    for (const [id, s] of Object.entries(sockets)) {
      s.on('state', ({ state, action }) => {
        latest[id] = state;
        if (id === 'p1' && action) log.push(action);
      });
    }
    await Promise.all([once(a, 'state'), once(b, 'state'), once(c, 'state'), call(a, 'startGame', {})]);
    const rnd = botRandom(11);
    let steps = 0;
    let rejected = 0;
    while (steps < 2500) {
      // Each bot decides from ITS OWN redacted view; the actor's own hand is visible there.
      const anyView = latest.p1!;
      if (anyView.phase === 'gameOver') break;
      const probe = nextAction(anyView, () => 0.5);
      if (!probe) break;
      const actorId = probe.playerId;
      const action = nextAction(latest[actorId]!, rnd);
      if (!action) break;
      const waits = Promise.all(Object.values(sockets).map((s) => once(s, 'state')));
      const reply = await call(sockets[actorId]!, 'action', { action });
      steps++;
      if (!reply.ok) {
        rejected++;
        Object.values(sockets).forEach((s) => s.removeAllListeners('state'));
        for (const [id, s] of Object.entries(sockets)) s.on('state', ({ state }) => (latest[id] = state));
        if (action.type === 'endTurn' || anyView.phase === 'flight.encounter') break;
        const endWait = Promise.all(Object.values(sockets).map((s) => once(s, 'state')));
        const r = await call(sockets[anyView.activePlayer]!, 'action', { action: { type: 'endTurn', playerId: anyView.activePlayer } });
        if (r.ok) await endWait;
        continue;
      }
      await waits;
    }
    const final = latest.p1!;
    expect(rejected).toBe(0);
    expect(steps).toBeGreaterThan(200);
    expect(final.winner).not.toBeNull();
    // Every view agrees on the public state and the redaction held throughout.
    for (const [id, view] of Object.entries(latest)) {
      expect(view.board).toEqual(final.board);
      expect(view.turnNumber).toBe(final.turnNumber);
      for (const p of view.players) expect(p.id === id ? p.hand.length : p.hand.length).toBe(p.id === id ? p.handCount : 0);
    }
    expect(final.phase).toBe('gameOver');
    expect(log.length).toBe(steps);
  }, 120_000);

  it('startWithState lets a test resume any position over sockets', async () => {
    const { a, b, c, code } = await threePlayerRoom();
    const room = store.getRoom(code)!;
    const state = createBeginnerGame({ players: room.players.map((p) => ({ id: p.id, name: p.name, color: p.color })), seed: 'resume' });
    const active = state.activePlayer;
    // VP is recomputed from the board after every action: 4 (start) + 10 (20 fame pieces) = 14.
    state.players.find((p) => p.id === active)!.famePieces = 20;
    state.phase = 'tradeBuild';
    state.turn.rolled = 6;
    state.players.find((p) => p.id === active)!.hand = ['carbon', 'carbon', 'carbon', 'food', 'food'];
    store.startWithState(room, state);
    const sockets: Record<string, Client> = { p1: a, p2: b, p3: c };
    const colony = Object.values(state.board.settlements).find((s) => s.owner === active && s.kind === 'colony')!;
    const states = Promise.all([once(a, 'state'), once(b, 'state'), once(c, 'state')]);
    expectOk(await call(sockets[active]!, 'action', { action: { type: 'build', playerId: active, item: 'spaceport', siteId: colony.nodeId } }));
    const [sa] = await states;
    expect(sa.state.winner).toBe(active);
    expect(sa.state.phase).toBe('gameOver');
    const reply: JoinReply = expectOk(await call(client(), 'resume', { roomCode: code, playerToken: room.players[0]!.token }));
    expect(reply.state?.winner).toBe(active);
    expect(reply.actions.map((x) => x.type)).toEqual(['build']);
  });
});
