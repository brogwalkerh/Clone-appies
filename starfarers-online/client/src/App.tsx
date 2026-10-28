/**
 * App shell with hash routing:
 *   #/            home: hot-seat or online
 *   #/local       hot-seat game (store: gameStore)
 *   #/online      create / join / rejoin a room
 *   #/room/CODE   room lobby, then the online game (store: remoteStore)
 *
 * `GameScreen` is store-agnostic: it reads through the StoreContext, so the
 * same board and panels serve both modes. Board interaction rules live here
 * (HANDOFF §6.3):
 *   - a panel's `nodePick` (build sites) wins over everything else;
 *   - during a space-jump pick, highlighted nodes are `legalJumpTargets`;
 *   - in flight.move, selecting one of the viewer's ships highlights
 *     `legalMoves` and clicking a highlighted node sends `moveShip` with the BFS path;
 *   - in phase 'setup' (advanced draft, spec §3.4) rounds 1–3 highlight the free
 *     Catanian sites for the current drafter and a click sends `draftColony`;
 *     round 4 opens the `DraftPanel`.
 */

import { WIN_VP, draftableSites, isColonyRound, shipsOf, type NodeId, type ShipId } from '@starfarers/shared';
import { useEffect, useMemo, useState } from 'react';
import { useStore } from 'zustand';
import { Board } from './board/Board.js';
import { legalJumpTargets, legalMoves } from './board/legalMoves.js';
import { useBoardMotion } from './board/motion.js';
import { VpTrack } from './board/VpTrack.js';
import type { RemoteStore } from './net/remoteStore.js';
import { remoteStore } from './net/socket.js';
import { ActionBar } from './panels/ActionBar.js';
import { BuildMenu } from './panels/BuildMenu.js';
import { ChatPanel } from './panels/ChatPanel.js';
import { DraftPanel } from './panels/DraftPanel.js';
import { EncounterModal } from './panels/EncounterModal.js';
import { FoundStationDialog } from './panels/FoundStationDialog.js';
import { FriendshipPanel } from './panels/FriendshipPanel.js';
import { HandPanel } from './panels/HandPanel.js';
import { LogPane } from './panels/LogPane.js';
import { MothershipPanel } from './panels/MothershipPanel.js';
import { JoinScreen, RoomLobby, navigate } from './panels/OnlineLobby.js';
import { PassBanner } from './panels/PassBanner.js';
import { SetupScreen } from './panels/SetupScreen.js';
import { SevenDialog } from './panels/SevenDialog.js';
import { TradePanel } from './panels/TradePanel.js';
import { GameHostControls } from './panels/HostControls.js';
import { TurnTimer } from './panels/TurnTimer.js';
import { StoreContext, gameStore, useAct, useGame, useShownState, type GameStore } from './store/gameStore.js';
import { PLAYER_COLOR, playerName } from './ui/format.js';
import { useEscape } from './ui/keyboard.js';
import { COARSE_QUERY, PHONE_QUERY, useMediaQuery } from './ui/media.js';

/** Phone tab bar (spec §14, HANDOFF §8.9a): one sidebar panel open at a time as a sheet. */
type PanelTab = 'hand' | 'ship' | 'build' | 'trade' | 'cards' | 'log' | 'chat';
const TAB_LABEL: Record<PanelTab, string> = { hand: 'Hand', ship: 'Ship', build: 'Build', trade: 'Trade', cards: 'Cards', log: 'Log', chat: 'Chat' };

export interface GameScreenProps {
  /** Extra sidebar content (the online chat). */
  extraPanels?: React.ReactNode;
  /** Header text instead of the seed (the room code online). */
  subtitle?: string | undefined;
  /** Extra header content (the online turn timer). */
  headerExtra?: React.ReactNode;
}

