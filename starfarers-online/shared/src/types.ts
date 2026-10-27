/**
 * Core domain types for the Starfarers Online engine (spec §12.1 / §12.2).
 *
 * Everything in here is plain data: JSON-serialisable, no classes, no methods,
 * so `GameState` can be cloned with `structuredClone`, sent over a socket and
 * stored verbatim.
 */

import type { Ball } from './config.js';
import type { EncounterCtx } from './encounters/schema.js';

export type { EncounterCtx } from './encounters/schema.js';

// ---------------------------------------------------------------------------
// Primitive identifiers
// ---------------------------------------------------------------------------

export type PlayerId = string;
/** Node (intersection) id, e.g. `N(3,4)` or `S(3,4)`; see board/geometry.ts. */
export type NodeId = string;
/** Planet id, `P(row,col)` — a planet is uniquely identified by its hex. */
export type PlanetId = string;
/** Sector id: a slot id (`N1`…`N8`, `F1`…`F7`) or a Catanian letter (`alpha`…`delta`). */
export type SectorId = string;
/** Tile id from board.json: `S1`…`S8`, `O_GreenFolk`…, `E1`…`E4`, or a Catanian letter. */
export type TileId = string;
export type ShipId = string;
export type DiscId = string;

export type Resource = 'ore' | 'fuel' | 'carbon' | 'food' | 'goods';
export const RESOURCES: readonly Resource[] = ['ore', 'fuel', 'carbon', 'food', 'goods'];

export type ResourceBag = Partial<Record<Resource, number>>;

export type PlayerColor = 'red' | 'blue' | 'yellow' | 'white';
export const PLAYER_COLORS: readonly PlayerColor[] = ['red', 'blue', 'yellow', 'white'];

export type Civ = 'greenFolk' | 'scientists' | 'diplomats' | 'merchants';
export const CIVS: readonly Civ[] = ['greenFolk', 'scientists', 'diplomats', 'merchants'];

export type Phase =
  | 'setup'
  | 'production'
  | 'tradeBuild'
  | 'flight.shake'
  | 'flight.encounter'
  | 'flight.move'
  | 'gameOver';

export type GameVariant = 'beginner' | 'strategic' | 'explorer' | 'wild';

/**
 * How the players' starting pieces reach the board (independent of the board
 * variant): `'preset'` = the rulebook's fixed positions (spec §3.3),
 * `'draft'` = the advanced set-up snake draft on the Catanian sites (§3.4),
 * played out as actions in phase `'setup'`.
 */
export type SetupMode = 'preset' | 'draft';

export type UpgradeKind = 'booster' | 'cannon' | 'freightPod';

export type BuildItem = 'colonyShip' | 'tradeShip' | 'spaceport' | UpgradeKind;

/** Friendship card ids (spec §8). Five per civilisation, 20 in total. */
export type FriendshipCardId =
  // Green Folk — production increase +1
  | 'axxa'
  | 'xulu'
  | 'asox'
  | 'esox'
  | 'xom'
  // Scientists — speed / combat bonuses
  | 'khaStar'
  | 'hirAkas'
  | 'khorNem'
  | 'hirSto'
  | 'asaBar'
  // Diplomats
  | 'raHal'
  | 'reBah'
  | 'reOhm'
  | 'raHna'
  | 'raHno'
  // Merchants
  | 'zuzzo'
  | 'orzel'
  | 'crizzetu'
  | 'utuzzo'
  | 'ezzel';

// ---------------------------------------------------------------------------
// Board geometry
// ---------------------------------------------------------------------------

/** Odd-r offset coordinate `[row, col]` of a pointy-top hex. */
export type HexCoord = readonly [row: number, col: number];
/** String form of a HexCoord: `"row,col"`. */
export type HexKey = string;

export type SiteType = 'colonySite' | 'dockingPoint' | 'plain';

