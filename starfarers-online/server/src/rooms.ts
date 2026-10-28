/**
 * Room store (spec §13, HANDOFF §7). No sockets in here: every method is a
 * plain function over `Room` so it can be unit-tested directly.
 *
 * Rooms live in memory; an optional `RoomPersistence` (persist.ts) receives a
 * `RoomSnapshot` after every mutation that changes it, and `restoreAll()`
 * reads them back on boot. `sweep()` expires idle and finished rooms.
 *
 * One `Rng` per room is created from a server-generated seed when the game
 * starts and reused across actions; `snapshot()` carries `rng.getState()`.
 *
 * Turn timer (spec §13, HANDOFF §8.2): with `config.turnTimerSeconds` set,
 * `deadlineAt` is `now + seconds` whenever a new turn begins — the game
 * starts, or an accepted action changes `turnKey()` (the turn number and
 * active player; in the draft, the pick). Actions inside a turn do not extend
 * it: the budget is per turn. `expireTurn()` finishes an overdue turn through
 * the engine (autoplay.ts); the socket layer (timer.ts) only schedules it.
 *
 * Host controls (HANDOFF §8.3, §5.25): `kickPlayer` (host, lobby only) removes
 * a seat and with it the token; `transferHost` (host, any time) moves the
 * role. While the host is disconnected, `hostAwaySince` records since when;
 * once `handoverMs` has passed and another player is connected,
 * `handOverHostIfDue` makes the longest-connected player host: the connected
 * player with the earliest `connectedAt` (start of the current, unbroken
 * connection; a second tab replacing the first keeps it), ties by seat order.
 * It runs on every bind (a returning player may find the hand-over overdue)
 * and from a timeout the socket layer arms at `handoverDueAt` (handover.ts).
 * Every host change is activity: it bumps `updatedAt`, writes the room and
 * adds a `from: 'room'` chat line. `hostAwaySince` / `connectedAt` are memory
 * only: after a restart nobody is connected, the host's absence counts from
 * boot (`restore`), so a hand-over never happens earlier than one full window
 * after the restart.
 */

import {
  PLAYER_COLORS,
  ROOM_CODE_ALPHABET,
  ROOM_CODE_LENGTH,
  ROOM_MAX_PLAYERS,
  ROOM_MIN_PLAYERS,
  actionRevealsHiddenCards,
  applyAction,
  createGame,
  createRng,
  isGameVariant,
  isSetupMode,
  isTurnTimerChoice,
  TURN_TIMER_CHOICES,
  HOST_HANDOVER_MS,
  ROOM_CHAT_ID,
  redactState,
  rngFromState,
  type Action,
  type ChatMessage,
  type GameError,
  type GameState,
  type JoinReply,
  type LobbyView,
  type NetError,
  type PlayerColor,
  type PlayerId,
  type Rng,
  type RoomConfig,
  type SetupMode,
} from '@starfarers/shared';
import { randomBytes, randomInt, randomUUID } from 'node:crypto';
import { describeAutoAction, timeoutAction } from './autoplay.js';
import type { RoomPersistence } from './persist.js';

export interface RoomPlayer {
  id: PlayerId;
  name: string;
  color: PlayerColor;
  /** Secret the client stores to reconnect. Never sent to other players. */
  token: string;
  socketId: string | null;
  connected: boolean;
  /** When the current, unbroken connection began (Unix ms); `null` while disconnected. Memory only (snapshots store `null`). */
  connectedAt: number | null;
}

export interface Room {
  code: string;
  name: string;
  createdAt: number;
  /** Last activity: create, join, start, accepted action, chat, socket bind/unbind. Drives `sweep()`. */
  updatedAt: number;
  hostId: PlayerId;
  players: RoomPlayer[];
  config: RoomConfig;
  started: boolean;
  seed: string | null;
  game: GameState | null;
  /** State the game started from (unredacted); `null` before the start or for a room stored before replay existed. */
  initial: GameState | null;
  rng: Rng | null;
  /** Accepted actions since the start, authoritative (unredacted). */
  actions: Action[];
  messages: ChatMessage[];
  /** Turn timer: when the current turn runs out (Unix ms), `null` = no timer / not started / over. Persisted. */
  deadlineAt: number | null;
  /** `turnKey(game)` the deadline was set for (memory only; recomputed on restore). */
  deadlineKey: string | null;
  /** Since when the host has been disconnected (Unix ms); `null` while the host is connected. Memory only; `restore` sets it to now. */
  hostAwaySince: number | null;
}

