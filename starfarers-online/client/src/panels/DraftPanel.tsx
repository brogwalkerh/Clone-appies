import {
  draftSpaceportCandidates,
  isColonyRound,
  isOccupied,
  spaceportSites,
  type GameState,
  type NodeId,
  type PlayerId,
  type ShipKind,
  type UpgradeKind,
} from '@starfarers/shared';
import { useState } from 'react';
import { useAct } from '../store/gameStore.js';
import { shortNode } from '../ui/format.js';

const UPGRADE_LABEL: Readonly<Record<UpgradeKind, string>> = { booster: 'Booster', cannon: 'Cannon', freightPod: 'Freight pod' };

/**
 * Round 4 of the advanced set-up draft (spec §3.4): the drafter picks which of
 * their colonies becomes the spaceport, a colony or trade ship, the spaceport
 * site for it and the bonus upgrade, and confirms the whole pick as one
 * `draftFinish` action. Rounds 1–3 are played on the board (App.tsx).
 */
export function DraftPanel({ state, viewer }: { state: GameState; viewer: PlayerId }) {
  const act = useAct();
  const [spaceport, setSpaceport] = useState<NodeId | null>(null);
  const [ship, setShip] = useState<ShipKind>('colony');
  const [shipSite, setShipSite] = useState<NodeId | null>(null);
  const [upgrade, setUpgrade] = useState<UpgradeKind | null>(null);
  const draft = state.draft;
  const me = state.players.find((p) => p.id === viewer);
  if (!draft || !me || isColonyRound(draft) || state.activePlayer !== viewer) return null;

  const candidates = draftSpaceportCandidates(state, viewer);
  const chosenSpaceport = spaceport && candidates.includes(spaceport) ? spaceport : (candidates[0] ?? null);
  const sites = chosenSpaceport ? spaceportSites(state.board, chosenSpaceport).filter((n) => !isOccupied(state.board, n)) : [];
  const chosenSite = shipSite && sites.includes(shipSite) ? shipSite : (sites[0] ?? null);
  const pool = [...new Set(draft.pool)];
  const chosenUpgrade = upgrade && draft.pool.includes(upgrade) ? upgrade : (pool[0] ?? null);
  const canTrade = me.pieces.stationsLeft > 0;
  const canColony = me.pieces.coloniesLeft > 0;
  const chosenShip: ShipKind = ship === 'trade' && canTrade ? 'trade' : canColony ? 'colony' : 'trade';

  return (
    <div className="modal" data-testid="draft-panel">
      <h3>Set-up round 4 — your spaceport, ship and bonus upgrade</h3>
      <div>
        <span className="muted">Upgrade this colony to your spaceport:</span>
        <div className="row">
          {candidates.map((n) => (
            <button key={n} type="button" data-testid={`draft-spaceport-${n}`} className={chosenSpaceport === n ? 'selected' : ''} onClick={() => setSpaceport(n)}>
              {shortNode(n)}
            </button>
          ))}
        </div>
      </div>
      <div>
        <span className="muted">Ship:</span>
        <div className="row">
          <button type="button" data-testid="draft-ship-colony" className={chosenShip === 'colony' ? 'selected' : ''} disabled={!canColony} onClick={() => setShip('colony')}>
            Colony ship
          </button>
          <button type="button" data-testid="draft-ship-trade" className={chosenShip === 'trade' ? 'selected' : ''} disabled={!canTrade} onClick={() => setShip('trade')}>
            Trade ship
          </button>
        </div>
      </div>
      <div>
        <span className="muted">On spaceport site:</span>
        <div className="row">
          {sites.map((n) => (
            <button key={n} type="button" data-testid={`draft-ship-site-${n}`} className={chosenSite === n ? 'selected' : ''} onClick={() => setShipSite(n)}>
              {shortNode(n)}
            </button>
          ))}
          {sites.length === 0 && <span className="error">No free site at that spaceport</span>}
        </div>
      </div>
      <div>
        <span className="muted">Bonus upgrade ({draft.pool.length} left in the pool):</span>
        <div className="row">
          {pool.map((u) => (
            <button key={u} type="button" data-testid={`draft-upgrade-${u}`} className={chosenUpgrade === u ? 'selected' : ''} onClick={() => setUpgrade(u)}>
              {UPGRADE_LABEL[u]}
              {draft.pool.filter((x) => x === u).length > 1 ? ` ×${draft.pool.filter((x) => x === u).length}` : ''}
            </button>
          ))}
        </div>
      </div>
      <button
        type="button"
        data-testid="draft-confirm"
        disabled={chosenSpaceport === null || chosenSite === null || chosenUpgrade === null}
        onClick={() =>
          chosenSpaceport !== null &&
          chosenSite !== null &&
          chosenUpgrade !== null &&
          act({ type: 'draftFinish', spaceportSiteId: chosenSpaceport, ship: chosenShip, shipSiteId: chosenSite, upgrade: chosenUpgrade })
        }
      >
        Confirm
      </button>
    </div>
  );
}
