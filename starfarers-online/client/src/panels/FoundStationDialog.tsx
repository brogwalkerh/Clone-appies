import { FRIENDSHIP_CARDS, canFoundTradeStation, outpostAtNode, pickableFriendshipCards, type GameState, type PlayerId, type ShipId } from '@starfarers/shared';
import { useState } from 'react';
import { useAct } from '../store/gameStore.js';
import { CIV_LABEL, playerName } from '../ui/format.js';
import { focusDialog } from '../ui/keyboard.js';

/** Dock + friendship-card pick for a trade ship on a docking point (spec §9.5). */
export function FoundStationDialog({ state, viewer, shipId }: { state: GameState; viewer: PlayerId; shipId: ShipId }) {
  const act = useAct();
  const [dock, setDock] = useState<number | null>(null);
  const [card, setCard] = useState<string | null>(null);
  const ship = state.board.ships[shipId];
  if (!ship || state.activePlayer !== viewer) return null;
  const outpost = outpostAtNode(state.board, ship.nodeId);
  if (!outpost?.civ || !outpost.docks) return null;
  const blocked = canFoundTradeStation(state, shipId, ship.nodeId);
  const cards = pickableFriendshipCards(state, outpost.civ);
  const freeDocks = outpost.docks.map((o, i) => [o, i] as const).filter(([o]) => o === null).map(([, i]) => i);
  const chosenDock = dock ?? freeDocks[0] ?? null;
  const chosenCard = card ?? cards[0] ?? null;
  return (
    <div className="modal" data-testid="found-station-dialog" role="dialog" aria-label="Found a trade station" ref={focusDialog}>
      <h3>Found a trade station at the {CIV_LABEL[outpost.civ]} outpost</h3>
      {blocked && <p className="error">{blocked.message}</p>}
      <div>
        <span className="muted">Dock:</span>
        <div className="row">
          {outpost.docks.map((owner, i) => (
            <button key={i} type="button" data-testid={`dock-choice-${i}`} disabled={owner !== null} className={chosenDock === i ? 'selected' : ''} onClick={() => setDock(i)}>
              {i + 1} {owner ? `(${playerName(state, owner)})` : ''}
            </button>
          ))}
        </div>
      </div>
      <div>
        <span className="muted">Friendship card:</span>
        <ul className="friendship-list">
          {cards.map((id) => (
            <li key={id}>
              <label>
                <input type="radio" name="friendship" checked={chosenCard === id} onChange={() => setCard(id)} data-testid={`card-choice-${id}`} /> {FRIENDSHIP_CARDS[id].name}
              </label>
            </li>
          ))}
        </ul>
      </div>
      <button
        type="button"
        data-testid="found-station-confirm"
        disabled={blocked !== null || chosenDock === null || chosenCard === null}
        onClick={() => chosenDock !== null && chosenCard !== null && act({ type: 'foundTradeStation', shipId, dockIndex: chosenDock, friendshipCardId: chosenCard as (typeof cards)[number] })}
      >
        Found station
      </button>
    </div>
  );
}
