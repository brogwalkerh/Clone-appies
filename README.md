# Mac Cleaner (working title)

A native, directly-distributed macOS 27 utility that finds and removes junk
(caches, logs, Xcode and AI-tool leftovers, broken downloads, Trash), uninstalls
apps with their leftovers, surfaces large/old/duplicate files, runs maintenance
tasks, and shows disk usage as an interactive Space Lens bubble map. Built with
Swift 6.2 and SwiftUI for Apple Silicon Macs, with a menu bar agent, a
`maccleaner` command-line tool, and App Intents so Siri and Shortcuts can drive
it. Feature parity with CleanMyMac 5.7.1 is the target; the name, artwork and
copy are our own.

**Status:** pre-alpha, milestone **M0 (Foundations)**. Nothing here is usable
yet; see the roadmap in [PLAN.md](PLAN.md) §7.

## Documents
- [PLAN.md](PLAN.md) — scope, platform facts, feature inventory, architecture, roadmap.
- [docs/CONTRACTS.md](docs/CONTRACTS.md) — shared Swift interfaces every package codes against.
- [docs/adr/](docs/adr/) — Architecture Decision Records.
- [CLAUDE.md](CLAUDE.md) — contributor guide and hard rules (trash-first, protected paths, helper op set).

## Building

### Foundation-only packages (Linux or macOS)
These build and test with any Swift 6.2 toolchain, including on Ubuntu 24.04
(`docker run --rm -v "$PWD":/src -w /src swift:6.2-noble ...`):

```sh
cd Packages/Core             && swift build && swift test
cd Packages/Modules/Cleanup  && swift build && swift test
cd Packages/SpaceLens        && swift build && swift test
cd CLI                       && swift build && swift test
```

### macOS app (macOS 27, Xcode 27, Apple Silicon)
The Xcode project is generated from `project.yml` and is not committed.

```sh
brew install xcodegen
xcodegen generate
open App.xcodeproj
```

Or from the command line:

```sh
xcodebuild -scheme App -destination 'platform=macOS,arch=arm64' build
xcodebuild test -scheme App -destination 'platform=macOS,arch=arm64' -only-testing AppTests
```

Release builds are signed, notarized and packaged by
[`.github/workflows/release.yml`](.github/workflows/release.yml) using
`Scripts/make-dmg.sh` and `Scripts/notarize.sh`. `Scripts/generate-fixtures.sh`
creates a fake home directory full of realistic junk for scanner tests.

## License
GNU General Public License v3.0 — see [LICENSE](LICENSE).
