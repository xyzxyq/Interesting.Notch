# Codex rocket and liquid attention drop — 2026-09-12

Implemented on `feature/codex-rocket-drop`.

- Shared animated NotchShape drives the black shell and music waves. Flame is independent from music; no invented token-rate, model-strength or fast-mode metrics.
- Waiting takes precedence over running tasks. Shell returns to the original notch, a stretched liquid neck separates into a black lightbulb drop, and clicking opens a keyboard-accessible native panel. Esc or losing focus dismisses the panel without resolving the request. Read-back of live status controls disappearance/resumption.
- Panel opens `codex://threads/<UUID>` for approval/input in Codex. The bridge intentionally exposes UUID/host and generic status only; it does not transmit conversation text or provide a write/approval API.
- Settings → Media contains the enable switch, live connection status and clearly labeled 20-second rocket/drop previews. Preview never submits a response or opens a fabricated task.
- Reduce Motion suppresses flame movement and liquid stretching; the shared music renderer retains its existing reduced-motion behavior.

## Bridge and limits

`python3 scripts/codex-notch-bridge-install.py` installs the current user's LaunchAgent `local.interestingnotch.codex-bridge`. It uses a persistent copy in `~/Library/Application Support/InterestingNotch/CodexBridge`, independent from this session and the external project volume. Remove the service with the same command plus `--uninstall`.

The read-only endpoint is `http://127.0.0.1:19427/state`. Browser Origin and incorrect Host headers are rejected; no CORS or write routes exist. The bridge reads Codex's local IPC stream version 11, retaining only runtime status. `waitingOnApproval` and `waitingOnUserInput` are verified installed-source flags. Recent 100 unarchived local IDs bootstrap discovery; actual live owner snapshots, not database recency, determine activity. Runtime broadcasts discover additional hosts/tasks. Private IPC and state DB schema can change with Codex updates; unsupported streams fail closed. Arbitrary assistant prose asking for confirmation without a structured waiting flag cannot be reliably detected. Remote tasks not advertised to this desktop connection are not guaranteed to appear.

Router heartbeat and active snapshot refresh run every 15 seconds; active owners stale for 45 seconds are treated as unavailable. Swift rejects old/future timestamps and invalid UUIDs. Disconnect never reports task completion.

## Verification

- Full Debug xcodebuild succeeded with `/Applications/Xcode.app/Contents/Developer`, derived data `/tmp/interesting-notch-rocket-build`, existing packages `/tmp/interesting-notch-baseline/SourcePackages`; no new dependencies.
- `scripts/test_codex_notch_bridge.py`: fragmented IPC frames, approval/user-input/resume/completion, revision gaps, status removal, owner disconnect, reconnect, unsupported version and stale-state handling passed. HTTP endpoint Host/Origin/path checks and live heartbeat refresh passed.
- `scripts/CodexNotchChecks.swift`: stale/future timestamp rejection, deep-link validation and physical center coverage throughout shape interpolation passed. Production SwiftUI view static rendering inspected below.
- Existing MusicEdgeChecks passed: audio attack/release, invalid audio, contour wrap, seven styles, three palettes, interior mask and Reduce Motion.
- Native UI checked after installation: real task running → rocket visible; water and lyrics retained; waiting preview → detached drop visible; click → native panel visible and focused; 20-second preview expiry → real running state; Esc → closes panel and real rocket remains. Actual approval request was not generated or approved for testing; waiting events tested through protocol fixtures and explicitly labeled UI preview.
- Current settings report that system audio capture is unavailable. Existing visual water/lyrics are verified; live audio-amplitude reactivity is not verified in this run. No screen/audio permissions were changed.
- Ad-hoc signature verified with `codesign --verify --deep --strict`; preserved the existing development bundle's no-entitlements signing setup. Installed `/Users/zxy/Applications/InterestingNotch Development.app`; prior bundle retained at `/Users/zxy/Applications/InterestingNotch Development.before-rocket-20260912-102922.app`.

## Reproduce

From the repository root:

```sh
python3 scripts/test_codex_notch_bridge.py
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc -swift-version 5 -D EDGE_CHECKS boringNotch/components/Notch/NotchShape.swift boringNotch/components/Notch/MusicEdgeEffect.swift boringNotch/components/Notch/CodexNotchEffect.swift boringNotch/managers/CodexActivity.swift scripts/CodexNotchChecks.swift -o /tmp/codex-notch-checks
/tmp/codex-notch-checks
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc -swift-version 5 -D EDGE_CHECKS boringNotch/managers/MusicEdgeAudio.swift boringNotch/components/Notch/NotchShape.swift boringNotch/components/Notch/MusicEdgeEffect.swift scripts/MusicEdgeChecks.swift -o /tmp/music-edge-checks
/tmp/music-edge-checks
```

This image is a static rendering of production views, not a live desktop screenshot:

![Rocket contour and liquid drop](/Volumes/MySSD/PROJECT/InterestingNotch/Interesting.Notch/docs/superpowers/validation/2026-09-12-codex-rocket-drop.png)

