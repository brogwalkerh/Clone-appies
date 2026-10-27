# Starfarers Online — project state and hand-off

Last updated after phase 5. The project is on `main` (merged in PR #2,
commit `45b6c0c`); phases 1–5 live there in full.

**Starting a new session:** read `CLAUDE.md`, then this file top to bottom, then
`starfarers-clone-spec.md` §13–§16. Run the commands in §2 to confirm green,
then pick up §8 (phase 6). Everything before §8 is finished and tested.
Read `CLAUDE.md` and `starfarers-clone-spec.md` first; this file only says
where the project stands and how to run the next phases.

## 1. Current state in one paragraph

Phases 1–5 of spec §15 are done: the pure engine in `shared/` plays a complete
beginner game from set-up to a 15-VP win (the 7, trade, build, flight,
exploration, pirate/ice tokens, founding, friendship cards, all 32 encounter
cards); the React client in `client/` plays it either hot-seat in one tab or
online; the Node + Socket.IO server in `server/` hosts rooms (create / join by
code / host starts with 3–4), redacts the state per socket, forwards actions
through the engine, carries chat, and re-binds a player by token after a
reload. 472 Vitest tests pass (423 engine, 17 server, 32 client), `tsc --noEmit`
is clean in all three packages, `pnpm build` produces `client/dist` and
`server/dist`, and the `starfarers-engine` CI job runs all of it. A Dockerfile
builds the single-process deploy. Verified by hand in headless Chromium: a
12-turn hot-seat run and a 3-browser online game (lobby, chat, start, hidden
hands, trade, shake, encounter, move, reload-reconnect, end turn) with zero
page errors.

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
    src/net/redact.ts   redactState(state, viewerId) + handSize(); src/net/protocol.ts: Socket.IO event types
    src/flight/reach.ts reachablePaths / legalMoves / legalJumpTargets (BFS + validateEndNode)
  server/                                        @starfarers/server, Node 22 + Socket.IO 4, in-memory rooms
    src/rooms.ts        RoomStore (no sockets): create/join/resume/bind/start/applyAction/chat/snapshot/restore
    src/socket.ts       attachSockets(io, store): protocol events → store, per-socket redacted `state`
    src/static.ts       static handler for client/dist with SPA fallback
    src/index.ts        entry: http + static + /healthz + Socket.IO; env PORT, HOST, STATIC_DIR, CORS_ORIGIN
    test/bot.ts         greedy bot (nextAction / actor) used to play whole games
    test/               rooms.test.ts (8), fullGame.test.ts (3 whole games to a win), socket.test.ts (6,
                        socket.io-client against an in-process server, incl. a full game over sockets)
  client/                                        @starfarers/client, Vite 6 + React 19 + zustand + socket.io-client
    index.html  vite.config.ts (proxies /socket.io to :3000 in dev)  vitest.config.ts (jsdom + testing-library)
    src/main.tsx  src/App.tsx   hash router (#/ #/local #/online #/room/CODE), GameScreen (store-agnostic)
    src/styles.css              dark theme, one file
    src/store/gameStore.ts      GameStoreState + hot-seat store; StoreContext / useGameStore / useGame / useAct
    src/net/remoteStore.ts      RemoteStoreState (extends GameStoreState) over a SocketLike; session.ts (localStorage);
                                socket.ts (real socket.io-client + lazy singleton)
    src/board/Board.tsx         SVG board from state.board + board/geometry; VpTrack.tsx; legalMoves.ts re-exports shared
    src/panels/                 HandPanel, MothershipPanel, BuildMenu, TradePanel, FriendshipPanel, SevenDialog,
                                EncounterModal, FoundStationDialog, ActionBar, LogPane, PassBanner, SetupScreen,
                                ResourcePicker (BagPicker), OnlineLobby (JoinScreen, RoomLobby), ChatPanel
    src/ui/format.ts            colours, labels, bag/hand helpers (no rules)
    test/                       6 files, 32 tests (legal-move highlight vs engine, encounter modal per
                                awaiting.kind, viewer switch, scripted full turn + replay, remote store
                                over a fake socket, session storage)
  Dockerfile  .dockerignore     single-process image: node server/dist/index.js serving client/dist
```

Toolchain: Node 22, pnpm 10.28, TypeScript 5.9.2 (strict,
`noUncheckedIndexedAccess`, `exactOptionalPropertyTypes`), Vitest 3.2.4, Vite
6.4.5 (pinned through a root `pnpm.overrides` so vitest and the client share one
Vite), React 19, zustand 5, ESM.
From `starfarers-online/`:

```sh
pnpm install && pnpm typecheck && pnpm test   # 472 tests, ~30 s (the socket full game is the slow one)
pnpm build                                    # client/dist (Vite) + server/dist/index.js (esbuild bundle)
pnpm start                                    # http://localhost:3000 — hot-seat and online from one process
pnpm dev:server & pnpm dev:client             # dev: tsx watch on :3000, Vite on :5173 proxying /socket.io
docker build -t starfarers . && docker run -p 3000:3000 starfarers
```

Deploy target (HANDOFF §7.7): any Node host that runs `pnpm build && pnpm start`
or the Dockerfile; one process, in-memory rooms (lost on restart — see §8 for
persistence). `PORT`, `HOST`, `STATIC_DIR`, `CORS_ORIGIN` are the only knobs.

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
| 4 Hot-seat client | `dc3cd18` | `client/` package; store with one rng per game and an action log that replays deterministically; SVG board (hexes, resource-coloured planets, discs sized by dice probability, face-down discs, P/I tokens, outposts with 5 docks, colonies/spaceports/ships in player colours); ship selection → BFS highlight filtered by `validateEndNode`, hover path preview, click to `moveShip`; found-colony buttons and a dock + friendship-card dialog for stations; hand / others' counts, mothership with shake animation, VP track, build menu with affordability and board site picks, supply trade with every ratio the player may use, player trade proposal / counter / accept / reject / withdraw, friendship card actions (Fame for Sale, Helping Hand, Relief Fund), 7 dialog (discard picker, steal target), encounter modal with progressive text and a control per `awaiting.kind` (space jump through board clicks), log pane with replay slider, pass-the-laptop curtain, seat select, error toast with the engine's message; Playwright-driven 12-turn smoke run with zero page errors | 444 |
| 5 Server, lobby, reconnect | (this branch, after `32b5c73`) | `shared/net`: `redactState` (other hands emptied + `handCount`, reserve pile / encounter deck emptied + counts, `seed` blanked, hidden log payloads stripped) and the typed Socket.IO protocol; `shared/flight/reach.ts` (BFS moved out of the client); `server/`: `RoomStore` with 6-char codes, per-player reconnect tokens, colours by join order, host-only start with 3–4, server-generated seed and one `Rng` per room, action validation (`action.playerId` must be the socket's player) before the engine, chat list, `snapshot()/restore()`, `startWithState()`; `attachSockets` emits `lobby` to the room, `state` redacted per socket with the accepted action attached, `error` to the sender only, evicts a stale socket when a token resumes elsewhere, mirrors `connected` into the game state; static serving + `/healthz`; `client/`: hash router, `StoreContext` so every panel runs against either store, `RemoteGameStore` (dispatch → emit with ack, snapshots for replay, viewer fixed, no curtain), localStorage session + auto-resume on `#/room/CODE`, join/create/rejoin screen, room lobby with copyable code, start button and chat, chat panel in the game sidebar, `(offline)` tag on disconnected players; Dockerfile; CI builds both; a greedy bot plays whole games to a win (3 through the store, 1 over sockets) with zero rejections | 472 |

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
13. Server (phase 5): `GameState.players[*].connected` is kept in step with the
   sockets by the room store (outside `applyAction`; no rule reads it).
   Redaction keeps the `GameState` shape; `Player.handCount`,
   `GameState.reservePileCount` / `encounterDeckCount` are the only additions,
   so every pure helper that reads public data works on a redacted state. Two
   engine helpers read opponents' `hand.length` (`stealTargets`,
   `playersWhoMustDiscard`) and are therefore server-side only; the client and
   the bot use `handSize()` instead.