export interface BoardNode {
  id: NodeId;
  /** Position in hex units (hex width = 1), for rendering. */
  pos: { x: number; y: number };
  /** Planets whose hex touches this intersection. */
  adjacentPlanets: PlanetId[];
  siteType: SiteType;
  /** Set for colony sites, docking points and sector centre nodes (empty sectors). */
  sectorId?: SectorId;
}

/** Undirected edge between two nodes; `a < b` lexicographically. */
export type Edge = readonly [a: NodeId, b: NodeId];

export type DiscIcon = 'tri' | 'br' | 'hex';
export type CatanianLetter = 'alpha' | 'beta' | 'gamma' | 'delta';
export type DiscBack = DiscIcon | CatanianLetter | 'reserve';

export interface SpecialToken {
  kind: 'pirateBase' | 'icePlanet';
  /** Cannons needed (pirate base) or freight pods needed (ice planet). */
  value: number;
}

export interface Disc {
  id: DiscId;
  back: DiscBack;
  /** Raw label as printed: `"8"`, `"3/12"`, `"P4"`, `"I3"`. */
  label: string;
  /** Production numbers. Two-number discs list both; P/I discs list none. */
  numbers: number[];
  /** Present on P/I discs; replaced by a token on the planet when explored. */
  special?: SpecialToken;
  faceUp: boolean;
}

export interface Planet {
  id: PlanetId;
  hex: HexCoord;
  sectorId: SectorId;
  resource: Resource;
  /** Number-disc back icon (unexplored systems only). */
  icon?: DiscIcon;
  disc: Disc | null;
  /** Active pirate-base / ice-planet token (none once defeated/terraformed). */
  token: SpecialToken | null;
}

/** What a tile printed in board.json is. */
export type TileKind = 'system' | 'outpost' | 'empty';
/**
 * A sector's kind. `'hidden'` appears only in a REDACTED state (net/redact.ts):
 * an undiscovered slot whose tile the viewer may not see. The authoritative
 * state always holds the real `TileKind`.
 */
export type SectorKind = TileKind | 'hidden';
export type SectorRegion = 'catanian' | 'near' | 'far';

export interface ColonySite {
  nodeId: NodeId;
  /** The two planets this site lies between. */
  planetIds: [PlanetId, PlanetId];
}

export interface Sector {
  id: SectorId;
  tileId: TileId;
  kind: SectorKind;
  region: SectorRegion;
  lobes: HexCoord[];
  /** Vertex id of the centre point (a node only for outposts and empties). */
  centreVertex: NodeId;
  /** Systems only. */
  planetIds: PlanetId[];
  colonySites: ColonySite[];
  /** Outposts only. */
  civ?: Civ;
  dockingPointId?: NodeId;
  /** Outposts only: 5 docks, each holding a trade station owner or null. */
  docks?: (PlayerId | null)[];
  /** False while any planet disc is face down. Catanian systems start explored. */
  explored: boolean;
  /**
   * False for a face-down tile (explorer / wild space set-ups, spec §3.2):
   * its identity is hidden information until a ship reaches an intersection
   * touching one of its lobes (flight/discover.ts). Always true in the
   * beginner and strategic set-ups and for the Catanian systems.
   */
  discovered: boolean;
}

export type SettlementKind = 'colony' | 'spaceport';

export interface Settlement {
  nodeId: NodeId;
  kind: SettlementKind;
  color: PlayerColor;
  /** `null` for the blocker colour's pieces in a 3-player game. */
  owner: PlayerId | null;
}

export type ShipKind = 'colony' | 'trade';

export interface Ship {
  id: ShipId;
  owner: PlayerId;
  kind: ShipKind;
  nodeId: NodeId;
  /** Colony ship parked on a colony site must found or leave next turn (§9.2). */
  mustFoundOrLeave: boolean;
  /**
   * Site a `mustFoundOrLeave` ship moved off during the current turn; it may not
   * end a move there again this turn (§9.2 "may only return by founding").
   * Cleared by `endTurn` (owned by flight/movement.ts).
   */
  leftSite?: NodeId;
}

