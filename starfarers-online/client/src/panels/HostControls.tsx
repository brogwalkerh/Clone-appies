/**
 * Host controls (HANDOFF §8.3). The server owns the host role; these show who
 * holds it, the pending automatic hand-over while the host is offline, the
 * room's idle expiry, and in game a small transfer control for the host
 * (`transfer-host` select + `transfer-host-confirm`). The per-player kick /
 * make-host buttons live in the room lobby (OnlineLobby.tsx).
 */

import { useState } from 'react';
import { useStore } from 'zustand';
import type { RemoteStore } from '../net/remoteStore.js';

function clockTime(ms: number): string {
  return new Date(ms).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
}

/** "Host: Ann" (+ the pending hand-over while the host is offline). Everyone sees it. */
export function HostNotice({ store }: { store: RemoteStore }) {
  const lobby = useStore(store, (s) => s.lobby);
  if (!lobby) return null;
  const host = lobby.players.find((p) => p.id === lobby.hostId);
  const handover = lobby.hostHandoverAt ?? null;
  return (
    <p className="muted" data-testid="lobby-host">
      Host: <strong>{host?.name ?? lobby.hostId}</strong>
      {host && !host.connected && handover !== null ? ` — offline; the host role passes to the longest-connected player at ${clockTime(handover)}` : ''}
    </p>
  );
}

/** When the room is deleted if nothing happens (server `updatedAt + idleMs`, moved on by chat seen since). */
export function LobbyExpiry({ store }: { store: RemoteStore }) {
  const lobby = useStore(store, (s) => s.lobby);
  const chat = useStore(store, (s) => s.chat);
  if (!lobby || lobby.expiresAt === undefined) return null;
  const idleMs = lobby.idleMs ?? 0;
  const expiresAt = Math.max(lobby.expiresAt, ...chat.map((m) => m.at + idleMs));
  const hours = Math.round(idleMs / 3_600_000);
  return (
    <p className="muted" data-testid="lobby-expires" data-expires-at={expiresAt}>
      Room expires {new Date(expiresAt).toLocaleString([], { weekday: 'short', hour: '2-digit', minute: '2-digit' })} if nobody is in it and nothing
      happens{hours > 0 ? ` (${hours} h without activity)` : ''}.
    </p>
  );
}

/** In game: who hosts, and for the host a select + confirm to hand the role on. */
export function GameHostControls({ store }: { store: RemoteStore }) {
  const lobby = useStore(store, (s) => s.lobby);
  const session = useStore(store, (s) => s.session);
  const [target, setTarget] = useState('');
  if (!lobby || !session) return null;
  const host = lobby.players.find((p) => p.id === lobby.hostId);
  const isHost = lobby.hostId === session.playerId;
  const others = lobby.players.filter((p) => p.id !== session.playerId);
  const chosen = others.some((p) => p.id === target) ? target : '';
  return (
    <span className="host-controls" data-testid="game-host">
      host {host?.name ?? lobby.hostId}
      {isHost ? ' (you)' : ''}
      {isHost && others.length > 0 && (
        <>
          {' '}
          <select value={chosen} onChange={(e) => setTarget(e.target.value)} data-testid="transfer-host" aria-label="Make host">
            <option value="">make host…</option>
            {others.map((p) => (
              <option key={p.id} value={p.id}>
                {p.name}
              </option>
            ))}
          </select>{' '}
          <button
            type="button"
            className="link"
            data-testid="transfer-host-confirm"
            disabled={!chosen}
            onClick={() => {
              void store.getState().transferHost(chosen);
              setTarget('');
            }}
          >
            confirm
          </button>
        </>
      )}
    </span>
  );
}
