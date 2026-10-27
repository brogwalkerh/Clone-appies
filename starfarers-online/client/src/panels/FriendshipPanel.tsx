import { FRIENDSHIP_CARDS, RESOURCES, reliefEligible, type GameState, type PlayerId, type Resource } from '@starfarers/shared';
import { useState } from 'react';
import { useAct } from '../store/gameStore.js';
import { CIV_LABEL, RESOURCE_LABEL } from '../ui/format.js';

function describe(id: keyof typeof FRIENDSHIP_CARDS): string {
  const e = FRIENDSHIP_CARDS[id].effect;
  switch (e.kind) {
    case 'productionIncrease':
      return `+1 ${RESOURCE_LABEL[e.resource].toLowerCase()} whenever you produce it`;
    case 'combatBonus':
      return [e.combat ? `combat +${e.combat}` : '', e.speed ? `speed +${e.speed}` : ''].filter(Boolean).join(', ');
    case 'reducedTribute':
      return 'discard on a 7 only with more than 12 cards';
    case 'fameForSale':
      return 'pay 1 goods for 1 fame piece (once per turn)';
    case 'helpingHand':
      return 'draw 1 card from each of 2 opponents ahead of you (once per turn)';
    case 'galacticReliefFund':
      return 'take any 1 resource when a roll gives you nothing';
    case 'merchant2for1':
      return `trade 2 ${RESOURCE_LABEL[e.resource].toLowerCase()} for 1 any (via supply trade)`;
    case 'merchant1for1':
      return `trade 1 goods for 1 any, once per turn (via supply trade)`;
  }
}

/** The viewer's friendship cards with the actions some of them carry (spec §8, §7.3). */
export function FriendshipPanel({ state, viewer }: { state: GameState; viewer: PlayerId }) {
  const act = useAct();
  const [targets, setTargets] = useState<PlayerId[]>([]);
  const [reliefWant, setReliefWant] = useState<Resource>('ore');
  const me = state.players.find((p) => p.id === viewer);
  if (!me) return null;
  const isActive = state.activePlayer === viewer;
  const inTradeBuild = state.phase === 'tradeBuild';
  const richer = state.players.filter((p) => p.id !== viewer && p.vp > me.vp);

  return (
    <section className="panel" data-testid="friendship-panel">
      <h3>Friendship cards</h3>
      {me.friendshipCards.length === 0 && <p className="muted">None yet — found a trade station at an outpost.</p>}
      <ul className="friendship-list">
        {me.friendshipCards.map((id) => {
          const def = FRIENDSHIP_CARDS[id];
          const e = def.effect;
          return (
            <li key={id} data-testid={`friendship-${id}`}>
              <strong>{def.name}</strong> <span className="muted">({CIV_LABEL[def.civ]})</span>
              <div className="muted small">{describe(id)}</div>
              {e.kind === 'fameForSale' && (
                <button
                  type="button"
                  disabled={!isActive || !inTradeBuild || state.turn.usedOncePerTurn.includes('fameForSale')}
                  onClick={() => act({ type: 'useFriendshipCard', cardId: id })}
                >
                  Pay 1 goods → 1 fame
                </button>
              )}
              {e.kind === 'helpingHand' && (
                <div className="row">
                  {richer.map((p) => (
                    <label key={p.id}>
                      <input
                        type="checkbox"
                        checked={targets.includes(p.id)}
                        onChange={(ev) => setTargets(ev.target.checked ? [...targets, p.id].slice(-2) : targets.filter((t) => t !== p.id))}
                      />
                      {p.name}
                    </label>
                  ))}
                  <button
                    type="button"
                    disabled={!isActive || !inTradeBuild || targets.length !== 2 || state.turn.usedOncePerTurn.includes('helpingHand')}
                    onClick={() => act({ type: 'useFriendshipCard', cardId: id, targets })}
                  >
                    Draw from both
                  </button>
                </div>
              )}
              {e.kind === 'galacticReliefFund' && (
                <div className="row">
                  <select value={reliefWant} onChange={(ev) => setReliefWant(ev.target.value as Resource)}>
                    {RESOURCES.map((r) => (
                      <option key={r} value={r}>
                        {RESOURCE_LABEL[r]}
                      </option>
                    ))}
                  </select>
                  <button
                    type="button"
                    data-testid="relief-claim"
                    disabled={!reliefEligible(state, viewer)}
                    onClick={() => act({ type: 'useFriendshipCard', cardId: id, want: reliefWant })}
                  >
                    Claim relief
                  </button>
                </div>
              )}
            </li>
          );
        })}
      </ul>
    </section>
  );
}
