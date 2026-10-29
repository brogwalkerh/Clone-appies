# UI specification (App target, macOS 27)

Companion to PLAN.md §4. Code lives in `App/` and `Packages/DesignSystem`.

## 1. Screen inventory

| Screen | File | Notes |
|---|---|---|
| Main window | `App/Navigation/RootView.swift` | `NavigationSplitView`, min 1200×800, default 1280×860 |
| Sidebar | `RootView.sidebar` | Default sidebar style, edge-to-edge, pins via context menu |
| Toolbar | `RootView` | Search field (`.searchable`), `ToolbarBell` with popover |
| Bottom bar | `BottomActionBar` | Per module; hosts one `PrimaryActionButton`, optional leading control |
| Smart Care | `Modules/SmartCare/SmartCareView.swift`, `ActionSetsPanel.swift` | Hero `ScanRing`, 5 module cards, Assistant panel (dismissable), My Tools action sets; Scan → Run |
| Cleanup | `Modules/Cleanup/CleanupView.swift` | Categories as disclosure groups, checkboxes, risk badges, Undo |
| Applications | `Modules/Applications/ApplicationsView.swift` | Segmented Uninstaller · Updater · Leftovers · Installers (§3.1) |
| My Clutter | `Modules/MyClutter/MyClutterView.swift` | Segmented Large & Old · Duplicates · Similar Images · Downloads (§3.2) |
| Shared findings UI | `Modules/Shared/FindingsList.swift` | `FindingsList`, `FindingRow`, `CategoryHeader`, `RiskBadge`, `FindingsActionBar`, removal confirmation, `ModuleTabBar` |
| Space Lens | `Modules/SpaceLens/SpaceLensView.swift` | `Canvas` bubbles, breadcrumbs, hover tooltip, context menu |
| My Activity | `Modules/MyActivity/MyActivityView.swift` | Swift Charts from the activity log, stat pills, recent events, Clear History |
| Performance | `Modules/Performance/PerformanceView.swift` (+ `MaintenanceTab`, `BackgroundItemsTab`, `HeavyConsumersTab`) | Segmented Maintenance · Login Items · Heavy Consumers · Hung Apps (§3.3) |
| Menu | `Modules/MenuApp/MenuAppView.swift` | Menu bar agent settings: enable, launch, pills, Screen Cleaning Mode (§3.4) |
| Protection | `Modules/Protection/ProtectionView.swift` (+ `MalwareTab`, `PrivacyTab`, `PermissionsTab`, `MonitorTab`) | Segmented Malware · Privacy · Permissions · Monitor (§3.6); Quarantine sheet |
| Cloud, Email | `Modules/Placeholders/PlaceholderViews.swift` | `EmptyState.comingSoon` with milestone |
| Helper install sheet | `RootView` + `OnboardingView(initialStep: .helper)` | Shown while `AppState.helperInstallRequested`; opened by Performance and `maccleaner://performance?task=` |
| Onboarding | `Onboarding/OnboardingView.swift` | Sheet, 680×560, three steps |
| Settings | `Settings/SettingsView.swift` | `TabView`: General, Protection, Ignore List, Scheduler, Advanced (§3.7) |
| Notification popover | `RootView.NotificationListView` | 340 pt wide, mark read / clear |
| Permission banner | `RootView.permissionBanner` | Top inset when Full Disk Access is denied |

## 2. Sidebar order and shortcuts

1. Smart Care (⌘1)
2. **My Tools** — user pins, reorderable, hidden when empty
3. **Modules** — Cleanup ⌘2 · Protection ⌘3 · Performance ⌘4 · Applications ⌘5 · My Clutter ⌘6
4. **More** — Cloud Cleanup ⌘7 · Email Cleanup ⌘8 · Space Lens ⌘9 · My Activity · Menu

Shortcuts live in the text-only **Go** menu (`ModuleCommands`). ⌘R runs a Cleanup scan.
Icons appear in the sidebar and toolbar only, never in menus.

## 3. States per module

