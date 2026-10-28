import { WIN_VP, type GameState } from '@starfarers/shared';
import { useRef } from 'react';
import { PLAYER_COLOR } from '../ui/format.js';
import { NO_MOTION, type BoardMotion } from './motion.js';

/** Horizontal spread between markers sharing a cell. */
const STACK_PX = 11;

/**
 * VP track along the board edge (spec §14): one cell per point. The player
 * markers live in an overlay lane, one element per player positioned with a
 * CSS `transform`, so a VP change slides the marker (HANDOFF §8.1). The
 * transition is switched on (`animate` class) only for live accepted actions
 * after the mount or the last return from replay, so scrubbing and going
 * back to live stay instant.
 */
export function VpTrack({ state, motion = NO_MOTION }: { state: GameState; motion?: BoardMotion | undefined }) {
  const cells = Array.from({ length: WIN_VP + 1 }, (_, i) => i);
  const gate = useRef({ animate: motion.animate, quietSeq: motion.seq });
  if (motion.animate && !gate.current.animate) gate.current.quietSeq = motion.seq;
  gate.current.animate = motion.animate;
  const animate = motion.animate && motion.seq !== gate.current.quietSeq;

  const byCell = new Map<number, string[]>();
  for (const p of state.players) {
    const n = Math.min(p.vp, WIN_VP);
    byCell.set(n, [...(byCell.get(n) ?? []), p.id]);
  }
  return (
    <div className={animate ? 'vp-track animate' : 'vp-track'} data-testid="vp-track" aria-label="Victory point track">
      {cells.map((n) => (
        <div key={n} className={n === WIN_VP ? 'vp-cell win' : 'vp-cell'}>
          <span className="vp-num">{n}</span>
        </div>
      ))}
      <div className="vp-lane">
        {state.players.map((p) => {
          const n = Math.min(p.vp, WIN_VP);
          const stack = byCell.get(n) ?? [p.id];
          const k = stack.indexOf(p.id) - (stack.length - 1) / 2;
          return (
            <span
              key={p.id}
              className="vp-slot"
              data-testid={`vp-marker-${p.id}`}
              data-vp={n}
              style={{ transform: `translateX(calc(${n} * (100% + 3px) + ${(k * STACK_PX).toFixed(1)}px))` }}
            >
              <span className="vp-marker" title={`${p.name}: ${p.vp} VP`} style={{ background: PLAYER_COLOR[p.color] }} />
            </span>
          );
        })}
      </div>
    </div>
  );
}
