# State continuity and animation scheduling

## Changes

- Keep missing tasks and waiting-to-running changes for a two-second stabilization window, keyed by host/task identity. New waiting requests appear immediately. Normalize ordering and prefer waiting when duplicate samples disagree.
- Preserve task presentation across transport failures until five seconds since last success; show disconnected status immediately and then clear retained data. Avoid publishing unchanged connection state every poll.
- A temporary non-music/non-battery HUD suppresses the rocket; the existing transition resumes from current live state after the HUD disappears. Waiting priority, pending count and request list remain intact.
- Shared screen-sleep and power-mode notifications gate decorative timelines. Music capture stops for screen sleep. Flame/lines/reminder refresh is explicitly bounded at 60 Hz normally and 30 Hz in low-power mode; ambient waves 30 Hz, fuel 30/15 Hz. Hidden view timelines pause.
- Reminder bounce decays after 12 seconds into subtle bulb breathing; landing and return keyframes remain unchanged. Screen wake does not replay landing for an already-settled drop.
- Music phase now integrates exponential speed easing analytically instead of updating three SwiftUI state values each frame. Pause/resume preserves phase.

## Verification

- CodexNotchChecks passed: includes transient missing task, waiting-to-running debounce, expiry, duplicate waiting priority, reset, phase continuity and pause/resume, reminder settling, plus prior keyframe/shape/render checks.
- MusicEdgeChecks passed. Full Debug xcodebuild passed. git diff --check passed.
- Signed with existing local certificate, compared designated requirements, installed and restarted the stable development app. Running PID 27334 at validation; installed debug dylib SHA-1 matches built product (59d7ad905b74a986904461d4897c3b4963fdbba6).
- Live UI: enabled water-drop preview; closed settings; drop exposed the accessible request button; clicking opened the request panel; after preview expiration the panel reflected real running state. Closed panel after verification.

## Limits

No comparative CPU/GPU/energy or frame-time measurements are claimed. Physical media-key HUD overlap, screen sleep/wake and low-power-mode behavior have not been manually exercised in this run. Completion/failure classification is not inferred from an absent task; the bridge currently only supplies running/waiting tasks.

## Automatic request-panel dismissal

When enabled and connected, an empty stabilized pending list now dismisses the request panel; waiting-to-running preview does the same. Remaining requests keep it open. Disconnection alone does not report completion or dismiss it. Reconnection applies the fresh task list before publishing connected=true, preventing a stale empty list from hiding a real pending request. The existing waiting-driven liquid return animation is preserved.

Added six dismissal-policy checks; CodexNotchChecks and the final Debug build passed. Installed with unchanged signing identity. In the live app, opened the water-drop preview and request panel, clicked “预览恢复运行”, and observed the panel disappear without clicking its close button.

## Accumulating droplets and volume

Incoming pending requests queue a falling droplet and an impact deformation on the existing drop. All pending requests remain in the existing request panel. Preview controls exercise one, two and three requests; this was verified in the live request list. Count reductions cancel obsolete incoming animations. Reduced motion and screen suspension settle directly.

The merged drop now grows during absorption: two requests have 1.25 times the original linear size, three approximately 1.40 times; growth caps at 1.70 to stay inside the existing interaction area. Removal animates the size down. The bulb remains centered in the same canvas.

CodexNotchChecks passed with merge trajectory, absorption and bounded growth assertions. Inspected the five-frame rendered merge strip at /tmp/codex-merge-preview.png. Final Debug build passed. Installed with unchanged designated signing requirement, verified the installed debug dylib matches the build using SHA-256, and restarted the stable app (PID 34302). No measured frame-time or real approval submission is claimed.