/** Serialisable form of a room: what `RoomPersistence` stores. */
export interface RoomSnapshot {
  code: string;
  name: string;
  createdAt: number;
  /** Added in phase 6; older snapshots lack it and `restore()` falls back to `createdAt`. */
  updatedAt: number;
  hostId: PlayerId;
  players: RoomPlayer[];
  config: RoomConfig;
  started: boolean;
  seed: string | null;
  game: GameState | null;
  /** Added in phase 6 for server-side replay; older snapshots lack it and restore with `null` (replay unavailable). */
  initial: GameState | null;
  rngState: [number, number, number, number] | null;
  actions: Action[];
  messages: ChatMessage[];
  /** Added in phase 7 (turn timer); older snapshots lack it and `restore()` recomputes it. */
  deadlineAt: number | null;
}

export type RoomResult<T> = { ok: true; value: T } | { ok: false; error: NetError | GameError };

const MAX_NAME = 24;
const MAX_CHAT = 500;
const MAX_MESSAGES = 200;

function netError(code: NetError['code'], message: string): RoomResult<never> {
  return { ok: false, error: { code, message } };
}

/** A snapshot as it may come back from storage (written before `updatedAt`, `initial` or `config.setup` existed). */
export type StoredRoomSnapshot = Omit<RoomSnapshot, 'updatedAt' | 'initial' | 'config' | 'deadlineAt'> & {
  updatedAt?: number;
  initial?: GameState | null;
  deadlineAt?: number | null;
  config: Omit<RoomConfig, 'setup'> & { setup?: SetupMode };
};

/** What identifies "one turn" for the timer: a change starts a fresh deadline. */
export function turnKey(game: GameState): string {
  const draft = game.phase === 'setup' ? game.draft : undefined;
  return draft ? `draft:${draft.round}:${draft.index}:${game.activePlayer}` : `turn:${game.turnNumber}:${game.activePlayer}`;
}

/** Upper bound on automatic actions per expiry (a turn needs ~10 at most); a guard, never reached in practice. */
export const MAX_TIMER_STEPS = 40;

/** Chat sender id / name of the timer's "timer: …" lines (not a player id). */
export const TIMER_CHAT_ID = 'timer';

/** What `expireTurn` did. */
export interface TimerRun {
  /** Accepted automatic actions, in order. */
  actions: Action[];
  /** The "timer: …" chat line, when anything happened or the run had to stop. */
  message: ChatMessage | null;
  /** Why nothing ran: no deadline, not yet due, or nobody connected (the room waits). */
  skipped: 'noDeadline' | 'notDue' | 'nobodyConnected' | null;
  /** The automatic action the engine refused, if any (the timer then stops for this turn). */
  rejected: string | null;
}

export const DEFAULT_IDLE_MS = 24 * 60 * 60 * 1000;
export const DEFAULT_FINISHED_MS = 24 * 60 * 60 * 1000;

export interface RoomStoreOptions {
  /** Seed for a new game; defaults to 16 random hex chars. Tests inject a fixed one. */
  seedFactory?: () => string;
  now?: () => number;
  codeFactory?: () => string;
  /** Where snapshots go after each mutation; none = memory only. */
  persistence?: RoomPersistence;
  /** `sweep()` removes rooms with no activity for this long (default 24 h). */
  idleMs?: number;
  /** `sweep()` removes finished games this long after their last activity (default 24 h). */
  finishedMs?: number;
  /** Persistence failures are logged here, never thrown (default console.warn). */
  warn?: (message: string) => void;
  /** How long the host may be offline before the role passes on (default `HOST_HANDOVER_MS`). */
  handoverMs?: number;
}

/** What `handOverHostIfDue` / `transferHost` did. */
export interface HostChange {
  from: PlayerId;
  to: PlayerId;
  message: ChatMessage;
}

export function randomRoomCode(): string {
  let code = '';
  for (let i = 0; i < ROOM_CODE_LENGTH; i++) code += ROOM_CODE_ALPHABET[randomInt(ROOM_CODE_ALPHABET.length)];
  return code;
}

export function normalizeCode(code: string): string {
  return code.trim().toUpperCase();
}

function cleanName(name: unknown): string | null {
  if (typeof name !== 'string') return null;
  const trimmed = name.trim().replace(/\s+/g, ' ');
  if (trimmed.length === 0 || trimmed.length > MAX_NAME) return null;
  return trimmed;
}

