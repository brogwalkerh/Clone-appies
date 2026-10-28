# Starfarers Online — project state and hand-off

Last updated after phase 6. Everything is on `main`: phases 1–5 via PR #2
(`45b6c0c`), phase 6 (persistence, variable set-ups, advanced draft, 3-player
review, server-side replay) via PR #3 (`e473ca2`), the phase 7 plan in this
file via PR #4 (`063b21f`). Phase 7 is in progress on `starfarers-phase-7`.

**Starting a new session:** paste the prompt in §10 into the new session. It
says to read `CLAUDE.md`, then this file top to bottom, then
`starfarers-clone-spec.md` §13–§16; branch from `main`; run the commands in §2
to confirm green (550 tests); then work §8 (phase 7) in order. Everything
before §8 is finished and tested; §8 is what separates the project from a
finished game and a deployable app.

## 1. Current state in one paragraph

Phases 1–6 of spec §15 are done except animations and turn-timer enforcement
(§8 part A also adds host controls and keyboard navigation): the pure
engine in `shared/` plays a complete game from set-up to a 15-VP win on any of
the four boards (beginner, strategic, explorer, wild space — the last two with
face-down tiles discovered by ships) starting either from the preset pieces or
from the §3.4 snake draft (the 7, trade, build, flight, exploration,
pirate/ice tokens, founding, friendship cards, all 32 encounter cards); the
React client in `client/` plays it hot-seat in one tab or online; the Node +
Socket.IO server in `server/` hosts rooms (create / join by code / host picks
board and set-up / starts with 3–4), redacts the state per socket (hidden
tiles included), forwards actions through the engine, carries chat, re-binds a
player by token after a reload, writes every room to a JSON file under
`DATA_DIR` and restores them on boot, expires idle rooms, and replays the
action log on request so a resumed client can scrub to turn 1. 550 Vitest
tests pass (464 engine, 44 server, 42 client), `tsc --noEmit` is clean in all
three packages, `pnpm build` produces `client/dist` and `server/dist`, and the
`starfarers-engine` CI job runs all of it. A Dockerfile builds the
single-process deploy with `/data` as the volume. Verified by hand in headless
Chromium (zero page errors): 3-browser online games on the explorer and
strategic boards and with the draft (lobby pickers seen by guests, chat, draft
through the UI, hidden hands, move, encounter, reload-reconnect, a server
restart with all three players resuming, log slider back to the initial state
and to a mid-game turn), plus hot-seat wild-space and draft runs.

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
    src/setup/           index.ts: createGame({ variant, setup, players, seed }) dispatches to beginner.ts
                         (preset pieces, 3p blockers), variants.ts (strategic / explorer / wild space tile +
                         disc shuffles), draft.ts (§3.4 snake draft: draftable sites, finishDraft),
                         common.ts (shared placement helpers); GAME_VARIANTS, SETUP_MODES + labels
    src/actions/        applyAction + per-phase handler modules (see §3); draft.ts handles the setup phase
    src/production/     produce.ts, seven.ts, relief.ts
    src/flight/         stats, shake, movement, explore, discover (face-down tiles), tokens, jump
    src/found/          colony, station, friendship, freeTradeShip
    src/encounters/     schema, cards (32 as data), engine (resumable interpreter), text (progressive reveal)
    src/index.ts        barrel; the server/client import only from here
    test/               19 files, 464 tests; test/support/tradeBuild.ts has fixture helpers;
                        setupVariants / discovery / draft tests are the phase 6 additions
    src/net/redact.ts   redactState(state, viewerId) + redactBoard() (hides undiscovered tiles) + handSize();
                        src/net/protocol.ts: Socket.IO event types
    src/flight/reach.ts reachablePaths / legalMoves / legalJumpTargets (BFS + validateEndNode)
  server/                                        @starfarers/server, Node 22 + Socket.IO 4, rooms in memory + JSON files
    src/rooms.ts        RoomStore (no sockets): create/join/resume/bind/configure/start/applyAction/chat/
                        snapshot/restore/restoreAll/sweep/flush/replayState; writes queued per room
    src/persist.ts      RoomPersistence interface; FileRoomPersistence (one <CODE>.json per room, atomic
                        rename, corrupt files skipped) and MemoryRoomPersistence (tests)
    src/socket.ts       attachSockets(io, store): protocol events → store, per-socket redacted `state`
    src/autoplay.ts     timeoutAction: the turn timer's minimal turn-ending sequence (+ pieces the test bot shares)
    src/timer.ts        TurnTimers: one unref'd timeout per room at `deadlineAt` (injectable scheduler)
    src/handover.ts     HostHandovers: one timeout per room at `handoverDueAt` (host hand-over, §5.25)
    src/static.ts       static handler for client/dist with SPA fallback
    src/index.ts        entry: http + static + /healthz + Socket.IO; restoreAll + sweep on boot, sweep every
                        10 min, flush on SIGTERM; env PORT, HOST, STATIC_DIR, CORS_ORIGIN, DATA_DIR,
                        ROOM_IDLE_HOURS, ROOM_FINISHED_HOURS, HOST_HANDOVER_MS
    test/bot.ts         greedy bot (nextAction / actor) used to play whole games
    test/               rooms.test.ts, fullGame.test.ts (whole games to a win: beginner ×3, strategic,
                        explorer, wild, draft+strategic 3p, draft+beginner 4p), socket.test.ts (socket.io-client
                        against an in-process server, incl. a full game over sockets and a replay round trip),
                        persist.test.ts (file store, restart determinism, sweep), replay.test.ts — 44 tests
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
                                ResourcePicker (BagPicker), OnlineLobby (JoinScreen, RoomLobby), ChatPanel,
                                DraftPanel (round 4 of the advanced set-up)
    src/ui/format.ts            colours, labels, bag/hand helpers (no rules)
    test/                       7 files, 42 tests (legal-move highlight vs engine incl. explorer and 3p
                                boards, encounter modal per awaiting.kind, viewer switch, scripted full
                                turn + replay, remote store over a fake socket incl. configureRoom and
                                server replay, session storage, variant/set-up pickers, draft panel)
  Dockerfile  .dockerignore     single-process image: node server/dist/index.js serving client/dist; DATA_DIR=/data (VOLUME)
