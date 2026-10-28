import type { GameState } from '@starfarers/shared';
import { useEffect, useRef } from 'react';
import { useGame } from '../store/gameStore.js';
import { logText, playerColor } from '../ui/format.js';

/** Debounce for remote replay fetches while the slider is dragged. */
export const REPLAY_FETCH_DELAY_MS = 150;

/** `state.log` newest at the bottom, plus a replay slider over the accepted-action history. */
export function LogPane({ state }: { state: GameState }) {
  const actions = useGame((s) => s.actions);
  const replayIndex = useGame((s) => s.replayIndex);
  const setReplayIndex = useGame((s) => s.setReplayIndex);
  const replayMin = useGame((s) => Math.min(s.replayMin ?? 0, s.actions.length));
  const ensureReplay = useGame((s) => s.ensureReplay);
  // Pin the list to its newest line. Scroll the list itself: scrollIntoView would also scroll the
  // sidebar and push the hand panel out of view on every new line.
  const list = useRef<HTMLOListElement>(null);
  useEffect(() => {
    const el = list.current;
    if (el) el.scrollTop = el.scrollHeight;
  }, [state.log.length]);
  // Ask only once the slider rests: every server-side backward jump replays from the initial state.
  useEffect(() => {
    if (replayIndex === null || !ensureReplay) return;
    const timer = setTimeout(() => void ensureReplay(replayIndex), REPLAY_FETCH_DELAY_MS);
    return () => clearTimeout(timer);
  }, [replayIndex, ensureReplay]);
  const shown = replayIndex ?? actions.length;
  const seek = (v: number) => {
    const clamped = Math.max(replayMin, Math.min(actions.length, v));
    setReplayIndex(clamped >= actions.length ? null : clamped);
  };
  // Explicit keys (same as a native range, but identical across browsers and jsdom): arrows ±1,
  // PageUp/PageDown ±10, Home = first reachable state, End = live. The fetch debounce above still applies.
  const KEY_STEP: Record<string, (v: number) => number> = {
    ArrowLeft: (v) => v - 1,
    ArrowDown: (v) => v - 1,
    ArrowRight: (v) => v + 1,
    ArrowUp: (v) => v + 1,
    PageDown: (v) => v - 10,
    PageUp: (v) => v + 10,
    Home: () => replayMin,
    End: () => actions.length,
  };
  return (
    <section className="panel log" data-testid="log-pane">
      <h3>Log</h3>
      <div className="replay">
        <input
          type="range"
          min={replayMin}
          max={actions.length}
          value={shown}
          aria-label="Replay position"
          aria-valuetext={replayIndex === null ? 'live' : `replay ${shown} of ${actions.length}`}
          data-testid="replay-slider"
          onKeyDown={(e) => {
            const step = KEY_STEP[e.key];
            if (!step) return;
            e.preventDefault();
            seek(step(shown));
          }}
          onChange={(e) => seek(Number(e.target.value))}
        />
        <span className="muted small">{replayIndex === null ? 'live' : `replay ${shown}/${actions.length}`}</span>
        {replayIndex !== null && (
          <button type="button" className="link" onClick={() => setReplayIndex(null)}>
            back to live
          </button>
        )}
      </div>
      <ol className="log-list" ref={list}>
        {state.log.map((e) => (
          <li key={e.seq} className={e.kind} style={{ borderLeftColor: playerColor(state, e.playerId) }}>
            <span className="muted small">T{e.turnNumber}</span> {logText(state, e)}
          </li>
        ))}
      </ol>
    </section>
  );
}
