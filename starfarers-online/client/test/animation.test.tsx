/**
 * Board animations (spec §14, HANDOFF §8.1). Animation is presentation only:
 * glyphs are always drawn where the state puts them and a slide is a
 * temporary transform that ends at the identity; replay and reduced motion
 * never animate.
 */

import type { Action, ClientToServerEvents, GameState, JoinReply, LobbyView, ServerToClientEvents } from '@starfarers/shared';
import { createGame, redactState } from '@starfarers/shared';
import { act, render, screen } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { GameScreen } from '../src/App.js';
import { Board } from '../src/board/Board.js';
import { legalMoves } from '../src/board/legalMoves.js';
import { FLIP_MS, SHIP_START_DELAY_MS, SHIP_STEP_MS, type BoardMotion } from '../src/board/motion.js';
import { VpTrack } from '../src/board/VpTrack.js';
import { createRemoteGameStore, type SocketLike } from '../src/net/remoteStore.js';
import { StoreContext, createGameStore, type GameStore } from '../src/store/gameStore.js';
import { PLAYERS, game, inFlight, setup, shipsOfActive } from './fixtures.js';

function mockReducedMotion(reduced: boolean) {
  Object.defineProperty(window, 'matchMedia', {
    configurable: true,
    writable: true,
    value: (query: string) => ({
      matches: reduced && query.includes('prefers-reduced-motion'),
      media: query,
      addEventListener() {},
      removeEventListener() {},
    }),
  });
}

beforeEach(() => {
  vi.useFakeTimers();
  mockReducedMotion(false);
});
afterEach(() => {
  vi.useRealTimers();
  delete (window as { matchMedia?: unknown }).matchMedia;
});

/** A hot-seat store in flight.move with the longest legal move of the first ship. */
function flightStore() {
  const store = createGameStore();
  store.getState().loadGame(setup('anim'), inFlight(game('anim'), 3));
  const g = store.getState().game!;
  const shipId = shipsOfActive(g)[0]!;
  const from = g.board.ships[shipId]!.nodeId;
  const [target, path] = [...legalMoves(g, shipId).entries()].sort((a, b) => b[1].length - a[1].length)[0]!;
  const move: Action = { type: 'moveShip', playerId: g.activePlayer, shipId, path };
  return { store, shipId, from, target, path, move };
}

function renderScreen(store: GameStore) {
  return render(
    <StoreContext.Provider value={store}>
      <GameScreen />
    </StoreContext.Provider>,
  );
}

/** Centre of a node's dot as drawn on the board. */
function nodeCentre(nodeId: string): { x: number; y: number } {
  const circles = screen.getByTestId(`node-${nodeId}`).querySelectorAll('circle');
  const dot = circles[circles.length - 1]!;
  return { x: Number(dot.getAttribute('cx')), y: Number(dot.getAttribute('cy')) };
}

/** Where the ship glyph is drawn, without its animation transform. */
function shipDrawnAt(shipId: string): { x: number; y: number } {
  const g = screen.getByTestId(`ship-${shipId}`);
  const poly = g.querySelector('polygon');
  if (poly) {
    const [apex, right] = (poly.getAttribute('points') ?? '').split(' ').map((p) => p.split(',').map(Number));
    return { x: apex![0]!, y: right![1]! - 8 };
  }
  const rect = g.querySelector('rect')!;
  return { x: Number(rect.getAttribute('x')) + 10, y: Number(rect.getAttribute('y')) + 7 };
}

function shipTransform(shipId: string): string {
  return (screen.getByTestId(`ship-${shipId}`).querySelector('.ship-motion') as SVGGElement).style.transform;
}

const totalSlideMs = (steps: number) => SHIP_START_DELAY_MS + steps * SHIP_STEP_MS + 1;

