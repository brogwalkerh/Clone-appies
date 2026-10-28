# Rule-confirmation checklist

For someone with the physical box (rulebook, almanac, the 16 sector tiles, the
encounter cards). Each entry is a rule the app currently plays by an inferred or
judged reading (spec §16, `[VERIFY]` in `shared/src/config.ts`, HANDOFF §5).

How to use it:

1. Tick the box in the summary when you have looked, and write what you saw on the
   entry's **Reading:** line.
2. If the box agrees with the current value: nothing to change. Tell the project
   manager so the `[VERIFY]` tag can be removed and HANDOFF §5 updated.
3. If it disagrees: change only the constant / JSON field named in the entry, then
   update the pin test named in the entry in the same commit (it fails on purpose
   until you do). Run `pnpm typecheck && pnpm test && pnpm build` from
   `starfarers-online/`.

Every pin message reads `RULES-CHECKLIST.md #N (...)`, so a failing test points
back here. Value pins all live in `shared/test/verifyPins.test.ts`; behaviour
pins for the judgment calls are named per entry.

Page references are the ones recorded when the layouts were transcribed (Almanac
p.4 sector tiles, Almanac p.16 strategic picture, Rulebook pp.2–3 beginner
set-up). Where no page was recorded the entry names the rulebook section to look
for.

## Summary

| ✓ | # | Look at | Question | Current value | Change in |
|---|---|---|---|---|---|
| [ ] | 1 | Backs of the 16 sector tiles | 1 star or 2 stars, per tile? | S1–S5, Green Folk, Merchants, E1, E2 = 1★; S6–S8, Scientists, Diplomats, E3, E4 = 2★ | `layouts/board.json` `sectors[*].stars` |
| [ ] | 2 | Rulebook pp.2–3 beginner picture | Which spaceport site holds each colour's starting colony ship? | yellow `[1,1]`, red `[4,1]`, blue `[9,1]`, white `[7,1]` | `layouts/beginner.json` `startingPieces.*.spaceport.shipSide` |
| [ ] | 3 | Encounter cards 12, 13, 14, 15 | Which shake totals are low / middle / high? | low 1–2, mid 3, high 4–5 | `ENCOUNTER_SHAKE_BANDS` |
| [ ] | 4 | Encounter cards 28, 29, 30 | Do donations of 1 and 2 give the same result? | yes (1 = 2 = +1 fame) | `TRAVELERS_DONATION_BRANCHES` |
| [ ] | 5 | Rulebook: explorer / wild space, discovering a sector | Does discovering a face-down sector end the ship's move? | no | `DISCOVERY_ENDS_MOVE` |
| [ ] | 6 | Rulebook / almanac: wild space set-up | In what slot order are the 15 face-down tiles dealt? | N4 N1 N6 N5 N2 N7 N3 N8, F5 F1 F3 F6 F2 F4 F7 | `WILD_SPACE_SLOT_ORDER` |
| [ ] | 7 | Rulebook: strategic set-up, discovering a sector | Who orients a placed / discovered system tile? | nobody; fixed rotation (lobe 0) | `VARIABLE_SETUP_START_LOBE` (or new `discoverOrient` step) |
| [ ] | 8 | Rulebook: strategic set-up | Which 1-star empty goes back in the box? | random of E1 / E2 | `STRATEGIC_RETURNED_EMPTY` |
| [ ] | 9 | Rulebook: advanced set-up, 3 players | Which bonus upgrade stays out of the pool? | one booster | `DRAFT_3P_REMOVED_UPGRADE` |
| [ ] | 10 | Rulebook: advanced set-up, 3 players | Are the 3 Catanian sites left free after the draft blocked? | yes (blocker colonies) | `DRAFT_3P_BLOCK_FREE_SITES` |
| [ ] | 11 | Rulebook: 3-player rules + no-blockade rules | Are the blocker spaceport's two sites off limits as end nodes? | no | `BLOCKER_SPACEPORT_SITES_BLOCK_END_NODES` |
| [ ] | 12 | Rulebook: trading with other players | Does the opponent's "accept" close the active player's offer? | yes | logic: `shared/src/actions/tradeBuild.ts` |
| [ ] | 13 | Rulebook: building a spaceport next to an opponent's ship | "Must move away if possible": one step, or any legal move? | one step | logic: `shared/src/actions/turn.ts` |
| [ ] | 14 | Encounter cards with "place 1 trade ship" | Does the player choose the spaceport site? | no; first free own site | logic: `shared/src/found/freeTradeShip.ts` |
| [ ] | 15 | Rulebook: reserve-pile draw | VP counted when you draw, or when you roll? | at draw time | logic: `shared/src/actions/production.ts` |
| [ ] | 16 | Encounter cards 24, 25–28, 30 | May a won space jump be declined? | yes | logic: `shared/src/encounters/engine.ts` |
| [ ] | 17 | Encounter cards 31, 32 | Does the player choose which upgrade Wear and Tear removes? | yes | logic: `shared/src/encounters/engine.ts` |
| [ ] | 18 | Encounter card 32 | Galactic Council with no freight pods anywhere: anyone honoured? | nobody | logic: `shared/src/encounters/engine.ts` (`galacticCouncil`) |
| [ ] | 19 | Encounter cards 16, 17, 18 | "Flee?" answered no: fight at once (no booster check)? | yes | data: `shared/src/encounters/cards.ts` |
| [ ] | 20 | — | HANDOFF §5.7: the `[VERIFY]` umbrella | covered by #1–#4 | — |