export class RoomStore {
  private readonly rooms = new Map<string, Room>();
  private readonly seedFactory: () => string;
  private readonly now: () => number;
  private readonly codeFactory: () => string;
  private readonly persistence: RoomPersistence | null;
  private readonly idleMs: number;
  private readonly finishedMs: number;
  private readonly warn: (message: string) => void;
  private readonly handoverMs: number;
  /** Tail of the write chain per room code: writes for one room never interleave. */
  private readonly writes = new Map<string, Promise<void>>();
  /**
   * Last replayed position per room (one entry each): a later index continues
   * from it, an earlier one restarts from `initial`. The log only grows and a
   * prefix never changes, so nothing invalidates it except a new start.
   */
  private readonly replayCache = new WeakMap<Room, { index: number; state: GameState; rngState: [number, number, number, number] }>();

  constructor(options: RoomStoreOptions = {}) {
    this.seedFactory = options.seedFactory ?? (() => randomBytes(8).toString('hex'));
    this.now = options.now ?? (() => Date.now());
    this.codeFactory = options.codeFactory ?? randomRoomCode;
    this.persistence = options.persistence ?? null;
    this.idleMs = options.idleMs ?? DEFAULT_IDLE_MS;
    this.finishedMs = options.finishedMs ?? DEFAULT_FINISHED_MS;
    this.warn = options.warn ?? ((m) => console.warn(`[rooms] ${m}`));
    this.handoverMs = options.handoverMs ?? HOST_HANDOVER_MS;
  }

  get size(): number {
    return this.rooms.size;
  }

  getRoom(code: string): Room | undefined {
    return this.rooms.get(normalizeCode(code));
  }

  createRoom(roomName: unknown, playerName: unknown): RoomResult<{ room: Room; player: RoomPlayer }> {
    const name = cleanName(playerName);
    if (!name) return netError('badRequest', `Player name must be 1–${MAX_NAME} characters`);
    const title = cleanName(roomName) ?? `${name}'s game`;
    let code = this.codeFactory();
    for (let tries = 0; this.rooms.has(code) && tries < 100; tries++) code = this.codeFactory();
    if (this.rooms.has(code)) return netError('badRequest', 'Could not allocate a room code');
    const player: RoomPlayer = { id: 'p1', name, color: PLAYER_COLORS[0] as PlayerColor, token: randomUUID(), socketId: null, connected: false, connectedAt: null };
    const now = this.now();
    const room: Room = {
      code,
      name: title,
      createdAt: now,
      updatedAt: now,
      hostId: player.id,
      players: [player],
      config: { turnTimerSeconds: null, variant: 'beginner', setup: 'preset' },
      started: false,
      seed: null,
      game: null,
      initial: null,
      rng: null,
      actions: [],
      messages: [],
      deadlineAt: null,
      deadlineKey: null,
      hostAwaySince: now,
    };
    this.rooms.set(code, room);
    this.changed(room);
    return { ok: true, value: { room, player } };
  }

  joinRoom(code: unknown, playerName: unknown): RoomResult<{ room: Room; player: RoomPlayer }> {
    if (typeof code !== 'string') return netError('badRequest', 'Room code missing');
    const room = this.rooms.get(normalizeCode(code));
    if (!room) return netError('noSuchRoom', `No room ${normalizeCode(code)}`);
    const name = cleanName(playerName);
    if (!name) return netError('badRequest', `Player name must be 1–${MAX_NAME} characters`);
    if (room.started) return netError('alreadyStarted', 'That game has already started');
    if (room.players.length >= ROOM_MAX_PLAYERS) return netError('roomFull', `Room ${room.code} already has ${ROOM_MAX_PLAYERS} players`);
    if (room.players.some((p) => p.name.toLowerCase() === name.toLowerCase())) return netError('nameTaken', `Someone in the room is already called ${name}`);
    const taken = new Set(room.players.map((p) => p.color));
    const color = PLAYER_COLORS.find((c) => !taken.has(c)) as PlayerColor;
    const usedIds = new Set(room.players.map((p) => p.id));
    let n = 1;
    while (usedIds.has(`p${n}`)) n++;
    const player: RoomPlayer = { id: `p${n}`, name, color, token: randomUUID(), socketId: null, connected: false, connectedAt: null };
    room.players.push(player);
    this.changed(room);
    return { ok: true, value: { room, player } };
  }

  /** Re-identify a player by token (reconnect, page reload). */
  resume(code: unknown, token: unknown): RoomResult<{ room: Room; player: RoomPlayer }> {
    if (typeof code !== 'string' || typeof token !== 'string') return netError('badRequest', 'Room code and token required');
    const room = this.rooms.get(normalizeCode(code));
    if (!room) return netError('noSuchRoom', `No room ${normalizeCode(code)}`);
    const player = room.players.find((p) => p.token === token);
    if (!player) return netError('badToken', 'That session is not valid for this room');
    return { ok: true, value: { room, player } };
  }

