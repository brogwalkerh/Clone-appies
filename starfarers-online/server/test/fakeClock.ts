/** A fake clock and timeout scheduler for the turn-timer tests (no real waiting). */

import type { Scheduler } from '../src/timer.js';

export class Clock {
  t = 1_000_000;
  now = () => this.t;
}

/** Timeouts on a fake clock; `advance` runs whatever falls due, in order. */
export class FakeScheduler implements Scheduler {
  private seq = 0;
  readonly tasks = new Map<number, { fn: () => void; at: number }>();
  constructor(readonly clock: Clock) {}
  setTimeout(fn: () => void, ms: number): unknown {
    const id = ++this.seq;
    this.tasks.set(id, { fn, at: this.clock.t + ms });
    return id;
  }
  clearTimeout(handle: unknown): void {
    this.tasks.delete(handle as number);
  }
  now(): number {
    return this.clock.t;
  }
  advance(ms: number): void {
    const end = this.clock.t + ms;
    for (;;) {
      const due = [...this.tasks.entries()].filter(([, t]) => t.at <= end).sort((a, b) => a[1].at - b[1].at)[0];
      if (!due) break;
      this.tasks.delete(due[0]);
      this.clock.t = Math.max(this.clock.t, due[1].at);
      due[1].fn();
    }
    this.clock.t = end;
  }
}