Items 12–20 are HANDOFF §5.1–§5.7 (§5.2 is #11). There are no other `[VERIFY]` or
"inferred" items in `config.ts` or the layouts beyond #1–#11 (checked with
`grep -rniE 'verify|inferred'`).

---

## 1. Tile star backs (`board.json` `sectors[*].stars`)

- **Look at:** the back of each of the 16 sector tiles (fronts identified via Almanac p.4).
- **Question:** does each tile's back show 1 star or 2 stars?
- **Current value and meaning:** inferred from the beginner picture and the Almanac p.16
  disc legend. 1-star tiles go to the 8 near slots, 2-star tiles to the 7 far slots in the
  strategic and explorer set-ups (one 1-star empty goes back to the box, so 9 × 1★ and
  7 × 2★ are needed). The beginner set-up does not use stars; wild space ignores them.

  | ✓ | Tile | Current | Reading |
  |---|---|---|---|
  | [ ] | S1 (carbon / food / fuel) | 1 | |
  | [ ] | S2 (carbon / ore / goods) | 1 | |
  | [ ] | S3 (fuel / ore / goods) | 1 | |
  | [ ] | S4 (fuel / food / ore) | 1 | |
  | [ ] | S5 (food / carbon / goods) | 1 | |
  | [ ] | S6 (carbon / fuel / goods) | 2 | |
  | [ ] | S7 (goods / food / ore) | 2 | |
  | [ ] | S8 (ore / carbon / goods) | 2 | |
  | [ ] | Green Folk outpost | 1 | |
  | [ ] | Merchants outpost | 1 | |
  | [ ] | Scientists outpost | 2 | |
  | [ ] | Diplomats outpost | 2 | |
  | [ ] | Empty E1 | 1 | |
  | [ ] | Empty E2 | 1 | |
  | [ ] | Empty E3 | 2 | |
  | [ ] | Empty E4 | 2 | |

- **Alternatives:** any tile 1 ↔ 2. The totals must stay 9 × 1★ and 7 × 2★ (with at least
  one 1-star empty), otherwise the strategic set-up throws.
- **Change:** `layouts/board.json` → `sectors.<id>.stars`; then the `_comment` there and
  `TILE_STARS_SOURCE` in `config.ts` (comment only) can drop "inferred".
- **Pinned by:** `shared/test/verifyPins.test.ts` › "#1 board.json sectors[*].stars: tile
  backs per tile (inferred)"; counts also in `shared/test/layout.test.ts` › "has the
  documented grid and 15 slots / 16 tiles"; distribution in
  `shared/test/setupVariants.test.ts` › "fills the 15 slots: 1-star tiles near, 2-star
  tiles far, one 1-star empty returned, all unique".
- **Reading:**

