/**
 * Turn timer (spec §13 "optional, off by default", HANDOFF §8.2): the
 * deadline policy in RoomStore, the minimal turn-ending sequence
 * (src/autoplay.ts) and the per-room timeouts (src/timer.ts), all on an
 * injected clock: no real waiting.
 */

import { TURN_TIMER_CHOICES, isTurnTimerChoice, shipsOf, type Action, type ActionType, type GameState } from '@starfarers/shared';
import { describe, expect, it } from 'vitest';
import { timeoutAction } from '../src/autoplay.js';
import { MemoryRoomPersistence } from '../src/persist.js';
import { RoomStore, TIMER_CHAT_ID, turnKey, type Room, type StoredRoomSnapshot } from '../src/rooms.js';
import { TurnTimers } from '../src/timer.js';
import { Clock, FakeScheduler } from './fakeClock.js';

function filled(store: RoomStore, n = 3): Room {
  const created = store.createRoom('Timer', 'Ann');
  if (!created.ok) throw new Error(created.error.message);
  const room = created.value.room;
  for (const name of ['Bob', 'Cid', 'Dee'].slice(0, n - 1)) {
    const j = store.joinRoom(room.code, name);
    if (!j.ok) throw new Error(j.error.message);
  }
  return room;
}

/** Everyone "online" (the timer waits in a room nobody is connected to). */
function connectAll(store: RoomStore, room: Room): void {
  for (const p of room.players) store.bindSocket(room, p, `sock-${p.id}`);
}

function timedRoom(seconds: number | null = 60, options: { setup?: 'draft'; persistence?: MemoryRoomPersistence; warn?: (m: string) => void } = {}) {
  const clock = new Clock();
  const store = new RoomStore({
    seedFactory: () => 'timer-seed',
    now: clock.now,
    ...(options.persistence ? { persistence: options.persistence } : {}),
    ...(options.warn ? { warn: options.warn } : {}),
  });
  const room = filled(store);
  expect(store.configureRoom(room, 'p1', { turnTimerSeconds: seconds, ...(options.setup ? { setup: options.setup } : {}) }).ok).toBe(true);
  connectAll(store, room);
  return { clock, store, room };
}

/** The timer must never build, trade or move a ship of its own accord. */
const TIMER_ACTIONS = new Set<ActionType>(['rollDice', 'discardForSeven', 'stealForSeven', 'shakeMothership', 'encounterChoice', 'encounterPick', 'foundTradeStation', 'endTurn', 'draftColony', 'draftFinish']);

describe('turn timer config', () => {
  it('TURN_TIMER_CHOICES: null or a listed number of seconds', () => {
    expect(TURN_TIMER_CHOICES.length).toBeGreaterThan(0);
    expect(isTurnTimerChoice(null)).toBe(true);
    for (const s of TURN_TIMER_CHOICES) expect(isTurnTimerChoice(s)).toBe(true);
    for (const bad of [0, -30, 31, '30', undefined, Number.NaN]) expect(isTurnTimerChoice(bad)).toBe(false);
  });

  it('configureRoom({ turnTimerSeconds }): host only, before the start, null or a listed value; persisted', async () => {
    const persistence = new MemoryRoomPersistence();
    const store = new RoomStore({ persistence });
    const room = filled(store);
    expect(room.config.turnTimerSeconds).toBeNull(); // off by default (spec §13)
    expect(store.configureRoom(room, 'p2', { turnTimerSeconds: 60 })).toMatchObject({ ok: false, error: { code: 'notHost' } });
    for (const bad of [99, '60', 0, -1, true, {}]) {
      expect(store.configureRoom(room, 'p1', { turnTimerSeconds: bad }), String(bad)).toMatchObject({ ok: false, error: { code: 'badRequest' } });
    }
    // A bad timer refuses the whole patch: the variant does not change either.
    expect(store.configureRoom(room, 'p1', { variant: 'explorer', turnTimerSeconds: 7 }).ok).toBe(false);
    expect(room.config).toEqual({ turnTimerSeconds: null, variant: 'beginner', setup: 'preset' });
    const smallest = Math.min(...TURN_TIMER_CHOICES);
    expect(store.configureRoom(room, 'p1', { turnTimerSeconds: smallest }).ok).toBe(true);
    expect(store.lobbyView(room).config.turnTimerSeconds).toBe(smallest);
    await store.flush();
    expect(persistence.get(room.code)?.config.turnTimerSeconds).toBe(smallest);
    expect(store.configureRoom(room, 'p1', { turnTimerSeconds: null }).ok).toBe(true);
    expect(room.config.turnTimerSeconds).toBeNull();
    store.startGame(room, 'p1');
    expect(store.configureRoom(room, 'p1', { turnTimerSeconds: 60 })).toMatchObject({ ok: false, error: { code: 'alreadyStarted' } });
  });
});

