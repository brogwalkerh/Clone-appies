/**
 * Online turn timer countdown (spec §13, HANDOFF §8.2). The server owns the
 * deadline (`deadlineAt` on every `state`) and plays the turn out when it
 * passes; this only shows the time left, corrected by the measured server
 * clock offset. Hidden when the room has no timer or the game is over.
 */

import { useEffect, useState } from 'react';
import { useStore } from 'zustand';
import type { RemoteStore } from '../net/remoteStore.js';
import { playerName } from '../ui/format.js';

/** "off", "30 s", "1 min", "1 min 30 s" … for the lobby picker. */
export function timerLabel(seconds: number | null): string {
  if (seconds === null) return 'off';
  if (seconds < 60) return `${seconds} s`;
  const m = Math.floor(seconds / 60);
  const s = seconds % 60;
  return s === 0 ? `${m} min` : `${m} min ${s} s`;
}

/** Milliseconds left → "m:ss" (rounded up, never negative). */
export function formatCountdown(ms: number): string {
  const total = Math.max(0, Math.ceil(ms / 1000));
  return `${Math.floor(total / 60)}:${String(total % 60).padStart(2, '0')}`;
}

export const TICK_MS = 250;
/** Below this the countdown turns urgent. */
export const URGENT_MS = 10_000;

export function TurnTimer({ store }: { store: RemoteStore }) {
  const deadlineAt = useStore(store, (s) => s.deadlineAt);
  const clockOffset = useStore(store, (s) => s.clockOffset);
  const game = useStore(store, (s) => s.game);
  const [now, setNow] = useState(() => Date.now());

  useEffect(() => {
    if (deadlineAt === null) return;
    setNow(Date.now());
    const id = setInterval(() => setNow(Date.now()), TICK_MS);
    return () => clearInterval(id);
  }, [deadlineAt]);

  if (deadlineAt === null || !game || game.winner !== null || game.phase === 'gameOver') return null;
  const left = deadlineAt - (now + clockOffset);
  return (
    <span className={`turn-timer${left <= URGENT_MS ? ' urgent' : ''}`} data-testid="turn-timer" title="Turn timer: when it runs out the server finishes the turn">
      {playerName(game, game.activePlayer)}: {left > 0 ? formatCountdown(left) : 'time up'}
    </span>
  );
}
