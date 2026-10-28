import { useState } from 'react';
import { useStore } from 'zustand';
import type { RemoteStore } from '../net/remoteStore.js';

/** Sender ids of the server's own lines: the turn timer (HANDOFF §8.2) and room notices (§8.3); never a player id. */
const SYSTEM_SENDERS = new Set(['timer', 'room']);

/**
 * The text to show after the sender's name. The server writes system lines as
 * "timer: …" / "room: …" (that is how they read in its log); next to the
 * sender's name the prefix would show twice ("Timer timer: …"), so it is dropped.
 */
export function chatText(m: { from: string; text: string }): string {
  const prefix = `${m.from}: `;
  return SYSTEM_SENDERS.has(m.from) && m.text.startsWith(prefix) ? m.text.slice(prefix.length) : m.text;
}

/** Room chat (server-side message list, not game state). */
export function ChatPanel({ store }: { store: RemoteStore }) {
  const chat = useStore(store, (s) => s.chat);
  const sendChat = useStore(store, (s) => s.sendChat);
  const me = useStore(store, (s) => s.session?.playerId);
  // Player ids are reused after a kick (lowest free pN), so an old line of a removed player can carry
  // this seat's id; the name tells them apart (names are unique within a room).
  const myName = useStore(store, (s) => s.lobby?.players.find((p) => p.id === s.session?.playerId)?.name);
  const [text, setText] = useState('');
  return (
    <section className="panel chat" data-testid="chat-panel">
      <h3>Chat</h3>
      <ol className="chat-list">
        {chat.map((m, i) => (
          // `from: 'timer'` marks the server's turn-timer lines (HANDOFF §8.2), `from: 'room'` its host notices (§8.3).
          <li
            key={`${m.at}-${i}`}
            className={m.from === me && m.name === myName ? 'mine' : SYSTEM_SENDERS.has(m.from) ? 'system muted' : ''}
            data-testid={m.from === 'timer' ? 'chat-timer' : m.from === 'room' ? 'chat-room' : undefined}
          >
            <strong>{m.name}</strong> {chatText(m)}
          </li>
        ))}
      </ol>
      <form
        className="row"
        onSubmit={(e) => {
          e.preventDefault();
          const t = text.trim();
          if (!t) return;
          void sendChat(t);
          setText('');
        }}
      >
        <input value={text} onChange={(e) => setText(e.target.value)} placeholder="Say something" aria-label="Chat message" data-testid="chat-input" />
        <button type="submit" data-testid="chat-send">
          Send
        </button>
      </form>
    </section>
  );
}