```

Toolchain: Node 22, pnpm 10.28, TypeScript 5.9.2 (strict,
`noUncheckedIndexedAccess`, `exactOptionalPropertyTypes`), Vitest 3.2.4, Vite
6.4.5 (pinned through a root `pnpm.overrides` so vitest and the client share one
Vite), React 19, zustand 5, ESM.
From `starfarers-online/`:

```sh
pnpm install && pnpm typecheck && pnpm test   # 550 tests, ~30 s (the socket full game is the slow one)
pnpm build                                    # client/dist (Vite) + server/dist/index.js (esbuild bundle)
pnpm start                                    # http://localhost:3000 — hot-seat and online from one process
pnpm dev:server & pnpm dev:client             # dev: tsx watch on :3000, Vite on :5173 proxying /socket.io
docker build -t starfarers . && docker run -p 3000:3000 starfarers
```

Deploy target (HANDOFF §7.7): any Node host that runs `pnpm build && pnpm start`
or the Dockerfile; one process; rooms are written to `DATA_DIR` (default
`./data`, the Docker image uses `/data`) after every change and read back on
boot, so a restart keeps every game. Knobs: `PORT`, `HOST`, `STATIC_DIR`,
`CORS_ORIGIN`, `DATA_DIR` (empty string = memory only), `ROOM_IDLE_HOURS`,
`ROOM_FINISHED_HOURS` (both default 24), `HOST_HANDOVER_MS` (default 300000,
the shared `HOST_HANDOVER_MS`; a short value is handy for driving the hand-over).

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
- Actions (spec §12.2, all implemented): `draftColony{siteId}` and
  `draftFinish{spaceportSiteId,ship,shipSiteId,upgrade}` (phase `setup`, draft
  games only), `rollDice`, `takeReserveDraw`,
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
| 5 Server, lobby, reconnect | `1ccb53d` `52e5db3` `6b945b7` | `shared/net`: `redactState` (other hands emptied + `handCount`, reserve pile / encounter deck emptied + counts, `seed` blanked, hidden log payloads stripped) and the typed Socket.IO protocol; `shared/flight/reach.ts` (BFS moved out of the client); `server/`: `RoomStore` with 6-char codes, per-player reconnect tokens, colours by join order, host-only start with 3–4, server-generated seed and one `Rng` per room, action validation (`action.playerId` must be the socket's player) before the engine, chat list, `snapshot()/restore()`, `startWithState()`; `attachSockets` emits `lobby` to the room, `state` redacted per socket with the accepted action attached, `error` to the sender only, evicts a stale socket when a token resumes elsewhere, mirrors `connected` into the game state; static serving + `/healthz`; `client/`: hash router, `StoreContext` so every panel runs against either store, `RemoteGameStore` (dispatch → emit with ack, snapshots for replay, viewer fixed, no curtain), localStorage session + auto-resume on `#/room/CODE`, join/create/rejoin screen, room lobby with copyable code, start button and chat, chat panel in the game sidebar, `(offline)` tag on disconnected players; Dockerfile; CI builds both; a greedy bot plays whole games to a win (3 through the store, 1 over sockets) with zero rejections | 472 |
| 6 Polish, part 1 | `723d7ad` `60bb274` `66d4725` `ea03792` `5784d53` `576190f` | `server/persist.ts` (`RoomPersistence`, file + memory stores), `RoomStore` writes a snapshot after every change with one write chain per room, `restoreAll()` on boot, `sweep()` for idle/finished rooms, `flush()` on SIGTERM, env `DATA_DIR` / `ROOM_IDLE_HOURS` / `ROOM_FINISHED_HOURS`, Docker `/data` volume; `shared/setup/` `createGame({variant, setup})` with strategic / explorer / wild-space tile and disc shuffles (`[VERIFY]` items in config), `Sector.discovered`, `GameState.discPools`, `flight/discover.ts` (tile flipped + discs drawn per icon at the exploration trigger), undiscovered interiors excluded from paths, `redactBoard` so a hidden tile is indistinguishable from any other, face-down tiles on the SVG board, variant picker in the set-up screen and the lobby (`configureRoom`); `JoinReply.initial` + `replay {index}` with an incremental per-room cache and a client-side cache so a resumed client scrubs to turn 1; the §3.4 snake draft as phase `setup` with `draftColony` / `draftFinish`, `DraftPanel`, bot support, 3-player pool and free-site rules in config; the 3-player blocker review (§5.2) | 550 |