## 2. Beginner starting colony-ship sites (`beginner.json` `shipSide`)

- **Look at:** Rulebook pp.2–3, beginner set-up picture: the colony ship beside each
  colour's spaceport.
- **Question:** which of the spaceport's two sites holds the colony ship, named by the
  planet whose outer edge it sits on?
- **Current value and meaning:** read from a small picture. Spec §16.3 speaks of "three"
  entries; the file has four, one per colour (in a 3-player game the unused colour's
  pieces are blockers and get no ship). Both sites are legal starts, so a mistake only moves
  the ship one intersection.

  | ✓ | Colour | Spaceport (system, between) | Current `shipSide` | Other site would be | Reading |
  |---|---|---|---|---|---|
  | [ ] | yellow | α, `[1,1]`–`[1,0]` | `[1,1]` (fuel) | `[1,0]` (carbon) | |
  | [ ] | red | β, `[3,1]`–`[4,1]` | `[4,1]` (goods) | `[3,1]` (fuel) | |
  | [ ] | blue | δ, `[9,1]`–`[10,1]` | `[9,1]` (goods) | `[10,1]` (ore) | |
  | [ ] | white | γ, `[6,1]`–`[7,1]` | `[7,1]` (carbon) | `[6,1]` (ore) | |

- **Alternatives:** the other hex in that spaceport's `between` pair.
- **Change:** `layouts/beginner.json` → `startingPieces.<colour>.spaceport.shipSide`; when
  all are confirmed set `BEGINNER_SHIP_SIDE_VERIFIED = true` in `config.ts`.
- **Pinned by:** `shared/test/verifyPins.test.ts` › "#2 beginner.json
  startingPieces[colour].spaceport.shipSide (read from a small picture)" (also pins
  `BEGINNER_SHIP_SIDE_VERIFIED = false`); placement in `shared/test/beginner.test.ts` ›
  "sets up a 4-player game" / "sets up a 3-player game with the 4th colour as blockers".
- **Reading:**

## 3. Shake bands on encounter cards 12–15 (`ENCOUNTER_SHAKE_BANDS`)

- **Look at:** encounter cards 12 and 13 (pirates' 1-for-2 trade) and 14 and 15 (pirate
  robs all opponents): the band labels under "shake your mothership".
- **Question:** which ball totals (black = 0, so 1–5) count as the low, middle and high
  result?
- **Current value and meaning:** low = 1–2, mid = 3, high = 4–5. With the five balls the
  totals come up 1: 10 %, 2: 20 %, 3: 30 %, 4: 20 %, 5: 20 %, so low 30 %, mid 30 %,
  high 40 %. Cards 12/13: low = the 2 cards are confiscated and −1 fame, mid = −1 fame,
  high = safe. Cards 14/15: low = cheated, −1 fame; mid = take 1 random card from each
  opponent but −1 fame; high = take 1 from each.
- **Alternatives:** any partition of 1–5 into three bands (e.g. low 1–2 / mid 3–4 /
  high 5). If the card instead prints ball colours, list the totals they add up to.
- **Change:** `shared/src/config.ts` → `ENCOUNTER_SHAKE_BANDS` (every total 1–5 in
  exactly one band).
- **Pinned by:** `shared/test/verifyPins.test.ts` › "#3 ENCOUNTER_SHAKE_BANDS (cards
  12–15): low 1–2, mid 3, high 4–5"; `shared/test/encounterTable.test.ts` › "[VERIFY]
  config matches the spec defaults" › "shake bands 12–15: low = 1–2, mid = 3, high = 4–5
  (every reachable total is covered once)"; the card 12–15 rows of the table test.
- **Reading:**

## 4. Travelers donation split, cards 28–30 (`TRAVELERS_DONATION_BRANCHES`)

- **Look at:** encounter cards 28, 29, 30 (travelers ask for a donation of 0–3).
- **Question:** do a donation of 1 and a donation of 2 give the same result on each card,
  and if not, what does each give?
- **Current value and meaning:** 28: 0 = remove 1 upgrade and −1 fame, 1 = +1 fame,
  2 = +1 fame, 3 = space jump. 29: 0 = nothing, 1–2 = +1 fame, 3 = free trade ship.
  30: 0 = −1 fame, 1–2 = +1 fame, 3 = space jump +1 fame. So paying 2 is never better
  than paying 1.
