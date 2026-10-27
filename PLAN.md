# Mac Cleaner for macOS 27 — Project Plan

A feature-complete, native clone of CleanMyMac (as of 5.7.1, Oct 2026) built for
macOS 27 "Golden Gate" with Liquid Glass and Siri AI integration.

This is a plan, not code. It covers scope, platform facts that drive the design,
the full feature inventory, architecture, security/permissions, a phased roadmap,
testing, and risks. Sections flagged **Decision** need a call before that phase starts.

---

## 1. Goals and scope

**Goal.** Ship a signed, notarized, directly-distributed macOS app that matches
CleanMyMac 5.7.1 feature-for-feature and looks native on macOS 27.

**Non-goals (v1).**
- No Intel build. macOS 27 is Apple Silicon only (M1 or later), so we are too.
- No Mac App Store build. Most of the useful work (deleting other apps' caches,
  killing processes, launch agents, Endpoint Security) is impossible inside the App
  Sandbox. Direct distribution with Developer ID is the only realistic path.
- No Windows/iOS ports. SwiftUI code could later move to iPadOS but it is not planned.

**Legal note.** "CleanMyMac", its icon, module names used as trade dress, and its
anti-malware signature database belong to MacPaw. We copy the *feature set and
interaction patterns*, not the name, artwork, or copy. Pick an original name and icon
before the first public build. Working title in this doc: **the app**.

---

## 2. Platform facts that shape the design

### macOS 27 "Golden Gate" (released Sept 14, 2026)

| Fact | Consequence for us |
|---|---|
| Apple Silicon only (M1+). Final release to support Rosetta. | Build arm64 only. No Intel testing matrix. |
| Liquid Glass applies automatically to standard controls when built with the macOS 27 SDK. `UIDesignRequiresCompatibility` is ignored. | Use stock SwiftUI controls and materials. Don't fight the system look. |
| New user-facing **Liquid Glass transparency slider** in System Settings. | Never hard-code glass. Use system materials so the slider and Reduce Transparency both work. Test at both slider extremes. |
| **Standardized window corner radius**; sidebars extend edge-to-edge; active windows more distinct; traffic lights are glass. | Use `NavigationSplitView` with the default sidebar. No custom window chrome. |
| Most icons removed from menu items (reverses a Tahoe change). | Keep menus text-only. Icons stay in toolbars and sidebar. |
| App icons have new depth layers across light / dark / tinted / clear. | Build the icon in Icon Composer with all four appearances. |
| **Siri AI** (Gemini-backed) acts in third-party apps **only through App Intents**. "Ask Siri" is in every context menu. | Expose every major action (Run Smart Care, Clean system junk, Uninstall app, Find large files) as App Intents so "Hey Siri, free up space on my Mac" works. |
| Spotlight rebuilt and indexes shortcuts/actions faster. | Same App Intents surface in Spotlight as actions. |
| Apple Intelligence on-device models (AFM 3 Core / Core Advanced) via Foundation Models framework. | Use for "Smart Insights" (explain what a file/folder is before deleting it). On-device, so no privacy issue and works offline. |
| System UI supports HDR; more external display modes. | No action, but don't ship assets that clip in HDR. |

### Toolchain

- **Xcode 27**, **Swift 6.2+** with strict concurrency on.
- **SwiftUI** for all UI. AppKit only where SwiftUI has no equivalent (menu bar
  extra fine control, `NSWorkspace` hooks, `CGEventTap`).
- **Swift Package Manager** local packages for modularity (think Maven modules /
  .NET projects in one solution).
- Deployment target: **macOS 27.0**. (**Decision:** drop to 26.0 if a macOS 26
  audience matters. It costs `#available` branches around Foundation Models and
  some Liquid Glass APIs.)

### For a Java / C# developer, the mapping is roughly

