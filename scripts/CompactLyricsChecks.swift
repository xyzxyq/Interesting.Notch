import Foundation
#if VISUAL_CHECKS
import AppKit
import SwiftUI
#endif
@main @MainActor struct CompactLyricsChecks {
    static func main() {
        assert(CompactLyrics.split("歌颂这种平凡") == ["歌颂", "这种", "平凡"])
        assert(CompactLyrics.split("也曾像朋友一样和我诉说") == ["也曾像", "朋友", "一样", "和我", "诉说"])
        let lines = CompactLyrics.parseLRC("[offset:-100]\n[00:01.5][00:03.500]歌颂这种平凡\n[00:05.50]\n[bad]ignored")
        assert(lines.count == 3)
        assert(abs(lines[0].time - 1.4) < 0.000001)
        assert(abs(lines[1].time - 3.4) < 0.000001)
        assert(abs(lines[2].time - 5.4) < 0.000001 && lines[2].text.isEmpty)
        let segments = CompactLyrics.timeline([.init(time: 10, text: "歌颂这种平凡"), .init(time: 20, text: "")], duration: 30)
        assert(segments.count == 3)
        assert(CompactLyrics.segment(at: 9, in: segments) == nil)
        assert(CompactLyrics.segment(at: 10, in: segments)?.text == "歌颂")
        assert(CompactLyrics.segment(at: 11, in: segments)?.text == "这种")
        assert(CompactLyrics.segment(at: 12, in: segments)?.text == "平凡")
        assert(CompactLyrics.segment(at: 13, in: segments) == nil)
        assert(CompactLyrics.segment(at: 10, in: segments)?.text == "歌颂") // backward seek
        assert(abs(CompactLyrics.nextBoundary(after: 10, in: segments)! - 10.8) < 0.000001)
        for input in ["你好，世界！", "abcdefg", "👨‍👩‍👧‍👦你好", "e\u{301}1234"] {
            let result = CompactLyrics.split(input)
            assert(result.allSatisfy { (1...3).contains($0.count) })
            let expected = input.filter { !$0.isWhitespace && !$0.isPunctuation }
            assert(result.joined() == String(expected))
        }
        assert(CompactLyrics.timeline([.init(time: 2, text: "你好")], duration: 3).last?.end == 3)
        assert(CompactLyrics.parseLRC("[00:01]你\n[00:01]好") == [LyricLine(time: 1, text: "你好")])
        assert(CompactLyrics.parseLRC("[offset:-2000]\n[00:01]你").first?.time == 0)
        assert(CompactLyrics.parseLRC("[00:99]bad\n[xx:01]bad").isEmpty)
        assert(CompactLyrics.timeline([], duration: 10).isEmpty)
        assert(CompactLyrics.split("， ！").isEmpty)
        assert(CompactLyrics.nextBoundary(after: 30, in: segments) == nil)
        let track = LyricTrack(bundleID: "com.apple.Music", title: "Song", artist: "Singer", album: "Album", duration: 180)
        let good = LyricCandidate(trackName: "Song", artistName: "Singer", albumName: "Album", duration: 181, plainLyrics: "Hello", syncedLyrics: "[00:01]Hello")
        let live = LyricCandidate(trackName: "Song Live", artistName: "Singer", albumName: "Album", duration: 180, plainLyrics: nil, syncedLyrics: "[00:01]Hello")
        let wrongDuration = LyricCandidate(trackName: "Song", artistName: "Singer", albumName: "Album", duration: 183, plainLyrics: nil, syncedLyrics: "[00:01]Hello")
        assert(CompactLyrics.match([live, wrongDuration, good], track: track)?.duration == 181)
        assert(CompactLyrics.match([good, good], track: track) == nil)
        assert(CompactLyrics.match([good], track: .init(bundleID: "com.apple.Music", title: "Song", artist: "", album: "Album", duration: 180)) == nil)
        let fast = LyricSegment(id: 0, start: 0, end: 0.1, text: "你")
        assert(abs(CompactLyrics.transitionDuration(for: fast) - 0.035) < 0.000001)
        let slow = LyricSegment(id: 1, start: 0, end: 2, text: "你好")
        assert(CompactLyrics.transitionDuration(for: slow) == 0.280)
        #if VISUAL_CHECKS
        visualChecks()
        runtimeChecks()
        #endif
        print("CompactLyrics checks passed")
    }
}

