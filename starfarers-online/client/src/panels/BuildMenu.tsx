import {
  BUILD_COSTS,
  MAX_SHIPS_ON_BOARD,
  UPGRADE_CAPS,
  handHas,
  isOccupied,
  shipsOf,
  spaceportSites,
  spaceportsOf,
  type BuildItem,
  type GameState,
  type NodeId,
  type PlayerId,
} from '@starfarers/shared';
import { useAct, useGame } from '../store/gameStore.js';
import { bagText, shortNode } from '../ui/format.js';

const ITEMS: { item: BuildItem; label: string }[] = [
  { item: 'colonyShip', label: 'Colony ship' },
  { item: 'tradeShip', label: 'Trade ship' },
  { item: 'spaceport', label: 'Spaceport' },
  { item: 'booster', label: 'Booster' },
  { item: 'cannon', label: 'Cannon' },
  { item: 'freightPod', label: 'Freight pod' },
];

/** Free spaceport sites of the player (where a new ship may be placed). */
export function freeSpaceportSites(state: GameState, playerId: PlayerId): NodeId[] {
  return spaceportsOf(state, playerId)
    .flatMap((sp) => spaceportSites(state.board, sp.nodeId))
    .filter((n) => !isOccupied(state.board, n));
}

/** Build menu with affordability from BUILD_COSTS; site picks go through the board (HANDOFF §6.4). */
export function BuildMenu({ state, viewer }: { state: GameState; viewer: PlayerId }) {
  const act = useAct();
  const setNodePick = useGame((s) => s.setNodePick);
  const nodePick = useGame((s) => s.nodePick);
  const me = state.players.find((p) => p.id === viewer);
  if (!me) return null;
  const enabled = state.phase === 'tradeBuild' && state.activePlayer === viewer;
  const shipSites = freeSpaceportSites(state, viewer);
  const colonies = Object.values(state.board.settlements).filter((s) => s.owner === viewer && s.kind === 'colony');
  const shipsOut = shipsOf(state, viewer).length;

  function disabledReason(item: BuildItem): string | null {
    switch (item) {
      case 'colonyShip':
      case 'tradeShip':
        if (shipsOut >= MAX_SHIPS_ON_BOARD || me!.pieces.transportsLeft < 1) return 'no free transport';
        if (item === 'colonyShip' && me!.pieces.coloniesLeft < 1) return 'no colony piece';
        if (item === 'tradeShip' && me!.pieces.stationsLeft < 1) return 'no station piece';
        if (shipSites.length === 0) return 'no free spaceport site';
        return null;
      case 'spaceport':
        if (me!.pieces.shipyardsLeft < 1) return 'no shipyard';
        if (colonies.length === 0) return 'no colony to upgrade';
        return null;
      case 'booster':
        return me!.mothership.boosters >= UPGRADE_CAPS.booster ? 'at cap' : state.upgradesTray.boosters < 1 ? 'tray empty' : null;
      case 'cannon':
        return me!.mothership.cannons >= UPGRADE_CAPS.cannon ? 'at cap' : state.upgradesTray.cannons < 1 ? 'tray empty' : null;
      case 'freightPod':
        return me!.mothership.freightPods >= UPGRADE_CAPS.freightPod ? 'at cap' : state.upgradesTray.freightPods < 1 ? 'tray empty' : null;
    }
  }

  function start(item: BuildItem) {
    if (item === 'colonyShip' || item === 'tradeShip') {
      if (shipSites.length === 1) {
        act({ type: 'build', item, siteId: shipSites[0] as NodeId });
        return;
      }
      setNodePick({
        label: `Choose a spaceport site for the ${item === 'colonyShip' ? 'colony' : 'trade'} ship`,
        candidates: shipSites,
        onPick: (siteId) => act({ type: 'build', item, siteId }),
      });
      return;
    }
    if (item === 'spaceport') {
      const sites = colonies.map((c) => c.nodeId);
      if (sites.length === 1) {
        act({ type: 'build', item, siteId: sites[0] as NodeId });
        return;
      }
      setNodePick({ label: 'Choose the colony to upgrade', candidates: sites, onPick: (siteId) => act({ type: 'build', item, siteId }) });
      return;
    }
    act({ type: 'build', item });
  }

  return (
    <section className="panel" data-testid="build-menu">
      <h3>Build</h3>
      {nodePick && (
        <p className="hint" data-testid="node-pick-hint">
          {nodePick.label}: {nodePick.candidates.map(shortNode).join(' · ')}{' '}
          <button type="button" className="link" onClick={() => setNodePick(null)}>
            cancel
          </button>
        </p>
      )}
      <ul className="build-list">
        {ITEMS.map(({ item, label }) => {
          const cost = BUILD_COSTS[item];
          const affordable = handHas(me.hand, cost);
          const reason = disabledReason(item);
          const disabled = !enabled || !affordable || reason !== null;
          return (
            <li key={item} className={disabled ? 'disabled' : ''}>
              <button type="button" data-testid={`build-${item}`} disabled={disabled} onClick={() => start(item)}>
                {label}
              </button>
              <span className={affordable ? 'cost ok' : 'cost'}>{bagText(cost)}</span>
              {reason && enabled && <span className="muted">{reason}</span>}
            </li>
          );
        })}
      </ul>
      <p className="muted small">
        Pieces left: {me.pieces.coloniesLeft} colonies · {me.pieces.stationsLeft} stations · {me.pieces.transportsLeft} transports · {me.pieces.shipyardsLeft} shipyards
      </p>
    </section>
  );
}
