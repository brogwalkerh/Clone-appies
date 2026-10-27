/**
 * Advanced set-up draft in the client (spec §3.4): the start-mode pickers
 * (hot-seat screen and room lobby), the board highlights for rounds 1–3, the
 * pass-the-laptop hand-over between drafters, and the round-4 DraftPanel.
 */

import type { ClientToServerEvents, LobbyView, ServerToClientEvents } from '@starfarers/shared';
import { createGame, draftSpaceportCandidates, draftableSites, isOccupied, spaceportSites } from '@starfarers/shared';
import { act, render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, it } from 'vitest';
import { GameScreen } from '../src/App.js';
import { createRemoteGameStore, type SocketLike } from '../src/net/remoteStore.js';
import type { SessionStorageLike } from '../src/net/session.js';
import { RoomLobby } from '../src/panels/OnlineLobby.js';
import { SetupScreen } from '../src/panels/SetupScreen.js';
import { StoreContext, createGameStore, requiredViewer, type GameStore } from '../src/store/gameStore.js';
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

function lobby(hostId: string, setup: 'preset' | 'draft' = 'preset'): LobbyView {
  return {
    code: 'DRAFT1',
    name: 'Test',
    players: [
      { id: 'p1', name: 'Ann', color: 'red', connected: true, isHost: hostId === 'p1' },
      { id: 'p2', name: 'Bob', color: 'blue', connected: true, isHost: hostId === 'p2' },
      { id: 'p3', name: 'Cid', color: 'yellow', connected: true, isHost: hostId === 'p3' },
    ],
    hostId,
    started: false,
    config: { turnTimerSeconds: null, variant: 'beginner', setup },
    messages: [],
    minPlayers: 3,
    maxPlayers: 4,
  };
}

function renderGame(store: GameStore) {
  return render(
    <StoreContext.Provider value={store}>
      <GameScreen />
    </StoreContext.Provider>,
  );
}

describe('start-mode pickers', () => {
  it('hot-seat: setup-select defaults to preset and starts a drafted game', async () => {
    const store = createGameStore();
    render(
      <StoreContext.Provider value={store}>
        <SetupScreen />
      </StoreContext.Provider>,
    );
    const select = screen.getByTestId('setup-select') as HTMLSelectElement;
    expect(select.value).toBe('preset');
    expect([...select.options].map((o) => o.value)).toEqual(['preset', 'draft']);
    await userEvent.selectOptions(select, 'draft');
    expect(screen.getByTestId('setup-description')).toHaveTextContent(/snake draft/i);
    await userEvent.selectOptions(screen.getByTestId('variant-select'), 'strategic');
    await userEvent.clear(screen.getByTestId('seed'));
    await userEvent.type(screen.getByTestId('seed'), 'drafted');
    await userEvent.click(screen.getByTestId('start-game'));
    const game = store.getState().game!;
    expect(game.setup).toBe('draft');
    expect(game.variant).toBe('strategic');
    expect(game.phase).toBe('setup');
    expect(store.getState().setup?.setup).toBe('draft');
    expect(store.getState().viewer).toBe(game.activePlayer);
    expect(game).toEqual(createGame({ variant: 'strategic', setup: 'draft', players: game.players.map((p) => ({ id: p.id, name: p.name, color: p.color })), seed: 'drafted' }));
  });

  it('lobby: the host changes the start mode through configureRoom; guests see it read-only', async () => {
    const socket = new FakeSocket();
    const store = createRemoteGameStore(socket, { storage: new MemoryStorage() });
    store.setState({ session: { roomCode: 'DRAFT1', playerToken: 't', playerId: 'p1' }, lobby: lobby('p1') });
    const { unmount } = render(<RoomLobby store={store} />);
    const select = screen.getByTestId('setup-select') as HTMLSelectElement;
    expect(select).toBeEnabled();
    expect(select.value).toBe('preset');
    expect(screen.getByTestId('lobby-setup')).toHaveTextContent(/Preset start/);
    await userEvent.selectOptions(select, 'draft');
    expect(socket.emitted.at(-1)).toEqual({ event: 'configureRoom', payload: { setup: 'draft' } });
    // The variant picker still sends only the variant.
    await userEvent.selectOptions(screen.getByTestId('variant-select'), 'wild');
    expect(socket.emitted.at(-1)).toEqual({ event: 'configureRoom', payload: { variant: 'wild' } });
    act(() => socket.fire('lobby', lobby('p1', 'draft')));
    expect((screen.getByTestId('setup-select') as HTMLSelectElement).value).toBe('draft');
    expect(screen.getByTestId('lobby-setup')).toHaveTextContent(/Set-up draft/);
    unmount();

    const guestSocket = new FakeSocket();
    const guest = createRemoteGameStore(guestSocket, { storage: new MemoryStorage() });
    guest.setState({ session: { roomCode: 'DRAFT1', playerToken: 't2', playerId: 'p2' }, lobby: lobby('p1', 'draft') });
    render(<RoomLobby store={guest} />);
    expect(screen.getByTestId('setup-select')).toBeDisabled();
    expect(screen.getByTestId('lobby-setup')).toHaveTextContent(/Set-up draft/);
    expect(screen.getByTestId('lobby-setup')).toHaveTextContent(/host chooses/);
    expect(guestSocket.emitted.filter((e) => e.event === 'configureRoom')).toHaveLength(0);
  });
});