- **Alternatives:** map 1 or 2 to another branch name (`nothing`, `loseFame`,
  `gainFame`, `removeUpgradeLoseFame`, `spaceJump`, `spaceJumpAndFame`,
  `freeTradeShip`); a new outcome needs a new entry in `TRAVELERS_OUTCOMES`
  (`shared/src/encounters/cards.ts`).
- **Change:** `shared/src/config.ts` → `TRAVELERS_DONATION_BRANCHES[28|29|30][1|2]`.
- **Pinned by:** `shared/test/verifyPins.test.ts` › "#4 TRAVELERS_DONATION_BRANCHES
  (cards 28–30): 1 and 2 give the same branch"; `shared/test/encounterTable.test.ts` ›
  "travelers 28–30: 0 / 1 / 2 / 3 map to the spec outcomes";
  `shared/test/encounterCards.test.ts` › "cards 28–30 take their donation split from
  TRAVELERS_DONATION_BRANCHES".
- **Reading:**

## 5. Does discovery end the move? (`DISCOVERY_ENDS_MOVE`)

- **Look at:** Rulebook, explorer / wild space variant: what happens when a ship reaches
  a face-down sector.
- **Question:** after flipping a face-down sector, may the ship keep moving with its
  remaining speed?
- **Current value and meaning:** `false`. The ship finishes the path it was sent on and
  keeps any steps left (spec §9.3 "movement may continue", §3.2 "works the same").
- **Alternatives:** `true`: the ship completes its validated path but forfeits the rest
  of its budget, like a space jump.
- **Change:** `shared/src/config.ts` → `DISCOVERY_ENDS_MOVE`.
- **Pinned by:** `shared/test/verifyPins.test.ts` › "#5 DISCOVERY_ENDS_MOVE = false";
  `shared/test/discovery.test.ts` › "pins DISCOVERY_ENDS_MOVE = false: the discovering
  ship keeps its remaining budget".
- **Reading:**

## 6. Wild space dealing order (`WILD_SPACE_SLOT_ORDER`)

