/**
 * Variable set-ups in the client (spec §3.2): the hot-seat picker starts the
 * chosen set-up, the lobby picker is host-only and emits `configureRoom`, and
 * the board draws undiscovered slots as face-down tiles.
 */

import type { ClientToServerEvents, GameState, LobbyView, ServerToClientEvents } from '@starfarers/shared';
import { createGame, redactState, undiscoveredInteriorNodes } from '@starfarers/shared';
import { act, render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, it } from 'vitest';
import { Board } from '../src/board/Board.js';
import { createRemoteGameStore, type SocketLike } from '../src/net/remoteStore.js';
import type { SessionStorageLike } from '../src/net/session.js';
import { RoomLobby } from '../src/panels/OnlineLobby.js';
import { SetupScreen } from '../src/panels/SetupScreen.js';
import { StoreContext, createGameStore } from '../src/store/gameStore.js';
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

function lobby(hostId: string): LobbyView {
  return {
    code: 'ABC234',
    name: 'Test',
    players: [
      { id: 'p1', name: 'Ann', color: 'red', connected: true, isHost: hostId === 'p1' },
      { id: 'p2', name: 'Bob', color: 'blue', connected: true, isHost: hostId === 'p2' },
      { id: 'p3', name: 'Cid', color: 'yellow', connected: true, isHost: hostId === 'p3' },
    ],
    hostId,
    started: false,
    config: { turnTimerSeconds: null, variant: 'beginner' },
    messages: [],
    minPlayers: 3,
    maxPlayers: 4,
  };
}

describe('hot-seat set-up screen', () => {
  it('offers the four set-ups, defaults to beginner and starts the chosen one', async () => {
    const store = createGameStore();
    render(
      <StoreContext.Provider value={store}>
        <SetupScreen />
      </StoreContext.Provider>,
    );
    const select = screen.getByTestId('variant-select') as HTMLSelectElement;
    expect(select.value).toBe('beginner');
    expect([...select.options].map((o) => o.value)).toEqual(['beginner', 'strategic', 'explorer', 'wild']);
    await userEvent.selectOptions(select, 'strategic');
    expect(screen.getByTestId('variant-description')).toHaveTextContent(/shuffled by region/);
    await userEvent.clear(screen.getByTestId('seed'));
    await userEvent.type(screen.getByTestId('seed'), 'picker');
    await userEvent.click(screen.getByTestId('start-game'));
    const game = store.getState().game!;
    expect(game.variant).toBe('strategic');
    expect(store.getState().setup?.variant).toBe('strategic');
    expect(game).toEqual(createGame({ variant: 'strategic', players: game.players.map((p) => ({ id: p.id, name: p.name, color: p.color })), seed: 'picker' }));
  });
});

describe('room lobby set-up picker', () => {
  it('lets the host change the set-up through configureRoom and shows it read-only to the others', async () => {
    const socket = new FakeSocket();
    const store = createRemoteGameStore(socket, { storage: new MemoryStorage() });
    store.setState({ session: { roomCode: 'ABC234', playerToken: 't', playerId: 'p1' }, lobby: lobby('p1') });
    const { unmount } = render(<RoomLobby store={store} />);
    const select = screen.getByTestId('variant-select') as HTMLSelectElement;
    expect(select).toBeEnabled();
    expect(screen.getByTestId('lobby-variant')).toHaveTextContent(/Beginner/);
    await userEvent.selectOptions(select, 'explorer');
    expect(socket.emitted.at(-1)).toEqual({ event: 'configureRoom', payload: { variant: 'explorer' } });
    // The server answers with a fresh lobby; the picker follows it.
    act(() => socket.fire('lobby', { ...lobby('p1'), config: { turnTimerSeconds: null, variant: 'explorer' } }));
    expect((screen.getByTestId('variant-select') as HTMLSelectElement).value).toBe('explorer');
    expect(screen.getByTestId('lobby-variant')).toHaveTextContent(/Explorer/);
    unmount();

    // A guest sees the value but cannot change it.
    const guestSocket = new FakeSocket();
    const guest = createRemoteGameStore(guestSocket, { storage: new MemoryStorage() });
    guest.setState({ session: { roomCode: 'ABC234', playerToken: 't2', playerId: 'p2' }, lobby: { ...lobby('p1'), config: { turnTimerSeconds: null, variant: 'wild' } } });
    render(<RoomLobby store={guest} />);
    expect(screen.getByTestId('variant-select')).toBeDisabled();
    expect(screen.getByTestId('lobby-variant')).toHaveTextContent(/Wild space/);
    expect(screen.getByTestId('lobby-variant')).toHaveTextContent(/host chooses/);
    expect(guestSocket.emitted.filter((e) => e.event === 'configureRoom')).toHaveLength(0);
  });
});

describe('board with face-down tiles', () => {
  const explorer: GameState = createGame({ variant: 'explorer', players: PLAYERS, seed: 'board-hidden' });

  it('draws every undiscovered slot as a hidden tile with no interior nodes, planets or docks (redacted and authoritative)', () => {
    for (const state of [explorer, redactState(explorer, 'p1')]) {
      const { container, unmount } = render(
        <Board state={state} viewer="p1" highlights={new Map()} selectedShip={null} onNodeClick={() => {}} onShipClick={() => {}} />,
      );
      expect(container.querySelectorAll('[data-testid^="hidden-"]')).toHaveLength(15);
      expect(container.querySelectorAll('[data-testid^="outpost-"]')).toHaveLength(0);
      expect(container.querySelectorAll('[data-testid^="disc-"]')).toHaveLength(12);
      for (const v of undiscoveredInteriorNodes(explorer.board)) expect(screen.queryByTestId(`node-${v}`)).toBeNull();
      unmount();
    }
    // A discovered slot draws as usual.
    const strategic = createGame({ variant: 'strategic', players: PLAYERS, seed: 'board-open' });
    const { container } = render(
      <Board state={strategic} viewer="p1" highlights={new Map()} selectedShip={null} onNodeClick={() => {}} onShipClick={() => {}} />,
    );
    expect(container.querySelectorAll('[data-testid^="hidden-"]')).toHaveLength(0);
    expect(container.querySelectorAll('[data-testid^="outpost-"]')).toHaveLength(4);
    expect(container.querySelectorAll('[data-testid^="disc-"]')).toHaveLength(36);
  });
});