Phase 6 review pass fixed: every client could read every face-down number
disc (label, numbers, pirate/ice specials, even the id) on discovered but
unexplored systems — pre-existing since phase 5 for beginner, extended to
strategic by phase 6 — `redactBoard` now blanks face-down discs; the reserve
discs were sent in draw order, so the next pirate/ice replacement was
predictable — now sorted with positionless ids; `configureRoom` did not count
as activity, so a host's variant / start-mode choice was lost on restart. The
review also ran a property probe (explorer + wild, 3 and 4 players, 8 seeds ×
700 bot actions): every move the client would offer is accepted by the
validator and every shortest path it would not offer is rejected, zero
disagreements across 2,381 flight states and 75 discoveries.

Review passes fixed: non-active Relief Fund holder blocked; bogus card names
cleared a 7 discard for free; inherited object keys could write junk into the
tray; tokens never claimed by a ship already adjacent when the threshold was
reached; pending trade ships not placed as soon as a site freed up.

## 5. Documented judgment calls (revisit when the UI makes them visible)

1. Trade finalisation: when the ACTIVE player proposes, the recipient's accept
   executes the trade (spec §7.1 literally says only the active player accepts).
2. 3-player blockers: reviewed in phase 6. §7.2, §9.2 and §11 are all written
   about *players* and `threePlayerRule` says the blockers "only block the
   sites", so `BLOCKER_SPACEPORT_SITES_BLOCK_END_NODES = false` ([VERIFY],
   `config.ts`): the blocker pieces still occupy their intersections, but the
   two empty spaceport sites beside the blocker spaceport are ordinary end
   nodes. `true` restores the phase-2 reading; both are tested.
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
8. (Superseded in phase 6: variable set-ups, the advanced draft and
   persistence are done; see §5.18–§5.21. The turn timer is still config only.)
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
16. Turn timer (phase 7, §8.2; superseded the phase-5 "config only"): see §5.24.
17. Remote replay: states received since joining are indexed locally
   (`snapshots`, offset `snapshotBase`); earlier indices are fetched from the
   server (`replay {index}`, §5.21), so a resumed client can scrub to turn 1.
18. Persistence (phase 6): "activity" = create, join, configure, start, an
   accepted action, chat; each bumps `updatedAt` and writes the whole
   `RoomSnapshot` (fire-and-forget, one write chain per room, failures logged
   via `RoomStoreOptions.warn`, never thrown). Socket bind/unbind bump
   `updatedAt` in memory only, so after a restart a room can expire up to one
   session earlier. `sweep()` removes rooms idle longer than `idleMs`, or
   finished (`phase === 'gameOver'` or `winner`) and idle longer than
   `finishedMs`; a room with a connected player is never swept. Snapshots
   written before phase 6 lack `updatedAt` / `initial` and still restore
   (`StoredRoomSnapshot`). Every accepted action rewrites the file (~300 KB at
   500 actions); coalescing bursts is a possible follow-up.
