/**
 * Pieces shared by every set-up (spec §3.3, §3.5): player records, starting
 * pieces on the Catanian sites, the reserve discs, the starting-player roll
 * and the assembly of the `GameState` once the board and its discs exist.
 *
 * `assembleState` consumes the rng in a fixed order (encounter deck, reserve
 * discs, reserve pile, starting hands, starting roll) so a seed keeps meaning
 * the same game whichever set-up produced the board.
 */

import {
  ENCOUNTER_CARD_COUNT,
  STARTING_BOOSTERS,
  STARTING_FAME_PIECES,
  STARTING_HAND_SIZE,
  SUPPLY_PER_RESOURCE,
  UPGRADES_TRAY_TOTAL,
  PIECE_LIMITS,
  friendshipCardsOf,
} from '../config.js';
import { makeDisc } from '../board/discs.js';
import { hexKey, hexEquals, vertexHexes } from '../board/geometry.js';
import { colonySiteBetween, neighborsOf } from '../board/query.js';
import type { BoardLayout, Placement } from '../board/layout.js';
import type { Rng } from '../rng.js';
import { buildReservePile, drawFromReserve } from '../supply.js';
import type {
  Board,
  Civ,
  Disc,
  DiscIcon,
  FriendshipCardId,
  GameState,
  GameVariant,
  Player,
  PlayerColor,
  PlayerId,
  Resource,
} from '../types.js';
import { CIVS, PLAYER_COLORS } from '../types.js';
import { recomputeAllVp } from '../vp.js';

export interface PlayerSpec {
  id: PlayerId;
  name: string;
  color: PlayerColor;
}

export function validatePlayers(players: PlayerSpec[]): void {
  if (players.length < 3 || players.length > 4) throw new Error(`A game needs 3–4 players, got ${players.length}`);
  const ids = new Set(players.map((p) => p.id));
  if (ids.size !== players.length) throw new Error('Player ids must be unique');
  const colors = new Set(players.map((p) => p.color));
  if (colors.size !== players.length) throw new Error('Player colours must be unique');
  for (const p of players) {
    if (!PLAYER_COLORS.includes(p.color)) throw new Error(`Unknown player colour ${p.color}`);
  }
}

export function makeReserveDiscs(layout: BoardLayout, rng: Rng): Disc[] {
  return rng
    .shuffle(layout.numberDiscs.reserve)
    .map((label, i) => makeDisc(`disc:reserve:${i}:${label}`, 'reserve', label, true));
}

export function makePlayer(spec: PlayerSpec): Player {
  return {
    id: spec.id,
    name: spec.name,
    color: spec.color,
    hand: [],
    vp: 0,
    famePieces: STARTING_FAME_PIECES,
    mothership: { boosters: STARTING_BOOSTERS, cannons: 0, freightPods: 0 },
    friendshipCards: [],
    medals: { pirate: 0, ice: 0 },
    pieces: {
      coloniesLeft: PIECE_LIMITS.colonies,
      stationsLeft: PIECE_LIMITS.tradeStations,
      transportsLeft: PIECE_LIMITS.transportShips,
      shipyardsLeft: PIECE_LIMITS.shipyards,
    },
    connected: true,
  };
}

/** Place a colour's 2 colonies + spaceport (+ colony ship for a real player). */
export function placeStartingPieces(state: GameState, placement: Placement, color: PlayerColor, player: Player | null): void {
  const pieces = placement.startingPieces?.[color];
  if (!pieces) throw new Error(`No starting pieces for ${color}`);
  const board = state.board;
  const owner = player?.id ?? null;

  for (const col of pieces.colonies) {
    const nodeId = colonySiteBetween(board, col.between[0], col.between[1]);
    if (board.settlements[nodeId]) throw new Error(`Starting site ${nodeId} already taken`);
    board.settlements[nodeId] = { nodeId, kind: 'colony', color, owner };
  }
  const spNode = colonySiteBetween(board, pieces.spaceport.between[0], pieces.spaceport.between[1]);
  if (board.settlements[spNode]) throw new Error(`Starting spaceport site ${spNode} already taken`);
  board.settlements[spNode] = { nodeId: spNode, kind: 'spaceport', color, owner };

  if (player) {
    // 2 colonies + the colony inside the spaceport + 1 shipyard.
    player.pieces.coloniesLeft -= 3;
    player.pieces.shipyardsLeft -= 1;

    // Colony ship on the spaceport site along the `shipSide` planet's outer edge.
    const sites = neighborsOf(board, spNode);
    const site = sites.find((n) => vertexHexes(n).some((h) => hexEquals(h, pieces.spaceport.shipSide)));
    if (!site) throw new Error(`No spaceport site of ${spNode} touches hex ${hexKey(pieces.spaceport.shipSide)}`);
    const shipId = `ship:${color}:1`;
    board.ships[shipId] = { id: shipId, owner: player.id, kind: 'colony', nodeId: site, mustFoundOrLeave: false };
    player.pieces.coloniesLeft -= 1;
    player.pieces.transportsLeft -= 1;
  }
}