describe('turn timer deadline', () => {
  it('null disables: no deadline, expiry does nothing', () => {
    const { clock, store, room } = timedRoom(null);
    store.startGame(room, 'p1');
    expect(room.deadlineAt).toBeNull();
    expect(store.lobbyView(room).deadlineAt).toBeNull();
    clock.t += 10 * 60 * 1000;
    const run = store.expireTurn(room);
    expect(run.skipped).toBe('noDeadline');
    expect(room.actions).toEqual([]);
  });

  it('starts with the game; actions inside the turn keep it; the next turn gets a fresh one', () => {
    const { clock, store, room } = timedRoom(60);
    expect(room.deadlineAt).toBeNull(); // not before the start
    store.startGame(room, 'p1');
    const start = clock.t;
    expect(room.deadlineAt).toBe(start + 60_000);
    expect(store.lobbyView(room).deadlineAt).toBe(start + 60_000);
    const first = room.game!.activePlayer;
    clock.t += 20_000;
    // A timely action: same turn, same deadline.
    const roll = timeoutAction(room.game!)!;
    expect(store.applyAction(room, roll.playerId, roll).ok).toBe(true);
    expect(room.deadlineAt).toBe(start + 60_000);
    // A rejected action changes nothing.
    expect(store.applyAction(room, first, { type: 'rollDice', playerId: first }).ok).toBe(false);
    expect(room.deadlineAt).toBe(start + 60_000);
    expect(store.expireTurn(room).skipped).toBe('notDue');
    // Finishing the turn in time re-arms for the next player from now.
    while (room.game!.activePlayer === first) {
      const a = timeoutAction(room.game!)!;
      expect(store.applyAction(room, a.playerId, a).ok, a.type).toBe(true);
    }
    expect(room.deadlineAt).toBe(clock.t + 60_000);
  });

  it('expiry plays the minimal sequence to the next player, as normal accepted actions, with a timer chat line', () => {
    const { clock, store, room } = timedRoom(30);
    store.startGame(room, 'p1');
    const first = room.game!.activePlayer;
    const firstName = room.players.find((p) => p.id === first)!.name;
    clock.t = room.deadlineAt! + 1;
    const seen: Action[] = [];
    const run = store.expireTurn(room, (a) => seen.push(a));
    expect(run.skipped).toBeNull();
    expect(run.rejected).toBeNull();
    expect(seen).toEqual(run.actions);
    expect(room.actions).toEqual(run.actions); // logged and replayable like any action
    expect(run.actions[0]).toEqual({ type: 'rollDice', playerId: first });
    expect(run.actions.at(-1)).toEqual({ type: 'endTurn', playerId: first });
    expect(run.actions.every((a) => TIMER_ACTIONS.has(a.type))).toBe(true);
    expect(room.game!.activePlayer).not.toBe(first);
    expect(room.game!.phase).toBe('production');
    expect(room.deadlineAt).toBe(clock.t + 30_000);
    expect(run.message).toMatchObject({ from: TIMER_CHAT_ID, name: 'Timer' });
    expect(run.message!.text).toMatch(new RegExp(`^timer: ${firstName} ran out of time; rolled, .*ended the turn$`));
    expect(room.messages.at(-1)).toEqual(run.message);
    // Replaying the log reproduces the state (the automatic actions are ordinary engine actions).
    const plain = (g: GameState) => ({ ...g, players: g.players.map((p) => ({ ...p, connected: false })) });
    expect(plain(store.replayState(room, room.actions.length))).toEqual(plain(room.game!));
  });

  it('many expired turns in a row: every one passes the turn, never builds, trades or moves (7s and encounters included)', () => {
    const { clock, store, room } = timedRoom(60);
    store.startGame(room, 'p1');
    const types = new Set<ActionType>();
    for (let turn = 0; turn < 60; turn++) {
      const key = turnKey(room.game!);
      clock.t = room.deadlineAt! + 1;
      const run = store.expireTurn(room);
      expect(run.rejected, `turn ${turn}`).toBeNull();
      expect(turnKey(room.game!)).not.toBe(key);
      for (const a of run.actions) types.add(a.type);
    }
    expect([...types].every((t) => TIMER_ACTIONS.has(t))).toBe(true);
    expect(types.has('shakeMothership')).toBe(true);
    expect(types.has('encounterChoice')).toBe(true);
    expect(types.has('discardForSeven') || types.has('stealForSeven')).toBe(true);
  });

  it('the advanced draft: each expired pick takes the first legal site, through to turn 1', () => {
    const { clock, store, room } = timedRoom(30, { setup: 'draft' });
    store.startGame(room, 'p1');
    expect(room.game!.phase).toBe('setup');
    let picks = 0;
    while (room.game!.phase === 'setup') {
      clock.t = room.deadlineAt! + 1;
      const run = store.expireTurn(room);
      expect(run.rejected).toBeNull();
      expect(run.actions).toHaveLength(1);
      expect(['draftColony', 'draftFinish']).toContain(run.actions[0]!.type);
      picks++;
    }
    expect(picks).toBe(12); // 3 players × 4 rounds
    expect(room.game!.phase).toBe('production');
    expect(room.deadlineAt).toBe(clock.t + 30_000);
  });

  it('a 7 owed by another player is resolved as that player', () => {
    const { clock, store, room } = timedRoom(60);
    store.startGame(room, 'p1');
    // Give everyone 9 cards and look for a roll of 7 (the rng is seeded, so this is deterministic).
    let found = false;
    for (let turn = 0; turn < 60 && !found; turn++) {
      for (const p of room.game!.players) p.hand = ['ore', 'ore', 'fuel', 'fuel', 'carbon', 'carbon', 'food', 'food', 'goods'];
      clock.t = room.deadlineAt! + 1;
      const run = store.expireTurn(room);
      expect(run.rejected).toBeNull();
      const discards = run.actions.filter((a) => a.type === 'discardForSeven');
      if (discards.length > 0) {
        found = true;
        const roller = run.actions[0]!.playerId;
        expect(discards.length).toBe(3);
        expect(discards.some((a) => a.playerId !== roller)).toBe(true);
        expect(run.actions.some((a) => a.type === 'stealForSeven' && a.playerId === roller)).toBe(true);
      }
    }
    expect(found).toBe(true);
  });

  it('a refused or impossible automatic action stops the timer for that turn (no loop) and warns', () => {
    const warnings: string[] = [];
    const { clock, store, room } = timedRoom(60, { warn: (m) => warnings.push(m) });
    store.startGame(room, 'p1');
    // A state the engine cannot leave automatically: an encounter phase with no encounter.
    const stuck = structuredClone(room.game!);
    stuck.phase = 'flight.encounter';
    delete stuck.turn.encounter;
    room.game = stuck;
    clock.t = room.deadlineAt! + 1;
    const run = store.expireTurn(room);
    expect(run.actions).toEqual([]);
    expect(run.rejected).toMatch(/no automatic action/);
    expect(room.deadlineAt).toBeNull();
    expect(warnings.some((w) => w.includes('timer') && w.includes(room.code))).toBe(true);
    expect(run.message!.text).toMatch(/^timer: .* the timer stopped/);
    expect(store.expireTurn(room).skipped).toBe('noDeadline');
  });

  it('waits while nobody is connected; the first player back gets a fresh budget', () => {
    const { clock, store, room } = timedRoom(60);
    store.startGame(room, 'p1');
    for (const p of room.players) store.unbindSocket(`sock-${p.id}`);
    clock.t = room.deadlineAt! + 5_000;
    expect(store.expireTurn(room).skipped).toBe('nobodyConnected');
    expect(room.actions).toEqual([]);
    store.bindSocket(room, room.players[1]!, 'back');
    expect(room.deadlineAt).toBe(clock.t + 60_000);
  });

  it('a restart (snapshot → restore) keeps the deadline; older snapshots without it still restore', async () => {
    const persistence = new MemoryRoomPersistence();
    const { clock, store, room } = timedRoom(90, { persistence });
    store.startGame(room, 'p1');
    clock.t += 5_000;
    const roll = timeoutAction(room.game!)!;
    store.applyAction(room, roll.playerId, roll);
    const deadline = room.deadlineAt!;
    await store.flush();
    expect(persistence.get(room.code)?.deadlineAt).toBe(deadline);

    // Boot a second store from the same persistence.
    const clock2 = new Clock();
    clock2.t = clock.t + 1_000;
    const store2 = new RoomStore({ persistence, now: clock2.now });
    expect(await store2.restoreAll()).toBe(1);
    const back = store2.getRoom(room.code)!;
    expect(back.deadlineAt).toBe(deadline);
    expect(store2.lobbyView(back).deadlineAt).toBe(deadline);
    // Same turn after the restart: an action keeps the deadline; expiry still finishes the turn.
    connectAll(store2, back);
    expect(back.deadlineAt).toBe(deadline);
    clock2.t = deadline + 1;
    const run = store2.expireTurn(back);
    expect(run.rejected).toBeNull();
    expect(run.actions.at(-1)?.type).toBe('endTurn');
    expect(back.deadlineAt).toBe(clock2.t + 90_000);

    // A snapshot written before phase 7 (no `deadlineAt`): a configured timer starts afresh, none stays off.
    const { deadlineAt: _d, ...legacy } = JSON.parse(JSON.stringify(store.snapshot(room))) as StoredRoomSnapshot;
    const store3 = new RoomStore({ now: () => 5_000_000 });
    expect(store3.restore(legacy).deadlineAt).toBe(5_000_000 + 90_000);
    const store4 = new RoomStore();
    expect(store4.restore({ ...legacy, config: { ...legacy.config, turnTimerSeconds: null } }).deadlineAt).toBeNull();
  });

  it('game over clears the deadline', () => {
    const { store, room } = timedRoom(60);
    store.startGame(room, 'p1');
    const won = structuredClone(room.game!);
    const me = won.players.find((p) => p.id === won.activePlayer)!;
    me.famePieces = 40; // VP are recomputed after the next action; this much fame wins on the spot.
    room.game = won;
    const roll = timeoutAction(room.game)!;
    expect(store.applyAction(room, roll.playerId, roll).ok).toBe(true);
    expect(room.game.phase).toBe('gameOver');
    expect(room.deadlineAt).toBeNull();
    expect(timeoutAction(room.game)).toBeNull();
  });

  /** The active player's colony ship parked on a free colony site and flagged "must found or leave" (spec §9.2). */
  function parked(coloniesLeft?: number) {
    const { clock, store, room } = timedRoom(60);
    store.startGame(room, 'p1');
    const g = structuredClone(room.game!);
    const ship = shipsOf(g, g.activePlayer).find((s) => s.kind === 'colony')!;
    const site = 'S(0,5)'; // a free colony site where the seeded game's active colony ship may found
    expect(g.board.nodes[site]?.siteType).toBe('colonySite');
    g.board.ships[ship.id]!.nodeId = site;
    g.board.ships[ship.id]!.mustFoundOrLeave = true;
    if (coloniesLeft !== undefined) g.players.find((p) => p.id === g.activePlayer)!.pieces.coloniesLeft = coloniesLeft;
    // No action yet: the edited position is the replay start too, so replay must reproduce the automatic turn.
    room.game = g;
    room.initial = g;
    clock.t = room.deadlineAt! + 1;
    return { store, room, ship: ship.id, site, pid: g.activePlayer };
  }

  it('the one forced move: a parked colony ship that may found founds, then the turn ends', () => {
    const { store, room, ship, pid } = parked();
    const run = store.expireTurn(room);
    expect(run.rejected).toBeNull();
    expect(room.game!.activePlayer).not.toBe(pid);
    const types = run.actions.map((a) => a.type);
    expect(types).toContain('foundColony');
    expect(types).not.toContain('moveShip');
    expect(types.indexOf('foundColony')).toBe(types.length - 2);
    expect(types.at(-1)).toBe('endTurn');
    expect(run.actions.find((a) => a.type === 'foundColony')).toMatchObject({ playerId: pid, shipId: ship });
    expect(run.message!.text).toMatch(/founded the colony, ended the turn$/);
    expect(store.replayState(room, room.actions.length).board).toEqual(room.game!.board);
  });

  it('the one forced move: a parked colony ship that cannot found takes its shortest legal move off the site', () => {
    const { store, room, ship, site, pid } = parked(0);
    const run = store.expireTurn(room);
    expect(run.rejected).toBeNull();
    expect(room.game!.activePlayer).not.toBe(pid);
    const types = run.actions.map((a) => a.type);
    expect(types).not.toContain('foundColony');
    expect(types.filter((t) => t === 'moveShip')).toHaveLength(1);
    const move = run.actions.find((a) => a.type === 'moveShip');
    expect(move).toMatchObject({ playerId: pid, shipId: ship });
    expect(room.game!.board.ships[ship]!.nodeId).not.toBe(site);
    expect([...types].every((t) => TIMER_ACTIONS.has(t) || t === 'moveShip')).toBe(true);
    expect(run.message!.text).toMatch(/moved the parked ship off its site, ended the turn$/);
    expect(store.replayState(room, room.actions.length).board).toEqual(room.game!.board);
  });
});

