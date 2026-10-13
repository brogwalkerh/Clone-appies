# 0005 — Minimum deployment target is macOS 26, not 27

Status: accepted (2026-10-13)

## Context
PLAN.md §2 proposed a macOS 27.0 deployment target with 26.0 as the fallback.
The first macOS CI run showed GitHub-hosted runners currently ship Xcode 26.6
with the macOS 26.5 SDK and no macOS 27 SDK. A 27.0 deployment target cannot
compile there, so the app target would stay unverified indefinitely.

Nothing in the M0/M1 code uses a macOS-27-only API. Liquid Glass, glass
buttons, `GlassEffectContainer`, App Intents, and the SwiftUI shell all exist
in macOS 26. The macOS 27 specifics that matter to us (standard corner radius,
glass transparency slider, text-only menus, Siri AI via App Intents) are either
system-side behaviors or conventions, not APIs we must link against.

## Decision
- `MACOSX_DEPLOYMENT_TARGET` and `LSMinimumSystemVersion` are **26.0**.
- Swift packages declare `.macOS("26.0")`.
- Any genuinely 27-only API is wrapped in `if #available(macOS 27, *)` with a
  26 fallback, and marked `// macOS27:` so they are easy to find.
- CI selects the newest installed Xcode; when a macOS 27 image appears the
  same spec builds against the 27 SDK without changes.

## Consequences
- The app runs on macOS 26 Tahoe as well, widening the audience at no cost.
- Code that targets a 27 feature must keep a 26 code path until the minimum is
  raised. Raising it later is a one-line change plus removing the guards.
- PLAN.md §2 and §9 should be read with this ADR in mind.
