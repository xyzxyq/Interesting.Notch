import SwiftUI
import AppKit

@main @MainActor struct MusicEdgeChecks {
    static func main() throws {
        assert(NotchMotionEnvironment.decorativeFrameInterval(lowPower: false) == 1.0 / 24)
        assert(NotchMotionEnvironment.decorativeFrameInterval(lowPower: true) == 1.0 / 15)
        assert(NotchMotionEnvironment.lyricsFrameInterval(lowPower: false) == 1.0 / 35)
        assert(NotchMotionEnvironment.lyricsFrameInterval(lowPower: true) == 1.0 / 15)
        assert(CodexThrust.frameInterval(lowPower: false) == 1.0 / 24)
        assert(CodexThrust.frameInterval(lowPower: true) == 1.0 / 15)
        // Phase stays continuous when music/rocket speed changes or a screen sleeps.
        var phase = MusicEdgePhase()
        let start = Date(timeIntervalSinceReferenceDate: 1234)
        phase.update(target: 1, paused: false, at: start)
        let changed = start.addingTimeInterval(2)
        let before = phase.value(at: changed)
        phase.update(target: 3, paused: false, at: changed)
        assert(abs(phase.value(at: changed) - before) < 1e-10)
        let epsilon = 0.0001
        let after = phase.value(at: changed.addingTimeInterval(epsilon))
        assert(after > before && after - before < 3 * epsilon)
        let sleeping = changed.addingTimeInterval(1)
        let frozen = phase.value(at: sleeping)
        phase.update(target: 3, paused: true, at: sleeping)
        assert(phase.value(at: sleeping.addingTimeInterval(3600)) == frozen)
        phase.update(target: 1, paused: false, at: sleeping.addingTimeInterval(3600))
        assert(phase.value(at: sleeping.addingTimeInterval(3600)) == frozen)
        assert(MusicEdgeFrame.waterSampleCount == 120)
        for phase in [-10.0, 0, 0.1, 1.2, 1234, 10_000] {
            let values = MusicEdgeFrame.waterUndulations(phase: phase)
            assert(values.count == 120)
            for i in values.indices {
                let f = Double(i) / 120
                let expected = sin(f * .pi * 10 - phase * 3) * 0.65 + sin(f * .pi * 18 + phase * 2) * 0.35
                assert(abs(values[i] - expected) < 1e-9, "Cached harmonics changed wave phase or amplitude")
            }
        }
        for style in ["water", "waterWhite", "waterColor"] {
            let idle = MusicEdgePlayback(style: style, alwaysOn: true, playing: false, energy: 1)
            let playing = MusicEdgePlayback(style: style, alwaysOn: true, playing: true, energy: 0)
            assert(idle.visible && idle.ambient && idle.speed < playing.speed)
            assert(!MusicEdgePlayback(style: style, alwaysOn: false, playing: false, energy: 0).visible)
        }
        assert(!MusicEdgePlayback(style: "off", alwaysOn: true, playing: true, energy: 1).visible)
        assert(!MusicEdgePlayback(style: "dust", alwaysOn: true, playing: false, energy: 0).visible)
        var meter = EdgeEnergy()
        let quiet = meter.update(rms: 0.001, dt: 0.1)
        let loud = meter.update(rms: 0.3, dt: 0.1)
        assert(quiet == 0 && loud > 0.4)
        let falling = meter.update(rms: 0, dt: 0.1)
        assert(falling > loud * 0.7 && falling < loud)
        for _ in 0..<100 { _ = meter.update(rms: .nan, dt: 0.1) }
        assert(meter.value < 0.0001)
        let shape = NotchShape(topCornerRadius: 6, bottomCornerRadius: 12)
        let contour = EdgeContour(path: shape.path(in: CGRect(x: 8, y: 8, width: 300, height: 32)))
        assert(contour.length > 500)
        assert(hypot(contour.point(0).x - contour.point(1).x, contour.point(0).y - contour.point(1).y) < 0.0001)
        let sample = contour.sample(0.37)
        let displaced = contour.point(0.37, outward: 3)
        assert(hypot(displaced.x - (sample.point.x + sample.normal.x * 3), displaced.y - (sample.point.y + sample.normal.y * 3)) < 0.0001)
        for i in 0..<100 { let p = contour.point(Double(i)/100, outward: 3); assert(p.x.isFinite && p.y.isFinite) }
        func checkSmooth(_ points: [CGPoint]) {
            let path = EdgeContour.smoothClosedPath(points)
            var current = CGPoint.zero
            var tangents: [(start: CGPoint, end: CGPoint)] = []
            var start = CGPoint.zero
            path.forEach { element in
                switch element {
                case .move(to: let p): start = p; current = p
                case .quadCurve(to: let end, control: let control):
                    tangents.append((CGPoint(x: control.x - current.x, y: control.y - current.y),
                                     CGPoint(x: end.x - control.x, y: end.y - control.y)))
                    current = end
                case .closeSubpath: assert(current == start, "Curve seam must close exactly")
                default: assertionFailure("Wave must not contain straight corner joins")
                }
            }
            assert(tangents.count == points.count)
            for i in tangents.indices {
                let a = tangents[i].end, b = tangents[(i + 1) % tangents.count].start
                // SwiftUI's materialized path elements introduce subpixel rounding.
                assert(hypot(a.x - b.x, a.y - b.y) < 0.0001, "Corner tangent is discontinuous")
            }
            let bounds = path.boundingRect
            assert(bounds.minX >= points.map(\.x).min()! - 0.0001 && bounds.maxX <= points.map(\.x).max()! + 0.0001)
            assert(bounds.minY >= points.map(\.y).min()! - 0.0001 && bounds.maxY <= points.map(\.y).max()! + 0.0001)
        }
        assert(EdgeContour.smoothClosedPath([]).isEmpty)
        checkSmooth([CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10), CGPoint(x: 0, y: 10)])
        for rocket in [0.0, 0.3, 1] { for liquid in [0.0, 16] {
            let shape = NotchShape(topCornerRadius: 6, bottomCornerRadius: 12, rocket: rocket, liquid: liquid)
            let path = EdgeContour(path: shape.path(in: CGRect(x: 0, y: 0, width: 300, height: 32)))
            var cursor = 1
            let forward = (0...120).map { Double($0) / 120 }
            checkSmooth((0..<120).map { path.point(Double($0) / 120, outward: 4) })
            for f in forward + forward.reversed() + [-0.1, 2.3, 0, 1] {
                let old = path.sample(f), next = path.sample(f, cursor: &cursor)
                assert(old.point == next.point && old.normal == next.normal, "Ordered contour sampling changed geometry")
            }
        } }
        let styles = ["water", "waterWhite", "waterColor", "ripple", "dust", "meteor", "mist"]
        func render(_ style: String, energy: Double, reduced: Bool = false, phase: Double = 0.7, sky: Bool = true,
                    rocket: Double = 0, width: Double = 352, strength: Double = 1) -> Data {
            let contourShape = NotchShape(topCornerRadius: 6, bottomCornerRadius: 12, rocket: rocket)
            let content = MusicEdgeFrame(shape: contourShape, style: style, strength: strength, energy: energy, phase: phase, color: .white, reduced: reduced, sky: sky)
                .frame(width: width + 96 * rocket, height: 80 + 96 * rocket)
            let renderer = ImageRenderer(content: content); renderer.scale = 2
            return NSBitmapImageRep(cgImage: renderer.cgImage!).representation(using: .png, properties: [:])!
        }
        func samePixels(_ a: Data, _ b: Data) -> Bool {
            let lhs = NSBitmapImageRep(data: a)!, rhs = NSBitmapImageRep(data: b)!
            guard lhs.pixelsWide == rhs.pixelsWide, lhs.pixelsHigh == rhs.pixelsHigh else { return false }
            for y in 0..<lhs.pixelsHigh {
                for x in 0..<lhs.pixelsWide {
                    if lhs.colorAt(x: x, y: y) != rhs.colorAt(x: x, y: y) { return false }
                }
            }
            return true
        }
        for style in styles {
            assert(!samePixels(render(style, energy: 0), render(style, energy: 1)), "Strong music did not change effect")
            assert(samePixels(render(style, energy: 0, reduced: true), render(style, energy: 1, reduced: true)), "Reduced motion still reacted: \(style)")
            for (rocket, width, phase, strength) in [(0.0, 220.0, 0.1, 0.4), (0, 600, 1.2, 1.6), (0.4, 352, 0.7, 1), (1, 352, 0.1, 1.6)] {
                let pixels = NSBitmapImageRep(data: render(style, energy: 1, phase: phase, rocket: rocket, width: width, strength: strength))!
                assert(pixels.colorAt(x: pixels.pixelsWide / 2, y: pixels.pixelsHigh / 2)!.alphaComponent == 0, "Effect covers contents during resize/rocket transition")
            }
        }
        let water = NSBitmapImageRep(data: render("water", energy: 1))!
        var darkPixels = 0
        for y in 0..<water.pixelsHigh {
            for x in 0..<water.pixelsWide {
                let c = water.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                if c.alphaComponent > 0.1 && c.redComponent < 0.2 { darkPixels += 1 }
            }
        }
        assert(darkPixels > 500, "Water must form a visible black perimeter")
        assert(water.colorAt(x: water.pixelsWide/2, y: water.pixelsHigh/2)!.alphaComponent == 0, "Effect covers notch contents")
        assert(!samePixels(render("water", energy: 1), render("water", energy: 1, phase: 1.2)), "Water must propagate over time")
        for variant in ["waterWhite", "waterColor"] {
            assert(!samePixels(render("water", energy: 1), render(variant, energy: 1)), "Water palette did not change")
            assert(samePixels(render(variant, energy: 0, reduced: true), render(variant, energy: 1, reduced: true, phase: 4)), "Reduced water must keep a fixed palette")
            let pixels = NSBitmapImageRep(data: render(variant, energy: 1))!
            assert(pixels.colorAt(x: pixels.pixelsWide/2, y: pixels.pixelsHigh/2)!.alphaComponent == 0, "Water palette covers content")
        }
        assert(!samePixels(render("waterWhite", energy: 1), render("waterColor", energy: 1)), "Color water must differ from white")
        let ringColors = (0..<3).map { WaterWave(phase: 0.7, slot: $0).paletteIndex }
        assert(Set(ringColors).count == 3, "Adjacent waves must have different colors")
        for slot in 0..<3 {
            assert(WaterWave(phase: 0.7, slot: slot).paletteIndex == WaterWave(phase: 0.71, slot: slot).paletteIndex, "Travelling wave changed color")
        }
        assert(WaterWave(phase: 0, slot: 0).paletteIndex != WaterWave(phase: 1.55, slot: 0).paletteIndex, "New emission must change color")
        assert(!samePixels(render("waterColor", energy: 0), render("waterColor", energy: 0, sky: false)), "Sky decoration must render")
        assert(samePixels(render("water", energy: 0), render("water", energy: 0, sky: false)), "Sky changed black water")
        assert(samePixels(render("waterColor", energy: 0, reduced: true), render("waterColor", energy: 0, reduced: true, sky: false)), "Reduced motion should omit sky")
        let preview = VStack(spacing: 18) {
            Text("音乐边缘 · 左：安静　右：强烈").font(.system(size: 15))
            ForEach(styles, id: \.self) { style in
                HStack(spacing: 20) {
                    Text(["water":"黑色水波", "waterWhite":"白色水波", "waterColor":"彩色水波", "ripple":"涟漪", "dust":"星尘", "meteor":"流星", "mist":"光雾"][style]!).frame(width: 70)
                    ForEach([0.0, 1.0], id: \.self) { energy in
                        ZStack {
                            if style == "water" { Color(white: 0.55) }
                            shape.fill(.black).padding(24)
                            MusicEdgeFrame(shape: shape, style: style, strength: 1, energy: energy, phase: 0.7, color: Color(red: 0.95, green: 0.9, blue: 0.8), reduced: false)
                        }.frame(width: 352, height: 80)
                    }
                }
            }
        }.padding(24).foregroundStyle(.white).background(Color(white: 0.13))
        let renderer = ImageRenderer(content: preview); renderer.scale = 2
        try NSBitmapImageRep(cgImage: renderer.cgImage!).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/music-edge-preview.png"))
        print("Music edge checks passed: attack/release, invalid audio, contour wrap, seven styles, three water palettes, interior mask and reduced motion")
    }
}