  /** Attach a socket to a player (connected = true). Returns the previous socket id, if another was bound. */
  bindSocket(room: Room, player: RoomPlayer, socketId: string): string | null {
    const previous = player.socketId !== socketId ? player.socketId : null;
    // An overdue turn in a room nobody was in (the timer waits for players): the first one back gets a fresh turn budget.
    if (!room.players.some((p) => p.connected) && room.deadlineAt !== null && room.deadlineAt <= this.now() && room.config.turnTimerSeconds !== null) {
      room.deadlineAt = this.now() + room.config.turnTimerSeconds * 1000;
    }
    player.socketId = socketId;
    if (!player.connected) player.connectedAt = this.now();
    player.connected = true;
    this.mirrorConnected(room);
    room.updatedAt = this.now();
    this.syncHostAway(room);
    this.handOverHostIfDue(room);
    return previous;
  }

  /** Detach a socket; returns the room/player it was bound to, if any. */
  unbindSocket(socketId: string): { room: Room; player: RoomPlayer } | null {
    for (const room of this.rooms.values()) {
      const player = room.players.find((p) => p.socketId === socketId);
      if (player) {
        player.socketId = null;
        player.connected = false;
        player.connectedAt = null;
        this.mirrorConnected(room);
        room.updatedAt = this.now();
        this.syncHostAway(room);
        return { room, player };
      }
    }
    return null;
  }

  /** Keep `GameState.players[*].connected` in step with the sockets (presentation only; no rule depends on it). */
  private mirrorConnected(room: Room): void {
    if (!room.game) return;
    room.game = {
      ...room.game,
      players: room.game.players.map((gp) => {
        const rp = room.players.find((p) => p.id === gp.id);
        return rp ? { ...gp, connected: rp.connected } : gp;
      }),
    };
  }

  /** Start the host's absence clock when the host is offline, stop it when online. */
  private syncHostAway(room: Room): void {
    const host = room.players.find((p) => p.id === room.hostId);
    if (host?.connected) room.hostAwaySince = null;
    else room.hostAwaySince ??= this.now();
  }

  /** The connected non-host player who has been connected longest (earliest `connectedAt`, ties by seat order). */
  handoverCandidate(room: Room): RoomPlayer | null {
    let best: RoomPlayer | null = null;
    for (const p of room.players) {
      if (p.id === room.hostId || !p.connected || p.connectedAt === null) continue;
      if (!best || p.connectedAt < (best.connectedAt as number)) best = p;
    }
    return best;
  }

  /** When the host role passes on if nothing changes: host offline and someone else connected; else `null`. */
  handoverDueAt(room: Room): number | null {
    if (room.hostAwaySince === null || !this.handoverCandidate(room)) return null;
    return room.hostAwaySince + this.handoverMs;
  }

  /** Hand the host role to the longest-connected player once the host has been offline for `handoverMs`. */
  handOverHostIfDue(room: Room): HostChange | null {
    const due = this.handoverDueAt(room);
    if (due === null || this.now() < due) return null;
    const to = this.handoverCandidate(room) as RoomPlayer;
    const from = room.players.find((p) => p.id === room.hostId);
    const minutes = Math.round(this.handoverMs / 60_000);
    return this.setHost(room, to, `room: ${from?.name ?? room.hostId} has been offline for ${minutes > 0 ? `${minutes} min` : `${Math.round(this.handoverMs / 1000)} s`}; ${to.name} is now the host`);
  }

  private setHost(room: Room, to: RoomPlayer, text: string): HostChange {
    const from = room.hostId;
    room.hostId = to.id;
    this.syncHostAway(room);
    const message = this.systemChat(room, text, ROOM_CHAT_ID, 'Room');
    return { from, to: to.id, message };
  }

  /** Host only, any time: make another seated player the host (written like any activity). */
  transferHost(room: Room, byPlayerId: PlayerId, targetId: unknown): RoomResult<HostChange> {
    if (room.hostId !== byPlayerId) return netError('notHost', 'Only the host can hand the host role on');
    const target = room.players.find((p) => p.id === targetId);
    if (!target) return netError('badRequest', `No player ${String(targetId)} in this room`);
    if (target.id === byPlayerId) return netError('badRequest', 'You are already the host');
    const by = room.players.find((p) => p.id === byPlayerId);
    return { ok: true, value: this.setHost(room, target, `room: ${by?.name ?? byPlayerId} made ${target.name} the host`) };
  }