describe('TurnTimers (scheduling)', () => {
  it('arms one timeout per room at its deadline, re-arms when it moves, clears on null, drops deleted rooms', () => {
    const { clock, store, room } = timedRoom(60);
    const scheduler = new FakeScheduler(clock);
    const fired: string[] = [];
    const timers = new TurnTimers(store, (r) => fired.push(r.code), scheduler);
    timers.arm(room); // not started: nothing
    expect(timers.size).toBe(0);
    store.startGame(room, 'p1');
    timers.arm(room);
    timers.arm(room); // idempotent
    expect(timers.size).toBe(1);
    expect(scheduler.tasks.size).toBe(1);
    expect(timers.armedAt(room.code)).toBe(room.deadlineAt);
    scheduler.advance(59_999);
    expect(fired).toEqual([]);
    scheduler.advance(1);
    expect(fired).toEqual([room.code]);
    expect(timers.size).toBe(0);

    // Deadline moves → old timeout replaced.
    room.deadlineAt = clock.t + 10_000;
    timers.arm(room);
    room.deadlineAt = clock.t + 20_000;
    timers.arm(room);
    expect(scheduler.tasks.size).toBe(1);
    scheduler.advance(15_000);
    expect(fired).toHaveLength(1);
    scheduler.advance(5_000);
    expect(fired).toHaveLength(2);

    // null clears.
    room.deadlineAt = clock.t + 10_000;
    timers.arm(room);
    room.deadlineAt = null;
    timers.arm(room);
    expect(scheduler.tasks.size).toBe(0);

    // A swept room's timeout does nothing when it fires.
    room.deadlineAt = clock.t + 10_000;
    timers.arm(room);
    store.deleteRoom(room.code);
    scheduler.advance(10_000);
    expect(fired).toHaveLength(2);
    timers.clearAll();
    expect(timers.size).toBe(0);
  });
});
