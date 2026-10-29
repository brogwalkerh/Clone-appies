/**
 * Board materials: one palette and the shared SVG `<defs>` (gradients, the
 * drop-shadow filters) so the board reads as printed card stock with plastic
 * pieces on it. Presentation only; the colours of resources, civs and players
 * come from ui/format.ts and are shaded here.
 */

import { RESOURCES, type Civ, type PlayerColor, type Resource } from '@starfarers/shared';
import { CIV_COLOR, PLAYER_COLOR, RESOURCE_COLOR } from '../ui/format.js';

export const INK = {
  /** Tile edges and piece outlines: the board's printed line colour. */
  line: '#0a1024',
  lane: '#9fb4e0',
  stud: '#8796bd',
  site: '#eadcae',
  dock: '#e2b552',
  brass: '#c9a24a',
  token: '#f2e8cc',
  tokenRim: '#8a7650',
  tokenInk: '#2a2016',
  tokenHot: '#b3261e',
  tileBack: '#1a2547',
  empty: '#121b38',
  highlight: '#ffd166',
  selected: '#ffffff',
} as const;

/** Mixes a `#rrggbb` colour toward white (amt > 0) or black (amt < 0). */
export function shade(hex: string, amt: number): string {
  const n = parseInt(hex.slice(1), 16);
  const target = amt < 0 ? 0 : 255;
  const t = Math.abs(amt);
  const ch = (v: number) => Math.round(v + (target - v) * t);
  const [r, g, b] = [(n >> 16) & 255, (n >> 8) & 255, n & 255].map(ch) as [number, number, number];
  return `#${((r << 16) | (g << 8) | b).toString(16).padStart(6, '0')}`;
}

const CIVS = Object.keys(CIV_COLOR) as Civ[];
const COLORS = Object.keys(PLAYER_COLOR) as PlayerColor[];

export const tileFill = (r: Resource) => `url(#tile-${r})`;
export const planetFill = (r: Resource) => `url(#planet-${r})`;
export const civFill = (c: Civ) => `url(#civ-${c})`;
export const pieceFill = (c: PlayerColor) => `url(#piece-${c})`;

/** Gradients and filters referenced by Board.tsx. Rendered once inside the board's `<svg>`. */
export function BoardDefs() {
  return (
    <defs>
      {RESOURCES.map((r) => (
        <radialGradient key={`t-${r}`} id={`tile-${r}`} cx="50%" cy="40%" r="65%">
          <stop offset="0%" stopColor={shade(RESOURCE_COLOR[r], -0.25)} />
          <stop offset="100%" stopColor={shade(RESOURCE_COLOR[r], -0.62)} />
        </radialGradient>
      ))}
      {RESOURCES.map((r) => (
        <radialGradient key={`p-${r}`} id={`planet-${r}`} cx="35%" cy="30%" r="75%">
          <stop offset="0%" stopColor={shade(RESOURCE_COLOR[r], 0.45)} />
          <stop offset="45%" stopColor={RESOURCE_COLOR[r]} />
          <stop offset="100%" stopColor={shade(RESOURCE_COLOR[r], -0.55)} />
        </radialGradient>
      ))}
      {CIVS.map((c) => (
        <radialGradient key={`c-${c}`} id={`civ-${c}`} cx="50%" cy="35%" r="70%">
          <stop offset="0%" stopColor={shade(CIV_COLOR[c], 0.08)} />
          <stop offset="100%" stopColor={shade(CIV_COLOR[c], -0.5)} />
        </radialGradient>
      ))}
      {COLORS.map((c) => (
        <linearGradient key={`pc-${c}`} id={`piece-${c}`} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%" stopColor={shade(PLAYER_COLOR[c], 0.35)} />
          <stop offset="55%" stopColor={PLAYER_COLOR[c]} />
          <stop offset="100%" stopColor={shade(PLAYER_COLOR[c], -0.35)} />
        </linearGradient>
      ))}
      <radialGradient id="token-face" cx="40%" cy="35%" r="70%">
        <stop offset="0%" stopColor="#fffaf0" />
        <stop offset="70%" stopColor={INK.token} />
        <stop offset="100%" stopColor="#d9c9a0" />
      </radialGradient>
      <radialGradient id="token-back" cx="40%" cy="35%" r="70%">
        <stop offset="0%" stopColor="#2c3a6b" />
        <stop offset="100%" stopColor="#141c38" />
      </radialGradient>
      <linearGradient id="tile-back" x1="0" y1="0" x2="1" y2="1">
        <stop offset="0%" stopColor="#24305a" />
        <stop offset="100%" stopColor={INK.tileBack} />
      </linearGradient>
      {/* Tiles lie flat (soft, short shadow); tokens and pieces stand up (longer shadow). */}
      <filter id="lay" x="-10%" y="-10%" width="120%" height="125%">
        <feDropShadow dx="0" dy="2" stdDeviation="1.6" floodColor="#000" floodOpacity="0.55" />
      </filter>
      <filter id="stand" x="-30%" y="-30%" width="160%" height="170%">
        <feDropShadow dx="1" dy="2.5" stdDeviation="1.4" floodColor="#000" floodOpacity="0.6" />
      </filter>
    </defs>
  );
}
