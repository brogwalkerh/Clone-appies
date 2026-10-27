/** Number-disc construction from the labels in `layouts/board.json`. */

import type { Disc, DiscBack, DiscId } from '../types.js';

/**
 * Build a disc from its printed label: `"8"`, `"3/12"`, `"P4"` (pirate base,
 * 4 cannons) or `"I3"` (ice planet, 3 freight pods).
 */
export function makeDisc(id: DiscId, back: DiscBack, label: string, faceUp: boolean): Disc {
  const pirate = /^P(\d+)$/.exec(label);
  if (pirate) {
    return { id, back, label, numbers: [], special: { kind: 'pirateBase', value: Number(pirate[1]) }, faceUp };
  }
  const ice = /^I(\d+)$/.exec(label);
  if (ice) {
    return { id, back, label, numbers: [], special: { kind: 'icePlanet', value: Number(ice[1]) }, faceUp };
  }
  const numbers = label.split('/').map((s) => Number(s.trim()));
  if (numbers.some((n) => !Number.isInteger(n) || n < 2 || n > 12)) {
    throw new Error(`makeDisc: bad disc label ${label}`);
  }
  return { id, back, label, numbers, faceUp };
}
