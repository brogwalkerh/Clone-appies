import { WIN_VP } from '@starfarers/shared';
import { describe, expect, it } from 'vitest';
import { RoomStore } from '../src/rooms.js';
import { botRandom, nextAction } from './bot.js';

/**
 * Whole games through the room store with the greedy bot. The bot only sends
 * actions it believes legal, so every rejection is a real disagreement between
 * the bot's reading of the rules and the engine — those are counted and must
 * be zero, and every game must end with a winner at WIN_VP.
 */
function playGame(seed: string, botSeed: number, maxActions = 6000) {
  const store = new RoomStore({ seedFactory: () => seed });
  const created = store.createRoom('bots', 'Ann');
  if (!created.ok) throw new Error('create');
  const room = created.value.room;
  store.joinRoom(room.code, 'Bob');
  store.joinRoom(room.code, 'Cid');
  if (botSeed % 2 === 0) store.joinRoom(room.code, 'Dee');
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
