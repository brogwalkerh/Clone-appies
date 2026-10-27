/** The reconnect token lives in localStorage (HANDOFF §7.3). One session per browser. */

import type { Session } from '@starfarers/shared';

const KEY = 'starfarers.session';

export interface SessionStorageLike {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
  removeItem(key: string): void;
}

function storage(): SessionStorageLike | null {
  try {
    return typeof localStorage === 'undefined' ? null : localStorage;
  } catch {
    return null;
  }
}

export function loadSession(store: SessionStorageLike | null = storage()): Session | null {
  try {
    const raw = store?.getItem(KEY);
    if (!raw) return null;
    const parsed = JSON.parse(raw) as Partial<Session>;
    if (typeof parsed.roomCode !== 'string' || typeof parsed.playerToken !== 'string' || typeof parsed.playerId !== 'string') return null;
    return { roomCode: parsed.roomCode, playerToken: parsed.playerToken, playerId: parsed.playerId };
  } catch {
    return null;
  }
}

export function saveSession(session: Session | null, store: SessionStorageLike | null = storage()): void {
  try {
    if (session) store?.setItem(KEY, JSON.stringify(session));
    else store?.removeItem(KEY);
  } catch {
    /* private mode etc. */
  }
}