  /**
   * Host only, before the start: remove another player's seat. The token goes
   * with it, so the kicked client cannot resume (it may join again by name
   * like anyone else; a kick is not a ban). Returns the removed player, whose
   * `socketId` the socket layer notifies.
   */
  kickPlayer(room: Room, byPlayerId: PlayerId, targetId: unknown): RoomResult<{ player: RoomPlayer; message: ChatMessage }> {
    if (room.hostId !== byPlayerId) return netError('notHost', 'Only the host can remove a player');
    if (room.started) return netError('alreadyStarted', 'The game has started; every seat stays');
    const index = room.players.findIndex((p) => p.id === targetId);
    const target = room.players[index];
    if (!target) return netError('badRequest', `No player ${String(targetId)} in this room`);
    if (target.id === byPlayerId) return netError('badRequest', 'The host cannot remove themself');
    room.players.splice(index, 1);
    const by = room.players.find((p) => p.id === byPlayerId);
    const message = this.systemChat(room, `room: ${by?.name ?? byPlayerId} removed ${target.name} from the room`, ROOM_CHAT_ID, 'Room');
    return { ok: true, value: { player: target, message } };
  }

  /**
   * Host only, before the start: change the room's set-up (`variant`, `setup`, `turnTimerSeconds`).
   * Unknown keys are ignored; nothing changes on a bad value. `turnTimerSeconds` is `null` or one of
   * `TURN_TIMER_CHOICES`.
   */
  configureRoom(room: Room, byPlayerId: PlayerId, patch: unknown): RoomResult<Room> {
    if (room.hostId !== byPlayerId) return netError('notHost', 'Only the host can change the set-up');
    if (room.started) return netError('alreadyStarted', 'The game has already started');
    if (typeof patch !== 'object' || patch === null) return netError('badRequest', 'A room configuration is needed');
    const { variant, setup, turnTimerSeconds } = patch as { variant?: unknown; setup?: unknown; turnTimerSeconds?: unknown };
    if (variant !== undefined && !isGameVariant(variant)) return netError('badRequest', `Unknown set-up ${String(variant)}`);
    if (setup !== undefined && !isSetupMode(setup)) return netError('badRequest', `Unknown start mode ${String(setup)}`);
    if (turnTimerSeconds !== undefined && !isTurnTimerChoice(turnTimerSeconds)) {
      return netError('badRequest', `Turn timer must be off (null) or one of ${TURN_TIMER_CHOICES.join(', ')} seconds`);
    }
    if (variant !== undefined && isGameVariant(variant)) room.config.variant = variant;
    if (setup !== undefined && isSetupMode(setup)) room.config.setup = setup;
    if (turnTimerSeconds !== undefined && isTurnTimerChoice(turnTimerSeconds)) room.config.turnTimerSeconds = turnTimerSeconds;
    // Configuring is activity (HANDOFF §5.18): without a write the choice is lost on restart.
    if (variant !== undefined || setup !== undefined || turnTimerSeconds !== undefined) this.changed(room);
    return { ok: true, value: room };
  }

  startGame(room: Room, byPlayerId: PlayerId): RoomResult<Room> {
    if (room.hostId !== byPlayerId) return netError('notHost', 'Only the host can start the game');
    if (room.started) return netError('alreadyStarted', 'The game has already started');
    if (room.players.length < ROOM_MIN_PLAYERS) return netError('tooFewPlayers', `Need ${ROOM_MIN_PLAYERS}–${ROOM_MAX_PLAYERS} players, have ${room.players.length}`);
    const seed = this.seedFactory();
    const game = createGame({
      variant: room.config.variant,
      setup: room.config.setup,
      id: room.code,
      seed,
      players: room.players.map((p) => ({ id: p.id, name: p.name, color: p.color })),
    });
    this.startWith(room, game, seed);
    return { ok: true, value: room };
  }

  /** Start from a given state (tests, resumed games). The rng is derived from the state's seed and log length. */
  startWithState(room: Room, game: GameState): Room {
    return this.startWith(room, game, `${game.seed}:${game.turnNumber}:${game.log.length}`);
  }

  private startWith(room: Room, game: GameState, rngSeed: string): Room {
    room.seed = rngSeed;
    room.game = game;
    room.initial = game;
    this.replayCache.delete(room);
    room.rng = createRng(rngSeed);
    room.started = true;
    room.actions = [];
    room.deadlineKey = null;
    this.mirrorConnected(room);
    this.refreshDeadline(room);
    this.changed(room);
    return room;
  }

  /**
   * Turn timer policy: no timer → `null`; game over → `null`; a new turn
   * (`turnKey` differs from the one the deadline was set for) → a fresh
   * `now + turnTimerSeconds`; otherwise the deadline stands.
   */
  private refreshDeadline(room: Room): void {
    const seconds = room.config.turnTimerSeconds;
    const game = room.game;
    if (seconds === null || !game || game.phase === 'gameOver' || game.winner !== null) {
      room.deadlineAt = null;
      room.deadlineKey = game ? turnKey(game) : null;
      return;
    }
    const key = turnKey(game);
    if (key !== room.deadlineKey) {
      room.deadlineAt = this.now() + seconds * 1000;
      room.deadlineKey = key;
    }
  }

