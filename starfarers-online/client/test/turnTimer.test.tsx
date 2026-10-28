/**
 * Turn timer in the client (HANDOFF §8.2): the host-only lobby picker emits
 * `configureRoom({ turnTimerSeconds })`, everyone sees `lobby-timer`, and the
 * in-game `turn-timer` counts down from the `state` payload's `deadlineAt`
 * (hidden without a timer or after the game).
 */

import { TURN_TIMER_CHOICES, createGame, redactState, type ClientToServerEvents, type LobbyView, type ServerToClientEvents } from '@starfarers/shared';
import { act, render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { createRemoteGameStore, type SocketLike } from '../src/net/remoteStore.js';
import type { SessionStorageLike } from '../src/net/session.js';
import { RoomLobby } from '../src/panels/OnlineLobby.js';
import { TurnTimer, formatCountdown, timerLabel } from '../src/panels/TurnTimer.js';
import { PLAYERS } from './fixtures.js';

class FakeSocket implements SocketLike {
  connected = true;
  emitted: { event: string; payload: unknown }[] = [];
  handlers = new Map<string, ((...args: never[]) => void)[]>();
  connect() {
    this.connected = true;
  }
  disconnect() {
    this.connected = false;
  }
  emit<E extends keyof ClientToServerEvents>(event: E, payload: Parameters<ClientToServerEvents[E]>[0], ack: (reply: never) => void): void {
    this.emitted.push({ event, payload });
    queueMicrotask(() => ack({ ok: true, value: { configured: true } } as never));
  }
  on(event: string, handler: (...args: never[]) => void): void {
    this.handlers.set(event, [...(this.handlers.get(event) ?? []), handler]);
  }
  off(event: string): void {
    this.handlers.delete(event);
  }
  fire<E extends keyof ServerToClientEvents>(event: E, ...args: unknown[]): void {
    for (const h of this.handlers.get(event) ?? []) (h as (...a: unknown[]) => void)(...args);
  }
}

class MemoryStorage implements SessionStorageLike {
  data = new Map<string, string>();
  getItem(k: string) {
    return this.data.get(k) ?? null;
  }
  setItem(k: string, v: string) {
    this.data.set(k, v);
  }
  removeItem(k: string) {
    this.data.delete(k);
  }
}

function lobby(turnTimerSeconds: number | null, started = false): LobbyView {
  return {
    code: 'ABC234',
    name: 'Test',
    players: [
      { id: 'p1', name: 'Ann', color: 'red', connected: true, isHost: true },
      { id: 'p2', name: 'Bob', color: 'blue', connected: true, isHost: false },
      { id: 'p3', name: 'Cid', color: 'yellow', connected: true, isHost: false },
    ],
    hostId: 'p1',
    started,
    config: { turnTimerSeconds, variant: 'beginner', setup: 'preset' },
    messages: [],
    minPlayers: 3,
    maxPlayers: 4,
  };
}

afterEach(() => {
  vi.useRealTimers();
});

describe('lobby turn-timer picker', () => {
  it('host picks a timer through configureRoom; guests see it read-only', async () => {
    const socket = new FakeSocket();
    const store = createRemoteGameStore(socket, { storage: new MemoryStorage() });
    store.setState({ session: { roomCode: 'ABC234', playerToken: 't', playerId: 'p1' }, lobby: lobby(null) });
    const { unmount } = render(<RoomLobby store={store} />);
    const select = screen.getByTestId('timer-select') as HTMLSelectElement;
    expect(select).toBeEnabled();
    expect(select.value).toBe('off'); // off by default (spec §13)
    expect([...select.options].map((o) => o.value)).toEqual(['off', ...TURN_TIMER_CHOICES.map(String)]);
    expect(screen.getByTestId('lobby-timer')).toHaveTextContent('No turn timer');
    const shortest = Math.min(...TURN_TIMER_CHOICES);
    await userEvent.selectOptions(select, String(shortest));
    expect(socket.emitted.at(-1)).toEqual({ event: 'configureRoom', payload: { turnTimerSeconds: shortest } });
    act(() => socket.fire('lobby', lobby(shortest)));
    expect((screen.getByTestId('timer-select') as HTMLSelectElement).value).toBe(String(shortest));
    expect(screen.getByTestId('lobby-timer')).toHaveTextContent(`${timerLabel(shortest)} per turn`);
    // Accurate about the one forced move (HANDOFF §5.24): no building or trading, a parked ship founds or leaves.
    expect(screen.getByTestId('lobby-timer')).toHaveTextContent('never builds or trades');
    expect(screen.getByTestId('lobby-timer')).toHaveTextContent('moves a ship only when a parked ship must found or leave');
    expect(screen.getByTestId('lobby-timer')).not.toHaveTextContent('no building, trading or moving');
    await userEvent.selectOptions(screen.getByTestId('timer-select'), 'off');
    expect(socket.emitted.at(-1)).toEqual({ event: 'configureRoom', payload: { turnTimerSeconds: null } });
    unmount();

    const guestSocket = new FakeSocket();
    const guest = createRemoteGameStore(guestSocket, { storage: new MemoryStorage() });
    guest.setState({ session: { roomCode: 'ABC234', playerToken: 't2', playerId: 'p2' }, lobby: lobby(90) });
    render(<RoomLobby store={guest} />);
    expect(screen.getByTestId('timer-select')).toBeDisabled();
    expect(screen.getByTestId('lobby-timer')).toHaveTextContent('1 min 30 s per turn');
    expect(screen.getByTestId('lobby-timer')).toHaveTextContent('host chooses');
    expect(guestSocket.emitted).toHaveLength(0);
  });

  it('labels and countdown format', () => {
    expect(timerLabel(null)).toBe('off');
    expect(timerLabel(30)).toBe('30 s');
    expect(timerLabel(60)).toBe('1 min');
    expect(timerLabel(300)).toBe('5 min');
    expect(formatCountdown(61_000)).toBe('1:01');
    expect(formatCountdown(500)).toBe('0:01');
    expect(formatCountdown(-5)).toBe('0:00');
  });
});

describe('in-game turn-timer countdown', () => {
  const game = createGame({ variant: 'beginner', players: PLAYERS, seed: 'timer-client' });

  it('counts down from deadlineAt in the state payload, corrected by serverNow, and hides when null', () => {
    vi.useFakeTimers();
    vi.setSystemTime(1_000_000);
    const socket = new FakeSocket();
    const store = createRemoteGameStore(socket, { storage: new MemoryStorage() });
    store.setState({ session: { roomCode: 'ABC234', playerToken: 't', playerId: 'p1' }, lobby: lobby(60, true) });
    render(<TurnTimer store={store} />);
    expect(screen.queryByTestId('turn-timer')).toBeNull();

    // The server's clock runs 2 s ahead of ours: 60 s on its clock is 58 s here.
    act(() => socket.fire('state', { state: redactState(game, 'p1'), action: null, deadlineAt: 1_062_000, serverNow: 1_002_000 }));
    const active = game.players.find((p) => p.id === game.activePlayer)!.name;
    expect(screen.getByTestId('turn-timer')).toHaveTextContent(`${active}: 1:00`);
    act(() => vi.advanceTimersByTime(15_000));
    expect(screen.getByTestId('turn-timer')).toHaveTextContent('0:45');
    expect(screen.getByTestId('turn-timer')).not.toHaveClass('urgent');
    act(() => vi.advanceTimersByTime(40_000));
    expect(screen.getByTestId('turn-timer')).toHaveTextContent('0:05');
    expect(screen.getByTestId('turn-timer')).toHaveClass('urgent');
    act(() => vi.advanceTimersByTime(10_000));
    expect(screen.getByTestId('turn-timer')).toHaveTextContent('time up');

    // The next turn's state resets it.
    act(() => socket.fire('state', { state: redactState(game, 'p1'), action: null, deadlineAt: 1_067_000 + 30_000, serverNow: 1_067_000 }));
    expect(screen.getByTestId('turn-timer')).toHaveTextContent('0:30');

    // No timer (null or a pre-phase-7 server without the field): hidden.
    act(() => socket.fire('state', { state: redactState(game, 'p1'), action: null, deadlineAt: null }));
    expect(screen.queryByTestId('turn-timer')).toBeNull();
    act(() => socket.fire('state', { state: redactState(game, 'p1'), action: null, deadlineAt: 2_000_000 }));
    expect(screen.getByTestId('turn-timer')).toBeInTheDocument();
    act(() => socket.fire('state', { state: redactState(game, 'p1'), action: null }));
    expect(screen.queryByTestId('turn-timer')).toBeNull();
  });

  it('is hidden once the game is over', () => {
    const socket = new FakeSocket();
    const store = createRemoteGameStore(socket, { storage: new MemoryStorage() });
    store.setState({ session: { roomCode: 'ABC234', playerToken: 't', playerId: 'p1' }, lobby: lobby(60, true) });
    render(<TurnTimer store={store} />);
    const over = { ...redactState(game, 'p1'), phase: 'gameOver' as const, winner: 'p1' };
    act(() => socket.fire('state', { state: over, action: null, deadlineAt: Date.now() + 60_000, serverNow: Date.now() }));
    expect(screen.queryByTestId('turn-timer')).toBeNull();
  });
});
