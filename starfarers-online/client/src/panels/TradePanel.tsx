import {
  FRIENDSHIP_CARDS,
  RESOURCES,
  SUPPLY_TRADE,
  type GameState,
  type PlayerId,
  type Resource,
  type ResourceBag,
} from '@starfarers/shared';
import { useState } from 'react';
import { useAct } from '../store/gameStore.js';
import { RESOURCE_LABEL, bagText, bagTotal, handBag, playerName } from '../ui/format.js';
import { BagPicker } from './ResourcePicker.js';

/** Supply ratios the viewer may use for `give` right now (spec §7.1 + Merchants cards). */
export function supplyRates(state: GameState, viewer: PlayerId, give: Resource): { cards: number; label: string }[] {
  const me = state.players.find((p) => p.id === viewer);
  if (!me) return [];
  const rates: { cards: number; label: string }[] = [{ cards: SUPPLY_TRADE.identicalForOne, label: '3:1' }];
  if (give === 'goods') rates.push({ cards: SUPPLY_TRADE.goodsForOne, label: '2 goods : 1' });
  for (const id of me.friendshipCards) {
    const e = FRIENDSHIP_CARDS[id].effect;
    if (e.kind === 'merchant2for1' && e.resource === give) rates.push({ cards: SUPPLY_TRADE.merchantsRate, label: `2:1 (${FRIENDSHIP_CARDS[id].name})` });
    if (e.kind === 'merchant1for1' && e.resource === give && !state.turn.usedOncePerTurn.includes('ezzel')) {
      rates.push({ cards: 1, label: `1:1 (${FRIENDSHIP_CARDS[id].name}, once per turn)` });
    }
  }
  return rates.sort((a, b) => a.cards - b.cards);
}

function SupplyTrade({ state, viewer }: { state: GameState; viewer: PlayerId }) {
  const act = useAct();
  const [give, setGive] = useState<Resource>('ore');
  const [want, setWant] = useState<Resource>('food');
  const me = state.players.find((p) => p.id === viewer);
  if (!me) return null;
  const hand = handBag(me.hand);
  const rates = supplyRates(state, viewer, give).filter((r) => hand[give] >= r.cards);
  return (
    <div className="supply-trade" data-testid="supply-trade">
      <h4>Trade with the supply</h4>
      <label>
        Give{' '}
        <select value={give} onChange={(e) => setGive(e.target.value as Resource)} data-testid="supply-give">
          {RESOURCES.map((r) => (
            <option key={r} value={r}>
              {RESOURCE_LABEL[r]} ({hand[r]})
            </option>
          ))}
        </select>
      </label>
      <label>
        {' '}
        for 1{' '}
        <select value={want} onChange={(e) => setWant(e.target.value as Resource)} data-testid="supply-want">
          {RESOURCES.map((r) => (
            <option key={r} value={r}>
              {RESOURCE_LABEL[r]} (supply {state.supply[r]})
            </option>
          ))}
        </select>
      </label>
      <div className="rates">
        {rates.length === 0 && <span className="muted">Not enough {RESOURCE_LABEL[give].toLowerCase()} for any ratio.</span>}
        {rates.map((r) => (
          <button
            key={r.label}
            type="button"
            data-testid={`supply-rate-${r.cards}`}
            onClick={() => act({ type: 'tradeWithSupply', give: Array.from({ length: r.cards }, () => give), want })}
          >
            {r.label}
          </button>
        ))}
      </div>
    </div>
  );
}

function PlayerTrade({ state, viewer }: { state: GameState; viewer: PlayerId }) {
  const act = useAct();
  const me = state.players.find((p) => p.id === viewer);
  const others = state.players.filter((p) => p.id !== viewer);
  const [to, setTo] = useState<PlayerId>(others[0]?.id ?? '');
  const [give, setGive] = useState<ResourceBag>({});
  const [want, setWant] = useState<ResourceBag>({});
  if (!me) return null;
  const open = state.openTrade;
  const isActive = state.activePlayer === viewer;
  // Non-active players may only trade with the active player (§7.1).
  const targets = isActive ? others : others.filter((p) => p.id === state.activePlayer);
  const target = targets.find((p) => p.id === to) ?? targets[0];
  const canPropose = target && bagTotal(give) > 0 && bagTotal(want) > 0;

  return (
    <div className="player-trade" data-testid="player-trade">
      <h4>Trade with a player</h4>
      {open && open.to !== 'supply' && (
        <div className="open-trade" data-testid="open-trade">
          <p>
            <strong>{playerName(state, open.from)}</strong> offers <strong>{playerName(state, open.to)}</strong> {bagText(open.give)} for {bagText(open.want)}.
          </p>
          {open.to === viewer && (
            <div className="row">
              <button type="button" data-testid="trade-accept" onClick={() => act({ type: 'respondTrade', accept: true })}>
                Accept
              </button>
              <button type="button" data-testid="trade-reject" onClick={() => act({ type: 'respondTrade', accept: false })}>
                Reject
              </button>
              <button
                type="button"
                data-testid="trade-counter"
                disabled={bagTotal(give) === 0 || bagTotal(want) === 0}
                onClick={() => act({ type: 'respondTrade', accept: false, counter: { give, want } })}
                title="Counter with the offer built below (from your point of view)"
              >
                Counter with the offer below
              </button>
            </div>
          )}
          {open.from === viewer && (
            <button type="button" data-testid="trade-withdraw" onClick={() => act({ type: 'respondTrade', accept: false })}>
              Withdraw
            </button>
          )}
        </div>
      )}
      <div className="offer-builder">
        <label>
          To{' '}
          <select value={target?.id ?? ''} onChange={(e) => setTo(e.target.value)} data-testid="trade-to">
            {targets.map((p) => (
              <option key={p.id} value={p.id}>
                {p.name}
              </option>
            ))}
          </select>
        </label>
        <div className="two-col">
          <div>
            <span className="muted">You give</span>
            <BagPicker value={give} onChange={setGive} max={handBag(me.hand)} testId="trade-give" />
          </div>
          <div>
            <span className="muted">You want</span>
            <BagPicker value={want} onChange={setWant} testId="trade-want" />
          </div>
        </div>
        <button
          type="button"
          data-testid="trade-propose"
          disabled={!canPropose}
          onClick={() => {
            if (target && act({ type: 'proposeTrade', to: target.id, give, want })) {
              setGive({});
              setWant({});
            }
          }}
        >
          Propose
        </button>
      </div>
    </div>
  );
}

/** Supply trade with ratio hints and player trade driven by `state.openTrade` (HANDOFF §6.4). */
export function TradePanel({ state, viewer }: { state: GameState; viewer: PlayerId }) {
  if (state.phase !== 'tradeBuild') return null;
  const isActive = state.activePlayer === viewer;
  return (
    <section className="panel" data-testid="trade-panel">
      <h3>Trade</h3>
      {isActive && <SupplyTrade state={state} viewer={viewer} />}
      <PlayerTrade state={state} viewer={viewer} />
    </section>
  );
}