  /**
   * The turn timer ran out: if `deadlineAt` has passed and somebody is in the
   * room, submit `timeoutAction` through `applyAction` (as the active player,
   * or whoever the game waits on) until the turn passes, calling `onApplied`
   * after each accepted action, and add a "timer: …" chat line. A refused
   * automatic action stops the run and clears the deadline for this turn, so
   * the timer can never loop; a room nobody is connected to waits instead
   * (the first player back gets a fresh budget, see `bindSocket`).
   */
  expireTurn(room: Room, onApplied: (action: Action) => void = () => {}): TimerRun {
    const run: TimerRun = { actions: [], message: null, skipped: null, rejected: null };
    if (!room.game || room.deadlineAt === null) return { ...run, skipped: 'noDeadline' };
    if (this.now() < room.deadlineAt) return { ...run, skipped: 'notDue' };
    if (!room.players.some((p) => p.connected)) return { ...run, skipped: 'nobodyConnected' };
    const startKey = turnKey(room.game);
    const late = room.players.find((p) => p.id === room.game?.activePlayer);
    const lateName = late?.name ?? room.game.activePlayer;
    for (let step = 0; step < MAX_TIMER_STEPS; step++) {
      const game: GameState | null = room.game;
      if (!game || game.phase === 'gameOver' || game.winner !== null || turnKey(game) !== startKey) break;
      const action = timeoutAction(game);
      if (!action) {
        run.rejected = `no automatic action in phase ${game.phase}`;
        break;
      }
      const result = this.applyAction(room, action.playerId, action);
      if (!result.ok) {
        run.rejected = `${action.type}: ${result.error.message}`;
        break;
      }
      run.actions.push(action);
      onApplied(action);
    }
    const game = room.game;
    if (game && turnKey(game) === startKey && game.phase !== 'gameOver' && game.winner === null) {
      // Stuck (refused, or no move left): stop for this turn rather than fire again.
      run.rejected ??= `the turn did not pass after ${MAX_TIMER_STEPS} automatic actions`;
      room.deadlineAt = null;
      this.warn(`timer in room ${room.code}: stopped, ${run.rejected}`);
    }
    const did = run.actions.map(describeAutoAction).join(', ');
    const text = run.rejected
      ? `timer: ${lateName} ran out of time; ${did ? `${did}, then ` : ''}the timer stopped (${run.rejected})`
      : `timer: ${lateName} ran out of time; ${did}`;
    run.message = this.systemChat(room, text);
    return run;
  }

  /** A chat line from the server itself (`from: TIMER_CHAT_ID` by default, `ROOM_CHAT_ID` for host notices). */
  private systemChat(room: Room, text: string, from: string = TIMER_CHAT_ID, name = 'Timer'): ChatMessage {
    const message: ChatMessage = { from, name, text: text.slice(0, MAX_CHAT), at: this.now() };
    room.messages.push(message);
    if (room.messages.length > MAX_MESSAGES) room.messages.splice(0, room.messages.length - MAX_MESSAGES);
    this.changed(room);
    return message;
  }

  /** Every room in memory (the timer arms them after a restart). */
  allRooms(): Room[] {
    return [...this.rooms.values()];
  }

  /** Validate the sender and run the engine. The state is replaced only on success. */
  applyAction(room: Room, playerId: PlayerId, action: unknown): RoomResult<GameState> {
    if (!room.started || !room.game || !room.rng) return netError('notStarted', 'The game has not started');
    if (typeof action !== 'object' || action === null || typeof (action as { type?: unknown }).type !== 'string') {
      return netError('badRequest', 'An action needs a string `type`');
    }
    const a = action as Action;
    if (a.playerId !== playerId) return netError('badRequest', `You may only act as ${playerId}`);
    const result = applyAction(room.game, a, room.rng);
    if (!result.ok) return { ok: false, error: result.error };
    room.game = result.value;
    room.actions.push(a);
    this.refreshDeadline(room);
    this.changed(room);
    return { ok: true, value: result.value };
  }

  addChat(room: Room, player: RoomPlayer, text: unknown): RoomResult<ChatMessage> {
    if (typeof text !== 'string' || text.trim().length === 0) return netError('badRequest', 'Empty message');
    const message: ChatMessage = { from: player.id, name: player.name, text: text.trim().slice(0, MAX_CHAT), at: this.now() };
    room.messages.push(message);
    if (room.messages.length > MAX_MESSAGES) room.messages.splice(0, room.messages.length - MAX_MESSAGES);
    this.changed(room);
    return { ok: true, value: message };
  }

