/**
 * Beginner set-up (spec §3.1, §3.3, §3.5; data in layouts/beginner.json).
 * The other set-ups live in setup/variants.ts; `createGame` (setup/index.ts)
 * dispatches on the variant.
 */

import { buildBoard } from '../board/graph.js';
import { makeDisc } from '../board/discs.js';
import { beginnerPlacement, boardLayout } from '../board/data.js';
import { hexKey } from '../board/geometry.js';
import type { BoardLayout, Placement } from '../board/layout.js';
import { createRng, type Rng } from '../rng.js';
import type { Board, DiscIcon, GameState, Sector } from '../types.js';
import { assembleState, validatePlayers, type PlayerSpec } from './common.js';

export type { PlayerSpec } from './common.js';

export interface BeginnerGameOptions {
  players: PlayerSpec[];
  seed: string;
  /** Game id; defaults to the seed. */
  id?: string;
  /** Override the layout data (tests). */
  layout?: BoardLayout;
  placement?: Placement;
}

/** Catanian discs face up, exactly as `beginnerDisc` lists them. */
function placeCatanianDiscs(board: Board, layout: BoardLayout): void {
  for (const sys of layout.catanian) {
    for (const lobe of sys.lobes) {
      const label = sys.beginnerDisc[hexKey(lobe.hex)];
      if (!label) throw new Error(`No beginner disc for ${sys.letter} lobe ${hexKey(lobe.hex)}`);
      const planet = board.planets[`P(${lobe.hex[0]},${lobe.hex[1]})`];
      if (!planet) throw new Error(`No planet at ${hexKey(lobe.hex)}`);
      planet.disc = makeDisc(`disc:${sys.letter}:${label}`, sys.letter, label, true);
    }
  }
}

/**
 * Unexplored discs: shuffle per icon, one of each icon per system, face down
 * (beginner and strategic set-ups). Returns the labels left over per icon
 * (none when all 8 systems are on the board).
 */
export function placeUnexploredDiscs(board: Board, layout: BoardLayout, rng: Rng): Record<DiscIcon, string[]> {
  const systems = unexploredSystems(board).sort((a, b) => a.id.localeCompare(b.id));
  const icons: DiscIcon[] = ['tri', 'br', 'hex'];
  const leftover: Record<DiscIcon, string[]> = { tri: [], br: [], hex: [] };
  for (const icon of icons) {
    const labels = rng.shuffle(layout.numberDiscs[icon]);
    if (labels.length < systems.length) throw new Error(`Not enough ${icon} discs for ${systems.length} systems`);
    systems.forEach((sector, i) => {
      const planet = sector.planetIds.map((id) => board.planets[id]).find((p) => p?.icon === icon);
      if (!planet) throw new Error(`System ${sector.id} has no ${icon}-icon planet`);
      const label = labels[i] as string;
      planet.disc = makeDisc(`disc:${icon}:${i}:${label}`, icon, label, false);
    });
    leftover[icon] = labels.slice(systems.length);
  }
  return leftover;
}

export function createBeginnerGame(options: BeginnerGameOptions): GameState {
  validatePlayers(options.players);
  const layout = options.layout ?? boardLayout();
  const placement = options.placement ?? beginnerPlacement();
  const rng = createRng(options.seed);

  const board = buildBoard(layout, placement);
  placeCatanianDiscs(board, layout);
  const discPools = placeUnexploredDiscs(board, layout, rng);

  return assembleState({
    id: options.id ?? options.seed,
    seed: options.seed,
    variant: 'beginner',
    players: options.players,
    board,
    layout,
    placement,
    discPools,
    rng,
    label: 'Beginner',
  });
}

/** Sector ids of the unexplored planetary systems, in placement order. */
export function unexploredSystems(board: Board): Sector[] {
  return Object.values(board.sectors).filter((s) => s.kind === 'system' && s.region !== 'catanian');
}
