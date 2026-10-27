/**
 * The shipped layout files, parsed once. `layouts/*.json` are the source of
 * truth (CLAUDE.md: load them, do not retype them).
 */

import boardJson from '../../../layouts/board.json' with { type: 'json' };
import beginnerJson from '../../../layouts/beginner.json' with { type: 'json' };
import { parseBoardLayout, parsePlacement, type BoardLayout, type Placement } from './layout.js';

let boardLayoutCache: BoardLayout | undefined;
let beginnerPlacementCache: Placement | undefined;

export function boardLayout(): BoardLayout {
  boardLayoutCache ??= parseBoardLayout(boardJson);
  return boardLayoutCache;
}

export function beginnerPlacement(): Placement {
  beginnerPlacementCache ??= parsePlacement(beginnerJson);
  return beginnerPlacementCache;
}