19. Variable set-ups: the authoritative board holds the real tile under every
   slot; `redactBoard` turns an undiscovered sector into `kind: 'hidden'`
   (no planets, no interior vertices or edges, rim nodes lose
   `adjacentPlanets`) and a test proves the redacted slot is identical whatever
   tile is really there. The hot-seat Board draws through `redactBoard` too,
   so face-down tiles are hidden from hot-seat players (trusted not to inspect
   state, like hands). Discovery runs per move step (and before a space jump
   lands) at the same trigger as exploration: a system draws one disc per
   planet from `discPools[icon]` through the rng, then the normal flip; an
   outpost just becomes usable. `exploreSector` ignores undiscovered systems.
   Undiscovered slot interiors are never legal path or end nodes
   (`validatePath`, `validateEndNode`, `reachablePaths` agree).
20. `[VERIFY]` config for the set-ups: `DISCOVERY_ENDS_MOVE = false` (the ship
   keeps its remaining steps), `WILD_SPACE_SLOT_ORDER` (near slots then far,
   each by mean lobe x, ties top-to-bottom), `VARIABLE_SETUP_START_LOBE = 0`
   (planets assigned clockwise from the first lobe; the physical placer may
   rotate), `STRATEGIC_RETURNED_EMPTY = 'random'` (E1/E2 are identical). The
   three variants use the beginner starting pieces unless the advanced draft
   is chosen. `configureRoom` ignores unknown keys; a bad value is
   `badRequest`.
21. Server-side replay: a remote client cannot re-run the engine (redacted
   seed, piles and action payloads), so `RoomStore.replayState(room, k)`
   replays `initial` + `actions[0..k)` with `createRng(room.seed)`, caching one
   `{index, state, rngState}` per room and continuing from it when k grows; the
   live end is answered from `room.game`. ~3.4 ms per action, so a 700-action
   game replays from scratch in ~2.5 s; the LogPane waits 150 ms after the
   slider stops before asking, the client caches the last 50 positions and
   shows the nearest known state meanwhile. There is no rate limit on
   `replay` yet. Rooms saved before phase 6 have `initial: null`: the join
   reply says so, the slider starts at the join point and nothing is
   requested. A `state` broadcast without an action (a reconnect) now
   replaces the latest local snapshot instead of appending, which kept replay
   indices aligned.
22. Advanced draft (§3.4): `createGame({ setup: 'draft' })` starts in phase
   `setup` with `state.draft` {round, order, index, starter, colonies, pool}
   and `activePlayer` = the picker, so the usual gating and "waiting for X"
   UI apply. Rounds 1/3 follow `turnOrder`, 2/4 the reverse (round 4 starts
   with the last placer of round 3). `draftColony` accepts any free Catanian
   site (no distance rule in the spec; Catanian sites are never adjacent).
   Round 4 is ONE action, `draftFinish`, validated as a unit (own drafted
   colony → spaceport, ship on one of its two free spaceport sites, upgrade
   still in the pool and under the cap) to keep the policy and UI simple.
   Closing deals 3 reserve cards each in seating order, +1 fame, recomputes VP
   (4 each), deletes `draft`, sets `production` with the round-1 starter. The
   starting 2d6 roll uses the same rng order as the preset set-up. 3-player:
   `DRAFT_3P_REMOVED_UPGRADE = 'booster'` ([VERIFY]; `'random'` supported) and
   `DRAFT_3P_BLOCK_FREE_SITES = true` ([VERIFY]; the three free sites get
   blocker colonies, no blocker spaceport). `redactState` passes `setup` /
   `draft` through; snapshot/restore and `replayState` work mid-draft.
23. From the phase 6 review: (a) `moveShip` is validated as a whole path
   against the pre-move hidden set, so a step that discovers a sector cannot
   enter that sector's interior in the same action; a second `moveShip` with
   the remaining budget does it, and the client's highlights agree. (b) The
   room's play rng is `createRng(seed)` with the same seed the set-up
   consumed, so the first in-game draws repeat the stream that shuffled the
   deck and piles (and, in strategic, the visible tiles); not exploitable in
   practice (xoshiro state from ~15 bounded ints) and changing it would move
   every seeded fixture, but note it before a public deployment. (c)
   Face-down discs are hidden on the hot-seat board too, like hidden tiles.
   (d) Log order on a discovering move is "discovered → token claimed →
   moved" (cosmetic). (e) A no-op `configureRoom({})` writes nothing; any
   applied key rewrites the room file.

