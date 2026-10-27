import type { Action, ClientToServerEvents, GameState, JoinReply, LobbyView, ServerToClientEvents } from '@starfarers/shared';
import { redactState } from '@starfarers/shared';
import { act, fireEvent, render, screen } from '@testing-library/react';
import { createElement } from 'react';
import { describe, expect, it } from 'vitest';
import { createRemoteGameStore, type SocketLike } from '../src/net/remoteStore.js';
import { loadSession, saveSession, type SessionStorageLike } from '../src/net/session.js';
import { LogPane, REPLAY_FETCH_DELAY_MS } from '../src/panels/LogPane.js';
import { StoreContext, useShownState, type GameStore } from '../src/store/gameStore.js';
import { game } from './fixtures.js';

/** In-memory socket: records emits, answers acks from a script, lets tests push server events. */
class FakeSocket implements SocketLike {
  connected = false;
  emitted: { event: string; payload: unknown }[] = [];
  handlers = new Map<string, ((...args: never[]) => void)[]>();
  replies = new Map<string, unknown>();
  connect() {
    this.connected = true;
    this.fire('connect');
  }
  disconnect() {
    this.connected = false;
    this.fire('disconnect');
  }
  emit<E extends keyof ClientToServerEvents>(event: E, payload: Parameters<ClientToServerEvents[E]>[0], ack: (reply: never) => void): void {
    this.emitted.push({ event, payload });
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

function lobby(started = false): LobbyView {
  return {
    code: 'ABC234',
    name: 'Test',
    players: [
      { id: 'p1', name: 'Ann', color: 'red', connected: true, isHost: true },
      { id: 'p2', name: 'Bob', color: 'blue', connected: true, isHost: false },
      { id: 'p3', name: 'Cid', color: 'yellow', connected: false, isHost: false },
    ],
    hostId: 'p1',
    started,
    config: { turnTimerSeconds: null, variant: 'beginner' },
    messages: [],
    minPlayers: 3,
    maxPlayers: 4,
  };
}

function joinReply(state: GameState | null, playerId = 'p2'): JoinReply {
  return { session: { roomCode: 'ABC234', playerToken: 'tok-2', playerId }, lobby: lobby(state !== null), state: state ? redactState(state, playerId) : null, actions: [], initial: null };
}

describe('session storage', () => {
  it('round-trips and rejects junk', () => {
    const mem = new MemoryStorage();
    expect(loadSession(mem)).toBeNull();
    saveSession({ roomCode: 'ABC234', playerToken: 't', playerId: 'p1' }, mem);
    expect(loadSession(mem)).toEqual({ roomCode: 'ABC234', playerToken: 't', playerId: 'p1' });
    mem.setItem('starfarers.session', '{"roomCode":1}');
    expect(loadSession(mem)).toBeNull();
    saveSession(null, mem);
    expect(mem.data.size).toBe(0);
  });
});

describe('RemoteGameStore', () => {
  it('joins a room, persists the session and fixes the viewer to the socket player', async () => {
    const socket = new FakeSocket();
    const mem = new MemoryStorage();
    const store = createRemoteGameStore(socket, { storage: mem });
    socket.replies.set('joinRoom', { ok: true, value: joinReply(null) });
    const r = await store.getState().joinRoom('abc234', 'Bob');
    expect(r.ok).toBe(true);
    expect(socket.connected).toBe(true);
    expect(store.getState().connection).toBe('connected');
    expect(store.getState().viewer).toBe('p2');
    expect(store.getState().pendingViewer).toBeNull();
    expect(store.getState().lobby?.code).toBe('ABC234');
    expect(store.getState().game).toBeNull();
    expect(loadSession(mem)?.playerToken).toBe('tok-2');
    expect(store.getState().mode).toBe('remote');
  });

  it('surfaces join failures as netError without touching the session', async () => {
    const socket = new FakeSocket();
    const mem = new MemoryStorage();
    const store = createRemoteGameStore(socket, { storage: mem });
    socket.replies.set('joinRoom', { ok: false, error: { code: 'noSuchRoom', message: 'No room ZZZZZZ' } });
    const r = await store.getState().joinRoom('ZZZZZZ', 'Bob');
    expect(r.ok).toBe(false);
    expect(store.getState().netError).toBe('No room ZZZZZZ');
    expect(loadSession(mem)).toBeNull();
  });

  it('dispatch emits the action and keeps engine rejections in `error`', async () => {
    const socket = new FakeSocket();
    const store = createRemoteGameStore(socket, { storage: new MemoryStorage() });
    const state = game();
    socket.replies.set('joinRoom', { ok: true, value: joinReply(state) });
    await store.getState().joinRoom('ABC234', 'Bob');
    expect(store.getState().game?.players.find((p) => p.id === 'p1')?.hand).toEqual([]);
    expect(store.getState().game?.players.find((p) => p.id === 'p2')?.hand.length).toBeGreaterThan(0);

    const action: Action = { type: 'rollDice', playerId: 'p2' };
    expect(store.getState().dispatch(action)).toBe(true);
    expect(socket.emitted.at(-1)).toEqual({ event: 'action', payload: { action } });

    socket.replies.set('action', { ok: false, error: { kind: 'error', code: 'notYourTurn', message: 'Not your turn' } });
    store.getState().dispatch(action);
    await new Promise((r) => setTimeout(r, 0));
    expect(store.getState().error?.code).toBe('notYourTurn');
    store.getState().clearError();
    expect(store.getState().error).toBeNull();
  });

  it('applies broadcast states, appends actions and replays from snapshots', async () => {
    const socket = new FakeSocket();
    const store = createRemoteGameStore(socket, { storage: new MemoryStorage() });
    const s0 = game();
    socket.replies.set('joinRoom', { ok: true, value: joinReply(s0) });
    await store.getState().joinRoom('ABC234', 'Bob');
    const s1 = structuredClone(s0);
    s1.turn.rolled = 8;
    s1.phase = 'tradeBuild';
    const a1: Action = { type: 'rollDice', playerId: s0.activePlayer };
    socket.fire('state', { state: redactState(s1, 'p2'), action: a1 });
    expect(store.getState().game?.turn.rolled).toBe(8);
    expect(store.getState().actions).toEqual([a1]);
    expect(store.getState().snapshots).toHaveLength(2);
    expect(store.getState().replayState(0).turn.rolled).toBeUndefined();
    expect(store.getState().replayState(1).turn.rolled).toBe(8);
    expect(store.getState().replayState(99).turn.rolled).toBe(8);
    // A state without an action (someone reconnected) does not grow the action log.
    socket.fire('state', { state: redactState(s1, 'p2'), action: null });
    expect(store.getState().actions).toHaveLength(1);
    // …and replaces the latest snapshot instead of shifting the replay indexes.
    expect(store.getState().snapshots).toHaveLength(2);
    expect(store.getState().replayState(1).turn.rolled).toBe(8);
    // Lobby and chat events.
    socket.fire('lobby', { ...lobby(true), messages: [{ from: 'p1', name: 'Ann', text: 'hi', at: 1 }] });
    expect(store.getState().chat).toHaveLength(1);
    socket.fire('chat', { from: 'p3', name: 'Cid', text: 'yo', at: 2 });
    expect(store.getState().chat.map((m) => m.text)).toEqual(['hi', 'yo']);
    // Server-pushed errors: engine errors vs room errors.
    socket.fire('error', { kind: 'error', code: 'wrongPhase', message: 'nope' });
    expect(store.getState().error?.code).toBe('wrongPhase');
    socket.fire('error', { code: 'badToken', message: 'resumed elsewhere' });
    expect(store.getState().netError).toBe('resumed elsewhere');
  });

  it('resume uses the saved session and leaveRoom forgets it', async () => {
    const mem = new MemoryStorage();
    saveSession({ roomCode: 'ABC234', playerToken: 'tok-2', playerId: 'p2' }, mem);
    const socket = new FakeSocket();
    const store = createRemoteGameStore(socket, { storage: mem });
    expect(store.getState().session?.roomCode).toBe('ABC234');
    socket.replies.set('resume', { ok: true, value: joinReply(game()) });
    const r = await store.getState().resume();
    expect(r.ok).toBe(true);
    expect(socket.emitted[0]).toEqual({ event: 'resume', payload: { roomCode: 'ABC234', playerToken: 'tok-2' } });
    expect(store.getState().game).not.toBeNull();
    store.getState().leaveRoom();
    expect(store.getState().session).toBeNull();
    expect(store.getState().game).toBeNull();
    expect(loadSession(mem)).toBeNull();
    expect(socket.connected).toBe(false);
    const none = await store.getState().resume();
    expect(none.ok).toBe(false);
  });

  it('a resumed client scrubs before its join through the server replay, one request per index', async () => {
    const socket = new FakeSocket();
    const store = createRemoteGameStore(socket, { storage: new MemoryStorage() });
    // Three accepted actions happened before this client resumed; positions are tagged via turn.rolled.
    const at = (k: number) => {
      const s = structuredClone(game());
      if (k > 0) s.turn.rolled = k + 1;
      return redactState(s, 'p2');
    };
    const actions: Action[] = [
      { type: 'rollDice', playerId: 'p1' },
      { type: 'discardForSeven', playerId: 'p3', cards: [] },
      { type: 'endTurn', playerId: 'p1' },
    ];
    const reply: JoinReply = { ...joinReply(null), lobby: lobby(true), state: at(3), actions, initial: at(0) };
    socket.replies.set('resume', { ok: true, value: reply });
    await store.getState().resume({ roomCode: 'ABC234', playerToken: 'tok-2', playerId: 'p2' });
    expect(store.getState().snapshotBase).toBe(3);
    expect(store.getState().replayMin).toBe(0);
    expect(store.getState().initial).toEqual(at(0));
    socket.replies.set('replay', { ok: true, value: at(1) });

    function Shown() {
      return createElement('span', { 'data-testid': 'shown' }, String(useShownState()?.turn.rolled ?? 'none'));
    }
    render(
      createElement(
        StoreContext.Provider,
        { value: store as unknown as GameStore },
        createElement(LogPane, { state: store.getState().game! }),
        createElement(Shown),
      ),
    );
    const slider = screen.getByLabelText('Replay position') as HTMLInputElement;
    expect(slider.min).toBe('0');
    expect(slider.max).toBe('3');

    const replayEmits = () => socket.emitted.filter((e) => e.event === 'replay');
    const settle = () =>
      act(async () => {
        await new Promise((r) => setTimeout(r, REPLAY_FETCH_DELAY_MS + 20));
      });
    // A drag over 2 → 1 asks only for where the slider comes to rest.
    act(() => {
      fireEvent.change(slider, { target: { value: '2' } });
    });
    act(() => {
      fireEvent.change(slider, { target: { value: '1' } });
    });
    // Meanwhile the nearest known position (the initial state) is shown.
    expect(screen.getByTestId('shown')).toHaveTextContent('none');
    await settle();
    expect(replayEmits()).toEqual([{ event: 'replay', payload: { index: 1 } }]);
    expect(screen.getByTestId('shown')).toHaveTextContent('2');
    expect(store.getState().replayState(1)).toEqual(at(1));
    expect(store.getState().replayVersion).toBe(1);

    // The same index again (slider away and back, or a direct call) is served from the cache.
    act(() => {
      fireEvent.change(slider, { target: { value: '3' } });
    });
    act(() => {
      fireEvent.change(slider, { target: { value: '1' } });
    });
    await settle();
    await act(async () => {
      await store.getState().ensureReplay(1);
    });
    expect(replayEmits()).toHaveLength(1);
    expect(screen.getByTestId('shown')).toHaveTextContent('2');
    // Index 0 (initial) and indexes at or after the join never need the server.
    await store.getState().ensureReplay(0);
    await store.getState().ensureReplay(3);
    expect(replayEmits()).toHaveLength(1);
    // The seat never moves while replaying.
    expect(store.getState().viewer).toBe('p2');
    expect(store.getState().pendingViewer).toBeNull();

    // Two concurrent requests for a new index share one emit.
    socket.replies.set('replay', { ok: true, value: at(2) });
    await Promise.all([store.getState().ensureReplay(2), store.getState().ensureReplay(2)]);
    expect(replayEmits()).toHaveLength(2);
    expect(store.getState().replayState(2).turn.rolled).toBe(3);
  });

  it('without a server initial state the slider starts at the join and nothing is requested', async () => {
    const socket = new FakeSocket();
    const store = createRemoteGameStore(socket, { storage: new MemoryStorage() });
    const actions: Action[] = [
      { type: 'rollDice', playerId: 'p1' },
      { type: 'endTurn', playerId: 'p1' },
    ];
    socket.replies.set('resume', { ok: true, value: { ...joinReply(game()), actions } });
    await store.getState().resume({ roomCode: 'ABC234', playerToken: 'tok-2', playerId: 'p2' });
    expect(store.getState().replayMin).toBe(2);
    await store.getState().ensureReplay(0);
    expect(socket.emitted.filter((e) => e.event === 'replay')).toHaveLength(0);
    expect(store.getState().replayState(0)).toBe(store.getState().snapshots[0]);
  });
});
