/**
 * Hot-seat game store (HANDOFF §6.2). One browser tab is the only authority:
 * it owns the `GameState`, a single `Rng` created once per game from the seed
 * and reused across actions, and the accepted-action log used for replay.
 *
 * Viewer model: the "viewer" is the seat currently holding the laptop. After
 * every accepted action the store works out which seat must act next
 * (`requiredViewer`); when that differs from the current viewer, `pendingViewer`
 * is set and the UI shows a "pass the laptop" banner and hides hands until
 * `acknowledgeViewer()` is called.
 *
 * Replay: `actions` plus the initial state and the rng seed reproduce every
 * intermediate state deterministically (`replayState(k)`), so no snapshots are
 * kept.
 */

import {
  applyAction,
  createGame,
  createRng,
  rngFromState,
  type Action,
  type GameError,
  type GameState,
  type GameVariant,
  type NodeId,
  type PlayerId,
  type PlayerSpec,
  type Rng,
  type ShipId,
} from '@starfarers/shared';
import { createContext, useContext } from 'react';
import { useStore } from 'zustand';
import { createStore, type StoreApi } from 'zustand/vanilla';

export interface GameSetup {
  players: PlayerSpec[];
  seed: string;
  /** Set-up (spec §3.2); defaults to 'beginner'. */
  variant?: GameVariant | undefined;
}

/** A board-click request from a panel ("choose a spaceport site"), shown as highlighted nodes. */
export interface NodePick {
  label: string;
  candidates: NodeId[];
  onPick(nodeId: NodeId): void;
}

export interface GameStoreState {
  /** 'local' = hot-seat authority in this tab; 'remote' = a server owns the state (net/remoteStore.ts). */
  mode: 'local' | 'remote';
  setup: GameSetup | null;
  /** State the action log starts from (a fresh game, or a loaded one). */
  initial: GameState | null;
  /** Live state. */
  game: GameState | null;
  /** Accepted actions since `initial`, in order. */
  actions: Action[];
  /** Seed string the game's rng was created from (differs from `setup.seed` after `loadGame`). */
  rngSeed: string;
  error: GameError | null;
  viewer: PlayerId | null;
  pendingViewer: PlayerId | null;
  selectedShip: ShipId | null;
  nodePick: NodePick | null;
  /** `null` = live; `k` = show the state after `k` actions (read-only). */
  replayIndex: number | null;

  newGame(setup: GameSetup): void;
  /** Start from an arbitrary state (tests, resumed games). `actions` are assumed already applied. */
  loadGame(setup: GameSetup, state: GameState): void;
  /** Apply an action through the engine. Returns true when accepted; the error is kept in `error` otherwise. */
  dispatch(action: Action): boolean;
  acknowledgeViewer(): void;
  /** Hot-seat convenience: hand the laptop to any seat (e.g. so a non-active player can propose a trade). */
  takeSeat(playerId: PlayerId): void;
  selectShip(shipId: ShipId | null): void;
  setNodePick(pick: NodePick | null): void;
  clearError(): void;
  setReplayIndex(index: number | null): void;
  /** State after the first `k` accepted actions (0 = initial). */
  replayState(k: number): GameState;
  /** Lowest index the replay slider offers (remote store: the join point when the server sent no initial state). Absent = 0. */
  replayMin?: number;
  /** Bumped when a replay state arrives asynchronously (remote store), so `useShownState` re-renders. */
  replayVersion?: number;
  /** Fetch the state for `k` if `replayState(k)` cannot answer locally yet (remote store only). */
  ensureReplay?(k: number): Promise<void>;
}

export type GameStore = StoreApi<GameStoreState>;

/**
 * Who must hold the laptop for the game to continue. `current` wins ties
 * (several players discarding for a 7 may do so in any order).
 */
export function requiredViewer(state: GameState, current: PlayerId | null): PlayerId {
  if (state.phase === 'gameOver') return current ?? state.activePlayer;
  const awaiting = state.turn.encounter?.awaiting;
  if (state.phase === 'flight.encounter' && awaiting) return awaiting.playerId;
  const seven = state.turn.seven;
  if (state.phase === 'production' && seven && seven.awaitingDiscard.length > 0) {
    if (current && seven.awaitingDiscard.includes(current)) return current;
    return seven.awaitingDiscard[0] as PlayerId;
  }
  const trade = state.openTrade;
  if (state.phase === 'tradeBuild' && trade && trade.to !== 'supply') return trade.to;
  return state.activePlayer;
}

