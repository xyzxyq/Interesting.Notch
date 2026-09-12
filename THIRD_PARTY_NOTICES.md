# LyricsX / LyricsKit acknowledgement

The local-first lyric workflow, multi-provider retrieval, manual candidate selection and persisted corrections were informed by [LyricsX](https://github.com/ddddxxx/LyricsX), inspected at commit `c16b6a413dda7bc0b793b897522e0c4ee0ffc716`.

`boringNotch/models/LyricsRepository.swift` adapts the NetEase search/download flow and response-field mapping from [ddddxxx/LyricsKit v0.11.0](https://github.com/ddddxxx/LyricsKit/blob/v0.11.0/Sources/LyricsService/Provider/NetEase.swift), commit `5506ee497ca689ed1686655ebb11e8ee29cc24cb`. That source is distributed under the Mozilla Public License 2.0. The adapted file retains its MPL notice; the complete license is in [LICENSES/MPL-2.0.txt](LICENSES/MPL-2.0.txt).

Adaptations use HTTPS and native Swift concurrency, retain this project's recording/version checks, independently handle provider failures, and add bounded response parsing, atomic local storage and explicit user selection. LyricsX/LyricsKit dependencies and their UI implementation are not bundled.

Lyrics remain the property of their respective rights holders. Cached/downloaded lyrics are runtime user data and are not included in this repository.
