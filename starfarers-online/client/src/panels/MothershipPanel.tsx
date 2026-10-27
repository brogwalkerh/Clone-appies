import { BALL_VALUES, UPGRADE_CAPS, speedOf, type GameState, type PlayerId } from '@starfarers/shared';

const BALL_COLOR = { yellow: '#f1c40f', red: '#e74c3c', blue: '#3498db', black: '#111' } as const;

/** Boosters / cannons / freight pods as icons, plus the last shake's two balls (spec §14). */
export function MothershipPanel({ state, viewer }: { state: GameState; viewer: PlayerId | null }) {
  const me = state.players.find((p) => p.id === viewer);
  if (!me) return null;
  const m = me.mothership;
  const isActive = state.activePlayer === me.id;
  const shake = isActive ? state.turn.shake : undefined;
  const rows: [string, number, number, string][] = [
    ['Boosters', m.boosters, UPGRADE_CAPS.booster, '▲'],
    ['Cannons', m.cannons, UPGRADE_CAPS.cannon, '✦'],
    ['Freight pods', m.freightPods, UPGRADE_CAPS.freightPod, '▣'],
  ];
  return (
    <section className="panel" data-testid="mothership-panel">
      <h3>Mothership</h3>
      <ul className="upgrades">
        {rows.map(([label, n, cap, glyph]) => (
          <li key={label}>
            <span className="label">{label}</span>
            <span className="icons" aria-label={`${n} of ${cap}`}>
              {Array.from({ length: cap }, (_, i) => (
                <span key={i} className={i < n ? 'icon on' : 'icon'}>
                  {glyph}
                </span>
              ))}
            </span>
            <span className="muted">
              {n}/{cap}
            </span>
          </li>
        ))}
      </ul>
      <div className="cards-held muted">
        Friendship cards: {me.friendshipCards.length} · Speed this turn: {isActive && state.turn.baseSpeed !== undefined ? speedOf(state, me.id) : '—'}
      </div>
      {shake && (
        <div className="shake" data-testid="shake-result">
          {shake.map((ball, i) => (
            <span key={i} className="ball" style={{ background: BALL_COLOR[ball], animationDelay: `${i * 0.25}s` }} title={`${ball} = ${BALL_VALUES[ball]}`}>
              {BALL_VALUES[ball]}
            </span>
          ))}
          <span className="muted">
            base {state.turn.baseSpeed} → speed {state.turn.speed}
            {shake.includes('black') ? ' · encounter!' : ''}
          </span>
        </div>
      )}
    </section>
  );
}
