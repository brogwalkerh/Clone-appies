# Starfarers Online — project state and hand-off

Last updated after phase 4 on branch `claude/dreamy-babbage-d8h1cd` (which
contains all of `claude/optimistic-mayer-4n6h9p`).
Read `CLAUDE.md` and `starfarers-clone-spec.md` first; this file only says
where the project stands and how to run the next phases.

## 1. Current state in one paragraph

Phases 1–4 of spec §15 are done: the pure engine in `shared/` plays a complete
beginner game from set-up to a 15-VP win, including the 7, trade, build, the
flight phase, exploration, pirate/ice tokens, founding, friendship cards, and
all 32 encounter cards; the hot-seat React client in `client/` plays that game
in one browser tab against the local engine (no network). 444 Vitest tests pass
(418 engine + 26 client); `tsc --noEmit` is clean in both packages; the
`starfarers-engine` CI job runs typecheck, tests and the Vite build on every
push. `server/` does not exist yet (the workspace file already lists it).
Nothing has been merged to `main`.

## 2. Layout

```
starfarers-online/
  CLAUDE.md, starfarers-clone-spec.md, HANDOFF.md (this file)
  layouts/board.json, layouts/beginner.json    board data; never retype, load
  package.json  pnpm-workspace.yaml (shared, server, client)  vitest.config.ts
  shared/                                        @starfarers/shared, pure TS engine, Foundation-free, no I/O
    src/types.ts        GameState, Player, Board, Ship, Settlement, Action union (16 intents), GameError, Result
    src/config.ts       every rule constant and every inferred / [VERIFY] item, with comments
    src/rng.ts          createRng(seed) → xoshiro128**; the ONLY source of randomness
    src/supply.ts       hand / supply / reserve-pile helpers
    src/vp.ts           computeVp, recomputeAllVp (spec §12.3)
    src/board/          geometry (pointy-top odd-r, N/S vertex ids), layout parsing, graph builder, query helpers
    src/setup/beginner.ts   createBeginnerGame({ players, seed }) for 3–4 players (blockers in 3p)
    src/actions/        applyAction + per-phase handler modules (see §3)
    src/production/     produce.ts, seven.ts, relief.ts
    src/flight/         stats, shake, movement, explore, tokens, jump
    src/found/          colony, station, friendship, freeTradeShip
    src/encounters/     schema, cards (32 as data), engine (resumable interpreter), text (progressive reveal)
    src/index.ts        barrel; the server/client import only from here
    test/               15 files, 418 tests; test/support/tradeBuild.ts has fixture helpers
  client/                                        @starfarers/client, Vite 6 + React 19 + zustand, hot-seat UI
    index.html  vite.config.ts  vitest.config.ts (jsdom + testing-library)
    src/main.tsx  src/App.tsx   app shell: board interaction rules, overlays, seat select, error toast
    src/styles.css              dark theme, one file
    src/store/gameStore.ts      GameStore (zustand vanilla + hook): state, one Rng per game, action log,
                                viewer / pendingViewer, nodePick, replayState(k), useAct()
    src/board/Board.tsx         SVG board from state.board + board/geometry; VpTrack.tsx; legalMoves.ts (BFS)
    src/panels/                 HandPanel, MothershipPanel, BuildMenu, TradePanel, FriendshipPanel,
                                SevenDialog, EncounterModal, FoundStationDialog, ActionBar, LogPane,
                                PassBanner, SetupScreen, ResourcePicker (BagPicker)
    src/ui/format.ts            colours, labels, bag/hand helpers (no rules)
    test/                       4 files, 26 tests (legal-move highlight vs engine, encounter modal per
                                awaiting.kind, viewer switch, scripted full turn + replay)
```

Toolchain: Node 22, pnpm 10.28, TypeScript 5.9.2 (strict,
`noUncheckedIndexedAccess`, `exactOptionalPropertyTypes`), Vitest 3.2.4, Vite
6.4.5 (pinned through a root `pnpm.overrides` so vitest and the client share one
Vite), React 19, zustand 5, ESM.
`pnpm install && pnpm typecheck && pnpm test` from `starfarers-online/`;
`pnpm --filter @starfarers/client dev` opens the hot-seat game on :5173,
`pnpm --filter @starfarers/client build` produces `client/dist/`.

