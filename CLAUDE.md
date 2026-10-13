# Mac Cleaner (working title) — guide for AI and human contributors

A native, directly-distributed macOS 27 cleaner app (CleanMyMac-style): Cleanup,
Protection, Performance, Applications, My Clutter, Space Lens, menu bar agent, CLI.
Swift 6.2, SwiftUI, Apple Silicon only. Status: pre-alpha, milestone M0.

## Where things are decided
- `PLAN.md` — scope, platform facts, architecture (§5), permissions (§6), roadmap.
- `docs/CONTRACTS.md` — the shared Swift API every package codes against. Change a
  signature there *and* every dependent in the same change, or do not change it.
- `docs/adr/` — Architecture Decision Records. Add one before reversing a decision.

## Directory layout
```
App/                  SwiftUI app target (main window, settings, onboarding, Intents)
MenuAgent/            Login-item agent: menu bar extra, Protection Monitor
PrivilegedHelper/     Root daemon (SMAppService), XPC server, closed op set
CLI/                  `maccleaner` command-line tool (SwiftPM package)
Packages/Core/        CleanerCore: scan engine, FileSystem, Remover, models
Packages/Modules/Cleanup/  CleanupModule: scanners + cleanup-rules.json
Packages/Modules/Clutter/  ClutterModule: large/old, duplicates, similar images, downloads
Packages/Modules/Applications/  ApplicationsModule: inventory, leftovers, orphans, updater
Packages/SpaceLens/   Size tree + circle packing layout
Packages/DesignSystem/  Colors, glass components, shared views (macOS only)
Packages/UIKitBridge/ AppKit shims (macOS only)
Scripts/              make-dmg.sh, notarize.sh, generate-fixtures.sh
.github/workflows/    ci.yml, release.yml
project.yml           XcodeGen spec; App.xcodeproj is generated, never committed
```

## Hard rules
1. **Foundation-only packages.** `CleanerCore`, `CleanupModule`, `ClutterModule`,
   `ApplicationsModule`, `SpaceLens` and `CLI` import Foundation only. They must `swift build && swift test` on Linux
   (Ubuntu 24.04) and on macOS. No AppKit/SwiftUI/Vision/ServiceManagement there.
   Anything platform-specific lives in `App/`, `MenuAgent/`, `DesignSystem`,
   `UIKitBridge`, guarded with `#if canImport(AppKit)` only when unavoidable.
2. **Swift 6 strict concurrency.** `swift-tools-version: 6.0`,
   `-strict-concurrency=complete`. Public types are `Sendable`; models are
   `Codable + Hashable`. UI on `@MainActor`; scanners are actors or `Sendable` structs.
3. **Trash first.** Deletion always goes through `Remover` with `.trash`.
   Permanent deletion only when the user explicitly opts out of Trash or when the
   Trash itself is being emptied. Every removal writes a `RemovalManifest` for undo.
4. **Protected paths.** No scanner may ever yield a path under `ProtectedPaths`
   (`/System`, `/usr`, `/bin`, `/sbin`, `/private/var/db`, `/Library/Apple`, Time
   Machine mounts, our own containers). `GuardedRemover` enforces this; tests fuzz it.
5. **Privileged helper is a closed set of operations.** Each XPC op is a typed,
   path-validated request. **Never add a generic "run shell command" op**, a
   generic "delete arbitrary path" op, or anything taking a format string or
   script body. Both sides verify code-signing requirements.
6. Do not hand-write `App.xcodeproj`; edit `project.yml` and regenerate.
7. Do not commit signing material (`*.p12`, `*.p8`, Sparkle private keys).

## Building and testing
Linux-testable packages (also work on macOS):
```sh
cd Packages/Core && swift build && swift test
cd Packages/Modules/Cleanup && swift build && swift test
cd Packages/Modules/Clutter && swift build && swift test
cd Packages/Modules/Applications && swift build && swift test
cd Packages/SpaceLens && swift build && swift test
cd CLI && swift build && swift test
```
macOS app (Xcode 26.6+ on Apple Silicon; minimum deployment macOS 26, see docs/adr/0005):
```sh
brew install xcodegen
xcodegen generate
xcodebuild -scheme App -destination 'platform=macOS,arch=arm64' build
```
macOS-only targets (`App`, `MenuAgent`, `PrivilegedHelper`, `DesignSystem`,
`UIKitBridge`) are **verified by CI on the macOS runner**, not on Linux dev
containers. If you cannot run Xcode locally, say so in the PR and let CI judge.

## Commit messages
Imperative, present tense, ≤ 72-char subject, scope prefix in parentheses:
`core: add FileWalker symlink-loop guard`, `ci: pin macOS 27 runner image`,
`cleanup: add Ollama models scanner`. Body explains *why*, references ADRs or
PLAN.md sections when relevant. One logical change per commit.