export function GameScreen({ extraPanels, subtitle, headerExtra }: GameScreenProps) {
  const state = useShownState();
  const live = useGame((s) => s.game);
  const mode = useGame((s) => s.mode);
  const viewer = useGame((s) => s.viewer);
  const pendingViewer = useGame((s) => s.pendingViewer);
  const error = useGame((s) => s.error);
  const clearError = useGame((s) => s.clearError);
  const selectedShip = useGame((s) => s.selectedShip);
  const selectShip = useGame((s) => s.selectShip);
  const nodePick = useGame((s) => s.nodePick);
  const takeSeat = useGame((s) => s.takeSeat);
  const replayIndex = useGame((s) => s.replayIndex);
  const newGame = useGame((s) => s.newGame);
  const setup = useGame((s) => s.setup);
  const setNodePick = useGame((s) => s.setNodePick);
  const act = useAct();
  const motion = useBoardMotion();
  const phone = useMediaQuery(PHONE_QUERY);
  const coarse = useMediaQuery(COARSE_QUERY);
  const [tab, setTab] = useState<PanelTab | null>(null);
  // Touch: the first tap on a highlighted node arms it (path preview + confirm bar), the second commits.
  const [armed, setArmed] = useState<NodeId | null>(null);

  const replaying = replayIndex !== null;
  const awaitingJump = state?.phase === 'flight.encounter' && state.turn.encounter?.awaiting?.kind === 'spaceJump' && state.turn.encounter.awaiting.playerId === viewer;
  const draftingColony = state?.phase === 'setup' && state.draft !== undefined && isColonyRound(state.draft) && state.activePlayer === viewer;
  const draftingFinish = state?.phase === 'setup' && state.draft !== undefined && !isColonyRound(state.draft) && state.activePlayer === viewer;

  const highlights = useMemo(() => {
    const m = new Map<NodeId, NodeId[] | null>();
    if (!state || replaying) return m;
    if (nodePick) {
      for (const n of nodePick.candidates) m.set(n, null);
      return m;
    }
    if (draftingColony) {
      for (const n of draftableSites(state)) m.set(n, null);
      return m;
    }
    if (!selectedShip || state.board.ships[selectedShip]?.owner !== viewer) return m;
    if (awaitingJump) {
      for (const n of legalJumpTargets(state, selectedShip)) m.set(n, null);
      return m;
    }
    if (state.phase === 'flight.move' && state.activePlayer === viewer) return legalMoves(state, selectedShip);
    return m;
  }, [state, replaying, nodePick, selectedShip, viewer, awaitingJump, draftingColony]);

  useEffect(() => setArmed(null), [highlights]);

  // Escape (ui/keyboard.ts): disarm a touch pick, cancel a build site pick, deselect the ship, close the
  // phone panel sheet, else dismiss the error toast.
  useEscape(() => {
    if (armed) {
      setArmed(null);
      return true;
    }
    if (nodePick) {
      setNodePick(null);
      return true;
    }
    if (selectedShip) {
      selectShip(null);
      return true;
    }
    if (tab) {
      setTab(null);
      return true;
    }
    if (error) {
      clearError();
      return true;
    }
    return false;
  });

  if (!state || !live) return null;

  const shipsSelectable =
    !replaying && !pendingViewer && !nodePick && (awaitingJump || (state.phase === 'flight.move' && state.activePlayer === viewer && state.turn.pendingFound === undefined));
  const onNodeClick = (nodeId: NodeId) => {
    if (replaying || pendingViewer) return;
    if (coarse && highlights.has(nodeId) && armed !== nodeId) {
      setArmed(nodeId);
      return;
    }
    setArmed(null);
    commitNode(nodeId);
  };
  const commitNode = (nodeId: NodeId) => {
    if (nodePick) {
      if (nodePick.candidates.includes(nodeId)) nodePick.onPick(nodeId);
      return;
    }
    if (state.phase === 'setup') {
      if (draftingColony && highlights.has(nodeId)) act({ type: 'draftColony', siteId: nodeId });
      return;
    }
    if (selectedShip && highlights.has(nodeId)) {
      if (awaitingJump) act({ type: 'encounterPick', shipId: selectedShip, targetNodeId: nodeId });
      else act({ type: 'moveShip', shipId: selectedShip, path: highlights.get(nodeId) ?? [] });
      return;
    }
    selectShip(null);
  };
  const onShipClick = (shipId: ShipId) => {
    if (replaying || pendingViewer) return;
    selectShip(selectedShip === shipId ? null : shipId);
  };
  const armedVerb = !armed ? '' : nodePick ? 'Build here' : draftingColony ? 'Place colony here' : awaitingJump ? 'Jump here' : 'Move here';
  const armedSteps = armed ? highlights.get(armed)?.length : undefined;
  // Ships are about 7 px wide on a phone before zooming, so touch players pick them from a list too.
  const myShips = viewer && shipsSelectable && coarse ? shipsOf(state, viewer) : [];
  const tradeWaiting = viewer !== null && state.openTrade?.to === viewer;
  const tabs: PanelTab[] = ['hand', 'ship', 'build', 'trade', 'cards', 'log', ...(extraPanels ? (['chat'] as const) : [])];
  const pane = (id: PanelTab) => (tab === id ? 'tab-pane open' : 'tab-pane');

  const pendingFound = state.turn.pendingFound;
  const winner = state.winner;
  const hidden = pendingViewer !== null;
  const restart = () => setup && newGame({ ...setup, seed: `${setup.seed}-${Date.now().toString(36)}` });
  // Mid-game the header link would throw the game away on one stray click, so it asks first.
  const confirmRestart = () => {
    if (winner || window.confirm('Start a new game? The current game will be lost.')) restart();
  };

  return (
    <div className={phone ? `app phone${tab ? ' sheet-open' : ''}` : 'app'}>
      <header className="topbar">
        <h1 className="brand">Starfarers Online</h1>
        <span className={subtitle ? 'muted' : 'muted seed'}>{subtitle ?? `seed ${state.seed}`}</span>
        {headerExtra}
        <span className="spacer" />
        {mode === 'local' ? (
          <label>
            Seat{' '}
            <select value={viewer ?? ''} onChange={(e) => takeSeat(e.target.value)} data-testid="seat-select" disabled={hidden}>
              {state.players.map((p) => (
                <option key={p.id} value={p.id}>
                  {p.name}
                </option>
              ))}
            </select>
          </label>
        ) : (
          <span data-testid="viewer-name">You are {playerName(state, viewer)}</span>
        )}
        <span className="swatch" style={{ background: PLAYER_COLOR[state.players.find((p) => p.id === viewer)?.color ?? 'white'] }} />
        {mode === 'local' ? (
          <button type="button" className="link" onClick={confirmRestart} data-testid="new-game">
            New game
          </button>
        ) : (
          <button type="button" className="link" onClick={() => navigate('#/online')}>
            Lobby
          </button>
        )}
      </header>
      {error && (
        <div className="toast error" role="alert" data-testid="error-toast" onClick={clearError}>
          <strong>{error.code}</strong>: {error.message}
        </div>
      )}
      {replaying && <div className="toast info">Replay view — the board shows an earlier state. Use the slider in the log to return to live play.</div>}
      <main className="layout">
        <div className="board-col">
          <VpTrack state={state} motion={motion} />
          <Board
            state={state}
            viewer={viewer}
            highlights={highlights}
            selectedShip={selectedShip}
            onNodeClick={onNodeClick}
            onShipClick={onShipClick}
            motion={motion}
            shipsSelectable={shipsSelectable}
            armedNode={armed}
          />
          {armed && (
            <div className="confirm-bar" data-testid="confirm-bar">
              <span className="muted">{armedSteps ? `${armedSteps} step${armedSteps === 1 ? '' : 's'}` : 'Selected spot'}</span>
              <span className="spacer" />
              <button type="button" onClick={() => setArmed(null)} data-testid="cancel-pick">
                Cancel
              </button>
              <button type="button" className="primary" onClick={() => onNodeClick(armed)} data-testid="confirm-pick">
                {armedVerb}
              </button>
            </div>
          )}
          {myShips.length > 0 && (
            <div className="ship-picker" role="group" aria-label="Your ships" data-testid="ship-picker">
              {myShips.map((ship) => (
                <button
                  key={ship.id}
                  type="button"
                  aria-pressed={selectedShip === ship.id}
                  className={selectedShip === ship.id ? 'selected' : undefined}
                  data-testid={`pick-ship-${ship.id}`}
                  onClick={() => onShipClick(ship.id)}
                >
                  {ship.kind === 'colony' ? 'Colony ship' : 'Trade ship'} {ship.id.split(':').pop()}
                </button>
              ))}
            </div>
          )}
          {viewer && !replaying && <ActionBar state={state} viewer={viewer} />}
        </div>
        <aside className="side" aria-label={phone && tab ? TAB_LABEL[tab] : undefined}>
          <div className={pane('hand')}>
            <HandPanel state={state} viewer={viewer} hidden={hidden} />
          </div>
          <div className={pane('ship')}>{viewer && <MothershipPanel state={state} viewer={viewer} />}</div>
          <div className={pane('build')}>{viewer && !replaying && <BuildMenu state={state} viewer={viewer} />}</div>
          <div className={pane('trade')}>{viewer && !replaying && <TradePanel state={state} viewer={viewer} />}</div>
          <div className={pane('cards')}>{viewer && !replaying && <FriendshipPanel state={state} viewer={viewer} />}</div>
          {extraPanels && <div className={pane('chat')}>{extraPanels}</div>}
          <div className={pane('log')}>
            <LogPane state={state} />
          </div>
        </aside>
      </main>
      {phone && (
        <nav className="phone-tabs" aria-label="Panels" data-testid="phone-tabs">
          {tabs.map((id) => (
            <button
              key={id}
              type="button"
              aria-pressed={tab === id}
              className={tab === id ? 'selected' : undefined}
              data-testid={`tab-${id}`}
              onClick={() => setTab(tab === id ? null : id)}
            >
              {TAB_LABEL[id]}
              {id === 'trade' && tradeWaiting && (
                <span className="badge" data-testid="tab-trade-badge">
                  <span className="visually-hidden">: an offer is waiting</span>
                </span>
              )}
            </button>
          ))}
        </nav>
      )}
      {!replaying && viewer && !hidden && <SevenDialog state={state} viewer={viewer} />}
      {!replaying && viewer && !hidden && <EncounterModal state={state} viewer={viewer} />}
      {!replaying && viewer && !hidden && pendingFound && <FoundStationDialog state={state} viewer={viewer} shipId={pendingFound} />}
      {!replaying && viewer && !hidden && draftingFinish && <DraftPanel state={state} viewer={viewer} />}
      {winner && (
        <div className="curtain" data-testid="game-over">
          <div className="curtain-card">
            <h2>
              {playerName(state, winner)} wins with {state.players.find((p) => p.id === winner)?.vp ?? WIN_VP} VP
            </h2>
            {mode === 'local' ? (
              <button type="button" onClick={restart}>
                Play again
              </button>
            ) : (
              <button type="button" onClick={() => navigate('#/online')}>
                Back to the lobby
              </button>
            )}
          </div>
        </div>
      )}
      <PassBanner state={state} />
    </div>
  );
}

