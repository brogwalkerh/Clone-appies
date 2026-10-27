import { describe, expect, it } from 'vitest';
import { beginnerPlacement, boardLayout } from '../src/board/data.js';
import { hexesAdjacent, hexKey, sharedVertex } from '../src/board/geometry.js';

describe('layouts/board.json', () => {
  const layout = boardLayout();

  it('has the documented grid and 15 slots / 16 tiles', () => {
    expect(layout.grid).toEqual({ rows: 11, cols: 16 });
    expect(layout.slots).toHaveLength(15);
    expect(layout.slots.filter((s) => s.region === 'near')).toHaveLength(8);
    expect(layout.slots.filter((s) => s.region === 'far')).toHaveLength(7);
    const tiles = Object.values(layout.tiles);
    expect(tiles).toHaveLength(16);
    expect(tiles.filter((t) => t.type === 'system')).toHaveLength(8);
    expect(tiles.filter((t) => t.type === 'outpost')).toHaveLength(4);
    expect(tiles.filter((t) => t.type === 'empty')).toHaveLength(4);
    // 9 one-star tiles for 8 near slots (one empty returns to the box), 7 two-star for 7 far slots.
    expect(tiles.filter((t) => t.stars === 1)).toHaveLength(9);
    expect(tiles.filter((t) => t.stars === 2)).toHaveLength(7);
  });

  it('every system tile has one planet per icon', () => {
    for (const t of Object.values(layout.tiles)) {
      if (t.type !== 'system') continue;
      const icons = (t.planets ?? []).map((p) => p.icon).sort();
      expect(icons).toEqual(['br', 'hex', 'tri']);
    }
  });

  it('disc inventory matches the spec (8 per icon, 5 reserve, 3 per Catanian system)', () => {
    expect(layout.numberDiscs.tri).toEqual(['3', '4', '4', '11', '12', '3', '4', '11']);
    expect(layout.numberDiscs.br).toEqual(['2', '5', '5', '6', '9', '5', '8', '9']);
    expect(layout.numberDiscs.hex).toEqual(['10', '10', '10', 'P4', 'P5', 'P6', 'I3', 'I4']);
    expect(layout.numberDiscs.reserve).toEqual(['3', '9', '10', '11', '11']);
    expect(layout.catanian.map((c) => c.discs)).toEqual([
      ['4', '8', '11'],
      ['8', '10', '3/12'],
      ['3', '6', '5'],
      ['2/11', '6', '9'],
    ]);
    for (const sys of layout.catanian) {
      expect(Object.values(sys.beginnerDisc).sort()).toEqual([...sys.discs].sort());
      expect(sys.lobes).toHaveLength(3);
    }
  });

  it('lobes of every slot are mutually adjacent and meet at one vertex', () => {
    for (const slot of layout.slots) {
      const [a, b, c] = slot.lobes as [typeof slot.lobes[0], typeof slot.lobes[0], typeof slot.lobes[0]];
      expect(hexesAdjacent(a, b), `${slot.id} ${hexKey(a)}-${hexKey(b)}`).toBe(true);
      expect(hexesAdjacent(b, c), `${slot.id} ${hexKey(b)}-${hexKey(c)}`).toBe(true);
      expect(hexesAdjacent(a, c), `${slot.id} ${hexKey(a)}-${hexKey(c)}`).toBe(true);
      expect(() => sharedVertex(slot.lobes)).not.toThrow();
    }
  });

  it('Catanian lobes are mutually adjacent too', () => {
    for (const sys of layout.catanian) {
      const hexes = sys.lobes.map((l) => l.hex);
      for (let i = 0; i < 3; i++) {
        for (let j = i + 1; j < 3; j++) {
          expect(hexesAdjacent(hexes[i]!, hexes[j]!), `${sys.letter}`).toBe(true);
        }
      }
      expect(() => sharedVertex(hexes)).not.toThrow();
    }
  });

  it('no two sectors share a hex', () => {
    const seen = new Set<string>();
    for (const slot of layout.slots) for (const l of slot.lobes) {
      expect(seen.has(hexKey(l))).toBe(false);
      seen.add(hexKey(l));
    }
    for (const sys of layout.catanian) for (const l of sys.lobes) {
      expect(seen.has(hexKey(l.hex))).toBe(false);
      seen.add(hexKey(l.hex));
    }
  });
});

describe('layouts/beginner.json', () => {
  const layout = boardLayout();
  const placement = beginnerPlacement();

  it('fills all 15 slots with 15 distinct tiles, leaving one empty tile in the box', () => {
    expect(placement.slots).toHaveLength(15);
    const tiles = placement.slots.map((s) => s.tileId);
    expect(new Set(tiles).size).toBe(15);
    const unused = Object.keys(layout.tiles).filter((t) => !tiles.includes(t));
    expect(unused).toHaveLength(1);
    expect(layout.tiles[unused[0]!]?.type).toBe('empty');
  });

  it('gives every system a lobe map matching its slot and tile', () => {
    for (const p of placement.slots) {
      const tile = layout.tiles[p.tileId]!;
      const slot = layout.slots.find((s) => s.id === p.slotId)!;
      if (tile.type !== 'system') {
        expect(p.lobes).toBeUndefined();
        continue;
      }
      expect(Object.keys(p.lobes!).sort()).toEqual(slot.lobes.map(hexKey).sort());
      expect(Object.values(p.lobes!).sort()).toEqual(tile.planets!.map((pl) => pl.resource).sort());
    }
  });

  it('defines starting pieces for all 4 colours', () => {
    expect(Object.keys(placement.startingPieces!).sort()).toEqual(['blue', 'red', 'white', 'yellow']);
    for (const pieces of Object.values(placement.startingPieces!)) {
      expect(pieces.colonies).toHaveLength(2);
      expect(pieces.spaceport.between.some((h) => hexKey(h) === hexKey(pieces.spaceport.shipSide))).toBe(true);
    }
  });
});