## Liquid motion refinement

- The original drop clamped its animated progress before calculating position, suppressing spring overshoot. Position now allows travel beyond the rest point; explicit decreasing rebound keyframes produce exactly two bounces (first lift about 13 pt, second about 4 pt).
- Added a shared animatable bottom-center liquid bulge to NotchShape. Shell and music contour both follow the same 0–8 pt displacement without uncovering the physical notch. Detachment and absorption each generate diminishing surface recoil.
- Return sequence includes a short anticipation dip, upward suction, neck fusion and surface settling over 0.85 seconds. Rocket appearance waits for that sequence. Interrupted tasks cancel pending keyframes; Reduce Motion uses static position/fade without surface motion.
- Full Debug build, two-rebound/settled-endpoint/liquid-coverage checks, existing Codex checks and MusicEdgeChecks passed. Updated signed development app; backup: `/Users/zxy/Applications/InterestingNotch Development.before-liquid-20260912-103559.app`.
- Native capture failed with ScreenCaptureKit error -3811 during this refinement, so live animation was not visually reverified. No system capture permissions changed.

## Continuous motion correction

User reported stiffness after the liquid refinement. Confirmed running binary had the updated debug dylib (different UUID from pre-liquid backup), so restart was not the cause. Replaced sequential ease-in/ease-out animations, which stopped velocity at every node, with elapsed-time monotone Hermite sampling. Added a numerical velocity-continuity test and a nonzero descent velocity assertion at the first stretch node. Both pass with existing geometry/state checks; full Debug build passed.

Added stretch/compression deformation and a fading neck before detachment. Lightbulb visibility now latches on after detachment rather than following bounce height, eliminating rebound-induced fading. Installed and restarted process 72282; installed and built debug dylib UUIDs match 3BA171FF-1097-3644-B8E7-2D1432014B98. Native capture recovered; preview shows the deformed lower contour, detached lightbulb and accessible click target. A still capture validates appearance only, not perceived temporal smoothness.

## Settled attention reminder

Added a settled-only reminder loop: lightbulb and ring brightness breathe between 0.44 and 1 over 2.8 seconds; the whole drop floats upward by up to 3 pt and back over 3.6 seconds. Both begin at the resting position with zero velocity after the two landing rebounds. Movement and brightness use the existing task lifecycle, cancelled on waiting-state changes; Reduce Motion keeps the indicator static. Before suction, the hover displacement is converted into the existing motion progress so return starts at the visible position. The stable button hit region remains available throughout.

Full Debug build and Codex checks passed, including reminder bounds/periods over 36 simulated seconds and previous continuous-velocity/two-bounce/coverage checks. Signed development app updated and restarted; backup is `InterestingNotch Development.before-reminder-20260912-104310.app`. Runtime process and installed/built debug dylib identity checked. No claim of a new real approval event or timed live visual recording.

Restart verification caught old PID 72282 retaining the backup dylib despite SIGTERM. Explicitly terminated only that development process after verifying its executable path, relaunched, and confirmed new PID 74328 maps the current development app's debug dylib (not the backup). This is the verified running reminder build.

## Reminder cadence and compact rocket

Replaced the settled reminder's 33ms Task.sleep loop (~30Hz) with SwiftUI TimelineView(.animation) without a fixed minimum interval. Hover offset and lightbulb brightness sample the same timeline frame. Timeline pauses outside settled waiting and under Reduce Motion. Return computes its starting offset from the same reminder function. This removes the explicit 30Hz ceiling; no measured display FPS is claimed.

Rocket nose extension reduced from 0.8H to 0.45H; tail from 0.5H to 0.28H (combined exterior length reduced ~44%). Flame reduced from base 1.4H to 0.85H and nozzle moved to match the shortened tail. Physical center and existing music content retained. Updated contour extent assertions, complete Codex checks, MusicEdgeChecks and Debug build passed; compact production render inspected. Development app replaced and restarted with old process exit ensured; installed/built debug dylib UUID and current mapped path checked.

## Shared drop drawing and interior rocket silhouette

User still perceived bulb lag and unused content-side margins. Moved bulb and ring from separate SwiftUI overlays into the drop's Canvas symbols/draw pass; body, ring and bulb now share the exact cy including hover offset. Removed independent symbol animation and whole-view hover offset. Breathing brightness remains a Canvas drawing opacity, so it cannot interpolate the glyph's position independently.

Remapped rocket geometry inside the original layout rectangle, using the pre-existing horizontal padding for the nose and tail rather than extending outside it. Nozzle uses the same mapping. Bounding-box tests now require the rocket to occupy exactly the original rectangle width; physical center coverage and previous motion checks pass. Full build and MusicEdgeChecks pass. Static production preview inspected; real app screenshot confirms compact rocket and retained album/lyrics. App updated/restarted and mapped current dylib checked. No measured frame-rate claim.