14. `dispatch` on the remote store returns `true` optimistically; the engine's
   rejection arrives through the ack and lands in `error` a tick later. Pickers
   reset on that optimistic `true`, so a rejected pick must be re-entered.
15. A player who resumes from a second tab evicts the first (one socket per
   token). Leaving a room only forgets the local session; the server keeps the
   seat so the token can come back.
16. Turn timer: `RoomConfig.turnTimerSeconds` is stored and sent in the lobby
   view but nothing enforces it (spec: config only in phase 5).
17. Remote replay indexes the redacted states received since joining
   (`snapshots`, offset `snapshotBase` = actions before the join), so a resumed
   client cannot scrub before its own join. Full replay needs the server's
   action log plus the initial state (both already in `RoomSnapshot`).

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

## 7. Phase 5 — server, lobby, reconnect (done)

Delivered as described in §4. Protocol (`shared/src/net/protocol.ts`), all
client → server events take an ack `{ ok, value } | { ok, error }`:

| Client → server | Reply / effect |
|---|---|
| `createRoom {roomName, playerName}` | `JoinReply` (session with token, lobby, state null, actions []); room gets `lobby` |
| `joinRoom {code, playerName}` | same; refused when started, full, name taken |
| `resume {roomCode, playerToken}` | same with the current redacted state and the redacted action log; room gets `lobby` (+ `state` if started) |
| `startGame {}` | host only, 3–4 players; room gets `lobby` then `state` per socket |
| `action {action}` | `action.playerId` must be the socket's player; engine runs; everyone gets `state {state, action}` (both redacted per viewer); on failure the sender alone gets `error` and the ack carries it |
| `chat {text}` | room gets `chat` |

