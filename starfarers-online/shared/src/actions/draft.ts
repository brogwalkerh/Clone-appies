/**
 * Advanced set-up draft handlers (spec §3.4): `draftColony` (rounds 1–3) and
 * `draftFinish` (round 4). The pick order, the pool and the closing of the
 * draft live in setup/draft.ts; `ACTION_POLICY` already restricts both actions
 * to phase 'setup' and to `activePlayer` (= the current picker).
 *
 * Round 4 is ONE action (spaceport + ship + bonus upgrade) validated as a unit:
 * the three choices depend on each other (the ship goes on a site of the new
 * spaceport) and a single action keeps the policy table, the log and the UI's
 * "whose pick is it" question trivial; nothing in it is hidden information.
 */

import { UPGRADE_CAPS, UPGRADE_TRAY_KEY } from '../config.js';
import { getPlayer, getSector, isOccupied, settlementAt, spaceportSites } from '../board/query.js';
import { advanceDraft, draftSpaceportCandidates, isColonyRound } from '../setup/draft.js';
import type { GameError, GameState, NodeId, Player, UpgradeKind } from '../types.js';
import { gameError } from '../types.js';
import type { ActionModule, Handler, HandlerMap } from './handler.js';
import { logEvent } from './handler.js';

function isUpgradeKind(value: unknown): value is UpgradeKind {
  return typeof value === 'string' && Object.hasOwn(UPGRADE_TRAY_KEY, value);
}

/** The Catanian colony site named by a draft pick, or the error to return. */
function draftableSite(state: GameState, siteId: unknown): NodeId | GameError {
  if (typeof siteId !== 'string') return gameError('invalidSite', 'draftColony needs a siteId');
  const node = state.board.nodes[siteId];
  if (!node) return gameError('invalidSite', `Unknown node ${siteId}`, { siteId });
  if (node.siteType !== 'colonySite' || node.sectorId === undefined || getSector(state.board, node.sectorId).region !== 'catanian') {
    return gameError('invalidSite', `${siteId} is not a Catanian colony site`, { siteId });
  }
  if (isOccupied(state.board, siteId)) return gameError('invalidSite', `Colony site ${siteId} is already taken`, { siteId });
  return siteId;
}

function nextShipId(state: GameState, player: Player): string {
  for (let n = 1; ; n++) {
    const id = `ship:${player.color}:${n}`;
    if (!state.board.ships[id]) return id;
  }
}

const handleDraftColony: Handler<'draftColony'> = (state, action, rng) => {
  const draft = state.draft;
  if (!draft) return gameError('wrongPhase', 'No set-up draft is in progress');
  if (!isColonyRound(draft)) return gameError('ruleViolation', 'Set-up round 4: upgrade a colony, place a ship and take an upgrade with draftFinish');
  const player = getPlayer(state, action.playerId);
  const site = draftableSite(state, action.siteId);
  if (typeof site !== 'string') return site;
  if (player.pieces.coloniesLeft < 1) return gameError('pieceLimit', 'No colony piece left');

  state.board.settlements[site] = { nodeId: site, kind: 'colony', color: player.color, owner: player.id };
  player.pieces.coloniesLeft -= 1;
  (draft.colonies[player.id] ??= []).push(site);
  logEvent(state, `${player.name} drafted a colony at ${site} (set-up round ${draft.round})`, player.id);
  advanceDraft(state, rng);
  return state;
};

const handleDraftFinish: Handler<'draftFinish'> = (state, action, rng) => {
  const draft = state.draft;
  if (!draft) return gameError('wrongPhase', 'No set-up draft is in progress');
  if (isColonyRound(draft)) return gameError('ruleViolation', `Set-up round ${draft.round}: place a colony with draftColony`);
  const player = getPlayer(state, action.playerId);

  // Spaceport: one of the player's own drafted colonies.
  const { spaceportSiteId, shipSiteId, ship: shipKind, upgrade } = action;
  const candidates = draftSpaceportCandidates(state, player.id);
  if (typeof spaceportSiteId !== 'string' || !candidates.includes(spaceportSiteId)) {
    return gameError('invalidSite', `${String(spaceportSiteId)} is not one of your drafted colonies`, { spaceportSiteId, candidates });
  }
  if (player.pieces.shipyardsLeft < 1) return gameError('pieceLimit', 'No shipyard piece left');

  // Ship: colony or trade, on one of the new spaceport's two sites.
  if (shipKind !== 'colony' && shipKind !== 'trade') return gameError('invalidAction', `ship must be 'colony' or 'trade', got ${String(shipKind)}`);
  if (player.pieces.transportsLeft < 1) return gameError('pieceLimit', 'No transport ship left');
  if (shipKind === 'colony' && player.pieces.coloniesLeft < 1) return gameError('pieceLimit', 'No colony piece left');
  if (shipKind === 'trade' && player.pieces.stationsLeft < 1) return gameError('pieceLimit', 'No trade station piece left');
  const sites = spaceportSites(state.board, spaceportSiteId);
  if (typeof shipSiteId !== 'string' || !sites.includes(shipSiteId)) {
    return gameError('invalidSite', `${String(shipSiteId)} is not a spaceport site of ${spaceportSiteId}`, { shipSiteId, sites });
  }
  if (isOccupied(state.board, shipSiteId)) return gameError('invalidSite', `Spaceport site ${shipSiteId} is occupied`, { shipSiteId });

  // Bonus upgrade: still in the pool, available in the tray, under the cap.
  if (!isUpgradeKind(upgrade)) return gameError('invalidAction', `Unknown upgrade ${String(upgrade)}`);
  if (!draft.pool.includes(upgrade)) return gameError('ruleViolation', `No ${upgrade} left in the set-up pool`, { upgrade, pool: [...draft.pool] });
  const trayKey = UPGRADE_TRAY_KEY[upgrade];
  if (state.upgradesTray[trayKey] < 1) return gameError('supplyEmpty', `No ${trayKey} left in the upgrades tray`, { upgrade });
  if (player.mothership[trayKey] >= UPGRADE_CAPS[upgrade]) return gameError('upgradeCap', `Your mothership already has ${UPGRADE_CAPS[upgrade]} ${trayKey}`, { upgrade });

  const settlement = settlementAt(state.board, spaceportSiteId);
  if (!settlement) return gameError('invalidSite', `No colony at ${spaceportSiteId}`, { spaceportSiteId });
  settlement.kind = 'spaceport';
  player.pieces.shipyardsLeft -= 1;
  const shipId = nextShipId(state, player);
  state.board.ships[shipId] = { id: shipId, owner: player.id, kind: shipKind, nodeId: shipSiteId, mustFoundOrLeave: false };
  player.pieces.transportsLeft -= 1;
  if (shipKind === 'colony') player.pieces.coloniesLeft -= 1;
  else player.pieces.stationsLeft -= 1;
  draft.pool.splice(draft.pool.indexOf(upgrade), 1);
  state.upgradesTray[trayKey] -= 1;
  player.mothership[trayKey] += 1;
  logEvent(state, `${player.name} upgraded ${spaceportSiteId} to a spaceport, placed a ${shipKind} ship (${shipId}) at ${shipSiteId} and took a ${upgrade} (set-up round 4)`, player.id);
  advanceDraft(state, rng);
  return state;
};

export const handlers: HandlerMap = {
  draftColony: handleDraftColony,
  draftFinish: handleDraftFinish,
};

export const draftModule: ActionModule = { handlers };
