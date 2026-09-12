# Codex rocket and liquid attention drop

**Goal:** Show a black rocket while Codex executes and a liquid lightbulb drop when the user must act, preserving music waves.
**Architecture:** One animated NotchShape drives the shell and existing music contour. A local read-only bridge provides live activity; a Swift observable model polls it and clears stale state. Waiting requests open a native panel linking to the original task; approval transport is not assumed.
**Tech Stack:** SwiftUI Canvas/Shape, AppKit panel, existing music renderer, local bridge using installed runtime.
**Spec:** User-approved design in this task, including the additional liquid drop transition and fallback to original Codex approval UI.

## Constraints
- Keep the physical notch covered; no dependency changes or fabricated speed/strength metrics.
- Preserve music settings/phase, keyboard access and Reduce Motion.
- Waiting takes precedence across concurrent tasks. Disconnection is not completion.
- Only a user click opens task content. No automatic permissions or responses.

## Execution
- [x] Verify a live, session-independent Codex activity source and a safe sandbox-compatible transport. Add protocol checks for wait/run/idle and disconnect.
- [x] Extend NotchShape with animatable rocket progress; share it with MusicEdgeEffect. Add a separate bounded flame outside content, independent of music energy.
- [x] Add sequenced liquid drop and a keyboard-accessible pending-task panel. Add enabled/connection/demo controls to existing settings; never mix demo and live tasks.
- [x] Run model/shape checks, existing music checks and full xcodebuild. Render the production visual components for inspection and record limitations.