| State | Trigger | Presentation | Primary button |
|---|---|---|---|
| Empty (idle) | No scan yet | `EmptyState(style: .symbol)` intro copy | "Scan" |
| Needs permission | FDA denied and idle | `EmptyState.needsPermission` + "Open System Settings" | "Scan" still enabled |
| Scanning | `phase == .scanning`, no findings | `EmptyState.scanning` with Cancel | "Scanning…" (loading, disabled) + "Stop" leading |
| Scanning with results | findings arriving | Linear progress strip + list | "Scanning…" |
| Results | `phase == .finished`, findings | Disclosure groups, selection, subtitle "X found • Y selected" | "Clean 12.4 GB" |
| Nothing found | finished, 0 findings | `EmptyState.nothingFound` + "Scan Again" | "Scan Again" |
| Cancelled | user stopped | Partial results (coordinator still emits `.completed`) or "Scan Stopped" | "Scan Again" |
| Done | manifest exists | Leading "Undo Last Cleanup" + "Reclaimed X" | "Scan Again" |
| Coming soon | later milestone | `EmptyState.comingSoon(feature:milestone:)` | disabled "Scan" |

Every scan-driven list (Cleanup, Applications › Leftovers / Installers, My Clutter) renders through
`FindingsList` + `FindingsActionBar`, so the rows above apply verbatim; tabbed modules filter the
one shared `ScanViewModel` by category id prefix and the primary button acts on the model's whole selection.

### 3.1 Applications (M2)

Segmented control (`ModuleTabBar`, `.bar` strip under the toolbar) selects the tab; the bottom bar changes with it.

| Tab | State | Trigger | Presentation | Primary button |
|---|---|---|---|---|
| Uninstaller | Discovering | `AppInventoryStore.discovery == .discovering`, no apps yet | `EmptyState.scanning("Finding installed apps…")` | "Uninstall" disabled |
| Uninstaller | Failed | discovery threw, no apps | `EmptyState` with "Try Again" | disabled |
| Uninstaller | List, nothing selected | apps loaded | Left: `List` of `InstalledAppRow` (icon, name, `AppSourceBadge`, version, last opened, size). Right 380 pt: "Select an App" | disabled |
| Uninstaller | App selected | `selectedAppID` set | Detail pane: 64 pt icon, name, version, source badge, `GlassCard` facts (size, last opened, bundle id, location), "Items to remove": bundle (always on) + leftovers with checkboxes, "Removing n items • X" | "Uninstall X" |
| Uninstaller | Resolving leftovers | `resolvingLeftovers` contains app | spinner row "Looking for support files…" | enabled (bundle only) |
| Uninstaller | System app | `app.isSystem` | lock.shield explanation instead of the checklist | disabled, help text |
| Uninstaller | Uninstalling / Done | `isUninstalling` / `lastUninstallManifest` | button loading; leading "Undo Last Uninstall" | "Uninstalling…" |
| Updater | Idle | `updateState == .idle` | `EmptyState` "Check for Updates" | "Check for Updates" |
| Updater | Checking | `.checking` | `EmptyState.scanning("Checking n apps…")` | "Checking…" (loading) |
| Updater | Up to date | `.checked`, no updates | `EmptyState.nothingFound` + "Check Again" | "Check for Updates" |
| Updater | Results | `.checked`, updates | `List` of `AvailableUpdateRow`: icon, name, installed → latest, source badge, "Open" (release notes or download via `NSWorkspace`) ; leading "Checked 2 minutes ago" | "Check for Updates" |
| Leftovers / Installers | all | `applicationsModel` phases | identical to §3 rows, filtered to `applications.orphaned` / `applications.installers` | "Scan" → "Remove X" |

Confirmation copy for Uninstall names the app and the number of support files. Removal always goes through
`GuardedRemover(wrapping: TrashRemover())`; `AppInventoryStore.uninstall` throws before touching a `.system` app.

### 3.2 My Clutter (M2)

One `clutterModel` runs Large & Old, Duplicates, Similar Images (Vision feature prints) and Downloads; tabs filter by category.

| Tab | State | Presentation |
|---|---|---|
| Large & Old | any | Threshold strip under the tab bar: "Larger than" slider (10 MB–5 GB, step 10 MB) and "Or not opened for" slider (any–2 y, step 30 d), both `@AppStorage`. Moving a slider calls `ScanViewModel.replaceScanners`; existing results stay and a caption reads "Applies on the next scan". |
| Large & Old, Downloads | results | `FindingsList` filtered to the tab's category |
| Duplicates, Similar Images | results | `KeeperGroupList`: one disclosure group per keeper parsed from "Duplicate of <path>" / "Similar to <keeper>"; header shows a lazily decoded 36 pt thumbnail (ImageIO, max 96 px) for images, keeper name, "Keeping this one • n copies", bytes, tri-state checkbox; rows are `FindingRow` |
| any | idle / scanning / nothing / cancelled | §3 rows; the nothing-found copy notes that other tabs may still hold results |