| You know | Swift equivalent |
|---|---|
| C# records / Java records | `struct` with value semantics (default), `final class` when identity matters |
| Interfaces | `protocol` (can have default implementations via extensions) |
| LINQ / Streams | `map`, `filter`, `reduce`, `lazy` on any `Sequence` |
| `async/await`, `Task<T>` | `async/await`, `Task`, structured concurrency (`TaskGroup`) |
| Locks / `synchronized` | `actor` — the compiler enforces isolation instead of you remembering a lock |
| WPF/XAML, JavaFX | SwiftUI — declarative, state-driven, no XAML file, views are value types |
| WCF / named pipes / Binder IPC | XPC — typed cross-process calls, used for our privileged helper |
| NuGet / Maven | Swift Package Manager |
| `IDisposable` / try-with-resources | ARC; `defer {}` for scope-exit cleanup |
| Exceptions | `throws` / `try` with typed `Error` enums (checked, not unchecked) |

---

## 3. Feature inventory (parity with CleanMyMac 5.7.1)

Each item maps to a MacPaw feature. Status column is the target release milestone
(see §7).

### 3.1 Smart Care (home screen)
One button runs the five core scans in parallel and shows a combined result with
a single "Run" action. Per-module cards expand to details.
- Scans: Cleanup, Protection, Performance, Applications, My Clutter.
- Shows total reclaimable space, threats found, maintenance tasks suggested,
  updates available, clutter found.