  lobbyView(room: Room): LobbyView {
    return {
      code: room.code,
      name: room.name,
      players: room.players.map((p) => ({ id: p.id, name: p.name, color: p.color, connected: p.connected, isHost: p.id === room.hostId })),
      hostId: room.hostId,
      started: room.started,
      config: { ...room.config },
      messages: [...room.messages],
      minPlayers: ROOM_MIN_PLAYERS,
      maxPlayers: ROOM_MAX_PLAYERS,
      deadlineAt: room.deadlineAt,
      expiresAt: room.updatedAt + this.idleMs,
      idleMs: this.idleMs,
      hostHandoverAt: this.handoverDueAt(room),
    };
  }

  /** An accepted action as other players may see it (hidden card payloads removed). */
  redactAction(action: Action, viewerId: PlayerId): Action {
    if (action.playerId === viewerId || !actionRevealsHiddenCards(action)) return action;
    switch (action.type) {
      case 'discardForSeven':
        return { ...action, cards: [] };
      case 'encounterPick': {
        const { resources: _r, ...rest } = action;
        return rest;
      }
      default:
        return action;
    }
  }

  joinReply(room: Room, player: RoomPlayer): JoinReply {
    return {
      session: { roomCode: room.code, playerToken: player.token, playerId: player.id },
      lobby: this.lobbyView(room),
      state: room.game ? redactState(room.game, player.id) : null,
      actions: room.actions.map((a) => this.redactAction(a, player.id)),
      initial: room.initial ? redactState(room.initial, player.id) : null,
    };
  }

  /**
   * Authoritative state after the first `index` accepted actions (0 =
   * initial): `initial` + `actions[0..index)` through the engine with a fresh
   * `createRng(room.seed)`, so the live `room.rng` is never touched. Throws
   * when the room has no initial state or the index is out of range; use
   * `replayFor` for the validated, redacted form.
   */
  replayState(room: Room, index: number): GameState {
    if (!room.initial || room.seed === null) throw new Error(`Room ${room.code} has no initial state to replay from`);
    if (!Number.isInteger(index) || index < 0 || index > room.actions.length) throw new Error(`Replay index ${index} is outside 0–${room.actions.length}`);
    const cached = this.replayCache.get(room);
    let state = room.initial;
    let rng = createRng(room.seed);
    let from = 0;
    if (cached && cached.index <= index) {
      state = cached.state;
      rng = rngFromState(cached.rngState);
      from = cached.index;
    }
    for (let i = from; i < index; i++) {
      const result = applyAction(state, room.actions[i] as Action, rng);
      if (!result.ok) throw new Error(`Replay diverged at action ${i}: ${result.error.message}`);
      state = result.value;
    }
    this.replayCache.set(room, { index, state, rngState: rng.getState() });
    return state;
  }

  /** `replayState` for a player: validated, with today's connection flags, redacted for `playerId`. */
  replayFor(room: Room, playerId: PlayerId, index: unknown): RoomResult<GameState> {
    if (!room.started || !room.game) return netError('notStarted', 'The game has not started');
    if (typeof index !== 'number' || !Number.isInteger(index)) return netError('badRequest', 'Replay index must be an integer');
    if (index < 0 || index > room.actions.length) return netError('badRequest', `Replay index must be 0–${room.actions.length}`);
    if (!room.initial) return netError('badRequest', 'Replay is unavailable for this room: it was saved without its initial state');
    let state: GameState;
    try {
      // The live end needs no engine run (a backward jump restarts from `initial`, ~ms per action).
      state = index === room.actions.length ? room.game : this.replayState(room, index);
    } catch (err) {
      return netError('badRequest', `Replay failed: ${errMessage(err)}`);
    }
    const connected = new Map(room.players.map((p) => [p.id, p.connected]));
    const shown = { ...state, players: state.players.map((p) => ({ ...p, connected: connected.get(p.id) ?? p.connected })) };
    return { ok: true, value: redactState(shown, playerId) };
  }

  snapshot(room: Room): RoomSnapshot {
    return {
      code: room.code,
      name: room.name,
      createdAt: room.createdAt,
      updatedAt: room.updatedAt,
      hostId: room.hostId,
      players: room.players.map((p) => ({ ...p, socketId: null, connected: false, connectedAt: null })),
      config: { ...room.config },
      started: room.started,
      seed: room.seed,
      game: room.game,
      initial: room.initial,
      rngState: room.rng ? room.rng.getState() : null,
      actions: [...room.actions],
      messages: [...room.messages],
      deadlineAt: room.deadlineAt,
    };
  }