24. Turn timer (spec §13, §8.2): off by default; the host picks `null` or one
   of `TURN_TIMER_CHOICES` (`config.ts`, inferred: 30 s – 5 min) with
   `configureRoom({ turnTimerSeconds })`; any other value refuses the whole
   patch (`badRequest`). Deadline policy: the budget is per TURN, not per
   action — `RoomStore` sets `deadlineAt = now + seconds` when the game starts
   and whenever an accepted action changes `turnKey` (turn number + active
   player; in the draft, round + pick index, so every draft pick is a
   "turn"); actions inside the turn, including other players' 7 discards or
   encounter picks, do not extend it. `null` on game over or without a timer.
   `deadlineAt` is persisted in `RoomSnapshot` (older snapshots recompute it
   from now) and sent in the `state` payload (with `serverNow` for skew) and
   `LobbyView`. On expiry `expireTurn` submits `timeoutAction`
   (`server/src/autoplay.ts`) through `applyAction` until the turn key
   changes: roll → a pending 7 (each discarder drops their first cards, then
   the roller steals from the first target) → reserve draw skipped →
   `shakeMothership` if the player has ships, else `endTurn` (either closes an
   open trade, so no withdraw/reject is sent) → encounter: the awaited pick as
   whoever it is awaited from (first option / first cards / decline a jump),
   else offer 0 / answer "no" → a pending trade station (first free dock,
   first card) → `endTurn`. The one forced move: when the engine refuses
   `endTurn` because a parked colony ship must found or leave, the timer
   founds if it may, else takes that ship's shortest legal move. It never
   builds or trades. Each automatic action is an ordinary accepted action
   (broadcast, logged, persisted, replayable); the visible marker is one chat
   line per expiry, `from: 'timer'`, text `timer: <name> ran out of time;
   rolled, …, ended the turn` (no engine type changes). A refused or missing
   automatic action stops the run, clears the deadline for that turn and
   warns: the timer never loops. A room with nobody connected waits (the
   timer does not play an abandoned game or keep it from being swept); the
   first player back into an overdue room gets a fresh budget.
   `server/src/timer.ts` keeps one unref'd timeout per room, re-armed on every
   `state` broadcast and for restored rooms at boot, cleared on null and for
   swept rooms. The test bot imports `actor` and the draft / 7 / encounter-pick
   / pending-station pieces from `autoplay.ts`, so its games are unchanged.

25. Host controls (§8.3): `kickPlayer` is host-only and lobby-only (a started
   game keeps every seat; the host cannot kick themself); the seat and its
   token are deleted, the kicked socket gets `kicked` and leaves the room, its
   client forgets the session and shows the join screen with the reason. A
   kick is not a ban: the same name may join again as a new seat. Player ids
   are reused (`pN` lowest free). `transferHost` is host-only, any time, to
   any other seated player (also an offline one; the hand-over clock then
   starts). Automatic hand-over: while the host is disconnected
   (`Room.hostAwaySince`), after `HOST_HANDOVER_MS` (config, 5 min, inferred)
   the host passes to the *longest-connected* player = the connected
   non-host with the earliest `connectedAt` (start of the current unbroken
   connection; a reconnect resets it, a second tab replacing the first does
   not), ties by seat order. Checked by a per-room timeout armed on every
   lobby broadcast (`server/src/handover.ts`) and on every bind (a player
   returning to an overdue room takes over at once). Nobody else connected →
   no hand-over until someone binds. Every host change is activity (written,
   `updatedAt` bumped) with a chat line `from: 'room'`. `hostAwaySince` /
   `connectedAt` are memory only: after a restart the absence counts from
   boot, so the earliest hand-over is one full window after the restart.
   `LobbyView.expiresAt` = `updatedAt + idleMs` (sent with `idleMs`); the
   lobby advances it on chat seen since. It is the deadline once everyone
   has left — a room with a connected player is never swept.

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

Known gaps, now scheduled in §8 (none block play): no keyboard navigation and
the Diplomats label overlap (§8.4); the pending trade-ship marker's
spaceport-site rule is shown only through the log (§8.4); no save/load of a
game to a file (§8.10); phones are not a target (spec §14).

## 7. Phase 5 — server, lobby, reconnect (done)

Delivered as described in §4. Protocol (`shared/src/net/protocol.ts`), all
client → server events take an ack `{ ok, value } | { ok, error }`:

| Client → server | Reply / effect |
|---|---|
| `createRoom {roomName, playerName}` | `JoinReply` (session with token, lobby, state null, actions []); room gets `lobby` |
| `joinRoom {code, playerName}` | same; refused when started, full, name taken |
| `resume {roomCode, playerToken}` | same with the current redacted state and the redacted action log; room gets `lobby` (+ `state` if started) |
| `configureRoom {variant?, setup?, turnTimerSeconds?}` | host only, before start; validated against `GAME_VARIANTS` / `SETUP_MODES` / `TURN_TIMER_CHOICES` (or `null`); room gets `lobby` |
| `startGame {}` | host only, 3–4 players; builds the game with `createGame(room.config)`; room gets `lobby` then `state` per socket |
| `action {action}` | `action.playerId` must be the socket's player; engine runs; everyone gets `state {state, action}` (both redacted per viewer); on failure the sender alone gets `error` and the ack carries it |
| `chat {text}` | room gets `chat` |
| `kickPlayer {playerId}` | host only, before start, not yourself; ack `{kicked}`; the kicked socket gets `kicked {roomCode, message}` and leaves; its token stops resuming (`badToken`); room gets `lobby` (§5.25) |
| `transferHost {playerId}` | host only, any time, another seated player; ack `{hostId}`; room gets `lobby` |
| `replay {index}` | the redacted state after `index` accepted actions (0 = initial); `badRequest` outside `0..actions.length` or when the room predates phase 6 |

Server → client: `lobby(LobbyView)`, `state({state, action, deadlineAt?, serverNow?})`, `error(NetError | GameError)`, `chat(ChatMessage)`.
Phase 7 added `LobbyView.deadlineAt?`, the `state` payload's `deadlineAt?` / `serverNow?` and timer chat lines
(`from: 'timer'`), and the test ids `timer-select`, `lobby-timer`, `turn-timer`, `chat-timer`.
Host controls (§8.3) added `kickPlayer` / `transferHost`, the server event `kicked`, `LobbyView.expiresAt?` /
`idleMs?` / `hostHandoverAt?`, room notice chat lines (`from: 'room'`, `ROOM_CHAT_ID`) and the test ids
`kick-<playerId>`, `make-host-<playerId>`, `lobby-host`, `lobby-expires` (`data-expires-at`), `game-host`,
`transfer-host`, `transfer-host-confirm`, `chat-room`.

Test ids added for the online screens: `online-screen`, `player-name`,
`room-name`, `create-room`, `room-code`, `join-room`, `rejoin`, `net-error`,
`room-lobby`, `lobby-code`, `lobby-players`, `start-online`, `chat-panel`,
`chat-input`, `chat-send`, `viewer-name`, `home`, `go-local`, `go-online`.
Phase 6 added `variant-select`, `variant-description`, `lobby-variant`,
`setup-select`, `setup-description`, `lobby-setup`, `phase-label`,
`hidden-<slot>` (a face-down tile on the board), `draft-panel`,
`draft-spaceport-<node>`, `draft-ship-colony|trade`, `draft-ship-site-<node>`,
`draft-upgrade-<kind>`, `draft-confirm` (draft sites are highlighted
`node-<id>` like build picks), and `JoinReply.initial` (the redacted initial
state) next to `actions`.

Known gaps, now scheduled in §8: (kick and host hand-over done, §5.25; the turn
timer is enforced, §5.24); the join screen does not validate the code format
(§8.4); `replay` has no rate limit (§8.6); no spectators (§8.10). Rooms are
persisted and expired since phase 6 (§5.18).

## 8. Phase 7 — finish the game, then ship it (next)

Spec §15 is complete except two §15.6 items (animations, turn timer) and the
rule confirmations in §16. Part A closes the spec; part B makes the app safe to
put in front of strangers; part C is optional. Each numbered item is one
commit (or a few) with tests, verified green and driven in headless Chromium
before it is called done (§9). Stop after part A and report if the budget
looks tight.

### Part A — close the spec

1. **Animations** (§14): the ship slides along `moveShip.path` node by node;
   a discovered tile flips (`hidden-<slot>` → sector) and a disc flips on
   exploration; the VP marker slides along `vp-track`; the mothership shake
   already animates. Drive them from the accepted action attached to each
   `state` broadcast (remote) or from the last `actions[]` entry (hot-seat) so
   replay stays instant: animate only when the shown state is live. CSS
   transitions on the SVG `transform` are enough; no library. Add a
   `prefers-reduced-motion` switch and a test that the final positions equal
   the state (animation is presentation only; the engine is untouched).
