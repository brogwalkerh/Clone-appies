import type { GameState } from '@starfarers/shared';
import { useEffect, useRef } from 'react';
import { useGame } from '../store/gameStore.js';
import { playerColor } from '../ui/format.js';

/** `state.log` newest at the bottom, plus a replay slider over the accepted-action history. */
export function LogPane({ state }: { state: GameState }) {
  const actions = useGame((s) => s.actions);
  const replayIndex = useGame((s) => s.replayIndex);
  const setReplayIndex = useGame((s) => s.setReplayIndex);
  const bottom = useRef<HTMLDivElement>(null);
  useEffect(() => {
    bottom.current?.scrollIntoView?.({ block: 'nearest' });
  }, [state.log.length]);
  const shown = replayIndex ?? actions.length;
  return (
    <section className="panel log" data-testid="log-pane">
      <h3>Log</h3>
      <div className="replay">
        <input
          type="range"
          min={0}
          max={actions.length}
          value={shown}
          aria-label="Replay position"
          onChange={(e) => {
            const v = Number(e.target.value);
            setReplayIndex(v >= actions.length ? null : v);
          }}
        />
        <span className="muted small">{replayIndex === null ? 'live' : `replay ${shown}/${actions.length}`}</span>
        {replayIndex !== null && (
          <button type="button" className="link" onClick={() => setReplayIndex(null)}>
            back to live
          </button>
        )}
      </div>
      <ol className="log-list">
        {state.log.map((e) => (
          <li key={e.seq} className={e.kind} style={{ borderLeftColor: playerColor(state, e.playerId) }}>
            <span className="muted small">T{e.turnNumber}</span> {e.message}
          </li>
        ))}
        <div ref={bottom} />
      </ol>
    </section>
  );
}
