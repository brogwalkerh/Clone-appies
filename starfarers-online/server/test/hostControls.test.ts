/**
 * Host controls in the room store (HANDOFF §8.3, §5.25): kick (lobby only),
 * transfer (any time), the automatic hand-over to the longest-connected
 * player after `handoverMs` offline, the lobby's expiry, and how all of it
 * persists. No sockets; the clock is injected.
 */

import { HOST_HANDOVER_MS, ROOM_CHAT_ID } from '@starfarers/shared';
import { describe, expect, it } from 'vitest';
import { MemoryRoomPersistence } from '../src/persist.js';
import { RoomStore, type Room } from '../src/rooms.js';
import { Clock } from './fakeClock.js';

const HANDOVER = 60_000;

function setup(n = 3, options: { persistence?: MemoryRoomPersistence; idleMs?: number } = {}) {
  const clock = new Clock();
  const store = new RoomStore({ now: clock.now, seedFactory: () => 'host-seed', handoverMs: HANDOVER, ...options });
  const created = store.createRoom('Host', 'Ann');
  if (!created.ok) throw new Error(created.error.message);
  const room = created.value.room;
  for (const name of ['Bob', 'Cid', 'Dee'].slice(0, n - 1)) {
    const j = store.joinRoom(room.code, name);
    if (!j.ok) throw new Error(j.error.message);
  }
  return { clock, store, room };
}

/** Bind every player in seat order, one ms apart (so connectedAt is the seat order). */
function bindAll(store: RoomStore, room: Room, clock: Clock) {
  for (const p of room.players) {
    store.bindSocket(room, p, `s-${p.id}`);
    clock.t += 1;
  }
}

describe('kickPlayer', () => {
  it('host removes a seat in the lobby; the token stops resuming; the room is written', async () => {
    const persistence = new MemoryRoomPersistence();
    const { store, room } = setup(3, { persistence });
    const bob = room.players[1]!;
    const result = store.kickPlayer(room, 'p1', 'p2');
    expect(result).toMatchObject({ ok: true, value: { player: { id: 'p2' } } });
    expect(room.players.map((p) => p.id)).toEqual(['p1', 'p3']);
    expect(store.resume(room.code, bob.token)).toMatchObject({ ok: false, error: { code: 'badToken' } });
    expect(room.messages.at(-1)).toMatchObject({ from: ROOM_CHAT_ID, text: 'room: Ann removed Bob from the room' });
    await store.flush();
    expect(persistence.get(room.code)!.players.map((p) => p.id)).toEqual(['p1', 'p3']);
    // A kick is not a ban: joining again by name gives a fresh seat and token.
    const again = store.joinRoom(room.code, 'Bob');
    expect(again.ok && again.value.player.token !== bob.token).toBe(true);
  });

  it('refuses non-hosts, the host themself, unknown players and a started game', () => {
    const { store, room } = setup(3);
    expect(store.kickPlayer(room, 'p2', 'p3')).toMatchObject({ ok: false, error: { code: 'notHost' } });
    expect(store.kickPlayer(room, 'p1', 'p1')).toMatchObject({ ok: false, error: { code: 'badRequest' } });
    expect(store.kickPlayer(room, 'p1', 'p9')).toMatchObject({ ok: false, error: { code: 'badRequest' } });
    expect(store.startGame(room, 'p1').ok).toBe(true);
    expect(store.kickPlayer(room, 'p1', 'p2')).toMatchObject({ ok: false, error: { code: 'alreadyStarted' } });
    expect(room.players).toHaveLength(3);
  });
});

describe('transferHost', () => {
  it('host only, to another seated player, in the lobby and in the game', () => {
    const { store, room } = setup(3);
    expect(store.transferHost(room, 'p2', 'p3')).toMatchObject({ ok: false, error: { code: 'notHost' } });
    expect(store.transferHost(room, 'p1', 'p1')).toMatchObject({ ok: false, error: { code: 'badRequest' } });
    expect(store.transferHost(room, 'p1', 'nobody')).toMatchObject({ ok: false, error: { code: 'badRequest' } });
    expect(store.transferHost(room, 'p1', 'p2')).toMatchObject({ ok: true, value: { from: 'p1', to: 'p2' } });
    expect(store.lobbyView(room).hostId).toBe('p2');
    expect(store.lobbyView(room).players.find((p) => p.isHost)?.id).toBe('p2');
    // The new host starts and keeps the controls in game.
    expect(store.startGame(room, 'p1')).toMatchObject({ ok: false, error: { code: 'notHost' } });
    expect(store.startGame(room, 'p2').ok).toBe(true);
    expect(store.transferHost(room, 'p2', 'p3').ok).toBe(true);
    expect(room.hostId).toBe('p3');
    expect(room.messages.at(-1)?.text).toBe('room: Bob made Cid the host');
  });

  it('is written and survives a restart', async () => {
    const persistence = new MemoryRoomPersistence();
    const { store, room } = setup(3, { persistence });
    store.transferHost(room, 'p1', 'p3');
    await store.flush();
    const store2 = new RoomStore({ persistence });
    await store2.restoreAll();
    expect(store2.getRoom(room.code)!.hostId).toBe('p3');
  });
});

