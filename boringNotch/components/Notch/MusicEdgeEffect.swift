import SwiftUI

struct EdgeContour {
    private var points: [CGPoint] = []
    private var distances: [Double] = []
    private(set) var length = 0.0
    init(path: Path) {
        var current = CGPoint.zero
        var first = CGPoint.zero
        func append(_ p: CGPoint) {
            if let previous = points.last { length += hypot(p.x - previous.x, p.y - previous.y) }
            points.append(p); distances.append(length)
            current = p
        }
        path.forEach { element in
            switch element {
            case .move(to: let p): first = p; append(p)
            case .line(to: let p): append(p)
            case .quadCurve(to: let end, control: let control):
                let start = current
                for i in 1...20 {
                    let t = Double(i) / 20; let u = 1 - t
                    append(CGPoint(x: u*u*start.x + 2*u*t*control.x + t*t*end.x,
                                   y: u*u*start.y + 2*u*t*control.y + t*t*end.y))
                }
            case .curve(to: let end, control1: let a, control2: let b):
                let start = current
                for i in 1...20 {
                    let t = Double(i)/20; let u = 1-t
                    append(CGPoint(x: u*u*u*start.x + 3*u*u*t*a.x + 3*u*t*t*b.x + t*t*t*end.x,
                                   y: u*u*u*start.y + 3*u*u*t*a.y + 3*u*t*t*b.y + t*t*t*end.y))
                }
            case .closeSubpath: append(first)
            }
        }
    }
    func point(_ fraction: Double, outward: Double = 0) -> CGPoint {
        guard length > 0, points.count > 1 else { return .zero }
        let f = fraction - floor(fraction)
        let distance = f * length
        var low = 1; var high = distances.count - 1
        while low < high { let mid = (low + high) / 2; if distances[mid] < distance { low = mid + 1 } else { high = mid } }
        let a = points[low - 1]; let b = points[low]
        let segment = max(0.0001, distances[low] - distances[low - 1])
        let t = (distance - distances[low - 1]) / segment
        return CGPoint(x: a.x + (b.x-a.x)*t - (b.y-a.y)/segment*outward,
                       y: a.y + (b.y-a.y)*t + (b.x-a.x)/segment*outward)
    }
}

struct MusicEdgeFrame: View {
    let shape: NotchShape
    let style: String
    let strength: Double
    let energy: Double
    let phase: Double
    let color: Color
    let reduced: Bool
    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 8, dy: 8)
            guard rect.width > 0, rect.height > 0 else { return }
            let outline = shape.path(in: rect)
            var mask = Path(CGRect(origin: .zero, size: size)); mask.addPath(outline)
            context.clip(to: mask, style: FillStyle(eoFill: true))
            let contour = EdgeContour(path: outline)
            let e = min(1, max(0, energy))
            if reduced { context.stroke(outline, with: .color(color.opacity(0.22)), lineWidth: 1); return }
            if style == "ripple" {
                for ring in 0..<2 {
                    let t = (phase * 0.9 + Double(ring) / 2).truncatingRemainder(dividingBy: 1)
                    var wave = Path()
                    for i in 0...180 {
                        let f = Double(i) / 180
                        let offset = 0.7 + t * (2 + e * 3) * strength + sin(f * .pi * 12 + phase * 4) * (0.2 + e * 0.7)
                        let p = contour.point(f == 1 ? 0 : f, outward: offset)
                        if i == 0 { wave.move(to: p) } else { wave.addLine(to: p) }
                    }
                    context.stroke(wave, with: .color(color.opacity((1-t) * (0.25+e*0.4))), lineWidth: 0.7)
                }
            } else {
                let count = style == "meteor" ? 7 : style == "mist" ? 85 : 44
                for i in 0..<count {
                    let seed = Double(i) * 0.61803398875
                    let f = seed + phase * (style == "meteor" ? 0.15 : 0.04)
                    let life = 0.5 + 0.5 * sin(phase * 2 + seed * 17)
                    let offset = min(5, (1 + life * (1 + e * 3)) * strength)
                    let point = contour.point(f, outward: offset)
                    let alpha = (0.18 + e * 0.65) * (0.25 + life * 0.75)
                    if style == "meteor" {
                        for tail in 0..<10 {
                            let p = contour.point(f - Double(tail) * (2 + e*2) / max(1,contour.length), outward: offset)
                            let r = 1.0 - Double(tail) * 0.065
                            context.fill(Path(ellipseIn: CGRect(x: p.x-r, y: p.y-r, width: 2*r, height: 2*r)),
                                         with: .color(color.opacity(alpha * (1-Double(tail)/10))))
                        }
                    } else {
                        let radius = style == "mist" ? 1.8 + life : 0.5 + life * 0.5
                        let dot = Path(ellipseIn: CGRect(x: point.x-radius, y: point.y-radius, width: 2*radius, height: 2*radius))
                        if style == "mist" {
                            context.fill(dot, with: .radialGradient(Gradient(colors: [color.opacity(alpha*0.45), .clear]), center: point, startRadius: 0, endRadius: radius))
                        } else { context.fill(dot, with: .color(color.opacity(alpha))) }
                    }
                }
            }
        }
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}

