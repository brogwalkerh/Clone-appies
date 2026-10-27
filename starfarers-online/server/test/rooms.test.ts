import { ROOM_CODE_LENGTH, ROOM_MAX_PLAYERS, draftableSites, type GameState } from '@starfarers/shared';
import { describe, expect, it } from 'vitest';
import { RoomStore, normalizeCode, randomRoomCode } from '../src/rooms.js';
import { botRandom, nextAction } from './bot.js';

function filled(store: RoomStore, n = 3) {
  const created = store.createRoom('Test', 'Ann');
  if (!created.ok) throw new Error(created.error.message);
  const room = created.value.room;
  const names = ['Bob', 'Cid', 'Dee'];
  for (let i = 1; i < n; i++) {
    const j = store.joinRoom(room.code, names[i - 1]);
    if (!j.ok) throw new Error(j.error.message);
  }
  return room;
}

describe('RoomStore lifecycle', () => {
  it('creates a room with a 6-char code and a host token', () => {
    const store = new RoomStore();
    const r = store.createRoom('Friday', 'Ann');
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.room.code).toHaveLength(ROOM_CODE_LENGTH);
    expect(r.value.room.hostId).toBe('p1');
    expect(r.value.player.token).toMatch(/[0-9a-f-]{36}/);
    expect(store.getRoom(r.value.room.code.toLowerCase())?.code).toBe(r.value.room.code);
    expect(normalizeCode(' abc123 ')).toBe('ABC123');
    expect(randomRoomCode()).not.toMatch(/[0O1I]/);
  });

  it('rejects bad names, unknown rooms, duplicates, full rooms and late joins', () => {
    const store = new RoomStore();
    expect(store.createRoom('x', '   ').ok).toBe(false);
    expect(store.joinRoom('NOPE42', 'Bob')).toMatchObject({ ok: false, error: { code: 'noSuchRoom' } });
    const room = filled(store, 4);
    expect(room.players.map((p) => p.color)).toEqual(['red', 'blue', 'yellow', 'white']);
    expect(store.joinRoom(room.code, 'Eve')).toMatchObject({ ok: false, error: { code: 'roomFull' } });
    const r2 = filled(store, 2);
    expect(store.joinRoom(r2.code, 'ann')).toMatchObject({ ok: false, error: { code: 'nameTaken' } });
    expect(store.startGame(r2, 'p1')).toMatchObject({ ok: false, error: { code: 'tooFewPlayers' } });
    const r3 = filled(store, 3);
    expect(store.startGame(r3, 'p2')).toMatchObject({ ok: false, error: { code: 'notHost' } });
    expect(store.startGame(r3, 'p1').ok).toBe(true);
    expect(store.joinRoom(r3.code, 'Zed')).toMatchObject({ ok: false, error: { code: 'alreadyStarted' } });
    expect(store.startGame(r3, 'p1')).toMatchObject({ ok: false, error: { code: 'alreadyStarted' } });
    expect(ROOM_MAX_PLAYERS).toBe(4);
  });

  it('starts a beginner game seeded by the store and keeps one rng per room', () => {
    const store = new RoomStore({ seedFactory: () => 'fixed-seed' });
    const room = filled(store);
    expect(store.startGame(room, 'p1').ok).toBe(true);
    expect(room.game?.seed).toBe('fixed-seed');
    expect(room.game?.players.map((p) => p.name)).toEqual(['Ann', 'Bob', 'Cid']);
    const active = room.game!.activePlayer;
    const a = store.applyAction(room, active, { type: 'rollDice', playerId: active });
    expect(a.ok).toBe(true);
    const roll = room.game!.turn.rolled;
    // A second store with the same seed reproduces the roll (same rng stream).
    const store2 = new RoomStore({ seedFactory: () => 'fixed-seed' });
    const room2 = filled(store2);
    store2.startGame(room2, 'p1');
    store2.applyAction(room2, active, { type: 'rollDice', playerId: active });
    expect(room2.game!.turn.rolled).toBe(roll);
  });

  it('refuses actions for another player, malformed actions, and before start', () => {
    const store = new RoomStore();
    const room = filled(store);
    expect(store.applyAction(room, 'p1', { type: 'rollDice', playerId: 'p1' })).toMatchObject({ ok: false, error: { code: 'notStarted' } });
    store.startGame(room, 'p1');
    const active = room.game!.activePlayer;
    const other = room.players.find((p) => p.id !== active)!.id;
    expect(store.applyAction(room, other, { type: 'rollDice', playerId: active })).toMatchObject({ ok: false, error: { code: 'badRequest' } });
    expect(store.applyAction(room, other, { type: 'rollDice', playerId: other })).toMatchObject({ ok: false, error: { code: 'notYourTurn' } });
    expect(store.applyAction(room, active, 'rollDice')).toMatchObject({ ok: false, error: { code: 'badRequest' } });
    expect(room.actions).toHaveLength(0);
    const before = room.game;
    expect(store.applyAction(room, active, { type: 'rollDice', playerId: active }).ok).toBe(true);
    expect(room.game).not.toBe(before);
    expect(room.actions).toHaveLength(1);
  });

  it('redacts the join reply per player and mirrors connection state', () => {
    const store = new RoomStore();
    const room = filled(store);
    store.startGame(room, 'p1');
    const [ann, bob] = room.players as [typeof room.players[0], typeof room.players[0]];
    store.bindSocket(room, ann, 'sock-a');
    const reply = store.joinReply(room, ann);
    expect(reply.session).toEqual({ roomCode: room.code, playerToken: ann.token, playerId: 'p1' });
    expect(reply.state?.players.find((p) => p.id === 'p1')?.hand.length).toBeGreaterThan(0);
    expect(reply.state?.players.find((p) => p.id === 'p2')?.hand).toEqual([]);
    expect(reply.state?.players.find((p) => p.id === 'p2')?.handCount).toBeGreaterThan(0);
    expect(reply.state?.seed).toBe('');
    expect(reply.lobby.players.find((p) => p.id === 'p1')).toMatchObject({ connected: true, isHost: true });
    expect(reply.lobby.players.find((p) => p.id === 'p2')).toMatchObject({ connected: false, isHost: false });
    expect(room.game?.players.find((p) => p.id === 'p1')?.connected).toBe(true);
    expect(store.unbindSocket('sock-a')?.player.id).toBe('p1');
    expect(room.game?.players.find((p) => p.id === 'p1')?.connected).toBe(false);
    expect(store.unbindSocket('nope')).toBeNull();
    // Rebinding reports the previous socket so it can be evicted.
    store.bindSocket(room, bob, 'sock-b1');
    expect(store.bindSocket(room, bob, 'sock-b2')).toBe('sock-b1');
    expect(store.resume(room.code, bob.token)).toMatchObject({ ok: true });
    expect(store.resume(room.code, 'wrong')).toMatchObject({ ok: false, error: { code: 'badToken' } });
  });

  it('chat is a room-level list, capped and trimmed', () => {
    const store = new RoomStore({ now: () => 42 });
    const room = filled(store);
    const ann = room.players[0]!;
    expect(store.addChat(room, ann, '   ')).toMatchObject({ ok: false });
    expect(store.addChat(room, ann, '  hi  ')).toMatchObject({ ok: true, value: { from: 'p1', name: 'Ann', text: 'hi', at: 42 } });
    expect(store.lobbyView(room).messages).toHaveLength(1);
    expect(room.game).toBeNull();
  });

  it('snapshot → restore reproduces the rng stream', () => {
    const store = new RoomStore({ seedFactory: () => 's' });
    const room = filled(store);
    store.startGame(room, 'p1');
    const active = room.game!.activePlayer;
    store.applyAction(room, active, { type: 'rollDice', playerId: active });
    const snap = store.snapshot(room);
    const twin = new RoomStore().restore(JSON.parse(JSON.stringify(snap)));
    expect(twin.game).toEqual(room.game);
    // Both continue identically.
    const rnd = botRandom(7);
    for (let i = 0; i < 30; i++) {
      const a = nextAction(room.game!, rnd);
      if (!a) break;
      const r1 = store.applyAction(room, a.playerId, a);
      const r2 = store.applyAction(twin, a.playerId, a);
      expect(r2.ok).toBe(r1.ok);
    }
    expect(twin.game).toEqual(room.game);
    expect(twin.actions).toEqual(room.actions);
  });

  it('configureRoom: host only, before the start, valid variants only; startGame uses it', () => {
    const store = new RoomStore({ seedFactory: () => 'variant-seed' });
    const room = filled(store);
    expect(store.lobbyView(room).config).toEqual({ turnTimerSeconds: null, variant: 'beginner', setup: 'preset' });
    expect(store.configureRoom(room, 'p2', { variant: 'strategic' })).toMatchObject({ ok: false, error: { code: 'notHost' } });
    expect(store.configureRoom(room, 'p1', { variant: 'classic' })).toMatchObject({ ok: false, error: { code: 'badRequest' } });
    expect(store.configureRoom(room, 'p1', 'strategic')).toMatchObject({ ok: false, error: { code: 'badRequest' } });
    expect(room.config.variant).toBe('beginner');
    expect(store.configureRoom(room, 'p1', { variant: 'explorer' }).ok).toBe(true);
    expect(store.lobbyView(room).config.variant).toBe('explorer');
    expect(store.configureRoom(room, 'p1', { variant: 'strategic', turnTimerSeconds: 99 }).ok).toBe(true);
    expect(room.config).toEqual({ turnTimerSeconds: null, variant: 'strategic', setup: 'preset' });
    expect(store.startGame(room, 'p1').ok).toBe(true);
    expect(room.game?.variant).toBe('strategic');
    expect(room.game?.seed).toBe('variant-seed');
    expect(store.configureRoom(room, 'p1', { variant: 'wild' })).toMatchObject({ ok: false, error: { code: 'alreadyStarted' } });
    expect(room.config.variant).toBe('strategic');
    // Every variant starts and is reproduced by the same seed.
    for (const variant of ['beginner', 'explorer', 'wild'] as const) {
      const s2 = new RoomStore({ seedFactory: () => 'variant-seed', codeFactory: () => 'ROOM42' });
      const r2 = filled(s2);
      expect(s2.configureRoom(r2, 'p1', { variant }).ok).toBe(true);
      expect(s2.startGame(r2, 'p1').ok).toBe(true);
      expect(r2.game?.variant).toBe(variant);
      const s3 = new RoomStore({ seedFactory: () => 'variant-seed', codeFactory: () => 'ROOM42' });
      const r3 = filled(s3);
      s3.configureRoom(r3, 'p1', { variant });
      s3.startGame(r3, 'p1');
      expect(r3.game).toEqual(r2.game);
      // Hidden tiles never reach a client.
      const view = s2.joinReply(r2, r2.players[1]!).state!;
      expect(Object.values(view.board.sectors).filter((x) => x.kind === 'hidden')).toHaveLength(variant === 'beginner' ? 0 : 15);
      expect(view.discPools).toEqual({ tri: [], br: [], hex: [] });
    }
  });

  it('configureRoom: the start mode (spec §3.4 draft) is a second, independent axis; startGame drafts', () => {
    const store = new RoomStore({ seedFactory: () => 'draft-room' });
    const room = filled(store);
    expect(store.configureRoom(room, 'p1', { setup: 'snake' })).toMatchObject({ ok: false, error: { code: 'badRequest' } });
    expect(store.configureRoom(room, 'p1', { variant: 'strategic', setup: 'snake' })).toMatchObject({ ok: false, error: { code: 'badRequest' } });
    expect(room.config).toEqual({ turnTimerSeconds: null, variant: 'beginner', setup: 'preset' });
    expect(store.configureRoom(room, 'p2', { setup: 'draft' })).toMatchObject({ ok: false, error: { code: 'notHost' } });
    expect(store.configureRoom(room, 'p1', { setup: 'draft' }).ok).toBe(true);
    expect(store.lobbyView(room).config).toEqual({ turnTimerSeconds: null, variant: 'beginner', setup: 'draft' });
    expect(store.configureRoom(room, 'p1', { variant: 'explorer' }).ok).toBe(true);
    expect(room.config).toEqual({ turnTimerSeconds: null, variant: 'explorer', setup: 'draft' });
    expect(store.configureRoom(room, 'p1', { variant: 'strategic', setup: 'preset' }).ok).toBe(true);
    expect(room.config).toEqual({ turnTimerSeconds: null, variant: 'strategic', setup: 'preset' });
    expect(store.configureRoom(room, 'p1', { setup: 'draft' }).ok).toBe(true);
    expect(store.startGame(room, 'p1').ok).toBe(true);
    const game = room.game!;
    expect(game.variant).toBe('strategic');
    expect(game.setup).toBe('draft');
    expect(game.phase).toBe('setup');
    expect(game.draft?.round).toBe(1);
    expect(Object.values(game.board.settlements)).toHaveLength(0);
    // The first picker drafts through the room store like any other action; the others are refused.
    const picker = game.activePlayer;
    const other = room.players.find((p) => p.id !== picker)!.id;
    const site = draftableSites(game)[0]!;
    expect(store.applyAction(room, other, { type: 'draftColony', playerId: other, siteId: site })).toMatchObject({ ok: false, error: { code: 'notYourTurn' } });
    expect(store.applyAction(room, picker, { type: 'rollDice', playerId: picker })).toMatchObject({ ok: false, error: { code: 'wrongPhase' } });
    expect(store.applyAction(room, picker, { type: 'draftColony', playerId: picker, siteId: site }).ok).toBe(true);
    expect(room.game!.board.settlements[site]?.owner).toBe(picker);
    expect(room.actions).toHaveLength(1);
    // Everyone sees the draft (public data) in their redacted view.
    const view = store.joinReply(room, room.players[1]!).state!;
    expect(view.draft).toEqual(room.game!.draft);
    expect(view.setup).toBe('draft');
  });

  it('a drafted game round-trips through snapshot/restore and replayState during the draft', () => {
    const store = new RoomStore({ seedFactory: () => 'draft-persist' });
    const room = filled(store, 4);
    store.configureRoom(room, 'p1', { setup: 'draft' });
    store.startGame(room, 'p1');
    const rnd = botRandom(11);
    const captured: GameState[] = [room.game!];
    for (let i = 0; i < 9; i++) {
      const a = nextAction(room.game!, rnd)!;
      expect(a.type).toBe('draftColony');
      expect(store.applyAction(room, a.playerId, a).ok).toBe(true);
      captured.push(room.game!);
    }
    expect(room.game!.phase).toBe('setup');
    expect(room.game!.draft?.round).toBe(3);
    // `connected` is mirrored from the sockets outside the engine (nobody is bound here), so compare without it.
    const plain = (g: GameState) => ({ ...g, players: g.players.map((p) => ({ ...p, connected: false })) });
    for (const k of [0, 1, 5, 9, 2, 9]) expect(plain(store.replayState(room, k)), `k=${k}`).toEqual(plain(captured[k]!));

    const snap = JSON.parse(JSON.stringify(store.snapshot(room)));
    expect(snap.config.setup).toBe('draft');
    const twinStore = new RoomStore();
    const twin = twinStore.restore(snap);
    expect(twin.game).toEqual(room.game);
    expect(twin.config).toEqual(room.config);
    // Both finish the draft identically and reach turn 1 with the same hands (the reserve pile is dealt by the engine).
    while (room.game!.phase === 'setup') {
      const a = nextAction(room.game!, rnd)!;
      expect(store.applyAction(room, a.playerId, a).ok).toBe(true);
      expect(twinStore.applyAction(twin, a.playerId, a).ok).toBe(true);
      captured.push(room.game!);
    }
    expect(room.actions).toHaveLength(16);
    expect(room.game!.phase).toBe('production');
    expect(room.game!.players.every((p) => p.hand.length === 3 && p.vp === 4)).toBe(true);
    expect(twin.game).toEqual(room.game);
    expect(plain(twinStore.replayState(twin, 16))).toEqual(plain(room.game!));
    for (const k of [12, 15, 16, 0]) expect(plain(store.replayState(room, k)), `k=${k}`).toEqual(plain(captured[k]!));
    // Turn 1 continues identically on both.
    const roll = nextAction(room.game!, rnd)!;
    expect(roll.type).toBe('rollDice');
    store.applyAction(room, roll.playerId, roll);
    twinStore.applyAction(twin, roll.playerId, roll);
    expect(twin.game).toEqual(room.game);
    // A snapshot written before `config.setup` existed restores as a preset room.
    const { setup: _setup, ...legacyConfig } = snap.config;
    const legacy = new RoomStore().restore({ ...snap, config: legacyConfig, started: false, game: null, initial: null, rngState: null, actions: [] });
    expect(legacy.config).toEqual({ turnTimerSeconds: null, variant: 'beginner', setup: 'preset' });
  });

  it('startWithState resumes an arbitrary state', () => {
    const store = new RoomStore();
    const room = filled(store);
    store.startGame(room, 'p1');
    const state: GameState = structuredClone(room.game!);
    const other = new RoomStore();
    const r2 = filled(other);
    other.startWithState(r2, state);
    expect(r2.started).toBe(true);
    expect(r2.game).toEqual(state);
  });
});