describe('playing the draft on the hot-seat game screen', () => {
  it('rounds 1–3: highlights the free Catanian sites for the drafter only, a click drafts, the laptop passes on', async () => {
    const store = createGameStore();
    store.getState().newGame({ players: PLAYERS, seed: 'client-draft', setup: 'draft' });
    const start = store.getState().game!;
    expect(start.phase).toBe('setup');
    expect(requiredViewer(start, null)).toBe(start.activePlayer);
    const { container } = renderGame(store);

    // No roll button, a set-up label, hand / mothership / build panels render for a player with nothing on the board.
    expect(screen.queryByTestId('action-roll')).toBeNull();
    expect(screen.getByTestId('phase-label')).toHaveTextContent(/Set-up: round 1 · \w+ places a colony/);
    expect(screen.getByTestId('hand-panel')).toHaveTextContent('0 cards');
    expect(screen.getByTestId('mothership-panel')).toBeInTheDocument();
    expect(screen.getByTestId('build-menu')).toBeInTheDocument();
    expect(screen.getByTestId('vp-track')).toBeInTheDocument();
    expect(screen.queryByTestId('draft-panel')).toBeNull();

    const sites = draftableSites(start);
    expect(sites).toHaveLength(12);
    const highlighted = [...container.querySelectorAll('[data-highlight="true"]')].map((el) => el.getAttribute('data-testid'));
    expect(highlighted.sort()).toEqual(sites.map((n) => `node-${n}`).sort());

    // A non-site click does nothing; a highlighted site drafts a colony.
    await userEvent.click(screen.getByTestId('node-N(5,1)'));
    expect(store.getState().actions).toHaveLength(0);
    const picker = start.activePlayer;
    await userEvent.click(screen.getByTestId(`node-${sites[0]}`));
    const after = store.getState().game!;
    expect(store.getState().actions).toEqual([{ type: 'draftColony', playerId: picker, siteId: sites[0] }]);
    expect(after.board.settlements[sites[0]!]).toMatchObject({ kind: 'colony', owner: picker });
    expect(screen.getByTestId(`settlement-${sites[0]}`)).toBeInTheDocument();

    // The next drafter must take the seat first; meanwhile nothing is highlighted and clicks are ignored.
    expect(store.getState().pendingViewer).toBe(after.activePlayer);
    expect(screen.getByTestId('pass-banner')).toBeInTheDocument();
    expect(container.querySelectorAll('[data-highlight="true"]')).toHaveLength(0);
    await userEvent.click(screen.getByTestId(`node-${sites[1]}`));
    expect(store.getState().actions).toHaveLength(1);
    await userEvent.click(screen.getByTestId('take-seat'));
    expect(store.getState().viewer).toBe(after.activePlayer);
    expect(container.querySelectorAll('[data-highlight="true"]')).toHaveLength(11);
    expect(screen.getByTestId(`node-${sites[0]}`)).not.toHaveAttribute('data-highlight');
    await userEvent.click(screen.getByTestId(`node-${sites[1]}`));
    expect(store.getState().game!.board.settlements[sites[1]!]?.owner).toBe(after.activePlayer);
    expect(store.getState().game!.draft?.index).toBe(2);
  });

  it('round 4: the DraftPanel picks the spaceport, ship kind, site and upgrade and confirms one draftFinish', async () => {
    const store = createGameStore();
    store.getState().newGame({ players: PLAYERS, seed: 'client-draft-4' });
    // Jump to round 4 through the store (9 colony picks), handing the laptop over each time.
    store.getState().newGame({ players: PLAYERS, seed: 'client-draft-4', setup: 'draft' });
    for (let i = 0; i < 9; i++) {
      const g = store.getState().game!;
      expect(store.getState().dispatch({ type: 'draftColony', playerId: g.activePlayer, siteId: draftableSites(g)[0]! })).toBe(true);
      store.getState().acknowledgeViewer();
    }
    const r4 = store.getState().game!;
    expect(r4.draft?.round).toBe(4);
    const me = r4.activePlayer;
    expect(store.getState().viewer).toBe(me);
    const { container } = renderGame(store);
    expect(screen.getByTestId('phase-label')).toHaveTextContent(/Set-up: round 4/);
    expect(container.querySelectorAll('[data-highlight="true"]')).toHaveLength(0);
    const panel = screen.getByTestId('draft-panel');
    expect(panel).toBeInTheDocument();

    const candidates = draftSpaceportCandidates(r4, me);
    expect(candidates).toHaveLength(3);
    for (const n of candidates) expect(screen.getByTestId(`draft-spaceport-${n}`)).toBeInTheDocument();
    const chosen = candidates[2]!;
    await userEvent.click(screen.getByTestId(`draft-spaceport-${chosen}`));
    const sites = spaceportSites(r4.board, chosen).filter((n) => !isOccupied(r4.board, n));
    expect(sites.length).toBeGreaterThan(0);
    for (const n of sites) expect(screen.getByTestId(`draft-ship-site-${n}`)).toBeInTheDocument();
    const site = sites[sites.length - 1]!;
    await userEvent.click(screen.getByTestId(`draft-ship-site-${site}`));
    await userEvent.click(screen.getByTestId('draft-ship-trade'));
    expect(screen.getByTestId('draft-upgrade-booster')).toHaveTextContent(/Booster/);
    await userEvent.click(screen.getByTestId('draft-upgrade-cannon'));
    await userEvent.click(screen.getByTestId('draft-confirm'));

    expect(store.getState().actions.at(-1)).toEqual({ type: 'draftFinish', playerId: me, spaceportSiteId: chosen, ship: 'trade', shipSiteId: site, upgrade: 'cannon' });
    const after = store.getState().game!;
    expect(after.board.settlements[chosen]).toMatchObject({ kind: 'spaceport', owner: me });
    const ship = Object.values(after.board.ships).find((s) => s.owner === me)!;
    expect(ship).toMatchObject({ kind: 'trade', nodeId: site });
    expect(after.players.find((p) => p.id === me)!.mothership.cannons).toBe(1);
    expect(after.draft?.pool).toEqual(['booster', 'freightPod']);
    expect(after.activePlayer).not.toBe(me);
    // The panel is gone for the previous drafter; the laptop goes to the next one.
    expect(screen.queryByTestId('draft-panel')).toBeNull();
    expect(store.getState().pendingViewer).toBe(after.activePlayer);
    await userEvent.click(screen.getByTestId('take-seat'));
    expect(screen.getByTestId('draft-panel')).toBeInTheDocument();
    // A gone upgrade is no longer offered.
    expect(screen.queryByTestId('draft-upgrade-cannon')).toBeNull();
  });
});