- **Look at:** Rulebook / Almanac, wild space set-up ("dealt from the nearest slot to the
  farthest"); any numbered picture of the slots.
- **Question:** in which order are the 15 slots filled?
- **Current value and meaning:** inferred: the 8 near slots, then the 7 far slots, each by
  distance from the Catanian edge, ties top to bottom:
  `N4 N1 N6 N5 N2 N7 N3 N8 F5 F1 F3 F6 F2 F4 F7`. The tiles are shuffled anyway, so the
  order only matters for replaying a seed and for which tile is left over.
- **Alternatives:** any permutation of the 15 slot ids (e.g. row by row, or the
  rulebook's numbering if it has one). Slot ids are in `layouts/board.json`
  `sectorSlots`.
- **Change:** `shared/src/config.ts` → `WILD_SPACE_SLOT_ORDER` (all 15 ids, once each).
- **Pinned by:** `shared/test/verifyPins.test.ts` › "#6 WILD_SPACE_SLOT_ORDER: near slots
  then far, nearest first"; `shared/test/setupVariants.test.ts` › "pins
  WILD_SPACE_SLOT_ORDER: all 15 slots, near before far, nearest first within a region"
  (that test also checks near-before-far and distance order; drop those checks if the
  rulebook says otherwise).
- **Reading:**

## 7. Who orients a system tile? (`VARIABLE_SETUP_START_LOBE`)

- **Look at:** Rulebook, strategic set-up (placing tiles) and explorer / wild space
  (discovering a sector).
- **Question:** may the player who places (strategic) or discovers (explorer, wild space)
  a planetary system tile choose its rotation?
- **Current value and meaning:** `0`. Nobody chooses: every system tile is turned the
  same way (planets assigned clockwise from the slot's first lobe), so the seed alone
  fixes the board and a discovery needs no input. Rotation decides which planet each
  colony site and approach route touches.
- **Alternatives:** `1` or `2` (another fixed rotation, cosmetic only). If the rulebook
  says the **discoverer chooses**, a config value is not enough: add a pending step
  `discoverOrient {sectorId, startLobe}` (HANDOFF §8 item 5) after a discovery, before
  discs are placed. If the **strategic placer chooses**, that is a set-up step for the
  board-building player and also needs new code.
- **Change:** `shared/src/config.ts` → `VARIABLE_SETUP_START_LOBE`, or the new action
  above (`shared/src/flight/discover.ts`, `shared/src/setup/variants.ts`).
- **Pinned by:** `shared/test/verifyPins.test.ts` › "#7 VARIABLE_SETUP_START_LOBE = 0 (no
  player orients a tile)"; `shared/test/setupVariants.test.ts` › "orients every placed
  system from the configured start lobe".
- **Reading:**

## 8. Which empty tile goes back? (`STRATEGIC_RETURNED_EMPTY`)

- **Look at:** Rulebook, strategic set-up ("return one empty 1-star sector").
- **Question:** does the rulebook name a specific empty tile, or is it any one?
- **Current value and meaning:** `'random'`, drawn through the seeded rng. E1 and E2 are
  identical, so this is cosmetic.
- **Alternatives:** `'E1'` or `'E2'` (must be a 1-star empty).
- **Change:** `shared/src/config.ts` → `STRATEGIC_RETURNED_EMPTY`.
- **Pinned by:** `shared/test/verifyPins.test.ts` › "#8 STRATEGIC_RETURNED_EMPTY =
  'random'"; `shared/test/setupVariants.test.ts` › "fills the 15 slots: …" (accepts any
  of the three values).
- **Reading:**

## 9. 3-player draft: the upgrade that stays out (`DRAFT_3P_REMOVED_UPGRADE`)

- **Look at:** Rulebook, advanced set-up, 3-player note ("one upgrade stays out").
- **Question:** which of {booster, booster, cannon, freight pod} is removed?
- **Current value and meaning:** `'booster'`, leaving booster / cannon / freight pod so
  the three bonuses differ. The removed one goes back to the tray.
- **Alternatives:** `'cannon'`, `'freightPod'`, or `'random'` (drawn through the rng).
- **Change:** `shared/src/config.ts` → `DRAFT_3P_REMOVED_UPGRADE`.
- **Pinned by:** `shared/test/verifyPins.test.ts` › "#9 DRAFT_3P_REMOVED_UPGRADE =
  'booster'"; `shared/test/draft.test.ts` › "DRAFT_3P_REMOVED_UPGRADE: which upgrade stays
  out of a 3-player pool (default: one booster)".
- **Reading:**

## 10. 3-player draft: block the free sites? (`DRAFT_3P_BLOCK_FREE_SITES`)

- **Look at:** Rulebook, advanced set-up with 3 players; compare the beginner 3-player
  rule (4th colour placed as blockers).
- **Question:** after a 3-player draft, are the three Catanian colony sites nobody picked
  filled with the unused colour's colonies?
- **Current value and meaning:** `true`. Blocker colonies go there, so nobody can found
  on them later; no blocker spaceport exists in a drafted game.
- **Alternatives:** `false`: the three sites stay open for founding later.
- **Change:** `shared/src/config.ts` → `DRAFT_3P_BLOCK_FREE_SITES`.
- **Pinned by:** `shared/test/verifyPins.test.ts` › "#10 DRAFT_3P_BLOCK_FREE_SITES =
  true"; `shared/test/draft.test.ts` › "3 players: the three free Catanian sites are
  filled by the unused colour (DRAFT_3P_BLOCK_FREE_SITES) — both values".
- **Reading:**

## 11. Blocker spaceport sites (`BLOCKER_SPACEPORT_SITES_BLOCK_END_NODES`, HANDOFF §5.2)

- **Look at:** Rulebook, 3-player rules (blocker pieces) and the no-blockade rules ("may
  not end on another player's spaceport site").
- **Question:** in a 3-player game, may a ship end its move on one of the two sites
  beside the unused colour's spaceport?
- **Current value and meaning:** `false`. The blockers only occupy the intersections they
  stand on; the two sites beside the blocker spaceport are ordinary end nodes.
- **Alternatives:** `true`: those two sites are off limits for every ship (the phase-2
  reading).
- **Change:** `shared/src/config.ts` → `BLOCKER_SPACEPORT_SITES_BLOCK_END_NODES`.
- **Pinned by:** `shared/test/verifyPins.test.ts` › "#11
  BLOCKER_SPACEPORT_SITES_BLOCK_END_NODES = false (HANDOFF §5.2)";
  `shared/test/flight.test.ts` › "3-player blocker spaceport sites:
  BLOCKER_SPACEPORT_SITES_BLOCK_END_NODES decides (default false: they 'only block the
  sites')" (tests both values).
- **Reading:**

## 12. Trade finalisation (HANDOFF §5.1)

- **Look at:** Rulebook, trading with other players.
- **Question:** when the active player makes an offer and an opponent accepts, is the
  trade done, or must the active player confirm again?
- **Current value and meaning:** done on the opponent's accept (the active player already
  consented by proposing). An opponent's offer to the active player needs the active
  player's accept.
- **Alternatives:** require a final confirmation from the active player after any
  accept (spec §7.1 read literally).
- **Change:** logic in `shared/src/actions/tradeBuild.ts` (`handleRespondTrade` / `executeTrade`) and
  the trade panel in `client/`; not a config value.
- **Pinned by:** `shared/test/trade.test.ts` › "player trades: responses and
  finalisation" › "the opponent accepting the active player's offer finalises it (active
  already consented)" and "an opponent offer is finalised only when the active player
  accepts".
- **Reading:**

## 13. "Move away from a new spaceport site if possible" (HANDOFF §5.3)

- **Look at:** Rulebook, building a spaceport when an opponent's ship stands on one of
  its sites.
- **Question:** "if possible" — is that one step to a legal intersection, or any legal
  move within the ship's speed?
- **Current value and meaning:** one step. If none of the ship's three neighbours is a
  legal end node (or speed is 0, or the ship is pinned), the ship may stay.
- **Alternatives:** any legal end node reachable within the ship's speed (use
  `reachablePaths` from `shared/src/flight/reach.ts`).
