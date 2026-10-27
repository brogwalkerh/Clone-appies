/**
 * `createGame({ variant, setup, players, seed })` — one entry point for every
 * set-up (spec §3.1–§3.4). Two independent axes: the board `variant` and the
 * starting-piece `setup` ('preset' = §3.3 fixed positions, 'draft' = the §3.4
 * snake draft played in phase 'setup'). The server and the hot-seat client call
 * this; the per-variant constructors stay exported for tests.
 */

import type { GameState, GameVariant, SetupMode } from '../types.js';
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

export const SETUP_MODES: readonly SetupMode[] = ['preset', 'draft'];

export const SETUP_MODE_LABELS: Readonly<Record<SetupMode, string>> = {
  preset: 'Preset start',
  draft: 'Set-up draft',
};

/** One-line description per start mode for the set-up screens. */
export const SETUP_MODE_DESCRIPTIONS: Readonly<Record<SetupMode, string>> = {
  preset: 'Everyone starts on the rulebook positions: 2 colonies, 1 spaceport and a colony ship.',
  draft: 'Advanced set-up: snake draft of 3 colonies each on the Catanian sites, then a spaceport, a ship and a bonus upgrade.',
};

export function isSetupMode(value: unknown): value is SetupMode {
  return typeof value === 'string' && (SETUP_MODES as readonly string[]).includes(value);
}

export interface CreateGameOptions {
  /** Defaults to 'beginner'. */
  variant?: GameVariant | undefined;
  /** Defaults to 'preset'. */
  setup?: SetupMode | undefined;
  players: PlayerSpec[];
  seed: string;
  /** Game id; defaults to the seed. */
  id?: string | undefined;
}

export function createGame(options: CreateGameOptions): GameState {
  const variant = options.variant ?? 'beginner';
  const base: { players: PlayerSpec[]; seed: string; id?: string; setup?: SetupMode } = { players: options.players, seed: options.seed };
  if (options.id !== undefined) base.id = options.id;
  if (options.setup !== undefined) base.setup = options.setup;
  if (variant === 'beginner') return createBeginnerGame(base);
  return createVariableGame(variant, base);
}