function LocalRoute() {
  const game = useStore(gameStore, (s) => s.game);
  return (
    <StoreContext.Provider value={gameStore}>
      {game ? <GameScreen /> : <SetupScreen />}
      {!game && (
        <p className="centered">
          <button type="button" className="link" onClick={() => navigate('#/')}>
            back
          </button>
        </p>
      )}
    </StoreContext.Provider>
  );
}

function RoomRoute({ store, code }: { store: RemoteStore; code: string }) {
  const session = useStore(store, (s) => s.session);
  const lobby = useStore(store, (s) => s.lobby);
  const game = useStore(store, (s) => s.game);
  const [tried, setTried] = useState(false);
  const inThisRoom = session?.roomCode === code && lobby !== null;

  // Page load / reload: resume with the saved token when it belongs to this room.
  useEffect(() => {
    if (inThisRoom || tried) return;
    setTried(true);
    if (session && session.roomCode === code) void store.getState().resume(session);
  }, [inThisRoom, tried, session, code, store]);

  if (!inThisRoom) {
    if (session && session.roomCode === code && !tried) return <p className="centered muted">Rejoining {code}…</p>;
    return <JoinScreen store={store} prefillCode={code} />;
  }
  if (!lobby.started || !game) return <RoomLobby store={store} />;
  return (
    <StoreContext.Provider value={store as unknown as GameStore}>
      <GameScreen subtitle={`room ${code}`} headerExtra={<><TurnTimer store={store} /><GameHostControls store={store} /></>} extraPanels={<ChatPanel store={store} />} />
    </StoreContext.Provider>
  );
}