#if VISUAL_CHECKS
extension CompactLyricsChecks {
    static func visualChecks() {
        let size = CGSize(width: CompactLyricsLayout.slotWidth, height: 24)
        let old = LyricGlyph(text: "歌颂", size: size, scale: 2, seed: 1, sample: true)
        let new = LyricGlyph(text: "这种", size: size, scale: 2, seed: 2, sample: true)
        assert(!old.particles.isEmpty && old.particles.count <= 160)
        assert(!new.particles.isEmpty && new.particles.count <= 160)
        let repeatGlyph = LyricGlyph(text: "这种", size: size, scale: 2, seed: 2, sample: true)
        assert(repeatGlyph.particles.map(\.origin) == new.particles.map(\.origin))
        assert(repeatGlyph.particles.map(\.drift) == new.particles.map(\.drift))
        assert(LyricGlyph(text: "这种", size: size, scale: 2, seed: 2, sample: false).particles.isEmpty)
        let transition = LyricTransition(outgoing: old, incoming: new, duration: 0.280, reduced: false)
        let strip = VStack(spacing: 12) {
            Text("Particle transition · 280 ms").font(.system(size: 12)).foregroundStyle(.white)
            HStack(spacing: 12) {
                ForEach(0..<7) { step in
                    VStack {
                        LyricTransitionCanvas(transition: transition,
                                              date: transition.startedAt.addingTimeInterval(Double(step) / 6 * 0.280), tint: .white)
                            .frame(width: size.width, height: size.height)
                        Text("\(step * 100 / 6)%").font(.system(size: 9)).foregroundStyle(.gray)
                    }
                }
            }
            Text("三字 / Emoji / mixed text").font(.system(size: 12)).foregroundStyle(.white)
            HStack(spacing: 12) {
                ForEach(["也曾像", "朋友", "👨‍👩‍👧‍👦你好", "é12"], id: \.self) { text in
                    Text(text).font(Font(CompactLyricsLayout.font(for: text, in: size)))
                        .foregroundStyle(.white).frame(width: size.width, height: size.height)
                        .border(.gray.opacity(0.4))
                }
            }
        }.padding(20).background(.black)
        let renderer = ImageRenderer(content: strip)
        renderer.scale = 3
        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            fatalError("Visual snapshot failed")
        }
        let url = URL(fileURLWithPath: "/tmp/interesting-notch-lyrics-preview.png")
        try! png.write(to: url)
        var renderTimes: [Double] = []
        for step in 0..<120 {
            let elapsed: Double = autoreleasepool {
                let begin = Date()
                let frameRenderer = ImageRenderer(content:
                    LyricTransitionCanvas(transition: transition,
                        date: transition.startedAt.addingTimeInterval(Double(step % 60) / 59 * 0.280), tint: .white)
                        .frame(width: size.width, height: size.height).background(.black))
                frameRenderer.scale = 2
                assert(frameRenderer.cgImage != nil)
                return Date().timeIntervalSince(begin) * 1000
            }
            renderTimes.append(elapsed)
        }
        renderTimes.sort()
        print(String(format: "Offscreen renderer: 120 frames, median %.3f ms, p95 %.3f ms (not display FPS)", renderTimes[60], renderTimes[114]))
        print("Visual checks passed; snapshot: \(url.path)")
    }
}
#endif

#if VISUAL_CHECKS
@MainActor private final class RuntimeClock: ObservableObject {
    @Published var position = 0.2
    @Published var date = Date()
    @Published var playing = false
    @Published var revision: UInt64 = 1
    @Published var segments: [LyricSegment] = [
        .init(id: 0, start: 0, end: 1, text: "歌颂"),
        .init(id: 1, start: 1, end: 2, text: "这种"),
        .init(id: 2, start: 2, end: 3, text: "平凡")
    ]
}
private struct RuntimeView: View {
    @ObservedObject var clock: RuntimeClock
    var body: some View {
        CompactLyricsView(segments: clock.segments, revision: clock.revision,
                          position: clock.position, sampleDate: clock.date, rate: 1,
                          isPlaying: clock.playing, tint: .white) { Text("—").foregroundStyle(.gray) }
            .background(.black)
    }
}
extension CompactLyricsChecks {
    static func runtimeChecks() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let clock = RuntimeClock()
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: CompactLyricsLayout.slotWidth, height: 24),
                              styleMask: .borderless, backing: .buffered, defer: false)
        let host = NSHostingView(rootView: RuntimeView(clock: clock))
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        func settle(_ seconds: Double = 0.12) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        func frame() -> Data {
            host.layoutSubtreeIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            return Data(bytes: bitmap.bitmapData!, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        }
        settle()
        let first = frame()
        settle(1.1)
        assert(frame() == first, "Paused lyrics advanced")
        clock.position = 1.2; clock.date = Date(); settle()
        let second = frame()
        assert(first != second, "Forward seek did not update rendered text")
        clock.position = 0.2; clock.date = Date(); settle()
        assert(frame() == first, "Backward seek did not restore rendered text")
        clock.position = 0.9; clock.date = Date(); clock.playing = true; settle(0.55)
        assert(frame() == second, "Resume/boundary transition did not settle on next text")
        clock.playing = false; clock.position = 1.4; clock.date = Date(); settle(0.4)
        let paused = frame(); settle(0.4)
        assert(frame() == paused && paused == second, "Pause left moving particles")
        clock.segments = [.init(id: 1, start: 0, end: 3, text: "朋友")]
        clock.revision += 1; settle()
        assert(frame() != second, "New song reused the old segment ID")
        clock.segments = []; clock.revision += 1; settle()
        let fallback = frame()
        assert(fallback != first && fallback != second, "Missing lyrics did not fall back")
        print("Runtime checks passed: pause, forward/back seek, resume, song revision, fallback")
    }
}
#endif
