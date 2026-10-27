import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, it } from 'vitest';
import { PassBanner } from '../src/panels/PassBanner.js';
import { createGameStore, gameStore, requiredViewer } from '../src/store/gameStore.js';
import { game, setup } from './fixtures.js';

describe('requiredViewer', () => {
  it('is the active player by default', () => {
    const s = game();
    expect(requiredViewer(s, null)).toBe(s.activePlayer);
  });
  it('is the trade recipient while a player proposal is open', () => {
    const s = game();
    s.phase = 'tradeBuild';
    s.openTrade = { from: s.activePlayer, to: 'p2', give: { ore: 1 }, want: { fuel: 1 } };
    expect(requiredViewer(s, s.activePlayer)).toBe('p2');
  });
  it('is the encounter picker', () => {
    const s = game();
    s.phase = 'flight.encounter';
    s.turn.encounter = { cardId: 1, stage: 'resolving', revealed: [], queue: [], awaiting: { kind: 'giveOne', playerId: 'p3', effect: { type: 'giveOne' }, count: 1 } };
    expect(requiredViewer(s, 'p1')).toBe('p3');
  });
  it('keeps the current viewer while they still owe a 7 discard, else the first who does', () => {
    const s = game();
    s.turn.rolled = 7;
    s.turn.seven = { awaitingDiscard: ['p2', 'p3'], stealDone: false };
    expect(requiredViewer(s, 'p3')).toBe('p3');
    expect(requiredViewer(s, 'p1')).toBe('p2');
  });
});

describe('viewer switch in the store', () => {
  it('sets pendingViewer when another seat must act and clears it on acknowledge', () => {
    const store = createGameStore();
    const s = game();
    s.phase = 'tradeBuild';
    const active = s.activePlayer;
    const other = s.players.find((p) => p.id !== active)!.id;
    s.players.find((p) => p.id === active)!.hand = ['ore', 'ore', 'ore'];
    store.getState().loadGame(setup(), s);
    expect(store.getState().viewer).toBe(active);
    const ok = store.getState().dispatch({ type: 'proposeTrade', playerId: active, to: other, give: { ore: 1 }, want: { fuel: 1 } });
    expect(ok).toBe(true);
    expect(store.getState().pendingViewer).toBe(other);
    store.getState().acknowledgeViewer();
    expect(store.getState().viewer).toBe(other);
    expect(store.getState().pendingViewer).toBeNull();
    // The recipient rejects: the laptop goes back to the active player.
    expect(store.getState().dispatch({ type: 'respondTrade', playerId: other, accept: false })).toBe(true);
    expect(store.getState().pendingViewer).toBe(active);
  });

  it('keeps errors without changing the viewer', () => {
    const store = createGameStore();
    store.getState().newGame(setup());
    const active = store.getState().game!.activePlayer;
    const other = store.getState().game!.players.find((p) => p.id !== active)!.id;
    expect(store.getState().dispatch({ type: 'rollDice', playerId: other })).toBe(false);
    expect(store.getState().error?.code).toBe('notYourTurn');
    expect(store.getState().viewer).toBe(active);
    expect(store.getState().actions).toHaveLength(0);
  });

  it('renders the pass banner and hands over on click', async () => {
    const s = game();
    s.phase = 'tradeBuild';
    const active = s.activePlayer;
    const other = s.players.find((p) => p.id !== active)!;
    s.players.find((p) => p.id === active)!.hand = ['ore', 'ore', 'ore'];
    gameStore.getState().loadGame(setup(), s);
    gameStore.getState().dispatch({ type: 'proposeTrade', playerId: active, to: other.id, give: { ore: 1 }, want: { fuel: 1 } });
    render(<PassBanner state={gameStore.getState().game!} />);
    expect(screen.getByTestId('pass-banner')).toHaveTextContent(`Pass the laptop to ${other.name}`);
    await userEvent.click(screen.getByTestId('take-seat'));
    expect(gameStore.getState().viewer).toBe(other.id);
  });
});