2. **Turn timer** (done, see §5.24) (§13 "optional, off by default"): `RoomConfig.turnTimerSeconds`
   is stored and shown but unenforced. Server side only: `RoomStore` gets a
   deadline per room set when `activePlayer` changes (`startWith`, after each
   accepted action), `attachSockets` arms one `setTimeout` per room (unref'd,
   re-armed on every `state`, persisted as `deadlineAt` in `RoomSnapshot` so a
   restart keeps it). On expiry the server submits the minimal legal
   sequence for the active player through the engine as that player
   (`rollDice` if not rolled → `takeReserveDraw` is optional, skip → resolve a
   pending 7 by discarding the first cards / stealing from the first target →
   `shakeMothership` if ships → encounter: first option / decline → `endTurn`),
   logging "timer: …" lines; the bot in `server/test/bot.ts` already produces
   exactly this sequence, so share its `nextAction`. Host sets it in the lobby
   via `configureRoom({ turnTimerSeconds })` (`timer-select`, `lobby-timer`);
   the client shows a countdown (`turn-timer`) from `deadlineAt` in the `state`
   payload. Tests: expiry runs the sequence, a timely action re-arms, a
   restart keeps the deadline, `null` disables.
3. **Host controls** (done, see §5.25) (HANDOFF §7 known gaps): `kickPlayer {playerId}` (host,
   lobby only — a started game keeps every seat), `transferHost {playerId}`
   (host, any time), automatic hand-over when the host has been disconnected
   for `HOST_HANDOVER_MS` (config, default 5 min) to the longest-connected
   player, and the room's expiry shown in the lobby (`lobby-expires`, from
   `updatedAt` + `idleMs` sent in `LobbyView`). Protocol rows + socket tests.
4. **Keyboard navigation and the §6 cosmetic gaps**: Tab order through the
   action bar, dialogs and the board (nodes are `<circle>`s; give the
   highlighted ones `tabIndex` and Enter/Space handlers), Escape closes
   dialogs, arrow keys move the log slider; the outpost civ label on the
   Diplomats tile overlaps the dock row (move the label to the lobe without
   docks); show the pending trade-ship marker's spaceport-site rule in the UI
   (today only the log); validate the room code format on the join screen
   before sending. Component tests for the keyboard paths.
5. **Rule confirmation checklist** (spec §16 + the phase 6 `[VERIFY]` items).
   Someone with the physical box reads these off and flips the config where
   needed; each is pinned by a test so the change is deliberate:
   `board.json` `sectors[*].stars` (tile backs); `beginner.json` `shipSide`;
   encounter cards 12–15 shake bands (`config.ts`); `DISCOVERY_ENDS_MOVE`;
   `WILD_SPACE_SLOT_ORDER`; `VARIABLE_SETUP_START_LOBE` (or let the discoverer
   orient: a `discoverOrient {sectorId, startLobe}` pending step, only if the
   rulebook says the discoverer chooses); `STRATEGIC_RETURNED_EMPTY`;
   `DRAFT_3P_REMOVED_UPGRADE`; `DRAFT_3P_BLOCK_FREE_SITES`;
   `BLOCKER_SPACEPORT_SITES_BLOCK_END_NODES`; judgment calls §5.1–§5.7. Record
   the outcome in §5 and remove the `[VERIFY]` tag from confirmed items.

### Part B — make it a real multiplayer app

6. **Server hardening**: rate-limit `replay` per socket (e.g. 2/s, burst 5)
   or keep a checkpoint state every 50 actions per room so a request is at
   most 50 engine steps; coalesce persistence writes (one write per room per
   ~250 ms, last snapshot wins, still flushed on SIGTERM); a
   `PostgresRoomPersistence` behind the same interface (`save`, `remove`,
   `loadAll`; table `rooms(code text primary key, snapshot jsonb,
   updated_at timestamptz)`, `DATABASE_URL` selects it over the file store;
   the Supabase MCP tools are available in the cloud session if that route is
   chosen); input size limits on every event (names, chat, action payloads
   are already bounded — check `replay`, `configureRoom`); a `/healthz` that
   reports persistence health.
7. **Stable identity**: a seat is a token in localStorage today, so a cleared
   browser loses it. Smallest step: a "rejoin link" (`#/room/CODE?t=<token>`)
   the lobby shows once with a copy button, and a host-side "re-invite" that
   mints a fresh token for a seat (`reissueToken {playerId}`, host only,
   invalidates the old one). Accounts (magic-link email via Supabase Auth)
   are a later option; do not block on them.
