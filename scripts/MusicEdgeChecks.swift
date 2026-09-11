import SwiftUI
import AppKit

@main @MainActor struct MusicEdgeChecks {
    static func main() throws {
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
        for i in 0..<100 { let p = contour.point(Double(i)/100, outward: 3); assert(p.x.isFinite && p.y.isFinite) }
        let styles = ["water", "ripple", "dust", "meteor", "mist"]
        func render(_ style: String, energy: Double, reduced: Bool = false, phase: Double = 0.7) -> Data {
            let content = MusicEdgeFrame(shape: shape, style: style, strength: 1, energy: energy, phase: phase, color: .white, reduced: reduced)
                .frame(width: 352, height: 80)
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
        let preview = VStack(spacing: 18) {
            Text("音乐边缘 · 左：安静　右：强烈").font(.system(size: 15))
            ForEach(styles, id: \.self) { style in
                HStack(spacing: 20) {
                    Text(["water":"黑色水波", "ripple":"涟漪", "dust":"星尘", "meteor":"流星", "mist":"光雾"][style]!).frame(width: 70)
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
        print("Music edge checks passed: attack/release, invalid audio, contour wrap, five styles, black water, interior mask and reduced motion")
    }
}