Primary button: "Scan" → "Scanning…" → "Remove X" (model-wide selection) → "Scan Again"; leading "Stop" / "Undo Last Removal".

### 3.3 Performance (M3)

`ModuleTabBar` selects the tab; the bottom bar changes with it. Maintenance drives `AppState.maintenance`
(`MaintenanceState`) so a run keeps streaming while the user navigates away. Heavy Consumers and Hung Apps share one
`ProcessMonitor` that polls `DarwinProcessSampler` every 3 s only while one of those tabs is visible (`.task(id: tab)`).
"Needs helper" means `task.requiresHelper && !HelperClient.shared.isAvailable`.

| Tab | State | Trigger | Presentation | Primary button |
|---|---|---|---|---|
| Maintenance | Idle | no run yet | `List` of `MaintenanceTaskRow`: checkbox, symbol, name, "Helper" / "Needs helper" badge, `RiskBadge` for caution/risky, one-line summary, "~5 s" estimate, chevron that expands the Smart Insights paragraph. Needs-helper rows are dimmed, unchecked-able, and carry an "Install helper" link that opens the helper sheet | "Run N tasks" (N = selected tasks that can run; disabled at 0) |
| Maintenance | Running | `maintenance.isRunning` | "This run" section above the catalog: `MaintenanceResultRow` per task in run order — pending (dashed circle), running (spinner), success (green check, message, bytes, seconds), failed (red x, message), skipped (orange minus, "needs helper"). Subtitle "Running 2 of 5…" | "Running…" (loading) + leading "Stop" |
| Maintenance | Done | results and not running | "This run" stays; leading text "3 succeeded • 1 failed • reclaimed 1.2 GB"; toolbar "Clear Results" | "Run N tasks" |
| Maintenance | Deep link | `maccleaner://performance?task=<id>` | Tab switches to Maintenance, only that task is checked; it runs immediately if it can, otherwise the helper sheet opens | as above |
| Login Items | Loading | first visit | `EmptyState.scanning("Reading launch agents…")` | "Remove 0 Broken Items" disabled |
| Login Items | Failed / Empty | discovery threw / no items | `EmptyState` with "Try Again" / `nothingFound` | disabled |
| Login Items | List | items | Sections Your Launch Agents · Login Item Apps · System Launch Agents · System Launch Daemons, each with a footer explaining where it comes from. `BackgroundItemRow`: domain symbol (red when broken), owner app + label, badges Broken · Apple · Run at load · Keep alive, program path, `.switch` toggle. Toggle rules: user agents via `LaunchctlService` (`bootout`/`bootstrap gui/<uid>`); system agents/daemons via `HelperClient.perform(.setLaunchDaemonEnabled)` (disabled with a banner + "Install helper" link when the helper is missing); Apple items, broken items and login-item apps read-only (help text says why). Context menu: Reveal in Finder | "Remove N Broken Items" (broken, non-Apple, user-domain plists) → `RemovalConfirmation` → `GuardedRemover(TrashRemover)`; leading "Manage in System Settings" (`x-apple.systempreferences:com.apple.LoginItems-Settings.extension`) |
| Heavy Consumers | Sampling | no sample yet | `EmptyState.scanning("Sampling processes…")` | "Refresh" (loading) |
| Heavy Consumers | Nothing heavy | ranker returns none | `EmptyState.nothingFound("No Heavy Consumers")` | "Refresh" |
| Heavy Consumers | List | ranked samples | `ProcessRow`: 28 pt icon (`NSRunningApplication.icon`, generic executable otherwise), name, "System" badge, "Not responding" badge, bundle id / PID, CPU % (orange ≥ 20 %), memory, energy when known, Quit (`terminate()`), Force Quit (`forceTerminate()`, destructive confirmation). System processes: both buttons disabled | "Refresh"; leading "Updated n seconds ago" |
| Hung Apps | Checking | no sample yet | `EmptyState.scanning("Checking for unresponsive apps…")` | "Force Quit All" disabled |
| Hung Apps | None | `ranker.hung` empty | `EmptyState.nothingFound("No unresponsive apps")` | disabled |
| Hung Apps | List | hung samples | same `ProcessRow` without the badge | "Force Quit All" → confirmation; leading "Checked n seconds ago" |

