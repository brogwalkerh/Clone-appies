import type { GameState } from '@starfarers/shared';
import { useGame } from '../store/gameStore.js';
import { playerColor, playerName } from '../ui/format.js';

/** Full-screen "pass the laptop" curtain shown whenever another seat must act (HANDOFF §6.2). */
export function PassBanner({ state }: { state: GameState }) {
  const pending = useGame((s) => s.pendingViewer);
  const acknowledge = useGame((s) => s.acknowledgeViewer);
  if (!pending) return null;
  return (
    <div className="curtain" data-testid="pass-banner">
      <div className="curtain-card" style={{ borderColor: playerColor(state, pending) }}>
        <h2>Pass the laptop to {playerName(state, pending)}</h2>
        <p className="muted">Hands are hidden until they take the seat.</p>
        <button type="button" data-testid="take-seat" onClick={acknowledge}>
          I am {playerName(state, pending)}
        </button>
      </div>
    </div>
  );
}
