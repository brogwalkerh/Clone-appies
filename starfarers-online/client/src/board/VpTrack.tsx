import { WIN_VP, type GameState } from '@starfarers/shared';
import { PLAYER_COLOR } from '../ui/format.js';

/** VP track along the board edge (spec §14): one cell per point, player markers stacked inside. */
export function VpTrack({ state }: { state: GameState }) {
  const cells = Array.from({ length: WIN_VP + 1 }, (_, i) => i);
  return (
    <div className="vp-track" data-testid="vp-track" aria-label="Victory point track">
      {cells.map((n) => (
        <div key={n} className={n === WIN_VP ? 'vp-cell win' : 'vp-cell'}>
          <span className="vp-num">{n}</span>
          <span className="vp-markers">
            {state.players
              .filter((p) => Math.min(p.vp, WIN_VP) === n)
              .map((p) => (
                <span key={p.id} className="vp-marker" title={`${p.name}: ${p.vp} VP`} style={{ background: PLAYER_COLOR[p.color] }} />
              ))}
          </span>
        </div>
      ))}
    </div>
  );
}
