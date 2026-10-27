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
 */

import {
  PLAYER_COLORS,
  ROOM_CODE_ALPHABET,
  ROOM_CODE_LENGTH,
  ROOM_MAX_PLAYERS,
  ROOM_MIN_PLAYERS,
  actionRevealsHiddenCards,
  applyAction,
  createBeginnerGame,
  createRng,
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
} from '@starfarers/shared';
import { randomBytes, randomInt, randomUUID } from 'node:crypto';
import type { RoomPersistence } from './persist.js';

export interface RoomPlayer {
  id: PlayerId;
  name: string;
  color: PlayerColor;
  /** Secret the client stores to reconnect. Never sent to other players. */
  token: string;
  socketId: string | null;
  connected: boolean;
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
  rng: Rng | null;
  /** Accepted actions since the start, authoritative (unredacted). */
  actions: Action[];
  messages: ChatMessage[];
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
  rngState: [number, number, number, number] | null;
  actions: Action[];
  messages: ChatMessage[];
}

export type RoomResult<T> = { ok: true; value: T } | { ok: false; error: NetError | GameError };

const MAX_NAME = 24;
const MAX_CHAT = 500;
const MAX_MESSAGES = 200;

function netError(code: NetError['code'], message: string): RoomResult<never> {
  return { ok: false, error: { code, message } };
}

/** A snapshot as it may come back from storage (written before `updatedAt` existed). */
export type StoredRoomSnapshot = Omit<RoomSnapshot, 'updatedAt'> & { updatedAt?: number };

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
  /** Tail of the write chain per room code: writes for one room never interleave. */
  private readonly writes = new Map<string, Promise<void>>();

  constructor(options: RoomStoreOptions = {}) {
    this.seedFactory = options.seedFactory ?? (() => randomBytes(8).toString('hex'));
    this.now = options.now ?? (() => Date.now());
    this.codeFactory = options.codeFactory ?? randomRoomCode;
    this.persistence = options.persistence ?? null;
    this.idleMs = options.idleMs ?? DEFAULT_IDLE_MS;
    this.finishedMs = options.finishedMs ?? DEFAULT_FINISHED_MS;
    this.warn = options.warn ?? ((m) => console.warn(`[rooms] ${m}`));
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
    const player: RoomPlayer = { id: 'p1', name, color: PLAYER_COLORS[0] as PlayerColor, token: randomUUID(), socketId: null, connected: false };
    const now = this.now();
    const room: Room = {
      code,
      name: title,
      createdAt: now,
      updatedAt: now,
      hostId: player.id,
      players: [player],
      config: { turnTimerSeconds: null },
      started: false,
      seed: null,
      game: null,
      rng: null,
      actions: [],
      messages: [],
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
    const player: RoomPlayer = { id: `p${n}`, name, color, token: randomUUID(), socketId: null, connected: false };
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
    player.socketId = socketId;
    player.connected = true;
    this.mirrorConnected(room);
    room.updatedAt = this.now();
    return previous;
  }

  /** Detach a socket; returns the room/player it was bound to, if any. */
  unbindSocket(socketId: string): { room: Room; player: RoomPlayer } | null {
    for (const room of this.rooms.values()) {
      const player = room.players.find((p) => p.socketId === socketId);
      if (player) {
        player.socketId = null;
        player.connected = false;
        this.mirrorConnected(room);
        room.updatedAt = this.now();
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

  startGame(room: Room, byPlayerId: PlayerId): RoomResult<Room> {
    if (room.hostId !== byPlayerId) return netError('notHost', 'Only the host can start the game');
    if (room.started) return netError('alreadyStarted', 'The game has already started');
    if (room.players.length < ROOM_MIN_PLAYERS) return netError('tooFewPlayers', `Need ${ROOM_MIN_PLAYERS}–${ROOM_MAX_PLAYERS} players, have ${room.players.length}`);
    const seed = this.seedFactory();
    const game = createBeginnerGame({
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
    room.rng = createRng(rngSeed);
    room.started = true;
    room.actions = [];
    this.mirrorConnected(room);
    this.changed(room);
    return room;
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
    };
  }

  snapshot(room: Room): RoomSnapshot {
    return {
      code: room.code,
      name: room.name,
      createdAt: room.createdAt,
      updatedAt: room.updatedAt,
      hostId: room.hostId,
      players: room.players.map((p) => ({ ...p, socketId: null, connected: false })),
      config: { ...room.config },
      started: room.started,
      seed: room.seed,
      game: room.game,
      rngState: room.rng ? room.rng.getState() : null,
      actions: [...room.actions],
      messages: [...room.messages],
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
      players: snapshot.players.map((p) => ({ ...p, socketId: null, connected: false })),
      config: { ...snapshot.config },
      started: snapshot.started,
      seed: snapshot.seed,
      game: snapshot.game,
      rng: snapshot.rngState ? rngFromState(snapshot.rngState) : null,
      actions: [...snapshot.actions],
      messages: [...snapshot.messages],
    };
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
