# UI specification (App target, macOS 27)

Companion to PLAN.md §4. Code lives in `App/` and `Packages/DesignSystem`.

## 1. Screen inventory

| Screen | File | Notes |
|---|---|---|
| Main window | `App/Navigation/RootView.swift` | `NavigationSplitView`, min 1200×800, default 1280×860 |
| Sidebar | `RootView.sidebar` | Default sidebar style, edge-to-edge, pins via context menu |
| Toolbar | `RootView` | Search field (`.searchable`), `ToolbarBell` with popover |
| Bottom bar | `BottomActionBar` | Per module; hosts one `PrimaryActionButton`, optional leading control |
| Smart Care | `Modules/SmartCare/SmartCareView.swift` | Hero `ScanRing`, 5 module cards, Assistant panel |
| Cleanup | `Modules/Cleanup/CleanupView.swift` | Categories as disclosure groups, checkboxes, risk badges, Undo |
| Space Lens | `Modules/SpaceLens/SpaceLensView.swift` | `Canvas` bubbles, breadcrumbs, hover tooltip, context menu |
| My Activity | `Modules/MyActivity/MyActivityView.swift` | Swift Charts, sample data until M5 |
| Protection, Performance, Applications, My Clutter, Cloud, Email, Menu | `Modules/Placeholders/PlaceholderViews.swift` | `EmptyState.comingSoon` with milestone |
| Onboarding | `Onboarding/OnboardingView.swift` | Sheet, 680×560, three steps |
| Settings | `Settings/SettingsView.swift` | `TabView`: General, Ignore List, Scheduler, Advanced |
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

Smart Care mirrors Cleanup: ring `.idle` → `.scanning(fraction)` → `.result(value, unit, caption)`.
Space Lens: empty → measuring → bubbles; hover tooltip; right-click Reveal / Zoom In / Move to Trash (confirmation).
Removal always goes through `GuardedRemover(wrapping: TrashRemover())`; permanent delete only when
Settings › General says so, with a destructive confirmation.

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
