import Foundation
#if VISUAL_CHECKS
import AppKit
import SwiftUI
#endif

@main @MainActor struct CompactLyricsChecks {
    static func main() async {
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
        let unchanged = state.clockUpdate(elapsed: nil, timestamp: nil, diff: true, playing: nil, rate: nil)
        assert(unchanged.position == state.currentTime && unchanged.date == state.lastUpdated)
        let track = LyricTrack(bundleID: "com.apple.Music", title: "Song", artist: "Singer", album: "Album", duration: 180)
        let good = LyricCandidate(trackName: "Song", artistName: "Singer", albumName: "Album", duration: 181, plainLyrics: "Hello", syncedLyrics: "[00:01]Hello")
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
        let payload: [String: Any] = ["trackName": "Song", "artistName": "Singer", "albumName": "Reissue", "duration": 180,
                                      "syncedLyrics": "[00:01]Hello"]
        func response(_ request: URLRequest, _ code: Int, _ data: Data = Data()) -> (Data, URLResponse) {
            (data, HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
        }
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
        print("Lyrics fetch checks passed: 503 retry, album fallback, duplicate/ambiguous versions, bounded outage, cancellation")
    }

}

#if VISUAL_CHECKS
extension CompactLyricsChecks {
    static func visualChecks() {
        let cover = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)!
        let cue = LyricSegment(id: 0, start: 0, end: 6, text: "歌颂这种平凡")
        let final = LyricSegment(id: 1, start: 25, end: 30, text: "一直唱到最后")
        let glyph = PortalGlyph(text: cue.text)
        assert(!glyph.points.isEmpty && glyph.points.count <= 320)
        let coverGlyph = PortalGlyph(image: cover)
        let lastWidth = ("凡" as NSString).size(withAttributes: [.font: CompactLyricsLayout.font]).width
        let endX = CompactLyricsLayout.textX(cue.text, width: glyph.size.width, sideWidth: 54, progress: 1)
        assert(abs(endX + glyph.size.width - lastWidth / 2 - 27) < 0.001, "Last character must finish centered")

        func pixels(_ phase: LyricPhase, _ rect: CGRect) -> Data {
            let renderer = ImageRenderer(content: PortalLyricsFrame(phase: phase, elapsed: 0, duration: 30,
                sideWidth: 54, gap: 150, tint: .white, reduced: false, glyph: glyph,
                cover: coverGlyph, albumArt: cover).frame(width: 258, height: 26))
            let bitmap = NSBitmapImageRep(cgImage: renderer.cgImage!.cropping(to: rect)!)
            return Data(bytes: bitmap.bitmapData!, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        }
        let left = CGRect(x: 0, y: 0, width: 54, height: 26)
        let right = CGRect(x: 204, y: 0, width: 54, height: 26)
        assert(pixels(.lyrics(cue), left) == pixels(.waves, left), "Lyrics leaked into album/moon area")
        assert(pixels(.lyrics(cue), right) != pixels(.finished, right), "First words invisible at exact start")

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
        let entranceTimes = [0.05, 0.25, 0.5, 0.8, 1.0]
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
                Text("首秒 → 左到右传送门揭示内容").font(.system(size: 12))
                ForEach(entranceTimes.indices, id: \.self) { i in
                    let time = entranceTimes[i]
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(format: "%.2f 秒", time)).font(.system(size: 10)).foregroundStyle(.gray)
                        PortalLyricsFrame(phase: .waves, elapsed: time, duration: 30,
                            sideWidth: 54, gap: 150, tint: .white, reduced: false,
                            glyph: nil, cover: coverGlyph, albumArt: cover, entrance: time)
                            .frame(width: 258, height: 26).background(.black)
                    }
                }
            }
        }.padding(20).foregroundStyle(.white).background(Color(white: 0.04))
        let transitionRenderer = ImageRenderer(content: transitions)
        transitionRenderer.scale = 2
        try! NSBitmapImageRep(cgImage: transitionRenderer.cgImage!).representation(using: .png, properties: [:])!
            .write(to: URL(fileURLWithPath: "/tmp/lyrics-transition-preview.png"))
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
        runtimeChecks(cover)
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
        clock.position = 3; clock.date = Date(); settle()
        assert(frame() != first, "Seek failed to move sentence")
        clock.position = 2; clock.date = Date(); settle()
        assert(frame() == first, "Backward seek changed line state")
        clock.playing = true; clock.date = Date(); settle(0.2); let moving = frame(); settle(0.2)
        assert(frame() != moving, "Playing text did not move")
        clock.playing = false; clock.position = 29.9; clock.date = Date(); settle()
        let ended = frame()
        clock.position = 2; clock.date = Date(); settle()
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
        clock.position = 1; clock.date = Date(); settle()
        assert(frame() != entry, "Entry did not reveal content")
        print("Portal runtime checks passed: pause, seek, ending rewind, waves, line dissolve, entry reveal")
    }
}
@MainActor private final class TestClock: ObservableObject {
    @Published var position = 2.0
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
