# Lyrics pipeline audit

Reviewed AppleMusicController / NowPlayingController -> PlaybackState -> MusicManager -> CompactLyrics fetch, match, parse, timeline and phase -> compact Canvas rendering, expanded lyrics and settings. This review includes metadata readiness, identity changes, cancellation, retry, transport clocks, seeking/ending, and UI recovery.

## Confirmed defects fixed

- A transient 503 remained in the shared failure variable even after that request recovered with 404/200. It prevented subsequent script variants. Failure now belongs to each request; healthy responses allow spelling fallback. An injected 503 followed by no simplified matches and a valid traditional result failed before the fix and passes afterward.
- Timestamp-only playback diffs replaced the date without advancing the old position. Now the old playing state/rate advances the position to the new date. Older timestamp-only updates preserve the current anchor. Paused anchors stay stationary.
- Synchronized matching accepted nonempty timed text entirely outside the recording. It now requires a displayable timeline segment. Plain mode also rejects entirely empty candidates.
- A transport cancellation could retry even when the enclosing Task was not cancelled. It now exits immediately. Invalid response/decoding failures participate in the existing delayed recovery policy.

## State simplifications and recovery

- Removed the separate view-level finished latch. Animation pause now follows playback and sample position directly. This removes extra reset dependencies for seeking, repeat and duration corrections. Timeline boundary tests passed; not every native transport interaction was automated.
- Incomplete title/artist/duration now displays a metadata-wait state without contacting the provider. Readiness changes invalidate the same-track shortcut.
- Added a retry button beside lyrics status in Media settings. Actual UI test observed loading with a disabled button, then synchronized-ready with an enabled button. Settings was closed after verification.

## Protections reviewed and retained

- Track identity includes player, title, artist, album and duration tolerance, not artwork or playback progress.
- Source/toggle/track changes cancel requests and increment generation. Each asynchronous publication checks cancellation/generation. This is a code review of MusicManager guards; not an exhaustive scheduler simulation of every event interleaving.
- Matching retains artist/title/duration checks, album preference and ambiguity rejection. It does not guess artist aliases or choose arbitrary search results.
- Script queries remain deduplicated. A completely unavailable service exits before multiplying spelling attempts; existing bounded outage and cancellation checks pass.
- Explicit blank cues preserve instrumental gaps. Timelines use supplied timestamps, not guessed vocal duration from character count.

## Validation

CompactLyricsChecks passed: script conversion/search, recovered errors, album fallback, ambiguous/duplicate versions, invalid/empty candidates, incomplete metadata, bounded retries, cancellation, timestamps, pause/resume, offsets and ending boundaries. Full Debug build, whitespace and ad-hoc signature checks passed. Installed/restarted development app; loaded dylib and build UUID match.

Real production fetch still matched the previously failing 285-second recording with 81 time marks and 57 segments. Current native app loaded 28 time marks; screenshot/accessibility confirmed lyrics inside the rocket. Manual retry loaded 28 time marks again and returned to ready. Playback continued after closing settings. No user playback, network configuration or permission changes were required.

## Reproduce checks

From the repository root:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc boringNotch/models/PlaybackState.swift boringNotch/models/CompactLyrics.swift scripts/CompactLyricsChecks.swift -o /tmp/compact-lyrics-audit
/tmp/compact-lyrics-audit
```

## Limits

A provider can lack synchronized lyrics, contain ambiguous versions, or be unreachable. These remain explicit unavailable/no-match cases with status and recovery, not fabricated success. This audit does not promise permanent absence of all lyric issues, add another provider, or claim measured FPS.