Errors from launchctl, the helper, or a quit that did not take surface through `messageAlert("Performance")`.

### 3.4 Menu (M3)

Settings for the login-item agent. Three `GlassCard`s in a 760 pt column; no scan, so the bottom bar hosts the
enable/disable action.

| Section | State | Presentation |
|---|---|---|
| Status card | `SMAppService.loginItem("com.example.maccleaner.MenuAgent").status` | Symbol + "Enabled; starts at login" / "Not enabled" / "Waiting for approval in System Settings › Login Items" / "Agent not found in the app bundle"; green "Enabled" label when registered |
| Pills card | `@AppStorage` in suite `com.example.maccleaner.shared` (`MenuAgentSettings.Key`: `menu.pills.cpu`, `.memory`, `.disk`, `.battery`, `.network`, `.trash`, `.protectionMonitor`, all default on) | 2-column grid of `.switch` toggles in glass capsules: CPU · RAM with Free Up · Disk and purgeable · Battery health · Network · Trash size · Protection Monitor. The agent reads the same suite |
| Screen Cleaning card | `ScreenCleaningController.shared.isActive` | Explanation + "Try Screen Cleaning Mode" (`.glassProminent`, disabled while active). If Accessibility is off an alert explains the limitation first; the controller still starts and shows its own explanation |
| Bottom bar | — | Primary "Enable Menu Bar Agent" / "Disable Menu Bar Agent" (register / unregister, loading while working; also mirrors `settings.showMenuBarAgent`); leading "Launch Now" (`NSWorkspace.openApplication` on `Contents/Library/LoginItems/MacCleanerMenu.app`) and, when approval is pending, "Open Login Items" |
| Errors | `MenuAgentController.lastError` | `messageAlert("Menu Bar Agent")` |

### 3.5 URL scheme

`CFBundleURLTypes` registers `maccleaner`. `DeepLink(url:)` (pure, tested in `Tests/AppTests/DeepLinkRouterTests.swift`)
parses `maccleaner://smart-care`, `maccleaner://cleanup[?scanner=<id>]`, `maccleaner://performance[?task=<id>]` and
`maccleaner://protection[?scope=quick|normal|deep]`; `DeepLinkRouter` selects the sidebar item, starts a Cleanup scan
restricted to the named scanner (unknown ids scan everything; the next plain Scan restores the full set), hands the task
to the Performance screen as above, or switches the malware scope (unknown or missing scope keeps the current one) and
starts the scan so Protection opens on live progress.

### 3.6 Protection (M4)

`ModuleTabBar` selects the tab; the bottom bar changes with it. Malware drives `AppState.malware` (`MalwareScanModel`,
`MalwareScanner.scanThreats` for the chosen `ScanScope`) and Privacy drives `AppState.privacyModel` (a `ScanViewModel`
over `PrivacyScanners.all()`), so both keep running while the user navigates away. Permissions reads TCC on demand
(`PermissionsStore`); Monitor polls the shared suite every 2 s only while visible (`.task(id:)`). Opening the module
loads the signature database once (bundled starter + `~/Library/Application Support/com.example.maccleaner/signatures`),
purges quarantine past the retention period, and, if Settings › Protection allows, checks the feed at most once a day.

