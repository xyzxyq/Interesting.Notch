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


## Async question detection repair

Live IPC showed async choice prompts as `agentMessage` items with `delivery=async`, while `threadRuntimeStatus.activeFlags` remained empty. Added a privacy-filtered projection of question IDs and acknowledged reply IDs from both `turns` and paged `turnHistory`, with incremental patch handling. Unanswered async questions now produce waiting status even when the turn is idle; only accepted steering replies clear them. No question or answer prose is retained in bridge state or exposed by HTTP.

Verified Python regression checks for async snapshots, accepted/rejected acknowledgement state, removals and text exclusion, alongside existing IPC and quota checks. Updated the existing LaunchAgent. Live HTTP returned waiting for this task, app Settings showed two pending tasks, and native screenshot/AX inspection confirmed the actual lightbulb droplet with a count of 2 (no preview mode). Earlier unanswered questions remain pending until answered.


## Per-question reminders and dissolve

The request panel's action opens the original Codex task; it is not an answer submission. Implemented acknowledgement-based removal: bridge publishes unanswered question IDs and the app expands each into a separate reminder identity. Multiple questions in one task now decrement individually. Only confirmed replies resolve questions; opening a task does not.

Added a bounded 216-tile content dissolve shared by rows, the borderless request panel, and the lightbulb droplet. Removed rows remain rendered during the 0.65-second dissolve; final panel closure waits for animation completion. Reduced Motion uses opacity instead. New arrivals cancel pending panel closure. Tests passed: Python IPC/async and two-to-one decrement, Swift Codex checks, `CodexDissolveChecks.swift` rendered coverage at 0/0.5/1, full Debug build and signing. Updated bridge and app; live AX showed three unanswered questions rather than two tasks. Live answer submission and full sequence still require user acceptance.

Dissolve render check: extract `struct CodexDissolve` through end of `CodexNotchEffect.swift` into a temporary Swift file prefixed with `import SwiftUI`, then compile it together with `scripts/CodexDissolveChecks.swift` using `xcrun swiftc` and run the executable.


## Click-to-read, anchored panel, and clear-all

User explicitly chose local read acknowledgement: successfully opening a task marks only that reminder identity read; failed navigation retains it. Read identities are saved so polling/relaunch does not re-add cleared async questions. This clears local notifications only, never submits an answer or approval to Codex.

The panel now expands down from the clicked droplet with a spring and fades the original droplet during expansion. Explicit 收起 reverses expansion without clearing reminders; 清空 marks all current reminders read and starts the shared particle dissolve. Escape also collapses. Losing key focus no longer dismisses the panel before a clicked row can dissolve. Reduced Motion disables expansion scaling.

Verified full Debug build/signing, Swift reminder filtering checks, and live UI: three reminders -> collapse still three -> reopen and click one task -> two -> clear -> panel and droplet absent. Subsequent polling retained the cleared state. Installed at the existing Pointer Preview app path.


## Direct async answers (supersedes click-to-read behavior)

The user clarified that the panel must submit answers directly. The bridge now retains pending question titles/options (superseding earlier text-exclusion claims), accepts token-protected local POST replies, and routes them to the owning task through Codex IPC. Rows remain pending until Codex publishes an accepted acknowledgement; navigation no longer marks them read. Freeform input supports Return. Clear remains local notification dismissal; collapse preserves questions. Approval requests without async question data retain a Codex fallback.

Python checks cover question projection, acknowledgement, duplicate and stale rejection, reply binding and answer-text exclusion. Debug build succeeded and the installed preview was updated. Live panel displayed question text/options/input. Collapse was verified by native UI: the panel disappeared and the waterdrop returned with all 3 remaining reminders. Live freeform Return submission subsequently passed: the dedicated neutral test answer arrived in the active Codex conversation, the remaining visible reminder disappeared, and the panel closed. Fixed missing restoreMessage.context and omitted unsupported array-valued additionalContext after inspecting actual IPC rejections. Added regression assertions. Separated collapse at the top from clear at the bottom after live defaults confirmed all reminders had been locally cleared.


## Continuous droplet-to-panel contour

Replaced separate drop/shell opacity handoff with a single opaque contour in the request panel. Cached corresponding perimeter samples morph the teardrop into the rounded panel; text and the bulb crossfade inside the silhouette. The original drop is hidden only while the panel owns presentation, then restored after collapse completion. A first-frame wait ensures the initial droplet is rendered before expansion. Debug build, signing verification, and image coverage checks at 0/0.25/0.5/1 passed. Installed preview updated; subjective continuity awaits the user test.


## Particle transition replaces contour morph

Per user request, removed contour morph and dual-window handoff logic. Opening dissolves the original droplet (0.4 s), then reverses the existing particle modifier to assemble the panel below it (0.55 s). Closing dissolves the panel first and then reassembles the droplet. Transitions disable panel actions and guard repeated clicks. Poll updates no longer overwrite an in-progress particle phase; actual question resolution still cancels the presentation sequence. Hidden panels remain fully dissolved to avoid a flash on reopening. Particle image checks, Codex checks, Debug build and signing passed.


## Panel-only particles and reversed droplet birth

Updated per latest request: panel opening assembles particles directly while the droplet stays visible; closing dissolves only the panel. Removed external drop dissolve state and the extra stage delays. When waiting ends, the droplet now runs the exact reversed birth keyframes and durations instead of particle dissolution. Regression samples at 10 ms intervals verify reverse position and surface values match forward samples at complementary timestamps (tolerance 0.00001). Swift checks, Debug build, signing and diff whitespace checks passed; updated installed preview.


## Growing multiline answer field

Reused native vertical-axis TextField with a one-line minimum and unconstrained vertical growth inside the existing scroll view. Send button aligns to the bottom. Debug build and signing passed; live screenshot confirmed three explicit lines expand the field. Return submitted all three lines intact to the original Codex question (confirmed by the delivered answer). Installed preview updated.


## Execution independent of async reminders

Root cause: pending async questions overrode runtime as waiting, and Swift also suppressed running whenever any reminder was pending. Added separate isRunning projection from raw runtime (active with no blocking approval/input flags), decoded with legacy fallback. Running presentation and effort now use that field independently of pending reminders. Regression checks cover active-with-questions, idle-with-questions, and blocking approval; Python and Swift checks plus Debug build/signing passed. Live bridge reported this task waiting+isRunning=true and another waiting+false. Installed preview's native screenshot showed rocket nose and orange exhaust during this real running turn with music present.


## HUD accessibility entry

Reproduced Request Accessibility with no visible change. Shared explicit permission request now opens System Settings Privacy_Accessibility when trust remains false, covering suppressed repeat TCC prompts. HUD labels the action and explains the next step. Debug build/signing/diff checks passed; installed app button opened the correct system permission pane. Live state: interesting botch.app toggle was already on, but the running app remained untrusted. Permission reauthorization and actual HUD interception remain unverified; no TCC toggles were changed by the agent.