/** Highest 2d6 starts; ties re-rolled among the tied players. */
export function rollForStart(players: readonly Player[], rng: Rng): PlayerId {
  let candidates = players.map((p) => p.id);
  while (candidates.length > 1) {
    const rolls = candidates.map((id) => ({ id, roll: rng.d6() + rng.d6() }));
    const best = Math.max(...rolls.map((r) => r.roll));
    candidates = rolls.filter((r) => r.roll === best).map((r) => r.id);
  }
  return candidates[0] as PlayerId;
}

export interface AssembleOptions {
  id: string;
  seed: string;
  variant: GameVariant;
  players: PlayerSpec[];
  /** Board with its sectors and discs already placed. */
  board: Board;
  layout: BoardLayout;
  /** Supplies the starting pieces (always the beginner positions, spec §3.3). */
  placement: Placement;
  /** Number discs still to be drawn (explorer / wild space); empty otherwise. */
  discPools: Record<DiscIcon, string[]>;
  rng: Rng;
  /** Set-up name for the first log line. */
  label: string;
}

/** Players, supply, decks, starting pieces, hands and the starting roll on top of a finished board. */
export function assembleState(options: AssembleOptions): GameState {
  const { board, layout, placement, rng } = options;
  const players = options.players.map(makePlayer);
  const n = players.length;
  const usedColors = new Set(players.map((p) => p.color));
  const blockerColor = n === 3 ? (PLAYER_COLORS.find((c) => !usedColors.has(c)) ?? null) : null;

  const friendshipCards = {} as Record<Civ, FriendshipCardId[]>;
  const friendshipMarkers = {} as Record<Civ, PlayerId | null>;
  for (const civ of CIVS) {
    friendshipCards[civ] = friendshipCardsOf(civ);
    friendshipMarkers[civ] = null;
  }

  const supply: Record<Resource, number> = {
    ore: SUPPLY_PER_RESOURCE,
    fuel: SUPPLY_PER_RESOURCE,
    carbon: SUPPLY_PER_RESOURCE,
    food: SUPPLY_PER_RESOURCE,
    goods: SUPPLY_PER_RESOURCE,
  };

  const state: GameState = {
    id: options.id,
    seed: options.seed,
    variant: options.variant,
    players,
    turnOrder: [],
    activePlayer: '',
    blockerColor,
    phase: 'setup',
    turnNumber: 1,
    board,
    supply,
    reservePile: [],
    upgradesTray: {
      boosters: UPGRADES_TRAY_TOTAL.boosters - n * STARTING_BOOSTERS,
      cannons: UPGRADES_TRAY_TOTAL.cannons,
      freightPods: UPGRADES_TRAY_TOTAL.freightPods,
      famePieces: UPGRADES_TRAY_TOTAL.famePieces - n * STARTING_FAME_PIECES,
    },
    encounterDeck: rng.shuffle(Array.from({ length: ENCOUNTER_CARD_COUNT }, (_, i) => i + 1)),
    encounterDiscard: [],
    friendshipCards,
    friendshipMarkers,
    reserveDiscs: makeReserveDiscs(layout, rng),
    discPools: { tri: [...options.discPools.tri], br: [...options.discPools.br], hex: [...options.discPools.hex] },
    pendingTradeShips: Object.fromEntries(players.map((p) => [p.id, 0])),
    openTrade: null,
    turn: { reserveDrawTaken: false, shipMovesUsed: {}, immobilized: [], usedOncePerTurn: [] },
    winner: null,
    log: [],
  };

  for (const p of players) placeStartingPieces(state, placement, p.color, p);
  if (blockerColor) placeStartingPieces(state, placement, blockerColor, null);

  state.reservePile = buildReservePile(state, rng);
  for (const p of players) p.hand.push(...drawFromReserve(state, STARTING_HAND_SIZE, rng));

  const starter = rollForStart(players, rng);
  const startIdx = players.findIndex((p) => p.id === starter);
  state.turnOrder = [...players.slice(startIdx), ...players.slice(0, startIdx)].map((p) => p.id);
  state.activePlayer = starter;
  state.phase = 'production';

  recomputeAllVp(state);
  state.log.push({
    seq: 0,
    turnNumber: 1,
    playerId: null,
    kind: 'event',
    message: `${options.label} game set up for ${n} players; ${players.find((p) => p.id === starter)?.name ?? starter} starts.`,
  });
  return state;
}