describe('ship slide along the moveShip path', () => {
  it('starts at the old node, steps through the path and ends with no transform at the state node', () => {
    const { store, shipId, from, target, path, move } = flightStore();
    renderScreen(store);
    expect(shipTransform(shipId)).toBe('');

    act(() => {
      expect(store.getState().dispatch(move)).toBe(true);
    });
    // Drawn at the state's node from the first frame; the transform offsets it back to the start.
    expect(screen.getByTestId(`ship-${shipId}`)).toHaveAttribute('data-node', target);
    expect(shipDrawnAt(shipId)).toEqual(nodeCentre(target));
    expect(screen.getByTestId(`ship-${shipId}`)).toHaveAttribute('data-moving', 'true');
    const a = nodeCentre(from);
    const b = nodeCentre(target);
    expect(shipTransform(shipId)).toBe(`translate(${(a.x - b.x).toFixed(1)}px, ${(a.y - b.y).toFixed(1)}px)`);

    // After the first step the ship is offset to the first path node.
    act(() => void vi.advanceTimersByTime(SHIP_START_DELAY_MS + 1));
    const first = nodeCentre(path[0]!);
    expect(shipTransform(shipId)).toBe(`translate(${(first.x - b.x).toFixed(1)}px, ${(first.y - b.y).toFixed(1)}px)`);

    act(() => void vi.advanceTimersByTime(totalSlideMs(path.length)));
    expect(shipTransform(shipId)).toBe('');
    expect(screen.getByTestId(`ship-${shipId}`)).not.toHaveAttribute('data-moving');
    expect(shipDrawnAt(shipId)).toEqual(nodeCentre(target));
    expect(store.getState().game!.board.ships[shipId]!.nodeId).toBe(target);
  });

  it('animates the action attached to a remote state broadcast', async () => {
    const { store: local, shipId, from, target, move } = flightStore();
    const before = local.getState().game!;
    local.getState().dispatch(move);
    const after = local.getState().game!;

    const socket = new FakeSocket();
    const remote = createRemoteGameStore(socket, { storage: null });
    socket.replies.set('joinRoom', { ok: true, value: joinReply(before) });
    await act(async () => {
      const p = remote.getState().joinRoom('ABC234', 'Bob');
      await vi.runAllTimersAsync();
      await p;
    });
    renderScreen(remote as unknown as GameStore);
    expect(screen.getByTestId(`ship-${shipId}`)).toHaveAttribute('data-node', from);

    act(() => socket.fire('state', { state: redactState(after, 'p2'), action: move }));
    expect(screen.getByTestId(`ship-${shipId}`)).toHaveAttribute('data-node', target);
    expect(shipTransform(shipId)).not.toBe('');
    act(() => void vi.advanceTimersByTime(totalSlideMs(move.type === 'moveShip' ? move.path.length : 0)));
    expect(shipTransform(shipId)).toBe('');
    expect(shipDrawnAt(shipId)).toEqual(nodeCentre(target));

    // A reconnect broadcast (no action) does not animate.
    act(() => socket.fire('state', { state: redactState(after, 'p2') }));
    expect(shipTransform(shipId)).toBe('');
  });
});

describe('replay stays instant', () => {
  it('scrubbing back and returning to live never transforms a ship or slides the VP markers', () => {
    const { store, shipId, from, target, move } = flightStore();
    renderScreen(store);
    act(() => void store.getState().dispatch(move));
    act(() => void vi.runAllTimers());
    expect(shipTransform(shipId)).toBe('');

    act(() => store.getState().setReplayIndex(0));
    expect(screen.getByTestId(`ship-${shipId}`)).toHaveAttribute('data-node', from);
    expect(shipTransform(shipId)).toBe('');
    expect(screen.getByTestId('vp-track')).not.toHaveClass('animate');

    act(() => store.getState().setReplayIndex(null));
    expect(screen.getByTestId(`ship-${shipId}`)).toHaveAttribute('data-node', target);
    expect(shipTransform(shipId)).toBe('');
    expect(screen.getByTestId('vp-track')).not.toHaveClass('animate');
  });

  it('a move dispatched mid-slide while switching to replay stops the slide at once', () => {
    const { store, shipId, move } = flightStore();
    renderScreen(store);
    act(() => void store.getState().dispatch(move));
    expect(shipTransform(shipId)).not.toBe('');
    act(() => store.getState().setReplayIndex(0));
    expect(shipTransform(shipId)).toBe('');
    act(() => store.getState().setReplayIndex(null));
    expect(shipTransform(shipId)).toBe('');
  });
});

describe('prefers-reduced-motion', () => {
  it('skips the slide entirely: the ship is at the state node with no transform', () => {
    mockReducedMotion(true);
    const { store, shipId, target, move } = flightStore();
    renderScreen(store);
    act(() => void store.getState().dispatch(move));
    expect(screen.getByTestId(`ship-${shipId}`)).toHaveAttribute('data-node', target);
    expect(screen.getByTestId(`ship-${shipId}`)).not.toHaveAttribute('data-moving');
    expect(shipTransform(shipId)).toBe('');
    expect(screen.getByTestId('vp-track')).not.toHaveClass('animate');
  });
});

describe('VP marker', () => {
  it('is positioned from the state and slides only after a live action', () => {
    const s = game();
    const motion0: BoardMotion = { seq: 0, action: null, animate: true };
    const { rerender } = render(<VpTrack state={s} motion={motion0} />);
    for (const p of s.players) expect(screen.getByTestId(`vp-marker-${p.id}`)).toHaveAttribute('data-vp', String(p.vp));
    expect(screen.getByTestId('vp-track')).not.toHaveClass('animate');

    const next = structuredClone(s);
    next.players[0]!.vp += 2;
    const roll: Action = { type: 'rollDice', playerId: s.activePlayer };
    rerender(<VpTrack state={next} motion={{ seq: 1, action: roll, animate: true }} />);
    expect(screen.getByTestId('vp-track')).toHaveClass('animate');
    const marker = screen.getByTestId(`vp-marker-${next.players[0]!.id}`);
    expect(marker).toHaveAttribute('data-vp', String(next.players[0]!.vp));
    expect(marker.style.transform).toContain(`calc(${next.players[0]!.vp} * (100% + 3px)`);

    // Replay: no transition; back to live with the same seq: still none.
    rerender(<VpTrack state={s} motion={{ seq: 1, action: roll, animate: false }} />);
    expect(screen.getByTestId('vp-track')).not.toHaveClass('animate');
    rerender(<VpTrack state={next} motion={{ seq: 1, action: roll, animate: true }} />);
    expect(screen.getByTestId('vp-track')).not.toHaveClass('animate');
  });
});

