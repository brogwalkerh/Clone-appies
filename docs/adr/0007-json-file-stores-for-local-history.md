# 0007 — Local history and settings records in JSON files, not SwiftData

Status: accepted (2026-10-29)

## Context
PLAN.md §5 planned SwiftData (or GRDB) for scan history, My Activity stats,
schedules and notifications, behind a `Store` protocol. M5 is where that data
first exists. Three facts weigh against SwiftData now:
- The logic that reads and writes this data (activity stats, Assistant rules,
  schedule evaluation, action sets) belongs in a Foundation-only package so it
  runs on Linux CI (ADR 0004). SwiftData is Apple-only; GRDB adds a C
  dependency to every Linux job.
- The volumes are small: a few thousand activity events per year, under 50
  inbox messages, a handful of schedules and action sets.
- Two processes touch it: the app and the MenuAgent (scheduled scans post
  inbox messages while the main window is closed).

## Decision
- `SmartCareModule` owns the stores. Each is an actor over one file in
  `~/Library/Application Support/com.example.maccleaner/`.
- The activity log is **JSON Lines**, append-only (one `ActivityEvent` per
  line). Undecodable lines are skipped, so a torn write loses one event, not
  the log. It is compacted to the newest `maxEvents` on open.
- Small records (inbox, schedules, schedule run times, action sets) are one
  JSON document each, written atomically (`Data.write(options: .atomic)`).
  Every mutation re-reads the file first, so the app and the agent see each
  other's writes; the remaining race is last-writer-wins on a sub-second
  window, acceptable for these records.
- The `ActivityStore` protocol stays, so a database can replace the JSON log
  later without touching callers.
- Settings stay in `UserDefaults` (`@AppStorage`), secrets in Keychain (§5).

## Consequences
- Stats are computed in memory from the event list; fine up to tens of
  thousands of events. Revisit (new ADR) if history must be kept for years.
- No schema migrations: new fields are optional, and decoding tolerates
  missing keys.
- Tests cover the stores against real temp files on Linux.
