/**
 * "Free trade ship" encounter reward (spec §10, §7.3):
 *
 *   Place 1 trade ship adjacent to 1 of your spaceports as soon as possible.
 *
 * It is placed at once when the player has a free transport, fewer than
 * `MAX_SHIPS_ON_BOARD` ships, a trade station piece and an unoccupied site of
 * one of their own spaceports. Otherwise a trade-ship marker is held in
 * `state.pendingTradeShips[playerId]` and is placed as soon as possible
 * (`tryPlacePendingTradeShips`: start of the player's turn, after a build, or
 * after a ship leaves the board by founding). A free ship placed during the
 * owner's flight phase may move the same turn.
 *
 * Site choice: the real game lets the player pick the spaceport site; the
 * engine places deterministically on the first free own site (spaceports in
 * settlement order, sites in graph-neighbour order). Both sites of a spaceport
 * are legal, so this does not change play.
 */

import { MAX_SHIPS_ON_BOARD } from '../config.js';
import { getPlayer, isOccupied, shipsOf, spaceportSites, spaceportsOf } from '../board/query.js';
import type { GameState, NodeId, Player, PlayerId, ShipId } from '../types.js';

/** Smallest unused `ship:<color>:<n>` (n ≥ 1), the scheme of setup/beginner.ts and build. */
export function nextShipId(state: GameState, player: Player): ShipId {
  for (let n = 1; ; n++) {
    const id = `ship:${player.color}:${n}`;
    if (!state.board.ships[id]) return id;
  }
}

/** Unoccupied sites of the player's own spaceports. */
export function freeOwnSpaceportSites(state: GameState, playerId: PlayerId): NodeId[] {
  return spaceportsOf(state, playerId)
    .flatMap((sp) => spaceportSites(state.board, sp.nodeId))
    .filter((site) => !isOccupied(state.board, site));
}

/** Where a free trade ship could go right now, or `null` if it cannot be placed yet. */
export function freeTradeShipSite(state: GameState, playerId: PlayerId): NodeId | null {
  const player = getPlayer(state, playerId);
  if (player.pieces.transportsLeft < 1) return null;
  if (shipsOf(state, playerId).length >= MAX_SHIPS_ON_BOARD) return null;
  if (player.pieces.stationsLeft < 1) return null;
  return freeOwnSpaceportSites(state, playerId)[0] ?? null;
}

function placeTradeShip(state: GameState, player: Player, site: NodeId): ShipId {
  const shipId = nextShipId(state, player);
  state.board.ships[shipId] = { id: shipId, owner: player.id, kind: 'trade', nodeId: site, mustFoundOrLeave: false };
  player.pieces.transportsLeft -= 1;
  player.pieces.stationsLeft -= 1;
  state.log.push({
    seq: state.log.length,
    turnNumber: state.turnNumber,
    playerId: player.id,
    kind: 'event',
    message: `${player.name} placed a free trade ship (${shipId}) at ${site}`,
  });
  return shipId;
}

/**
 * Grant the encounter reward: place the trade ship now if possible, otherwise
 * hold a trade-ship marker for the player.
 */
export function grantFreeTradeShip(state: GameState, playerId: PlayerId): 'placed' | 'pending' {
  const player = getPlayer(state, playerId);
  const site = freeTradeShipSite(state, playerId);
  if (site !== null) {
    placeTradeShip(state, player, site);
    return 'placed';
  }
  state.pendingTradeShips[playerId] = (state.pendingTradeShips[playerId] ?? 0) + 1;
  state.log.push({
    seq: state.log.length,
    turnNumber: state.turnNumber,
    playerId,
    kind: 'event',
    message: `${player.name} holds a trade-ship marker (${state.pendingTradeShips[playerId]} pending)`,
  });
  return 'pending';
}

/** Place as many of the player's pending trade-ship markers as now possible; returns how many were placed. */
export function tryPlacePendingTradeShips(state: GameState, playerId: PlayerId): number {
  const player = getPlayer(state, playerId);
  let placed = 0;
  while ((state.pendingTradeShips[playerId] ?? 0) > 0) {
    const site = freeTradeShipSite(state, playerId);
    if (site === null) break;
    placeTradeShip(state, player, site);
    state.pendingTradeShips[playerId] = (state.pendingTradeShips[playerId] ?? 0) - 1;
    placed += 1;
  }
  return placed;
}
