import Foundation
#if VISUAL_CHECKS
import AppKit
import SwiftUI
#endif

@main @MainActor struct CompactLyricsChecks {
    static func main() {
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
        let track = LyricTrack(bundleID: "com.apple.Music", title: "Song", artist: "Singer", album: "Album", duration: 180)
        let good = LyricCandidate(trackName: "Song", artistName: "Singer", albumName: "Album", duration: 181, plainLyrics: "Hello", syncedLyrics: "[00:01]Hello")
        assert(CompactLyrics.match([good], track: track) != nil)
        assert(CompactLyrics.match([good, good], track: track) == nil)
        #if VISUAL_CHECKS
        visualChecks()
        #endif
        print("Portal lyrics checks passed: Chinese script, LRC, full lines, instrumental/sung endings, seek, matching")
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
        let cases: [(String, LyricPhase, Double, PortalGlyph?)] = [
            ("双侧歌词 · 同一文字带", .lyrics(cue), 2.1, glyph),
            ("右入左出 · 连续滑动", .lyrics(cue), 3.0, glyph),
            ("伴奏 · 向左传播", .waves, 20, nil),
            ("尾奏 · 封面与波浪", .outro, 26, nil),
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
        try! png.write(to: URL(fileURLWithPath: "/tmp/portal-lyrics-preview.png"))
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
        print("Portal runtime checks passed: pause, scroll, forward/back seek, ending rewind, wave fallback")
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