export interface Board {
  grid: { rows: number; cols: number };
  nodes: Record<NodeId, BoardNode>;
  edges: Edge[];
  /** Node → neighbouring node ids (derived from `edges`). */
  adjacency: Record<NodeId, NodeId[]>;
  sectors: Record<SectorId, Sector>;
  planets: Record<PlanetId, Planet>;
  /** Colonies and spaceports keyed by node id. */
  settlements: Record<NodeId, Settlement>;
  ships: Record<ShipId, Ship>;
}

// ---------------------------------------------------------------------------
// Players and game state
// ---------------------------------------------------------------------------

export interface Mothership {
  boosters: number;
  cannons: number;
  freightPods: number;
}

export interface PlayerPieces {
  coloniesLeft: number;
  stationsLeft: number;
  transportsLeft: number;
  shipyardsLeft: number;
}

export interface Player {
  id: PlayerId;
  name: string;
  color: PlayerColor;
  hand: Resource[];
  /** Cached result of `computeVp`; recomputed after every accepted action. */
  vp: number;
  famePieces: number;
  mothership: Mothership;
  friendshipCards: FriendshipCardId[];
  medals: { pirate: number; ice: number };
  pieces: PlayerPieces;
  connected: boolean;
  /**
   * Set by `redactState` (net/redact.ts): number of cards in `hand`, kept for
   * every player while opponents' `hand` arrays are emptied. Absent in the
   * authoritative state; clients read `handCount ?? hand.length`.
   */
  handCount?: number;
}

export interface UpgradesTray {
  boosters: number;
  cannons: number;
  freightPods: number;
  famePieces: number;
}

export interface TradeProposal {
  from: PlayerId;
  to: PlayerId | 'supply';
  give: ResourceBag;
  want: ResourceBag;
}

export interface TurnState {
  rolled?: number;
  reserveDrawTaken: boolean;
  baseSpeed?: number;
  speed?: number;
  shipMovesUsed: Record<ShipId, number>;
  immobilized: ShipId[];
  /** Encounter in progress / just resolved this turn (encounters/schema.ts, owned by actions/encounter.ts). */
  encounter?: EncounterCtx;
  /** The two balls revealed by this turn's mothership shake (flight/shake.ts). */
  shake?: Ball[];
  /**
   * Trade ship that just ended its move on a docking point and must found a
   * trade station now (§9.2); while set, only `foundTradeStation` is legal.
   */
  pendingFound?: ShipId;
  /** Ids of once-per-turn abilities already used (e.g. friendship card ids). */
  usedOncePerTurn: string[];
  /** Pending bookkeeping while resolving a 7 (owned by actions/production.ts). */
  seven?: {
    awaitingDiscard: PlayerId[];
    stealDone: boolean;
  };
  /**
   * Cards each player received from this turn's (non-7) production roll, Green
   * Folk bonus included. Set by `rollDice`; read by the Diplomats "Galactic
   * Relief Fund" eligibility check (production/relief.ts).
   */
  productionReceived?: Record<PlayerId, number>;
}

/**
 * Advanced set-up draft in progress (spec §3.4; owned by actions/draft.ts).
 * Present only while `phase === 'setup'` in a `'draft'` game. Public data:
 * `redactState` passes it through unchanged.
 */
export interface DraftState {
  /** 1–3: place a colony; 4: spaceport + ship + bonus upgrade. */
  round: 1 | 2 | 3 | 4;
  /** Pick order of the current round (snake: 1 and 3 clockwise, 2 and 4 counter-clockwise). */
  order: PlayerId[];
  /** Index into `order` of the current picker (always `state.activePlayer`). */
  index: number;
  /** Winner of the opening 2d6 roll: first picker of round 1 and the first active player once the draft is over. */
  starter: PlayerId;
  /** Colony sites drafted per player in rounds 1–3, in pick order. */
  colonies: Record<PlayerId, NodeId[]>;
  /** Bonus upgrades still to be taken in round 4. */
  pool: UpgradeKind[];
}

export interface LogEntry {
  seq: number;
  turnNumber: number;
  playerId: PlayerId | null;
  kind: 'action' | 'event';
  action?: Action;
  message: string;
}

