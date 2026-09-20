import Foundation
#if VISUAL_CHECKS
import AppKit
import SwiftUI
#endif

@main @MainActor struct CompactLyricsChecks {
    static func main() async {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        for (hour, minute, expected) in [(7, 59, CompactLyrics.TimeOfDay.dawn), (8, 0, .day), (16, 59, .day), (17, 0, .dusk), (18, 59, .dusk), (19, 0, .night), (23, 59, .night), (0, 0, .dawn)] {
            let date = calendar.date(from: DateComponents(year: 2026, month: 9, day: 11, hour: hour, minute: minute))!
            assert(CompactLyrics.timeOfDay(at: date, calendar: calendar) == expected)
        }
        let utcMidnight = Date(timeIntervalSince1970: 0)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        assert(CompactLyrics.timeOfDay(at: utcMidnight, calendar: calendar) == .day, "Use local rather than UTC hour")
        assert(CompactLyrics.titleKey("偏爱-《仙剑奇侠传3》电视剧插曲") == CompactLyrics.titleKey("偏爱"))
        assert(CompactLyrics.titleKey("偏爱 (Live)") != CompactLyrics.titleKey("偏爱"))
        assert(CompactLyrics.titleKey("偏爱 - Remix") != CompactLyrics.titleKey("偏爱"))
        let lines = CompactLyrics.parseLRC("[offset:-100]\n[00:01.5][00:03.500]回憶\n[00:05.50]")
        assert(lines.count == 3 && abs(lines[0].time - 1.4) < 0.00001 && lines[2].text.isEmpty)
        assert(CompactLyrics.displayText("回憶與愛", languages: ["zh-Hans-CN"]) == "回忆与爱")
        assert(CompactLyrics.displayText("回忆与爱", languages: ["zh-Hant-TW"]) == "回憶與愛")
        assert(CompactLyrics.displayText("回忆", languages: ["zh-HK"]) == "回憶")
        assert(CompactLyrics.displayText("回憶", languages: ["en-US", "zh-Hans"]) == "回憶")
        assert(CompactLyrics.displayText("Love 👨‍👩‍👧‍👦", languages: ["zh-Hans"]) == "Love 👨‍👩‍👧‍👦")
        let outro = CompactLyrics.timeline([.init(time: 10, text: "歌颂这种平凡"), .init(time: 14, text: "")], duration: 30)
        assert(outro.count == 1 && outro[0].text == "歌颂这种平凡")
        assert(CompactLyrics.phase(at: 9, cues: outro, duration: 30) == .waves)
        assert(CompactLyrics.phase(at: 11, cues: outro, duration: 30) == .lyrics(outro[0]))
        assert(CompactLyrics.phase(at: 20, cues: outro, duration: 30) == .waves)
        assert(CompactLyrics.phase(at: 26, cues: outro, duration: 30) == .outro)
        let sung = CompactLyrics.timeline([.init(time: 26, text: "一直唱到最后")], duration: 30)
        assert(sung[0].end == 30)
        assert(CompactLyrics.phase(at: 29.3, cues: sung, duration: 30) == .lyrics(sung[0]))
        assert(CompactLyrics.phase(at: 29.9, cues: sung, duration: 30) == .finished)
        assert(CompactLyrics.phase(at: 29, cues: [], duration: 30) == .waves)
        assert(CompactLyrics.dissolve(at: 28, duration: 30) == 0)
        assert(CompactLyrics.dissolve(at: 29.9, duration: 30) == 1)
        assert(CompactLyrics.phase(at: 11, cues: outro, duration: 30) == .lyrics(outro[0])) // backward seek
        let long = CompactLyrics.timeline([.init(time: 10, text: "爱"), .init(time: 20, text: "下一句")], duration: 30)
        assert(long[0].end == 20, "Long vocal was truncated by character count")
        assert(CompactLyrics.phase(at: 19.9, cues: long, duration: 30) == .lyrics(long[0]))
        assert(CompactLyrics.phase(at: 20, cues: long, duration: 30) == .lyrics(long[1]))
        // Compare chronological lookup to the original scans, including instrumental
        // gaps, exact boundaries, reverse seeks, replacement lyrics and empty tracks.
        let timed = CompactLyrics.timeline((0..<300).map { LyricLine(time: Double($0) * 0.7, text: $0 % 4 == 0 ? "" : "line \($0)") }, duration: 210)
        for cues in [timed, long, outro, []] {
            let positions = stride(from: -1.0, through: 211.0, by: 0.013).map { $0 }
                + cues.flatMap { [$0.start, $0.end, $0.end + 0.4] }
            for position in positions + positions.reversed() {
                let found = CompactLyrics.neighbors(at: position, cues: cues)
                assert(found.current == cues.last { $0.start <= position && position < $0.end })
                assert(found.outgoing == cues.last { $0.end <= position && position < $0.end + 0.4 })
                assert(found.nextStart == cues.first { $0.start > position }?.start)
            }
        }
        assert(CompactLyrics.neighbors(at: .nan, cues: long).current == nil)
        var state = PlaybackState(bundleIdentifier: "com.apple.Music")
        state.currentTime = 10; state.lastUpdated = Date(timeIntervalSince1970: 100); state.isPlaying = true
        let pause = state.clockUpdate(elapsed: nil, timestamp: nil, diff: true, playing: false, rate: nil, now: Date(timeIntervalSince1970: 105))
        assert(pause.position == 15 && pause.date.timeIntervalSince1970 == 105)
        state.currentTime = pause.position; state.lastUpdated = pause.date; state.isPlaying = false
        let resume = state.clockUpdate(elapsed: nil, timestamp: nil, diff: true, playing: true, rate: nil, now: Date(timeIntervalSince1970: 120))
        assert(resume.position == 15 && resume.date.timeIntervalSince1970 == 120)
        let fractional = state.clockUpdate(elapsed: 30, timestamp: "1970-01-01T00:02:00.250Z", diff: true, playing: nil, rate: nil)
        assert(fractional.position == 30 && fractional.date.timeIntervalSince1970 == 120.25)
        let plain = state.clockUpdate(elapsed: 30, timestamp: "1970-01-01T00:02:00Z", diff: true, playing: nil, rate: nil)
        assert(plain.date.timeIntervalSince1970 == 120)
        assert(CompactLyrics.phase(at: 19.5 + 0.5, cues: long, duration: 30) == .lyrics(long[1]))
        assert(CompactLyrics.phase(at: 20.5 - 1, cues: long, duration: 30) == .lyrics(long[0]))
        state.isPlaying = true
        let timestampOnly = state.clockUpdate(elapsed: nil, timestamp: "1970-01-01T00:02:00Z", diff: true, playing: nil, rate: nil)
        assert(timestampOnly.position == 30 && timestampOnly.date.timeIntervalSince1970 == 120, "Timestamp-only updates must advance the old clock anchor")
        let oldTimestamp = state.clockUpdate(elapsed: nil, timestamp: "1970-01-01T00:01:30Z", diff: true, playing: nil, rate: nil)
        assert(oldTimestamp.position == state.currentTime && oldTimestamp.date == state.lastUpdated)
        let unchanged = state.clockUpdate(elapsed: nil, timestamp: nil, diff: true, playing: nil, rate: nil)
        assert(unchanged.position == state.currentTime && unchanged.date == state.lastUpdated)
        let track = LyricTrack(bundleID: "com.apple.Music", title: "Song", artist: "Singer", album: "Album", duration: 180)
        let good = LyricCandidate(trackName: "Song", artistName: "Singer", albumName: "Album", duration: 181, plainLyrics: "Hello", syncedLyrics: "[00:01]Hello")
        let outside = LyricCandidate(trackName: "Song", artistName: "Singer", albumName: "Album", duration: 180, plainLyrics: nil, syncedLyrics: "[03:05]Outside the recording")
        assert(CompactLyrics.match([outside], track: track) == nil, "Timed lyrics need at least one displayable segment")
        let empty = LyricCandidate(trackName: "Song", artistName: "Singer", albumName: "Album", duration: 180, plainLyrics: "  ", syncedLyrics: nil)
        assert(CompactLyrics.match([empty], track: track, requireSynced: false) == nil, "An empty payload is not plain lyrics")
        assert(CompactLyrics.match([good], track: track) != nil)
        assert(CompactLyrics.match([good, good], track: track) != nil)
        let other = LyricCandidate(trackName: "Song", artistName: "Singer", albumName: "Album", duration: 180, plainLyrics: nil, syncedLyrics: "[00:10]Other")
        assert(CompactLyrics.match([good, other], track: track) == nil)
        let reissue = LyricCandidate(trackName: "Ｓｏｎｇ", artistName: "Singer", albumName: "Reissue", duration: 180, plainLyrics: nil, syncedLyrics: "[00:01]Hello")
        assert(CompactLyrics.match([reissue], track: track) != nil)
        let live = LyricCandidate(trackName: "Song (Live)", artistName: "Singer", albumName: "Album", duration: 180, plainLyrics: nil, syncedLyrics: "[00:01]Hello")
        assert(CompactLyrics.match([live], track: track) == nil)
        await networkChecks(track)
        #if VISUAL_CHECKS
        visualChecks()
        #endif
        print("Moon lyrics checks passed: Chinese script, timestamp intervals, clock anchors, offsets, endings, matching")
    }
    static func networkChecks(_ track: LyricTrack) async {
        assert(CompactLyrics.retryDelay(for: URLError(.secureConnectionFailed)) == 60_000_000_000)
        assert(CompactLyrics.retryDelay(for: CompactLyrics.FetchError.http(503)) != nil)
        assert(CompactLyrics.retryDelay(for: URLError(.cancelled)) == nil)
        assert(CompactLyrics.retryDelay(for: CancellationError()) == nil)
        assert(CompactLyrics.retryDelay(for: CompactLyrics.FetchError.http(404)) == nil)
        let payload: [String: Any] = ["trackName": "Song", "artistName": "Singer", "albumName": "Reissue", "duration": 180,
                                      "syncedLyrics": "[00:01]Hello"]
        func response(_ request: URLRequest, _ code: Int, _ data: Data = Data()) -> (Data, URLResponse) {
            (data, HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
        }
        let chineseTrack = LyricTrack(bundleID: "com.apple.Music", title: "人间", artist: "王菲", album: "王菲", duration: 285)
        let traditionalPayload: [String: Any] = ["trackName": "人間", "artistName": "王菲", "albumName": "王菲", "duration": 285,
                                                 "syncedLyrics": "[00:01]测试"]
        var initialFailure = true
        let traditional = try! await CompactLyrics.fetch(chineseTrack, transport: { request in
            if initialFailure { initialFailure = false; return response(request, 503) }
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            let isTraditional = items.contains { $0.name == "track_name" && $0.value == "人間" }
            if request.url!.path.hasSuffix("/get") {
                return isTraditional ? response(request, 200, try JSONSerialization.data(withJSONObject: traditionalPayload)) : response(request, 404)
            }
            return response(request, 200, try JSONSerialization.data(withJSONObject: isTraditional ? [traditionalPayload] : []))
        }, sleep: { _ in })
        assert(traditional != nil, "Recovered transient errors must not block traditional search fallback")
        // Reproduce the live database spelling: 孙燕姿 is indexed as Yanzi Sun.
        let romanizedTrack = LyricTrack(bundleID: "com.apple.Music", title: "我怀念的", artist: "孙燕姿", album: "逆光", duration: 289.114)
        let romanizedPayload: [String: Any] = ["trackName": "我怀念的", "artistName": "Yanzi Sun", "albumName": "逆光",
                                               "duration": 289.135, "syncedLyrics": "[00:01]测试歌词"]
        let romanizedResult = try! await CompactLyrics.fetch(romanizedTrack, transport: { request in
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            if request.url!.path.hasSuffix("/get") { return response(request, 404) }
            let includesArtist = items.contains { $0.name == "artist_name" }
            return response(request, 200, try JSONSerialization.data(withJSONObject: includesArtist ? [] : [romanizedPayload]))
        }, sleep: { _ in })
        assert(romanizedResult != nil, "Title-only recovery must match the album, duration and romanized artist")
        func candidate(artist: String = "Yanzi Sun", album: String = "逆光", title: String = "我怀念的",
                       duration: Double = 289, cue: String = "测试歌词") -> LyricCandidate {
            LyricCandidate(trackName: title, artistName: artist, albumName: album, duration: duration,
                           plainLyrics: nil, syncedLyrics: "[00:01]" + cue)
        }
        assert(CompactLyrics.match([candidate()], track: romanizedTrack) != nil)
        assert(CompactLyrics.match([candidate(artist: "Sun Yan-Zi")], track: romanizedTrack) != nil)
        assert(CompactLyrics.match([candidate(artist: "孙彦姿")], track: romanizedTrack) == nil, "Different Chinese names must not collapse to the same pinyin")
        assert(CompactLyrics.match([candidate(artist: "Li Daimo")], track: romanizedTrack) == nil)
        assert(CompactLyrics.match([candidate(album: "Other")], track: romanizedTrack) == nil)
        assert(CompactLyrics.match([candidate(album: "")], track: romanizedTrack) == nil)
        assert(CompactLyrics.match([candidate(duration: 294)], track: romanizedTrack) == nil)
        assert(CompactLyrics.match([candidate(title: "我怀念的 (Live)")], track: romanizedTrack) == nil)
        assert(CompactLyrics.match([candidate(), candidate(cue: "另一句歌词")], track: romanizedTrack) == nil)
        let exactArtist = candidate(artist: "孙燕姿", cue: "同名歌手优先")
        assert(CompactLyrics.match([candidate(), exactArtist], track: romanizedTrack)?.artistName == "孙燕姿")
        let subtitleTrack = LyricTrack(bundleID: "com.apple.Music", title: "海屿你(求你别离开我)", artist: "马也_Crabbit",
                                       album: "海屿你(求你别离开我) - Single", duration: 296.022)
        let subtitlePayload: [String: Any] = ["trackName": "海屿你", "artistName": "馬也_Crabbit", "albumName": "海屿你 - Single",
                                             "duration": 295, "syncedLyrics": "[00:01]求你别离开我"]
        let subtitleResult = try! await CompactLyrics.fetch(subtitleTrack, transport: { request in
            if request.url!.path.hasSuffix("/get") { return response(request, 404) }
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            let baseTitle = items.contains { $0.name == "track_name" && $0.value == "海屿你" }
            return response(request, 200, try JSONSerialization.data(withJSONObject: baseTitle ? [subtitlePayload] : []))
        }, sleep: { _ in })
        assert(subtitleResult != nil, "A lyric-quoted subtitle needs base-title search plus lyric, artist, album and duration verification")
        func subtitleCandidate(artist: String = "馬也_Crabbit", album: String = "海屿你 - Single", cue: String = "求你别离开我") -> LyricCandidate {
            LyricCandidate(trackName: "海屿你", artistName: artist, albumName: album, duration: 295,
                           plainLyrics: nil, syncedLyrics: "[00:01]" + cue)
        }
        assert(CompactLyrics.match([subtitleCandidate(cue: "Unrelated lyrics")], track: subtitleTrack) == nil)
        assert(CompactLyrics.match([subtitleCandidate(artist: "Another singer")], track: subtitleTrack) == nil)
        assert(CompactLyrics.match([subtitleCandidate(album: "Another album")], track: subtitleTrack) == nil)
        let versionTrack = LyricTrack(bundleID: "com.apple.Music", title: "海屿你(现场重制版本)", artist: "马也_Crabbit",
                                      album: "海屿你(现场重制版本) - Single", duration: 296)
        assert(CompactLyrics.match([subtitleCandidate()], track: versionTrack) == nil, "Do not blindly strip version labels")
        var calls = 0
        let recovered = try! await CompactLyrics.fetch(track, transport: { request in
            calls += 1
            if calls == 1 { return response(request, 503) }
            return response(request, 200, try JSONSerialization.data(withJSONObject: payload))
        }, sleep: { _ in })
        assert(recovered != nil && calls == 2, "Transient failure did not retry")
        calls = 0
        let fallback = try! await CompactLyrics.fetch(track, transport: { request in
            calls += 1
            if calls == 1 { return response(request, 404) }
            if calls == 2 { return response(request, 200, Data("[]".utf8)) }
            assert(!URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.contains { $0.name == "album_name" })
            return response(request, 200, try JSONSerialization.data(withJSONObject: [payload]))
        }, sleep: { _ in })
        assert(fallback != nil && calls == 3, "Album-free fallback was not attempted")
        calls = 0
        do {
            _ = try await CompactLyrics.fetch(track, transport: { request in
                calls += 1; return response(request, 503)
            }, sleep: { _ in })
            assertionFailure("Permanent outage was reported as not found")
        } catch { assert(calls == 9, "Retries must be bounded") }
        let cancellation = Task { () -> Bool in
            do {
                _ = try await CompactLyrics.fetch(track, transport: { _ in throw URLError(.timedOut) },
                    sleep: { _ in throw CancellationError() })
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }
        let cancelled = await cancellation.value
        assert(cancelled)
        var cancelledCalls = 0
        do {
            _ = try await CompactLyrics.fetch(track, transport: { _ in
                cancelledCalls += 1
                throw URLError(.cancelled)
            }, sleep: { _ in assertionFailure("Cancelled requests must not retry") })
            assertionFailure("Cancelled transport must throw")
        } catch { assert(cancelledCalls == 1) }
        var invalidTrack = track
        invalidTrack = LyricTrack(bundleID: track.bundleID, title: track.title, artist: " ", album: track.album, duration: 0)
        assert(!invalidTrack.isReady)
        let invalidResult = try! await CompactLyrics.fetch(invalidTrack, transport: { _ in
            assertionFailure("Incomplete metadata must not contact the provider")
            throw URLError(.badURL)
        })
        assert(invalidResult == nil)
        assert(CompactLyrics.retryDelay(for: CompactLyrics.FetchError.invalidResponse) != nil)
        print("Lyrics fetch checks passed: 503 retry, album fallback, duplicate/ambiguous versions, bounded outage, cancellation")
    }

}

#if VISUAL_CHECKS
extension CompactLyricsChecks {
    static func visualChecks() {
        let motion = CompactLyricsLayout.celestialMotion(elapsed: 1, ending: 0, reduced: false)
        assert(motion.turn > 0 && abs(motion.lift) > 0 && abs(motion.light) > 0)
        let still = CompactLyricsLayout.celestialMotion(elapsed: 1, ending: 0, reduced: true)
        assert(still.turn == 0 && still.lift == 0 && still.light == 0)
        let ending = CompactLyricsLayout.celestialMotion(elapsed: 1, ending: 1, reduced: false)
        assert(ending.lift == 0 && ending.light == 0)
        assert(CompactLyricsLayout.celestialTransition(elapsed: 10, duration: 0) == 0)
        assert(CompactLyricsLayout.celestialTransition(elapsed: 96.3, duration: 100) == 0)
        assert(abs(CompactLyricsLayout.celestialTransition(elapsed: 97.55, duration: 100) - 0.5) < 0.00001)
        assert(CompactLyricsLayout.celestialTransition(elapsed: 100, duration: 100) == 1)
        assert(CompactLyricsLayout.celestialTransition(elapsed: 98.8, duration: 100) == 1)
        assert(CompactLyricsLayout.celestialTransition(elapsed: 50, duration: 100) == 0)
        assert(CompactLyricsLayout.moonBoundary(progress: 0, angle: 0) == -1)
        assert(CompactLyricsLayout.moonBoundary(progress: 1, angle: 0) == 1)
        assert(abs(CompactLyricsLayout.moonBoundary(progress: 0.5, angle: 0) - 0.35) < 0.00001)
        assert(abs(CompactLyricsLayout.moonBoundary(progress: 0.5, angle: .pi / 2)) < 0.00001)
        for step in 0..<100 {
            assert(CompactLyricsLayout.moonBoundary(progress: Double(step) / 100, angle: 0)
                < CompactLyricsLayout.moonBoundary(progress: Double(step + 1) / 100, angle: 0))
        }
        for gap in [0.0, 150, 210] {
            let duration = CompactLyricsLayout.entranceDuration(sideWidth: 54, gap: gap)
            func edge(_ time: Double) -> CGFloat {
                CompactLyricsLayout.entranceEdge(sideWidth: 54, gap: gap, progress: time / duration)
            }
            assert(abs(duration - (2 + gap / 108)) < 0.00001)
            assert(edge(0) == 0 && abs(edge(duration) - (108 + gap)) < 0.00001)
            assert(abs(edge(1) - 54) < 0.00001)
            assert(abs(edge(duration - 1) - (54 + gap)) < 0.00001)
            for time in [0.5, duration - 0.5] {
                assert(abs((edge(time + 0.01) - edge(time)) / 0.01 - 54) < 0.00001)
            }
            if gap > 0 {
                assert(abs((edge(duration / 2 + 0.01) - edge(duration / 2)) / 0.01 - 108) < 0.00001)
            }
            for boundary in [1.0, duration - 1] {
                assert(abs(edge(boundary + 0.00001) - edge(boundary - 0.00001)) < 0.003, "Portal position stays continuous")
            }
        }
        let cover = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)!
        let cue = LyricSegment(id: 0, start: 0, end: 6, text: "歌颂这种平凡")
        let final = LyricSegment(id: 1, start: 25, end: 30, text: "一直唱到最后")
        let glyph = PortalGlyph(text: cue.text)
        assert(!glyph.points.isEmpty && glyph.points.count <= 320)
        for text in [cue.text, "ending  ", "月亮🌙", ""] {
            let cached = PortalGlyph(text: text)
            for progress in [0.0, 0.5, 1.0] {
                let measured = CompactLyricsLayout.textX(text, width: cached.size.width, sideWidth: 54, progress: progress)
                let reused = CompactLyricsLayout.textX(text, width: cached.size.width, sideWidth: 54, progress: progress,
                    lastCharacterWidth: cached.lastCharacterWidth)
                assert(measured == reused, "Cached glyph width must preserve lyric position")
            }
        }
        let coverGlyph = PortalGlyph(image: cover)
        let lastWidth = ("凡" as NSString).size(withAttributes: [.font: CompactLyricsLayout.font]).width
        let endX = CompactLyricsLayout.textX(cue.text, width: glyph.size.width, sideWidth: 54, progress: 1)
        assert(abs(endX + glyph.size.width - lastWidth / 2 - 27) < 0.001, "Last character must finish centered")
        assert(CompactLyricsLayout.textX(cue.text, width: glyph.size.width, sideWidth: 54, progress: 0 ) == 54)
        let enteringX = CompactLyricsLayout.textX(cue.text, width: glyph.size.width, sideWidth: 54, progress: 0.1 / 6)
        assert(enteringX > 4 && enteringX < 54, "New line must enter from the right")
        let positions = (0...60).map { step in
            CompactLyricsLayout.textX(cue.text, width: glyph.size.width, sideWidth: 54, progress: Double(step) / 60)
        }
        let stepDistance = positions[1] - positions[0]
        assert(stepDistance < 0)
        for i in 1..<positions.count {
            assert(abs((positions[i] - positions[i - 1]) - stepDistance) < 0.00001,
                   "Entry velocity must equal the rest of the line")
        }

        func pixels(_ phase: LyricPhase, _ rect: CGRect, time: Double = 0) -> Data {
            let renderer = ImageRenderer(content: PortalLyricsFrame(phase: phase, elapsed: time, duration: 30,
                sideWidth: 54, gap: 150, tint: .white, reduced: false, glyph: glyph,
                cover: coverGlyph, albumArt: cover).frame(width: 258, height: 26))
            let bitmap = NSBitmapImageRep(cgImage: renderer.cgImage!.cropping(to: rect)!)
            // Compare only cropped pixels, excluding backing-row padding outside this lane.
            var values = Data()
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    let color = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                    let alpha = color.alphaComponent
                    values.append(contentsOf: [color.redComponent * alpha, color.greenComponent * alpha,
                                               color.blueComponent * alpha, alpha].map { UInt8(min(255, max(0, ($0 * 255).rounded()))) })
                }
            }
            return values
        }
        let left = CGRect(x: 0, y: 0, width: 54, height: 26)
        let right = CGRect(x: 204, y: 0, width: 54, height: 26)
        assert(pixels(.lyrics(cue), left) == pixels(.waves, left), "Lyrics leaked into album/moon area")
        assert(pixels(.lyrics(cue), right) == pixels(.finished, right), "New line appeared inside the viewport")
        assert(pixels(.lyrics(cue), right, time: 0.1) != pixels(.finished, right), "New line did not slide in")

