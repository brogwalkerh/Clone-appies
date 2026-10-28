/** Display helpers shared by the board and the panels. No game rules live here. */

import {
  FRIENDSHIP_CARDS,
  RESOURCES,
  type ActionType,
  type Civ,
  type FriendshipCardId,
  type GameState,
  type LogEntry,
  type PlayerColor,
  type PlayerId,
  type Resource,
  type ResourceBag,
} from '@starfarers/shared';

/** Planet / card colours, from layouts/board.json → planets (goods is "multicolor"). */
export const RESOURCE_COLOR: Readonly<Record<Resource, string>> = {
  ore: '#c0392b',
  fuel: '#e67e22',
  carbon: '#2980b9',
  food: '#27ae60',
  goods: '#8e44ad',
};

export const RESOURCE_LABEL: Readonly<Record<Resource, string>> = {
  ore: 'Ore',
  fuel: 'Fuel',
  carbon: 'Carbon',
  food: 'Food',
  goods: 'Trade goods',
};

export const PLAYER_COLOR: Readonly<Record<PlayerColor, string>> = {
  red: '#e74c3c',
  blue: '#3498db',
  yellow: '#f1c40f',
  white: '#ecf0f1',
};

export const CIV_LABEL: Readonly<Record<Civ, string>> = {
  greenFolk: 'Green Folk',
  scientists: 'Scientists',
  diplomats: 'Diplomats',
  merchants: 'Merchants',
};

export const CIV_COLOR: Readonly<Record<Civ, string>> = {
  greenFolk: '#1e8449',
  scientists: '#1f618d',
  diplomats: '#7d6608',
  merchants: '#6c3483',
};

export function bagEntries(bag: ResourceBag): [Resource, number][] {
  return RESOURCES.filter((r) => (bag[r] ?? 0) > 0).map((r) => [r, bag[r] as number]);
}

export function bagText(bag: ResourceBag): string {
  const parts = bagEntries(bag).map(([r, n]) => `${n} ${RESOURCE_LABEL[r].toLowerCase()}`);
  return parts.length ? parts.join(', ') : 'nothing';
}

export function bagTotal(bag: ResourceBag): number {
  return bagEntries(bag).reduce((n, [, c]) => n + c, 0);
}

export function handBag(hand: readonly Resource[]): Record<Resource, number> {
  const bag: Record<Resource, number> = { ore: 0, fuel: 0, carbon: 0, food: 0, goods: 0 };
  for (const r of hand) bag[r] += 1;
  return bag;
}

export function playerName(state: GameState, id: PlayerId | null | undefined): string {
  if (!id) return '—';
  return state.players.find((p) => p.id === id)?.name ?? id;
}

export function playerColor(state: GameState, id: PlayerId | null | undefined): string {
  const p = state.players.find((x) => x.id === id);
  return p ? PLAYER_COLOR[p.color] : '#777';
}

export function cardName(id: FriendshipCardId): string {
  return FRIENDSHIP_CARDS[id].name;
}

export function phaseLabel(phase: GameState['phase']): string {
  switch (phase) {
    case 'setup':
      return 'Set-up';
    case 'production':
      return 'Production';
    case 'tradeBuild':
      return 'Trade & Build';
    case 'flight.shake':
      return 'Flight — shake';
    case 'flight.encounter':
      return 'Flight — encounter';
    case 'flight.move':
      return 'Flight — move';
    case 'gameOver':
      return 'Game over';
  }
}

/** Verb phrases for the engine's action log lines, whose `message` is the raw action type. */
export const ACTION_LABEL: Readonly<Record<ActionType, string>> = {
  rollDice: 'rolls the dice',
  takeReserveDraw: 'takes reserve cards',
  discardForSeven: 'discards for the 7',
  stealForSeven: 'steals a card',
  proposeTrade: 'proposes a trade',
  respondTrade: 'answers a trade',
  tradeWithSupply: 'trades with the supply',
  build: 'builds',
  useFriendshipCard: 'plays a friendship card',
  shakeMothership: 'shakes the mothership',
  encounterChoice: 'chooses in the encounter',
  encounterPick: 'picks in the encounter',
  moveShip: 'moves a ship',
  foundColony: 'founds a colony',
  foundTradeStation: 'founds a trade station',
  endTurn: 'ends the turn',
  draftColony: 'drafts a colony site',
  draftFinish: 'finishes the set-up draft',
};

/** A log line as shown: events verbatim, actions as "<player> <verb phrase>". */
export function logText(state: GameState, entry: LogEntry): string {
  if (entry.kind !== 'action' || !entry.action) return entry.message;
  return `${playerName(state, entry.playerId)} ${ACTION_LABEL[entry.action.type] ?? entry.message}`;
}

/** 2..12 → 1..6 ways to roll it (6/8 are 5, 7 is 6). */
export function dicePips(n: number): number {
  return Math.max(0, 6 - Math.abs(7 - n));
}

/** Short node label for logs/buttons: `N(3,4)` → `3,4↑`, `S(3,4)` → `3,4↓`. */
export function shortNode(id: string): string {
  const m = /^([NS])\((\d+),(\d+)\)$/.exec(id);
  if (!m) return id;
  return `${m[2]},${m[3]}${m[1] === 'N' ? '↑' : '↓'}`;
}