- **Change:** logic in `shared/src/actions/turn.ts` (`canMove` in the endTurn gate).
- **Pinned by:** `shared/test/verifyPins.test.ts` › "#13 (§5.3) a ship on a new opponent
  spaceport site may stay when no ONE-step move is legal" (new);
  `shared/test/flight.test.ts` › "a ship flagged on an opponent's new spaceport site must
  leave if it can move"; `shared/test/build.test.ts` › "flags an opponent's ship sitting
  on a new spaceport site as must-leave".
- **Reading:**

## 14. Free trade ship placement (HANDOFF §5.4)

- **Look at:** encounter cards with "place 1 trade ship adjacent to 1 of your spaceports"
  (5, 6, 9, 18, 19, 29) and the rulebook on trade-ship markers.
- **Question:** does the player choose which spaceport site gets the ship?
- **Current value and meaning:** no; the first free site of the player's own spaceports
  (spaceports in settlement order, sites in graph order). Both sites are legal.
- **Alternatives:** the player chooses (a pending pick like the space-jump target).
- **Change:** logic in `shared/src/found/freeTradeShip.ts` (`freeTradeShipSite`) plus a
  new pick in `shared/src/encounters/engine.ts` and the client.
- **Pinned by:** `shared/test/verifyPins.test.ts` › "#14 (§5.4) a free trade ship goes on
  the FIRST free own spaceport site; the player does not choose" (new);
  `shared/test/found.test.ts` › "free trade ship (§10)" › "is placed on a free own
  spaceport site when transport, piece and site are available".
- **Reading:**

## 15. Reserve draw timing (HANDOFF §5.5)

- **Look at:** Rulebook, production phase, drawing from the reserve pile by VP.
- **Question:** is the player's VP counted when they draw, or as it stood when they
  rolled?
- **Current value and meaning:** at draw time (`takeReserveDraw` reads current VP). A
  player whose VP changes between the roll and the draw draws by the new total.
