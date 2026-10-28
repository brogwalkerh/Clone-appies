/**
 * Board animations (spec §14, HANDOFF §8.1). Presentation only: every element
 * is rendered at the position the state says, and an animation is a temporary
 * CSS `transform` on top of it that ends at the identity. The engine is
 * untouched.
 *
 * Trigger: a `BoardMotion` whose `seq` changes. `useBoardMotion` bumps `seq`
 * exactly when ONE new accepted action lands while the shown state is live —
 * the last `actions[]` entry, which the hot-seat store appends in `dispatch`
 * and the remote store appends from the action attached to each `state`
 * broadcast. Scrubbing the replay slider, returning to live, joining or
 * resuming never bumps it, so replay stays instant. `animate` is false while
 * replaying or under `prefers-reduced-motion: reduce`; then every effect
 * short-circuits and a running animation stops at once.
 */

import type { Action, GameState, NodeId, PlanetId, SectorId } from '@starfarers/shared';
import { useEffect, useLayoutEffect, useRef, useState, type CSSProperties } from 'react';
import { useGame } from '../store/gameStore.js';

/** Time a ship takes per path step. */
export const SHIP_STEP_MS = 180;
/** Delay before the first step so the start offset is painted before the transition begins. */
export const SHIP_START_DELAY_MS = 30;
/** Tile / disc flip duration (keep in step with `.flip` in styles.css). */
export const FLIP_MS = 600;

export interface BoardMotion {
  /** Bumped once per live accepted action; the animation effects key on it. */
  seq: number;
  /** The action that bumped `seq` (null before the first one). */
  action: Action | null;
  /** False while replaying or under `prefers-reduced-motion: reduce`. */
  animate: boolean;
}

export const NO_MOTION: BoardMotion = { seq: 0, action: null, animate: false };

const REDUCED_QUERY = '(prefers-reduced-motion: reduce)';

export function prefersReducedMotion(): boolean {
  if (typeof window === 'undefined' || typeof window.matchMedia !== 'function') return false;
  return window.matchMedia(REDUCED_QUERY).matches;
}

export function useReducedMotion(): boolean {
  const [reduced, setReduced] = useState(prefersReducedMotion);
  useEffect(() => {
    if (typeof window === 'undefined' || typeof window.matchMedia !== 'function') return;
    const mq = window.matchMedia(REDUCED_QUERY);
    const onChange = () => setReduced(mq.matches);
    mq.addEventListener?.('change', onChange);
    return () => mq.removeEventListener?.('change', onChange);
  }, []);
  return reduced;
}

/** Derive the board motion from the store: one bump per live accepted action. */
export function useBoardMotion(): BoardMotion {
  const actions = useGame((s) => s.actions);
  const replayIndex = useGame((s) => s.replayIndex);
  const reduced = useReducedMotion();
  const seen = useRef<{ len: number; seq: number; action: Action | null } | null>(null);
  if (seen.current === null) seen.current = { len: actions.length, seq: 0, action: null };
  const cur = seen.current;
  if (actions.length !== cur.len) {
    // Only a single new action while live animates; a jump (join, resume, new game) just resyncs.
    if (actions.length === cur.len + 1 && replayIndex === null) {
      cur.seq += 1;
      cur.action = actions[actions.length - 1] ?? null;
    }
    cur.len = actions.length;
  }
  return { seq: cur.seq, action: cur.action, animate: replayIndex === null && !reduced };
}

export interface Point {
  x: number;
  y: number;
}

/**
 * Style for a ship glyph sliding along a `moveShip` path. The glyph is drawn
 * at the state's node; the style offsets it to each waypoint in turn (the
 * previous node, then every path node) and clears at the last one, which is
 * the state's node. `undefined` when idle.
 */