describe('tile and disc flips', () => {
  const noop = () => {};
  const board = (state: GameState, motion: BoardMotion) => (
    <Board state={state} viewer={null} highlights={new Map()} selectedShip={null} onNodeClick={noop} onShipClick={noop} motion={motion} />
  );
  const roll = (s: GameState): Action => ({ type: 'rollDice', playerId: s.activePlayer });

  it('flips a discovered tile (hidden-<slot> → sector) and clears afterwards', () => {
    const s = createGame({ variant: 'explorer', players: PLAYERS, seed: 'anim-flip' });
    const hidden = Object.values(s.board.sectors).find((x) => !x.discovered && x.kind === 'system')!;
    expect(hidden).toBeDefined();
    const { rerender } = render(board(s, { seq: 0, action: null, animate: true }));
    expect(screen.getByTestId(`hidden-${hidden.id}`)).toBeInTheDocument();

    const next = structuredClone(s);
    next.board.sectors[hidden.id]!.discovered = true;
    rerender(board(next, { seq: 1, action: roll(s), animate: true }));
    expect(screen.queryByTestId(`hidden-${hidden.id}`)).toBeNull();
    expect(screen.getByTestId(`sector-${hidden.id}`)).toHaveClass('flip');
    act(() => void vi.advanceTimersByTime(FLIP_MS + 1));
    expect(screen.getByTestId(`sector-${hidden.id}`)).not.toHaveClass('flip');
  });

  it('flips a disc on exploration, but not in replay or with reduced motion', () => {
    const s = game();
    const planet = Object.values(s.board.planets).find((p) => p.disc && !p.disc.faceUp && !p.token)!;
    expect(planet).toBeDefined();
    const next = structuredClone(s);
    next.board.planets[planet.id]!.disc!.faceUp = true;

    const { rerender, unmount } = render(board(s, { seq: 0, action: null, animate: true }));
    rerender(board(next, { seq: 1, action: roll(s), animate: true }));
    expect(screen.getByTestId(`disc-${planet.id}`)).toHaveClass('flip');
    unmount();

    // Replay (animate false): the same change shows instantly.
    const r2 = render(board(s, { seq: 0, action: null, animate: false }));
    r2.rerender(board(next, { seq: 0, action: null, animate: false }));
    expect(screen.getByTestId(`disc-${planet.id}`)).not.toHaveClass('flip');
    r2.unmount();

    // Reduced motion through the whole screen path is covered above; the Board itself short-circuits on animate=false.
    mockReducedMotion(true);
    const r3 = render(board(s, { seq: 0, action: null, animate: false }));
    r3.rerender(board(next, { seq: 1, action: roll(s), animate: false }));
    expect(screen.getByTestId(`disc-${planet.id}`)).not.toHaveClass('flip');
  });
});

/* ---- remote fixtures ---- */

class FakeSocket implements SocketLike {
  connected = false;
  handlers = new Map<string, ((...args: never[]) => void)[]>();
  replies = new Map<string, unknown>();
  connect() {
    this.connected = true;
    this.fire('connect');
  }
  disconnect() {
    this.connected = false;
  }
  emit<E extends keyof ClientToServerEvents>(event: E, _payload: Parameters<ClientToServerEvents[E]>[0], ack: (reply: never) => void): void {
    const reply = this.replies.get(event) ?? { ok: true, value: { accepted: true } };
    queueMicrotask(() => ack(reply as never));
  }
  on(event: string, handler: (...args: never[]) => void): void {
    this.handlers.set(event, [...(this.handlers.get(event) ?? []), handler]);
  }
  off(event: string): void {
    this.handlers.delete(event);
  }
  fire<E extends keyof ServerToClientEvents>(event: E | 'connect' | 'disconnect', ...args: unknown[]): void {
    for (const h of this.handlers.get(event) ?? []) (h as (...a: unknown[]) => void)(...args);
  }
}

function lobby(): LobbyView {
  return {
    code: 'ABC234',
    name: 'Test',
    players: PLAYERS.map((p, i) => ({ id: p.id, name: p.name, color: p.color, connected: true, isHost: i === 0 })),
    hostId: 'p1',
    started: true,
    config: { turnTimerSeconds: null, variant: 'beginner', setup: 'preset' },
    messages: [],
    minPlayers: 3,
    maxPlayers: 4,
  };
}

function joinReply(state: GameState): JoinReply {
  return { session: { roomCode: 'ABC234', playerToken: 'tok-2', playerId: 'p2' }, lobby: lobby(), state: redactState(state, 'p2'), actions: [], initial: null };
}
