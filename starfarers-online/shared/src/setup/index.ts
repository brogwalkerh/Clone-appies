/**
 * `createGame({ variant, players, seed })` — one entry point for every set-up
 * (spec §3.1–§3.2). The server and the hot-seat client call this; the
 * per-variant constructors stay exported for tests.
 */

import type { GameState, GameVariant } from '../types.js';
import { createBeginnerGame, type PlayerSpec } from './beginner.js';
import { createVariableGame } from './variants.js';

export const GAME_VARIANTS: readonly GameVariant[] = ['beginner', 'strategic', 'explorer', 'wild'];

export const GAME_VARIANT_LABELS: Readonly<Record<GameVariant, string>> = {
  beginner: 'Beginner',
  strategic: 'Strategic',
  explorer: 'Explorer',
  wild: 'Wild space',
};

/** One-line description per set-up for the set-up screens. */
export const GAME_VARIANT_DESCRIPTIONS: Readonly<Record<GameVariant, string>> = {
  beginner: 'Fixed board from the rulebook; systems are explored when a ship reaches them.',
  strategic: 'Tiles shuffled by region, face up; discs shuffled onto the planets, face down.',
  explorer: 'As strategic, but the tiles are face down and are discovered by your ships.',
  wild: 'All 16 tiles shuffled and dealt face down from the nearest slot to the farthest.',
};

export function isGameVariant(value: unknown): value is GameVariant {
  return typeof value === 'string' && (GAME_VARIANTS as readonly string[]).includes(value);
}

export interface CreateGameOptions {
  /** Defaults to 'beginner'. */
  variant?: GameVariant | undefined;
  players: PlayerSpec[];
  seed: string;
  /** Game id; defaults to the seed. */
  id?: string | undefined;
}

export function createGame(options: CreateGameOptions): GameState {
  const variant = options.variant ?? 'beginner';
  const base = options.id === undefined ? { players: options.players, seed: options.seed } : { players: options.players, seed: options.seed, id: options.id };
  if (variant === 'beginner') return createBeginnerGame(base);
  return createVariableGame(variant, base);
}
