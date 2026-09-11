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

// Assign color by emission, so a travelling wave never changes color mid-flight.
struct WaterWave {
    let progress: Double
    let paletteIndex: Int
    init(phase: Double, slot: Int) {
        let cycle = phase * 0.65 + Double(slot) / 3
        progress = cycle - floor(cycle)
        let emission = Int(floor(cycle)) * 3 - slot
        paletteIndex = ((emission % 5) + 5) % 5
    }
    static let colors: [Color] = [
        Color(red: 0.45, green: 0.68, blue: 0.94),
        Color(red: 0.69, green: 0.56, blue: 0.89),
        Color(red: 0.91, green: 0.59, blue: 0.69),
        Color(red: 0.91, green: 0.75, blue: 0.48),
        Color(red: 0.43, green: 0.79, blue: 0.74)
    ]
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
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 24, dy: 24)
            guard rect.width > 0, rect.height > 0 else { return }
            let outline = shape.path(in: rect)
            var mask = Path(CGRect(origin: .zero, size: size)); mask.addPath(outline)
            context.clip(to: mask, style: FillStyle(eoFill: true))
            let contour = EdgeContour(path: outline)
            let e = min(1, max(0, energy))
            guard style != "off" else { return }
            let isWater = style.hasPrefix("water")
            let isColorWater = style == "waterColor"
            let waterInk: GraphicsContext.Shading = .color(style == "waterWhite" ? .white : .black)
            if reduced {
                context.stroke(outline, with: isColorWater ? .color(WaterWave.colors[0]) : isWater ? waterInk : .color(color.opacity(0.4)), lineWidth: 2)
                return
            }
            if isWater {
                // All water palettes share the same geometry; content stays fixed inside the mask.
                func surface(distance: Double, amplitude: Double) -> Path {
                    let expanded = EdgeContour(path: shape.path(in: rect.insetBy(dx: -distance, dy: -distance)))
                    var path = Path()
                    for i in 0..<240 {
                        let f = Double(i) / 240
                        let undulation = sin(f * .pi * 10 - phase * 3) * 0.65
                            + sin(f * .pi * 18 + phase * 2) * 0.35
                        let base = expanded.point(f)
                        let taper = min(1, max(0, (base.y - rect.minY) / 12))
                        let point = expanded.point(f, outward: undulation * amplitude * taper)
                        if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                    path.closeSubpath()
                    return path
                }
                let reach = min(17, (isColorWater ? 14 + e * 4 : 10 + e * 8) * strength)
                // Three waves travel outwards and disappear before their phase wraps.
                for ring in 0..<3 {
                    let state = WaterWave(phase: phase, slot: ring)
                    let t = state.progress
                    let fade = sin(.pi * t) * (1 - t * (isColorWater ? 0.35 : 1))
                    let ringInk: GraphicsContext.Shading = isColorWater ? .color(WaterWave.colors[state.paletteIndex]) : waterInk
                    let wave = surface(distance: 2 + t * reach, amplitude: (0.5 + e) * strength)
                    var waveContext = context
                    waveContext.opacity *= fade * 0.9
                    waveContext.stroke(wave, with: ringInk, style: StrokeStyle(lineWidth: (isColorWater ? 1.7 + e * 0.5 : 2.5 + e * 1.5) * strength, lineCap: .round, lineJoin: .round))
                    // A faint water highlight preserves the contour on dark wallpaper.
                    context.stroke(wave, with: .color(.white.opacity(fade * 0.16)), style: StrokeStyle(lineWidth: 0.65, lineJoin: .round))
                }
                let edge = surface(distance: (isColorWater ? 1.5 : 2.5 + e * 2) * strength, amplitude: (isColorWater ? 0.3 : 0.6 + e * 1.4) * strength)
                context.fill(edge, with: waterInk)
                context.stroke(edge, with: .color((style == "waterWhite" ? Color.black : Color.white).opacity(0.10)), style: StrokeStyle(lineWidth: 0.65, lineJoin: .round))
                return
            }
            if style == "ripple" {
                for ring in 0..<3 {
                    let t = (phase * 0.9 + Double(ring) / 3).truncatingRemainder(dividingBy: 1)
                    let expanded = EdgeContour(path: shape.path(in: rect.insetBy(dx: -0.7 - t * (5 + e * 6) * strength, dy: -0.7 - t * (5 + e * 6) * strength)))
                    var wave = Path()
                    for i in 0...180 {
                        let f = Double(i) / 180
                        let offset = sin(f * .pi * 12 + phase * 4) * (0.4 + e * 1.0) * min(1, max(0, (expanded.point(f).y - rect.minY) / 12))
                        let p = expanded.point(f == 1 ? 0 : f, outward: offset)
                        if i == 0 { wave.move(to: p) } else { wave.addLine(to: p) }
                    }
                    context.stroke(wave, with: .color(color.opacity((1-t) * 0.22)), style: StrokeStyle(lineWidth: 4 * strength, lineJoin: .round))
                    context.stroke(wave, with: .color(color.opacity((1-t) * (0.72+e*0.25))), style: StrokeStyle(lineWidth: 1.7 * strength, lineJoin: .round))
                }
            } else {
                let count = style == "meteor" ? 11 : style == "mist" ? 110 : 78
                for i in 0..<count {
                    let seed = Double(i) * 0.61803398875
                    let f = seed + phase * (style == "meteor" ? 0.15 : 0.04)
                    let life = 0.5 + 0.5 * sin(phase * 2 + seed * 17)
                    let offset = (1.5 + life * (3 + e * 5)) * strength
                    let point = contour.point(f, outward: offset)
                    let alpha = (0.72 + e * 0.28) * (0.55 + life * 0.45)
                    if style == "meteor" {
                        for tail in 0..<24 {
                            let p = contour.point(f - Double(tail) * (2.2 + e*1.4) / max(1,contour.length), outward: offset)
                            let r = (1.9 - Double(tail) * 0.06) * strength
                            context.fill(Path(ellipseIn: CGRect(x: p.x-r, y: p.y-r, width: 2*r, height: 2*r)),
                                         with: .color(color.opacity(alpha * (1-Double(tail)/24))))
                        }
                    } else {
                        let radius = (style == "mist" ? 5 + life * 2.5 : 1.2 + life * 0.7) * strength
                        let dot = Path(ellipseIn: CGRect(x: point.x-radius, y: point.y-radius, width: 2*radius, height: 2*radius))
                        if style == "mist" {
                            context.fill(dot, with: .radialGradient(Gradient(colors: [color.opacity(alpha*0.85), .clear]), center: point, startRadius: 0, endRadius: radius))
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
                    phase += min(0.1, max(0, date.timeIntervalSince(previous))) * ((style.hasPrefix("water") ? 0.4 : 0.65) + (reactive ? audio.energy : 0) * 1.8)
                    previous = date
                }
        }
        .padding(-24)
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
        Picker("音乐边缘动效", selection: Binding(
            get: { style.hasPrefix("water") ? "water" : style },
            set: { choice in
                if choice != "water" || !style.hasPrefix("water") { style = choice }
            }
        )) {
            Text("关闭").tag("off"); Text("水波").tag("water")
            Text("涟漪").tag("ripple"); Text("星尘").tag("dust")
            Text("流星").tag("meteor"); Text("光雾").tag("mist")
        }
        if style.hasPrefix("water") {
            Picker("水波颜色", selection: $style) {
                Text("黑色").tag("water")
                Text("白色").tag("waterWhite")
                Text("彩色").tag("waterColor")
            }
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
