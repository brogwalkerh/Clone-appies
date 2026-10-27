/**
 * Typed views of `layouts/board.json` (the fixed board) and a placement such as
 * `layouts/beginner.json`. `parseBoardLayout` / `parsePlacement` validate the raw
 * JSON once so the graph builder can work with clean, typed data.
 */

import type {
  CatanianLetter,
  Civ,
  DiscIcon,
  HexCoord,
  HexKey,
  PlayerColor,
  Resource,
  SectorKind,
  TileId,
} from '../types.js';
import { CIVS, PLAYER_COLORS, RESOURCES } from '../types.js';
import { hexKey, parseHexKey } from './geometry.js';

export type DiscLabel = string;

export interface CatanianSystemLayout {
  letter: CatanianLetter;
  /** Lobe hex → planet resource. */
  lobes: { hex: HexCoord; resource: Resource }[];
  /** The 3 disc labels of this system (strategic set-up shuffles them). */
  discs: DiscLabel[];
  /** Beginner set-up: lobe hex key → disc label. */
  beginnerDisc: Record<HexKey, DiscLabel>;
}

export interface SlotLayout {
  id: string;
  region: 'near' | 'far';
  lobes: HexCoord[];
}

export interface TilePlanet {
  resource: Resource;
  icon: DiscIcon;
}

export interface TileLayout {
  id: TileId;
  type: SectorKind;
  stars: 1 | 2;
  /** Systems: planets in clockwise order. */
  planets?: TilePlanet[];
  civ?: Civ;
}

export interface BoardLayout {
  grid: { rows: number; cols: number };
  catanian: CatanianSystemLayout[];
  slots: SlotLayout[];
  tiles: Record<TileId, TileLayout>;
  numberDiscs: Record<DiscIcon, DiscLabel[]> & { reserve: DiscLabel[] };
}

export interface SlotPlacement {
  slotId: string;
  tileId: TileId;
  /** Systems: lobe hex key → resource of the planet placed on that lobe. */
  lobes?: Record<HexKey, Resource>;
}

export interface StartingSite {
  system: CatanianLetter;
  between: [HexCoord, HexCoord];
}

export interface StartingPieces {
  spaceport: StartingSite & { shipSide: HexCoord };
  colonies: StartingSite[];
}

export interface Placement {
  slots: SlotPlacement[];
  /** Present for the beginner layout. */
  startingPieces?: Record<PlayerColor, StartingPieces>;
}

// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------

type Json = Record<string, unknown>;

function obj(v: unknown, what: string): Json {
  if (typeof v !== 'object' || v === null || Array.isArray(v)) throw new Error(`layout: ${what} must be an object`);
  return v as Json;
}

function asResource(v: unknown, what: string): Resource {
  if (typeof v !== 'string' || !(RESOURCES as readonly string[]).includes(v)) {
    throw new Error(`layout: ${what} has unknown resource ${String(v)}`);
  }
  return v as Resource;
}

function asHex(v: unknown, what: string): HexCoord {
  if (typeof v === 'string') return parseHexKey(v);
  if (Array.isArray(v) && v.length === 2 && v.every((n) => Number.isInteger(n))) return [v[0] as number, v[1] as number];
  throw new Error(`layout: ${what} is not a hex coordinate`);
}

function asLabel(v: unknown): DiscLabel {
  return typeof v === 'number' ? String(v) : String(v);
}

const CATANIAN_LETTERS: readonly CatanianLetter[] = ['alpha', 'beta', 'gamma', 'delta'];

