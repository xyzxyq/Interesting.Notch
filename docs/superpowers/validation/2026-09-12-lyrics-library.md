# LyricsX-inspired lyric reliability

## Implementation

- Added `LyricsRepository` with local-first retrieval, concurrent LRCLIB/NetEase lookup, shared recording matching and cancellation. First independently matched result wins; pending work is cancelled. One provider's failure or one failed NetEase candidate does not discard successful candidates.
- Added versioned atomic JSON persistence in Application Support/InterestingNotch/Lyrics. File keys hash player, title, artist, album and rounded duration; stored identity and duration are checked again when loading. Automatic entries are rematched; explicit choices are recalled only for the associated track. Invalid or corrupt entries fall through to fetching. Plain-only cache entries cannot satisfy synchronized demand. Disk write failures do not discard playable lyrics and are surfaced in status.
- Added a settings sheet for keyword search, ranked candidates, lyric preview, explicit selection and UTF-8 LRC import. Selection persists and dismisses the sheet. A presentation item freezes the target song when opening; the manager also checks the target before applying, and cancels pending automatic work when accepting a choice. Import requires a usable timeline and a file no larger than 2 MB. The existing retry button explicitly bypasses the cache.
- Native-first plain lyrics behavior and the existing compact display/clock are retained. No new package dependency. NetEase request flow/field mapping adapted from LyricsKit v0.11.0; MPL notice, full license and source attribution included.

## Checks

`LyricsRepositoryChecks` passes disk reuse, corrupted data recovery, album/duration isolation, manual persistence, plain/synced separation, cached playback with network forbidden, provider outage recovery, a failed candidate alongside a valid candidate, and cancellation without persistence. The candidate-failure scenario failed before its corresponding fix. Existing `CompactLyricsChecks` passes matching, cancellation/retry, clock, pause/resume, seeking and timeline regressions.

Real Swift URLSession checks fetched 我怀念的 from NetEase (82 display segments), returned 11 manual candidates across LRCLIB and NetEase, and loaded the persisted result from another executable invocation whose transport always throws an offline error. No system network changes were used to simulate offline mode.

The first native sheet test exposed an empty initial presentation when optional content and a separate Boolean were updated together. Replaced it with item-driven sheet presentation and verified the first open after restart displayed the expected fields and candidates.

Native UI: current 同手同脚 / 林宜融 had ambiguous automatic results. Read current album 星光二班你们是我的星光 and duration 251.567 seconds, selected the corresponding 星光2班 你们是我的星光 / 林宜融 / 251-second candidate, and observed the sheet dismiss plus status 已记住选择 · 网易云. Read the saved entry back and confirmed manual=true. Imported a temporary UTF-8 LRC containing that same selected timeline through NSOpenPanel; observed automatic dismissal and status 已记住选择 · 导入 LRC. Closed settings and verified successive lyrics in the closed rocket using native accessibility and screenshot. No playback controls were changed. Cross-track application is guarded in both UI and manager; that race was reviewed, not exercised by forcing a live skip.

Final Debug build succeeded. Existing build warnings concern the MediaRemoteAdapter minimum macOS version and skipped App Intents extraction. Stable local certificate signing and designated-requirement comparison passed. Installed debug dylib SHA-256 equals the built product; installed/restarted /Users/zxy/Applications/InterestingNotch Development.app, PID 49086. git diff --check passed.

## Reproduction

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc boringNotch/models/CompactLyrics.swift boringNotch/models/LyricsRepository.swift scripts/LyricsRepositoryChecks.swift -o /tmp/lyrics-repository-checks
/tmp/lyrics-repository-checks
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc boringNotch/models/PlaybackState.swift boringNotch/models/CompactLyrics.swift scripts/CompactLyricsChecks.swift -o /tmp/compact-lyrics-checks
/tmp/compact-lyrics-checks
```

## Limits

Only LRCLIB and NetEase are integrated in this iteration; other LyricsX providers were not bundled. Upstream service availability and coverage are not guaranteed. Automatic selection uses the existing strict version gates, not LyricsX's looser similarity score. Manual candidates are ordered by individual match acceptance and duration difference. The cache relies on available metadata, not a catalog recording ID; indistinguishable metadata cannot identify different recordings. Timing remains line-based LRC, the existing offset setting remains global, and this change does not claim word-level karaoke timing or measured performance savings.
