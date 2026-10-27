import { WIN_VP, type GameVariant } from '@starfarers/shared';
import { describe, expect, it } from 'vitest';
import { RoomStore } from '../src/rooms.js';
import { botRandom, nextAction } from './bot.js';

/**
 * Whole games through the room store with the greedy bot. The bot only sends
 * actions it believes legal, so every rejection is a real disagreement between
 * the bot's reading of the rules and the engine — those are counted and must
 * be zero, and every game must end with a winner at WIN_VP.
 */
function playGame(seed: string, botSeed: number, maxActions = 6000, variant: GameVariant = 'beginner') {
  const store = new RoomStore({ seedFactory: () => seed });
  const created = store.createRoom('bots', 'Ann');
  if (!created.ok) throw new Error('create');
  const room = created.value.room;
  store.joinRoom(room.code, 'Bob');
  store.joinRoom(room.code, 'Cid');
  if (botSeed % 2 === 0) store.joinRoom(room.code, 'Dee');
  expect(store.configureRoom(room, 'p1', { variant }).ok).toBe(true);
  expect(store.startGame(room, 'p1').ok).toBe(true);
  const rnd = botRandom(botSeed);
  let rejected = 0;
  let actions = 0;
  const rejections: string[] = [];
  let lastKey = '';
  let stuck = 0;
  while (actions < maxActions) {
    const game = room.game!;
    const a = nextAction(game, rnd);
    if (!a) break;
    const r = store.applyAction(room, a.playerId, a);
    actions++;
    if (!r.ok) {
      rejected++;
      rejections.push(`${a.type} by ${a.playerId} in ${game.phase}: ${r.error.message}`);
      const key = `${game.turnNumber}:${game.phase}:${a.type}:${game.log.length}`;
      if (key === lastKey && ++stuck > 3) break;
      lastKey = key;
      // Fall back to ending the turn / declining so the game keeps moving.
      if (a.type === 'endTurn' || game.phase === 'flight.encounter') break;
      store.applyAction(room, game.activePlayer, { type: 'endTurn', playerId: game.activePlayer });
    } else {
      stuck = 0;
    }
  }
  return { room, actions, rejected, rejections };
}

describe('full games through the room store', () => {
  for (const [seed, botSeed] of [
    ['full-game-a', 1],
    ['full-game-b', 2],
    ['full-game-c', 3],
  ] as const) {
    it(`seed ${seed}: ends with a winner at ${WIN_VP} VP or runs long without engine faults`, () => {
      const { room, actions, rejected, rejections } = playGame(seed, botSeed);
      const game = room.game!;
      expect(rejected, rejections.join('\n')).toBe(0);
      expect(game.winner, `no winner after ${actions} actions, turn ${game.turnNumber}`).not.toBeNull();
      expect(game.phase).toBe('gameOver');
      expect(game.players.find((p) => p.id === game.winner)!.vp).toBeGreaterThanOrEqual(WIN_VP);
      expect(game.turnNumber).toBeGreaterThan(20);
      expect(room.actions).toHaveLength(actions - rejected);
      // Card conservation across the whole game.
      const cards = Object.values(game.supply).reduce((a, b) => a + b, 0) + game.reservePile.length + game.players.reduce((n, p) => n + p.hand.length, 0);
      expect(cards).toBe(100);
    });
  }
});

describe('full games on the variable set-ups (spec §3.2)', () => {
  for (const [variant, seed, botSeed] of [
    ['strategic', 'full-strategic', 4],
    ['explorer', 'full-explorer', 5],
    ['wild', 'full-wild', 6],
  ] as const) {
    it(`${variant}: the bot plays to a win with zero rejections and every tile gets discovered or stays face down consistently`, () => {
      const { room, actions, rejected, rejections } = playGame(seed, botSeed, 8000, variant);
      const game = room.game!;
      expect(rejected, rejections.join('\n')).toBe(0);
      expect(game.variant).toBe(variant);
      expect(game.winner, `no winner after ${actions} actions, turn ${game.turnNumber}`).not.toBeNull();
      expect(game.players.find((p) => p.id === game.winner)!.vp).toBeGreaterThanOrEqual(WIN_VP);
      // Discs are conserved: every discovered system drew exactly 3 from the pools; hidden systems hold none.
      const discovered = Object.values(game.board.sectors).filter((s) => s.region !== 'catanian' && s.discovered);
      if (variant !== 'strategic') {
        expect(discovered.length).toBeGreaterThan(0);
        const hiddenSystems = Object.values(game.board.sectors).filter((s) => s.kind === 'system' && !s.discovered);
        for (const s of hiddenSystems) for (const id of s.planetIds) expect(game.board.planets[id]!.disc).toBeNull();
        const pooled = game.discPools.tri.length + game.discPools.br.length + game.discPools.hex.length;
        expect(pooled).toBe(24 - 3 * discovered.filter((s) => s.kind === 'system').length);
      }
      // No ship ever rests inside an undiscovered slot.
      for (const ship of Object.values(game.board.ships)) {
        const node = game.board.nodes[ship.nodeId]!;
        if (node.sectorId) expect(game.board.sectors[node.sectorId]!.discovered).toBe(true);
      }
    });
  }
});
