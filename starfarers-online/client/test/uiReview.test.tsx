/**
 * UI/UX review fixes: readable action log lines, the hot-seat "New game" confirmation,
 * labelled seat inputs, and the primary action-bar button.
 */
import { applyAction, createRng } from '@starfarers/shared';
import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { GameScreen } from '../src/App.js';
import { SetupScreen } from '../src/panels/SetupScreen.js';
import { StoreContext, createGameStore } from '../src/store/gameStore.js';
import { logText } from '../src/ui/format.js';
import { game, setup } from './fixtures.js';

afterEach(() => vi.restoreAllMocks());

describe('logText', () => {
  it('turns an action entry into "<player> <verb phrase>" and keeps events verbatim', () => {
    const s = game();
    const result = applyAction(s, { type: 'rollDice', playerId: s.activePlayer }, createRng('log-text'));
    if (!result.ok) throw new Error(result.error.message);
    const next = result.value;
    const action = next.log.find((e) => e.kind === 'action')!;
    const event = next.log.find((e) => e.kind === 'event')!;
    const name = next.players.find((p) => p.id === s.activePlayer)!.name;
    expect(action.message).toBe('rollDice');
    expect(logText(next, action)).toBe(`${name} rolls the dice`);
    expect(logText(next, event)).toBe(event.message);
  });
});

function renderGame() {
  const store = createGameStore();
  store.getState().newGame(setup());
  store.getState().acknowledgeViewer();
  render(
    <StoreContext.Provider value={store}>
      <GameScreen />
    </StoreContext.Provider>,
  );
  return store;
}

describe('hot-seat New game', () => {
  it('asks first and keeps the game when the player cancels', async () => {
    const store = renderGame();
    const before = store.getState().game;
    const confirm = vi.spyOn(window, 'confirm').mockReturnValue(false);
    await userEvent.click(screen.getByTestId('new-game'));
    expect(confirm).toHaveBeenCalledOnce();
    expect(store.getState().game).toBe(before);
  });

  it('starts a fresh game once confirmed', async () => {
    const store = renderGame();
    const before = store.getState().game!;
    vi.spyOn(window, 'confirm').mockReturnValue(true);
    await userEvent.click(screen.getByTestId('new-game'));
    expect(store.getState().game!.seed).not.toBe(before.seed);
  });
});

describe('action bar', () => {
  it('marks the turn-advancing step as the primary button', () => {
    renderGame();
    expect(screen.getByTestId('action-roll')).toHaveClass('primary');
  });
});

describe('setup screen', () => {
  it('names every seat input for assistive tech', () => {
    const store = createGameStore();
    render(
      <StoreContext.Provider value={store}>
        <SetupScreen />
      </StoreContext.Provider>,
    );
    expect(screen.getByRole('textbox', { name: 'Seat 1 name' })).toBeInTheDocument();
    expect(screen.getByRole('combobox', { name: 'Seat 3 colour' })).toBeInTheDocument();
  });
});
