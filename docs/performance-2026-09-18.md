# Performance and update validation — 2026-09-18

## Changes

- Native MediaRemote playback stops the fallback video timer. Video applications are
  enumerated on application launch/exit, rather than inspecting every app bundle
  every second. Fallback IO polling resumes when needed, with timer tolerance, and
  stops during screen sleep.
- Paused music controls stop animation timelines. The decorative spectrum uses
  Core Animation instead of recurring timer allocations. Face blinking is cancelled
  when its view disappears; day/night checks use the native minute schedule.
- Audio metering requests 16 kHz mono, processes samples at the effect's visual
  cadence, and publishes only changed levels/status. Multiple windows share capture
  demand and release it when the last consumer disappears. This changes the visual
  amplitude meter only, not Apple Music's output sample rate or sound quality.
- Avoid unchanged published media fields, repair repeated track transitions when
  artwork is shared, remove controller/stream retention, and decode artwork directly
  to a bitmap no larger than 512 pixels. The image test caught and eliminated Retina
  upsampling caused by `NSImage(cgImage:size:)`.
- The small Codex fuel indicator uses 12 FPS (6 in Low Power Mode), with its static
  SF Symbol outside the per-frame Canvas. Lyrics and main water animations retain
  their previous frame limits.

## Observed runtime samples

Installed Release 3.0.6 versus the modified Release build, same persisted settings,
only one main Interesting Notch process running during each sample. Codex/water
ambient effects were present; Apple Music was not playing. Each run used 12 `top`
iterations at one-second intervals, discarding the first iteration.

| Run | Mean process CPU | `top MEM` |
| --- | ---: | ---: |
| Installed build | 6.79% | 152 MB |
| Modified build, after settings window closed | 4.41% | 115 MB |

CPU samples before: 5.6, 6.7, 6.4, 6.5, 6.5, 9.4, 6.8, 6.5, 6.7, 7.0, 6.6.
CPU samples after: 3.4, 4.6, 4.3, 4.4, 4.4, 4.4, 4.6, 4.8, 4.8, 4.5, 4.3.

These are short observational samples, not a controlled energy benchmark. Restart,
uptime/cache differences and other system work limit memory/CPU attribution. They
must not be represented as Apple Music playback savings or measured battery/power
savings. The final artwork fix was made after these samples; no playback artwork
was present during the samples.

## Verification

Passed: Debug and Release builds, signed app launch, energy lifecycle checks,
large/corrupt artwork checks, music idle/source/video fallback checks, compact
lyrics and fetch/timing checks, music edge checks, permission-path and Chinese
localization checks. The energy checks exercise the production methods, including
multiple-window capture release, timer cancellation/restart, and spectrum stop/resume.

The signed release archive and generated feed passed signature validation both
through Sparkle and independently with CryptoKit against the configured public
key. A tampered archive was rejected. The DMG packaging flow verified its checksum,
mounted layout, app signature, and generated a signed `appcast.xml` alongside it.

Actual UI verification confirmed both update toggles, default checks on / automatic
installation off, disabling the installation toggle when checks are off, and an
enabled manual check button. Manual checking correctly reported an update-feed
error: the public v3.0.6 release currently has no `appcast.xml` asset. No release was
published by this task. See [automatic-updates.md](automatic-updates.md).

## Initial runtime coverage limits

The user primarily uses Apple Music. Music was launched but its window could not
be inspected by the computer-use service (`SCStreamErrorDomain -3811`, twice);
MediaRemote returned no current playback. Real-song play/pause/seek/track-change
CPU and meter checks therefore remain unverified, despite the reducer/timing and
lifecycle regression checks passing. No screen/audio permission was changed.

Next measurement: use one song and the same lyric/water/audio-response settings,
allow playback to stabilize, collect at least 60 seconds for playback and pause,
and compare the same Release configuration. A complete public-channel installation
and relaunch test requires a newer published release with its signed feed.

Implementation references: [Apple audio sample-rate support](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/samplerate),
[Sparkle publishing workflow](https://sparkle-project.org/documentation/publishing/).


## Apple Music Debug playback follow-up

The user started Apple Music. MediaRemote confirmed `com.apple.Music`,
`playing=true`, `playbackRate=1` before and after the Debug restart. Only the
Debug main app was running; an orphaned adapter from the previous Debug process
was terminated. The Apple Music process was left running.

A 10-second stack sample identified per-frame glyph measurement and invisible
star symbol drawing in the moon lyrics renderer. The follow-up caches the final
character width with each existing `PortalGlyph` and skips star rendering while
its opacity factor is zero. Animation timing, frame rate and visible effects are
unchanged.

The complete compact-lyrics executable checks passed, including cached/uncached
position equivalence for Chinese, whitespace, emoji and empty input. Four before
and after PNGs (moon lyrics, transitions, weather, sun/moon) were byte-identical.
The offscreen renderer reported median 0.146 ms / p95 0.247 ms before and median
0.100 ms / p95 0.160 ms after, from one run each; these are rendering checks, not
screen FPS or a controlled speedup benchmark. The updated Debug build and signed
launch passed.

Live CPU samples below use `top -l 61 -s 1` with the initial sample discarded.
Playback continued across different song positions/tracks, and restarting changes
cache state. These observations cannot establish a causal percentage saving.
Actual energy consumption was not measured. Real-player pause/seek/track-change
interaction checks and a controlled Release comparison remain outstanding.

| Debug playback | Samples | Mean CPU | Peak CPU | top MEM |
| --- | --- | --- | --- | --- |
| Before | 60 | 9.47% | 11.3% | 114–116 MB |
| After | 60 | 9.24% | 21.3% | 113–119 MB |
