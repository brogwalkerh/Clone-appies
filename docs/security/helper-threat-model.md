# Privileged helper — threat model

Scope: `com.example.maccleaner.helper`, the root daemon installed via
`SMAppService.daemon` (ADR 0002, CLAUDE.md rule 5). Code: `Packages/HelperProtocol`
(contract + validation, Linux-tested), `PrivilegedHelper/Sources` (daemon),
`App/Services/HelperClient.swift` (client).

## What the helper can do
Exactly the eleven `HelperOperation` cases, each mapped by `HelperCommandPlan`
to a fixed argv for an allow-listed absolute executable (`tmutil`, `purge`,
`dscacheutil`, `killall`, `periodic`, `mdutil`, `lsregister`, `launchctl`,
`sqlite3`, `rm`). Caller input reaches argv in only five places, each after
validation: a Spotlight volume, a snapshot byte count, a cache path, a launchd
label, and the caller's home (for Mail's `Envelope Index`).

## What it cannot do
- Run a shell, script, or arbitrary executable: there is no such operation, no
  `-c`, no `env`, and `CommandExecutor` refuses any executable outside
  `HelperCommandPlan.allowedExecutables` even if a future plan named one.
- Delete an arbitrary path: `rm` is reachable only through `removeSystemCache`,
  whose path must be standardized, absolute, free of `..`/`.`/`//`, strictly
  below `/Library/Caches/` or `/private/var/folders/`, and not a symlink.
- Touch Apple launchd jobs: labels starting with `com.apple.` (any case) are
  refused; labels are restricted to `[A-Za-z0-9_.-]`, so no `/`, space or
  shell metacharacters.
- Read or write files on the caller's behalf, open sockets, or load code.

## Validation boundary
`HelperRequestValidator` is pure (no I/O except an injected `isSymlink`) and
runs on **both** sides: the app validates before any XPC traffic, the helper
re-validates every decoded request with a real `FileManager` symlink probe and
trusts nothing the client did. The wire is JSON; an unknown operation fails to
decode and is refused. Argument strings are never concatenated into a command
line; they are single argv elements, and `rm` gets `--` before the path.

## Code-signing checks (both directions)
- Helper → client: in `listener(_:shouldAcceptNewConnection:)` the peer's
  audit token (`kSecGuestAttributeAudit`) is resolved with
  `SecCodeCopyGuestWithAttributes` and checked with `SecCodeCheckValidity`
  against `HelperConstants.clientRequirement` (Apple anchor, our bundle id, our
  Team ID). Failure rejects the connection before any object is exported;
  missing audit token fails closed. `setCodeSigningRequirement` is also set so
  the kernel-backed check repeats on every message.
- Client → helper: `NSXPCConnection.setCodeSigningRequirement(helperRequirement)`
  pins the app to our signed helper binary.
- `TEAMID_PLACEHOLDER` matches no certificate, so unsigned dev builds cannot
  talk to each other by accident; `release.yml` substitutes the real Team ID.

## Why there is no generic command op
A root process that accepts a command string is a local privilege escalation
for any process able to reach the Mach service, and code-signing checks only
narrow *who* asks, not *what* they can be tricked into asking (a compromised
or injected main app is in scope). A closed, typed set makes every capability
reviewable, deterministic, dry-run-able and testable without root.

## Residual risks
- `removeSystemCache` under `/private/var/folders` can delete other users'
  per-user cache/temp data (that is its purpose); the symlink check covers
  only the final component, so a hostile symlinked *parent* directory created
  by another local user could redirect `rm -rf`. Mitigation planned: resolve
  the path with `realpath` in the helper and re-check the root (M3 follow-up).
- The audit token is read via KVC on `NSXPCConnection`; if Apple removes it the
  helper stops accepting connections (safe, but a functional regression).
- `periodic`, `lsregister` and `tmutil` are system tools with their own
  behaviour; we only choose fixed arguments.
- Operations run serially per helper process but not across a reinstall.

## Test coverage enforcing the invariants (`Packages/HelperProtocol`, 42 tests)
- Validator: home, cache path (roots, `..`, `.`, `//`, trailing slash, NUL,
  symlink), volume, label (Apple prefix, metacharacters), byte count.
- Plans: every operation has a plan; every executable is absolute and
  allow-listed; no shell, no `-c`; exact argv per operation; `rm -rf --`;
  `speedUpMail` uses `skipIfMissing` instead of globbing.
- Wire: JSON round-trips for every operation and response; unknown operation
  and garbage payloads fail to decode; requirement strings name the right ids.