## 3. Engine API the client and server build on

```ts
import { createBeginnerGame, applyAction, createRng, computeVp,
         visibleEncounterText, ACTION_POLICY, /* board query helpers */ } from '@starfarers/shared';

const state = createBeginnerGame({ players: [{id,name,color}, ...], seed: 'abc' });
const rng   = createRng(state.seed + ':' + state.turnNumber);   // server decides the seeding policy
const r     = applyAction(state, { type: 'rollDice', playerId }, rng);
if (r.ok) next = r.value; else show(r.error.code, r.error.message);
```

- `applyAction` never mutates its input (structuredClone), checks `gameOver`,
  unknown player, phase and active-player gating from `ACTION_POLICY`,
  dispatches, recomputes VP, runs the win hook, appends a log entry.
- Phases: `production → tradeBuild → (shakeMothership) → flight.encounter? →
  flight.move → (endTurn) → production`, plus `gameOver`.
- Actions (spec §12.2, all implemented): `rollDice`, `takeReserveDraw`,
  `discardForSeven{cards}`, `stealForSeven{target}`, `proposeTrade{to,give,want}`,
  `respondTrade{accept,counter?}`, `tradeWithSupply{give,want}`,
  `build{item,siteId?}`, `useFriendshipCard{cardId,give?,want?,targets?}`,
  `shakeMothership`, `encounterChoice{value,cards?}`, `encounterPick{...}`,
  `moveShip{shipId,path}` (path = nodes AFTER the current one),
  `foundColony{shipId}`, `foundTradeStation{shipId,dockIndex,friendshipCardId}`,
  `endTurn`.
- Who may act when is in `shared/src/actions/policy.ts`. Non-active players act
  on: `discardForSeven`, `proposeTrade`/`respondTrade`, Galactic Relief Fund via
  `useFriendshipCard`, and `encounterPick` when `turn.encounter.awaiting.playerId`
  is them.
- Pending-input markers the UI must watch: `turn.seven.awaitingDiscard`,
  `turn.pendingFound` (trade ship on a dock; only `foundTradeStation` is legal),
  `turn.encounter.awaiting` (who must pick what; `awaiting.kind`, `count`,
  `options`), `state.openTrade`.
- Hidden information: `Player.hand`, `reservePile`, `encounterDeck`,
  `LogEntry.action` payloads such as `discardForSeven.cards`. The server must
  redact these per socket (spec §12.1); the engine does not.
- Board geometry for drawing: `BoardNode.pos {x,y}` is already computed in
  hex units; `Planet.hex`, `Sector.lobes`, `Sector.centreVertex`,
  `Sector.dockingPointId`, `Sector.docks[5]`, `Board.adjacency` for BFS.

## 4. What each completed phase delivered

| Phase | Commits | Content | Tests |
|---|---|---|---|
| 1 Engine core | `2ee1cdf` `45ab3c9` `e99b274` `cc0f01d` `2a72c1e` | types, config, rng, board graph (394 nodes / 545 edges, 36 colony sites, 4 docking points, no edge through a system centre), beginner set-up incl. 3-player blockers, production incl. the 7, Green Folk +1, supply-shortage rule, reserve draws by VP, Relief Fund, supply and player trades, all builds with limits and caps, Fame for Sale, Helping Hand, endTurn, win at 15 on own turn, CI job | 136 |
| 2 Flight | `f4b72e4` `c4ac534` | uniform two-ball shake (40 % encounter), speed and combat incl. Scientists cards, moveShip validator (§9.2/§11: pass-through, backtrack, cumulative budget, no-blockade rules, must-found-or-leave), exploration flips discs into numbers or tokens, immediate pirate defeat / ice terraform with reserve discs, foundColony (3p cap), foundTradeStation (freight threshold, docks, card pick, marker on strict majority), free trade ships with pending markers, space-jump helpers | 226 |
| 3 Encounters | `9a1dcd3` `867d7d9` | 32 cards as data, resumable effect interpreter with player picks, contests, flee, shake bands, Wear and Tear, redraw, progressive text; one spec-derived test per branch per outcome (zero mismatches found) | 418 |
| 4 Hot-seat client | (this branch) | `client/` package; store with one rng per game and an action log that replays deterministically; SVG board (hexes, resource-coloured planets, discs sized by dice probability, face-down discs, P/I tokens, outposts with 5 docks, colonies/spaceports/ships in player colours); ship selection → BFS highlight filtered by `validateEndNode`, hover path preview, click to `moveShip`; found-colony buttons and a dock + friendship-card dialog for stations; hand / others' counts, mothership with shake animation, VP track, build menu with affordability and board site picks, supply trade with every ratio the player may use, player trade proposal / counter / accept / reject / withdraw, friendship card actions (Fame for Sale, Helping Hand, Relief Fund), 7 dialog (discard picker, steal target), encounter modal with progressive text and a control per `awaiting.kind` (space jump through board clicks), log pane with replay slider, pass-the-laptop curtain, seat select, error toast with the engine's message; Playwright-driven 12-turn smoke run with zero page errors | 444 |

