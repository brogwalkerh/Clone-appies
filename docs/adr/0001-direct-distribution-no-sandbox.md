# 0001. Direct distribution, no App Sandbox

Status: Accepted
Date: 2026-10-13

## Context
The product must delete other apps' caches and containers, read all of
`~/Library`, enumerate and toggle launch agents, quit and force-quit arbitrary
processes, swallow input for Screen Cleaning Mode via `CGEventTap`, install a
root daemon, and (later) load an Endpoint Security extension. Roughly 70% of the
feature inventory in PLAN.md §3 is impossible inside the App Sandbox, and the
Mac App Store requires the sandbox. macOS 27 is Apple Silicon only, so there is
no Intel build to distribute either way.

## Decision
Ship the main app, menu agent and privileged helper **outside the Mac App
Store**, signed with a Developer ID certificate, with **Hardened Runtime
enabled and App Sandbox disabled**, notarized by Apple, and self-updated with
Sparkle 2. The only sandboxed target is the future Safari web extension,
because Safari requires it.

Hardened Runtime exceptions (`allow-jit`, `allow-unsigned-executable-memory`,
`disable-library-validation`, `allow-dyld-environment-variables`) stay **off**;
`automation.apple-events` is the one entitlement we add.

## Consequences
- Full Disk Access, Accessibility and Login Items approvals become explicit
  onboarding steps with deep links; permission state is re-checked at launch.
- We own the update channel (Sparkle appcast, EdDSA signing key) and the
  release pipeline (`release.yml`: sign, notarize, staple, DMG, appcast).
- Notarization is mandatory; any new entitlement or embedded binary must pass
  `spctl --assess` in CI before it reaches users.
- A future App Store "lite" edition would be a separate sandboxed target with a
  reduced feature set; nothing in Core may assume sandbox-only APIs.