export function createGameStore(): GameStore {
  let rng: Rng | null = null;
  let replayCache: { k: number; state: GameState; rngState: [number, number, number, number] } | null = null;

  return createStore<GameStoreState>()((set, get) => {
    const begin = (setup: GameSetup, initial: GameState, rngSeed: string) => {
      rng = createRng(rngSeed);
      replayCache = null;
      set({
        setup,
        initial,
        game: initial,
        actions: [],
        rngSeed,
        error: null,
        viewer: initial.activePlayer,
        pendingViewer: null,
        selectedShip: null,
        nodePick: null,
        replayIndex: null,
      });
    };

    return {
      mode: 'local',
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

      newGame(setup) {
        begin(setup, createGame({ variant: setup.variant ?? 'beginner', players: setup.players, seed: setup.seed }), setup.seed);
      },

      loadGame(setup, state) {
        // A loaded state has consumed an unknown amount of the original stream; derive a fresh one.
        begin(setup, state, `${state.seed}:${state.turnNumber}:${state.log.length}`);
      },

      dispatch(action) {
        const { game, actions, viewer } = get();
        if (!game || !rng) return false;
        const result = applyAction(game, action, rng);
        if (!result.ok) {
          set({ error: result.error });
          return false;
        }
        const next = result.value;
        const needed = requiredViewer(next, viewer);
        set({
          game: next,
          actions: [...actions, action],
          error: null,
          selectedShip: null,
          nodePick: null,
          replayIndex: null,
          pendingViewer: needed !== viewer ? needed : null,
        });
        return true;
      },

      acknowledgeViewer() {
        const { pendingViewer } = get();
        if (pendingViewer) set({ viewer: pendingViewer, pendingViewer: null, selectedShip: null, nodePick: null });
      },

      takeSeat(playerId) {
        set({ viewer: playerId, pendingViewer: null, selectedShip: null, nodePick: null, error: null });
      },

      selectShip(shipId) {
        set({ selectedShip: shipId, nodePick: null });
      },

      setNodePick(pick) {
        set({ nodePick: pick, selectedShip: null });
      },

      clearError() {
        set({ error: null });
      },

      setReplayIndex(index) {
        set({ replayIndex: index, selectedShip: null, nodePick: null });
      },

      replayState(k) {
        const { initial, actions, rngSeed, game } = get();
        if (!initial) throw new Error('No game loaded');
        const target = Math.max(0, Math.min(k, actions.length));
        if (target === actions.length && game) return game;
        let state = initial;
        let r = createRng(rngSeed);
        let from = 0;
        if (replayCache && replayCache.k <= target) {
          state = replayCache.state;
          r = rngFromState(replayCache.rngState);
          from = replayCache.k;
        }
        for (let i = from; i < target; i++) {
          const res = applyAction(state, actions[i] as Action, r);
          if (!res.ok) throw new Error(`Replay diverged at action ${i}: ${res.error.message}`);
          state = res.value;
        }
        replayCache = { k: target, state, rngState: r.getState() };
        return state;
      },
    };
  });
}

/** The app-wide hot-seat store instance. Tests create their own with `createGameStore()`. */
export const gameStore = createGameStore();

/**
 * Which store the panels talk to. The hot-seat store is the default; the
 * online routes wrap the game screen in a provider holding the remote store,
 * so every panel works unchanged against either (HANDOFF §7.5).
 */
export const StoreContext = createContext<GameStore | null>(null);

export function useGameStore(): GameStore {
  return useContext(StoreContext) ?? gameStore;
}

export function useGame<T>(selector: (s: GameStoreState) => T): T {
  return useStore(useGameStore(), selector);
}

/** The state currently shown: the live game, or a replay snapshot. */
export function useShownState(): GameState | null {
  const game = useGame((s) => s.game);
  const replayIndex = useGame((s) => s.replayIndex);
  const replayState = useGame((s) => s.replayState);
  useGame((s) => s.replayVersion);
  if (replayIndex === null) return game;
  return replayState(replayIndex);
}

/** An action without its `playerId`, distributed over the union so each variant keeps its own fields. */
export type ActionInput = Action extends infer A ? (A extends Action ? Omit<A, 'playerId'> : never) : never;

/** Convenience: dispatch with the viewer's id filled in. */
export function useAct(): (action: ActionInput) => boolean {
  const viewer = useGame((s) => s.viewer);
  const dispatch = useGame((s) => s.dispatch);
  return (action) => {
    if (!viewer) return false;
    return dispatch({ ...action, playerId: viewer } as Action);
  };
}