export interface GameState {
  id: string;
  seed: string;
  variant: GameVariant;
  /** How the starting pieces were (or are being) placed; `'preset'` for every game created before the draft existed. */
  setup: SetupMode;
  players: Player[];
  turnOrder: PlayerId[];
  activePlayer: PlayerId;
  /** Unused colour whose pieces block sites in a 3-player game; null with 4 players. */
  blockerColor: PlayerColor | null;
  phase: Phase;
  turnNumber: number;
  board: Board;
  supply: Record<Resource, number>;
  reservePile: Resource[];
  upgradesTray: UpgradesTray;
  encounterDeck: number[];
  encounterDiscard: number[];
  friendshipCards: Record<Civ, FriendshipCardId[]>;
  friendshipMarkers: Record<Civ, PlayerId | null>;
  reserveDiscs: Disc[];
  /**
   * Number discs not yet on the board, by back icon (explorer / wild space:
   * drawn through the rng when a system is discovered). Empty in the beginner
   * and strategic set-ups. Hidden information: `redactState` empties the
   * lists and sets `discPoolCounts`.
   */
  discPools: Record<DiscIcon, string[]>;
  /** Trade-ship markers owed per player (encounter "free trade ship" when it cannot be placed yet). */
  pendingTradeShips: Record<PlayerId, number>;
  openTrade: TradeProposal | null;
  /** The advanced set-up draft while it runs (phase `'setup'`, `setup === 'draft'`); removed once the draft is over. */
  draft?: DraftState;
  turn: TurnState;
  winner: PlayerId | null;
  log: LogEntry[];
  /** Set by `redactState`: sizes of the hidden `reservePile` / `encounterDeck`. */
  reservePileCount?: number;
  encounterDeckCount?: number;
  /** Set by `redactState`: sizes of the hidden `discPools`. */
  discPoolCounts?: Record<DiscIcon, number>;
}

// ---------------------------------------------------------------------------
// Actions (intents) — spec §12.2
// ---------------------------------------------------------------------------

interface ActionBase {
  playerId: PlayerId;
}

export interface RollDiceAction extends ActionBase { type: 'rollDice' }
export interface TakeReserveDrawAction extends ActionBase { type: 'takeReserveDraw' }
export interface DiscardForSevenAction extends ActionBase { type: 'discardForSeven'; cards: Resource[] }
export interface StealForSevenAction extends ActionBase { type: 'stealForSeven'; target: PlayerId }
export interface ProposeTradeAction extends ActionBase {
  type: 'proposeTrade';
  to: PlayerId | 'supply';
  give: ResourceBag;
  want: ResourceBag;
}
export interface RespondTradeAction extends ActionBase {
  type: 'respondTrade';
  accept: boolean;
  /** Counter-offer (from the responder's point of view) when `accept` is false. */
  counter?: { give: ResourceBag; want: ResourceBag };
}
export interface TradeWithSupplyAction extends ActionBase {
  type: 'tradeWithSupply';
  /** Cards handed to the supply: 3 identical, or 2 goods. */
  give: Resource[];
  want: Resource;
}
export interface BuildAction extends ActionBase {
  type: 'build';
  item: BuildItem;
  /** Spaceport site for a new ship, or the colony node to upgrade to a spaceport. */
  siteId?: NodeId;
}
export interface UseFriendshipCardAction extends ActionBase {
  type: 'useFriendshipCard';
  cardId: FriendshipCardId;
  /** Merchants 2:1 / Ezzel 1:1 trades. */
  give?: Resource;
  want?: Resource;
  /** "A Helping Hand": the two opponents to draw from. */
  targets?: PlayerId[];
}
export interface ShakeMothershipAction extends ActionBase { type: 'shakeMothership' }
/**
 * The active player's answer to the encounter card (spec §10). An offer is
 * `value: 0–3` plus the exact `cards` handed to the supply (paid BEFORE the
 * result is revealed; with no cards only 0 is possible). A yes/no card takes
 * `value: boolean`. Cards 7/8 take the offer first, then the yes/no.
 */