Review passes fixed: non-active Relief Fund holder blocked; bogus card names
cleared a 7 discard for free; inherited object keys could write junk into the
tray; tokens never claimed by a ship already adjacent when the threshold was
reached; pending trade ships not placed as soon as a site freed up.

## 5. Documented judgment calls (revisit when the UI makes them visible)

1. Trade finalisation: when the ACTIVE player proposes, the recipient's accept
   executes the trade (spec §7.1 literally says only the active player accepts).
2. 3-player blocker colour's spaceport sites block other ships' end nodes
   (`flight/movement.ts`, `isForeignSpaceportSite`); the rulebook's "they only
   block the sites" could mean the opposite. One-line flip.
3. §7.2 "opponent must move away from a new spaceport site if possible" checks
   one-step neighbours only.
4. Free trade ships go on the first free own spaceport site; the player does
   not choose (both sites are equivalent).
5. Reserve draw uses VP at draw time, not roll time.
6. Space jump may be declined; Wear and Tear still asks which upgrade to
   remove; Galactic Council honours nobody when nobody has a freight pod;
   "Flee?" no = fight directly.
7. `[VERIFY]` items (shake bands on cards 12–15, travelers splits 28–30, tile
   star backs, beginner `shipSide`) live in `config.ts`/`board.json` and are
   pinned by tests so a change is deliberate.
8. Not yet implemented and deferred by spec to phase 6: strategic / explorer /
   wild-space set-ups (the loader already takes any placement), advanced
   set-up draft (§3.4), turn timer, persistence.
9. Client (phase 4): the "viewer" is one seat; `requiredViewer` picks the
   encounter picker, then a 7-discarder (current viewer first), then the open
   trade's recipient, else the active player. Any seat can also be taken from
   the header (`takeSeat`) so a non-active player can propose a trade. The
   curtain hides hands only while `pendingViewer` is set; hot-seat players are
   trusted not to peek.
10. Client replay keeps no snapshots: `actions[]` + the initial state + the rng
   seed string reproduce every state (`replayState(k)`, cached incrementally).
   `loadGame` derives a fresh rng seed (`seed:turn:logLength`) because a loaded
   state has consumed an unknown part of the stream.
11. The encounter modal stays open after the card resolves (stage `done`) until
   "Continue" is clicked, so the result text is not lost when the phase flips.
12. Build site picks: with one candidate the build is sent immediately; with
   several the board highlights them (`nodePick`) and the click sends `build`.

## 6. Phase 4 — hot-seat client (done)

Delivered as described in §4. How to run and verify:

```sh
cd starfarers-online && pnpm install
pnpm typecheck && pnpm test                      # shared + client
pnpm --filter @starfarers/client dev             # http://localhost:5173
pnpm --filter @starfarers/client build           # client/dist (CI runs this too)
```

Engine API the client relies on (all pre-existing, plus the additive barrel
exports `production/seven.ts` and `production/relief.ts` for the 7 dialog and
the Relief Fund button): `createBeginnerGame`, `applyAction`, `createRng`,
`rngFromState`, `ACTION_POLICY`, `validateEndNode`, `validateJumpTarget`,
`stepsLeft`, `canFoundColony`, `canFoundTradeStation`, `outpostAtNode`,
`pickableFriendshipCards`, `reliefEligible`, `discardCountFor`, `stealTargets`,
`reserveDrawFor`, `speedOf`, `visibleEncounterText`, `encounterCard`,
`hexCorners`, `hexCenter`, `vertexPosition`, `handHas`, `shipsOf`,
`spaceportsOf`, `spaceportSites`, `isOccupied`, config constants.

