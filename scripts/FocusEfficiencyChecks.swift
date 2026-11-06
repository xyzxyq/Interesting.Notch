import AppKit
import SwiftUI
import Darwin

@main @MainActor struct FocusEfficiencyChecks {
    static func cpu() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    static func main() {
        freopen(CommandLine.arguments[1] + ".log", "w", stdout)
        freopen(CommandLine.arguments[1] + ".err", "w", stderr)
        setbuf(stdout, nil)
        _ = NSApplication.shared
        let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Bounded focus animation comparison")
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let cue = LyricSegment(id: 0, start: 2, end: 4, text: "让这一刻，慢慢流淌")
        #if !FOCUS_BASELINE
        func dates(position: Double = 0, rate: Double = 1, offset: Double = 0,
                   duration: Double = 8, now: Date? = nil, segments: [LyricSegment]? = nil) -> [Double] {
            ImmersiveFocus.lyricUpdateDates(segments: segments ?? [cue], position: position,
                sampleDate: start, rate: rate, duration: duration, offset: offset, now: now ?? start)
                .map { $0.timeIntervalSince(start) }
        }
        let scheduled = dates()
        assert(scheduled.count == 6 && scheduled[0] == 0 && scheduled[1] == 2 && scheduled[3] == 4)
        assert(abs(scheduled[2] - 2.18) < 0.000001 && abs(scheduled[4] - 4.4) < 0.000001 && scheduled[5] == 8)
        assert(dates(rate: 0) == [0] && dates(rate: .nan) == [0] && dates(position: .nan) == [0])
        assert(dates(segments: []) == [0, 8], "No lyrics must not create frame wakeups")
        assert(dates(duration: 0, segments: []) == [0], "Unbounded interlude needs no timer")
        assert(dates(position: 9) == [0], "Finished track must stop scheduling")
        assert(dates(rate: 2)[1] == 1 && dates(offset: 1)[1] == 1)
        assert(dates(position: 3)[1] == 1 && dates(position: 1)[1] == 1, "Seek must rebuild boundary times")
        assert(dates(now: start.addingTimeInterval(5)) == [5, 8])
        assert(ImmersiveFocus.lyricFrameInterval(width: 300, duration: 30, rate: 1, transitioning: false) == 1.0 / 15)
        assert(ImmersiveFocus.lyricFrameInterval(width: 300, duration: 2, rate: 1, transitioning: false) == 1.0 / 30)
        assert(ImmersiveFocus.lyricFrameInterval(width: 300, duration: 30, rate: 1, transitioning: true) == 1.0 / 30)
        let interval = ImmersiveFocus.lyricFrameInterval(width: 300, duration: 8, rate: 1, transitioning: false)
        assert(abs((300 + 80) / 8 * interval - 2) < 0.000001, "Slow wave may travel at most two points per frame")
        assert(ImmersiveFocus.lyricFrameInterval(width: 300, duration: 8, rate: 2, transitioning: false) < interval)
        assert(ImmersiveFocus.lyricFrameInterval(width: .nan, duration: 8, rate: 1, transitioning: false) == 1.0 / 30)
        let stage = ImmersiveProjectionMotion.Stage()
        stage.update(sourceWidth: 280, waiting: true, animated: true, cue: nil, cueAge: 0)
        let layers = stage.layer!.sublayers!
        let spirits = layers.filter { $0.animation(forKey: "spirit") != nil }
        assert(spirits.count == 3)
        var occupiedPositions = [[CGFloat]]()
        for spirit in spirits {
            let color = NSColor(cgColor: spirit.backgroundColor!)!.usingColorSpace(.deviceRGB)!
            assert(color.redComponent == 0 && color.greenComponent == 0 && color.blueComponent == 0
                   && color.alphaComponent == 1 && spirit.opacity == 1, "Waiting spirits must be opaque black")
            let group = spirit.animation(forKey: "spirit") as! CAAnimationGroup
            let flight = group.animations!.compactMap { $0 as? CAKeyframeAnimation }.first { $0.keyPath == "position" }!
            let points = (flight.values as! [NSValue]).map(\.pointValue)
            assert(points.first == points.last, "Spirit loop must close without a position jump")
            let positions = (0..<3).map { step -> CGFloat in
                let phase = (group.timeOffset / group.duration + Double(step) / 3).truncatingRemainder(dividingBy: 1)
                let frame = flight.keyTimes!.firstIndex { abs($0.doubleValue - phase) < 0.000001 }!
                return points[frame].x
            }
            assert(Set(positions).count == 3, "Each spirit must exchange left, middle and right positions")
            occupiedPositions.append(positions)
        }
        for step in 0..<3 {
            assert(Set(occupiedPositions.map { $0[step] }).count == 3, "Swaps must not collapse all spirits into one slot")
        }
        assert(layers.filter { $0.animation(forKey: "echo") != nil }.count == 3)
        let glow = layers.first!, pulse = layers[1]
        let sentinel = CABasicAnimation(keyPath: "opacity"); sentinel.duration = 123
        glow.add(sentinel, forKey: "breath")
        stage.update(sourceWidth: 280, waiting: false, animated: true, cue: cue, cueAge: 0.1)
        assert(glow.animation(forKey: "breath")?.duration == 123, "A new lyric must not reset the V glow")
        let burst = pulse.animation(forKey: "projection") as! CAAnimationGroup
        let arc = (pulse.mask as! CAShapeLayer).path!
        var curves = 0
        arc.applyWithBlock { if $0.pointee.type == .addCurveToPoint { curves += 1 } }
        assert(curves >= 2 && arc.boundingBoxOfPath.height > 20, "Projection wavefront must be curved")
        assert(pulse.anchorPoint == CGPoint(x: 0.5, y: 0) && pulse.position == CGPoint(x: 100, y: 2))
        assert(burst.animations?.compactMap { ($0 as? CAPropertyAnimation)?.keyPath } == ["transform.scale", "opacity"],
               "Arc must expand radially from the aperture without translating a straight band")
        assert(layers.allSatisfy { $0.animation(forKey: "spirit") == nil }, "Spirit flights must stop during lyrics")
        let next = LyricSegment(id: 1, start: 8, end: 12, text: "下一句")
        stage.update(sourceWidth: 280, waiting: false, animated: true, cue: next, cueAge: 2)
        assert(pulse.animation(forKey: "projection") == nil, "Seeking into a line must not replay a late pulse")
        stage.update(sourceWidth: 280, waiting: true, animated: false, cue: nil, cueAge: 0)
        assert(layers.allSatisfy { $0.animationKeys()?.isEmpty ?? true }, "Reduce Motion must stop all animations")
        stage.update(sourceWidth: 280, waiting: true, animated: true, cue: nil, cueAge: 0)
        stage.stop()
        assert(layers.allSatisfy { $0.animationKeys()?.isEmpty ?? true }, "Teardown must stop native loops")
        print("PASS: boundary schedule, seek, offset, pause, black spirits exchanging positions, glow interaction, radial arc pulse and teardown")
        #endif

        let panel = BoringNotchWindow(contentRect: NSRect(x: 200, y: 300, width: 640, height: 110),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let scenes = ["lyrics", "typical_lyrics", "interlude", "paused"]
        var results: [[String: Any]] = []
        func run(_ index: Int) {
            guard index < scenes.count else {
                panel.orderOut(nil); panel.contentView = nil
                let data = try! JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
                try! data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
                print(String(data: data, encoding: .utf8)!)
                ProcessInfo.processInfo.endActivity(activity)
                exit(0)
            }
            let scene = scenes[index]
            var cueStart = 0.0
            let typical = (0..<12).map { index -> LyricSegment in
                let lengths = [4.0, 8.0, 3.5, 6.0]
                let lines = ["让这一刻，慢慢流淌", "晚风轻轻吹过窗旁", "光落在字里", "把心里的声音，留给此刻的自己"]
                let end = cueStart + lengths[index % 4]
                defer { cueStart = end + 0.6 }
                return LyricSegment(id: index, start: cueStart, end: end, text: lines[index % 4])
            }
            let view = VStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 14).fill(.black).frame(width: 280, height: 32)
                    .overlay(alignment: .leading) {
                        #if FOCUS_BASELINE
                        FocusModeIcon().frame(width: 20, height: 20).padding(.leading, 12)
                        #else
                        FocusModeIcon(breathing: true).frame(width: 20, height: 20).padding(.leading, 12)
                        #endif
                    }
                ImmersiveLyricsView(segments: scene == "interlude" ? [] : scene == "typical_lyrics" ? typical
                    : [.init(id: 0, start: 0, end: 300, text: cue.text)],
                    position: scene == "typical_lyrics" ? 0 : 60, sampleDate: Date(), rate: scene == "paused" ? 0 : 1, duration: 360, offset: 0,
                    sourceWidth: 280)
            }.frame(width: 640, height: 110, alignment: .top)
            panel.contentView = NSHostingView(rootView: view)
            panel.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                let before = cpu(), began = Date()
                DispatchQueue.main.asyncAfter(deadline: .now() + 18) {
                    let elapsed = Date().timeIntervalSince(began)
                    let result: [String: Any] = ["scene": scene, "seconds": elapsed,
                        "cpu_percent": (cpu() - before) / elapsed * 100]
                    results.append(result)
                    print("MEASURE", result)
                    run(index + 1)
                }
            }
        }
        run(0)
        withExtendedLifetime(panel) { NSApp.run() }
    }
}