8. **Deployment**: the Dockerfile is the unit. Target any Node host (Railway
   is connected to this workspace but needs authorising in the session;
   Fly/Render work the same): set `PORT`, `DATA_DIR=/data` on a volume (or
   `DATABASE_URL` after item 6), `CORS_ORIGIN` unset (same origin), TLS from
   the host. Add `Scripts/`-style `deploy.md` under `starfarers-online/` with
   the exact commands, a GitHub Actions `starfarers-deploy` job gated on
   `starfarers-engine` passing on `main`, structured logs (JSON lines) and
   a log line per accepted action with room code and player id for
   debugging. Smoke-test the deployed URL with the drive script (§9) pointed
   at it instead of a local server.
9. **Real-play feedback**: play three full games with people (one per board
   type, one with the draft) and revisit HANDOFF §5 (23 judgment calls) and
   the `[VERIFY]` list with what felt wrong; file each change as its own
   commit with the rule reference.

### Part C — nice to have (pick by taste)

10. Spectators (`joinAsSpectator`, redacted as "no seat", no actions); save
    and load a hot-seat game to a file (`loadGame` + `actions[]` already make
    it small); an AI opponent that is fun rather than merely legal (the test
    bot is greedy and rule-complete; start from it, add trade evaluation and
    target selection); an in-app rules reference generated from the spec; a
    phone layout (explicitly out of scope in §14 — only if wanted); a
    tutorial using the replay slider over a scripted game.

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
  use absolute paths in scripts (also inside `( … ) &` subshells).
- Branches: one per phase from `main`, landed by a PR with a merge commit
  (PR #2, PR #3). After a PR merges, never stack on that branch; start the
  next one from `main`. The first commit of a session fixes this file's
  header if it is stale.
- Phase 6 ran one agent per item in isolated git worktrees and cherry-picked
  the results onto the branch in order; the worktrees are cut from `main`, so
  an agent that must build on the branch has to `git reset --hard` to it
  first. Shared-file edits stayed additive, so every cherry-pick applied
  cleanly.
- The phase 6 drive script plays any set-up by clicking test ids in priority
  order (take-seat, draft panel / highlighted site, encounter and 7 dialogs,
  roll / reserve / shake / found / one move / end), reloads a guest, restarts
  the server on the same `DATA_DIR`, and scrubs the log slider to 0 and to
  the middle, checking the log pane shrinks accordingly (the action bar is
  hidden while replaying).

## 10. Kickoff prompt for the next session

Paste this as the first message of a new Claude Code session on
`brogwalkerh/Clone-appies`:

```
The Starfarers Online project lives in starfarers-online/ on main of
brogwalkerh/Clone-appies (phases 1–6 merged; PR #3 is phase 6). Read, in
this order:
1. starfarers-online/CLAUDE.md
2. starfarers-online/HANDOFF.md (all of it; §8 is your work list)
3. starfarers-online/starfarers-clone-spec.md §3, §9, §13, §14, §15, §16

Confirm the baseline is green before changing code:
cd starfarers-online && pnpm install && pnpm typecheck && pnpm test && pnpm build
Expect 550 tests passing across shared, server and client.

Create one branch from main for phase 7. If HANDOFF.md's header is stale,
fix it in the first commit.

Then phase 7 (HANDOFF §8) in order, one commit per item with tests,
verified green before each commit:
Part A: 1 animations, 2 turn timer, 3 host controls, 4 keyboard navigation
and cosmetic gaps, 5 rule-confirmation checklist (prepare the checklist and
leave the config values unchanged unless I give you the physical readings).
Stop after part A and report if the budget looks tight; part B (6 server
hardening, 7 stable identity, 8 deployment, 9 real-play feedback) can wait.

Rules that held so far and must keep holding: engine in shared/ stays pure
with all randomness through the injected Rng; every rule gets a test; every
[VERIFY] item lives in config.ts with a comment; the engine never sees a
redacted state; commits are "starfarers: <imperative subject>" with a body
explaining why; push only to your branch; do not open a pull request unless
asked.

Verification before you call an item done: pnpm typecheck && pnpm test &&
pnpm build, then a headless-Chromium drive of the built app (Playwright is
at /opt/node-tools/node_modules/playwright; write a fresh script in your
scratchpad as HANDOFF §9 describes, start node server/dist/index.js on a
spare port, open three browser contexts, use the test ids in HANDOFF
§6–§7). Use absolute paths in shell calls; parallel calls that cd interfere
with each other.

When finished, update HANDOFF.md the same way the previous sessions did
(state paragraph, layout, phase table row, judgment calls, next-phase list,
this kickoff prompt), commit it, push, and end with a short report: what
was built, what passes, what is next.

You are the project manager: delegate each item to an agent in its own
worktree (reset it to your branch first, see HANDOFF §9), review and
cherry-pick the results in order, and run a review agent at the end.
```
