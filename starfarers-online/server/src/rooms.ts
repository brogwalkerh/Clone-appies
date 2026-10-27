/**
 * In-memory room store (spec §13, HANDOFF §7). No sockets in here: every
 * method is a plain function over `Room` so it can be unit-tested directly and
 * swapped for a persistent store later (`snapshot()` is the serialisable form).
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

/** Serialisable form of a room (for a future persistent store). */
export interface RoomSnapshot {
  code: string;
  name: string;
  createdAt: number;
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

export interface RoomStoreOptions {
  /** Seed for a new game; defaults to 16 random hex chars. Tests inject a fixed one. */
  seedFactory?: () => string;
  now?: () => number;
  codeFactory?: () => string;
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

  constructor(options: RoomStoreOptions = {}) {
    this.seedFactory = options.seedFactory ?? (() => randomBytes(8).toString('hex'));
    this.now = options.now ?? (() => Date.now());
    this.codeFactory = options.codeFactory ?? randomRoomCode;
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
    const room: Room = {
      code,
      name: title,
      createdAt: this.now(),
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
    return { ok: true, value: result.value };
  }

  addChat(room: Room, player: RoomPlayer, text: unknown): RoomResult<ChatMessage> {
    if (typeof text !== 'string' || text.trim().length === 0) return netError('badRequest', 'Empty message');
    const message: ChatMessage = { from: player.id, name: player.name, text: text.trim().slice(0, MAX_CHAT), at: this.now() };
    room.messages.push(message);
    if (room.messages.length > MAX_MESSAGES) room.messages.splice(0, room.messages.length - MAX_MESSAGES);
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

  restore(snapshot: RoomSnapshot): Room {
    const room: Room = {
      code: snapshot.code,
      name: snapshot.name,
      createdAt: snapshot.createdAt,
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
    this.rooms.set(room.code, room);
    return room;
  }

  deleteRoom(code: string): boolean {
    return this.rooms.delete(normalizeCode(code));
  }
}
