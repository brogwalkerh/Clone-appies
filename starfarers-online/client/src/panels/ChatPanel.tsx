import { useState } from 'react';
import { useStore } from 'zustand';
import type { RemoteStore } from '../net/remoteStore.js';

/** Room chat (server-side message list, not game state). */
export function ChatPanel({ store }: { store: RemoteStore }) {
  const chat = useStore(store, (s) => s.chat);
  const sendChat = useStore(store, (s) => s.sendChat);
  const me = useStore(store, (s) => s.session?.playerId);
  const [text, setText] = useState('');
  return (
    <section className="panel chat" data-testid="chat-panel">
      <h3>Chat</h3>
      <ol className="chat-list">
        {chat.map((m, i) => (
          // `from: 'timer'` marks the server's turn-timer lines (HANDOFF §8.2).
          <li key={`${m.at}-${i}`} className={m.from === me ? 'mine' : m.from === 'timer' ? 'system muted' : ''} data-testid={m.from === 'timer' ? 'chat-timer' : undefined}>
            <strong>{m.name}</strong> {m.text}
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
