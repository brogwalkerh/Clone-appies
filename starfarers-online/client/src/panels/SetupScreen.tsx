import {
  GAME_VARIANTS,
  GAME_VARIANT_DESCRIPTIONS,
  GAME_VARIANT_LABELS,
  PLAYER_COLORS,
  SETUP_MODES,
  SETUP_MODE_DESCRIPTIONS,
  SETUP_MODE_LABELS,
  type GameVariant,
  type PlayerColor,
  type PlayerSpec,
  type SetupMode,
} from '@starfarers/shared';
import { useState } from 'react';
import { useGame } from '../store/gameStore.js';
import { PLAYER_COLOR } from '../ui/format.js';

const DEFAULT_NAMES = ['Ann', 'Bob', 'Cid', 'Dee'];

/** New-game form: set-up variant, start mode, 3–4 seats, names, colours, seed. */
export function SetupScreen() {
  const newGame = useGame((s) => s.newGame);
  const [variant, setVariant] = useState<GameVariant>('beginner');
  const [setupMode, setSetupMode] = useState<SetupMode>('preset');
  const [count, setCount] = useState(3);
  const [names, setNames] = useState<string[]>(DEFAULT_NAMES);
  const [colors, setColors] = useState<PlayerColor[]>([...PLAYER_COLORS]);
  const [seed, setSeed] = useState(() => `game-${Math.random().toString(36).slice(2, 8)}`);
  const seats = Array.from({ length: count }, (_, i) => i);
  const duplicateColors = new Set(colors.slice(0, count)).size !== count;

  return (
    <div className="setup" data-testid="setup-screen">
      <h1>Starfarers Online — hot-seat</h1>
      <p className="muted">Everyone shares this screen; hands are hidden when the seat changes.</p>
      <label>
        Set-up{' '}
        <select value={variant} onChange={(e) => setVariant(e.target.value as GameVariant)} data-testid="variant-select">
          {GAME_VARIANTS.map((v) => (
            <option key={v} value={v}>
              {GAME_VARIANT_LABELS[v]}
            </option>
          ))}
        </select>
      </label>
      <p className="muted small" data-testid="variant-description">{GAME_VARIANT_DESCRIPTIONS[variant]}</p>
      <label>
        Start{' '}
        <select value={setupMode} onChange={(e) => setSetupMode(e.target.value as SetupMode)} data-testid="setup-select">
          {SETUP_MODES.map((m) => (
            <option key={m} value={m}>
              {SETUP_MODE_LABELS[m]}
            </option>
          ))}
        </select>
      </label>
      <p className="muted small" data-testid="setup-description">{SETUP_MODE_DESCRIPTIONS[setupMode]}</p>
      <label>
        Players{' '}
        <select value={count} onChange={(e) => setCount(Number(e.target.value))} data-testid="player-count">
          <option value={3}>3</option>
          <option value={4}>4</option>
        </select>
      </label>
      <table className="seats">
        <tbody>
          {seats.map((i) => (
            <tr key={i}>
              <td>Seat {i + 1}</td>
              <td>
                <input value={names[i] ?? ''} data-testid={`name-${i}`} onChange={(e) => setNames(names.map((n, j) => (j === i ? e.target.value : n)))} />
              </td>
              <td>
                <select value={colors[i]} data-testid={`color-${i}`} onChange={(e) => setColors(colors.map((c, j) => (j === i ? (e.target.value as PlayerColor) : c)))}>
                  {PLAYER_COLORS.map((c) => (
                    <option key={c} value={c}>
                      {c}
                    </option>
                  ))}
                </select>
                <span className="swatch" style={{ background: PLAYER_COLOR[colors[i] ?? 'red'] }} />
              </td>
            </tr>
          ))}
        </tbody>
      </table>
      <label>
        Seed <input value={seed} data-testid="seed" onChange={(e) => setSeed(e.target.value)} />
      </label>
      {duplicateColors && <p className="error">Each player needs a different colour.</p>}
      <button
        type="button"
        data-testid="start-game"
        disabled={duplicateColors || seats.some((i) => !(names[i] ?? '').trim())}
        onClick={() => {
          const players: PlayerSpec[] = seats.map((i) => ({ id: `p${i + 1}`, name: (names[i] ?? '').trim(), color: colors[i] as PlayerColor }));
          newGame({ players, seed: seed.trim() || 'default', variant, setup: setupMode });
        }}
      >
        Start game
      </button>
    </div>
  );
}
