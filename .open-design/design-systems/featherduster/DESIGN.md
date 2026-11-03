# Featherduster

> Native macOS cleaner on Liquid Glass. One glass button, one ring, one big rounded number per screen.

Source of truth: `Packages/DesignSystem` (Swift) and PLAN.md §4. This file describes that
system for design agents; when the two disagree, the Swift code wins. Hex values below are
the code's `RGB` triples converted to sRGB hex.

## 1. Visual Theme & Atmosphere

A SwiftUI app for macOS 26+ that looks like part of the OS. System chrome, materials and
SF Symbols carry the structure; the app adds only three things: a module tint, a scan ring,
and big rounded numerals. Each screen has one job and one primary action at the bottom.

**Key characteristics**
- `NavigationSplitView`: sidebar on the left, one work area on the right, a glass bottom bar.
- Liquid Glass (`.glassEffect`, `GlassEffectContainer`) for floating controls only; `.regularMaterial` / `.thinMaterial` for panels. Zero custom blur, zero shadows.
- One tint per module, one brand accent for everything else, neutrals from the system.
- Results are numbers, not charts: "12.4 GB" set huge in SF Pro Rounded.
- Light, Dark, and an Increased-contrast variant of each, calculated in code.

## 2. Color

### Module tints (light / dark)
| Token | Light | Dark | Module |
|---|---|---|---|
| `--tint-cleanup` | `#2ea85c` | `#52cc78` | Cleanup |
| `--tint-protection` | `#0078fa` | `#2499ff` | Protection |
| `--tint-performance` | `#fa8a1a` | `#ffa138` | Performance |
| `--tint-applications` | `#8a4ce6` | `#b07aff` | Applications |
| `--tint-clutter` | `#0099a6` | `#42c7cc` | My Clutter |
| `--accent` | `#5463f7` | `#808fff` | Smart Care, Space Lens, My Activity, Menu |

Increased contrast (`ColorSchemeContrast.increased`): light values move 18% toward black,
dark values 18% toward white. Light-IC: cleanup `#268a4b`, protection `#0062cd`,
performance `#cd7115`, applications `#713fbc`, clutter `#007d88`, accent `#4552cb`.
Dark-IC: cleanup `#71d590`, protection `#4babff`, performance `#ffb25c`,
applications `#be92ff`, clutter `#64d1d5`, accent `#96a3ff`.

- Tints color the screen's ScanRing, its primary button, sidebar symbol and key numerals. Nothing else.
- `--accent` appears at most twice per screen: the progress ring and the primary button.

### Status (platform system colors, light / dark)
- Green `#34c759` / `#30d158`: granted, enabled, healthy; risk **Safe**.
- Orange `#ff9500` / `#ff9f0a`: needs attention; risk **Caution**, "Needs helper".
- Red `#ff3b30` / `#ff453a`: failed, broken, "Not responding"; risk **Risky**; unread badge.
- Blue `#007aff` / `#0a84ff`: neutral info badges ("Helper", "Run at load", App Store).
- A status always carries its word. Badges are a capsule filled with the color at 15% opacity, the word in the full color, 10px semibold.

### Neutrals (platform semantics, light / dark)
- Window background `#ececec` / `#323232`; content (lists, tables) `#ffffff` / `#1e1e1e`.
- Label `rgba(0,0,0,0.85)` / `rgba(255,255,255,0.85)`; secondary `rgba(0,0,0,0.5)` / `rgba(255,255,255,0.55)`; tertiary `rgba(0,0,0,0.26)` / `rgba(255,255,255,0.25)`; separator `rgba(0,0,0,0.1)` / `rgba(255,255,255,0.1)`.
- `.secondary` is the most used text style in the app: captions, units, metadata.

### Contrast (on content background)
Below 4.5:1 and kept as the source has them: light `--tint-performance` 2.4:1,
`--tint-cleanup` 3.1:1, `--tint-clutter` 3.4:1, `--tint-protection` 4.1:1, secondary label
4.0:1; white button labels on every dark tint (about 2:1 to 3:1). Use tints for symbols, rings
and numerals 24px and larger; never for body text in light mode.

## 3. Typography

- **Family:** SF Pro (system font, Dynamic Type). Numerals and result values use **SF Pro Rounded** (`design: .rounded`) with monospaced digits.
- **macOS text styles at default size:** large title 26/32, title 22/26, title 2 17/22, title 3 15/20, headline 13/16 bold, body 13/16, callout 12/15, subheadline 11/14, footnote 10/13, caption 10/13, caption 2 10/13 medium.
- Most used: `caption` (metadata, StatPill captions) and `callout` (explanations, ring captions). Card and row titles: `headline`.
- **Rounded numerals:** result 56 semibold (ScanRing), progress 44 semibold, ByteText default 34 semibold, unit 24 medium in secondary label, button value 20 semibold, badge count 9 bold.
- Byte sizes: decimal units (1000-based), one decimal place: "12.4 GB", "532 B". The unit is half the numeral's size, medium weight, secondary color, baseline-aligned, gap 12% of the size.
- Fallback for web mockups: `-apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif`; rounded: `ui-rounded, "SF Pro Rounded", -apple-system, sans-serif`.

