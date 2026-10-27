/**
 * App shell: wires the store to the board and the panels. Board interaction
 * rules live here (HANDOFF §6.3):
 *   - a panel's `nodePick` (build sites) wins over everything else;
 *   - during a space-jump pick, highlighted nodes are `legalJumpTargets`;
 *   - in flight.move, selecting one of the viewer's ships highlights
 *     `legalMoves` and clicking a highlighted node sends `moveShip` with the BFS path.
 */

import { WIN_VP, type NodeId, type ShipId } from '@starfarers/shared';
import { useMemo } from 'react';
import { Board } from './board/Board.js';
import { legalJumpTargets, legalMoves } from './board/legalMoves.js';
import { VpTrack } from './board/VpTrack.js';
import { ActionBar } from './panels/ActionBar.js';
import { BuildMenu } from './panels/BuildMenu.js';
import { EncounterModal } from './panels/EncounterModal.js';
import { FoundStationDialog } from './panels/FoundStationDialog.js';
import { FriendshipPanel } from './panels/FriendshipPanel.js';
import { HandPanel } from './panels/HandPanel.js';
import { LogPane } from './panels/LogPane.js';
import { MothershipPanel } from './panels/MothershipPanel.js';
import { PassBanner } from './panels/PassBanner.js';
import { SetupScreen } from './panels/SetupScreen.js';
import { SevenDialog } from './panels/SevenDialog.js';
import { TradePanel } from './panels/TradePanel.js';
import { useAct, useGame, useShownState } from './store/gameStore.js';
import { PLAYER_COLOR, playerName } from './ui/format.js';

export function App() {
  const state = useShownState();
  const live = useGame((s) => s.game);
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
  const act = useAct();

  const replaying = replayIndex !== null;
  const awaitingJump = state?.phase === 'flight.encounter' && state.turn.encounter?.awaiting?.kind === 'spaceJump' && state.turn.encounter.awaiting.playerId === viewer;

  const highlights = useMemo(() => {
    const m = new Map<NodeId, NodeId[] | null>();
    if (!state || replaying) return m;
    if (nodePick) {
      for (const n of nodePick.candidates) m.set(n, null);
      return m;
    }
    if (!selectedShip || state.board.ships[selectedShip]?.owner !== viewer) return m;
    if (awaitingJump) {
      for (const n of legalJumpTargets(state, selectedShip)) m.set(n, null);
      return m;
    }
    if (state.phase === 'flight.move' && state.activePlayer === viewer) return legalMoves(state, selectedShip);
    return m;
  }, [state, replaying, nodePick, selectedShip, viewer, awaitingJump]);

  if (!state || !live) return <SetupScreen />;

  const onNodeClick = (nodeId: NodeId) => {
    if (replaying || pendingViewer) return;
    if (nodePick) {
      if (nodePick.candidates.includes(nodeId)) nodePick.onPick(nodeId);
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

  const pendingFound = state.turn.pendingFound;
  const winner = state.winner;
  const hidden = pendingViewer !== null;

  return (
    <div className="app">
      <header className="topbar">
        <strong>Starfarers Online</strong>
        <span className="muted">seed {state.seed}</span>
        <span className="spacer" />
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
        <span className="swatch" style={{ background: PLAYER_COLOR[state.players.find((p) => p.id === viewer)?.color ?? 'white'] }} />
        <button type="button" className="link" onClick={() => setup && newGame({ ...setup, seed: `${setup.seed}-${Date.now().toString(36)}` })}>
          New game
        </button>
      </header>
      {error && (
        <div className="toast error" role="alert" data-testid="error-toast" onClick={clearError}>
          <strong>{error.code}</strong>: {error.message}
        </div>
      )}
      {replaying && <div className="toast info">Replay view — the board shows an earlier state. Use the slider in the log to return to live play.</div>}
      <main className="layout">
        <div className="board-col">
          <VpTrack state={state} />
          <Board state={state} viewer={viewer} highlights={highlights} selectedShip={selectedShip} onNodeClick={onNodeClick} onShipClick={onShipClick} />
          {viewer && !replaying && <ActionBar state={state} viewer={viewer} />}
        </div>
        <aside className="side">
          <HandPanel state={state} viewer={viewer} hidden={hidden} />
          {viewer && <MothershipPanel state={state} viewer={viewer} />}
          {viewer && !replaying && <BuildMenu state={state} viewer={viewer} />}
          {viewer && !replaying && <TradePanel state={state} viewer={viewer} />}
          {viewer && !replaying && <FriendshipPanel state={state} viewer={viewer} />}
          <LogPane state={state} />
        </aside>
      </main>
      {!replaying && viewer && !hidden && <SevenDialog state={state} viewer={viewer} />}
      {!replaying && viewer && !hidden && <EncounterModal state={state} viewer={viewer} />}
      {!replaying && viewer && !hidden && pendingFound && <FoundStationDialog state={state} viewer={viewer} shipId={pendingFound} />}
      {winner && (
        <div className="curtain" data-testid="game-over">
          <div className="curtain-card">
            <h2>{playerName(state, winner)} wins with {state.players.find((p) => p.id === winner)?.vp ?? WIN_VP} VP</h2>
            <button type="button" onClick={() => setup && newGame({ ...setup, seed: `${setup.seed}-${Date.now().toString(36)}` })}>
              Play again
            </button>
          </div>
        </div>
      )}
      <PassBanner state={state} />
    </div>
  );
}
