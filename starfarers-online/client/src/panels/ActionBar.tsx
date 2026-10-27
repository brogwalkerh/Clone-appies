import { canFoundColony, isColonyRound, reserveDrawFor, shipsOf, type GameState, type PlayerId } from '@starfarers/shared';
import { useAct, useGame } from '../store/gameStore.js';
import { phaseLabel, playerName } from '../ui/format.js';

/** Phase-driven actions (HANDOFF §6.5): only what ACTION_POLICY + preconditions allow for the viewer right now. */
export function ActionBar({ state, viewer }: { state: GameState; viewer: PlayerId }) {
  const act = useAct();
  const selectedShip = useGame((s) => s.selectedShip);
  const me = state.players.find((p) => p.id === viewer);
  if (!me) return null;
  const isActive = state.activePlayer === viewer;
  const ships = shipsOf(state, viewer);
  const sevenPending = state.turn.seven !== undefined && state.phase === 'production' && (state.turn.seven.awaitingDiscard.length > 0 || !state.turn.seven.stealDone);
  const buttons: { id: string; label: string; onClick(): void }[] = [];

  if (isActive && state.phase !== 'gameOver') {
    if (state.phase === 'production' && state.turn.rolled === undefined) {
      buttons.push({ id: 'roll', label: 'Roll dice', onClick: () => act({ type: 'rollDice' }) });
    }
    const draw = reserveDrawFor(me.vp);
    if ((state.phase === 'production' || state.phase === 'tradeBuild') && state.turn.rolled !== undefined && !sevenPending && !state.turn.reserveDrawTaken && draw > 0) {
      buttons.push({ id: 'reserve', label: `Take ${draw} reserve card${draw === 1 ? '' : 's'}`, onClick: () => act({ type: 'takeReserveDraw' }) });
    }
    if (state.phase === 'tradeBuild' && ships.length > 0 && state.turn.baseSpeed === undefined) {
      buttons.push({ id: 'shake', label: 'Shake the mothership', onClick: () => act({ type: 'shakeMothership' }) });
    }
    if (state.phase === 'flight.move' && state.turn.pendingFound === undefined) {
      for (const ship of ships) {
        if (ship.kind === 'colony' && canFoundColony(state, ship.id) === null) {
          buttons.push({ id: `found-${ship.id}`, label: `Found colony with ${ship.id}`, onClick: () => act({ type: 'foundColony', shipId: ship.id }) });
        }
      }
    }
    if ((state.phase === 'tradeBuild' && ships.length === 0) || state.phase === 'flight.move') {
      buttons.push({ id: 'end', label: 'End turn', onClick: () => act({ type: 'endTurn' }) });
    }
  }

  const draft = state.phase === 'setup' ? state.draft : undefined;
  return (
    <div className="action-bar" data-testid="action-bar">
      <span className="phase" data-testid="phase-label">
        {draft ? (
          <>
            Set-up: round {draft.round} · {playerName(state, state.activePlayer)}{' '}
            {isColonyRound(draft) ? 'places a colony' : 'upgrades a colony to a spaceport, places a ship and takes an upgrade'}
            {isActive && isColonyRound(draft) && ' — click a highlighted Catanian site'}
          </>
        ) : (
          <>
            Turn {state.turnNumber} · {phaseLabel(state.phase)} · {playerName(state, state.activePlayer)}
            {state.phase === 'flight.move' && isActive && state.turn.speed !== undefined && ` · speed ${state.turn.speed}`}
            {selectedShip && ` · selected ${selectedShip}`}
          </>
        )}
      </span>
      {!isActive && state.phase !== 'gameOver' && <span className="muted">Waiting for {playerName(state, state.activePlayer)}</span>}
      {buttons.map((b) => (
        <button key={b.id} type="button" data-testid={`action-${b.id}`} onClick={b.onClick}>
          {b.label}
        </button>
      ))}
    </div>
  );
}