        let cases: [(String, LyricPhase, Double, PortalGlyph?)] = [
            ("开始 · 封面与满月", .lyrics(cue), 0, glyph),
            ("右侧歌词 · 连续滚动", .lyrics(cue), 3.0, glyph),
            ("中途 · 半月与右侧波纹", .waves, 15, nil),
            ("曲终前 · 月球变为星星", .outro, 28.7, nil),
            ("尾奏收尾 · 同步消散", .outro, 29.3, nil),
            ("唱到曲终 · 歌词消散", .lyrics(final), 29.3, PortalGlyph(text: final.text))
        ]
        let strip = VStack(alignment: .leading, spacing: 14) {
            ForEach(cases.indices, id: \.self) { index in
                let row = cases[index]
                VStack(alignment: .leading, spacing: 5) {
                    Text(row.0).font(.system(size: 11)).foregroundStyle(.gray)
                    PortalLyricsFrame(phase: row.1, elapsed: row.2, duration: 30,
                                      sideWidth: 54, gap: 150, tint: .white, reduced: false,
                                      glyph: row.3, cover: coverGlyph, albumArt: cover)
                        .frame(width: 258, height: 26)
                        .background(.black)
                        .overlay { Rectangle().stroke(.gray.opacity(0.25)) }
                }
            }
        }.padding(20).background(Color(white: 0.04))
        let renderer = ImageRenderer(content: strip)
        renderer.scale = 3
        let image = renderer.cgImage!
        let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
        try! png.write(to: URL(fileURLWithPath: "/tmp/moon-lyrics-preview.png"))
        let nextCue = LyricSegment(id: 2, start: 6, end: 12, text: "也曾像朋友一样和我诉说")
        let nextGlyph = PortalGlyph(text: nextCue.text)
        let transitionTimes = [5.999, 6.0, 6.1, 6.25, 6.4]
        let entranceTimes = [0.1, 0.5, 1.0, 2.4, 3.8, 4.3, 4.8]
        let transitions = HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                Text("句尾居中 → 旧句消散、新句显现").font(.system(size: 12))
                ForEach(transitionTimes.indices, id: \.self) { i in
                    let time = transitionTimes[i]
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(format: "%.2f 秒", time)).font(.system(size: 10)).foregroundStyle(.gray)
                        PortalLyricsFrame(phase: .lyrics(i == 0 ? cue : nextCue), elapsed: time, duration: 30,
                            sideWidth: 54, gap: 150, tint: .white, reduced: false,
                            glyph: i == 0 ? glyph : nextGlyph, cover: coverGlyph, albumArt: cover,
                            outgoing: i > 0 && i < 4 ? cue : nil, outgoingGlyph: glyph)
                            .frame(width: 258, height: 26).background(.black)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("加速通过刘海 → 两侧保持原速").font(.system(size: 12))
                ForEach(entranceTimes.indices, id: \.self) { i in
                    let time = entranceTimes[i]
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(format: "%.2f 秒", time)).font(.system(size: 10)).foregroundStyle(.gray)
                        PortalLyricsFrame(phase: .waves, elapsed: time, duration: 30,
                            sideWidth: 54, gap: 150, tint: .white, reduced: false,
                            glyph: nil, cover: coverGlyph, albumArt: cover, entrance: time / CompactLyricsLayout.entranceDuration(sideWidth: 54, gap: 150))
                            .frame(width: 258, height: 26).background(.black)
                    }
                }
            }
        }.padding(20).foregroundStyle(.white).background(Color(white: 0.04))
        let transitionRenderer = ImageRenderer(content: transitions)
        transitionRenderer.scale = 2
        try! NSBitmapImageRep(cgImage: transitionRenderer.cgImage!).representation(using: .png, properties: [:])!
            .write(to: URL(fileURLWithPath: "/tmp/lyrics-transition-preview.png"))
        let weatherPreview = VStack(alignment: .leading, spacing: 12) {
            ForEach(NotchWeatherKind.allCases, id: \.self) { kind in
                HStack {
                    Text(kind.label).frame(width: 55)
                    ForEach([8.0, 27.55, 29.3], id: \.self) { time in
                        PortalLyricsFrame(phase: time < 26 ? .waves : .outro, elapsed: time, duration: 30,
                            sideWidth: 54, gap: 0, tint: .white, reduced: false, glyph: nil,
                            cover: coverGlyph, albumArt: cover, daylight: 1,
                            weather: NotchWeatherSnapshot(kind: kind, wind: 7, observed: .now, fetched: .now,
                                place: WeatherPlace(name: "Preview", latitude: 0, longitude: 0)))
                            .frame(width: 108, height: 26).background(.black)
                    }
                }
            }
        }.padding(20).foregroundStyle(.white).background(Color(white: 0.04))
        let weatherRenderer = ImageRenderer(content: weatherPreview)
        weatherRenderer.scale = 4
        try! NSBitmapImageRep(cgImage: weatherRenderer.cgImage!).representation(using: .png, properties: [:])!
            .write(to: URL(fileURLWithPath: "/tmp/notch-weather-preview.png"))
        let solarTimes = [0.0, 15, 27.55, 28.8, 29.3]
        let solarLabels = ["开始", "中段", "收拢中", "曲终前", "粒子消散"]
        let celestialPreview = HStack(alignment: .top, spacing: 20) {
            ForEach(0..<4, id: \.self) { mode in
                VStack(alignment: .leading, spacing: 12) {
                    Text(["凌晨 00–08 · 微星月球", "白天 08–17 · 太阳", "傍晚 17–19 · 落日", "夜间 19–24 · 月球"][mode]).font(.system(size: 12))
                    ForEach(solarTimes.indices, id: \.self) { i in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(solarLabels[i]).font(.system(size: 10)).foregroundStyle(.gray)
                            PortalLyricsFrame(phase: i < 2 ? .waves : .outro, elapsed: solarTimes[i], duration: 30,
                                sideWidth: 54, gap: 150, tint: .white, reduced: false, glyph: nil,
                                cover: coverGlyph, albumArt: cover, daylight: mode == 1 ? 1 : 0, dawn: mode == 0 ? 1 : 0, dusk: mode == 2 ? 1 : 0)
                                .frame(width: 258, height: 26).background(.black)
                        }
                    }
                }
            }
        }.padding(20).foregroundStyle(.white).background(Color(white: 0.04))
        let celestialRenderer = ImageRenderer(content: celestialPreview)
        celestialRenderer.scale = 3
        try! NSBitmapImageRep(cgImage: celestialRenderer.cgImage!).representation(using: .png, properties: [:])!
            .write(to: URL(fileURLWithPath: "/tmp/sun-moon-preview.png"))
        var times: [Double] = []
        for index in 0..<120 {
            let ms: Double = autoreleasepool {
                let start = Date()
                let frame = ImageRenderer(content: PortalLyricsFrame(phase: .lyrics(cue), elapsed: 1 + Double(index) / 60,
                    duration: 30, sideWidth: 54, gap: 150, tint: .white, reduced: false,
                    glyph: glyph, cover: coverGlyph, albumArt: cover).frame(width: 258, height: 26))
                frame.scale = 2
                assert(frame.cgImage != nil)
                return Date().timeIntervalSince(start) * 1000
            }
            times.append(ms)
        }
        times.sort()
        print(String(format: "Portal offscreen renderer: median %.3f ms; p95 %.3f ms (not display FPS)", times[60], times[114]))
        colorChecks(cover)
        runtimeChecks(cover)
    }

    static func colorChecks(_ cover: NSImage) {
        let cue = LyricSegment(id: 0, start: 0, end: 5, text: "彩虹歌词 Colorful lyrics")
        let glyph = PortalGlyph(text: cue.text)
        let artwork = PortalGlyph(image: cover)
        let styles: [LyricColorStyle] = [.automatic, .custom, .rainbow]
        func frame(_ style: LyricColorStyle, time: Double, outgoing: Bool = false) -> some View {
            PortalLyricsFrame(phase: outgoing ? .waves : .lyrics(cue), elapsed: time, duration: 30,
                sideWidth: 54, gap: 150, tint: .white, reduced: false, glyph: glyph,
                cover: artwork, albumArt: cover, outgoing: outgoing ? cue : nil,
                outgoingGlyph: outgoing ? glyph : nil, lyricColorStyle: style, lyricColor: .green)
                .frame(width: 258, height: 26)
        }
        func pixels(_ image: CGImage, rect: CGRect) -> Data {
            let bitmap = NSBitmapImageRep(cgImage: image.cropping(to: rect)!)
            var result = Data()
            for y in 0..<bitmap.pixelsHigh {
                result.append(bitmap.bitmapData! + y * bitmap.bytesPerRow, count: bitmap.pixelsWide * 4)
            }
            return result
        }
        // Both the scrolling line and outgoing text/dust use the selected palette;
        // artwork, moon and their geometry stay byte-identical.
        for outgoing in [false, true] {
            let images = styles.map { style in
                ImageRenderer(content: frame(style, time: outgoing ? 5.15 : 2.5, outgoing: outgoing)).cgImage!
            }
            let left = CGRect(x: 0, y: 0, width: 54, height: 26)
            let right = CGRect(x: 204, y: 0, width: 54, height: 26)
            for i in 1..<images.count {
                assert(pixels(images[0], rect: left) == pixels(images[i], rect: left))
                assert(pixels(images[0], rect: right) != pixels(images[i], rect: right))
            }
            assert(pixels(images[1], rect: right) != pixels(images[2], rect: right))
        }
        let preview = VStack(alignment: .leading, spacing: 16) {
            ForEach(styles, id: \.rawValue) { style in
                VStack(alignment: .leading, spacing: 6) {
                    Text(style.rawValue).font(.caption).foregroundStyle(.gray)
                    Text(cue.text).font(Font(CompactLyricsLayout.font))
                        .foregroundStyle(style.foreground(tint: .white, custom: .green))
                    frame(style, time: 2.5)
                }
            }
        }.padding(16).background(.black)
        let previewRenderer = ImageRenderer(content: preview)
        previewRenderer.scale = 3
        let bitmap = NSBitmapImageRep(cgImage: previewRenderer.cgImage!)
        try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/lyrics-color-preview.png"))
        for style in styles {
            var samples: [Double] = []
            for i in 0..<160 {
                let elapsed = autoreleasepool {
                    let start = Date()
                    let renderer = ImageRenderer(content: frame(style, time: 1 + Double(i) / 160))
                    renderer.scale = 2
                    guard renderer.cgImage != nil else { fatalError("Missing lyric color render") }
                    return Date().timeIntervalSince(start) * 1000
                }
                if i >= 40 { samples.append(elapsed) }
            }
            samples.sort()
            print(String(format: "Lyric color %@: median %.3f ms; p95 %.3f ms (offscreen only)", style.rawValue, samples[60], samples[114]))
        }
    }

    static func runtimeChecks(_ cover: NSImage) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let clock = TestClock()
        let host = NSHostingView(rootView: TestView(clock: clock, cover: cover))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 258, height: 26),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host; window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        func settle(_ seconds: Double = 0.15) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        func frame() -> Data {
            host.layoutSubtreeIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            return Data(bytes: bitmap.bitmapData!, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        }
        settle(); let first = frame(); settle(0.3)
        assert(frame() == first, "Paused motion changed")
        clock.position = 5.5; clock.date = Date(); settle()
        assert(frame() != first, "Seek failed to move sentence")
        clock.position = 5; clock.date = Date(); settle()
        assert(frame() == first, "Backward seek changed line state")
        clock.playing = true; clock.date = Date(); settle(0.2); let moving = frame(); settle(0.2)
        assert(frame() != moving, "Playing text did not move")
        clock.playing = false; clock.position = 29.9; clock.date = Date(); settle()
        let ended = frame()
        clock.position = 5; clock.date = Date(); settle()
        assert(frame() == first && frame() != ended, "Rewind after ending did not restore lyrics")
        clock.segments = []; clock.revision += 1; settle()
        let waves = frame(); settle(0.3)
        assert(frame() == waves && waves != first, "Paused fallback wave changed or retained lyrics")
        clock.segments = [LyricSegment(id: 0, start: 0, end: 6, text: "歌颂这种平凡"),
                          LyricSegment(id: 1, start: 6, end: 12, text: "也曾像朋友一样和我诉说")]
        clock.position = 6.1; clock.date = Date(); clock.revision += 1; settle()
        let transition = frame(); settle(0.3)
        assert(frame() == transition, "Paused line dissolution advanced")
        clock.position = 6.5; clock.date = Date(); settle()
        assert(frame() != transition, "Old line did not dissolve")
        clock.position = 0.3; clock.date = Date(); clock.revision += 1; settle()
        let entry = frame(); settle(0.3)
        assert(frame() == entry, "Paused entry portal advanced")
        clock.position = 5; clock.date = Date(); settle()
        assert(frame() != entry, "Entry did not reveal content")
        print("Portal runtime checks passed: pause, seek, ending rewind, waves, line dissolve, entry reveal")
    }
}
@MainActor private final class TestClock: ObservableObject {
    // Start beyond the longer entrance so runtime checks can see the lyric lane.
    @Published var position = 5.0
    @Published var date = Date()
    @Published var playing = false
    @Published var revision: UInt64 = 1
    @Published var segments = [LyricSegment(id: 0, start: 0, end: 6, text: "歌颂这种平凡")]
}
private struct TestView: View {
    @ObservedObject var clock: TestClock
    let cover: NSImage
    var body: some View {
        CompactLyricsView(segments: clock.segments, revision: clock.revision, position: clock.position,
                          sampleDate: clock.date, rate: 1, duration: 30, isPlaying: clock.playing,
                          tint: .white, albumArt: cover, sideWidth: 54, gap: 150, height: 26).background(.black)
    }
}
#endif
