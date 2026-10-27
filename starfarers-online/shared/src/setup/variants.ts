/**
 * Variable set-ups (spec §3.1 strategic paragraph, §3.2).
 *
 *   Strategic   1-star tiles (minus one 1-star empty, `STRATEGIC_RETURNED_EMPTY`)
 *               shuffled into the 8 near slots, 2-star tiles into the 7 far
 *               slots, all face up (`discovered`) but systems unexplored; each
 *               Catanian Greek-letter disc trio shuffled within its system; the
 *               24 number discs shuffled per back icon onto the matching planets,
 *               face down — the ordinary `exploreSector` flip then applies.
 *   Explorer    same tiles and Catanian discs, but the 15 slot tiles face DOWN
 *               (`discovered: false`); the number discs wait in
 *               `state.discPools` per icon and are drawn through the rng when a
 *               system is discovered (flight/discover.ts).
 *   Wild space  all 16 tiles shuffled and dealt face down along
 *               `WILD_SPACE_SLOT_ORDER` (nearest → farthest); the 16th tile is
 *               returned to the box unseen. Discs as in explorer.
 *
 * Starting pieces are the beginner positions (spec §3.3; the advanced draft of
 * §3.4 is a later item). Planet orientation on a placed system is
 * `VARIABLE_SETUP_START_LOBE` (config, judgment call). Every random choice
 * goes through the seeded rng, so the seed reproduces the whole board.
 */

import { beginnerPlacement, boardLayout } from '../board/data.js';
import { makeDisc } from '../board/discs.js';
import { hexKey, lobesClockwise } from '../board/geometry.js';
import { buildBoard } from '../board/graph.js';
import { assignPlanetsClockwise, type BoardLayout, type Placement, type SlotPlacement, type TileLayout } from '../board/layout.js';
import { STRATEGIC_RETURNED_EMPTY, VARIABLE_SETUP_START_LOBE, WILD_SPACE_SLOT_ORDER } from '../config.js';
import { createRng, type Rng } from '../rng.js';
import type { Board, DiscIcon, GameState, GameVariant, TileId } from '../types.js';
import { placeUnexploredDiscs } from './beginner.js';
import { assembleState, validatePlayers, type PlayerSpec } from './common.js';

export type VariableVariant = Exclude<GameVariant, 'beginner'>;

export interface VariableGameOptions {
  players: PlayerSpec[];
  seed: string;
  /** Game id; defaults to the seed. */
  id?: string;
  /** Override the layout data (tests). */
  layout?: BoardLayout;
}

export interface TilePlacementResult {
  slots: SlotPlacement[];
  /** The tile that went back to the box. */
  returnedTile: TileId;
}

function slotPlacement(layout: BoardLayout, slotId: string, tile: TileLayout): SlotPlacement {
  const slot = layout.slots.find((s) => s.id === slotId);
  if (!slot) throw new Error(`Unknown slot ${slotId}`);
  const p: SlotPlacement = { slotId, tileId: tile.id };
  if (tile.type === 'system') p.lobes = assignPlanetsClockwise(slot, tile, VARIABLE_SETUP_START_LOBE, lobesClockwise);
  return p;
}

function sortedTiles(layout: BoardLayout): TileLayout[] {
  return Object.values(layout.tiles).sort((a, b) => a.id.localeCompare(b.id));
}

/** Strategic / explorer tile distribution: 1-star → near, 2-star → far, one 1-star empty returned. */
export function strategicTilePlacement(layout: BoardLayout, rng: Rng): TilePlacementResult {
  const tiles = sortedTiles(layout);
  const oneStar = tiles.filter((t) => t.stars === 1);
  const twoStar = tiles.filter((t) => t.stars === 2);
  const oneStarEmpties = oneStar.filter((t) => t.type === 'empty');
  if (oneStarEmpties.length === 0) throw new Error('strategic set-up: no 1-star empty tile to return');
  const returned =
    STRATEGIC_RETURNED_EMPTY === 'random'
      ? rng.pick(oneStarEmpties)
      : oneStarEmpties.find((t) => t.id === STRATEGIC_RETURNED_EMPTY);
  if (!returned) throw new Error(`strategic set-up: ${STRATEGIC_RETURNED_EMPTY} is not a 1-star empty tile`);
  const near = layout.slots.filter((s) => s.region === 'near');
  const far = layout.slots.filter((s) => s.region === 'far');
  const nearTiles = rng.shuffle(oneStar.filter((t) => t.id !== returned.id));
  const farTiles = rng.shuffle(twoStar);
  if (nearTiles.length !== near.length) throw new Error(`strategic set-up: ${nearTiles.length} 1-star tiles for ${near.length} near slots`);
  if (farTiles.length !== far.length) throw new Error(`strategic set-up: ${farTiles.length} 2-star tiles for ${far.length} far slots`);
  const slots = [
    ...near.map((slot, i) => slotPlacement(layout, slot.id, nearTiles[i] as TileLayout)),
    ...far.map((slot, i) => slotPlacement(layout, slot.id, farTiles[i] as TileLayout)),
  ];
  return { slots, returnedTile: returned.id };
}