| Tab | State | Trigger | Presentation | Primary button |
|---|---|---|---|---|
| Malware | any | — | Scope strip under the tab bar: segmented Quick · Normal · Deep (disabled while scanning) with a one-line explanation of what the scope covers | — |
| Malware | Idle | no run yet | `EmptyState` "Ready to Scan" + `SignatureFooter`: "Signatures: n hash • m pattern • k allowlisted", version or "Bundled starter set…", "Update Signatures" (`.glass`; status line shows "Checking…", "Updated to <version> • n files", "Up to date", or the error) | "Scan" |
| Malware | Scanning | `phase == .scanning`, no threats | `ScanProgressView`: large spinner, "Scanning N locations…", elapsed `mm:ss` (`TimelineView`), `GlassCard` listing up to 10 resolved roots (`ScanScopeResolver`) with "and n more", Cancel | "Scanning…" (loading) + leading "Stop" |
| Malware | Scanning with results | threats arriving | Strip "Scanning… n threats so far in N locations" + `ThreatList` | "Scanning…" |
| Malware | Results | finished or cancelled, threats | `List` sections per severity (critical → low), header: tri-state `SelectionCheckbox`, `SeverityBadge`, "n threats", bytes. `ThreatRow`: checkbox, shield symbol in the severity color, name, `SeverityBadge` (Low grey · Medium orange · High red · Critical purple), kind badge Signature (blue) / Heuristic (grey), full path (middle-truncated), detail line, size; context menu Reveal in Finder. Subtitle "n threats • m selected"; toolbar "Select All" | "Quarantine n threats" (disabled at 0 selected) → confirmation ("Items move to the app's quarantine folder with all permissions removed…") → `ThreatQuarantine.quarantine`; button reads "Quarantining…" |
| Malware | Quarantined | `lastQuarantineManifest` | Leading "Show Quarantine" + "Quarantined n items"; quarantined rows leave the list; notification posted | "Scan Again" |
| Malware | No threats | finished, 0 threats | `EmptyState.nothingFound("No Threats Found")` with "<Scope> scan checked N locations in 42 s against n signatures. Signatures <version>." + `SignatureFooter` | "Scan Again" |
| Malware | Cancelled | user stopped | Partial results, or "Scan Stopped" | "Scan Again" |
| Malware | Failed | scanner threw / database missing | `EmptyState` "Scan Failed" with the message + "Try Again"; `messageAlert("Protection")` | "Scan Again" |
| Malware | Quarantine sheet | toolbar "Quarantine (n)" / leading "Show Quarantine" | 680×500 sheet: header with item count and retention note; `List` with one section per `QuarantineManifest` (date • n items, "Restore" per manifest) and rows name, `SeverityBadge`, original path, size, per-record error; footer "Delete All Permanently" (destructive confirmation → `purge(olderThan: 0)`), notice text, "Done". Empty: "Quarantine is empty" |
| Privacy | any | — | Banner under the tab bar: green "No browsers are running." or orange "<Safari and Chrome> are running." + "Quit Browsers" (`.glass`, confirmation, graceful `NSRunningApplication.terminate`), re-checked every 3 s. Supported: Safari, Chrome, Firefox, Arc, Edge | — |
| Privacy | Idle / Needs permission / Scanning / Results / Nothing / Cancelled / Done | `privacyModel` phases | §3 rows verbatim through `FindingsList` (categories `privacy.<kind>`; Wi-Fi networks and Firefox places are `.risky`) | "Scan" → "Remove X" → "Scan Again"; leading "Stop" / "Undo Last Removal" |
| Permissions | Reading | first visit | `EmptyState.scanning("Reading app permissions…")` | "Refresh" (loading) |
| Permissions | Needs permission | `TCCPermissionsReader.grants()` threw | `EmptyState` "Full Disk Access Required" with the reader's message + "Open Full Disk Access Settings" (`Privacy_AllFiles`) | "Refresh" |
| Permissions | Empty | no grants | `EmptyState.nothingFound("No Permission Grants")` + "Refresh" | "Refresh" |
| Permissions | List | grants | One section per `PrivacyService` in enum order (Camera, Microphone, Full Disk Access, Accessibility, Screen Recording, Location Services, Contacts, Calendars, Photos, Input Monitoring, Automation): header `Label` + "n of m granted" + "Manage in System Settings" (`x-apple.systempreferences:com.apple.preference.security?Privacy_<Camera|Microphone|AllFiles|Accessibility|ScreenCapture|LocationServices|Contacts|Calendars|Photos|ListenEvent|Automation>`), footer explains the service. `PermissionGrantRow`: 28 pt app icon (`AppIconProvider` via bundle id or path, `app.dashed` fallback), name, bundle id, relative last-modified, green "Allowed" / grey "Denied". Granted rows first | "Refresh"; leading "Read n minutes ago" |
| Monitor | any | shared suite `monitor.enabled`, `monitor.lastEvent`, `monitor.threatCount` + `SMAppService.loginItem` status | Three `GlassCard`s in a 760 pt column. Status card: symbol + line — grey "Menu bar agent is off" / "Monitor is off", orange "Waiting for the agent to start the monitor", green "Running • last activity 2 minutes ago", red "n threats found • last …" with a large count. Settings card: `.switch` "Watch for threats in real time" bound to `monitor.enabled`, watched locations (~/Downloads, /Applications, ~/Library/LaunchAgents, /Library/LaunchAgents, /Library/LaunchDaemons). Orange hint card "Requires the menu bar agent to be enabled" + "Open Menu" when the agent is not registered | "Enable Monitor" / "Disable Monitor"; leading "Open Menu Settings" |

