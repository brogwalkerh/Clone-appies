/**
 * Host hand-over scheduling (HANDOFF §8.3, §5.25). `RoomStore` decides when
 * the host role passes on (`handoverDueAt`) and does it
 * (`handOverHostIfDue`); this module keeps one timeout per room armed for
 * that time, like `TurnTimers` does for the turn deadline. `arm(room)` runs on
 * every lobby broadcast (connect, disconnect, host change…): a no-op when the
 * due time is unchanged, re-scheduled when it moved, cleared when it is `null`
 * (host online, or nobody else connected — then the next bind checks it).
 */

import type { Room, RoomStore } from './rooms.js';
import { realScheduler, type Scheduler } from './timer.js';

const MAX_DELAY_MS = 2_147_483_647;

export class HostHandovers {
  private readonly pending = new Map<string, { handle: unknown; at: number }>();

  constructor(
    private readonly store: RoomStore,
    private readonly onDue: (room: Room) => void,
    private readonly scheduler: Scheduler = realScheduler,
  ) {}

  /** The time a room's hand-over timeout is armed for, if any (tests). */
  armedAt(code: string): number | null {
    return this.pending.get(code)?.at ?? null;
  }

  arm(room: Room): void {
    const at = this.store.handoverDueAt(room);
    const current = this.pending.get(room.code);
    if (current && current.at === at) return;
    this.clear(room.code);
    if (at === null) return;
    const delay = Math.min(MAX_DELAY_MS, Math.max(0, at - this.scheduler.now()));
    const handle = this.scheduler.setTimeout(() => {
      if (this.pending.get(room.code)?.handle === handle) this.pending.delete(room.code);
      if (this.store.getRoom(room.code) !== room) return;
      this.onDue(room);
    }, delay);
    this.pending.set(room.code, { handle, at });
  }

  clear(code: string): void {
    const current = this.pending.get(code);
    if (!current) return;
    this.scheduler.clearTimeout(current.handle);
    this.pending.delete(code);
  }
}
