import { describe, expect, it } from 'vitest';
import { createRng, rngFromState } from '../src/rng.js';

describe('rng', () => {
  it('is deterministic for the same seed', () => {
    const a = createRng('seed-1');
    const b = createRng('seed-1');
    const sa = Array.from({ length: 50 }, () => a.next());
    const sb = Array.from({ length: 50 }, () => b.next());
    expect(sa).toEqual(sb);
  });

  it('differs between seeds', () => {
    const a = createRng('seed-1');
    const b = createRng('seed-2');
    const sa = Array.from({ length: 20 }, () => a.int(1000));
    const sb = Array.from({ length: 20 }, () => b.int(1000));
    expect(sa).not.toEqual(sb);
  });

  it('next() stays in [0,1) and int() in range', () => {
    const r = createRng('range');
    for (let i = 0; i < 10_000; i++) {
      const x = r.next();
      expect(x).toBeGreaterThanOrEqual(0);
      expect(x).toBeLessThan(1);
      const n = r.int(7);
      expect(n).toBeGreaterThanOrEqual(0);
      expect(n).toBeLessThan(7);
      expect(Number.isInteger(n)).toBe(true);
    }
    expect(() => r.int(0)).toThrow();
  });

  it('shuffle returns a permutation and leaves the input untouched', () => {
    const r = createRng('shuffle');
    const input = Array.from({ length: 40 }, (_, i) => i);
    const copy = input.slice();
    const out = r.shuffle(input);
    expect(input).toEqual(copy);
    expect(out).toHaveLength(40);
    expect([...out].sort((a, b) => a - b)).toEqual(input);
    expect(out).not.toEqual(input);
  });

  it('shuffle is reasonably uniform', () => {
    const r = createRng('uniform');
    const counts = [0, 0, 0, 0];
    const trials = 4000;
    for (let i = 0; i < trials; i++) {
      const first = r.shuffle([0, 1, 2, 3])[0] as number;
      counts[first] = (counts[first] ?? 0) + 1;
    }
    for (const c of counts) {
      expect(c).toBeGreaterThan(trials / 4 - 150);
      expect(c).toBeLessThan(trials / 4 + 150);
    }
  });

  it('pick and d6 work; state can be restored', () => {
    const r = createRng('pick');
    expect(['a', 'b', 'c']).toContain(r.pick(['a', 'b', 'c']));
    expect(() => r.pick([])).toThrow();
    for (let i = 0; i < 100; i++) {
      const d = r.d6();
      expect(d).toBeGreaterThanOrEqual(1);
      expect(d).toBeLessThanOrEqual(6);
    }
    const snapshot = r.getState();
    const clone = rngFromState(snapshot);
    expect(clone.next()).toBe(r.next());
  });
});
