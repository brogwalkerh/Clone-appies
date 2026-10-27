/**
 * Exploring planetary systems (spec §9.3).
 *
 * `exploreAt(state, nodeId, shipId?)`: for every system touching the node whose
 * discs are still face down, flip all three. A disc carrying a `special`
 * (P4/P5/P6 pirate base, I3/I4 ice planet) is replaced by the matching token:
 * `planet.token = { kind, value }` and `planet.disc = null` — the disc record
 * leaves the board exactly like the physical disc does, so the planet produces
 * nothing until the token is beaten and a reserve disc takes its place
 * (flight/tokens.ts). Number discs simply become `faceUp` and produce from the
 * next roll. The sector is marked `explored` and an event is logged.
 *
 * When `shipId` is given, `checkSpecialTokens` runs afterwards so a ship whose
 * owner already meets a freshly revealed threshold claims the token at once
 * (§9.6 "immediately"). Callers in a move loop call this once per step, with
 * the ship's `nodeId` already updated to that step.
 */

import { planetsOfSector, sectorsAdjacentToNode } from '../board/query.js';
import { logEvent } from '../actions/handler.js';
import type { GameState, NodeId, Sector, SectorId, ShipId } from '../types.js';
import { checkSpecialTokens } from './tokens.js';

/** Flip one system's discs; returns false if it was already explored. */
export function exploreSector(state: GameState, sector: Sector): boolean {
  if (sector.kind !== 'system' || sector.explored) return false;
  const revealed: string[] = [];
  for (const planet of planetsOfSector(state.board, sector.id)) {
    const disc = planet.disc;
    if (!disc) continue;
    disc.faceUp = true;
    revealed.push(disc.label);
    if (disc.special) {
      planet.token = { ...disc.special };
      planet.disc = null;
    }
  }
  sector.explored = true;
  logEvent(state, `System ${sector.id} explored: discs ${revealed.join(', ')} revealed`);
  return true;
}

/** Explore every unexplored system adjacent to the node; returns the sector ids flipped. */
export function exploreAt(state: GameState, nodeId: NodeId, shipId?: ShipId): SectorId[] {
  const flipped: SectorId[] = [];
  for (const sector of sectorsAdjacentToNode(state.board, nodeId)) {
    if (exploreSector(state, sector)) flipped.push(sector.id);
  }
  if (shipId !== undefined) checkSpecialTokens(state, shipId);
  return flipped;
}
