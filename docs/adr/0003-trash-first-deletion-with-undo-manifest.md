# 0003. Trash-first deletion with an undo manifest

Status: Accepted
Date: 2026-10-13

## Context
A cleaner's single worst failure mode is deleting something the user wanted.
Scanners are heuristic; the rules table will be wrong sometimes; users click
"Run" on a summary without reading every row. CleanMyMac mitigates this by
moving to Trash and offering review; we must do at least as well.

## Decision
All deletion goes through the `Remover` protocol (`docs/CONTRACTS.md`) with
`RemovalMode.trash` as the default. `TrashRemover` uses
`FileManager.trashItem` on macOS and the XDG trash directory on Linux (for test
parity). `RemovalMode.permanent` is used only when the user has explicitly
enabled "skip Trash" in Settings, or when the thing being emptied **is** the
Trash. Every removal run produces a `RemovalManifest` (what was removed, where
it was trashed to, success per item) persisted to disk before the UI reports
completion; "Undo last cleanup" replays it via `Remover.undo`.

`GuardedRemover` wraps every remover and refuses any path under
`ProtectedPaths`. The ScanCoordinator additionally drops protected findings so
they never reach the UI.

## Consequences
- Reclaimed space is not freed until the user empties Trash; the UI must say
  so and offer the empty-Trash action. This matches user expectations.
- Trash on a different volume than the file (external disks) may fall back to
  that volume's `.Trashes`; the manifest records the real destination.
- Permanent deletion paths get the heaviest tests: a "never deletes outside
  Trash unless explicitly permanent" assertion and a protected-path fuzz test.
- Root-owned deletions via the helper (ADR 0002) follow the same rule: the
  helper trashes into the admin's Trash or a staged quarantine directory and
  reports the destination so the manifest stays complete.