Errors from quarantine, restore, purge and privacy removal surface through `messageAlert("Protection")`. Smart Care's
Protection card reads `lastScanSummaries[.protection]` (threat count or "Nothing to clean"); the hero "Threats" pill shows the
same count. `RunMalwareScanIntent` (Siri / Shortcuts, `ScanScopeAppEnum`) runs a fresh scanner to completion and reports the count.

### 3.7 Settings › Protection (M4)

| Section | Control | Storage |
|---|---|---|
| Signatures | "Feed URL" text field (prompt and "Reset to Default" = `https://github.com/brogwalkerh/Clone-appies/releases/latest/download/`; orange caption while not an http(s) URL — the default is used meanwhile), "Update signatures automatically" toggle (default on; once a day when Protection opens) | `protection.signatureFeedURL`, `protection.autoUpdateSignatures` |
| Quarantine | Stepper "Keep quarantined items for n days" (1–365, default 30); older manifests are purged when Protection opens | `protection.quarantineRetentionDays` |
| Protection Monitor | "Watch Downloads, Applications and launch agents in real time" toggle, mirrored by Protection › Monitor | `monitor.enabled` in suite `com.example.maccleaner.shared` |

Space Lens: empty → measuring → bubbles; hover tooltip; right-click Reveal / Zoom In / Move to Trash (confirmation).
Removal always goes through `GuardedRemover(wrapping: TrashRemover())`; permanent delete only when
Settings › General says so, with a destructive confirmation.

## 3.3 Menu popover (MenuAgent, M3)

`MenuBarExtra` in `.window` style, 320 pt wide, built from `StatPill` rows inside one
`GlassEffectContainer`. Data comes from `SystemStatsSampler` (2 s), a 60 s Trash measurement and,
since M4, the FSEvents `ProtectionMonitor` that `AgentState` owns for the life of the agent process.

| Row / control | State | Presentation |
|---|---|---|
| Status item | normal pressure | `sparkles` symbol only |
| Status item | warn / critical | symbol + 6 pt amber / red dot |
| Status item | threats found (M4) | symbol + 6 pt red dot; wins over the pressure dot; accessibility "Mac Cleaner, threats found" |
| Header | measuring | "Mac Cleaner" + "Measuring…" (`.updatesFrequently`) until the first sample |
| CPU, Memory, Disk, Network | no sample yet | pills show "–" |
| Memory | any | "used / total", `PressureBadge` (Normal / Warn / Critical), small glass "Free Up" → `maccleaner://performance?task=maintenance.freeRAM` |
| Disk | any | "used / total", caption "N purgeable" |
| Battery | laptop | "N %", caption "Charging • 312 cycles • 91 % health"; row hidden on desktops |
| Network | any | "↓ 1.2 MB/s  ↑ 120 KB/s" |
| Trash | any | size, small glass "Empty" (disabled at 0 B) → `maccleaner://cleanup?scanner=cleanup.trash` |
| Protection Monitor | off (M4) | grey dot, caption "Off" (or "Off — <reason>" when FSEvents failed), secondary text; `.switch` toggle off |
| Protection Monitor | running | green dot, caption "Watching N files" (N = files hashed since start); toggle on |
| Protection Monitor | threats | red dot, red caption "N threats found — <latest name>"; toggle on; a "Threat detected" user notification (body "<name> — <file>") is posted per new threat, authorization requested once on first start |
| Protection Monitor | any | dot + text are a plain button → `maccleaner://protection`; the toggle writes `monitor.enabled` (default true) in suite `com.example.maccleaner.shared` and starts / stops the monitor in place. Watched: `~/Downloads`, `/Applications`, `~/Library/LaunchAgents`, `/Library/LaunchAgents`, `/Library/LaunchDaemons` |
| Run Smart Care | always | `.glassProminent`, full width, ⏎ → `maccleaner://smart-care` |
| Screen Cleaning Mode | idle / active | `.glass`; disabled while a session is running |
| Open Mac Cleaner · Quit | always | `.glass`; ⌘Q quits the agent |

