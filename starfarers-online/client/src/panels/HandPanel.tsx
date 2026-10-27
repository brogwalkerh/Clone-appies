import { RESOURCES, type GameState, type PlayerId } from '@starfarers/shared';
import { PLAYER_COLOR, RESOURCE_COLOR, RESOURCE_LABEL, handBag } from '../ui/format.js';

/** Own cards grouped by type; opponents as counts (spec §14 "Hand"). */
export function HandPanel({ state, viewer, hidden }: { state: GameState; viewer: PlayerId | null; hidden: boolean }) {
  const me = state.players.find((p) => p.id === viewer);
  return (
    <section className="panel" data-testid="hand-panel">
      <h3>Hand</h3>
      {me && !hidden ? (
        <div className="hand" data-testid="own-hand">
          {RESOURCES.map((r) => {
            const n = handBag(me.hand)[r];
            return (
              <div key={r} className="card-stack" data-testid={`hand-${r}`} style={{ borderColor: RESOURCE_COLOR[r] }}>
                <span className="card-name">{RESOURCE_LABEL[r]}</span>
                <span className="card-count">{n}</span>
              </div>
            );
          })}
          <div className="hand-total">{me.hand.length} cards</div>
        </div>
      ) : (
        <p className="muted">{hidden ? 'Hidden until the next player takes the seat.' : 'No seat selected.'}</p>
      )}
      <ul className="others">
        {state.players.map((p) => (
          <li key={p.id} data-testid={`player-row-${p.id}`}>
            <span className="swatch" style={{ background: PLAYER_COLOR[p.color] }} />
            <span className={p.id === state.activePlayer ? 'name active' : 'name'}>{p.name}</span>
            <span className="muted">
              {p.hand.length} cards · {p.vp} VP · fame {p.famePieces} · medals {p.medals.pirate}P/{p.medals.ice}I
            </span>
          </li>
        ))}
      </ul>
    </section>
  );
}
