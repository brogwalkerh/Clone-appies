import { mkdtemp, readdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import { FileRoomPersistence, MemoryRoomPersistence, type RoomPersistence } from '../src/persist.js';
import { RoomStore, type Room, type RoomSnapshot } from '../src/rooms.js';
import { BOT_GAME_TIMEOUT_MS, botRandom, nextAction } from './bot.js';

const dirs: string[] = [];
async function tempDir(): Promise<string> {
  const dir = await mkdtemp(join(tmpdir(), 'starfarers-persist-'));
  dirs.push(dir);
  return dir;
}
afterEach(async () => {
  for (const d of dirs.splice(0)) await rm(d, { recursive: true, force: true });
});

function filled(store: RoomStore, n = 3): Room {
  const created = store.createRoom('Persist', 'Ann');
  if (!created.ok) throw new Error(created.error.message);
  const room = created.value.room;
  for (const name of ['Bob', 'Cid', 'Dee'].slice(0, n - 1)) {
    const j = store.joinRoom(room.code, name);
    if (!j.ok) throw new Error(j.error.message);
  }
  return room;
}

/** Plays `count` bot actions; returns how many were accepted. */
function play(store: RoomStore, room: Room, rnd: () => number, count: number): number {
  let accepted = 0;
  for (let i = 0; i < count; i++) {
    const a = nextAction(room.game!, rnd);
    if (!a) break;
    if (!store.applyAction(room, a.playerId, a).ok) break;
    accepted++;
  }
  return accepted;
}

describe('FileRoomPersistence', () => {
  it('round-trips snapshots, removes them, and creates the directory on demand', async () => {
    const dir = join(await tempDir(), 'nested', 'rooms');
    const files = new FileRoomPersistence(dir);
    expect(await files.loadAll()).toEqual([]); // missing directory is an empty store
    const store = new RoomStore({ seedFactory: () => 'file-seed' });
    const room = filled(store);
    store.startGame(room, 'p1');
    const snap = store.snapshot(room);
    await files.save(snap);
    await files.save(snap); // overwrite in place
    expect(await readdir(dir)).toEqual([`${room.code}.json`]);
    expect(await files.loadAll()).toEqual([JSON.parse(JSON.stringify(snap))]);
    await files.remove(room.code);
    await files.remove(room.code); // unknown code is not an error
    expect(await files.loadAll()).toEqual([]);
  });

  it('skips corrupt, foreign and misnamed files with a warning, and clears stale temp files', async () => {
    const dir = await tempDir();
    const warnings: string[] = [];
    const files = new FileRoomPersistence(dir, (m) => warnings.push(m));
    const store = new RoomStore();
    const good = filled(store);
    await files.save(store.snapshot(good));
    await writeFile(join(dir, 'BROKEN.json'), '{"code":"BROK', 'utf8');
    await writeFile(join(dir, 'OTHER.json'), '{"hello":1}', 'utf8');
    await writeFile(join(dir, 'WRONG1.json'), JSON.stringify(store.snapshot(good)), 'utf8');
    await writeFile(join(dir, `${good.code}.json.1.abcd.tmp`), 'partial', 'utf8');
    await writeFile(join(dir, 'README.txt'), 'not a room', 'utf8');
    const loaded = await files.loadAll();
    expect(loaded.map((s) => s.code)).toEqual([good.code]);
    expect(warnings).toHaveLength(3);
    expect(warnings.join('\n')).toMatch(/BROKEN\.json/);
    expect((await readdir(dir)).some((n) => n.endsWith('.tmp'))).toBe(false);
  });

  it('refuses codes that are not safe file names', async () => {
    const files = new FileRoomPersistence(await tempDir());
    await expect(files.remove('../etc')).rejects.toThrow(/unsafe/);
    const snap = { code: 'a/b' } as RoomSnapshot;
    await expect(files.save(snap)).rejects.toThrow(/unsafe/);
  });
});

describe('RoomStore with persistence', { timeout: BOT_GAME_TIMEOUT_MS }, () => {
  it('saves after create, join, start, each accepted action and chat — not after a rejected action', async () => {
    const mem = new MemoryRoomPersistence();
    let t = 1000;
    const store = new RoomStore({ persistence: mem, seedFactory: () => 'spy-seed', now: () => t });
    // Writes are fire-and-forget; flush() lets the spy see them.
    const saves = async () => {
      await store.flush();
      return mem.saves.length;
    };
    const room = filled(store); // create + 2 joins
    expect(await saves()).toBe(3);
    t = 2000;
    expect(store.startGame(room, 'p1').ok).toBe(true);
    expect(await saves()).toBe(4);
    const active = room.game!.activePlayer;
    const other = room.players.find((p) => p.id !== active)!.id;
    expect(store.applyAction(room, other, { type: 'rollDice', playerId: other }).ok).toBe(false);
    expect(store.applyAction(room, active, { type: 'nonsense', playerId: active }).ok).toBe(false);
    expect(await saves()).toBe(4);
    t = 3000;
    expect(store.applyAction(room, active, { type: 'rollDice', playerId: active }).ok).toBe(true);
    expect(await saves()).toBe(5);
    const accepted = play(store, room, botRandom(3), 20);
    expect(await saves()).toBe(5 + accepted);
    expect(store.addChat(room, room.players[0]!, '  ').ok).toBe(false);
    t = 4000;
    expect(store.addChat(room, room.players[0]!, 'gg').ok).toBe(true);
    expect(await saves()).toBe(6 + accepted);
    // Socket binds only bump updatedAt.
    t = 5000;
    store.bindSocket(room, room.players[0]!, 'sock');
    store.unbindSocket('sock');
    expect(await saves()).toBe(6 + accepted);
    expect(room.updatedAt).toBe(5000);
    const saved = mem.get(room.code)!;
    expect(saved.updatedAt).toBe(4000);
    expect(saved.actions).toEqual(room.actions);
    expect(saved.messages.map((m) => m.text)).toEqual(['gg']);
    expect(saved.rngState).toEqual(room.rng!.getState());
  });

  it('serialises writes per room and logs failures instead of throwing', async () => {
    const order: string[] = [];
    let inFlight = 0;
    let maxInFlight = 0;
    let fail = false;
    const slow: RoomPersistence = {
      async save(s) {
        inFlight++;
        maxInFlight = Math.max(maxInFlight, inFlight);
        await new Promise((r) => setTimeout(r, 5));
        inFlight--;
        if (fail) throw new Error('disk full');
        order.push(`${s.players.length}`);
      },
      async remove() {},
      async loadAll() {
        return [];
      },
    };
    const warnings: string[] = [];
    const store = new RoomStore({ persistence: slow, warn: (m) => warnings.push(m) });
    filled(store, 4);
    await store.flush();
    expect(maxInFlight).toBe(1);
    expect(order).toEqual(['1', '2', '3', '4']);
    fail = true;
    const r = store.createRoom('x', 'Zed');
    expect(r.ok).toBe(true);
    await expect(store.flush()).resolves.toBeUndefined();
    expect(warnings).toEqual([expect.stringMatching(/save .* failed: disk full/)]);
  });

  it('configureRoom is persisted: a restored un-started room keeps its variant and start mode', async () => {
    const persistence = new MemoryRoomPersistence();
    const store = new RoomStore({ persistence });
    const room = filled(store);
    await store.flush();
    const saves = persistence.saves.length;
    expect(store.configureRoom(room, 'p1', { variant: 'explorer', setup: 'draft' }).ok).toBe(true);
    await store.flush();
    expect(persistence.saves.length).toBe(saves + 1);
    const restored = new RoomStore({ persistence });
    expect(await restored.restoreAll()).toBe(1);
    const room2 = restored.getRoom(room.code)!;
    expect(room2.config).toEqual({ turnTimerSeconds: null, variant: 'explorer', setup: 'draft' });
    expect(restored.configureRoom(room2, 'p1', { variant: 'wild' }).ok).toBe(true);
    expect(restored.startGame(room2, 'p1').ok).toBe(true);
    expect(room2.game!.variant).toBe('wild');
    expect(room2.game!.setup).toBe('draft');
  });

  it('deleteRoom removes the stored snapshot and a stale room reference cannot resurrect it', async () => {
    const mem = new MemoryRoomPersistence();
    const store = new RoomStore({ persistence: mem });
    const room = filled(store);
    expect(store.deleteRoom(room.code.toLowerCase())).toBe(true);
    expect(store.deleteRoom(room.code)).toBe(false);
    store.addChat(room, room.players[0]!, 'still here?');
    await store.flush();
    expect(mem.rooms.size).toBe(0);
    expect(mem.removes).toEqual([room.code]);
  });

  it('a restart restores every room and the games continue identically (rng state round-trips)', async () => {
    const dir = await tempDir();
    const before = new RoomStore({ persistence: new FileRoomPersistence(dir), seedFactory: () => 'restart-seed' });
    const room = filled(before, 4);
    const lobbyOnly = filled(before, 2);
    before.addChat(lobbyOnly, lobbyOnly.players[0]!, 'waiting');
    expect(before.startGame(room, 'p1').ok).toBe(true);
    const rnd = botRandom(11);
    expect(play(before, room, rnd, 120)).toBe(120);
    await before.flush();

    const after = new RoomStore({ persistence: new FileRoomPersistence(dir) });
    expect(await after.restoreAll()).toBe(2);
    const twin = after.getRoom(room.code)!;
    expect(twin.game).toEqual(room.game);
    expect(twin.actions).toEqual(room.actions);
    expect(twin.rng!.getState()).toEqual(room.rng!.getState());
    expect(twin.updatedAt).toBe(room.updatedAt);
    expect(after.getRoom(lobbyOnly.code)?.messages.map((m) => m.text)).toEqual(['waiting']);
    expect(after.resume(room.code, room.players[2]!.token)).toMatchObject({ ok: true });

    // Continue the same bot script in both stores.
    let steps = 0;
    for (; steps < 250; steps++) {
      const a = nextAction(room.game!, rnd);
      if (!a) break;
      const r1 = before.applyAction(room, a.playerId, a);
      const r2 = after.applyAction(twin, a.playerId, a);
      expect(r2.ok).toBe(r1.ok);
      if (!r1.ok) break;
      if (steps % 50 === 0) expect(twin.game).toEqual(room.game);
    }
    expect(steps).toBeGreaterThan(100);
    expect(twin.game).toEqual(room.game);
    expect(twin.actions).toEqual(room.actions);
    await Promise.all([before.flush(), after.flush()]);
  });

  it('restore() accepts a snapshot written before updatedAt existed and marks everyone disconnected', () => {
    const store = new RoomStore({ now: () => 777 });
    const room = filled(store);
    store.startGame(room, 'p1');
    store.bindSocket(room, room.players[0]!, 'sock');
    const { updatedAt: _dropped, ...legacy } = store.snapshot(room);
    legacy.createdAt = 123;
    // A connected flag frozen into the stored game state is cleared on restore.
    legacy.game = { ...legacy.game!, players: legacy.game!.players.map((p) => ({ ...p, connected: true })) };
    const restored = new RoomStore().restore(JSON.parse(JSON.stringify(legacy)));
    expect(restored.updatedAt).toBe(123);
    expect(restored.players.every((p) => !p.connected && p.socketId === null)).toBe(true);
    expect(restored.game!.players.every((p) => !p.connected)).toBe(true);
  });

  it('restoreAll() without persistence restores nothing', async () => {
    expect(await new RoomStore().restoreAll()).toBe(0);
  });
});

describe('RoomStore.sweep', () => {
  const HOUR = 60 * 60 * 1000;

  it('expires idle and old finished rooms, keeps active, recent-finished and connected rooms', async () => {
    const mem = new MemoryRoomPersistence();
    let t = 0;
    const store = new RoomStore({ persistence: mem, now: () => t, idleMs: 24 * HOUR, finishedMs: 2 * HOUR });
    const idle = filled(store);
    const connected = filled(store);
    store.bindSocket(connected, connected.players[1]!, 'sock-c');
    const finishedOld = filled(store);
    store.startGame(finishedOld, 'p1');
    store.startWithState(finishedOld, { ...finishedOld.game!, phase: 'gameOver', winner: 'p1' });

    t = 20 * HOUR;
    const active = filled(store);
    const finishedRecent = filled(store);
    store.startGame(finishedRecent, 'p1');
    store.startWithState(finishedRecent, { ...finishedRecent.game!, phase: 'gameOver', winner: 'p2' });
    expect(store.sweep()).toEqual([finishedOld.code]); // finished 20 h ago > 2 h; idle room only 20 h

    t = 21 * HOUR;
    expect(store.sweep()).toEqual([]);
    t = 24 * HOUR + 1;
    store.addChat(active, active.players[0]!, 'still playing');
    expect(store.sweep().sort()).toEqual([idle.code, finishedRecent.code].sort());

    expect(store.getRoom(idle.code)).toBeUndefined();
    expect(store.getRoom(connected.code)).toBe(connected); // idle 24 h but a player is connected
    expect(store.getRoom(active.code)).toBe(active);
    await store.flush();
    expect([...mem.rooms.keys()].sort()).toEqual([connected.code, active.code].sort());
    expect(mem.removes.sort()).toEqual([idle.code, finishedOld.code, finishedRecent.code].sort());

    // Once the last player leaves, the idle clock starts from the disconnect.
    t = 30 * HOUR;
    store.unbindSocket('sock-c');
    t = 30 * HOUR + 23 * HOUR;
    expect(store.sweep()).toEqual([active.code]); // its last chat was 29 h ago
    t = 30 * HOUR + 24 * HOUR + 1;
    expect(store.sweep()).toEqual([connected.code]);
  });

  it('defaults to 24 h for both limits', () => {
    let t = 0;
    const store = new RoomStore({ now: () => t });
    const room = filled(store);
    t = 24 * HOUR;
    expect(store.sweep()).toEqual([]);
    t = 24 * HOUR + 1;
    expect(store.sweep()).toEqual([room.code]);
  });
});