export function useShipSlide(shipId: string, nodeId: NodeId, motion: BoardMotion, posOf: (id: NodeId) => Point): CSSProperties | undefined {
  const [slide, setSlide] = useState<{ points: Point[]; i: number; seq: number } | null>(null);
  const prevNode = useRef(nodeId);

  // Layout effects so the start offset is applied before the first paint at the new node.
  useLayoutEffect(() => {
    const from = prevNode.current;
    const action = motion.action;
    if (!motion.animate || !action || action.type !== 'moveShip' || action.shipId !== shipId) return;
    const path = action.path;
    if (path.length === 0 || path[path.length - 1] !== nodeId || from === nodeId) return;
    const points = [from, ...path].map(posOf);
    setSlide({ points, i: 0, seq: motion.seq });
    const timers: ReturnType<typeof setTimeout>[] = [];
    for (let i = 1; i < points.length; i++) {
      timers.push(setTimeout(() => setSlide((s) => (s ? { ...s, i } : s)), SHIP_START_DELAY_MS + (i - 1) * SHIP_STEP_MS));
    }
    timers.push(setTimeout(() => setSlide(null), SHIP_START_DELAY_MS + (points.length - 1) * SHIP_STEP_MS));
    return () => timers.forEach(clearTimeout);
    // Keyed on seq only: a new live accepted action is the one trigger.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [motion.seq]);

  useLayoutEffect(() => {
    if (!motion.animate) setSlide(null);
  }, [motion.animate]);

  useLayoutEffect(() => {
    prevNode.current = nodeId;
  });

  if (!slide || !motion.animate || slide.seq !== motion.seq) return undefined;
  const final = posOf(nodeId);
  const at = slide.points[slide.i] ?? final;
  return {
    transform: `translate(${(at.x - final.x).toFixed(1)}px, ${(at.y - final.y).toFixed(1)}px)`,
    transition: slide.i === 0 ? 'none' : `transform ${SHIP_STEP_MS}ms linear`,
  };
}

export interface Flips {
  sectors: ReadonlySet<SectorId>;
  discs: ReadonlySet<PlanetId>;
}

const NO_FLIPS: Flips = { sectors: new Set(), discs: new Set() };

/** Face-down markers of a (redacted) board: hidden sectors and face-down discs. */
function faceDown(board: GameState['board']): { sectors: Set<SectorId>; discs: Set<PlanetId> } {
  const sectors = new Set<SectorId>();
  const discs = new Set<PlanetId>();
  for (const s of Object.values(board.sectors)) if (s.kind === 'hidden') sectors.add(s.id);
  for (const p of Object.values(board.planets)) if (p.disc && !p.disc.faceUp && !p.token) discs.add(p.id);
  return { sectors, discs };
}

/**
 * Sectors and discs that turned face up with the latest live action
 * (`hidden-<slot>` → the real sector on discovery, a disc on exploration).
 * Takes the redacted board the Board draws. Clears after `FLIP_MS`.
 */
export function useFlips(board: GameState['board'], motion: BoardMotion): Flips {
  const [flips, setFlips] = useState<Flips & { seq: number }>({ ...NO_FLIPS, seq: -1 });
  const prev = useRef(faceDown(board));

  useLayoutEffect(() => {
    const before = prev.current;
    if (!motion.animate || motion.seq === 0) return;
    const now = faceDown(board);
    const sectors = new Set([...before.sectors].filter((id) => !now.sectors.has(id) && board.sectors[id]));
    const discs = new Set([...before.discs].filter((id) => !now.discs.has(id) && board.planets[id]));
    // Planets that appear with a just-discovered tile show their face-up discs flipping with it.
    for (const p of Object.values(board.planets)) if (sectors.has(p.sectorId) && (p.disc?.faceUp || p.token)) discs.add(p.id);
    if (sectors.size === 0 && discs.size === 0) return;
    setFlips({ sectors, discs, seq: motion.seq });
    const t = setTimeout(() => setFlips({ ...NO_FLIPS, seq: -1 }), FLIP_MS);
    return () => clearTimeout(t);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [motion.seq]);

  useLayoutEffect(() => {
    if (!motion.animate) setFlips({ ...NO_FLIPS, seq: -1 });
  }, [motion.animate]);

  useLayoutEffect(() => {
    prev.current = faceDown(board);
  });

  return motion.animate && flips.seq === motion.seq ? flips : NO_FLIPS;
}
