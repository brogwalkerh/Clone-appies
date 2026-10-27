# Starfarers Online — project state and hand-off

Last updated after commit `867d7d9` on branch `claude/optimistic-mayer-4n6h9p`.
Read `CLAUDE.md` and `starfarers-clone-spec.md` first; this file only says
where the project stands and how to run the next phases.

## 1. Current state in one paragraph

Phases 1–3 of spec §15 are done: the pure engine in `shared/` plays a complete
beginner game from set-up to a 15-VP win, including the 7, trade, build, the
flight phase, exploration, pirate/ice tokens, founding, friendship cards, and
all 32 encounter cards. 418 Vitest tests pass; `tsc --noEmit` is clean; a
`starfarers-engine` job runs both on every push in `.github/workflows/ci.yml`.
`server/` and `client/` do not exist yet (the workspace file already lists
them). Nothing has been merged to `main`.

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
```

Toolchain: Node 22, pnpm 10.28, TypeScript 5.9.2 (strict,
`noUncheckedIndexedAccess`, `exactOptionalPropertyTypes`), Vitest 3.2.4, ESM.
`pnpm install && pnpm typecheck && pnpm test` from `starfarers-online/`.

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

## 6. Phase 4 — hot-seat client (next)

Goal (spec §14, §15.4): a React + Vite app in `client/` that plays a full
3–4 player game in one browser tab against the local engine, no network.

Instructions for the implementing agent:

1. Create `client/` as workspace package `@starfarers/client`: Vite 6, React 18
   or 19, TypeScript strict, Vitest + `@testing-library/react` for component
   tests, `vitest.config.ts` so the root `pnpm test` picks it up, scripts
   `dev`, `build`, `typecheck`, `test`. Depend on `@starfarers/shared` via
   `workspace:*`. No official Catan art, names or logos; placeholder shapes.
2. State layer: a `GameStore` (zustand or useReducer) holding `GameState`,
   `seed`, a per-game `Rng` created with `createRng(seed)` and reused across
   actions (the hot-seat is the only authority), an `error` slot, and a
   `dispatch(action)` that calls `applyAction` and keeps the previous state for
   undo-less replay of the log. Hot-seat: the "current viewer" is the player
   whose input is pending (active player, or `awaiting.playerId`, or a player
   in `awaitingDiscard`, or the `openTrade` recipient); show a "pass the laptop"
   banner on viewer change and hide other hands.
3. Board (SVG): render all hexes from `state.board.sectors[*].lobes` and
   `Planet.hex` using `board/geometry` (`hexCorners`, `vertexPosition`);
   planets coloured by resource (`board.json → planets` colour map), disc
   number with font size scaled by dice probability (6/8 largest), face-down
   discs as blank, tokens as P/I badges; outposts with 5 dock slots around the
   docking point; nodes as clickable circles; settlements (colony/spaceport by
   shape) and ships (colony/trade) in player colours. Selecting a ship
   highlights legal end nodes = BFS over `board.adjacency` with budget
   `turn.speed − turn.shipMovesUsed[shipId]` filtered by
   `validateEndNode(state, ship, nodeId)` from `flight/movement.ts`; clicking a
   highlighted node sends `moveShip` with the BFS path. Also "found colony" /
   "found trade station" buttons when `canFoundColony` / `canFoundTradeStation`
   return null.
4. Panels: hand (own cards grouped by type, others as counts), mothership
   (boosters/cannons/pods, shake animation revealing `turn.shake`), VP track
   along the board edge, build menu with affordability from `BUILD_COSTS`,
   trade panel (supply trade with ratio hints incl. Merchants cards; player
   trade proposal/counter/accept driven by `openTrade`), friendship card
   panel, encounter modal that shows `visibleEncounterText(state)` box by box
   and renders the right control for `awaiting.kind`, a 7-resolution dialog
   (discard picker, steal target), and a log pane rendering `state.log`.
5. Phase-driven action bar: only show actions whose `ACTION_POLICY` phase
   matches and whose preconditions hold; always show the engine's `GameError`
   message on rejection.
6. Tests: component tests for the board BFS highlight (legal nodes equal the
   engine's answer), the encounter modal control for each `awaiting.kind`, the
   viewer switch, and one "scripted full turn" test that plays
   roll → build → shake → move → endTurn through the store with a seeded rng.
   Add `pnpm --filter @starfarers/client build` and the client tests to the CI
   job in `.github/workflows/ci.yml`.
7. Done when: `pnpm dev` in `client/` opens a game that can be played to a win
   by hand, all tests pass, typecheck is clean, nothing in `shared/` changed
   except additive helpers (list them).

Recommended agents: one Opus implementer for the store + board, one Opus
implementer for the panels + modals (parallel, disjoint folders under
`client/src/board` and `client/src/panels`, shared contract = the store
file written first), then a reviewer that plays a full game with Playwright
(Chromium is pre-installed in the cloud container).

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
   store interface as the hot-seat store, selected by route.
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
