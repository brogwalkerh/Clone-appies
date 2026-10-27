/**
 * Per-viewer redaction of the authoritative state (spec §12.1, §13). The
 * server calls this once per socket before emitting `state`; the engine never
 * sees a redacted state.
 *
 * Hidden from a viewer:
 *   - every OTHER player's `hand` (emptied; `handCount` carries the size for all players),
 *   - the order and contents of `reservePile` and `encounterDeck` (emptied; counts kept),
 *   - `seed` (knowing it would let a client replay the rng),
 *   - `log[*].action` payloads that reveal cards other players chose
 *     (`discardForSeven.cards`, `encounterPick.resources` for `payResources` /
 *     `giveOne`), stripped unless the viewer is the actor; the human-readable
 *     `message` stays.
 *
 * The result keeps the `GameState` shape so every pure helper that only reads
 * public data (board queries, VP, action policy, movement validation) works on
 * it unchanged.
 */

import type { Action, GameState, LogEntry, PlayerId } from '../types.js';

/** Actions whose payload names cards that opponents should not see. */
export function actionRevealsHiddenCards(action: Action): boolean {
  switch (action.type) {
    case 'discardForSeven':
      return action.cards.length > 0;
    case 'encounterPick':
      return action.resources !== undefined && action.resources.length > 0;
    default:
      return false;
  }
}

function redactLogEntry(entry: LogEntry, viewerId: PlayerId): LogEntry {
  if (!entry.action || entry.action.playerId === viewerId || !actionRevealsHiddenCards(entry.action)) return entry;
  const { action: _action, ...rest } = entry;
  return rest;
}

export function redactState(state: GameState, viewerId: PlayerId): GameState {
  return {
    ...state,
    seed: '',
    players: state.players.map((p) => ({
      ...p,
      hand: p.id === viewerId ? [...p.hand] : [],
      handCount: p.hand.length,
    })),
    reservePile: [],
    reservePileCount: state.reservePile.length,
    encounterDeck: [],
    encounterDeckCount: state.encounterDeck.length,
    log: state.log.map((e) => redactLogEntry(e, viewerId)),
  };
}

/** Hand size that works on both authoritative and redacted states. */
export function handSize(player: { hand: readonly unknown[]; handCount?: number | undefined }): number {
  return player.handCount ?? player.hand.length;
}
