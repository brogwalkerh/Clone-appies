/**
 * Online screens (HANDOFF §7): create / join / rejoin a room, then the room
 * lobby (players, host's Start button, chat) until the game starts.
 */

import {
  GAME_VARIANTS,
  GAME_VARIANT_DESCRIPTIONS,
  GAME_VARIANT_LABELS,
  SETUP_MODES,
  SETUP_MODE_DESCRIPTIONS,
  SETUP_MODE_LABELS,
  type GameVariant,
  type SetupMode,
} from '@starfarers/shared';
import { useEffect, useState } from 'react';
import { useStore } from 'zustand';
import type { RemoteStore } from '../net/remoteStore.js';
import { PLAYER_COLOR } from '../ui/format.js';
import { ChatPanel } from './ChatPanel.js';

export function navigate(hash: string): void {
  window.location.hash = hash;
}

export function JoinScreen({ store, prefillCode }: { store: RemoteStore; prefillCode?: string | undefined }) {
  const session = useStore(store, (s) => s.session);
  const netError = useStore(store, (s) => s.netError);
  const connection = useStore(store, (s) => s.connection);
  const [name, setName] = useState('');
  const [roomName, setRoomName] = useState('');
  const [code, setCode] = useState(prefillCode ?? '');
  const [busy, setBusy] = useState(false);

  const go = async (p: Promise<{ ok: boolean }>) => {
    setBusy(true);
    const r = await p;
    setBusy(false);
    if (r.ok) navigate(`#/room/${store.getState().session?.roomCode ?? ''}`);
  };

  return (
    <div className="setup" data-testid="online-screen">
      <h1>Starfarers Online — play online</h1>
      <p className="muted">
        One player creates a room and shares its code; 3–4 players start. Connection: {connection}.
      </p>
      {session && (
        <div className="open-trade" data-testid="rejoin-box">
          <p>
            You were in room <strong>{session.roomCode}</strong> as {session.playerId}.
          </p>
          <div className="row">
            <button type="button" data-testid="rejoin" disabled={busy} onClick={() => void go(store.getState().resume(session))}>
              Rejoin
            </button>
            <button type="button" className="link" onClick={() => store.getState().leaveRoom()}>
              forget it
            </button>
          </div>
        </div>
      )}
      <label>
        Your name <input value={name} data-testid="player-name" onChange={(e) => setName(e.target.value)} maxLength={24} />
      </label>
      <fieldset>
        <legend>Create a room</legend>
        <label>
          Room name <input value={roomName} data-testid="room-name" onChange={(e) => setRoomName(e.target.value)} placeholder="optional" />
        </label>
        <button type="button" data-testid="create-room" disabled={busy || !name.trim()} onClick={() => void go(store.getState().createRoom(roomName, name))}>
          Create
        </button>
      </fieldset>
      <fieldset>
        <legend>Join a room</legend>
        <label>
          Code <input value={code} data-testid="room-code" onChange={(e) => setCode(e.target.value.toUpperCase())} maxLength={6} />
        </label>
        <button type="button" data-testid="join-room" disabled={busy || !name.trim() || code.trim().length < 6} onClick={() => void go(store.getState().joinRoom(code, name))}>
          Join
        </button>
      </fieldset>
      {netError && <p className="error" data-testid="net-error">{netError}</p>}
      <button type="button" className="link" onClick={() => navigate('#/')}>
        back
      </button>
    </div>
  );
}

export function RoomLobby({ store }: { store: RemoteStore }) {
  const lobby = useStore(store, (s) => s.lobby);
  const session = useStore(store, (s) => s.session);
  const netError = useStore(store, (s) => s.netError);
  const connection = useStore(store, (s) => s.connection);
  const [copied, setCopied] = useState(false);
  useEffect(() => {
    if (!copied) return;
    const t = setTimeout(() => setCopied(false), 1500);
    return () => clearTimeout(t);
  }, [copied]);
  if (!lobby || !session) return null;
  const isHost = lobby.hostId === session.playerId;
  const canStart = lobby.players.length >= lobby.minPlayers && lobby.players.length <= lobby.maxPlayers;
  return (
    <div className="setup" data-testid="room-lobby">
      <h1>{lobby.name}</h1>
      <p>
        Room code <strong data-testid="lobby-code">{lobby.code}</strong>{' '}
        <button
          type="button"
          className="link"
          onClick={() => {
            void navigator.clipboard?.writeText(lobby.code).then(() => setCopied(true));
          }}
        >
          {copied ? 'copied' : 'copy'}
        </button>
        <span className="muted"> · share it; the game starts with {lobby.minPlayers}–{lobby.maxPlayers} players · {connection}</span>
      </p>
      <ul className="others" data-testid="lobby-players">
        {lobby.players.map((p) => (
          <li key={p.id}>
            <span className="swatch" style={{ background: PLAYER_COLOR[p.color] }} />
            <span className="name">
              {p.name}
              {p.isHost ? ' (host)' : ''}
              {p.id === session.playerId ? ' — you' : ''}
            </span>
            <span className="muted">{p.connected ? 'online' : 'offline'}</span>
          </li>
        ))}
      </ul>
      <label>
        Set-up{' '}
        <select
          value={lobby.config.variant}
          disabled={!isHost}
          data-testid="variant-select"
          onChange={(e) => void store.getState().configureRoom({ variant: e.target.value as GameVariant })}
        >
          {GAME_VARIANTS.map((v) => (
            <option key={v} value={v}>
              {GAME_VARIANT_LABELS[v]}
            </option>
          ))}
        </select>{' '}
        <span className="muted" data-testid="lobby-variant">
          {GAME_VARIANT_LABELS[lobby.config.variant]} — {GAME_VARIANT_DESCRIPTIONS[lobby.config.variant]}
          {isHost ? '' : ' (the host chooses)'}
        </span>
      </label>
      <label>
        Start{' '}
        <select
          value={lobby.config.setup}
          disabled={!isHost}
          data-testid="setup-select"
          onChange={(e) => void store.getState().configureRoom({ setup: e.target.value as SetupMode })}
        >
          {SETUP_MODES.map((m) => (
            <option key={m} value={m}>
              {SETUP_MODE_LABELS[m]}
            </option>
          ))}
        </select>{' '}
        <span className="muted" data-testid="lobby-setup">
          {SETUP_MODE_LABELS[lobby.config.setup]} — {SETUP_MODE_DESCRIPTIONS[lobby.config.setup]}
          {isHost ? '' : ' (the host chooses)'}
        </span>
      </label>
      {isHost ? (
        <button type="button" data-testid="start-online" disabled={!canStart} onClick={() => void store.getState().startGame()}>
          Start game ({lobby.players.length} players)
        </button>
      ) : (
        <p className="muted">Waiting for the host to start.</p>
      )}
      {netError && <p className="error" data-testid="net-error">{netError}</p>}
      <ChatPanel store={store} />
      <button
        type="button"
        className="link"
        onClick={() => {
          store.getState().leaveRoom();
          navigate('#/online');
        }}
      >
        leave room
      </button>
    </div>
  );
}
