import {
  MAX_OFFER,
  encounterCard,
  visibleEncounterText,
  type EncounterPickRequest,
  type GameState,
  type PlayerId,
  type ResourceBag,
  type UpgradeKind,
} from '@starfarers/shared';
import { useState } from 'react';
import { useAct, useGame } from '../store/gameStore.js';
import { handBag, playerName } from '../ui/format.js';
import { BagPicker, bagToList } from './ResourcePicker.js';

const UPGRADE_LABEL: Record<UpgradeKind, string> = { booster: 'Booster', cannon: 'Cannon', freightPod: 'Freight pod' };

function Pick({ state, viewer, awaiting }: { state: GameState; viewer: PlayerId; awaiting: EncounterPickRequest }) {
  const act = useAct();
  const selectShip = useGame((s) => s.selectShip);
  const selectedShip = useGame((s) => s.selectedShip);
  const [bag, setBag] = useState<ResourceBag>({});
  const me = state.players.find((p) => p.id === viewer);
  if (!me) return null;
  const count = awaiting.count ?? 1;
  const list = bagToList(bag);

  switch (awaiting.kind) {
    case 'resources':
      return (
        <div data-testid="pick-resources">
          <p>Take {count} resource{count === 1 ? '' : 's'} of your choice from the supply.</p>
          <BagPicker value={bag} onChange={setBag} max={state.supply} maxTotal={count} testId="pick" />
          <button type="button" data-testid="pick-confirm" disabled={list.length !== count} onClick={() => act({ type: 'encounterPick', resources: list }) && setBag({})}>
            Take {list.length}/{count}
          </button>
        </div>
      );
    case 'payResources':
    case 'giveOne': {
      const verb = awaiting.kind === 'giveOne' ? `Give ${playerName(state, state.activePlayer)}` : 'Pay';
      return (
        <div data-testid={`pick-${awaiting.kind}`}>
          <p>
            {me.name}: {verb.toLowerCase()} {count} card{count === 1 ? '' : 's'} from your hand.
          </p>
          <BagPicker value={bag} onChange={setBag} max={handBag(me.hand)} maxTotal={count} testId="pick" />
          <button type="button" data-testid="pick-confirm" disabled={list.length !== count} onClick={() => act({ type: 'encounterPick', resources: list }) && setBag({})}>
            {verb} {list.length}/{count}
          </button>
        </div>
      );
    }
    case 'upgradeKind':
    case 'removeUpgrade':
      return (
        <div data-testid={`pick-${awaiting.kind}`}>
          <p>{awaiting.kind === 'upgradeKind' ? 'Choose the upgrade to receive.' : `${me.name}: choose the upgrade to remove.`}</p>
          <div className="row">
            {(awaiting.options ?? []).map((o) => (
              <button key={o} type="button" data-testid={`pick-option-${o}`} onClick={() => act({ type: 'encounterPick', upgrade: o as UpgradeKind })}>
                {UPGRADE_LABEL[o as UpgradeKind] ?? o}
              </button>
            ))}
          </div>
        </div>
      );
    case 'immobilizeShip':
      return (
        <div data-testid="pick-immobilizeShip">
          <p>Choose the ship that cannot move this turn.</p>
          <div className="row">
            {(awaiting.options ?? []).map((o) => (
              <button key={o} type="button" data-testid={`pick-option-${o}`} onClick={() => act({ type: 'encounterPick', shipId: o })}>
                {o} ({state.board.ships[o]?.kind})
              </button>
            ))}
          </div>
        </div>
      );
    case 'spaceJump':
      return (
        <div data-testid="pick-spaceJump">
          <p>Space jump: pick a ship, then click a highlighted intersection on the board — or decline.</p>
          <div className="row">
            {(awaiting.options ?? []).map((o) => (
              <button key={o} type="button" data-testid={`pick-option-${o}`} className={selectedShip === o ? 'selected' : ''} onClick={() => selectShip(o)}>
                {o} ({state.board.ships[o]?.kind})
              </button>
            ))}
            <button type="button" data-testid="pick-decline" onClick={() => act({ type: 'encounterPick', decline: true })}>
              Decline the jump
            </button>
          </div>
        </div>
      );
  }
}

