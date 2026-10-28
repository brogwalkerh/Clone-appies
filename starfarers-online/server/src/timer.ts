/**
 * Turn timer scheduling (spec §13, HANDOFF §8.2). `RoomStore` owns the
 * deadline (`room.deadlineAt`) and what happens on expiry (`expireTurn`);
 * this module only keeps one timeout per room, armed for that deadline.
 *
 * `arm(room)` is called whenever the room's state is broadcast: it is a no-op
 * when the scheduled time already matches, re-schedules when the deadline
 * moved, and clears the timeout when the deadline is `null` (no timer, game
 * over, stopped). `clear(code)` is for swept / deleted rooms; a timeout for a
 * room that is no longer in the store is dropped when it fires. The real
 * scheduler unrefs its handles so a pending timer never keeps Node alive.
 */

import type { Room, RoomStore } from './rooms.js';

export interface Scheduler {
  setTimeout(fn: () => void, ms: number): unknown;
  clearTimeout(handle: unknown): void;
  now(): number;
}

export const realScheduler: Scheduler = {
  setTimeout(fn, ms) {
    const handle = setTimeout(fn, ms);
    handle.unref();
    return handle;
  },
  clearTimeout(handle) {
    clearTimeout(handle as ReturnType<typeof setTimeout>);
  },
  now: () => Date.now(),
};

/** Node caps a timeout at 2^31-1 ms (~24.8 days); a later deadline re-arms when the capped one fires. */
const MAX_DELAY_MS = 2_147_483_647;

export class TurnTimers {
  private readonly pending = new Map<string, { handle: unknown; at: number }>();

  constructor(
    private readonly store: RoomStore,
    private readonly onExpire: (room: Room) => void,
    private readonly scheduler: Scheduler = realScheduler,
  ) {}

  /** Number of armed timeouts (tests). */
  get size(): number {
    return this.pending.size;
  }

  /** The deadline a room's timeout is armed for, if any (tests). */
  armedAt(code: string): number | null {
    return this.pending.get(code)?.at ?? null;
  }

  arm(room: Room): void {
    const at = room.deadlineAt;
    const current = this.pending.get(room.code);
    if (current && current.at === at) return;
    this.clear(room.code);
    if (at === null || !room.started || !room.game) return;
    const delay = Math.min(MAX_DELAY_MS, Math.max(0, at - this.scheduler.now()));
    const handle = this.scheduler.setTimeout(() => {
      if (this.pending.get(room.code)?.handle === handle) this.pending.delete(room.code);
      if (this.store.getRoom(room.code) !== room) return;
      this.onExpire(room);
    }, delay);
    this.pending.set(room.code, { handle, at });
  }

  clear(code: string): void {
    const current = this.pending.get(code);
    if (!current) return;
    this.scheduler.clearTimeout(current.handle);
    this.pending.delete(code);
  }

  clearAll(): void {
    for (const code of [...this.pending.keys()]) this.clear(code);
  }
}
