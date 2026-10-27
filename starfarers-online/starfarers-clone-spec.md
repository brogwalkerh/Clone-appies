# Catan: Starfarers (2019 edition) — Online Web Clone Build Spec

Purpose: give Claude Code everything it needs to build a browser-based, online multiplayer clone of **Catan: Starfarers (2019, Catan Studio / Kosmos)** for 3–4 friends. Rules below are transcribed from the official 2019 Rulebook and Almanac (catan.com PDFs). Where a detail could not be verified, it is marked **[VERIFY]**.

Legal note: this is a private, non-commercial fan clone for friends. Do not copy official artwork, card illustrations, or logos. Use original art/placeholder shapes. Do not name the product "Catan" in the UI; use a working title (e.g. "Starfarers Online").

---

## 0. Build Targets (read first)

- **Players:** 3–4 humans, online, one game lobby per room code.
- **Server-authoritative** game engine. The client only renders state and sends intents. All randomness (dice, mothership shake, encounter draw, reserve pile, number discs) happens on the server.
- **Reconnect-safe:** a player who refreshes or drops gets full state back and resumes.
- **Hidden info:** resource hands are hidden; card counts are public. Encounter card text is revealed step by step (see §9).
- **Hot-seat fallback:** same engine must run locally in one browser tab for testing (no network).
- **Deliverables:** `/server` (engine + sockets), `/client` (React UI), `/shared` (types, rules constants, pure engine), tests for the engine.

