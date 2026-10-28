/**
 * Outpost glyph layout (HANDOFF §8.4): the dock row sits just below the
 * docking point (the sector's centre vertex) and the civ label goes in the
 * lobe whose centre is farthest from the dock row segment — the lobe the row
 * does not cross — so the two never overlap
 * whatever the tile's orientation (it used to sit 14 px above the centre,
 * crowding the dock row and the docking point on the Diplomats tile). Pure geometry, no rules.
 */

import { hexCenter, vertexPosition, type Sector } from '@starfarers/shared';

export interface Pt {
  x: number;
  y: number;
}

export const DOCK_SPREAD = 16;
export const DOCK_R = 6;
export const DOCK_DY = 4;
export const LABEL_FONT = 11;

export interface OutpostLayout {
  /** Text anchor (middle, baseline) of the civ label. */
  label: Pt;
  docks: Pt[];
}

/** `px` maps board units to SVG pixels (Board.tsx). */
export function outpostLayout(sector: Sector, px: (p: Pt) => Pt): OutpostLayout {
  const centre = px(vertexPosition(sector.centreVertex));
  const n = sector.docks?.length ?? 0;
  const docks = Array.from({ length: n }, (_, i) => ({ x: centre.x + (i - (n - 1) / 2) * DOCK_SPREAD, y: centre.y + DOCK_DY }));
  // Distance from a lobe centre to the dock row (a horizontal segment through the dock centres).
  const rowY = centre.y + DOCK_DY;
  const half = ((Math.max(n, 1) - 1) / 2) * DOCK_SPREAD;
  const toRow = (c: Pt) => Math.hypot(Math.max(0, Math.abs(c.x - centre.x) - half), c.y - rowY);
  let best: Pt = { x: centre.x, y: centre.y - 14 };
  let bestD = -1;
  for (const hex of sector.lobes) {
    const c = px(hexCenter(hex));
    const d = toRow(c);
    if (d > bestD + 1e-6) {
      bestD = d;
      best = c;
    }
  }
  // Vertically centre the text on the lobe centre.
  return { label: { x: best.x, y: best.y + LABEL_FONT * 0.35 }, docks };
}
