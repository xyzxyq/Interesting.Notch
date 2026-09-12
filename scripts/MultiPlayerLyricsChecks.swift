import Foundation

@main struct MultiPlayerLyricsChecks {
    static func update(_ json: String) throws -> NowPlayingUpdate {
        try JSONDecoder().decode(NowPlayingUpdate.self, from: Data(json.utf8))
    }

    static func main() async throws {
        let date = Date(timeIntervalSince1970: 120)
        var state = PlaybackState(bundleIdentifier: "com.apple.Music")
        state.title = "Previous song"
        state.artist = "Previous artist"
        state.album = "Previous album"
        state.currentTime = 90
        state.lastUpdated = Date(timeIntervalSince1970: 100)
        state.isPlaying = true
        state.artwork = Data([1, 2, 3])
        // A source-only diff must clear the old identity, clock and artwork.
        state = state.applying(try update(#"{"diff":true,"payload":{"bundleIdentifier":"com.netease.163music"}}"#), now: date)
        assert(state.bundleIdentifier == "com.netease.163music")
        assert(state.title.isEmpty && state.artist.isEmpty && state.album.isEmpty)
        assert(state.currentTime == 0 && state.duration == 0 && !state.isPlaying && state.artwork == nil)
        // Actual NetEase 3.1.9 payload shape: zero elapsed anchored to track start.
        state = state.applying(try update(#"{"diff":false,"payload":{"bundleIdentifier":"com.netease.163music","title":"遇见","artist":"孙燕姿","album":"The Moment","duration":209.81553125,"elapsedTime":0,"timestamp":"1970-01-01T00:01:40Z","playing":true,"playbackRate":1}}"#), now: date)
        assert(state.currentTime == 0 && state.lastUpdated.timeIntervalSince1970 == 100)
        let exited = state.endingPlayback(now: date)
        assert(exited.bundleIdentifier.isEmpty && !exited.isPlaying && exited.playbackRate == 0)
        assert(exited.currentTime == 20 && exited.title == "遇见", "Exit freezes the last render state")
        let empty = state.applying(try update(#"{"diff":false,"payload":{}}"#), now: date)
        assert(empty.bundleIdentifier.isEmpty && !empty.isPlaying, "Empty full update ends the source")
        let paused = state.applying(try update(#"{"diff":true,"payload":{"playing":false}}"#), now: date)
        assert(paused.currentTime == 20 && !paused.isPlaying && paused.title == "遇见")
        let resumed = paused.applying(try update(#"{"diff":true,"payload":{"playing":true}}"#), now: date.addingTimeInterval(10))
        assert(resumed.currentTime == 20 && resumed.lastUpdated == date.addingTimeInterval(10))
        let sought = resumed.applying(try update(#"{"diff":true,"payload":{"elapsedTime":60}}"#), now: date.addingTimeInterval(15))
        assert(sought.currentTime == 60 && sought.title == "遇见")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LyricsStore(directory: root)
        let candidate = LyricCandidate(trackName: "Song", artistName: "Artist", albumName: "Album", duration: 180,
                                       plainLyrics: nil, syncedLyrics: "[00:10]First\n[00:20]Second", source: "Check")
        // These are synthetic provider identities, not a claim of client verification.
        for source in ["com.apple.Music", "com.netease.163music", "com.tencent.QQMusic", "test.kugou", "test.other-player"] {
            let track = LyricTrack(bundleID: source, title: "Song", artist: "Artist", album: "Album", duration: 180)
            assert(CompactLyrics.match([candidate], track: track) == candidate)
            assert(store.load(track, requireSynced: true) == nil, "Manual choices must not leak across players")
            try store.save(candidate, for: track, manual: true)
            let result = try await LyricsRepository.fetch(track, store: store, transport: { _ in throw URLError(.notConnectedToInternet) })
            let cues = CompactLyrics.timeline(CompactLyrics.parseLRC(result!.candidate.syncedLyrics!), duration: track.duration)
            assert(CompactLyrics.phase(at: 15, cues: cues, duration: 180) == .lyrics(cues[0]))
        }
        // The view, automatic fetch and manual publication must all use the same preference.
        let ui = try String(contentsOfFile: "boringNotch/ContentView.swift", encoding: .utf8)
        let manager = try String(contentsOfFile: "boringNotch/managers/MusicManager.swift", encoding: .utf8)
        assert(!ui.contains("enableCompactLyrics &&"))
        assert(!manager.contains("Defaults[.enableCompactLyrics] &&"))
        print("Multi-player checks passed: source changes, pause/resume/seek, NetEase clock, provider-independent lyrics and isolated cache")
    }
}