/** Wild space: all 16 tiles shuffled, dealt along WILD_SPACE_SLOT_ORDER, the 16th returned unseen. */
export function wildTilePlacement(layout: BoardLayout, rng: Rng): TilePlacementResult {
  const shuffled = rng.shuffle(sortedTiles(layout));
  if (WILD_SPACE_SLOT_ORDER.length !== layout.slots.length) {
    throw new Error(`WILD_SPACE_SLOT_ORDER lists ${WILD_SPACE_SLOT_ORDER.length} slots, the board has ${layout.slots.length}`);
  }
  if (shuffled.length !== layout.slots.length + 1) throw new Error(`wild space: ${shuffled.length} tiles for ${layout.slots.length} slots`);
  const slots = WILD_SPACE_SLOT_ORDER.map((slotId, i) => slotPlacement(layout, slotId, shuffled[i] as TileLayout));
  return { slots, returnedTile: (shuffled[layout.slots.length] as TileLayout).id };
}

/** Each Catanian system's Greek-letter trio shuffled within the system, face up. */
function placeShuffledCatanianDiscs(board: Board, layout: BoardLayout, rng: Rng): void {
  for (const sys of layout.catanian) {
    const labels = rng.shuffle(sys.discs);
    sys.lobes.forEach((lobe, i) => {
      const planet = board.planets[`P(${lobe.hex[0]},${lobe.hex[1]})`];
      if (!planet) throw new Error(`No planet at ${hexKey(lobe.hex)}`);
      const label = labels[i] as string;
      planet.disc = makeDisc(`disc:${sys.letter}:${label}`, sys.letter, label, true);
    });
  }
}

const LABELS: Record<VariableVariant, string> = { strategic: 'Strategic', explorer: 'Explorer', wild: 'Wild space' };

export function createVariableGame(variant: VariableVariant, options: VariableGameOptions): GameState {
  validatePlayers(options.players);
  const layout = options.layout ?? boardLayout();
  const rng = createRng(options.seed);

  const tiles = variant === 'wild' ? wildTilePlacement(layout, rng) : strategicTilePlacement(layout, rng);
  const placement: Placement = { slots: tiles.slots };
  const starting = beginnerPlacement().startingPieces;
  if (starting) placement.startingPieces = starting;

  const board = buildBoard(layout, placement);
  placeShuffledCatanianDiscs(board, layout, rng);

  let discPools: Record<DiscIcon, string[]>;
  if (variant === 'strategic') {
    discPools = placeUnexploredDiscs(board, layout, rng);
  } else {
    discPools = { tri: [...layout.numberDiscs.tri], br: [...layout.numberDiscs.br], hex: [...layout.numberDiscs.hex] };
    for (const sector of Object.values(board.sectors)) {
      if (sector.region !== 'catanian') sector.discovered = false;
    }
  }

  return assembleState({
    id: options.id ?? options.seed,
    seed: options.seed,
    variant,
    players: options.players,
    board,
    layout,
    placement,
    discPools,
    rng,
    label: LABELS[variant],
  });
}

export function createStrategicGame(options: VariableGameOptions): GameState {
  return createVariableGame('strategic', options);
}

export function createExplorerGame(options: VariableGameOptions): GameState {
  return createVariableGame('explorer', options);
}

export function createWildSpaceGame(options: VariableGameOptions): GameState {
  return createVariableGame('wild', options);
}
