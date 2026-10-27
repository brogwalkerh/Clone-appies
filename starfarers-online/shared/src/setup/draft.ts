/**
 * Advanced set-up draft (spec §3.4) — pure helpers shared by the set-up
 * (`assembleState` creates `state.draft`), the action handlers
 * (actions/draft.ts) and the clients (legal sites, round labels).
 *
 * Snake draft on the 12 Catanian colony sites, `activePlayer` = the current
 * picker: round 1 clockwise from the winner of the opening 2d6 roll (that is
 * `turnOrder`), round 2 counter-clockwise, round 3 clockwise, round 4
 * counter-clockwise starting with the last placer of round 3. Rounds 1–3 place
 * a colony each (`draftColony`); round 4 (`draftFinish`) upgrades one drafted
 * colony to a spaceport, puts a colony or trade ship on one of its two
 * spaceport sites and takes one bonus upgrade from `DRAFT_UPGRADE_POOL`
 * (3 players: one upgrade stays out, `DRAFT_3P_REMOVED_UPGRADE`). When the
 * last pick lands `finishDraft` deals 3 reserve cards and 1 fame piece each,
 * fills the free sites with the 4th colour in a 3-player game
 * (`DRAFT_3P_BLOCK_FREE_SITES`) and opens turn 1 for the starter.
 */

import { DRAFT_3P_BLOCK_FREE_SITES, DRAFT_3P_REMOVED_UPGRADE, DRAFT_COLONY_ROUNDS, DRAFT_UPGRADE_POOL, STARTING_FAME_PIECES, STARTING_HAND_SIZE } from '../config.js';
import { logEvent } from '../actions/handler.js';
import { freshTurnState } from '../actions/turn.js';
import { getPlayer, getSector, isOccupied } from '../board/query.js';
import type { Rng } from '../rng.js';
import { drawFromReserve } from '../supply.js';
import type { DraftState, GameState, NodeId, PlayerId, UpgradeKind } from '../types.js';
import { recomputeAllVp } from '../vp.js';

export type DraftRound = DraftState['round'];

/** Pick order of a round: odd rounds follow `turnOrder` (clockwise from the starter), even rounds reverse it. */
export function draftOrder(round: DraftRound, turnOrder: readonly PlayerId[]): PlayerId[] {
  return round % 2 === 1 ? [...turnOrder] : [...turnOrder].reverse();
}

/**
 * The bonus upgrades offered in round 4. With fewer players than upgrades
 * (3 players) one stays out: `removed` names it, or `'random'` draws it
 * through the rng (the configured default is `DRAFT_3P_REMOVED_UPGRADE`).
 */
export function draftUpgradePool(playerCount: number, removed: UpgradeKind | 'random' = DRAFT_3P_REMOVED_UPGRADE, rng?: Rng): UpgradeKind[] {
  const pool = [...DRAFT_UPGRADE_POOL];
  while (pool.length > playerCount) {
    const out = removed === 'random' ? (rng ? rng.pick(pool) : (pool[0] as UpgradeKind)) : removed;
    const i = pool.indexOf(out);
    if (i < 0) throw new Error(`draft pool ${pool.join(',')} holds no ${out} to leave out`);
    pool.splice(i, 1);
  }
  return pool;
}

/** `state.draft` for a game that has just rolled for its starter (turnOrder set, no pieces placed). */
export function initialDraftState(state: GameState, starter: PlayerId, rng: Rng): DraftState {
  return {
    round: 1,
    order: draftOrder(1, state.turnOrder),
    index: 0,
    starter,
    colonies: Object.fromEntries(state.players.map((p) => [p.id, [] as NodeId[]])),
    pool: draftUpgradePool(state.players.length, DRAFT_3P_REMOVED_UPGRADE, rng),
  };
}

/** Free Catanian colony sites — where a colony may be drafted (rounds 1–3). Sorted by id. */
export function draftableSites(state: GameState): NodeId[] {
  const board = state.board;
  return Object.values(board.nodes)
    .filter((n) => n.siteType === 'colonySite' && n.sectorId !== undefined && getSector(board, n.sectorId).region === 'catanian' && !isOccupied(board, n.id))
    .map((n) => n.id)
    .sort();
}

/** Is the draft in a colony round (1–3) rather than the final round? */
export function isColonyRound(draft: DraftState): boolean {
  return draft.round <= DRAFT_COLONY_ROUNDS;
}

/** The colonies a player drafted that are still plain colonies (round 4 spaceport candidates). */
export function draftSpaceportCandidates(state: GameState, playerId: PlayerId): NodeId[] {
  const picks = state.draft?.colonies[playerId] ?? [];
  return picks.filter((n) => {
    const s = state.board.settlements[n];
    return s !== undefined && s.owner === playerId && s.kind === 'colony';
  });
}

/**
 * Hand the pick to the next player, open the next round, or finish the draft
 * (mutates `state`; the caller has validated and applied the current pick).
 */
export function advanceDraft(state: GameState, rng: Rng): void {
  const draft = state.draft;
  if (!draft) throw new Error('advanceDraft: no draft in progress');
  draft.index += 1;
  if (draft.index < draft.order.length) {
    state.activePlayer = draft.order[draft.index] as PlayerId;
    return;
  }
  if (draft.round < 4) {
    draft.round = (draft.round + 1) as DraftRound;
    draft.order = draftOrder(draft.round, state.turnOrder);
    draft.index = 0;
    state.activePlayer = draft.order[0] as PlayerId;
    logEvent(
      state,
      draft.round <= DRAFT_COLONY_ROUNDS
        ? `Set-up round ${draft.round}: ${getPlayer(state, state.activePlayer).name} places a colony`
        : `Set-up round 4: ${getPlayer(state, state.activePlayer).name} upgrades a colony to a spaceport, places a ship and takes a bonus upgrade`,
      null,
    );
    return;
  }
  finishDraft(state, rng);
}

/**
 * Close the draft (spec §3.4 "then 3 reserve cards + 1 fame piece each"):
 * 3-player blockers on the free sites when `blockFreeSites`, hands dealt in
 * seating order (the same order as the preset set-up), fame pieces, VP
 * recomputed, phase → production with the starter active and a fresh turn.
 */
export function finishDraft(state: GameState, rng: Rng, blockFreeSites: boolean = DRAFT_3P_BLOCK_FREE_SITES): void {
  const draft = state.draft;
  if (!draft) throw new Error('finishDraft: no draft in progress');
  if (state.blockerColor && blockFreeSites) {
    const free = draftableSites(state);
    for (const nodeId of free) state.board.settlements[nodeId] = { nodeId, kind: 'colony', color: state.blockerColor, owner: null };
    if (free.length > 0) logEvent(state, `The unused ${state.blockerColor} colour blocks the free Catanian sites ${free.join(', ')}`, null);
  }
  for (const p of state.players) {
    p.hand.push(...drawFromReserve(state, STARTING_HAND_SIZE, rng));
    p.famePieces += STARTING_FAME_PIECES;
    state.upgradesTray.famePieces -= STARTING_FAME_PIECES;
  }
  delete state.draft;
  state.openTrade = null;
  state.turn = freshTurnState();
  state.activePlayer = draft.starter;
  state.phase = 'production';
  recomputeAllVp(state);
  logEvent(state, `Set-up draft complete: everyone drew ${STARTING_HAND_SIZE} reserve cards and a fame piece; ${getPlayer(state, draft.starter).name} starts turn 1`, null);
}
