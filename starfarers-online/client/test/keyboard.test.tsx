/**
 * Keyboard navigation and the §6 cosmetic gaps (HANDOFF §8.4): highlighted
 * board nodes and selectable ships are tab stops that act on Enter/Space like
 * a click, Escape closes only what may be closed, the replay slider moves with
 * the keys (still debounced), the join screen validates the room code, the
 * outpost label clears the dock row, and a pending free trade ship explains
 * the spaceport-site rule.
 */

import { createGame, freeOwnSpaceportSites, hexCenter, vertexPosition, type GameState, type Sector } from '@starfarers/shared';
import { act, cleanup, fireEvent, render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { GameScreen } from '../src/App.js';
import { SCALE } from '../src/board/Board.js';
import { legalMoves } from '../src/board/legalMoves.js';
import { DOCK_R, LABEL_FONT, outpostLayout } from '../src/board/outpostLayout.js';
import { createRemoteGameStore, type SocketLike } from '../src/net/remoteStore.js';
import { EncounterModal } from '../src/panels/EncounterModal.js';
import { LogPane, REPLAY_FETCH_DELAY_MS } from '../src/panels/LogPane.js';
import { MothershipPanel } from '../src/panels/MothershipPanel.js';
import { JoinScreen, normalizeRoomCode, roomCodeError } from '../src/panels/OnlineLobby.js';
import { SevenDialog } from '../src/panels/SevenDialog.js';
import { StoreContext, createGameStore, type GameStore } from '../src/store/gameStore.js';
import { PLAYERS, game, inFlight, setup, shipsOfActive } from './fixtures.js';

afterEach(() => {
  vi.useRealTimers();
});

function flightStore(seed = 'kbd') {
  const store = createGameStore();
  store.getState().loadGame(setup(seed), inFlight(game(seed), 3));
  const g = store.getState().game!;
  const shipId = shipsOfActive(g)[0]!;
  return { store, shipId };
}

function renderScreen(store: GameStore) {
  return render(
    <StoreContext.Provider value={store}>
      <GameScreen />
    </StoreContext.Provider>,
  );
}

async function tabUntil(user: ReturnType<typeof userEvent.setup>, pred: (el: Element) => boolean, shift = false, max = 400): Promise<Element> {
  for (let i = 0; i < max; i++) {
    await user.tab({ shift });
    const el = document.activeElement;
    if (el && pred(el)) return el;
  }
  throw new Error('never reached by Tab');
}

describe('board keyboard navigation', () => {
  it('puts only highlighted nodes in the tab order', () => {
    const { store, shipId } = flightStore();
    renderScreen(store);
    act(() => store.getState().selectShip(shipId));
    const nodes = [...document.querySelectorAll('[data-testid^="node-"]')];
    const highlighted = nodes.filter((n) => n.getAttribute('data-highlight') === 'true');
    expect(highlighted.length).toBe(legalMoves(store.getState().game!, shipId).size);
    expect(highlighted.length).toBeGreaterThan(0);
    for (const n of highlighted) {
      expect(n.getAttribute('tabindex')).toBe('0');
      expect(n.getAttribute('aria-label')).toMatch(/node|intersection|site|point/);
    }
    for (const n of nodes) if (n.getAttribute('data-highlight') !== 'true') expect(n.hasAttribute('tabindex')).toBe(false);
  });

  it('Tab reaches the own ship, Enter selects it, Tab reaches a highlighted node and Enter moves exactly like a click', async () => {
    const user = userEvent.setup();
    const a = flightStore();
    renderScreen(a.store);
    const ship = await tabUntil(user, (el) => el.getAttribute('data-testid') === `ship-${a.shipId}`);
    expect(ship.getAttribute('role')).toBe('button');
    await user.keyboard('{Enter}');
    expect(a.store.getState().selectedShip).toBe(a.shipId);
    // Highlighted nodes precede the ships in document order: Shift+Tab reaches them.
    const target = await tabUntil(user, (el) => el.getAttribute('data-highlight') === 'true', true);
    const nodeId = target.getAttribute('data-testid')!.slice('node-'.length);
    await user.keyboard('{Enter}');
    const viaKey = a.store.getState().actions;
    expect(viaKey).toHaveLength(1);
    expect(viaKey[0]!.type).toBe('moveShip');
    cleanup();

    // The same node clicked in a fresh, identical store.
    const b = flightStore();
    renderScreen(b.store);
    act(() => b.store.getState().selectShip(b.shipId));
    fireEvent.click(screen.getByTestId(`node-${nodeId}`));
    expect(b.store.getState().actions).toEqual(viaKey);
    expect(b.store.getState().game).toEqual(a.store.getState().game);
  });

  it('Space on a highlighted node acts too; non-own ships are not tab stops', async () => {
    const { store, shipId } = flightStore();
    renderScreen(store);
    act(() => store.getState().selectShip(shipId));
    const g = store.getState().game!;
    for (const ship of Object.values(g.board.ships)) {
      const el = screen.getByTestId(`ship-${ship.id}`);
      expect(el.hasAttribute('tabindex')).toBe(ship.owner === g.activePlayer);
    }
    const node = document.querySelector('[data-highlight="true"]') as SVGGElement;
    node.focus();
    fireEvent.keyDown(node, { key: ' ' });
    expect(store.getState().actions).toHaveLength(1);
    expect(store.getState().actions[0]!.type).toBe('moveShip');
  });

  it('Escape deselects the ship and cancels a build site pick', () => {
    const { store, shipId } = flightStore();
    renderScreen(store);
    act(() => store.getState().selectShip(shipId));
    fireEvent.keyDown(document.body, { key: 'Escape' });
    expect(store.getState().selectedShip).toBeNull();
    act(() => store.getState().setNodePick({ label: 'pick', candidates: [], onPick() {} }));
    fireEvent.keyDown(document.body, { key: 'Escape' });
    expect(store.getState().nodePick).toBeNull();
  });
});

describe('Escape on dialogs', () => {
  function doneEncounter(): GameState {
    const s = game();
    s.phase = 'flight.move';
    s.turn.encounter = { cardId: 1, stage: 'done', revealed: ['A ship hails you.'], queue: [] };
    return s;
  }

  it('closes the resolved encounter (optional "Continue") and moves focus into it on open', () => {
    const s = doneEncounter();
    const store = createGameStore();
    store.getState().loadGame(setup(), s);
    render(
      <StoreContext.Provider value={store}>
        <EncounterModal state={s} viewer={s.activePlayer} />
      </StoreContext.Provider>,
    );
    expect(document.activeElement).toBe(screen.getByTestId('encounter-continue'));
    fireEvent.keyDown(document.body, { key: 'Escape' });
    expect(screen.queryByTestId('encounter-modal')).not.toBeInTheDocument();
  });

  it('does not dismiss an awaited encounter pick', () => {
    const s = game();
    s.phase = 'flight.encounter';
    s.turn.encounter = {
      cardId: 1,
      stage: 'resolving',
      revealed: ['A ship hails you.'],
      queue: [],
      awaiting: { kind: 'upgradeKind', playerId: s.activePlayer, options: ['booster'], effect: { type: 'gainResource', resource: 'any', count: 1 } },
    };
    const store = createGameStore();
    store.getState().loadGame(setup(), s);
    render(
      <StoreContext.Provider value={store}>
        <EncounterModal state={s} viewer={s.activePlayer} />
      </StoreContext.Provider>,
    );
    fireEvent.keyDown(document.body, { key: 'Escape' });
    expect(screen.getByTestId('encounter-modal')).toBeInTheDocument();
    expect(screen.getByTestId('pick-option-booster')).toBeInTheDocument();
    expect(store.getState().actions).toHaveLength(0);
  });

  it('does not dismiss a pending 7 discard', () => {
    const s = game();
    s.phase = 'production';
    s.turn.rolled = 7;
    const me = s.players[0]!;
    me.hand = ['ore', 'ore', 'ore', 'fuel', 'fuel', 'fuel', 'food', 'food'];
    s.turn.seven = { awaitingDiscard: [me.id], stealDone: false } as GameState['turn']['seven'] & object;
    const store = createGameStore();
    store.getState().loadGame(setup(), s);
    render(
      <StoreContext.Provider value={store}>
        <SevenDialog state={s} viewer={me.id} />
      </StoreContext.Provider>,
    );
    expect(screen.getByTestId('seven-dialog').contains(document.activeElement)).toBe(true);
    fireEvent.keyDown(document.body, { key: 'Escape' });
    expect(screen.getByTestId('seven-dialog')).toBeInTheDocument();
    expect(screen.getByTestId('discard-confirm')).toBeDisabled();
  });
});

describe('replay slider keys', () => {
  function playedStore() {
    const { store, shipId } = flightStore('slider');
    const g = store.getState().game!;
    const moves = [...legalMoves(g, shipId).values()];
    store.getState().dispatch({ type: 'moveShip', playerId: g.activePlayer, shipId, path: moves[0]! });
    store.getState().dispatch({ type: 'endTurn', playerId: g.activePlayer });
    return store;
  }

  it('arrows step, Home/End jump, and the remote fetch is still debounced', () => {
    vi.useFakeTimers();
    const store = playedStore();
    const n = store.getState().actions.length;
    expect(n).toBeGreaterThanOrEqual(2);
    const ensureReplay = vi.fn(async () => {});
    store.setState({ ensureReplay });
    render(
      <StoreContext.Provider value={store}>
        <LogPane state={store.getState().game!} />
      </StoreContext.Provider>,
    );
    const slider = screen.getByTestId('replay-slider');
    expect(slider.tabIndex).toBe(0);
    slider.focus();
    fireEvent.keyDown(slider, { key: 'ArrowLeft' });
    expect(store.getState().replayIndex).toBe(n - 1);
    fireEvent.keyDown(slider, { key: 'ArrowLeft' });
    expect(store.getState().replayIndex).toBe(n - 2);
    act(() => void vi.advanceTimersByTime(REPLAY_FETCH_DELAY_MS - 1));
    expect(ensureReplay).not.toHaveBeenCalled();
    act(() => void vi.advanceTimersByTime(1));
    expect(ensureReplay).toHaveBeenCalledTimes(1);
    expect(ensureReplay).toHaveBeenLastCalledWith(n - 2);
    fireEvent.keyDown(slider, { key: 'ArrowRight' });
    expect(store.getState().replayIndex).toBe(n - 1);
    fireEvent.keyDown(slider, { key: 'Home' });
    expect(store.getState().replayIndex).toBe(0);
    fireEvent.keyDown(slider, { key: 'ArrowLeft' });
    expect(store.getState().replayIndex).toBe(0);
    fireEvent.keyDown(slider, { key: 'End' });
    expect(store.getState().replayIndex).toBeNull();
    fireEvent.keyDown(slider, { key: 'ArrowRight' });
    expect(store.getState().replayIndex).toBeNull();
  });
});

describe('join screen code validation', () => {
  const socket: SocketLike = {
    connected: false,
    connect() {},
    disconnect() {},
    emit() {},
    on() {},
    off() {},
  } as unknown as SocketLike;

  it('normalises case and whitespace and names the bad characters', () => {
    expect(normalizeRoomCode(' ab c2 34 ')).toBe('ABC234');
    expect(roomCodeError('ABC234')).toBeNull();
    expect(roomCodeError('')).toBeNull();
    expect(roomCodeError('ABC10O')).toMatch(/"1", "0", "O"/);
    expect(roomCodeError('ABC23')).toMatch(/6 characters/);
    expect(roomCodeError('ABC2345')).toMatch(/6 characters/);
  });

  it('disables Join with an inline code-error, then sends the normalised code', async () => {
    const user = userEvent.setup();
    const store = createRemoteGameStore(socket, { storage: null });
    const joinRoom = vi.fn(async () => ({ ok: false as const, error: { code: 'notFound' as const, message: 'no room' } }));
    store.setState({ joinRoom } as never);
    render(<JoinScreen store={store} />);
    await user.type(screen.getByTestId('player-name'), 'Ann');
    await user.type(screen.getByTestId('room-code'), 'abc10o');
    expect(screen.getByTestId('code-error')).toBeInTheDocument();
    expect(screen.getByTestId('join-room')).toBeDisabled();
    await user.keyboard('{Enter}');
    expect(joinRoom).not.toHaveBeenCalled();
    await user.clear(screen.getByTestId('room-code'));
    await user.type(screen.getByTestId('room-code'), 'ab c 234');
    expect((screen.getByTestId('room-code') as HTMLInputElement).value).toBe('ABC234');
    expect(screen.queryByTestId('code-error')).not.toBeInTheDocument();
    expect(screen.getByTestId('join-room')).toBeEnabled();
    await user.keyboard('{Enter}');
    expect(joinRoom).toHaveBeenCalledWith('ABC234', 'Ann');
  });
});

describe('outpost civ label', () => {
  const px = (p: { x: number; y: number }) => ({ x: p.x * SCALE, y: p.y * SCALE });
  type Box = { x0: number; y0: number; x1: number; y1: number };
  const overlap = (a: Box, b: Box) => a.x0 < b.x1 && b.x0 < a.x1 && a.y0 < b.y1 && b.y0 < a.y1;
  const LABELS: Record<string, string> = { greenFolk: 'Green Folk', scientists: 'Scientists', diplomats: 'Diplomats', merchants: 'Merchants' };

  function check(sector: Sector) {
    const { label, docks } = outpostLayout(sector, px);
    // Generous text box: 0.65 em per character, full font height above the baseline, descenders below.
    const w = (LABELS[sector.civ!]!.length * LABEL_FONT * 0.65) / 2;
    const text: Box = { x0: label.x - w, y0: label.y - LABEL_FONT, x1: label.x + w, y1: label.y + LABEL_FONT * 0.3 };
    const dockRow: Box = {
      x0: Math.min(...docks.map((d) => d.x)) - DOCK_R,
      y0: Math.min(...docks.map((d) => d.y)) - DOCK_R,
      x1: Math.max(...docks.map((d) => d.x)) + DOCK_R,
      y1: Math.max(...docks.map((d) => d.y)) + DOCK_R,
    };
    const c = px(vertexPosition(sector.centreVertex));
    const halo: Box = { x0: c.x - 12, y0: c.y - 12, x1: c.x + 12, y1: c.y + 12 };
    expect(docks).toHaveLength(5);
    expect(overlap(text, dockRow), `${sector.id} label vs docks`).toBe(false);
    expect(overlap(text, halo), `${sector.id} label vs docking point`).toBe(false);
    // And it stays inside the tile: on one of the lobe centres.
    const nearest = Math.min(...sector.lobes.map((h) => Math.hypot(px(hexCenter(h)).x - label.x, px(hexCenter(h)).y - label.y)));
    expect(nearest).toBeLessThan(LABEL_FONT);
  }

  it('clears the dock row and the docking point on every outpost of every board', () => {
    let diplomats = 0;
    for (const variant of ['beginner', 'strategic'] as const) {
      const g = createGame({ variant, players: PLAYERS, seed: `label-${variant}` });
      for (const sector of Object.values(g.board.sectors)) {
        if (sector.kind !== 'outpost' || !sector.civ) continue;
        if (sector.civ === 'diplomats') diplomats++;
        check(sector);
      }
    }
    expect(diplomats).toBeGreaterThan(0);
  });

  it('is drawn where the layout says', () => {
    const g = createGame({ variant: 'beginner', players: PLAYERS, seed: 'label-draw' });
    const store = createGameStore();
    store.getState().loadGame(setup(), g);
    renderScreen(store);
    const sector = Object.values(g.board.sectors).find((s) => s.civ === 'diplomats')!;
    const el = screen.getByTestId(`civ-label-${sector.id}`);
    const docks = [0, 1, 2, 3, 4].map((i) => screen.getByTestId(`dock-${sector.id}-${i}`));
    const dockY = Number(docks[0]!.getAttribute('cy'));
    expect(Math.abs(Number(el.getAttribute('y')) - dockY)).toBeGreaterThan(DOCK_R + LABEL_FONT);
  });
});

describe('pending free trade ship note', () => {
  it('explains the spaceport-site rule when every own site is taken', () => {
    const s = game();
    const me = s.players[0]!;
    s.pendingTradeShips[me.id] = 1;
    // Fill every free own spaceport site with a blocker ship of another player.
    for (const [i, site] of freeOwnSpaceportSites(s, me.id).entries()) {
      s.board.ships[`ship:block:${i}`] = { id: `ship:block:${i}`, owner: s.players[1]!.id, kind: 'trade', nodeId: site, mustFoundOrLeave: false };
    }
    expect(freeOwnSpaceportSites(s, me.id)).toHaveLength(0);
    render(<MothershipPanel state={s} viewer={me.id} />);
    const note = screen.getByTestId('pending-trade-ship');
    expect(note.textContent).toMatch(/all your spaceport sites are occupied/);
    expect(note.textContent).toMatch(/first site of one of your own spaceports that frees up/);
  });

  it('names the missing piece when a site is free, and is absent without a marker', () => {
    const s = game();
    const me = s.players[0]!;
    const { unmount } = render(<MothershipPanel state={s} viewer={me.id} />);
    expect(screen.queryByTestId('pending-trade-ship')).not.toBeInTheDocument();
    unmount();
    s.pendingTradeShips[me.id] = 2;
    me.pieces.stationsLeft = 0;
    render(<MothershipPanel state={s} viewer={me.id} />);
    expect(screen.getByTestId('pending-trade-ship').textContent).toMatch(/2 free trade ships are waiting.*once you have a trade station piece/);
  });
});