Server → client: `lobby(LobbyView)`, `state({state, action})`, `error(NetError | GameError)`, `chat(ChatMessage)`.

Test ids added for the online screens: `online-screen`, `player-name`,
`room-name`, `create-room`, `room-code`, `join-room`, `rejoin`, `net-error`,
`room-lobby`, `lobby-code`, `lobby-players`, `start-online`, `chat-panel`,
`chat-input`, `chat-send`, `viewer-name`, `home`, `go-local`, `go-online`.

Known gaps (phase 6 candidates): rooms live in memory (a restart drops them;
`RoomStore.snapshot/restore` are the hooks for Postgres/Supabase or a JSON
file); no room expiry; no spectators; the join screen does not validate the
code format before sending; no "kick" or host hand-over when the host leaves;
the turn timer is config only.

## 8. Phase 6 — polish (next)

Spec §15.6. Suggested order, each its own commit with tests:

1. **Persistence** (optional in spec, most valuable first): persist
   `RoomSnapshot` on every accepted action and restore on boot. Smallest
   version: a JSON file per room under `DATA_DIR` (write `snapshot(room)`
   after `applyAction`, `restore()` all files on start, delete finished
   rooms after a day). Supabase/Postgres is the same interface with a table
   `rooms(code primary key, snapshot jsonb, updated_at)`; the Supabase MCP
   tools are available in the cloud session if that route is chosen. Add
   room expiry (idle > N hours) while there.
2. **Variable set-ups** (strategic → explorer → wild space, spec §3.2):
   shuffle logic in `shared/src/setup/` using the existing loader and
   `assignPlanetsClockwise`; `GameVariant` already exists on `GameState`;
   `[VERIFY]` tile star backs live in `layouts/board.json`. Expose the variant
   in `createBeginnerGame`'s successor and in the lobby/setup screens.
3. **Advanced set-up draft** (§3.4), then the **3-player rule review** against
   judgment call §5.2 (blocker spaceport sites).
4. **Log replay from the server**: send `initial` + full `actions` in
   `JoinReply` (or on demand) so a resumed client can scrub to turn 1; the
   hot-seat store's `replayState` already shows the shape.
5. **Animations** (ship moves along the path, disc flips, VP marker slides)
   and the cosmetic gaps from §6; keyboard navigation.
6. **Host controls**: hand host over when the host disconnects for long,
   kick, room expiry UI; the turn timer enforcement if wanted.
7. Revisit the judgment calls in §5 once real players have played a few games.

## 9. Working agreements that held so far

- One agent per disjoint set of files; shared files (`types.ts`, `config.ts`,
  `policy.ts`, `actions/index.ts`) edited only additively with exact-string
  edits; every agent lists its shared-file edits in its report.
- Every rule gets a test; every `[VERIFY]` item lives in config with a comment.
- A review agent runs after each phase, traces real action sequences against
  the spec, fixes with regression tests, and lists judgment calls.
- Commits: `starfarers: <imperative subject>`, body explains why, one logical
  change per commit, verified green before committing.
- Verification before a phase is called done: `pnpm typecheck && pnpm test &&
  pnpm build`, plus a headless-Chromium drive of the built app (Playwright is
  preinstalled in the cloud container at `/opt/node-tools/node_modules/playwright`;
  the drive scripts are not committed — they live in the session scratchpad —
  so write a fresh one: start `node server/dist/index.js` on a spare port,
  open 3 browser contexts, use the test ids listed in §6/§7).
- Parallel shell calls that `cd` interfere with each other in this harness;
  use absolute paths in scripts.
