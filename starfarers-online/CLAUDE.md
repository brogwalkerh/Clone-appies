# Starfarers Online — project instructions for Claude Code

Read `starfarers-clone-spec.md` in full before writing code. It is the source of truth for rules, data, and architecture. `layouts/board.json` and `layouts/beginner.json` are the board data; load them, do not retype them.

## Working rules
- TypeScript everywhere. Monorepo: `shared/` (pure engine, no I/O), `server/` (Node + Socket.IO), `client/` (React + Vite, SVG board).
- The engine is deterministic: all randomness comes from an injected RNG seeded per game. Never call `Math.random` in `shared/`.
- Follow the spec's phase order (§15). Finish phase 1 with passing tests before phase 2.
- Every rule in the spec gets a test. Encounter cards are data (§10) with a table-driven test per branch.
- Anything the spec marks as inferred or **[VERIFY]** goes in a config file with a comment, never hard-coded in logic.
- No official Catan art, names, or logos in the UI. Working title: Starfarers Online.
- Keep replies to the user short. State what was built, what passes, and what is next.

## First task
Set up the monorepo (pnpm workspaces, Vitest), then implement phase 1: types, board graph builder from `layouts/*.json`, beginner placement, production (incl. the 7), trade with supply, build, VP, win. Add the graph sanity tests from §15. Stop and report when `pnpm test` is green.