  /**
   * Rebuild a room from a snapshot: every player disconnected (and mirrored
   * into the game state), the rng continued from `rngState`. Does not write to
   * persistence (the snapshot came from there or from a test).
   */
  restore(snapshot: StoredRoomSnapshot): Room {
    const room: Room = {
      code: snapshot.code,
      name: snapshot.name,
      createdAt: snapshot.createdAt,
      updatedAt: snapshot.updatedAt ?? snapshot.createdAt,
      hostId: snapshot.hostId,
      players: snapshot.players.map((p) => ({ ...p, socketId: null, connected: false, connectedAt: null })),
      config: { ...snapshot.config, setup: snapshot.config.setup ?? 'preset' },
      started: snapshot.started,
      seed: snapshot.seed,
      game: snapshot.game,
      initial: snapshot.initial ?? null,
      rng: snapshot.rngState ? rngFromState(snapshot.rngState) : null,
      actions: [...snapshot.actions],
      messages: [...snapshot.messages],
      deadlineAt: snapshot.deadlineAt ?? null,
      deadlineKey: snapshot.game ? turnKey(snapshot.game) : null,
      // Nobody is connected after a restart: the host's absence (for the hand-over) counts from now.
      hostAwaySince: this.now(),
    };
    // A snapshot from before the timer existed: a configured timer starts a fresh budget now.
    if (snapshot.deadlineAt === undefined) {
      room.deadlineKey = null;
      this.refreshDeadline(room);
    }
    this.mirrorConnected(room);
    this.rooms.set(room.code, room);
    return room;
  }

  /** Remove a room from memory and from persistence. */
  deleteRoom(code: string): boolean {
    const key = normalizeCode(code);
    if (!this.rooms.delete(key)) return false;
    const persistence = this.persistence;
    if (persistence) this.enqueue(key, () => persistence.remove(key), `remove ${key}`);
    return true;
  }

  /** Load every stored room into memory. Returns how many were restored. */
  async restoreAll(): Promise<number> {
    if (!this.persistence) return 0;
    const snapshots = await this.persistence.loadAll();
    let count = 0;
    for (const snapshot of snapshots as StoredRoomSnapshot[]) {
      try {
        this.restore(snapshot);
        count++;
      } catch (err) {
        this.warn(`could not restore room ${String(snapshot.code)}: ${errMessage(err)}`);
      }
    }
    return count;
  }

  /**
   * Expire rooms (memory + persistence): no activity for `idleMs`, or a
   * finished game with no activity for `finishedMs`. A room with any connected
   * player is always kept. Returns the removed codes.
   */
  sweep(): string[] {
    const now = this.now();
    const removed: string[] = [];
    for (const room of [...this.rooms.values()]) {
      if (room.players.some((p) => p.connected)) continue;
      const idle = now - room.updatedAt;
      const finished = room.game !== null && (room.game.phase === 'gameOver' || room.game.winner !== null);
      if (idle > this.idleMs || (finished && idle > this.finishedMs)) {
        this.deleteRoom(room.code);
        removed.push(room.code);
      }
    }
    return removed;
  }

  /** Resolves once every write queued so far (and any queued meanwhile) has settled. */
  async flush(): Promise<void> {
    while (this.writes.size > 0) await Promise.all([...this.writes.values()]);
  }

  /** A mutation that changes the snapshot: bump `updatedAt` and persist. */
  private changed(room: Room): void {
    room.updatedAt = this.now();
    this.persist(room);
  }

  /**
   * Fire-and-forget save. The snapshot is taken now (the rng state moves on
   * with the next action); the write is chained behind earlier writes for the
   * same room so two quick actions cannot interleave their renames.
   */
  private persist(room: Room): void {
    const persistence = this.persistence;
    if (!persistence) return;
    // A stale reference to a deleted room must not resurrect its file.
    if (this.rooms.get(room.code) !== room) return;
    const snapshot = this.snapshot(room);
    this.enqueue(room.code, () => persistence.save(snapshot), `save ${room.code}`);
  }

  private enqueue(code: string, write: () => Promise<void>, what: string): void {
    const previous = this.writes.get(code) ?? Promise.resolve();
    const next = previous
      .then(write)
      .catch((err: unknown) => this.warn(`${what} failed: ${errMessage(err)}`));
    this.writes.set(code, next);
    void next.then(() => {
      if (this.writes.get(code) === next) this.writes.delete(code);
    });
  }
}

function errMessage(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}