export interface EncounterChoiceAction extends ActionBase {
  type: 'encounterChoice';
  value: number | boolean;
  cards?: Resource[];
}
/**
 * Answer to `turn.encounter.awaiting` (encounters/schema.ts `EncounterPickRequest`),
 * sent by the player named there — not necessarily the active player.
 */
export interface EncounterPickAction extends ActionBase {
  type: 'encounterPick';
  /** resources / payResources / giveOne. */
  resources?: Resource[];
  /** upgradeKind / removeUpgrade. */
  upgrade?: UpgradeKind;
  /** immobilizeShip / spaceJump. */
  shipId?: ShipId;
  /** spaceJump. */
  targetNodeId?: NodeId;
  /** spaceJump: skip the jump. */
  decline?: boolean;
}
export interface MoveShipAction extends ActionBase { type: 'moveShip'; shipId: ShipId; path: NodeId[] }
export interface FoundColonyAction extends ActionBase { type: 'foundColony'; shipId: ShipId }
export interface FoundTradeStationAction extends ActionBase {
  type: 'foundTradeStation';
  shipId: ShipId;
  dockIndex: number;
  friendshipCardId: FriendshipCardId;
}
export interface EndTurnAction extends ActionBase { type: 'endTurn' }
/** Advanced set-up (spec §3.4), rounds 1–3: place a colony on a free Catanian colony site. */
export interface DraftColonyAction extends ActionBase { type: 'draftColony'; siteId: NodeId }
/**
 * Advanced set-up round 4, one action for the whole pick: upgrade one of the
 * player's drafted colonies to a spaceport, place a colony or trade ship on one
 * of that spaceport's two sites and take one bonus upgrade from the draft pool.
 */
export interface DraftFinishAction extends ActionBase {
  type: 'draftFinish';
  spaceportSiteId: NodeId;
  ship: ShipKind;
  shipSiteId: NodeId;
  upgrade: UpgradeKind;
}

export type Action =
  | RollDiceAction
  | TakeReserveDrawAction
  | DiscardForSevenAction
  | StealForSevenAction
  | ProposeTradeAction
  | RespondTradeAction
  | TradeWithSupplyAction
  | BuildAction
  | UseFriendshipCardAction
  | ShakeMothershipAction
  | EncounterChoiceAction
  | EncounterPickAction
  | MoveShipAction
  | FoundColonyAction
  | FoundTradeStationAction
  | EndTurnAction
  | DraftColonyAction
  | DraftFinishAction;

export type ActionType = Action['type'];

/** The concrete action object for a given `type` literal. */
export type ActionOf<T extends ActionType> = Extract<Action, { type: T }>;

// ---------------------------------------------------------------------------
// Errors and results
// ---------------------------------------------------------------------------

export type GameErrorCode =
  | 'unknownPlayer'
  | 'notYourTurn'
  | 'wrongPhase'
  | 'gameOver'
  | 'notImplemented'
  | 'invalidAction'
  | 'insufficientResources'
  | 'pieceLimit'
  | 'upgradeCap'
  | 'supplyEmpty'
  | 'invalidSite'
  | 'invalidPath'
  | 'invalidTarget'
  | 'ruleViolation';

export interface GameError {
  kind: 'error';
  code: GameErrorCode;
  message: string;
  details?: Record<string, unknown>;
}

export type Result<T, E = GameError> =
  | { ok: true; value: T }
  | { ok: false; error: E };

export function gameError(code: GameErrorCode, message: string, details?: Record<string, unknown>): GameError {
  return details === undefined ? { kind: 'error', code, message } : { kind: 'error', code, message, details };
}

export function isGameError(value: unknown): value is GameError {
  return typeof value === 'object' && value !== null && (value as { kind?: unknown }).kind === 'error';
}

export function ok<T>(value: T): Result<T> {
  return { ok: true, value };
}

export function err<T>(error: GameError): Result<T> {
  return { ok: false, error };
}