- **Assistant** panel: contextual recommendations ("You haven't emptied Trash in
  30 days", "3 apps have leftovers"). Rule-based in v1, Apple Intelligence
  phrasing in v2.
- Milestone: M5.

### 3.2 Cleanup
Junk categories, each a pluggable scanner:
- User caches, system caches (helper required), logs, crash reports.
- Language/localization files in apps (opt-in, risky).
- Broken login items, broken preferences.
- Mail attachments (local copies), Xcode derived data / archives / simulators,
  Docker / Homebrew caches.
- Trash bins (all volumes), iOS backups and old iOS software updates.
- Broken / stale downloads, partial `.download` bundles.
- Purgeable space ("Free Up Purgeable Space" task).
- **Smart Insights**: tap any file → on-device model explains what it is and
  whether it is safe to remove. Ships with a curated rules table as fallback.
- Milestone: M1 (core), M5 (Smart Insights).

### 3.3 Protection
- Malware scan: **Quick** (running processes, login items, launch agents, recent
  downloads), **Normal** (user home + Applications), **Deep** (all volumes).
- Detection: YARA-style rule engine + hash list + heuristics (unsigned binaries
  with persistence, quarantine-flag anomalies, known-bad launch agent patterns).
- **Decision:** signature source. Options: ClamAV official DB (GPL-licensed
  signatures, ok to consume), curated open threat intel, or own research.
  Recommend ClamAV + own heuristics for v1.
- Privacy: clear browser history/cookies/autofill (Safari, Chrome, Firefox, Arc,
  Edge), recent items lists, Wi-Fi networks list, chat app caches.
- App permissions review: list apps holding Camera, Mic, Full Disk Access,
  Accessibility, Screen Recording, with deep links into System Settings.
- **Protection Monitor** (menu bar): real-time watch. Full version via an
  **Endpoint Security system extension** (needs Apple entitlement approval, weeks).
  Fallback: FSEvents on `~/Downloads`, `/Applications`, LaunchAgents dirs plus
  quarantine xattr check on new files.
- Milestone: M4.

### 3.4 Performance
- Maintenance tasks: free up RAM, free purgeable space, run periodic scripts,
  flush DNS cache, reindex Spotlight, repair disk permissions (user domain),
  thin Time Machine local snapshots, rebuild Launch Services DB, speed up Mail
  (vacuum Envelope Index), reset Bluetooth module.
- Login items & background items: list and toggle. Our own via `SMAppService`;
  third-party via reading `~/Library/LaunchAgents`, `/Library/LaunchAgents`,
  `LaunchDaemons`, and deep-linking to System Settings › Login Items where the
  OS requires user action.
- Heavy consumers: live CPU/RAM/energy top list with Quit / Force Quit.
- Hung apps detection (unresponsive for N seconds).
- Milestone: M3.

### 3.5 Applications
- **Uninstaller**: app + leftovers (caches, prefs, containers, support files,
  launch agents, kernel/system extensions, receipts). Grouped by vendor and by
  source (App Store / direct / Homebrew cask / Setapp).
- **Leftovers**: orphaned files from already-removed apps.
- **Updater**: App Store updates via `SKPaymentQueue`-free path (parse receipts +
  App Store lookup API), Sparkle apps via their appcast feeds, Homebrew casks via
  `brew outdated --cask`.
- **Extensions**: Safari extensions, Spotlight importers, QuickLook plugins,
  Finder Sync, share/action extensions, system extensions — enable/disable/remove.
- **Reset app** (wipe data, keep binary) and **Installers** (stray .dmg/.pkg).
- Background scanning: start listing as results stream in (5.5.5 behavior).
- Milestone: M2.

### 3.6 My Clutter
- **Large & Old files** with size/age sliders and type filters.
- **Duplicates**: size bucket → partial hash → full hash (SHA-256) pipeline.
- **Similar images**: Vision `VNGenerateImageFeaturePrintRequest` distance
  clustering; show best-quality pick per group.
- **Downloads** triage (installers, archives, screenshots, old files).
- Milestone: M2.

### 3.7 Cloud Cleanup (Plus-tier parity)
- iCloud Drive: local-only analysis of `~/Library/Mobile Documents` plus
  evict/download state via `NSFileManager` ubiquitous keys.
- Google Drive, OneDrive, Dropbox via their REST APIs with OAuth. Actions:
  delete in cloud, remove from Mac and cloud, unsync (keep cloud-only).
- Milestone: M6.

### 3.8 Email Cleanup (5.7.0)
- Gmail API (OAuth): scan newsletters, promotions, spam, drafts, large
  attachments; smart suggestions; unsubscribe (List-Unsubscribe header +
  one-click), trash, archive; subscription manager.
- **Decision:** add IMAP generic support (iCloud Mail, Outlook) in v1 or v2.
- Milestone: M6.

### 3.9 Space Lens
- Interactive bubble map of the disk, folders sized by content, zoom into a
  bubble to re-layout, breadcrumb back out, right-click to reveal/trash.
- Circle-packing layout computed off-main-thread; Canvas-based rendering.
- Milestone: M1 (part of the vertical slice).

### 3.10 Menu bar app ("Menu")
- Popover with: storage, RAM (with "Free up"), CPU, battery health/cycles,
  network up/down, Protection Monitor status, Trash size, quick-run Smart Care,
  and **Screen Cleaning Mode**.
- Runs as a separate login-item agent so it survives the main window closing.
- Milestone: M3.

### 3.11 Screen Cleaning Mode (5.7.1)
- Full-screen black window on every display, keyboard and trackpad input
  swallowed via `CGEventTap` (needs Accessibility permission), 2-minute
  countdown, hold-to-exit escape hatch, auto-exits.
- Milestone: M3 (small, ships with Menu).

### 3.12 Dashboard & shell features
- **My Activity** (5.4.0): storage reclaimed over time, cloud cleanup progress,
  threats blocked, "time saved" estimate. Charts via Swift Charts.
- **My Tools** (5.5.0): pin tools to sidebar top, drag to reorder, create
  **custom action sets** ("Friday clean": caches + Trash + RAM) runnable in one
  click and exposed as App Intents.
- **Notification Center** (5.6.0): bell icon in toolbar; in-app messages, scan
  reminders, update notices. Backed by a local store; optional remote feed later.
- Ignore list, scheduled scans, scan history with undo-from-Trash.
- Settings: General, Ignore List, Scheduler, Protection, Updates, Privacy,
  Advanced (helper install/uninstall).
- Milestone: M5.

### 3.13 MacPaw "In progress" items worth getting ahead of
- Cleanup of AI-tool leftovers (Ollama models, LM Studio, Hugging Face caches,
  Xcode predictive-completion models). Cheap to add as Cleanup scanners. M1.
- Safari/Chrome tab-and-window extension (close duplicates, suspend heavy tabs).
  Safari Web Extension target. M7.
- **Command-line interface**: `maccleaner scan --module cleanup --json`,
  `maccleaner run smart-care`. Reuses Core package. Great for testing too. M3.

---

## 4. Design system (macOS 27 / Liquid Glass)

**Layout.** `NavigationSplitView`. Left sidebar: Smart Care on top, then
My Tools pins, then the five modules, then My Clutter, Cloud, Email, Space Lens,
Menu. Right: detail with a large glass "Scan / Run" button in the bottom bar,
mirroring CleanMyMac's one-primary-action pattern.

**Materials and color.**
- Use `.glassEffect()` and `GlassEffectContainer` for floating controls
  (scan button, filter chips, toolbar groups). Use `.regularMaterial` /
  `.thinMaterial` for panels. Zero custom blur.
- Respect `accessibilityReduceTransparency` and the new system glass slider by
  never compositing text over unmaterialized imagery.
- Accent: one brand color used sparingly (progress rings, primary button). Module
  tints: Cleanup green, Protection blue, Performance orange, Applications purple,
  My Clutter teal. All from `Color` asset catalog with light/dark/high-contrast.

**Motion.** Scan progress as a circular ring that morphs into the result count.
Bubble map zoom with `matchedGeometryEffect`. Respect Reduce Motion.

**Typography.** System font, Dynamic Type sizes, large rounded numerals for
"12.4 GB" results (`.font(.system(.largeTitle, design: .rounded))`).

**Icon.** Icon Composer, layered: background disc, glass broom/sparkle glyph,
highlight layer. Export light, dark, tinted, clear.

**Menus.** Text-only menu items per macOS 27 convention. Keyboard shortcuts for
every module (⌘1–⌘9).

**Onboarding.** Three screens: welcome → permissions walkthrough (Full Disk
Access, Accessibility for Screen Cleaning, Notifications; each with a "Open
System Settings" deep link and live status) → install privileged helper.
Permission status is re-checked on every launch and surfaced as a banner.

**Empty, loading, and result states** designed for every module before code.

---

## 5. Architecture

```
MacCleaner.xcworkspace
├── App/                     SwiftUI app target (main window, settings, onboarding)
├── MenuAgent/               Login-item agent: menu bar extra, Protection Monitor UI
├── PrivilegedHelper/        Root daemon via SMAppService, XPC server, allow-listed ops
├── SecurityExtension/       Endpoint Security system extension (optional, M4)
├── CLI/                     `maccleaner` command-line tool
├── SafariExtension/         Tab manager web extension (M7)
├── Intents/                 App Intents + Shortcuts + Siri AI surface
└── Packages/
    ├── Core/                Scan engine, file walking, hashing, models, persistence
    ├── Modules/             One sub-target per module (Cleanup, Protection, ...)
    ├── Cloud/               Google Drive / OneDrive / Dropbox / Gmail clients
    ├── Malware/             Rule engine, signature DB updater
    ├── UIKitBridge/         AppKit shims (event taps, NSWorkspace, display enumeration)
    └── DesignSystem/        Colors, glass components, charts, shared views
```

**Scan engine.** A `Scanner` protocol: `func scan(context) -> AsyncStream<Finding>`.
Each module is a list of scanners. A `ScanCoordinator` actor fans out with a
`TaskGroup`, throttles disk I/O (configurable concurrency, lower on battery),
dedupes findings by path, and publishes progress. Results are `Sendable` structs.

**File walking.** `FileManager.enumerator` with `.skipsPackageDescendants` where
appropriate, resource keys prefetched (`fileSize`, `contentModificationDate`,
`isDirectory`, `isPackage`, `volumeIdentifier`). Hard-coded protected path list
(`/System`, `/usr`, `/bin`, Time Machine mounts, our own containers) that no
scanner may ever return.

**Deletion.** Always `FileManager.trashItem` first; permanent delete only on the
user's explicit "skip Trash" setting or when Trash is the thing being emptied.
Every run writes a manifest so "Undo last cleanup" can restore from Trash.
Optional APFS local snapshot (`tmutil localsnapshot`) before Performance tasks.

**Privilege.** Main app is unprivileged. Anything needing root (system caches,
launch daemons, periodic scripts, DNS flush, Spotlight reindex of `/`, deleting
other users' files) goes through the helper over XPC. The helper exposes a
*closed* set of operations with path validation; it never takes "run this shell
command" requests. Installed via `SMAppService.daemon`, both sides verify code
signing requirements.

**Persistence.** SwiftData (or GRDB if SwiftData's macOS 27 performance disappoints)
for scan history, My Activity stats, ignore list, schedules, notifications.
Settings in `UserDefaults` via `@AppStorage`. Secrets (OAuth tokens) in Keychain.

**Concurrency.** Swift 6 strict concurrency. UI on `@MainActor`, scanners as
actors or `Sendable` structs, all cross-process via XPC with `Codable` payloads.

**Networking.** `URLSession` only. Endpoints: signature DB updates, Sparkle
appcast for our own updates, cloud provider APIs, App Store lookup.

**Intents.** `AppIntent` types for RunSmartCare, CleanJunk, UninstallApp(app),
FindLargeFiles(minSize), FreeUpRAM, RunActionSet(name), with `AppShortcutsProvider`
phrases. Entities for apps and action sets so Siri AI can parameterize.

---

## 6. Permissions, entitlements, distribution

| Need | Mechanism | User-visible step |
|---|---|---|
| Read all user files, other apps' containers | Full Disk Access | Onboarding deep link to Privacy & Security |
| Swallow input in Screen Cleaning Mode | Accessibility (`CGEventTap`) | Onboarding deep link |
| Root operations | `SMAppService.daemon` helper | One-time approval in Login Items |
| Real-time Protection Monitor | Endpoint Security entitlement + system extension | Apple approval request (plan 4–8 weeks); user approves extension |
| Menu bar agent at login | `SMAppService.loginItem` | Automatic, toggle in Settings |
| Notifications | `UNUserNotificationCenter` | Standard prompt |
| Cloud/Gmail | OAuth 2.0 PKCE via `ASWebAuthenticationSession` | Browser sign-in |
| Distribution | Developer ID, Hardened Runtime, notarization, Sparkle for updates | None |

No App Sandbox on the main app (it would block ~70% of features). The Safari
extension target is sandboxed as required.

---

## 7. Roadmap

Estimates assume one developer full-time, ramping back into Swift in parallel.
Add 30% if that ramp is slow.

| Milestone | Weeks | Deliverable |
|---|---|---|
| **M0 Foundations** | 2 | Xcode 27 workspace, packages, CI (GitHub Actions on macOS 27 runner), signing, Sparkle, `NavigationSplitView` shell with Liquid Glass, onboarding + permission checks, helper install over XPC with a "ping" op. Icon v1. |
| **M1 Vertical slice: Cleanup + Space Lens** | 5 | Scan engine, 8–10 Cleanup scanners (caches, logs, Trash, Xcode, AI leftovers, broken downloads, purgeable), trash-with-undo, Space Lens bubble map. First internal build. |
| **M2 Applications + My Clutter** | 5 | Uninstaller with leftovers, leftovers scan, updater (App Store + Sparkle + brew), extensions, installers, background scanning. Large & old, duplicates, similar images. |
| **M3 Performance + Menu + CLI** | 4 | Maintenance tasks via helper, login/background items, heavy consumers, hung apps. Menu bar agent with stats. Screen Cleaning Mode. `maccleaner` CLI sharing Core. |
| **M4 Protection** | 5 | Rule engine, ClamAV signature ingest + updater, Quick/Normal/Deep scans, privacy cleaners, permissions review, FSEvents monitor. Submit Endpoint Security entitlement request at M2 so it may land here. |
| **M5 Smart Care + shell** | 4 | Smart Care home, Assistant rules, My Activity charts, My Tools pins + action sets, Notification Center, scheduler, ignore list, Smart Insights via Foundation Models. |
| **M6 Cloud + Email** | 4 | iCloud Drive analysis, Google Drive / OneDrive / Dropbox, Gmail Email Cleanup. |
| **M7 Siri, Spotlight, polish, release** | 3 | App Intents for all actions, Shortcuts phrases, Spotlight actions, Safari tab extension, accessibility audit, localization scaffolding (en first), beta via Sparkle channel, 1.0. |

Total ≈ **32 weeks** to a 1.0 at full parity. A credible **0.5 beta** exists
after M3 (~16 weeks): Cleanup, Applications, Clutter, Performance, Menu.

---

## 8. Testing strategy

- **Unit tests** per scanner against fixture trees built in a temp directory
  (`FileManager.temporaryDirectory`), including symlink loops, packages,
  permission-denied dirs, and APFS clones (clones must not double-count).
- **Golden-path integration tests** run the CLI against a fixture volume image.
- **Safety tests**: a protected-path fuzz test asserts no scanner ever yields a
  path under the protected list; a "never deletes outside Trash" assertion on
  the deletion layer.
- **UI tests** (XCUITest) for onboarding, Smart Care run, uninstall flow.
- **Appearance matrix**: light/dark, Increase Contrast, Reduce Transparency,
  Reduce Motion, glass slider min/max, 1200×800 minimum window. Snapshot tests
  via `ImageRenderer` where stable.
- **VM testing**: Tart or UTM macOS 27 VMs for clean-install onboarding,
  helper install, and malware-sample scanning (EICAR + benign lookalikes only).
- **Performance budgets**: full Cleanup scan of a 1 TB home < 60 s on M1;
  UI stays 60 fps during scan; memory < 400 MB peak.

---

## 9. Risks and open decisions

| Risk / decision | Mitigation |
|---|---|
| Endpoint Security entitlement denied or slow | FSEvents fallback ships regardless; ES is additive. Apply early (end of M2). |
| Malware signature licensing/quality | Start with ClamAV DB (GPL signatures, consumed as data) + own heuristics. Revisit commercial feeds later. |
| SwiftData performance on large scan histories | Abstract behind a `Store` protocol; swap to GRDB if needed. |
| Deleting the wrong thing | Trash-first, undo manifest, protected paths, dry-run mode, opt-in for risky categories (language files, system caches). |
| Google/Microsoft/Dropbox API quota and app verification (Gmail needs OAuth app review for restricted scopes) | Begin verification paperwork at M4; ship Cloud/Email behind a feature flag. |
| Liquid Glass readability complaints (the reason Apple added the slider) | Stock materials only; test at slider extremes; never rely on glass for text contrast. |
| App Store wish later | Would need a sandboxed "lite" edition; out of scope for v1. |
| Name / trademark | Pick an original name before any public build. |
| Deployment target 27 vs 26 | Decide at M0. Default 27. |

---

## 10. Repository layout (this repo)

```
/PLAN.md                this document
/docs/                  design notes, ADRs, permission flow diagrams
/App, /MenuAgent, ...   targets as in §5
/Packages/              local Swift packages
/Scripts/               notarize.sh, make-dmg.sh, fixture generators
/.github/workflows/     ci.yml (build + test on macos-27), release.yml
```

---

## 11. Getting back into Swift (suggested ramp, ~1 week alongside M0)

1. *The Swift Programming Language* book, chapters on optionals, protocols,
   generics, error handling, concurrency. Skim the rest; it reads like Kotlin.
2. Apple's *SwiftUI Tutorials* (Landmarks) for the mental model: state drives
   view, views are cheap values, no controllers.
3. WWDC25 sessions on Liquid Glass in SwiftUI and the WWDC26 App Intents / Siri
   sessions. Both are directly relevant to §4 and §5.
4. Write the first Cleanup scanner and its tests before touching any UI. It
   exercises FileManager, async streams, actors, and the test harness in one go.

---

## Sources

- 9to5Mac, "macOS 27 Golden Gate now available, here is everything new" (Sept 14, 2026):
  https://9to5mac.com/2026/09/14/macos-27-golden-gate-now-available-here-is-everything-new/
- TechRadar, "macOS 27 Golden Gate announced at WWDC 2026":
  https://www.techradar.com/computing/mac-os/macos-27-golden-gate-announced-at-wwdc-2026-heres-everything-you-need-to-know
- MacRumors, WWDC 2026 recap: https://www.macrumors.com/2026/06/13/top-stories-wwdc-2026-recap/
- Apple Developer Forums on Liquid Glass compatibility in the 27 SDKs:
  https://developer.apple.com/forums/thread/839061
- MacPaw, CleanMyMac "What's New" (5.0.0 → 5.7.1): https://macpaw.com/cleanmymac/whats-new
- MacPaw, CleanMyMac product page: https://cleanmymac.com/
- MacPaw support, feature availability by edition:
  https://macpaw.com/support/cleanmymac/knowledgebase/feature-plans
- TidBITS, CleanMyMac 5.0 watchlist: https://tidbits.com/watchlist/cleanmymac-5-0/
- Macworld, CleanMyMac review: https://www.macworld.com/article/352922/cleanmymac-x-review-macos.html
