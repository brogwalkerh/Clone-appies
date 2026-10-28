import { BALL_VALUES, MAX_SHIPS_ON_BOARD, UPGRADE_CAPS, freeOwnSpaceportSites, shipsOf, speedOf, type GameState, type Player, type PlayerId } from '@starfarers/shared';

const BALL_COLOR = { yellow: '#f1c40f', red: '#e74c3c', blue: '#3498db', black: '#111' } as const;

/**
 * Why a free trade ship (encounter reward, HANDOFF §5.4) is still a marker:
 * the engine places it on the first free site of one of the player's own
 * spaceports as soon as one frees up (found/freeTradeShip.ts).
 */
export function pendingTradeShipNote(state: GameState, me: Player): string | null {
  const n = state.pendingTradeShips[me.id] ?? 0;
  if (n < 1) return null;
  const what = n === 1 ? 'A free trade ship is' : `${n} free trade ships are`;
  const missing: string[] = [];
  if (me.pieces.transportsLeft < 1 || shipsOf(state, me.id).length >= MAX_SHIPS_ON_BOARD) missing.push('a free transport');
  if (me.pieces.stationsLeft < 1) missing.push('a trade station piece');
  const need = missing.length > 0 ? `you have ${missing.join(' and ')}` : '';
  if (freeOwnSpaceportSites(state, me.id).length === 0) {
    return `${what} waiting — all your spaceport sites are occupied. It is placed automatically on the first site of one of your own spaceports that frees up${need ? ` (and once ${need})` : ''}.`;
  }
  return `${what} waiting. It is placed automatically on the first free site of one of your own spaceports once ${need || 'possible'}.`;
}

/** Boosters / cannons / freight pods as icons, plus the last shake's two balls (spec §14). */
export function MothershipPanel({ state, viewer }: { state: GameState; viewer: PlayerId | null }) {
  const me = state.players.find((p) => p.id === viewer);
  if (!me) return null;
  const m = me.mothership;
  const isActive = state.activePlayer === me.id;
  const shake = isActive ? state.turn.shake : undefined;
  const pendingNote = pendingTradeShipNote(state, me);
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
      {pendingNote && (
        <p className="hint" data-testid="pending-trade-ship">
          {pendingNote}
        </p>
      )}
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
