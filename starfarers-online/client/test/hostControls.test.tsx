/**
 * Host controls in the client (HANDOFF §8.3): in the room lobby the host gets
 * per-player `kick-<id>` (lobby only) and `make-host-<id>` buttons, everyone
 * sees the host (`lobby-host`) and the room's expiry (`lobby-expires`); in
 * game the host transfers with `transfer-host` + `transfer-host-confirm`; a
 * `kicked` event forgets the session and leaves the reason in `netError`.
 */

import type { ClientToServerEvents, LobbyView, ServerToClientEvents } from '@starfarers/shared';
import { act, render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, it } from 'vitest';
import { createRemoteGameStore, type SocketLike } from '../src/net/remoteStore.js';
import type { SessionStorageLike } from '../src/net/session.js';
import { ChatPanel } from '../src/panels/ChatPanel.js';
import { GameHostControls } from '../src/panels/HostControls.js';
import { RoomLobby } from '../src/panels/OnlineLobby.js';

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
    queueMicrotask(() => ack({ ok: true, value: {} } as never));
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

const EXPIRES = Date.UTC(2026, 9, 29, 12, 0);

function lobby(hostId = 'p1', started = false, hostOnline = true): LobbyView {
  return {
    code: 'ABC234',
    name: 'Test',
    players: [
      { id: 'p1', name: 'Ann', color: 'red', connected: hostId !== 'p1' || hostOnline, isHost: hostId === 'p1' },
      { id: 'p2', name: 'Bob', color: 'blue', connected: true, isHost: hostId === 'p2' },
      { id: 'p3', name: 'Cid', color: 'yellow', connected: true, isHost: hostId === 'p3' },
    ],
    hostId,
    started,
    config: { turnTimerSeconds: null, variant: 'beginner', setup: 'preset' },
    messages: [],
    minPlayers: 3,
    maxPlayers: 4,
    expiresAt: EXPIRES,
    idleMs: 24 * 3_600_000,
    hostHandoverAt: hostOnline ? null : EXPIRES - 1_000,
  };
}

function storeFor(playerId: string, view: LobbyView) {
  const socket = new FakeSocket();
  const storage = new MemoryStorage();
  const store = createRemoteGameStore(socket, { storage });
  store.setState({ session: { roomCode: 'ABC234', playerToken: `t-${playerId}`, playerId }, lobby: view });
  return { socket, storage, store };
}

