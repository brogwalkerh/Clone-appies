/**
 * Mothership shake (spec §1 "Ball values", §9.1): reveal 2 of the 5 balls
 * {Y, Y, R, B, K} without replacement.
 *
 * `drawBalls` is pure apart from consuming the rng and is shared by
 * `shakeMothership` and by in-encounter shakes (phase 3), where black counts
 * as 0 and does NOT trigger a second encounter.
 */

import { BALLS_PER_SHAKE, BALL_VALUES, BLACK_BALL_BASE_SPEED, MOTHERSHIP_BALLS, type Ball } from '../config.js';
import type { Rng } from '../rng.js';

export interface ShakeResult {
  balls: Ball[];
  /** Sum of the ball values (black = 0). */
  total: number;
  black: boolean;
  /** Base speed for the flight phase: 3 with a black ball, else the sum. */
  baseSpeed: number;
}

/**
 * Uniformly draw `BALLS_PER_SHAKE` balls without replacement: a Fisher–Yates
 * shuffle of the 5 balls is uniform over orderings, so its first two entries
 * are a uniform ordered draw (P(black among them) = 2/5 = 40%).
 */
export function drawBalls(rng: Rng): Ball[] {
  return rng.shuffle(MOTHERSHIP_BALLS).slice(0, BALLS_PER_SHAKE);
}

export function evaluateShake(balls: readonly Ball[]): ShakeResult {
  const total = balls.reduce((n, b) => n + BALL_VALUES[b], 0);
  const black = balls.includes('black');
  return { balls: [...balls], total, black, baseSpeed: black ? BLACK_BALL_BASE_SPEED : total };
}

export function shake(rng: Rng): ShakeResult {
  return evaluateShake(drawBalls(rng));
}
