# Lyrics recovery: romanized artists and lyric-quoted subtitles

## Live diagnosis

The installed app had compact lyrics enabled, a valid playing Apple Music track, and a settings status of no matching synchronized lyrics. The first reported track was 我怀念的 / 孙燕姿 / 逆光, duration 289.114 seconds. LRCLIB searches with either simplified or traditional Chinese artist metadata returned zero candidates. Title-only search returned the synchronized recording indexed as Yanzi Sun / 逆光, 289.134875 seconds. This failure occurred before rendering and did not come from the droplet animation.

During diagnosis playback advanced to 海屿你(求你别离开我) / 马也_Crabbit / 海屿你(求你别离开我) - Single, 296.022 seconds. The source has a synchronized record under 海屿你 / 馬也_Crabbit / 海屿你 - Single, 295 seconds. The full parenthetical subtitle appears in a timed lyric line. These are two independently reproduced metadata lookup failures.

## Scoped fix

- After normal get/artist search attempts, permit title-only discovery. All candidates still pass matching; healthy exact responses preserve the fast path, and complete service outages do not add discovery requests.
- Prefer exact artist names. A Chinese name of two to four Han characters can alternatively match direct Latin pinyin or surname-last spelling only with matching album and duration. Different Han names remain distinct. This is not an unrestricted artist alias table; stage names and non-pinyin spellings are not guessed.
- A four-to-twenty-character Chinese parenthetical phrase may be searched under the base title, but acceptance requires the exact artist, duration tolerance, matching single titles (allowing the Single/EP release label), and the entire subtitle in a synchronized lyric line. Other version labels are not blindly removed.
- Conflicting eligible timelines remain rejected. Existing generation/cancellation, source/toggle invalidation, retry, LRC parsing and timeline behavior are unchanged.

## Validation

Each new failure was reproduced in the existing runnable CompactLyricsChecks before its corresponding production change. Both failed at the intended result assertion, then passed after the fix. Added rejection cases for different artist, different Chinese name with identical pinyin, wrong/missing album, wrong duration, Live/version labels, conflicting timelines and unrelated subtitle text. Existing outage, cancellation, simplified/traditional spelling, playback clock, pause/resume, seek and ending checks passed.

Production URLSession fetch results:

| Track | Timed marks | Display segments |
| --- | ---: | ---: |
| 我怀念的 | 45 | 42 |
| 海屿你(求你别离开我) | 49 | 48 |
| 人间 | 81 | 57 |
| 苏州河 | 34 | 33 |

Final Debug xcodebuild succeeded and git diff --check passed. Signed using the existing development certificate; verified unchanged designated requirement and installed/build debug dylib SHA-256 equality. Restarted /Users/zxy/Applications/InterestingNotch Development.app, PID 40950.

Native UI verification after installation: Apple Music had naturally advanced to 我好想你. Accessibility exposed successive lyric lines in the closed notch. Opened/closed the notch and captured the closed rocket with visible lyric text at its right side. The reported two tracks were validated through the production fetch and timeline functions; playback was not rewound to replay them. The previous clock/seek checks are automated checks, not a claim that every native transport interaction was manually exercised today.

## Reproduction

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc boringNotch/models/PlaybackState.swift boringNotch/models/CompactLyrics.swift scripts/CompactLyricsChecks.swift -o /tmp/compact-lyrics-checks
/tmp/compact-lyrics-checks
```

Source coverage and network availability remain external limits. No universal lyric coverage, arbitrary alias equivalence, or permanent absence of future defects is claimed. No dependency, network setting or permission was changed by this fix.
