import type { GameState } from '@starfarers/shared';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import { FileRoomPersistence } from '../src/persist.js';
import { RoomStore, type Room } from '../src/rooms.js';
import { BOT_GAME_TIMEOUT_MS, botRandom, nextAction } from './bot.js';

const dirs: string[] = [];
afterEach(async () => {
  for (const d of dirs.splice(0)) await rm(d, { recursive: true, force: true });
});

function startedRoom(store: RoomStore, players = 3): Room {
  const created = store.createRoom('Replay', 'Ann');
  if (!created.ok) throw new Error(created.error.message);
  const room = created.value.room;
  for (const name of ['Bob', 'Cid', 'Dee'].slice(0, players - 1)) store.joinRoom(room.code, name);
  const started = store.startGame(room, 'p1');
  if (!started.ok) throw new Error(started.error.message);
  return room;
}

/** Plays bot actions until the game ends, a rejection, or `max`; returns `room.game` after each accepted action (index 0 = start). */
function playCapturing(store: RoomStore, room: Room, rnd: () => number, max: number): GameState[] {
  const states: GameState[] = [room.game!];
  for (let i = 0; i < max; i++) {
    const a = nextAction(room.game!, rnd);
    if (!a) break;
    if (!store.applyAction(room, a.playerId, a).ok) break;
    states.push(room.game!);
  }
  return states;
}

/** `connected` is presentation state mirrored from the sockets, outside the engine. */
function withoutConnected(state: GameState): GameState {
  return { ...state, players: state.players.map((p) => ({ ...p, connected: false })) };
}

describe('RoomStore.replayState', { timeout: BOT_GAME_TIMEOUT_MS }, () => {
  it('reproduces the state after every k-th action of a bot game, in any query order', () => {
    const store = new RoomStore({ seedFactory: () => 'replay-seed' });
    const room = startedRoom(store, 4);
    store.bindSocket(room, room.players[1]!, 'sock-b');
    // ~3 ms per engine step, so the game is capped; 350 actions span dozens of turns, 7s, encounters and trades.
    const captured = playCapturing(store, room, botRandom(2), 350);
    const n = room.actions.length;
    expect(n).toBe(captured.length - 1);
    expect(n).toBe(350);
    expect(withoutConnected(room.initial!)).toEqual(withoutConnected(captured[0]!));

    // Forward (incremental cache), backward (restart from initial), and the ends.
    for (const k of [0, 1, 7, 120, Math.floor(n / 2), n - 1, n, 3, 250, 249, n, 0]) {
      expect(withoutConnected(store.replayState(room, k)), `k=${k}`).toEqual(withoutConnected(captured[k]!));
    }
    expect(withoutConnected(store.replayState(room, n))).toEqual(withoutConnected(room.game!));
    expect(() => store.replayState(room, n + 1)).toThrow(/outside/);
    expect(() => store.replayState(room, -1)).toThrow(/outside/);
  });

  it('does not disturb the live rng: a store that replayed plays on exactly like an untouched twin', () => {
    const replayed = new RoomStore({ seedFactory: () => 'twin-seed', codeFactory: () => 'TWIN22' });
    const twin = new RoomStore({ seedFactory: () => 'twin-seed', codeFactory: () => 'TWIN22' });
    const a = startedRoom(replayed);
    const b = startedRoom(twin);
    const rnd = botRandom(5);
    let steps = 0;
    for (; steps < 260; steps++) {
      const action = nextAction(a.game!, rnd);
      if (!action) break;
      const ra = replayed.applyAction(a, action.playerId, action);
      const rb = twin.applyAction(b, action.playerId, action);
      expect(ra.ok).toBe(rb.ok);
      if (!ra.ok) break;
      // Replay at a moving point (forward, back to the start, the live end) while the game goes on.
      if (steps % 50 === 0) {
        replayed.replayState(a, Math.floor(steps / 2));
        replayed.replayState(a, a.actions.length);
        replayed.replayState(a, 0);
      }
    }
    expect(steps).toBe(260);
    expect(a.game).toEqual(b.game);
    expect(a.rng!.getState()).toEqual(b.rng!.getState());
  });
});

