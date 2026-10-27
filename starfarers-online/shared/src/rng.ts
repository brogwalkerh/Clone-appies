/**
 * Seeded, deterministic PRNG. All randomness in `shared/` goes through an `Rng`
 * instance; `Math.random` is never used.
 *
 * Algorithm: xoshiro128** seeded via the cyrb128 string hash.
 */

export interface Rng {
  /** Uniform float in [0, 1). */
  next(): number;
  /** Uniform integer in [0, maxExclusive). */
  int(maxExclusive: number): number;
  /** Returns a new, shuffled copy (Fisher–Yates); the input is not modified. */
  shuffle<T>(arr: readonly T[]): T[];
  /** Uniformly chosen element; throws on an empty array. */
  pick<T>(arr: readonly T[]): T;
  /** One six-sided die, 1–6. */
  d6(): number;
  /** Snapshot of the generator state (4 × uint32), for persistence. */
  getState(): [number, number, number, number];
}

function cyrb128(str: string): [number, number, number, number] {
  let h1 = 1779033703;
  let h2 = 3144134277;
  let h3 = 1013904242;
  let h4 = 2773480762;
  for (let i = 0; i < str.length; i++) {
    const k = str.charCodeAt(i);
    h1 = h2 ^ Math.imul(h1 ^ k, 597399067);
    h2 = h3 ^ Math.imul(h2 ^ k, 2869860233);
    h3 = h4 ^ Math.imul(h3 ^ k, 951274213);
    h4 = h1 ^ Math.imul(h4 ^ k, 2716044179);
  }
  h1 = Math.imul(h3 ^ (h1 >>> 18), 597399067);
  h2 = Math.imul(h4 ^ (h2 >>> 22), 2869860233);
  h3 = Math.imul(h1 ^ (h3 >>> 17), 951274213);
  h4 = Math.imul(h2 ^ (h4 >>> 19), 2716044179);
  return [(h1 ^ h2 ^ h3 ^ h4) >>> 0, (h2 ^ h1) >>> 0, (h3 ^ h1) >>> 0, (h4 ^ h1) >>> 0];
}

function rotl(x: number, k: number): number {
  return ((x << k) | (x >>> (32 - k))) >>> 0;
}

class Xoshiro128StarStar implements Rng {
  private s0: number;
  private s1: number;
  private s2: number;
  private s3: number;

  constructor(state: [number, number, number, number]) {
    [this.s0, this.s1, this.s2, this.s3] = state;
    if ((this.s0 | this.s1 | this.s2 | this.s3) === 0) {
      // All-zero state would be a fixed point.
      this.s0 = 0x9e3779b9;
    }
  }

  private nextUint32(): number {
    const result = (Math.imul(rotl(Math.imul(this.s1, 5) >>> 0, 7), 9) >>> 0);
    const t = (this.s1 << 9) >>> 0;
    this.s2 ^= this.s0;
    this.s3 ^= this.s1;
    this.s1 ^= this.s2;
    this.s0 ^= this.s3;
    this.s2 ^= t;
    this.s3 = rotl(this.s3, 11);
    this.s0 >>>= 0;
    this.s1 >>>= 0;
    this.s2 >>>= 0;
    this.s3 >>>= 0;
    return result;
  }

  next(): number {
    return this.nextUint32() / 4294967296;
  }

  int(maxExclusive: number): number {
    if (!Number.isInteger(maxExclusive) || maxExclusive <= 0) {
      throw new RangeError(`Rng.int: maxExclusive must be a positive integer, got ${maxExclusive}`);
    }
    return Math.floor(this.next() * maxExclusive);
  }

  shuffle<T>(arr: readonly T[]): T[] {
    const out = arr.slice();
    for (let i = out.length - 1; i > 0; i--) {
      const j = this.int(i + 1);
      const tmp = out[i] as T;
      out[i] = out[j] as T;
      out[j] = tmp;
    }
    return out;
  }

  pick<T>(arr: readonly T[]): T {
    if (arr.length === 0) throw new RangeError('Rng.pick: empty array');
    return arr[this.int(arr.length)] as T;
  }

  d6(): number {
    return this.int(6) + 1;
  }

  getState(): [number, number, number, number] {
    return [this.s0, this.s1, this.s2, this.s3];
  }
}

/** Create a generator from a string seed. Same seed ⇒ same sequence. */
export function createRng(seed: string): Rng {
  return new Xoshiro128StarStar(cyrb128(seed));
}

/** Restore a generator from a state captured with `getState()`. */
export function rngFromState(state: [number, number, number, number]): Rng {
  return new Xoshiro128StarStar([...state]);
}
