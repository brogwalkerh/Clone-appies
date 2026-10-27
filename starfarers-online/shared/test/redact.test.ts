import { describe, expect, it } from 'vitest';
import { ACTION_POLICY, applyAction, computeVp, createBeginnerGame, createGame, createRng, exploreSector, handSize, redactBoard, redactState, validateEndNode, type GameState } from '../src/index.js';

const PLAYERS = [
  { id: 'p1', name: 'Ann', color: 'red' as const },
  { id: 'p2', name: 'Bob', color: 'blue' as const },
  { id: 'p3', name: 'Cid', color: 'yellow' as const },
];

function game(): GameState {
  return createBeginnerGame({ players: PLAYERS, seed: 'redact' });
}

describe('redactState', () => {
  it('keeps the viewer hand, empties the others and records every hand size', () => {
    const s = game();
    const r = redactState(s, 'p2');
    for (const p of r.players) {
      const original = s.players.find((o) => o.id === p.id)!;
      expect(p.handCount).toBe(original.hand.length);
      expect(handSize(p)).toBe(original.hand.length);
      if (p.id === 'p2') expect(p.hand).toEqual(original.hand);
      else expect(p.hand).toEqual([]);
    }
  });

  it('hides the reserve pile, the encounter deck and the seed but keeps their sizes', () => {
    const s = game();
    const r = redactState(s, 'p1');
    expect(r.reservePile).toEqual([]);
    expect(r.reservePileCount).toBe(s.reservePile.length);
    expect(r.encounterDeck).toEqual([]);
    expect(r.encounterDeckCount).toBe(s.encounterDeck.length);
    expect(r.seed).toBe('');
    expect(r.encounterDiscard).toEqual(s.encounterDiscard);
  });

  it('hides the labels, numbers, specials and ids of face-down discs until the system is explored (beginner and strategic)', () => {
    for (const variant of ['beginner', 'strategic'] as const) {
      const s = createGame({ variant, players: PLAYERS, seed: 'redact-discs' });
      const faceDown = Object.values(s.board.planets).filter((p) => p.disc !== null && !p.disc.faceUp);
      expect(faceDown).toHaveLength(24);
      expect(faceDown.some((p) => p.disc!.special !== undefined)).toBe(true); // a P/I disc is among them
      const r = redactState(s, 'p1');
      for (const p of faceDown) {
        const seen = r.board.planets[p.id]!.disc!;
        expect(seen).toEqual({ id: `disc:hidden:${p.id}`, back: p.disc!.back, label: '', numbers: [], faceUp: false });
      }
      // Face-up (Catanian) discs are untouched, the redaction is idempotent and the input is not mutated.
      for (const p of Object.values(s.board.planets).filter((p) => p.disc?.faceUp)) expect(r.board.planets[p.id]!.disc).toEqual(p.disc);
      expect(redactBoard(r.board)).toEqual(r.board);
      expect(Object.values(s.board.planets).filter((p) => p.disc !== null && !p.disc.faceUp)).toHaveLength(24);
      // Once explored the real discs (and tokens) are public.
      const sector = Object.values(s.board.sectors).find((x) => x.kind === 'system' && !x.explored)!;
      expect(exploreSector(s, sector)).toBe(true);
      const after = redactState(s, 'p1');
      for (const id of sector.planetIds) {
        const planet = s.board.planets[id]!;
        expect(after.board.planets[id]!.disc).toEqual(planet.disc);
        expect(after.board.planets[id]!.token).toEqual(planet.token);
      }
    }
  });

  it('hides the order of the reserve discs but not their contents', () => {
    const s = game();
    const r = redactState(s, 'p1');
    expect(r.reserveDiscs.map((d) => d.label)).toEqual([...s.reserveDiscs.map((d) => d.label)].sort((a, b) => Number(a) - Number(b)));
    expect(r.reserveDiscs.map((d) => d.id)).toEqual(r.reserveDiscs.map((_, i) => `disc:reserve:hidden:${i}`));
    // Two seeds with different pile orders look the same to a client.
    const other = createBeginnerGame({ players: PLAYERS, seed: 'redact-other-pile' });
    expect(other.reserveDiscs.map((d) => d.label)).not.toEqual(s.reserveDiscs.map((d) => d.label));
    expect(redactState(other, 'p1').reserveDiscs).toEqual(r.reserveDiscs);
    expect(s.reserveDiscs.map((d) => d.id)).toEqual(s.reserveDiscs.map((d, i) => `disc:reserve:${i}:${d.label}`)); // input untouched
  });

  it('does not mutate the input and leaves public data untouched', () => {
    const s = game();
    const before = structuredClone(s);
    const r = redactState(s, 'p1');
    expect(s).toEqual(before);
    // The board is public apart from its face-down discs (hidden until explored, see above).
    expect({ ...r.board, planets: undefined }).toEqual({ ...s.board, planets: undefined });
    for (const p of Object.values(s.board.planets)) {
      if (p.disc === null || p.disc.faceUp) expect(r.board.planets[p.id]).toEqual(p);
      else expect({ ...r.board.planets[p.id], disc: undefined }).toEqual({ ...p, disc: undefined });
    }
    expect(r.supply).toEqual(s.supply);
    expect(r.players.map((p) => p.vp)).toEqual(s.players.map((p) => p.vp));
  });

  it('strips discard payloads from the log for everyone but the discarder', () => {
    const s = game();
    const active = s.activePlayer;
    const other = s.players.find((p) => p.id !== active)!;
    s.turn.rolled = 7;
    s.turn.seven = { awaitingDiscard: [other.id], stealDone: false };
    other.hand = ['ore', 'ore', 'fuel', 'fuel', 'food', 'food', 'goods', 'goods'];
    const r = applyAction(s, { type: 'discardForSeven', playerId: other.id, cards: ['ore', 'ore', 'fuel', 'fuel'] }, createRng('x'));
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    const entry = r.value.log.find((e) => e.action?.type === 'discardForSeven')!;
    expect(entry).toBeDefined();
    const forOther = redactState(r.value, other.id).log.find((e) => e.seq === entry.seq)!;
    const forActive = redactState(r.value, active).log.find((e) => e.seq === entry.seq)!;
    expect(forOther.action?.type).toBe('discardForSeven');
    expect(forActive.action).toBeUndefined();
    expect(forActive.message).toBe(entry.message);
  });

  it('public helpers still work on a redacted state', () => {
    const s = game();
    s.phase = 'flight.move';
    s.turn.baseSpeed = 3;
    s.turn.speed = 4;
    const r = redactState(s, 'p1');
    expect(computeVp(r, 'p1')).toBe(computeVp(s, 'p1'));
    const ship = Object.values(s.board.ships)[0]!;
    const node = s.board.adjacency[ship.nodeId]![0]!;
    expect(validateEndNode(r, ship, node)).toEqual(validateEndNode(s, ship, node));
    expect(ACTION_POLICY.rollDice.phases).toContain('production');
  });
});
