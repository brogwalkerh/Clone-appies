# 0004. Foundation-only core packages verified on Linux CI

Status: Accepted
Date: 2026-10-13

## Context
The scan engine, file walking, hashing, rule evaluation, removal manifests, the
Cleanup scanners, the Space Lens size tree/layout and the CLI are pure logic
over a filesystem abstraction. Development happens partly in Linux containers
without Xcode; GitHub's macOS 27 runners are scarce, slow and expensive; and
the macOS runner image for the newest OS tends to lag its release. We want
fast, cheap, parallel test feedback on every push and a design that keeps UI
concerns out of the engine.

## Decision
`CleanerCore`, `CleanupModule`, `SpaceLens` and `CLI` are **Foundation-only**
SwiftPM packages (`swift-tools-version: 6.0`, strict concurrency). They must
`swift build && swift test` on Ubuntu 24.04 with the `swift:6.2` toolchain and
on macOS. CI runs them in a Linux matrix on every push and PR; the macOS job
builds the app and runs `AppTests` only.

Platform code (AppKit, SwiftUI, Vision, ServiceManagement, Sparkle) lives in
`App/`, `MenuAgent/`, `PrivilegedHelper/`, `DesignSystem` and `UIKitBridge`.
Shared code may touch AppKit only behind `#if canImport(AppKit)` and only when
there is no Foundation alternative.

## Consequences
- Scanners are testable against fixture trees (`Scripts/generate-fixtures.sh`)
  on any machine; the `FileSystem` protocol is the seam.
- Some Foundation behaviors differ on Linux (`.isPackage` is always false,
  `trashItem` is unavailable, `CGPoint` comes from Foundation); contracts
  document these and tests must not depend on macOS-only semantics.
- macOS-specific bugs can only be caught by the macOS CI job or a real Mac;
  PRs touching platform code should say which was used.
- Foundation-only is enforced by review and by the Linux build itself: an
  accidental `import AppKit` in Core fails CI immediately.
