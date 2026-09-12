import Foundation

@main struct LyricsRepositoryChecks {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LyricsStore(directory: root)
        let chineseTrack = LyricTrack(bundleID: "com.netease.163music", title: "后来", artist: "刘若英", album: "祝你幸福", duration: 339)
        let pinyin = LyricCandidate(trackName: "后来", artistName: "刘若英", albumName: "祝你幸福", duration: 339,
            plainLyrics: nil, syncedLyrics: "[00:13]hòu lái wǒ zǒng suàn xué huì le rú hé qù ài\n[00:20]kě xī nǐ zǎo yǐ yuǎn qù xiāo shī zài rén hǎi")
        let hanzi = LyricCandidate(trackName: "后来", artistName: "刘若英", albumName: "祝你幸福", duration: 339,
            plainLyrics: nil, syncedLyrics: "[00:13]後來 我總算學會了如何去愛\n[00:20]可惜你早已遠去消失在人海")
        assert(CompactLyrics.match([pinyin, hanzi], track: chineseTrack) == hanzi)
        try store.save(pinyin, for: chineseTrack, manual: false)
        assert(store.load(chineseTrack, requireSynced: true) == nil, "Old automatic pinyin cache must be re-fetched")
        try store.save(pinyin, for: chineseTrack, manual: true)
        assert(store.load(chineseTrack, requireSynced: true) == pinyin, "Keep explicit user choices")
        try store.remove(chineseTrack)
        let english = LyricCandidate(trackName: "后来", artistName: "刘若英", albumName: "祝你幸福", duration: 339,
            plainLyrics: nil, syncedLyrics: "[00:13]Yesterday all my troubles seemed so far away now it looks as though they are here to stay")
        assert(!CompactLyrics.hasExpectedScript(english, track: chineseTrack), "Unknown Latin version of Chinese metadata needs manual selection")
        assert(CompactLyrics.hasExpectedScript(hanzi, track: chineseTrack))
        let unmarked = LyricCandidate(trackName: "后来", artistName: "刘若英", albumName: "祝你幸福", duration: 339,
            plainLyrics: nil, syncedLyrics: "[00:00]作词：施人诚\n[00:01]作曲：玉城千春\n[00:13]hou lai wo zong suan xue hui le ru he qu ai\n[00:20]ke xi ni zao yi yuan qu")
        assert(!CompactLyrics.hasExpectedScript(unmarked, track: chineseTrack), "Credits must not validate unmarked pinyin")
        var local = hanzi; local.source = "网易云"
        var remote = hanzi; remote.source = "LRCLIB"
        assert(LyricsRepository.preferred([remote, local], track: chineseTrack) == local)
        assert(LyricsRepository.preferred([local, remote], track: chineseTrack) == local)
        let englishTrack = LyricTrack(bundleID: "player", title: "Yesterday", artist: "The Beatles", album: "Help", duration: 339)
        assert(CompactLyrics.hasExpectedScript(english, track: englishTrack), "English songs keep their original script")
        let track = LyricTrack(bundleID: "com.apple.Music", title: "Song", artist: "Singer", album: "Album", duration: 180)
        let cue = LyricCandidate(trackName: "Song", artistName: "Singer", albumName: "Album", duration: 180,
                                 plainLyrics: nil, syncedLyrics: "[00:01]Test", source: "Test")
        try store.save(cue, for: track, manual: false)
        assert(store.load(track, requireSynced: true) == cue)
        let savedFile = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first!
        var legacy = try JSONSerialization.jsonObject(with: Data(contentsOf: savedFile)) as! [String: Any]
        legacy["version"] = 1
        try JSONSerialization.data(withJSONObject: legacy).write(to: savedFile)
        assert(store.load(track, requireSynced: true) == nil, "Old automatic selection policy must be invalidated")
        legacy["manual"] = true
        try JSONSerialization.data(withJSONObject: legacy).write(to: savedFile)
        assert(store.load(track, requireSynced: true) == cue, "Legacy manual selections must survive migration")
        try Data("broken cache".utf8).write(to: savedFile)
        assert(store.load(track, requireSynced: true) == nil, "Corrupt cache must recover through fetching")
        try store.save(cue, for: track, manual: false)
        let other = LyricTrack(bundleID: track.bundleID, title: track.title, artist: track.artist, album: "Live", duration: 180)
        assert(store.load(other, requireSynced: true) == nil)
        let differentDuration = LyricTrack(bundleID: track.bundleID, title: track.title, artist: track.artist, album: track.album, duration: 185)
        assert(store.load(differentDuration, requireSynced: true) == nil)
        let cached = try await LyricsRepository.fetch(track, store: store, transport: { _ in
            assertionFailure("A cached song must work without network access")
            throw URLError(.notConnectedToInternet)
        })
        assert(cached?.cached == true)
        let custom = LyricCandidate(trackName: "User selected", artistName: "Alias", albumName: nil, duration: 180,
                                    plainLyrics: nil, syncedLyrics: "[00:02]Selected", source: "Import")
        try store.save(custom, for: track, manual: true)
        assert(store.load(track, requireSynced: true) == custom, "Remember explicit user choices")
        try store.remove(track)
        assert(store.load(track, requireSynced: true) == nil)
        let empty = LyricCandidate(trackName: track.title, artistName: track.artist, albumName: track.album, duration: 180,
                                  plainLyrics: "Plain only", syncedLyrics: nil)
        try store.save(empty, for: track, manual: false)
        assert(store.load(track, requireSynced: true) == nil)
        assert(store.load(track, requireSynced: false) != nil)
        try store.remove(track)
        let transport: LyricsRepository.Transport = { request in
            let url = request.url!
            let payload: String
            let status: Int
            if url.host == "lrclib.net" { throw URLError(.notConnectedToInternet) }
            if url.path.contains("search") {
                status = 200
                payload = #"{"code":200,"result":{"songs":[{"id":1,"name":"Song","duration":180000,"artists":[{"name":"Singer"}],"album":{"name":"Album"}},{"id":2,"name":"Song (Live)","duration":200000,"artists":[{"name":"Singer"}],"album":{"name":"Live"}}]}}"#
            } else if URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name == "id" && $0.value == "2" }) == true {
                status = 503; payload = "{}"
            } else {
                status = 200
                payload = #"{"code":200,"lrc":{"lyric":"[00:01]Recovered"}}"#
            }
            return (Data(payload.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        let recovered = try await LyricsRepository.fetch(track, store: store, transport: transport)
        assert(recovered?.candidate.source == "网易云" && recovered?.cached == false)
        assert(store.load(track, requireSynced: true) != nil, "Successful fallback must be persisted")
        let results = await LyricsRepository.search(track, transport: transport)
        assert(results.candidates.count == 1 && !results.failures.isEmpty, "A failing source must not hide another source's candidates")
        try store.remove(track)
        for slowLRCLIB in [true, false] {
            let raced = try await LyricsRepository.fetch(track, store: store, useCache: false, transport: { request in
                let library = request.url!.host == "lrclib.net"
                if library == slowLRCLIB { try await Task.sleep(for: .milliseconds(30)) }
                if library {
                    let value = LyricCandidate(trackName: "Song", artistName: "Singer", albumName: "Album", duration: 180,
                                               plainLyrics: nil, syncedLyrics: "[00:01]Library version")
                    return (try JSONEncoder().encode(value), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                }
                return try await transport(request)
            })
            assert(raced?.candidate.source == "网易云", "Reversing network completion order must not change selection")
        }
        try store.remove(track)
        let cancelled = Task { try await LyricsRepository.fetch(track, store: store, transport: { _ in
            throw CancellationError()
        }) }
        do { _ = try await cancelled.value; assertionFailure("Cancellation must propagate") }
        catch is CancellationError {}
        assert(store.load(track, requireSynced: true) == nil)
        print("LyricsRepository checks passed: disk reuse, version isolation, manual choice, plain/synced separation, fallback, partial failure, cancellation")
    }
}