describe('RoomStore.replayFor', () => {
  it('validates the request and redacts for the asking player', () => {
    const store = new RoomStore({ seedFactory: () => 'replay-for' });
    const lobby = store.createRoom('Lobby', 'Ann');
    if (!lobby.ok) throw new Error('create');
    expect(store.replayFor(lobby.value.room, 'p1', 0)).toMatchObject({ ok: false, error: { code: 'notStarted' } });

    const room = startedRoom(store);
    playCapturing(store, room, botRandom(9), 40);
    const n = room.actions.length;
    for (const bad of [-1, n + 1, 1.5, '2', null, undefined]) {
      expect(store.replayFor(room, 'p2', bad), String(bad)).toMatchObject({ ok: false, error: { code: 'badRequest' } });
    }
    const r = store.replayFor(room, 'p2', 0);
    if (!r.ok) throw new Error(r.error.message);
    expect(r.value.seed).toBe('');
    expect(r.value.reservePile).toEqual([]);
    expect(r.value.encounterDeck).toEqual([]);
    for (const p of r.value.players) {
      const real = room.initial!.players.find((q) => q.id === p.id)!;
      expect(p.handCount).toBe(real.hand.length);
      expect(p.hand).toEqual(p.id === 'p2' ? real.hand : []);
    }
    // The live end matches the state the player is sent anyway.
    store.bindSocket(room, room.players[1]!, 'sock');
    const last = store.replayFor(room, 'p2', n);
    expect(last).toEqual({ ok: true, value: store.joinReply(room, room.players[1]!).state });
    expect(last.ok && last.value.players.find((p) => p.id === 'p2')?.connected).toBe(true);
  });

  it('join replies carry the redacted initial state once the game has started', () => {
    const store = new RoomStore({ seedFactory: () => 'join-initial' });
    const created = store.createRoom('R', 'Ann');
    if (!created.ok) throw new Error('create');
    expect(store.joinReply(created.value.room, created.value.player).initial).toBeNull();
    const room = startedRoom(store);
    playCapturing(store, room, botRandom(4), 15);
    const reply = store.joinReply(room, room.players[2]!);
    expect(reply.initial?.seed).toBe('');
    expect(reply.initial?.turnNumber).toBe(room.initial!.turnNumber);
    expect(reply.initial?.players.find((p) => p.id === 'p1')?.hand).toEqual([]);
    expect(reply.actions).toHaveLength(room.actions.length);
  });
});

describe('initial state and persistence', { timeout: BOT_GAME_TIMEOUT_MS }, () => {
  it('a snapshot keeps the initial state, so replay works after a restart', async () => {
    const dir = await mkdtemp(join(tmpdir(), 'starfarers-replay-'));
    dirs.push(dir);
    const before = new RoomStore({ persistence: new FileRoomPersistence(dir), seedFactory: () => 'persist-replay' });
    const room = startedRoom(before);
    const captured = playCapturing(before, room, botRandom(3), 80);
    await before.flush();
    const after = new RoomStore({ persistence: new FileRoomPersistence(dir) });
    expect(await after.restoreAll()).toBe(1);
    const restored = after.getRoom(room.code)!;
    expect(restored.initial).toEqual(room.initial);
    for (const k of [0, 10, restored.actions.length]) {
      expect(withoutConnected(after.replayState(restored, k))).toEqual(withoutConnected(captured[k]!));
    }
  });

  it('an old snapshot without `initial` still loads; replay is then refused with a clear error', async () => {
    const dir = await mkdtemp(join(tmpdir(), 'starfarers-replay-old-'));
    dirs.push(dir);
    const store = new RoomStore({ seedFactory: () => 'old-shape' });
    const room = startedRoom(store);
    playCapturing(store, room, botRandom(6), 12);
    const { initial: _initial, updatedAt: _updatedAt, ...legacy } = store.snapshot(room);
    await writeFile(join(dir, `${room.code}.json`), JSON.stringify(legacy), 'utf8');

    const warnings: string[] = [];
    const persistence = new FileRoomPersistence(dir, (m) => warnings.push(m));
    expect(await persistence.loadAll()).toHaveLength(1);
    const after = new RoomStore({ persistence });
    expect(await after.restoreAll()).toBe(1);
    expect(warnings).toEqual([]);
    const restored = after.getRoom(room.code)!;
    expect(restored.initial).toBeNull();
    expect(restored.game).toEqual(withoutConnected(room.game!));
    expect(after.joinReply(restored, restored.players[0]!).initial).toBeNull();
    const r = after.replayFor(restored, 'p1', 0);
    expect(r).toMatchObject({ ok: false, error: { code: 'badRequest' } });
    expect(!r.ok && r.error.message).toMatch(/initial state/);
    expect(() => after.replayState(restored, 0)).toThrow(/no initial state/);
    // The game itself carries on.
    const a = nextAction(restored.game!, botRandom(1));
    expect(after.applyAction(restored, a!.playerId, a!).ok).toBe(true);
  });
});
