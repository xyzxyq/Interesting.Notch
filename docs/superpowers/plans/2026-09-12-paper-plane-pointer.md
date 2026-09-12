# Paper Plane Pointer Implementation Plan

> **For agentic workers:** Execute in this task using superpowers:executing-plans. Check off each verified deliverable.

**Goal:** Add an opt-in black paper-plane pointer, preserving text and resize cursor behavior.

**Architecture:** Register only the existing ordinary-arrow names with the WindowServer, using dynamically resolved cursor APIs. Save originals before mutation, verify registration, and restore on disable/quit; preserve a recovery journal across abnormal termination. No mouse tracking overlay, polling, permission prompt, or new dependency.

**Tech Stack:** Swift, AppKit/CoreGraphics, SwiftUI, existing settings and app lifecycle.

**Spec:** User-approved design in the current task: black Telegram-like folded silhouette, subtle light outline/shadow, fixed direction and tip hotspot, Appearance toggle default off, cross-app feasibility and restoration verification before delivery.

## Global Constraints

- macOS deployment target 14.0; verify on this host's macOS 26.6.2.
- Keep text selection, link, drag badges and resize cursors intact.
- Missing APIs, unreadable originals or a failed backup must prevent activation.
- Private APIs are experimental: disclose support limits; do not claim all apps/OS versions tested.
- Do not remove sandboxing, add a daemon, or install another cursor manager.

## Deliverables

- [x] Implement artwork and reversible arrow registration in `boringNotch/managers/PaperPlanePointer.swift`; use an atomic recovery journal and read-back verification. Add standalone `scripts/PaperPlanePointerChecks.swift` for image geometry, backup/recovery and real registration/restore.
- [x] Connect `PaperPlanePointerManager.shared.start()` / `.stop()` to app lifecycle and a preview/toggle/status section in Appearance. Register the new file in the Xcode project.
- [x] Run standalone checks, independent-process verification and full Xcode build; inspect the rendered artwork.
- [ ] Manual visual acceptance across app windows and physical multiple displays. Native UI capture failed with ScreenCaptureKit error -3812; do not treat registry read-back as visual acceptance.

## Validation commands

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc boringNotch/managers/PaperPlanePointer.swift scripts/PaperPlanePointerChecks.swift -o /tmp/interestingnotch-pointer/checks
/tmp/interestingnotch-pointer/checks
/tmp/interestingnotch-pointer/checks --live
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -configuration Debug -derivedDataPath /tmp/interesting-notch-main-build CODE_SIGNING_ALLOWED=NO build
```

## Verified results

- Full Xcode Debug build passed; no warnings in PaperPlanePointer.swift after Sendable correction.
- Standalone checks passed for artwork/hotspot, serialization, failed backup, alias batching, partial rollback, repeated enable, foreign-theme preservation and retry after a failed restore.
- Real WindowServer registration and restoration passed on macOS 26.6.2, including a probe signed with the app sandbox entitlements. A separate process read both installed arrow aliases at 32 × 32 points, hotspot (4, 3), with four representations; originals returned to 28 × 40 points, hotspot (4, 2).
- Text, contextual-menu and copy-drag image snapshots remained unchanged in the live check.
- The runtime probe completed and restored originals. The existing running project app was left running; the new feature is default off.
- Locally signed preview: `/Users/zxy/Applications/InterestingNotch Pointer Preview.app`. Private API compatibility and visual behavior in individual applications still require hands-on acceptance; no claim of exhaustive OS, display, lock/sleep or fullscreen testing.

## Dock-only rendering diagnosis

The user reproduced Dock-only replacement. Live preferences showed `cursorIsCustomized = 1`, black fill and gray outline (~0.37056 RGB). The registry contained the plane while `NSCursor.currentSystem` still returned the original 28 × 40 arrow in an ordinary app. Mousecape's source README documents the same conflict: https://github.com/sdmj76/Mousecape-swiftUI#troubleshooting .

Added a read-only compatibility check (verified readable in the sandbox), activation guard with restoration, explanatory settings link, and change/activation notification checks. Added regression tests for blocking activation before registration and restoring an already-applied theme when colors become customized. System color changes are separate from theme registration and require the user's decision; original color and size values were backed up without modifying them.

After explicit user authorization, reset pointer colors through System Settings. Read-back confirmed `cursorIsCustomized = 0`, white outline and black fill, with pointer size unchanged at `1.519003391265869`. Rebuilt, signed, installed and restarted the preview. After moving the pointer into an ordinary window, an independent `NSCursor.currentSystem` probe reported the 32 × 32 image and hotspot (4, 3), with ChatGPT frontmost; inspection of its exported PNG confirmed the paper-plane artwork. This verifies actual cursor selection outside Dock on this host. Physical multi-display, fullscreen and lock/sleep acceptance remain unverified.