Reduce Transparency: glass pills and buttons fall back on their own; the header badge
switches from the accent→performance gradient to a flat accent fill. No custom blur anywhere.

### 3.4 Screen Cleaning Mode (M3)

| State | Trigger | Presentation |
|---|---|---|
| Needs permission | `AXIsProcessTrusted() == false` | `NSAlert` "Accessibility Access Required" with "Open System Settings" (Privacy › Accessibility) and Cancel; nothing else happens |
| Active | `begin(duration:)` (default 120 s) | One black borderless `.screenSaver` window per display, cursor hidden, all keyboard and mouse events swallowed by a session event tap; centered `mm:ss` countdown (120 pt, 55 % white) and "Keyboard and trackpad are locked. Hold ⌘ for 2 seconds to exit." |
| Holding ⌘ | `flagsChanged` with ⌘ down | 220 pt linear progress fills over 2 s; releasing resets it |
| Ended | countdown hits 0, ⌘ held 2 s, or `end()` | Tap removed, windows closed, cursor restored, agent re-activated |

Reduce Motion drops the numeric cross-fade on the countdown. Text stays dim on pure black so smudges remain visible while wiping.

## 4. Liquid Glass checklist (PLAN.md §4)

- [ ] Stock controls only; no custom window chrome, no custom blur, no `NSVisualEffectView`.
- [ ] Floating controls use `.glassEffect()` / `.buttonStyle(.glass | .glassProminent)` inside a `GlassEffectContainer` (bottom bar, chips, tooltip).
- [ ] Panels use `.regularMaterial` / `.bar` (`GlassCard`, banners, progress strip), never glass.
- [ ] Text never sits on unmaterialized imagery; Space Lens labels draw on tinted fills with `Color.primary`.
- [ ] One accent (`ModuleTint.accent`) for rings and the primary button; module tints only on their own module.
- [ ] Colors come from `ThemedColor` (light/dark + increased-contrast variants), no hard-coded `Color(red:…)` in views.
- [ ] Reduce Transparency and the system glass slider are never overridden; nothing reads or caches glass opacity.
- [ ] Reduce Motion: no spinning arc, no spring on `ScanRing`, no breadcrumb animation; `.contentTransition(.numericText())` stays (cross-fade only).
- [ ] Menus are text-only; symbols only in sidebar, toolbar, cards.
- [ ] Numerals use `.rounded` design with `monospacedDigit()` (`ByteText`, `ScanRing`, headers).
- [ ] Every interactive element has an accessibility label; progress views carry `.updatesFrequently`.
- [ ] Window minimum 1200×800 enforced with `.frame(minWidth:minHeight:)` + `.windowResizability(.contentMinSize)`.

## 5. Appearance test matrix

Run each screen in §1 through every row; record with `ImageRenderer` snapshots where stable (PLAN.md §8).

| Axis | Values | What to check |
|---|---|---|
| Appearance | Light, Dark | Module tints readable on `.regularMaterial`; badges and risk colors keep contrast |
| Increase Contrast | Off, On | `ThemedColor` shifts (−18 % / +18 %); glass button borders visible |
| Reduce Transparency | Off, On | Glass falls back to opaque; no text loses contrast; layout unchanged |
| Reduce Motion | Off, On | Ring does not spin; phase changes cross-fade; bubble zoom is instant |
| Glass slider | Minimum, Maximum | Bottom bar and tooltip legible at both extremes over busy Space Lens canvas |
| Window size | 1200×800, 1280×860, full screen | Sidebar 220–300 pt; module cards stay 5-up; bottom bar never clips the primary button |
| Content scale | Default, Larger Text | `ByteText` and `ScanRing` scale via `minimumScaleFactor`; rows wrap detail line |
| Permission state | FDA granted / denied | Banner appears only when denied and onboarding is done; Cleanup idle shows needs-permission state |

Sign-off: all cells pass on macOS 27.0 with the macOS 27 SDK before each milestone build.