Test ids worth knowing for Playwright or further component tests: `board`,
`node-<id>` (`data-highlight="true"` when targetable), `ship-<id>`,
`settlement-<node>`, `dock-<sector>-<i>`, `action-roll|reserve|shake|end`,
`action-found-<ship>`, `build-<item>`, `supply-rate-<n>`, `trade-propose|accept|
reject|counter|withdraw`, `seven-dialog`, `discard-confirm`, `steal-<pid>`,
`encounter-modal`, `encounter-box`, `choice-offer|yes|no`, `offer-confirm`,
`pick-<kind>`, `pick-option-<value>`, `pick-confirm`, `pick-decline`,
`found-station-dialog`, `found-station-confirm`, `pass-banner`, `take-seat`,
`seat-select`, `error-toast`, `vp-track`, `log-pane`.

Known gaps to pick up in phase 6 (none block play): no keyboard navigation; the
outpost civ label can overlap the dock row on the Diplomats tile; the
spaceport-site rule for a *pending* trade-ship marker is shown only through the
log; no save/load of a game to a file (the store's `loadGame` + action log make
it a small addition); phones are not a target (spec §14).

## 7. Phase 5 — server, lobby, reconnect

Goal (spec §13, §15.5): `server/` package `@starfarers/server` (Node 22,
Socket.IO 4, TypeScript), one process, in-memory room store.

1. Room lifecycle: `createRoom(name) → {code (6 chars), playerToken}`,
   `joinRoom(code, name)`, host `start` when 3–4 present; seeds the game with a
   server-generated seed; one `Rng` per room persisted alongside the state
   (serialise `rng.getState()` with the room).
2. Transport: client emits `{ type: 'action', action }`; server validates
   `action.playerId === socket's player`, runs `applyAction`, on success emits
   `state` to every socket with `redactState(state, viewerId)` (other hands →
   `handCount`, reserve pile and encounter deck → counts, `log[*].action`
   stripped of hidden payloads), on failure emits `error` to the sender only.
   `redactState` lives in `shared/` (pure) so the client can reuse the type.
3. Reconnect: client stores `{roomCode, playerToken}` in `localStorage`; on
   connect with a token the server re-binds the socket, marks
   `player.connected`, and sends the current redacted state.
4. Trade negotiation and encounter picks already live in the engine state; the
   server only forwards. Chat: `chat` event appended to a room-level message
   list (not game state). Turn timer: off by default, config only.
5. Client: add a lobby screen and a `RemoteGameStore` implementing the same
   `GameStoreState` interface as `client/src/store/gameStore.ts` (dispatch →
   socket emit; `game` ← redacted `state` events; `viewer` fixed to the
   socket's player, `pendingViewer` always null; `replayState` from the
   server's action log or disabled), selected by route. The panels only use
   `useGame` / `useAct` / `useShownState`, so swapping the store instance is
   enough.
6. Tests: server unit tests with `socket.io-client` against an in-process
   server: create/join/start, action round trip, redaction per socket,
   rejection to sender only, reconnect with token, full scripted game over
   sockets. Add to CI.
7. Deploy target: single Node process serving the built client statically
   (Fly.io / Railway / Render); `Dockerfile` optional.

## 8. Phase 6 — polish

Strategic, Explorer and Wild Space set-ups (shuffle logic in
`setup/`; the loader and `assignPlanetsClockwise` already exist), advanced
set-up draft (§3.4), animations, log replay, optional Postgres/Supabase
persistence, 3-player rule review, and the judgment calls in §5 above.

## 9. Working agreements that held so far

- One agent per disjoint set of files; shared files (`types.ts`, `config.ts`,
  `policy.ts`, `actions/index.ts`) edited only additively with exact-string
  edits; every agent lists its shared-file edits in its report.
- Every rule gets a test; every `[VERIFY]` item lives in config with a comment.
- A review agent runs after each phase, traces real action sequences against
  the spec, fixes with regression tests, and lists judgment calls.
- Commits: `starfarers: <imperative subject>`, body explains why, one logical
  change per commit, verified green before committing.
