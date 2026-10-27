/**
 * Remote game store (HANDOFF §7.5): the same `GameStoreState` surface as the
 * hot-seat store, backed by a Socket.IO connection. `dispatch` sends the action
 * and returns true optimistically; a rejection arrives through the ack (and the
 * server's `error` event) and lands in `error`. The viewer is fixed to the
 * socket's player, so `pendingViewer` is always null and the curtain never
 * shows. Replay uses the redacted states received since joining; positions
 * before the join are asked from the server (`replay`), which re-runs the
 * engine and answers with this player's redacted view (HANDOFF §8.4).
 */

import type {
  ChatMessage,
  ClientToServerEvents,
  GameError,
  GameState,
  GameVariant,
  JoinReply,
  LobbyView,
  NetError,
  ServerToClientEvents,
  Session,
  SetupMode,
} from '@starfarers/shared';
import { createStore, type StoreApi } from 'zustand/vanilla';
import type { GameStoreState } from '../store/gameStore.js';
import { loadSession, saveSession, type SessionStorageLike } from './session.js';

/** Server-replayed states kept per store (most recently used last). */
export const REPLAY_CACHE_SIZE = 50;

type AckOf<E extends keyof ClientToServerEvents> = Parameters<Parameters<ClientToServerEvents[E]>[1]>[0];

/** The slice of a socket.io-client `Socket` the store uses; tests pass a fake. */
export interface SocketLike {
  connected: boolean;
  connect(): void;
  disconnect(): void;
  emit<E extends keyof ClientToServerEvents>(event: E, payload: Parameters<ClientToServerEvents[E]>[0], ack: (reply: AckOf<E>) => void): void;
  on<E extends keyof ServerToClientEvents>(event: E, handler: ServerToClientEvents[E]): void;
  on(event: 'connect' | 'disconnect', handler: () => void): void;
  off(event: string): void;
}

export type Connection = 'idle' | 'connecting' | 'connected' | 'disconnected';

export type NetResult<T> = { ok: true; value: T } | { ok: false; error: NetError | GameError };

export interface RemoteStoreState extends GameStoreState {
  connection: Connection;
  session: Session | null;
  lobby: LobbyView | null;
  chat: ChatMessage[];
  /** Last room-level failure (join refused, connection lost…), separate from engine `error`. */
  netError: string | null;
  /** Redacted states received since joining; `replayState(k)` indexes these. */
  snapshots: GameState[];
  /** Number of accepted actions that happened before the first snapshot (resumed games). */
  snapshotBase: number;
  /** Lowest replayable index: 0 when the server sent the initial state (or we saw the start), else `snapshotBase`. */
  replayMin: number;
  /** Bumped whenever a server-replayed state lands in the cache. */
  replayVersion: number;
  /** Ask the server for the state after `k` actions unless it is known locally; one request per index. */
  ensureReplay(k: number): Promise<void>;

  connect(): void;
  createRoom(roomName: string, playerName: string): Promise<NetResult<JoinReply>>;
  joinRoom(code: string, playerName: string): Promise<NetResult<JoinReply>>;
  resume(session?: Session | null): Promise<NetResult<JoinReply>>;
  /** Host only, before the start: pick the board set-up (spec §3.2) and/or the start mode (§3.3 / §3.4). */
  configureRoom(patch: { variant?: GameVariant; setup?: SetupMode }): Promise<NetResult<{ configured: true }>>;
  startGame(): Promise<NetResult<{ started: true }>>;
  sendChat(text: string): Promise<NetResult<{ sent: true }>>;
  /** Forget the session and return to the lobby screens. */
  leaveRoom(): void;
}

export type RemoteStore = StoreApi<RemoteStoreState>;

export interface RemoteStoreOptions {
  storage?: SessionStorageLike | null;
}