### Recommended stack
- TypeScript everywhere (user background: Java/C#/C++ — strongly typed code is the right fit).
- `shared/`: pure TS game engine, no I/O. `applyAction(state, action, rng) -> state | error`. Deterministic with injected RNG so tests are reproducible.
- `server/`: Node + Socket.IO. In-memory room store; optional Postgres/Supabase persistence for resume after server restart (phase 2).
- `client/`: React + Vite. Board rendered as SVG (hex grid with intersections as clickable nodes).
- Deploy: single Node process (Fly.io / Railway / Render). No auth beyond room code + display name.

---

## 1. Components (data to model)

| Item | Count | Notes |
|---|---|---|
| Board sections | 6 | Fixed Catanian Colonies end (4 planetary systems, Greek letters α β γ δ) + 15 vacant sector slots. Nebula line splits slots into 8 **Near** and 7 **Far**. Victory point track printed along one edge. |
| Sectors | 16 (15 used) | 8 planetary systems, 4 alien outposts, 4 empty. Backs show 1 star or 2 stars. One empty 1-star sector goes back in the box in the standard setup. |
| Number discs | 36 | See exact inventory below. 12 Catanian (Greek-letter backs) + 24 unexplored (icon backs). Some discs show 2 numbers (planet produces on either). |
| Special tokens | 16 | 3 pirate base tokens (**4, 5, 6** cannons), 2 ice planet tokens (**3, 4** freight pods), fame medal on back. 5 reserve number discs: **3, 9, 10, 11, 11**. 6 trade-ship markers. |

### Number disc inventory (verified from Almanac p.4–5)
Catanian Colonies (placed face up):
- α: 4, 8, 11
- β: 8, 10, 3/12
- γ: 3, 6, 5
- δ: 2/11, 6, 9

Unexplored planets. Every planetary system has 3 planets, each carrying one of 3 back icons (△ triangle, [ ] bracket, ◇ hex-circle). Discs are shuffled **per icon type** and one of each type goes on each of the 8 systems:
- △ (8): 3, 4, 4, 11, 12, 3, 4, 11
- [ ] (8): 2, 5, 5, 6, 9, 5, 8, 9
- ◇ (8): 10, 10, 10, **P4, P5, P6** (pirate bases), **I3, I4** (ice planets)

So pirate bases and ice planets can only appear on the ◇-icon planet of a system, and at most one per system.
| Resource cards | 100 | 20 each: ore (red planet), fuel (orange), carbon (blue), food (green), goods (multicolor). |
| Encounter cards | 32 | Numbered 1–32. Full text in §9. |
| Friendship cards | 20 | 5 per outpost civilization (Green Folk, Scientists, Diplomats, Merchants). Full text in §8. Travelers appear only in encounters. |
| Friendship markers | 4 | One per outpost civilization. 2 VP. |
| Fame medal pieces | 40 | Half-medals. 2 pieces = 1 VP. |
| Upgrades | 20 freight pods, 24 cannons, 24 boosters | Shared supply; if the tray is empty you cannot build that upgrade. |
| Player pieces (per color) | 9 colonies, 7 trade stations, 3 transport ships, 3 shipyards, 1 VP marker | Transport + colony = colony ship. Transport + trade station = trade ship. Colony + shipyard = spaceport. |
| Mothership | 1 per player | Holds 5 balls: 2 yellow, 1 red, 1 blue, 1 black. Shake reveals 2. |
| Dice | 2d6 | Production. |

### Ball values (mothership shake)
- Blue = 1, Yellow = 2, Red = 3, Black = 0 + triggers encounter.
- Shake = draw 2 of the 5 balls without replacement.
- Non-black pairs: YY=4, YB=3, YR=5, RB=4 → base speed 3–5.
- Any pair with black → base speed is fixed at **3** and an encounter happens (P = 4/10 = 40% per shake).
- For **combat strength / speed comparisons inside encounters**, black counts as 0 and does NOT trigger a second encounter.

---

## 2. Board Geometry

- Hex grid. Every sector is a cluster of 3 hexes ("3 lobes") meeting at a center point; planetary systems have one planet per lobe. Ships move along hex edges between **intersections** (hex vertices). Ships cannot pass through the center of a planetary system.
- Three special intersection types:
  - **Colony site:** intersection between 2 planets of the same system. 3 per planetary system.
  - **Docking point:** circular center of an outpost. 5 **docks** around it hold trade stations (docks are not movement nodes).
  - **Spaceport site:** the 2 intersections adjacent to a spaceport.
- Empty sectors have a central intersection ships can move through.
- Adjacency: an intersection is "adjacent to a planet" if the planet hex touches it. Exploration, pirate base defeat, and terraforming all key off this adjacency.

**Implementation:** model the board as a graph `{ nodes: Intersection[], edges: [nodeId, nodeId][] }`. Each node records `adjacentPlanets[]`, `siteType`, `sectorId`. Generate the graph from `layouts/board.json` (slots, lobes, Catanian hexes) plus a placement (`layouts/beginner.json` or a shuffled strategic placement) via the same loader.

---

## 3. Setup

### 3.1 Board — data lives in `layouts/board.json` and `layouts/beginner.json` (transcribed from the PDFs)
- Grid: pointy-top hexes, **odd-r offset coordinates** `[row, col]`, odd rows shifted half a hex to the right. 11 rows × 16 cols. Row 0 is the VP-track edge; column 0 is the Catanian edge.
- Catanian Colonies (fixed, column 0–1): α `[0,1]` food, `[1,0]` carbon, `[1,1]` fuel · β `[3,0]` ore, `[3,1]` fuel, `[4,1]` goods · γ `[6,1]` ore, `[7,0]` food, `[7,1]` carbon · δ `[9,0]` fuel, `[9,1]` goods, `[10,1]` ore. Disc values per system in §1; beginner assignment per lobe in `board.json`.
- 15 slots, each a tri-lobe of 3 hexes: near N1–N8, far F1–F7 (coordinates in `board.json`). The nebula only separates near from far for set-up; it has no movement effect.
- 16 tiles: 8 systems S1–S8 (planet colours + disc icon per planet in `board.json`), 4 outposts, 4 empties. Star backs are inferred (1-star: S1–S5, Green Folk, Merchants, 2 empties; 2-star: S6–S8, Scientists, Diplomats, 2 empties) — keep as config.
- Intersection rules per sector type (centre vertex, colony sites, docking point) are spelled out in `board.json` → `intersections`.
- **Beginner set-up** (`beginner.json`): exact tile-to-slot placement, planet orientation per lobe, and all 4 colours' starting spaceport, 2 colonies, and colony-ship site. Implement this first; it is the rulebook's recommended first game.
- **Strategic set-up:** shuffle 1-star tiles into near slots (return 1 empty), 2-star tiles into far slots, shuffle each Greek-letter disc trio within its system, shuffle the 24 discs per icon onto matching planets.

### 3.2 Variable setups (phase 2)
- **Strategic:** shuffle 1-star sectors → 8 Near slots; 2-star sectors → 7 Far slots; all face up; Greek-letter discs shuffled onto Catanian planets; remaining discs face-down on matching icons.
- **Explorer:** same as Strategic but sectors stay face **down** (must be discovered). Number discs are sorted by icon and placed only when a system is discovered.
- **Wild Space:** all 16 sectors shuffled and dealt face down from nearest slot to farthest; 1 left over returns to box unseen.

### 3.3 Players (Beginner)
- Each player: 2 colonies + 1 spaceport on preset Catanian sites (diagram). In a **3-player** game, also place the 4th color's 2 colonies + 1 spaceport as blockers.
- 1 colony ship on the preset spaceport site.
- VP marker at **4**.
- Draw 3 resource cards from the reserve pile.
- 1 fame medal piece.
- 1 booster on the mothership.
- Starting player: highest 2d6 roll. Turn order clockwise.

### 3.4 Advanced setup phase (phase 2)
Snake draft on Catanian colony sites: R1 colony (clockwise), R2 colony (counter-clockwise), R3 colony (clockwise), R4 (counter-clockwise, starting with last placer of R3): upgrade 1 colony to spaceport, place 1 colony ship OR trade ship on a spaceport site, take 1 bonus upgrade from pool {2 boosters, 1 cannon, 1 freight pod} (3-player: one upgrade stays out). Then 3 reserve cards + 1 fame piece each.

### 3.5 Supply
- Resource supply: 20 of each type minus what is dealt.
- **Reserve pile:** 8 of each of the 5 types (40 cards), shuffled face down. When empty, rebuild it the same way from the supply.
- Friendship card stacks face up (visible to all), friendship marker on each stack.
- Encounter deck shuffled face down; discard pile.

---

## 4. Victory Points

| Source | VP | Can be lost? |
|---|---|---|
| Colony | 1 | No |
| Spaceport | 2 (replaces the colony's 1 → net +1 when built) | No |
| Friendship marker | 2 | Yes — goes to whoever has the most trade stations at that outpost |
| Pirate base token (defeated) | 1 | No |
| Ice planet token (terraformed) | 1 | No |
| 2 fame medal pieces | 1 | Yes — pieces can be lost in encounters; VP = floor(pieces / 2) |

**Win:** a player who reaches **15 VP on their own turn** wins immediately. (Server: check after every state change during the active player's turn.)

---

## 5. Turn Structure

```
1. PRODUCTION
   a. Active player rolls 2d6.
   b. All players collect production (or resolve a 7, §6).
   c. Active player draws from the reserve pile by VP: 4–7 VP → 2 cards; 8–9 VP → 1 card; 10+ → 0.
      (Can still be taken during Trade & Build if forgotten; forfeited once the mothership is shaken.)
2. TRADE & BUILD — any order, any number of times.
3. FLIGHT
   a. If the player has 0 ships on the board, skip to end of turn.
   b. Shake mothership → base speed, maybe encounter (resolve encounter fully before moving).
   c. Speed = base + boosters on mothership + boosters on Scientists friendship cards. Applies to every ship.
   d. Move ships one at a time, each up to Speed intersections.
4. Pass dice to the left.
```

### 5.1 Production details
- For each colony/spaceport adjacent to a planet whose disc shows the rolled number, owner takes 1 card of that planet's type. **A spaceport produces 1, not 2.**
- Two-number discs produce on either number.
- Green Folk "Production Increase" card: +1 of that type whenever you produce ≥1 of it.
- If the supply lacks enough of a type to pay everyone fully, **nobody** gets that type this roll.
- Diplomats "Galactic Relief Fund": if you got 0 cards from the roll (and it is not a 7), take any 1 resource.

## 6. Rolling a 7
In order:
1. Every player with **>7 cards** (8+) discards half, round down (9 → discard 4). "Reduced Tribute" card raises the threshold to >12.
2. Roller picks one opponent and steals 1 random card.
3. Every opponent draws 1 card from the reserve pile, starting left of the roller.
4. Roller takes their normal reserve-pile draw (by VP).
5. Continue to Trade & Build.

## 7. Trade & Build

### 7.1 Trade
- **With players:** active player only may initiate/finalize. Non-active players can only trade with the active player. No gifting (0-for-N is illegal).
- **With supply:** 3 identical → 1 any. 2 goods → 1 any.
- Merchants friendship cards: 2:1 for the named resource (unlimited); Ezzel's goods 1:1 once per turn.

**UI:** trade proposal object `{ from, to: playerId | 'supply', give: ResourceBag, want: ResourceBag }`; counter-offers; only the active player can accept/finalize.

### 7.2 Build costs
| Item | Cost | Limits / placement |
|---|---|---|
| Colony ship | 1 ore, 1 fuel, 1 carbon, 1 food | Needs a free transport ship + free colony piece + an unoccupied **own** spaceport site. Placed there. May move same turn. |
| Trade ship | 1 ore, 1 fuel, 2 goods | Needs free transport + free trade station piece + unoccupied own spaceport site. May move same turn. |
| Spaceport | 3 carbon, 2 food | Upgrade one of your colonies (needs a free shipyard, max 3). No ship needed. +1 VP. If an opponent's ship now sits on a new spaceport site, that opponent must move it away on their next turn if possible. |
| Booster | 2 fuel | Max 6 on mothership. +1 speed. |
| Cannon | 2 carbon | Max 6. +1 combat strength. |
| Freight pod | 2 ore | Max 5. +1 freight capacity. |

Max 3 ships on the board (3 transports). Max 9 colonies, 7 trade stations.

### 7.3 Other Trade & Build actions
- Diplomats "Fame for Sale": pay 1 goods → +1 fame piece, once per turn even with both copies.
- Diplomats "A Helping Hand": if ≥2 opponents have more VP than you, draw 1 random card from each of 2 of them, once per turn.
- Build a pending trade ship (trade-ship marker) as soon as possible.

## 8. Friendship Cards (exact effects)

**Green Folk** (Production Increase +1): Axxa fuel, Xulu carbon, Asox ore, Esox food, Xom goods.

**Scientists** (do not count as physical upgrades; cannot be removed by "remove an upgrade"):
- Kha-Star: combat +2.
- Hir-Akas: speed +2.
- Khor-Nem, Hir-Sto, Asa-Bar: speed +1 and combat +1 each.

**Diplomats:** Ra'Hal Reduced Tribute (×1), Re'Bah & Re'Ohm Fame for Sale (×2), Ra'Hna A Helping Hand (×1), Ra'Hno Galactic Relief Fund (×1).

**Merchants:** Zuzzo 2:1 carbon, Orzel 2:1 food, Crizzetu 2:1 ore, Utuzzo 2:1 fuel, Ezzel 1:1 goods (once/turn).

Rules: each trade station at an outpost = choose any 1 remaining card of that civilization (see all 5). Cards are never lost. Effects start immediately.

## 9. Flight Phase

### 9.1 Shake
Server draws 2 balls from {Y,Y,R,B,K}. If K present → `baseSpeed = 3`, push an `ENCOUNTER` sub-phase before movement. Otherwise `baseSpeed = sum`.

### 9.2 Flight rules (validate server-side)
- Move along connected intersections only. Cannot cross a planetary system center.
- Each ship: 0..Speed steps. Backtracking allowed within the turn.
- May pass through occupied intersections (counted). May **not end** on an occupied intersection (one piece per intersection).
- May not end on another player's spaceport site.
- Trade ship may never end on a colony site. Colony ship may never end on a docking point.
- Trade ship may end on a docking point **only** if it immediately founds a trade station (freight pod check §9.5).
- Colony ship may end on a colony site without founding; then on its next turn it must either found or leave (and may only return to that site by founding). Exception: pinned by an encounter.
- Encounter result "ship cannot move this turn" is enforced per ship.

### 9.3 Explore
When a ship (at any point in its move) reaches an intersection adjacent to a planetary system with face-down discs: flip all 3. Pirate/ice discs are replaced with the matching special token. Movement may continue. (Explorer/Wild Space: flipping a face-down sector works the same, then discs are placed.)

### 9.4 Found a colony
Colony ship ends on an unoccupied colony site not adjacent to any pirate base / ice planet → player may found: transport returns to supply, colony placed, +1 VP, produces from next roll. **3-player:** max 2 colonies per planetary system.

### 9.5 Found a trade station
Trade ship ends on a docking point and `freightPods > stationsAlreadyAtOutpost` (0 stations → need 1 pod; 3 stations → need 4). Max 5 stations per outpost. Transport returns; station placed; player picks a friendship card. First station at an outpost → friendship marker (2 VP). Marker moves to any player who later has strictly more stations there.

### 9.6 Pirate bases and ice planets
- Ship adjacent to a pirate-base planet and `cannons (+ Scientists cannon bonuses) >= tokenNumber` → base defeated immediately: token goes to player (1 VP, unlosable), draw a random reserve disc face up onto the planet.
- Ship adjacent to an ice planet and `freightPods >= tokenNumber` → terraformed, same reward flow.
- A colony ship already on the adjacent colony site may found immediately after, or continue moving.
- Token numbers (verified): `pirateBases: [4, 5, 6]`, `icePlanets: [3, 4]`.

### 9.7 Space jump
Move any one of your ships to any unoccupied intersection, obeying no-blockade rules. Trade ships cannot jump to any colony site. May explore/discover on arrival. Ends that ship's movement.

## 10. Encounters (full card text, 32 cards)

Mechanics:
- The player to the left "reads" — in the app, the server reveals text boxes progressively to **all** players; the active player makes the choice before seeing results.
- Resource offers (0–3) are paid to the supply before the result is revealed; with no cards you must choose 0.
- "Shake your mothership" inside an encounter = new 2-ball draw, black = 0, no new encounter.
- **Combat:** active player's strength = ball sum + cannons + Scientist cannon bonuses. Opponent named on the card ("player to your left/right", "2nd player to your left/right") shakes likewise. Win if `yours >= theirs`. The pirate player gains/loses nothing.
- **Speed race:** same but with boosters + Scientist speed bonuses. Win if `yours >= theirs`.
- "Remove any 1 upgrade": player's choice; no effect if none. "Lose fame pieces": no effect below 0.
- "Place 1 trade ship adjacent to 1 of your spaceports as soon as possible": free trade ship now if a transport + piece + free own spaceport site exist, else a **trade-ship marker** is held until possible. It can move the same turn.
- After any encounter, base speed is 3 and the discarded card goes to the discard pile. Cards 31 and 32 ("Wear and Tear") hit **all** players, in order, no choices.

| # | Setup | Branches |
|---|---|---|
| 1 | Merchant: offer 0–3. | 0: everyone gives you 1 resource of their choice, you lose 2 fame. 1: +1 food, lose 1 fame. 2: +1 any, +1 fame. 3: +2 any, +1 fame. |
| 2 | Merchant: offer 0–3. | 0: lose 1 fame. 1: +1 any. 2: +1 any, +1 fame. 3: +1 any upgrade, +1 fame. |
| 3 | Merchant: offer 0–3. | 0: lose 1 fame. 1: nothing. 2: +1 fame. 3: +1 goods, +1 fame. |
| 4 | Merchant: offer 0–3. | 0: gift returned (nothing). 1: +1 goods. 2: +1 any, +1 fame. 3: +2 any, +1 fame. |
| 5 | Merchant prince: offer 0–3. | 0: one ship cannot move, lose 1 fame. 1: lose 1 fame. 2: +1 any, +1 fame. 3: free trade ship. |
| 6 | Merchant prince: offer 0–3. | 0: one ship cannot move, lose 1 fame. 1: lose 1 fame. 2: +1 any, +1 fame. 3: free trade ship. |
| 7 | Merchant is a pirate in disguise after offer 0–3. Attack? | No: lose the gift. Yes: fight player to your **right**. Win: gift back, +1 fame. Lose: gift lost, one ship cannot move. |
| 8 | Same as 7 but fight player to your **left**. | Same results. |
| 9 | Pirate demands 2 resources. Surrender? | Yes: pay 2 (pirate thanks you). No: fight **right**. Win: free trade ship. Lose: remove 1 upgrade, +1 fame. |
| 10 | Pirate demands 2. Surrender? | Yes: pay 2, lose 1 fame. No: fight **2nd right**. Win: +2 carbon, +1 fame. Lose: one ship cannot move, +1 fame. |
| 11 | Pirate demands 2. Surrender? | Yes: pay 2 AND one ship cannot move. No: fight **left**. Win: +2 ore, +1 fame. Lose: remove 1 upgrade. |
| 12 | Pirates offer 1-for-2 trade. Accept? | No: +1 fame. Yes: trade 1→2 any with supply, then shake (black = 0, totals 1–5). Bands on card: low total → police confiscate the 2 cards and you lose 1 fame; middle → accused, lose 1 fame; high → safe voyage. **[VERIFY bands]** — default low=1–2, mid=3, high=4–5. |
| 13 | Same as 12. | No: nothing. Yes: same shake table. |
| 14 | Pirate offers to rob all opponents for 1 resource. Accept? | No: +1 fame. Yes: pay 1, shake. Bands: low → pirate cheats you, lose 1 fame; middle → take 1 random from each opponent but lose 1 fame; high → take 1 random from each opponent. **[VERIFY bands]** — same default. |
| 15 | Same as 14. | No: nothing. Yes: same shake table. |
| 16 | Pirate attacks. Flee? | Flee: if your boosters ≥ player to your **right**'s → escape; else fight. Fight **right**. Win: +1 any upgrade, +1 fame. Lose: remove 1 upgrade. |
| 17 | Pirate attacks. Flee? | Flee: boosters ≥ **2nd left** → escape but lose 1 fame; else fight. Fight **2nd left**. Win: +2 ore, +1 fame. Lose: remove 1 upgrade, +1 fame. |
| 18 | Pirate attacks. Flee? | Flee: boosters ≥ **left** → escape; else fight. Fight **left**. Win: free trade ship. Lose: one ship cannot move. |
| 19 | Distress call. Respond? | No: nothing (ship crashes). Yes: speed race vs **2nd right**. Win: free trade ship. Lose: remove 1 upgrade. |
| 20 | Distress call. Respond? | No: lose 1 fame (refused a Diplomat). Yes: speed race vs **left**. Win: +1 fame, take 1 random card from each opponent. Lose: remove 1 upgrade, +1 fame. |
| 21 | Distress call. Respond? | No: lose 1 fame. Yes: speed race vs **right**. Win: +1 upgrade of choice, +1 fame. Lose: remove 1 upgrade. |
| 22 | Ship attacked by pirates. Rescue? | No: nothing. Yes: fight **2nd right**. Win: +2 goods, +1 fame. Lose: one ship cannot move. |
| 23 | Ship attacked. Rescue? | No: lose 1 fame. Yes: fight **right**. Win: +2 any, +1 fame. Lose: remove 1 upgrade, +1 fame. |
| 24 | Ship attacked. Rescue? | No: lose 1 fame. Yes: fight **left**. Win: space jump for 1 ship, +1 fame. Lose: one ship cannot move, +1 fame. |
| 25 | Wormhole. Attempt jump? | No: draw a new encounter card. Yes: speed race vs **left**. Win: space jump. Lose: one ship cannot move. |
| 26 | Wormhole. | No: new card. Yes: race vs **right**. Win: jump. Lose: one ship cannot move. |
| 27 | Wormhole. | No: new card. Yes: race vs **2nd right**. Win: jump. Lose: remove 1 upgrade. |
| 28 | Travelers ask donation 0–3. | 0: remove 1 upgrade, lose 1 fame. 1: +1 fame. 2: +1 fame. 3: space jump. **[VERIFY]** split of 1 vs 2. |
| 29 | Travelers 0–3. | 0: nothing. 1–2: +1 fame. 3: free trade ship. **[VERIFY]** |
| 30 | Travelers 0–3. | 0: lose 1 fame. 1–2: +1 fame. 3: space jump, +1 fame. **[VERIFY]** |
| 31 | Wear and Tear (all players) | 1. Each player with >8 upgrades removes 1. 2. Reshuffle entire encounter deck (incl. discards), draw a new card for the active player. |
| 32 | Wear and Tear (all players) | 1. Each player with >6 upgrades removes 1. 2. Galactic Council: player(s) with the most freight pods get +1 fame. 3. Reshuffle deck, draw a new card. |

Model each card as data: `{ id, prompt, choice: 'yesno' | 'offer0to3', branches: {...}, opponent: 'L'|'R'|'LL'|'RR', test: 'combat'|'speed'|'boosters'|'shake', effects[] }`. Effects are a small enum the engine applies (`gainResource`, `loseFame`, `removeUpgrade`, `immobilizeShip`, `freeTradeShip`, `spaceJump`, `stealRandomFromAll`, `redraw`, ...).

For the **[VERIFY]** shake tables on 12–15, implement the obvious mapping (low total = bad, high = good, 3 bands) behind a config and label it in the code.

## 11. No-Blockade Rules (summary for the validator)
- Cannot end on another player's spaceport site.
- Trade ship never ends on a colony site.
- Colony ship never ends on a docking point.
- Trade ship on a docking point only with an immediate trade station.
- Colony ship parked on a colony site must found or leave next turn.
- Space jump obeys all of the above.

---

## 12. Engine Design

### 12.1 State (shared/types.ts)
```ts
type Resource = 'ore'|'fuel'|'carbon'|'food'|'goods';
type Phase = 'setup'|'production'|'tradeBuild'|'flight.shake'|'flight.encounter'|'flight.move'|'gameOver';

interface GameState {
  id: string; seed: string; variant: 'beginner'|'strategic'|'explorer'|'wild';
  players: Player[]; turnOrder: string[]; activePlayer: string; phase: Phase;
  board: Board;                     // graph + sectors + discs + tokens
  supply: Record<Resource, number>; reservePile: Resource[];
  upgradesTray: { boosters: number; cannons: number; freightPods: number; famePieces: number };
  encounterDeck: number[]; encounterDiscard: number[];
  friendshipCards: Record<Civ, FriendshipCardId[]>; friendshipMarkers: Record<Civ, string|null>;
  reserveDiscs: Disc[]; pendingTradeShips: Record<string, number>;
  turn: { rolled?: number; reserveDrawTaken: boolean; baseSpeed?: number; speed?: number;
          shipMovesUsed: Record<shipId, number>; immobilized: shipId[]; encounter?: EncounterCtx;
          usedOncePerTurn: string[] };
  log: LogEntry[];
}
interface Player { id; name; color; hand: Resource[]; vp: number; famePieces: number;
  mothership: { boosters: number; cannons: number; freightPods: number };
  friendshipCards: FriendshipCardId[]; medals: { pirate: number; ice: number };
  pieces: { coloniesLeft; stationsLeft; transportsLeft; shipyardsLeft };
  connected: boolean; }
```
Clients receive a **redacted** view: other players' `hand` becomes `handCount`; reserve pile and encounter deck are counts only.

### 12.2 Actions (intents)
`rollDice`, `takeReserveDraw`, `discardForSeven`, `stealForSeven{target}`, `proposeTrade`, `respondTrade`, `tradeWithSupply`, `build{item, siteId?}`, `useFriendshipCard{cardId, ...}`, `shakeMothership`, `encounterChoice{value}`, `encounterPick{...}` (upgrade to remove / ship to immobilize / jump target), `moveShip{shipId, path: nodeId[]}`, `foundColony{shipId}`, `foundTradeStation{shipId, dockIndex, friendshipCardId}`, `endTurn`.

Every action: validate → apply → append log → recompute VP → check win. Reject with a typed error the client can show.

### 12.3 VP recompute (pure function)
`vp = colonies + 2*spaceports + 2*markers + pirateMedals + iceMedals + floor(fame/2)` where spaceports are counted once (colony inside it is not double counted).

### 12.4 Tests (Vitest) — minimum
- Production incl. 7, discard threshold, supply shortage rule, Green Folk +1.
- Build legality (sites, piece limits, upgrade caps).
- Shake distribution and encounter trigger probability (40%).
- Path validation: pass-through, backtrack, no-blockade, step count.
- Explore flip, pirate/ice replacement, defeat/terraform thresholds.
- Trade station freight-pod threshold, friendship marker handoff.
- Every encounter card branch (table-driven).
- Win at 15 only on own turn.

---

## 13. Networking

- Socket.IO rooms keyed by 6-char code. Host creates, others join with name. Host starts when 3–4 present.
- Server keeps `GameState` per room; emits `state` (redacted per socket) after every accepted action; emits `error` to the sender on rejection.
- Reconnect: client stores `{roomCode, playerToken}` in localStorage; on reconnect, server re-binds socket to player.
- Trade negotiation is a server-mediated state object (one open proposal at a time); non-active players may send counter-proposals; only the active player can accept.
- Turn timer: optional, off by default.
- Chat: simple room chat.

---

## 14. Client UI

- **Board (SVG):** hex sectors; planets colored by resource with disc numbers (font size scaled to probability, 6/8 largest); intersections as clickable circles; highlight legal end nodes for the selected ship given remaining speed (BFS on the graph with step budget); draw the planned path; outposts show 5 dock slots.
- **Mothership panel:** your boosters/cannons/pods as icons; shake animation revealing 2 balls.
- **Hand:** your cards grouped by type; others show counts.
- **VP track** along the board edge.
- **Encounter modal:** text revealed box by box; choice buttons; shows both shake results in a fight/race.
- **Trade panel:** build offer, send to player or supply; incoming offers for non-active players.
- **Log** with replay of every event.
- Responsive enough for a laptop; phones are not a target in v1.

---

## 15. Implementation Phases

1. **Engine core** (shared): types, board graph builder from `layouts/*.json`, beginner placement, production, trade, build, VP, win. Tests. Include a test that the generated graph has exactly 24 colony sites on unexplored systems + 12 Catanian sites, 4 docking points, and that no path crosses a system centre.
2. **Flight**: shake, movement validator, explore, found colony, found station, friendship cards, pirate/ice.
3. **Encounters**: all 32 cards as data + effect interpreter. Tests per branch.
4. **Hot-seat client**: full UI against the local engine.
5. **Server + lobby + reconnect**: Socket.IO, redaction, trade negotiation.
6. **Polish**: 3-player rules, animations, log/replay, optional persistence, variable setups (Strategic → Explorer → Wild Space).

## 16. Open items (everything else is verified against the 2019 Rulebook + Almanac)
1. Star backs of the 16 tiles (`board.json` → `sectors[*].stars`) are inferred, not read. Check against the physical tiles.
2. Shake-result bands on encounter cards 12–15 (read the band labels off the physical cards; defaults are in the table).
3. The three "shipSide" entries in `beginner.json` were read from a small picture; if a starting colony ship is on the wrong one of the two spaceport sites it does not change play (both are legal).

Sources: Catan: Starfarers Rulebook (2019, catan.com PDF), Catan: Starfarers Almanac (2019, catan.com PDF), rulespal.com rulebook transcript, nerdly.co.uk review (ball values).