- **Alternatives:** VP at roll time (store it on `turn` at `rollDice`).
- **Change:** logic in `shared/src/actions/production.ts` (`takeReserveDraw`).
- **Pinned by:** `shared/test/verifyPins.test.ts` › "#15 (§5.5) the reserve draw uses VP
  at DRAW time, not at roll time" (new); `shared/test/production.test.ts` ›
  "takeReserveDraw" › "draws by the VP table: …".
- **Reading:**

## 16. A won space jump may be declined (HANDOFF §5.6)

- **Look at:** encounter cards 24, 25, 26, 27, 28, 30 ("space jump").
- **Question:** is the jump optional?
- **Current value and meaning:** optional (`encounterPick {decline: true}`); the ship then
  moves normally.
- **Alternatives:** compulsory (remove the `decline` path).
- **Change:** logic in `shared/src/encounters/engine.ts` (space-jump pick) and the
  encounter modal in `client/`.
- **Pinned by:** `shared/test/encounterTable.test.ts` › "card 24: yes, win — the jump may
  be declined, +1 fame"; `shared/test/encounter.test.ts` › "card 28 offer 3: pick a ship
  and a target validated like a jump; the jump explores and ends that ship's move".
- **Reading:**

## 17. Wear and Tear: who picks the upgrade (HANDOFF §5.6)

- **Look at:** encounter cards 31 and 32.
- **Question:** does each affected player choose which upgrade to remove?
- **Current value and meaning:** yes; each player over the threshold is asked in turn
  order from the active player (same as "remove any 1 upgrade" elsewhere).
- **Alternatives:** a fixed or random upgrade, without asking.
- **Change:** logic in `shared/src/encounters/engine.ts` (`wearAndTear` queues a
  `removeUpgrade` pick per player).
- **Pinned by:** `shared/test/encounterTable.test.ts` › "full sequence: p1 (7) and p3 (7)
  remove 1, p2 (6) is spared; the council honours the single leader; card 5 is
  redrawn".
- **Reading:**

## 18. Galactic Council with no freight pods (HANDOFF §5.6)

- **Look at:** encounter card 32, the Galactic Council line.
- **Question:** if nobody has a freight pod, does everyone (tied at 0) get +1 fame, or
  nobody?
- **Current value and meaning:** nobody (`most >= 1` required).
- **Alternatives:** everyone tied at 0 gets +1 fame.
- **Change:** logic in `shared/src/encounters/engine.ts` (`galacticCouncil` case); not a
  config value.
- **Pinned by:** `shared/test/encounterTable.test.ts` › "with no freight pods anywhere
  nobody is honoured (documented reading of \"most freight pods\")".
- **Reading:**

## 19. "Flee?" no means fight at once (HANDOFF §5.6)

- **Look at:** encounter cards 16, 17, 18.
- **Question:** answering "no" to "Flee?" — does the fight start straight away, with no
  booster comparison?
- **Current value and meaning:** yes; only "yes" compares boosters (escape or caught →
  fight).
- **Alternatives:** none expected; if the card reads differently, change the card data.
- **Change:** data in `shared/src/encounters/cards.ts` (the `no` branch of 16–18).
- **Pinned by:** `shared/test/encounter.test.ts` › "flee (card 16): boosters ≥ R's →
  escaped with no shake; otherwise caught and the fight follows" (card 17 "stood");
  `shared/test/encounterTable.test.ts` › "card 16: fight, win — +1 upgrade of choice, +1
  fame" and the other `answer: false` rows of 16–18.
- **Reading:**

## 20. The `[VERIFY]` umbrella (HANDOFF §5.7)

- **Look at:** nothing extra.
- **Question:** once #1–#4 are read, can the `[VERIFY]` tags on those items be removed?
- **Current value and meaning:** §5.7 lists the shake bands (#3), travelers split (#4),
  tile stars (#1) and beginner `shipSide` (#2) as `[VERIFY]` and pinned.
- **Alternatives:** —
- **Change:** comments only in `shared/src/config.ts` and the `_comment` in
  `layouts/board.json`; HANDOFF §5 is updated by the project manager.
- **Pinned by:** the pins of #1–#4.
- **Reading:**
