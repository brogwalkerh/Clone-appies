/**
 * Socket.IO protocol between `server/` and `client/` (spec §13). Types only —
 * no I/O here. Every client → server event takes an acknowledgement callback
 * so the sender learns about rejection without a broadcast.
 */

import type { Action, GameError, GameState, GameVariant, PlayerColor, PlayerId, SetupMode } from '../types.js';

export interface LobbyPlayer {
  id: PlayerId;
  name: string;
  color: PlayerColor;
  connected: boolean;
  isHost: boolean;
}

export interface ChatMessage {
  from: PlayerId;
  name: string;
  text: string;
  /** Unix ms. */
  at: number;
}

export interface RoomConfig {
  /** Seconds per turn; `null` = no timer (default). Config only in phase 5, not enforced. */
  turnTimerSeconds: number | null;
  /** Set-up used when the host starts (spec §3.2); default 'beginner'. Host-only, via `configureRoom`. */
  variant: GameVariant;
  /** Starting pieces (spec §3.3 preset / §3.4 draft); default 'preset'. Host-only, via `configureRoom`. */
  setup: SetupMode;
}

/** What every member sees about the room, before and during the game. */
export interface LobbyView {
  code: string;
  name: string;
  players: LobbyPlayer[];
  hostId: PlayerId;
  started: boolean;
  config: RoomConfig;
  messages: ChatMessage[];
  minPlayers: number;
  maxPlayers: number;
}

export interface Session {
  roomCode: string;
  playerToken: string;
  playerId: PlayerId;
}

export interface NetError {
  code: 'badRequest' | 'noSuchRoom' | 'roomFull' | 'alreadyStarted' | 'notStarted' | 'notHost' | 'badToken' | 'nameTaken' | 'notInRoom' | 'tooFewPlayers';
  message: string;
}

export type Ack<T> = (reply: { ok: true; value: T } | { ok: false; error: NetError | GameError }) => void;

/** Reply to createRoom / joinRoom / resume: who you are, the lobby, and the game if started. */
export interface JoinReply {
  session: Session;
  lobby: LobbyView;
  state: GameState | null;
  /** Accepted actions so far (redacted), for the client's replay slider. */
  actions: Action[];
  /**
   * The state the game started from, redacted for this player; `null` before
   * the start or for a room stored before replay existed. With it and the
   * `replay` query a resumed client can scrub back to the first turn.
   */
  initial: GameState | null;
}

export interface ClientToServerEvents {
  createRoom(payload: { roomName: string; playerName: string }, ack: Ack<JoinReply>): void;
  joinRoom(payload: { code: string; playerName: string }, ack: Ack<JoinReply>): void;
  resume(payload: { roomCode: string; playerToken: string }, ack: Ack<JoinReply>): void;
  /** Host only, before the start: change the room's set-up (board variant and/or start mode); the room then gets a fresh `lobby`. */
  configureRoom(payload: { variant?: GameVariant; setup?: SetupMode }, ack: Ack<{ configured: true }>): void;
  startGame(payload: Record<string, never>, ack: Ack<{ started: true }>): void;
  action(payload: { action: Action }, ack: Ack<{ accepted: true }>): void;
  /** State after the first `index` accepted actions (0 = initial), replayed on the server and redacted for the asker. */
  replay(payload: { index: number }, ack: Ack<GameState>): void;
  chat(payload: { text: string }, ack: Ack<{ sent: true }>): void;
}

export interface ServerToClientEvents {
  lobby(view: LobbyView): void;
  /** Redacted for this socket's player; `action` is the accepted action that produced it (redacted too). */
  state(payload: { state: GameState; action: Action | null }): void;
  /** Sent to the offending socket only. */
  error(error: NetError | GameError): void;
  chat(message: ChatMessage): void;
}

export const ROOM_MIN_PLAYERS = 3;
export const ROOM_MAX_PLAYERS = 4;
export const ROOM_CODE_LENGTH = 6;
/** No 0/O/1/I so codes survive being read aloud. */
export const ROOM_CODE_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