export function parseBoardLayout(raw: unknown): BoardLayout {
  const root = obj(raw, 'board');
  const grid = obj(root['grid'], 'grid');
  const rows = Number(grid['rows']);
  const cols = Number(grid['cols']);
  if (!Number.isInteger(rows) || !Number.isInteger(cols)) throw new Error('layout: grid rows/cols missing');

  const catRaw = obj(root['catanianColonies'], 'catanianColonies');
  const catanian: CatanianSystemLayout[] = CATANIAN_LETTERS.map((letter) => {
    const sys = obj(catRaw[letter], `catanianColonies.${letter}`);
    const lobesRaw = obj(sys['lobes'], `${letter}.lobes`);
    const lobes = Object.entries(lobesRaw).map(([k, res]) => ({ hex: parseHexKey(k), resource: asResource(res, k) }));
    const discs = (sys['discs'] as unknown[]).map(asLabel);
    const beginnerDisc: Record<HexKey, DiscLabel> = {};
    for (const [k, v] of Object.entries(obj(sys['beginnerDisc'], `${letter}.beginnerDisc`))) {
      beginnerDisc[hexKey(parseHexKey(k))] = asLabel(v);
    }
    return { letter, lobes, discs, beginnerDisc };
  });

  const slotsRaw = obj(root['sectorSlots'], 'sectorSlots');
  const slots: SlotLayout[] = Object.entries(slotsRaw)
    .filter(([k]) => !k.startsWith('_'))
    .map(([id, v]) => {
      const s = obj(v, `slot ${id}`);
      const region = s['region'];
      if (region !== 'near' && region !== 'far') throw new Error(`layout: slot ${id} has bad region`);
      const lobes = (s['lobes'] as unknown[]).map((h, i) => asHex(h, `slot ${id} lobe ${i}`));
      if (lobes.length !== 3) throw new Error(`layout: slot ${id} must have 3 lobes`);
      return { id, region, lobes };
    });

  const tilesRaw = obj(root['sectors'], 'sectors');
  const tiles: Record<TileId, TileLayout> = {};
  for (const [id, v] of Object.entries(tilesRaw)) {
    if (id.startsWith('_')) continue;
    const t = obj(v, `tile ${id}`);
    const type = t['type'];
    if (type !== 'system' && type !== 'outpost' && type !== 'empty') throw new Error(`layout: tile ${id} bad type`);
    const stars = t['stars'] === 2 ? 2 : 1;
    const tile: TileLayout = { id, type, stars };
    if (type === 'system') {
      tile.planets = (t['planets'] as unknown[]).map((p, i) => {
        const pl = obj(p, `tile ${id} planet ${i}`);
        const icon = pl['icon'];
        if (icon !== 'tri' && icon !== 'br' && icon !== 'hex') throw new Error(`layout: tile ${id} planet ${i} bad icon`);
        return { resource: asResource(pl['res'], `tile ${id} planet ${i}`), icon };
      });
      if (tile.planets.length !== 3) throw new Error(`layout: tile ${id} must have 3 planets`);
    }
    if (type === 'outpost') {
      const civ = t['civ'];
      if (typeof civ !== 'string' || !(CIVS as readonly string[]).includes(civ)) throw new Error(`layout: tile ${id} bad civ`);
      tile.civ = civ as Civ;
    }
    tiles[id] = tile;
  }

  const discsRaw = obj(root['numberDiscs'], 'numberDiscs');
  const numberDiscs = {
    tri: (discsRaw['tri'] as unknown[]).map(asLabel),
    br: (discsRaw['br'] as unknown[]).map(asLabel),
    hex: (discsRaw['hex'] as unknown[]).map(asLabel),
    reserve: (discsRaw['reserve'] as unknown[]).map(asLabel),
  };

  return { grid: { rows, cols }, catanian, slots, tiles, numberDiscs };
}

export function parsePlacement(raw: unknown): Placement {
  const root = obj(raw, 'placement');
  const slotsRaw = obj(root['slots'], 'slots');
  const slots: SlotPlacement[] = Object.entries(slotsRaw)
    .filter(([k]) => !k.startsWith('_'))
    .map(([slotId, v]) => {
      const s = obj(v, `placement slot ${slotId}`);
      const tileId = String(s['sector']);
      const p: SlotPlacement = { slotId, tileId };
      if (s['lobes'] !== undefined) {
        const lobes: Record<HexKey, Resource> = {};
        for (const [k, res] of Object.entries(obj(s['lobes'], `placement ${slotId}.lobes`))) {
          lobes[hexKey(parseHexKey(k))] = asResource(res, `${slotId}.lobes.${k}`);
        }
        p.lobes = lobes;
      }
      return p;
    });

  const placement: Placement = { slots };
  if (root['startingPieces'] !== undefined) {
    const spRaw = obj(root['startingPieces'], 'startingPieces');
    const startingPieces = {} as Record<PlayerColor, StartingPieces>;
    for (const color of PLAYER_COLORS) {
      const c = obj(spRaw[color], `startingPieces.${color}`);
      const sp = obj(c['spaceport'], `${color}.spaceport`);
      const site = (v: Json, what: string): StartingSite => {
        const system = v['system'];
        if (typeof system !== 'string' || !(CATANIAN_LETTERS as readonly string[]).includes(system)) {
          throw new Error(`layout: ${what} bad system`);
        }
        const between = v['between'] as unknown[];
        if (!Array.isArray(between) || between.length !== 2) throw new Error(`layout: ${what} bad between`);
        return { system: system as CatanianLetter, between: [asHex(between[0], what), asHex(between[1], what)] };
      };
      startingPieces[color] = {
        spaceport: { ...site(sp, `${color}.spaceport`), shipSide: asHex(sp['shipSide'], `${color}.shipSide`) },
        colonies: (c['colonies'] as unknown[]).map((v, i) => site(obj(v, `${color}.colonies[${i}]`), `${color}.colonies[${i}]`)),
      };
    }
    placement.startingPieces = startingPieces;
  }
  return placement;
}

/**
 * Strategic-set-up helper (not used by the beginner game): assign a system
 * tile's planets to a slot's lobes clockwise, starting at `startLobeIndex`
 * (0–2) of the clockwise lobe order.
 */
export function assignPlanetsClockwise(
  slot: SlotLayout,
  tile: TileLayout,
  startLobeIndex: number,
  lobesClockwise: (lobes: readonly HexCoord[]) => HexCoord[],
): Record<HexKey, Resource> {
  if (!tile.planets) throw new Error(`assignPlanetsClockwise: tile ${tile.id} is not a system`);
  const ordered = lobesClockwise(slot.lobes);
  const out: Record<HexKey, Resource> = {};
  for (let i = 0; i < 3; i++) {
    const hex = ordered[(startLobeIndex + i) % 3] as HexCoord;
    out[hexKey(hex)] = (tile.planets[i] as TilePlanet).resource;
  }
  return out;
}