describe('room lobby host buttons', () => {
  it('the host gets kick and make-host per other player; clicks send kickPlayer / transferHost', async () => {
    const { socket, store } = storeFor('p1', lobby());
    render(<RoomLobby store={store} />);
    expect(screen.queryByTestId('kick-p1')).toBeNull();
    expect(screen.queryByTestId('make-host-p1')).toBeNull();
    expect(screen.getByTestId('kick-p2')).toBeInTheDocument();
    expect(screen.getByTestId('make-host-p3')).toBeInTheDocument();
    expect(screen.getByTestId('lobby-host')).toHaveTextContent('Host: Ann');
    expect(screen.getByTestId('lobby-expires')).toHaveAttribute('data-expires-at', String(EXPIRES));
    expect(screen.getByTestId('lobby-expires')).toHaveTextContent('24 h without activity');
    await userEvent.click(screen.getByTestId('kick-p2'));
    expect(socket.emitted.at(-1)).toEqual({ event: 'kickPlayer', payload: { playerId: 'p2' } });
    await userEvent.click(screen.getByTestId('make-host-p3'));
    expect(socket.emitted.at(-1)).toEqual({ event: 'transferHost', payload: { playerId: 'p3' } });
    // The new host's lobby arrives: Ann loses the buttons.
    act(() => socket.fire('lobby', lobby('p3')));
    expect(screen.queryByTestId('kick-p2')).toBeNull();
    expect(screen.queryByTestId('make-host-p2')).toBeNull();
    expect(screen.getByTestId('lobby-host')).toHaveTextContent('Host: Cid');
  });

  it('guests see the host and the pending hand-over but no buttons; a started room has no kick', () => {
    const { store } = storeFor('p2', lobby('p1', false, false));
    const { unmount } = render(<RoomLobby store={store} />);
    expect(screen.queryByTestId('kick-p3')).toBeNull();
    expect(screen.queryByTestId('make-host-p3')).toBeNull();
    expect(screen.getByTestId('lobby-host')).toHaveTextContent('Host: Ann — offline; the host role passes');
    unmount();
    const host = storeFor('p1', lobby('p1', true));
    render(<RoomLobby store={host.store} />);
    expect(screen.queryByTestId('kick-p2')).toBeNull();
    expect(screen.getByTestId('make-host-p2')).toBeInTheDocument();
  });

  it('chat seen since the lobby moves the shown expiry on', () => {
    const { socket, store } = storeFor('p2', lobby());
    render(<RoomLobby store={store} />);
    act(() => socket.fire('chat', { from: 'p1', name: 'Ann', text: 'hi', at: EXPIRES - 24 * 3_600_000 + 60_000 }));
    expect(screen.getByTestId('lobby-expires')).toHaveAttribute('data-expires-at', String(EXPIRES + 60_000));
  });

  it('a kicked event forgets the session and keeps the reason', () => {
    const { socket, storage, store } = storeFor('p2', lobby());
    storage.setItem('starfarers.session', JSON.stringify({ roomCode: 'ABC234', playerToken: 't-p2', playerId: 'p2' }));
    act(() => socket.fire('kicked', { roomCode: 'ABC234', message: 'The host removed you from room ABC234' }));
    const s = store.getState();
    expect(s.session).toBeNull();
    expect(s.lobby).toBeNull();
    expect(s.netError).toBe('The host removed you from room ABC234');
    expect([...storage.data.values()].some((v) => v.includes('t-p2'))).toBe(false);
  });
});

describe('in-game host transfer', () => {
  it('the host picks a player and confirms; guests only see who hosts', async () => {
    const { socket, store } = storeFor('p1', lobby('p1', true));
    const { unmount } = render(<GameHostControls store={store} />);
    expect(screen.getByTestId('game-host')).toHaveTextContent('host Ann (you)');
    expect(screen.getByTestId('transfer-host-confirm')).toBeDisabled();
    await userEvent.selectOptions(screen.getByTestId('transfer-host'), 'p2');
    await userEvent.click(screen.getByTestId('transfer-host-confirm'));
    expect(socket.emitted.at(-1)).toEqual({ event: 'transferHost', payload: { playerId: 'p2' } });
    unmount();
    const guest = storeFor('p3', lobby('p2', true));
    render(<GameHostControls store={guest.store} />);
    expect(screen.getByTestId('game-host')).toHaveTextContent('host Bob');
    expect(screen.queryByTestId('transfer-host')).toBeNull();
  });
});

describe('chat lines from the server and reused seats', () => {
  it('system lines show the sender once ("Timer …", "Room …"), and a removed player\'s old line is not "mine" for the seat that reuses the id', () => {
    const view = lobby();
    view.messages = [
      { from: 'p2', name: 'Dee', text: 'I was p2 before the kick', at: 1 },
      { from: 'room', name: 'Room', text: 'room: Ann removed Dee from the room', at: 2 },
      { from: 'p2', name: 'Bob', text: 'hello, I am the new p2', at: 3 },
      { from: 'timer', name: 'Timer', text: 'timer: Bob ran out of time; rolled, ended the turn', at: 4 },
    ];
    const { store } = storeFor('p2', view);
    store.setState({ chat: view.messages });
    render(<ChatPanel store={store} />);
    expect(screen.getByTestId('chat-room')).toHaveTextContent(/^Room Ann removed Dee from the room$/);
    expect(screen.getByTestId('chat-timer')).toHaveTextContent(/^Timer Bob ran out of time; rolled, ended the turn$/);
    const items = screen.getByTestId('chat-panel').querySelectorAll('li');
    expect(items[0]).not.toHaveClass('mine');
    expect(items[2]).toHaveClass('mine');
    expect(screen.getByTestId('chat-timer')).toHaveClass('system');
  });
});
