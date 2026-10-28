/**
 * Phone layout (spec §14, HANDOFF §8.9a): the zoom maths, tap-to-preview /
 * tap-to-confirm on touch screens, the ship list, and the panel tabs. jsdom
 * has no `matchMedia`, so each test stubs which queries match.
 */

import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, describe, expect, it } from 'vitest';
import { GameScreen } from '../src/App.js';
import { legalMoves } from '../src/board/legalMoves.js';
import { MAX_ZOOM, clampView, focusView, zoomOf, zoomView, type Box } from '../src/board/view.js';
import { StoreContext, createGameStore } from '../src/store/gameStore.js';
import { COARSE_QUERY, PHONE_QUERY } from '../src/ui/media.js';
import { game, inFlight, setup, shipsOfActive } from './fixtures.js';

function mockMedia(matching: string[]) {
  Object.defineProperty(window, 'matchMedia', {
    configurable: true,
    writable: true,
    value: (query: string) => ({ matches: matching.includes(query), media: query, addEventListener() {}, removeEventListener() {} }),
  });
}

afterEach(() => {
  delete (window as { matchMedia?: unknown }).matchMedia;
});

const FULL: Box = { x: 0, y: 0, w: 1000, h: 600 };

describe('board view maths', () => {
  it('zooms about a fixed point and back out to the whole board', () => {
    const v = zoomView(FULL, FULL, 2, 250, 150);
    expect(v).toEqual({ x: 125, y: 75, w: 500, h: 300 });
    expect(zoomOf(FULL, v)).toBe(2);
    expect(zoomView(FULL, v, 0.25)).toEqual(FULL);
  });

  it('never zooms past MAX_ZOOM or pans off the board', () => {
    expect(zoomOf(FULL, zoomView(FULL, FULL, 100))).toBeCloseTo(MAX_ZOOM);
    const v = clampView(FULL, { x: 900, y: -50, w: 500, h: 300 });
    expect(v).toEqual({ x: 500, y: 0, w: 500, h: 300 });
  });

  it('focuses so a 32-unit target is at least 44 px, even if far targets need a pan', () => {
    const screenPx = { w: 360, h: 420 };
    const minScale = 44 / 32;
    const wide = focusView(FULL, { x: 100, y: 100, w: 700, h: 300 }, screenPx, minScale);
    expect(screenPx.w / wide.w).toBeGreaterThanOrEqual(minScale - 1e-9);
    // A lone nearby target stops at twice that scale instead of filling the screen (on a board small
    // enough that MAX_ZOOM is not the tighter limit).
    const small: Box = { x: 0, y: 0, w: 600, h: 400 };
    const near = focusView(small, { x: 300, y: 200, w: 10, h: 10 }, screenPx, minScale);
    expect(screenPx.w / near.w).toBeCloseTo(2 * minScale);
    expect(near.x + near.w / 2).toBeCloseTo(305);
  });
});

/** A hot-seat game in flight.move, rendered as on a touch phone. */
function renderTouchFlight() {
  mockMedia([PHONE_QUERY, COARSE_QUERY]);
  const store = createGameStore();
  store.getState().loadGame(setup('phone'), inFlight(game('phone'), 3));
  const g = store.getState().game!;
  const shipId = shipsOfActive(g)[0]!;
  render(
    <StoreContext.Provider value={store}>
      <GameScreen />
    </StoreContext.Provider>,
  );
  return { store, shipId };
}

describe('touch play', () => {
  it('picks a ship from the list, previews on the first tap and moves on confirm', async () => {
    const { store, shipId } = renderTouchFlight();
    await userEvent.click(screen.getByTestId(`pick-ship-${shipId}`));
    expect(store.getState().selectedShip).toBe(shipId);
    const [target] = [...legalMoves(store.getState().game!, shipId).keys()];
    const before = store.getState().actions.length;

    await userEvent.click(screen.getByTestId(`node-${target}`));
    expect(store.getState().actions.length).toBe(before);
    expect(screen.getByTestId(`node-${target}`)).toHaveClass('armed');
    expect(screen.getByTestId('confirm-pick')).toHaveTextContent('Move here');
    expect(screen.getByTestId('board').querySelector('.path-preview')).not.toBeNull();

    await userEvent.click(screen.getByTestId('confirm-pick'));
    expect(store.getState().actions.length).toBe(before + 1);
    expect(store.getState().actions.at(-1)).toMatchObject({ type: 'moveShip', shipId });
  });

  it('a second tap on the armed spot also confirms; Cancel disarms', async () => {
    const { store, shipId } = renderTouchFlight();
    await userEvent.click(screen.getByTestId(`pick-ship-${shipId}`));
    const [a, b] = [...legalMoves(store.getState().game!, shipId).keys()];
    await userEvent.click(screen.getByTestId(`node-${a}`));
    await userEvent.click(screen.getByTestId('cancel-pick'));
    expect(screen.queryByTestId('confirm-bar')).toBeNull();
    const before = store.getState().actions.length;
    await userEvent.click(screen.getByTestId(`node-${b}`));
    await userEvent.click(screen.getByTestId(`node-${b}`));
    expect(store.getState().actions.length).toBe(before + 1);
  });

  it('a mouse still moves on one click (no confirm step)', async () => {
    mockMedia([]);
    const store = createGameStore();
    store.getState().loadGame(setup('phone'), inFlight(game('phone'), 3));
    const shipId = shipsOfActive(store.getState().game!)[0]!;
    render(
      <StoreContext.Provider value={store}>
        <GameScreen />
      </StoreContext.Provider>,
    );
    expect(screen.queryByTestId('ship-picker')).toBeNull();
    expect(screen.queryByTestId('phone-tabs')).toBeNull();
    await userEvent.click(screen.getByTestId(`ship-${shipId}`));
    const [target] = [...legalMoves(store.getState().game!, shipId).keys()];
    const before = store.getState().actions.length;
    await userEvent.click(screen.getByTestId(`node-${target}`));
    expect(store.getState().actions.length).toBe(before + 1);
  });
});

describe('phone panel tabs', () => {
  it('opens one panel at a time and closes it on a second tap', async () => {
    renderTouchFlight();
    const hand = screen.getByTestId('hand-panel').parentElement!;
    const build = screen.getByTestId('build-menu').parentElement!;
    expect(hand).not.toHaveClass('open');
    await userEvent.click(screen.getByTestId('tab-hand'));
    expect(hand).toHaveClass('open');
    expect(screen.getByTestId('tab-hand')).toHaveAttribute('aria-pressed', 'true');
    await userEvent.click(screen.getByTestId('tab-build'));
    expect(hand).not.toHaveClass('open');
    expect(build).toHaveClass('open');
    await userEvent.click(screen.getByTestId('tab-build'));
    expect(build).not.toHaveClass('open');
  });

  it('badges the Trade tab when an offer waits for the viewer', () => {
    mockMedia([PHONE_QUERY]);
    const store = createGameStore();
    const s = game('phone');
    s.phase = 'tradeBuild';
    const other = s.players.find((p) => p.id !== s.activePlayer)!.id;
    s.openTrade = { from: s.activePlayer, to: other, give: { ore: 1 }, want: { fuel: 1 } };
    store.getState().loadGame(setup('phone'), s);
    store.getState().takeSeat(other);
    store.getState().acknowledgeViewer();
    render(
      <StoreContext.Provider value={store}>
        <GameScreen />
      </StoreContext.Provider>,
    );
    expect(screen.getByTestId('tab-trade-badge')).toBeInTheDocument();
  });
});
