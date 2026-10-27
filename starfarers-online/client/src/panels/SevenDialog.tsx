import { discardCountFor, stealTargets, type GameState, type PlayerId, type ResourceBag } from '@starfarers/shared';
import { useState } from 'react';
import { useAct } from '../store/gameStore.js';
import { handBag, playerName } from '../ui/format.js';
import { BagPicker, bagToList } from './ResourcePicker.js';

/** 7-resolution: discard picker for players over the limit, then the steal target for the roller (spec §6). */
export function SevenDialog({ state, viewer }: { state: GameState; viewer: PlayerId }) {
  const act = useAct();
  const [discard, setDiscard] = useState<ResourceBag>({});
  const seven = state.turn.seven;
  if (!seven || state.phase !== 'production') return null;
  const me = state.players.find((p) => p.id === viewer);
  if (!me) return null;

  if (seven.awaitingDiscard.length > 0) {
    if (!seven.awaitingDiscard.includes(viewer)) {
      return (
        <div className="modal" data-testid="seven-dialog">
          <h3>A 7 was rolled</h3>
          <p>Waiting for {seven.awaitingDiscard.map((id) => playerName(state, id)).join(', ')} to discard.</p>
        </div>
      );
    }
    const need = discardCountFor(me.hand.length);
    const chosen = bagToList(discard);
    return (
      <div className="modal" data-testid="seven-dialog">
        <h3>A 7 was rolled — discard {need} cards</h3>
        <p className="muted">
          {me.name}, you hold {me.hand.length} cards. Choose exactly {need} to hand back to the supply.
        </p>
        <BagPicker value={discard} onChange={setDiscard} max={handBag(me.hand)} maxTotal={need} testId="discard" />
        <button
          type="button"
          data-testid="discard-confirm"
          disabled={chosen.length !== need}
          onClick={() => {
            if (act({ type: 'discardForSeven', cards: chosen })) setDiscard({});
          }}
        >
          Discard {chosen.length}/{need}
        </button>
      </div>
    );
  }

  if (!seven.stealDone && state.activePlayer === viewer) {
    const targets = stealTargets(state, viewer);
    return (
      <div className="modal" data-testid="seven-dialog">
        <h3>A 7 was rolled — steal a card</h3>
        {targets.length === 0 ? (
          <p className="muted">Nobody holds a card to steal; the engine resolved this automatically.</p>
        ) : (
          <div className="row">
            {targets.map((id) => (
              <button key={id} type="button" data-testid={`steal-${id}`} onClick={() => act({ type: 'stealForSeven', target: id })}>
                Steal from {playerName(state, id)}
              </button>
            ))}
          </div>
        )}
      </div>
    );
  }
  return null;
}