function Choice({ state, viewer }: { state: GameState; viewer: PlayerId }) {
  const act = useAct();
  const [offer, setOffer] = useState<ResourceBag>({});
  const ctx = state.turn.encounter;
  const me = state.players.find((p) => p.id === viewer);
  if (!ctx || !me) return null;
  const card = encounterCard(ctx.cardId);
  const offerStep = card.choice === 'offer0to3' || (card.choice === 'offerThenYesno' && ctx.offerPaid === undefined);
  if (offerStep) {
    const cards = bagToList(offer);
    return (
      <div data-testid="choice-offer">
        <p>How many cards do you offer (0–{MAX_OFFER})? They go to the supply before the outcome is revealed.</p>
        <BagPicker value={offer} onChange={setOffer} max={handBag(me.hand)} maxTotal={MAX_OFFER} testId="offer" />
        <button type="button" data-testid="offer-confirm" onClick={() => act({ type: 'encounterChoice', value: cards.length, cards }) && setOffer({})}>
          Offer {cards.length} card{cards.length === 1 ? '' : 's'}
        </button>
      </div>
    );
  }
  if (card.choice === 'none') return null;
  return (
    <div className="row" data-testid="choice-yesno">
      <button type="button" data-testid="choice-yes" onClick={() => act({ type: 'encounterChoice', value: true })}>
        Yes
      </button>
      <button type="button" data-testid="choice-no" onClick={() => act({ type: 'encounterChoice', value: false })}>
        No
      </button>
    </div>
  );
}

/**
 * Encounter modal (spec §14): text revealed box by box via `visibleEncounterText`,
 * the right control for the stage / `awaiting.kind`, and both shake results of
 * a contest. Stays open after the card resolves until dismissed.
 */
export function EncounterModal({ state, viewer }: { state: GameState; viewer: PlayerId }) {
  const [dismissed, setDismissed] = useState<string | null>(null);
  const ctx = state.turn.encounter;
  if (!ctx) return null;
  const live = state.phase === 'flight.encounter';
  const doneKey = `${state.turnNumber}:${ctx.cardId}`;
  if (!live && (ctx.stage !== 'done' || dismissed === doneKey)) return null;
  const card = encounterCard(ctx.cardId);
  const texts = visibleEncounterText(state);
  const awaiting = ctx.awaiting;
  const isActive = state.activePlayer === viewer;

  return (
    <div className="modal encounter" data-testid="encounter-modal">
      <h3>
        Encounter #{card.id}: {card.title}
      </h3>
      <div className="encounter-text">
        {texts.map((t, i) => (
          <p key={i} className="box" data-testid="encounter-box">
            {t}
          </p>
        ))}
      </div>
      {ctx.contestResults?.map((c, i) => (
        <div key={i} className="contest" data-testid="contest-result">
          <strong>{c.kind === 'combat' ? 'Fight' : 'Race'}:</strong> {playerName(state, c.yours.playerId)} {c.yours.balls.join('+')} = {c.yours.total} + {c.yours.bonus} ={' '}
          <b>{c.yours.strength}</b> vs {playerName(state, c.theirs.playerId)} {c.theirs.balls.join('+')} = {c.theirs.total} + {c.theirs.bonus} = <b>{c.theirs.strength}</b> →{' '}
          {c.won ? 'won' : 'lost'}
        </div>
      ))}
      {ctx.fleeResults?.map((f, i) => (
        <div key={i} className="contest">
          <strong>Flee:</strong> your boosters {f.yours} vs {playerName(state, f.opponent)} {f.theirs} → {f.escaped ? 'escaped' : 'caught'}
        </div>
      ))}
      {ctx.tableShakes?.map((t, i) => (
        <div key={i} className="contest">
          <strong>Shake:</strong> {t.balls.join('+')} = {t.total} ({t.band})
        </div>
      ))}
      {live && ctx.stage === 'choice' && (isActive ? <Choice state={state} viewer={viewer} /> : <p className="muted">Waiting for {playerName(state, state.activePlayer)} to decide.</p>)}
      {live && awaiting && (awaiting.playerId === viewer ? <Pick key={awaiting.kind + awaiting.playerId} state={state} viewer={viewer} awaiting={awaiting} /> : <p className="muted">Waiting for {playerName(state, awaiting.playerId)} ({awaiting.kind}).</p>)}
      {!live && (
        <button type="button" data-testid="encounter-continue" onClick={() => setDismissed(doneKey)}>
          Continue
        </button>
      )}
    </div>
  );
}
