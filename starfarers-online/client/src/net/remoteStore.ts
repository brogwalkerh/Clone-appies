/**
 * Remote game store (HANDOFF §7.5): the same `GameStoreState` surface as the
 * hot-seat store, backed by a Socket.IO connection. `dispatch` sends the action
 * and returns true optimistically; a rejection arrives through the ack (and the
 * server's `error` event) and lands in `error`. The viewer is fixed to the
 * socket's player, so `pendingViewer` is always null and the curtain never
 * shows. Replay uses the redacted states received since joining.
 */

import type {
  ChatMessage,
  ClientToServerEvents,
  GameError,
  GameState,
  JoinReply,
  LobbyView,
  NetError,
  ServerToClientEvents,
  Session,
} from '@starfarers/shared';
import { createStore, type StoreApi } from 'zustand/vanilla';
import type { GameStoreState } from '../store/gameStore.js';
import { loadSession, saveSession, type SessionStorageLike } from './session.js';

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

  connect(): void;
  createRoom(roomName: string, playerName: string): Promise<NetResult<JoinReply>>;
  joinRoom(code: string, playerName: string): Promise<NetResult<JoinReply>>;
  resume(session?: Session | null): Promise<NetResult<JoinReply>>;
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

    const applyJoin = (reply: JoinReply) => {
      persist(reply.session);
      set({
        session: reply.session,
        lobby: reply.lobby,
        chat: reply.lobby.messages,
        viewer: reply.session.playerId,
        pendingViewer: null,
        game: reply.state,
        initial: reply.state,
        actions: reply.actions,
        snapshots: reply.state ? [reply.state] : [],
        snapshotBase: reply.actions.length,
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
        snapshots: [...snapshots, state],
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
        const { snapshots, snapshotBase, game } = get();
        const i = Math.max(0, Math.min(k - snapshotBase, snapshots.length - 1));
        return snapshots[i] ?? (game as GameState);
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
        set({ session: null, lobby: null, chat: [], game: null, initial: null, actions: [], snapshots: [], snapshotBase: 0, viewer: null, error: null, netError: null });
        socket.disconnect();
        set({ connection: 'idle' });
      },
    };
  });

  return store;
}