describe('automatic host hand-over', () => {
  it('passes to the longest-connected player after handoverMs offline', () => {
    const { clock, store, room } = setup(4);
    bindAll(store, room, clock);
    // Bob drops and comes back: his connection is now the newest, so Cid has been connected longest.
    store.unbindSocket('s-p2');
    store.bindSocket(room, room.players[1]!, 's-p2b');
    expect(store.handoverDueAt(room)).toBeNull(); // host online
    store.unbindSocket('s-p1');
    const awayAt = clock.t;
    expect(store.handoverDueAt(room)).toBe(awayAt + HANDOVER);
    expect(store.lobbyView(room).hostHandoverAt).toBe(awayAt + HANDOVER);
    clock.t += HANDOVER - 1;
    expect(store.handOverHostIfDue(room)).toBeNull();
    clock.t += 1;
    expect(store.handOverHostIfDue(room)).toMatchObject({ from: 'p1', to: 'p3' });
    expect(room.hostId).toBe('p3');
    expect(room.messages.at(-1)).toMatchObject({ from: ROOM_CHAT_ID, text: 'room: Ann has been offline for 1 min; Cid is now the host' });
    expect(store.handoverDueAt(room)).toBeNull();
    // The old host comes back as an ordinary player.
    store.bindSocket(room, room.players[0]!, 's-p1b');
    expect(room.hostId).toBe('p3');
  });

  it('ties go by seat order; a second tab keeps the connection age', () => {
    const { clock, store, room } = setup(3);
    for (const p of room.players) store.bindSocket(room, p, `s-${p.id}`); // same instant
    store.bindSocket(room, room.players[1]!, 's-p2-tab2'); // Bob's second tab replaces the first
    store.unbindSocket('s-p1');
    clock.t += HANDOVER;
    expect(store.handOverHostIfDue(room)?.to).toBe('p2');
  });

  it('the host returning in time cancels it; nobody connected means no hand-over until someone binds', () => {
    const { clock, store, room } = setup(3);
    bindAll(store, room, clock);
    store.unbindSocket('s-p1');
    clock.t += HANDOVER / 2;
    store.bindSocket(room, room.players[0]!, 's-p1b');
    clock.t += HANDOVER;
    expect(store.handOverHostIfDue(room)).toBeNull();
    expect(room.hostId).toBe('p1');

    // Everyone leaves; the window passes with nobody to take over; the first one back becomes host on bind.
    for (const id of ['s-p1b', 's-p2', 's-p3']) store.unbindSocket(id);
    expect(store.handoverDueAt(room)).toBeNull();
    clock.t += HANDOVER * 3;
    store.bindSocket(room, room.players[2]!, 's-p3b');
    expect(room.hostId).toBe('p3');
  });

  it('works in a started game too', () => {
    const { clock, store, room } = setup(3);
    bindAll(store, room, clock);
    expect(store.startGame(room, 'p1').ok).toBe(true);
    store.unbindSocket('s-p1');
    clock.t += HANDOVER;
    expect(store.handOverHostIfDue(room)?.to).toBe('p2');
  });

  it('after a restart the host absence counts from boot; the hand-over is written', async () => {
    const persistence = new MemoryRoomPersistence();
    const { clock, store, room } = setup(3, { persistence });
    bindAll(store, room, clock);
    store.unbindSocket('s-p1');
    clock.t += HANDOVER - 10; // almost due when the server goes down
    await store.flush();
    const store2 = new RoomStore({ persistence, now: clock.now, handoverMs: HANDOVER });
    await store2.restoreAll();
    const r2 = store2.getRoom(room.code)!;
    expect(r2.hostAwaySince).toBe(clock.t);
    expect(r2.players.every((p) => p.connectedAt === null)).toBe(true);
    store2.bindSocket(r2, r2.players[1]!, 'x-p2');
    expect(store2.handoverDueAt(r2)).toBe(clock.t + HANDOVER);
    clock.t += HANDOVER;
    expect(store2.handOverHostIfDue(r2)?.to).toBe('p2');
    await store2.flush();
    expect(persistence.get(room.code)!.hostId).toBe('p2');
  });

  it('defaults to HOST_HANDOVER_MS', () => {
    const clock = new Clock();
    const store = new RoomStore({ now: clock.now });
    const created = store.createRoom('x', 'Ann');
    if (!created.ok) throw new Error('create');
    const room = created.value.room;
    store.joinRoom(room.code, 'Bob');
    bindAll(store, room, clock);
    store.unbindSocket('s-p1');
    expect(store.handoverDueAt(room)).toBe(clock.t + HOST_HANDOVER_MS);
    expect(HOST_HANDOVER_MS).toBe(5 * 60 * 1000);
  });
});

describe('lobby expiry', () => {
  it('expiresAt = updatedAt + idleMs and moves with activity', () => {
    const { clock, store, room } = setup(3, { idleMs: 3_600_000 });
    const v1 = store.lobbyView(room);
    expect(v1.idleMs).toBe(3_600_000);
    expect(v1.expiresAt).toBe(room.updatedAt + 3_600_000);
    clock.t += 5_000;
    store.addChat(room, room.players[0]!, 'hi');
    expect(store.lobbyView(room).expiresAt).toBe(clock.t + 3_600_000);
  });
});