function Home() {
  return (
    <div className="setup" data-testid="home">
      <h1>Starfarers Online</h1>
      <p className="muted">A space-colonisation board game. No official art, names or logos; working title.</p>
      <div className="row">
        <button type="button" data-testid="go-local" onClick={() => navigate('#/local')}>
          Hot-seat (one screen)
        </button>
        <button type="button" data-testid="go-online" onClick={() => navigate('#/online')}>
          Play online
        </button>
      </div>
    </div>
  );
}

function useHash(): string {
  const [hash, setHash] = useState(() => window.location.hash || '#/');
  useEffect(() => {
    const onChange = () => setHash(window.location.hash || '#/');
    window.addEventListener('hashchange', onChange);
    return () => window.removeEventListener('hashchange', onChange);
  }, []);
  return hash;
}

const TITLES: [prefix: string, title: string][] = [
  ['#/local', 'Hot-seat'],
  ['#/room/', 'Room'],
  ['#/online', 'Play online'],
];

export function App() {
  const hash = useHash();
  const section = TITLES.find(([prefix]) => hash.startsWith(prefix))?.[1];
  useEffect(() => {
    document.title = section ? `${section} — Starfarers Online` : 'Starfarers Online';
  }, [section]);
  if (hash.startsWith('#/local')) return <LocalRoute />;
  if (hash.startsWith('#/room/')) {
    const code = decodeURIComponent(hash.slice('#/room/'.length)).toUpperCase().slice(0, 6);
    return <RoomRoute store={remoteStore()} code={code} />;
  }
  if (hash.startsWith('#/online')) return <JoinScreen store={remoteStore()} />;
  return <Home />;
}