#if !EDGE_CHECKS
struct MusicEdgeEffect: View {
    let shape: NotchShape
    @ObservedObject private var music = MusicManager.shared
    @ObservedObject private var audio = MusicEdgeAudio.shared
    @AppStorage("musicEdgeStyle") private var style = "off"
    @AppStorage("musicEdgeStrength") private var strength = 1.0
    @AppStorage("musicEdgeReactive") private var reactive = true
    @Environment(\.accessibilityReduceMotion) private var reduced
    @State private var phase = 0.0
    @State private var previous = Date.now
    private var captureKey: String { "\(style != "off" && reactive && music.isPlaying && !reduced)-\(music.bundleIdentifier ?? "")" }
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !music.isPlaying || style == "off" || reduced)) { clock in
            let elapsed = music.elapsedTime + (music.isPlaying ? max(0, clock.date.timeIntervalSince(music.timestampDate)) * max(0, music.playbackRate) : 0)
            let ending = CompactLyrics.dissolve(at: elapsed, duration: music.songDuration)
            let period = CompactLyrics.timeOfDay(at: clock.date)
            let tint: Color = period == .dusk ? Color(red: 0.95, green: 0.80, blue: 0.67) : period == .day ? Color(red: 0.97, green: 0.94, blue: 0.86) : Color(white: period == .dawn ? 0.70 : 0.88)
            MusicEdgeFrame(shape: shape, style: style, strength: strength, energy: reactive ? audio.energy : 0,
                           phase: phase, color: tint, reduced: reduced)
                .opacity(style == "off" || !music.isPlaying ? 0 : (1-ending) * min(1, max(0, elapsed / 2)))
                .animation(.easeOut(duration: 0.4), value: music.isPlaying)
                .onChange(of: clock.date) { _, date in
                    phase += min(0.1, max(0, date.timeIntervalSince(previous))) * (0.4 + (reactive ? audio.energy : 0) * 1.8)
                    previous = date
                }
        }
        .padding(-8)
        .allowsHitTesting(false)
        .task(id: captureKey) { audio.configure(bundleID: music.bundleIdentifier, active: style != "off" && reactive && music.isPlaying && !reduced) }
    }
}

struct MusicEdgeSettings: View {
    @AppStorage("musicEdgeStyle") private var style = "off"
    @AppStorage("musicEdgeStrength") private var strength = 1.0
    @AppStorage("musicEdgeReactive") private var reactive = true
    @ObservedObject private var audio = MusicEdgeAudio.shared
    var body: some View {
        Picker("音乐边缘动效", selection: $style) {
            Text("关闭").tag("off"); Text("涟漪").tag("ripple"); Text("星尘").tag("dust")
            Text("流星").tag("meteor"); Text("光雾").tag("mist")
        }
        if style != "off" {
            Picker("效果强度", selection: $strength) {
                Text("轻柔").tag(0.7); Text("标准").tag(1.0); Text("鲜明").tag(1.3)
            }
            Toggle("跟随音乐强弱", isOn: $reactive)
            if reactive {
                Text(audio.status).font(.caption).foregroundStyle(.secondary)
                Text("首次使用需要系统的屏幕与系统音频录制权限。仅分析当前播放器音频强度，不保存录音；受保护内容可能无法响应。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

#endif
