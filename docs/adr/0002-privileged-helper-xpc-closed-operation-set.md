# 0002. Privileged helper exposes a closed operation set over XPC

Status: Accepted
Date: 2026-10-13

## Context
Some tasks need root: system caches under `/Library/Caches`, launch daemons,
periodic maintenance scripts, DNS flush, Spotlight reindex of `/`, thinning
local snapshots, deleting other users' files. The main app is unprivileged
(ADR 0001). A root helper is the largest attack surface in the product: a bug
there is a local privilege escalation for any process that can talk to it.

## Decision
Install one root daemon via `SMAppService.daemon`, embedded in the app bundle
(`Contents/Library/LaunchDaemons/com.example.maccleaner.helper.plist`). It is
an XPC server whose protocol is a **closed, enumerated set of operations**,
each a `Codable` request type with typed parameters and server-side path
validation against `ProtectedPaths` and an allow-list of roots.

The helper **never** accepts a shell command, script body, format string,
arbitrary executable path, or an unconstrained "delete this path" request.
New capabilities are added as new typed operations, reviewed as such.

Both sides verify the peer: the app checks the helper's code-signing
requirement, the helper checks the connecting process's designated requirement
(same team ID, our bundle identifier) via `SecCodeCheckValidity` on the
audit token before servicing any request. Every operation is logged.

## Consequences
- Adding a root feature costs a new op, tests, and a review; this friction is
  intentional.
- Operations are deterministic and dry-run-able, so the CLI and tests can
  exercise their validation logic without root.
- The helper must stay small: Foundation + `CleanerCore` only, no UI frameworks.
- Version skew between app and helper is handled by an explicit protocol
  version op (`ping` returns it); mismatches trigger reinstall, never fallback
  to a looser contract.