export function createRemoteGameStore(socket: SocketLike, options: RemoteStoreOptions = {}): RemoteStore {
  const storage = options.storage === undefined ? undefined : options.storage;
  const persist = (session: Session | null) => (storage === undefined ? saveSession(session) : saveSession(session, storage));
  const load = () => (storage === undefined ? loadSession() : loadSession(storage));

  const store = createStore<RemoteStoreState>()((set, get) => {
    const emit = <E extends keyof ClientToServerEvents>(event: E, payload: Parameters<ClientToServerEvents[E]>[0]) =>
      new Promise<AckOf<E>>((resolve) => {
        socket.emit(event, payload, resolve);
      });

    /** States before `snapshotBase`, fetched with `replay`; cleared on every join / leave. */
    const replays = new Map<number, GameState>();
    const inflight = new Map<number, Promise<void>>();
    let replayGeneration = 0;
    const resetReplays = () => {
      replays.clear();
      inflight.clear();
      replayGeneration++;
    };

    const applyJoin = (reply: JoinReply) => {
      persist(reply.session);
      resetReplays();
      const serverInitial = reply.initial ?? null;
      set({
        session: reply.session,
        lobby: reply.lobby,
        chat: reply.lobby.messages,
        viewer: reply.session.playerId,
        pendingViewer: null,
        game: reply.state,
        initial: serverInitial ?? reply.state,
        actions: reply.actions,
        snapshots: reply.state ? [reply.state] : [],
        snapshotBase: reply.actions.length,
        replayMin: serverInitial || reply.actions.length === 0 ? 0 : reply.actions.length,
        error: null,
        netError: null,
        replayIndex: null,
        selectedShip: null,
        nodePick: null,
      });
    };

    const joinCall = async <E extends 'createRoom' | 'joinRoom' | 'resume'>(event: E, payload: Parameters<ClientToServerEvents[E]>[0]): Promise<NetResult<JoinReply>> => {
      if (!socket.connected) get().connect();
      const reply = (await emit(event, payload)) as NetResult<JoinReply>;
      if (reply.ok) applyJoin(reply.value);
      else set({ netError: reply.error.message });
      return reply;
    };

    socket.on('connect', () => set({ connection: 'connected', netError: null }));
    socket.on('disconnect', () => set({ connection: 'disconnected' }));
    socket.on('lobby', (lobby) => set({ lobby, chat: lobby.messages }));
    socket.on('chat', (message) => set({ chat: [...get().chat, message] }));
    socket.on('error', (error) => {
      if ('kind' in error) set({ error });
      else set({ netError: error.message });
    });
    socket.on('state', ({ state, action }) => {
      const { actions, snapshots } = get();
      set({
        game: state,
        initial: get().initial ?? state,
        actions: action ? [...actions, action] : actions,
        // A state without an action (someone (re)connected) replaces the latest snapshot so indexes stay aligned with `actions`.
        snapshots: action || snapshots.length === 0 ? [...snapshots, state] : [...snapshots.slice(0, -1), state],
        error: null,
        selectedShip: null,
        nodePick: null,
        replayIndex: null,
      });
    });

    return {
      mode: 'remote',
      setup: null,
      initial: null,
      game: null,
      actions: [],
      rngSeed: '',
      error: null,
      viewer: null,
      pendingViewer: null,
      selectedShip: null,
      nodePick: null,
      replayIndex: null,
      connection: 'idle',
      session: load(),
      lobby: null,
      chat: [],
      netError: null,
      snapshots: [],
      snapshotBase: 0,
      replayMin: 0,
      replayVersion: 0,

      newGame() {
        throw new Error('newGame is a hot-seat action; online games start from the lobby');
      },
      loadGame() {
        throw new Error('loadGame is a hot-seat action');
      },

      dispatch(action) {
        const { session } = get();
        if (!session) return false;
        void emit('action', { action }).then((reply) => {
          if (!reply.ok) set({ error: 'kind' in reply.error ? reply.error : { kind: 'error', code: 'invalidAction', message: reply.error.message } });
        });
        return true;
      },

      acknowledgeViewer() {
        /* the seat never changes online */
      },
      takeSeat() {
        /* the seat never changes online */
      },
      selectShip(shipId) {
        set({ selectedShip: shipId, nodePick: null });
      },
      setNodePick(pick) {
        set({ nodePick: pick, selectedShip: null });
      },
      clearError() {
        set({ error: null, netError: null });
      },
      setReplayIndex(index) {
        set({ replayIndex: index, selectedShip: null, nodePick: null });
      },
      replayState(k) {
        const { snapshots, snapshotBase, game, actions, initial, replayMin } = get();
        const target = Math.max(0, Math.min(k, actions.length));
        if (snapshots.length > 0 && target >= snapshotBase) return snapshots[Math.min(target - snapshotBase, snapshots.length - 1)] ?? (game as GameState);
        if (target === 0 && replayMin === 0 && initial) return initial;
        const hit = replays.get(target);
        if (hit) return hit;
        // Not fetched yet (ensureReplay is on its way): show the nearest known position meanwhile.
        const known: [number, GameState | null | undefined][] = [[0, replayMin === 0 ? initial : null], ...replays, [snapshotBase, snapshots[0]]];
        let best: GameState | null = null;
        let distance = Infinity;
        for (const [index, state] of known) {
          if (state && Math.abs(index - target) < distance) {
            best = state;
            distance = Math.abs(index - target);
          }
        }
        return best ?? (game as GameState);
      },
      ensureReplay(k) {
        const { snapshots, snapshotBase, game, actions, initial, replayMin, session } = get();
        const target = Math.max(0, Math.min(k, actions.length));
        if (!session || !game || target < replayMin) return Promise.resolve();
        if (snapshots.length > 0 && target >= snapshotBase) return Promise.resolve();
        if (target === 0 && initial) return Promise.resolve();
        const hit = replays.get(target);
        if (hit) {
          replays.delete(target);
          replays.set(target, hit);
          return Promise.resolve();
        }
        const pending = inflight.get(target);
        if (pending) return pending;
        const generation = replayGeneration;
        const request = emit('replay', { index: target }).then((reply) => {
          if (generation !== replayGeneration) return;
          inflight.delete(target);
          if (!reply.ok) {
            set({ netError: reply.error.message });
            return;
          }
          replays.set(target, reply.value);
          while (replays.size > REPLAY_CACHE_SIZE) {
            const oldest = replays.keys().next().value;
            if (oldest === undefined) break;
            replays.delete(oldest);
          }
          set({ replayVersion: get().replayVersion + 1 });
        });
        inflight.set(target, request);
        return request;
      },

      connect() {
        if (get().connection === 'idle' || get().connection === 'disconnected') {
          set({ connection: 'connecting' });
          socket.connect();
        }
      },
      createRoom(roomName, playerName) {
        return joinCall('createRoom', { roomName, playerName });
      },
      joinRoom(code, playerName) {
        return joinCall('joinRoom', { code, playerName });
      },
      resume(session) {
        const s = session ?? get().session;
        if (!s) return Promise.resolve({ ok: false, error: { code: 'badToken', message: 'No saved session' } });
        return joinCall('resume', { roomCode: s.roomCode, playerToken: s.playerToken });
      },
      async configureRoom(patch) {
        const reply = await emit('configureRoom', patch);
        if (!reply.ok) set({ netError: reply.error.message });
        return reply;
      },
      async startGame() {
        const reply = await emit('startGame', {});
        if (!reply.ok) set({ netError: reply.error.message });
        return reply;
      },
      async sendChat(text) {
        const reply = await emit('chat', { text });
        if (!reply.ok) set({ netError: reply.error.message });
        return reply;
      },
      leaveRoom() {
        persist(null);
        resetReplays();
        set({ session: null, lobby: null, chat: [], game: null, initial: null, actions: [], snapshots: [], snapshotBase: 0, replayMin: 0, viewer: null, error: null, netError: null });
        socket.disconnect();
        set({ connection: 'idle' });
      },
    };
  });

  return store;
}