## 4. Spacing & Grid

Raw point values, no named scale in the code: 1, 2, 4, 6, 8, 10, 12, 14, 16, 20, 24, 28, 32.
- 12: default stack spacing in screens and popovers.
- 10: icon-to-label gaps (buttons, stat pills).
- 16: card padding (`Metrics.cardPadding`).
- 20: list horizontal inset (FindingsList).
- 24: bottom bar horizontal padding.
- Radii (continuous corners): 6 thumbnails, 8 glass overlays, 16 cards (`Metrics.cardCornerRadius`), capsule for every button, pill and badge.

## 5. Layout & Composition

- Window minimum 1200 × 800. Sidebar order: Smart Care; My Tools (pins); Modules (Cleanup, Protection, Performance, Applications, My Clutter); More (Cloud Cleanup, Email Cleanup, Space Lens, My Activity, Menu). ⌘1–⌘9 shortcuts.
- Detail screen: one work area (ring, list or map) and a fixed `BottomActionBar`: 84px tall, `.bar` background, top divider, the primary button centred, an optional leading item mirrored by a hidden copy so the button stays centred.
- Notification Center popover: 340px wide, `.regularMaterial`. Menu bar popover: `.regularMaterial`, 14px inset.
- Separate zones with space and materials, not borders or nested cards.

## 6. Components

- **PrimaryActionButton:** one per screen. `.glassProminent` capsule, `.extraLarge`, padding 28 × 10, min width 200, label title 3 semibold, optional ByteText at 20 ("Clean **12.4** GB"), spinner when loading. Label sequence: Scan → Scanning… → Clean 12.4 GB → Scan Again. It is the window's default action.
- **GlassCard:** `.regularMaterial`, 16 radius, 16 padding, optional 1px edge in the tint at 35% (all four sides, never a left-border accent).
- **StatPill:** glass capsule, padding 14 × 8: 24px-wide symbol in the tint, rounded headline value, caption below in secondary.
- **ToolbarBell:** `bell` / `bell.badge` (multicolor when unread), red count capsule 9px rounded bold, "99+" cap.
- **ScanRing:** 220 diameter, 14 stroke, round caps, track at 18% of the tint, starts at 12 o'clock. Phases: idle (sparkle), indeterminate (28% arc spinning), determinate ("63%" + "Scanning…"), result ("12.4" + "GB" + caption).
- **EmptyState:** `ContentUnavailableView` factories: nothing found (`checkmark.seal`), needs permission (`lock.shield` + "Open System Settings"), scanning (large spinner + Cancel), coming soon. Actions use `.glass` buttons.
- **ByteText:** see Typography.
- **Risk badge / PerformanceBadge** (app level): word in a 15% capsule, 10px semibold.
- Secondary buttons are `.buttonStyle(.glass)`; icons are SF Symbols only.

## 7. Motion & Interaction

- ScanRing phase changes: spring, 0.6s. Indeterminate arc: linear rotation, 1.2s per turn.
- Changing numbers use the numeric-text content transition (digits roll).
- Space Lens bubbles zoom with matched-geometry transitions.
- **Reduce Motion:** no spin, no spring; a plain progress indicator replaces "Scanning".
- **Reduce Transparency** and the system glass slider apply automatically because only stock glass and materials are used; never put text over unmaterialized imagery.
- Keyboard: Return triggers the primary action; ⌘1–⌘9 switch modules.

## 8. Voice & Brand

Calm, specific, reassuring. Second person ("your Mac"), never "we", no exclamation marks, no emoji.
- Messages: sentence case, what happened then what to do. "Your Mac is already tidy. Check back after a few days of use."
- Buttons and titles: Title Case verbs. "Scan", "Clean", "Open System Settings", "Scan Again".
- Name the real thing: "Full Disk Access Required". "Grant Full Disk Access in System Settings so the app can see these files."
- Spell out safety: "Items marked Risky are never removed by an action set." "Unsaved changes in this app will be lost."
- Progress uses the ellipsis character: "Scanning…", "Looking for support files…".
- App icon: a white glass feather tilted up to the right, with a small four-point sparkle at its upper left, on an automatic gradient of `--accent` (`App/Resources/AppIcon.icon`). There is no separate wordmark; set the name in plain type, and never redraw the feather in another color or add strokes to it.

## 9. Anti-patterns

- More than one primary button on a screen, or a primary button outside the bottom bar.
- Custom blurs, drop shadows, gradients, or glass on panels (glass is for floating controls).
- Module tints used for body text in light mode, or as large background fills.
- Status shown by color alone; red and green told apart without their words.
- Charts or dashboards where one big number answers the question.
- Hand-picked hex values in Swift instead of `ModuleTint` / `.moduleTint(_:)`.
- Fixed font sizes where a Dynamic Type style exists.
- Indigo-violet gradients or a second accent: `--accent` is close to Tailwind's default indigo, so keep it scarce and let the module tints carry identity.
- Marketing tone, exclamation marks, emoji, "we".
