/**
 * Discovering face-down sectors (spec §3.2 explorer / wild space, §9.3).
 *
 * In those set-ups the 15 slot tiles start `discovered: false`: the
 * authoritative board already holds the real tile under each slot (so the
 * seed alone reproduces the game), but `redactState` hides it, and ships may
 * neither end on nor pass through the slot's interior nodes
 * (`undiscoveredInteriorNodes`). When a ship's move or jump reaches a node
 * touching one of the slot's lobes — the same trigger point as `exploreAt` —
 * the tile is discovered:
 *   - a planetary system draws one disc per planet from `state.discPools`
 *     (by the planet's back icon, through the rng), places them face down and
 *     flips them at once (`flipSystemDiscs`: specials become tokens), so the
 *     player sees one event "discovered a planetary system: discs 5, 9, P4";
 *   - an outpost's docking point and docks become usable;
 *   - an empty sector just becomes passable.
 * The planets' orientation was fixed at set-up (`VARIABLE_SETUP_START_LOBE`).
 * `DISCOVERY_ENDS_MOVE` (config, [VERIFY]) says whether the discovering ship
 * keeps the rest of its budget; `applyMove` reads it.
 */

import { logEvent } from '../actions/handler.js';
import { makeDisc } from '../board/discs.js';
import { planetsOfSector, undiscoveredSectorsTouchingNode } from '../board/query.js';
import type { Rng } from '../rng.js';
import type { GameState, NodeId, Sector, SectorId } from '../types.js';
import { flipSystemDiscs } from './explore.js';

function describeTile(sector: Sector): string {
  if (sector.kind === 'system') return 'a planetary system';
  if (sector.kind === 'outpost') return `the ${sector.civ ?? 'alien'} outpost`;
  return 'empty space';
}

/**
 * Turn one face-down sector face up. For a system the discs are drawn from
 * the per-icon pools through `rng` and flipped immediately. Returns false
 * when the sector was already discovered.
 */
export function discoverSector(state: GameState, sector: Sector, rng: Rng | undefined): boolean {
  if (sector.discovered) return false;
  sector.discovered = true;
  if (sector.kind !== 'system') {
    logEvent(state, `Sector ${sector.id} discovered: ${describeTile(sector)} (${sector.tileId})`);
    return true;
  }
  for (const planet of planetsOfSector(state.board, sector.id)) {
    if (planet.disc || !planet.icon) continue;
    const pool = state.discPools[planet.icon];
    if (pool.length === 0) throw new Error(`discoverSector: no ${planet.icon} disc left for ${planet.id}`);
    if (!rng) throw new Error('discoverSector: an rng is needed to draw number discs');
    const [label] = pool.splice(rng.int(pool.length), 1) as [string];
    planet.disc = makeDisc(`disc:${planet.icon}:${sector.id}:${label}`, planet.icon, label, false);
  }
  const revealed = flipSystemDiscs(state, sector);
  logEvent(state, `Sector ${sector.id} discovered: ${describeTile(sector)} (${sector.tileId}); discs ${revealed.join(', ')} revealed`);
  return true;
}

/** Discover every face-down sector touching the node; returns the sector ids turned over. */
export function discoverAt(state: GameState, nodeId: NodeId, rng: Rng | undefined): SectorId[] {
  const found: SectorId[] = [];
  for (const sector of undiscoveredSectorsTouchingNode(state.board, nodeId)) {
    if (discoverSector(state, sector, rng)) found.push(sector.id);
  }
  return found;
}
