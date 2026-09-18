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
    func sample(_ fraction: Double) -> (point: CGPoint, normal: CGPoint) {
        guard length > 0, points.count > 1 else { return (.zero, .zero) }
        let f = fraction - floor(fraction)
        let distance = f * length
        var low = 1; var high = distances.count - 1
        while low < high { let mid = (low + high) / 2; if distances[mid] < distance { low = mid + 1 } else { high = mid } }
        let a = points[low - 1]; let b = points[low]
        let segment = max(0.0001, distances[low] - distances[low - 1])
        let t = (distance - distances[low - 1]) / segment
        return (CGPoint(x: a.x + (b.x-a.x)*t, y: a.y + (b.y-a.y)*t),
                CGPoint(x: -(b.y-a.y)/segment, y: (b.x-a.x)/segment))
    }
    func point(_ fraction: Double, outward: Double = 0) -> CGPoint {
        let sample = sample(fraction)
        return CGPoint(x: sample.point.x + sample.normal.x * outward,
                       y: sample.point.y + sample.normal.y * outward)
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

struct MusicEdgePlayback {
    let ambient: Bool
    let visible: Bool
    let speed: Double
    init(style: String, alwaysOn: Bool, playing: Bool, energy: Double) {
        ambient = alwaysOn && style.hasPrefix("water") && !playing
        visible = style != "off" && (playing || ambient)
        speed = ambient ? 0.12 : (style.hasPrefix("water") ? 0.4 : 0.65) + min(1, max(0, energy)) * 1.8
    }
}

struct MusicEdgeFrame: View {
    static let waterSampleCount = 120
    let shape: NotchShape
    let style: String
    let strength: Double
    let energy: Double
    let phase: Double
    let color: Color
    let reduced: Bool
    var sky = true
    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 24 + 48 * shape.rocket, dy: 24 + 48 * shape.rocket)
            guard rect.width > 0, rect.height > 0 else { return }
            let outline = shape.path(in: rect)
            var mask = Path(CGRect(origin: .zero, size: size)); mask.addPath(outline)
            context.clip(to: mask, style: FillStyle(eoFill: true))
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
                    for i in 0..<Self.waterSampleCount {
                        let f = Double(i) / Double(Self.waterSampleCount)
                        let undulation = sin(f * .pi * 10 - phase * 3) * 0.65
                            + sin(f * .pi * 18 + phase * 2) * 0.35
                        let sample = expanded.sample(f)
                        let taper = min(1, max(0, (sample.point.y - rect.minY) / 12))
                        let point = CGPoint(x: sample.point.x + sample.normal.x * undulation * amplitude * taper,
                                            y: sample.point.y + sample.normal.y * undulation * amplitude * taper)
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
                if isColorWater && sky { drawSky(in: &context, rect: rect, energy: e) }
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
                let contour = EdgeContour(path: outline)
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

    private func drawSky(in context: inout GraphicsContext, rect: CGRect, energy: Double) {
        // Decoration stays within the 24-point outer margin and shares the content mask.
        let drift = phase * 0.22
        let presence = min(1, 0.75 + energy * 0.15) * min(1.15, strength)
        for i in 0..<2 {
            let x = rect.minX + rect.width * (i == 0 ? 0.24 : 0.70) + sin(drift + Double(i) * 2) * 4
            let y = rect.maxY + 15 + sin(drift * 0.7 + Double(i)) * 1.2
            let scale = i == 0 ? 1.0 : 0.8
            var cloud = Path()
            cloud.move(to: CGPoint(x: -12, y: 3))
            cloud.addCurve(to: CGPoint(x: -7, y: -1), control1: CGPoint(x: -14, y: -1), control2: CGPoint(x: -10, y: -3))
            cloud.addCurve(to: CGPoint(x: 3, y: -3), control1: CGPoint(x: -6, y: -8), control2: CGPoint(x: 2, y: -8))
            cloud.addCurve(to: CGPoint(x: 10, y: 0), control1: CGPoint(x: 7, y: -6), control2: CGPoint(x: 11, y: -4))
            cloud.addCurve(to: CGPoint(x: 11, y: 5), control1: CGPoint(x: 16, y: 0), control2: CGPoint(x: 16, y: 5))
            cloud.addQuadCurve(to: CGPoint(x: -12, y: 3), control: CGPoint(x: 0, y: 7))
            cloud.closeSubpath()
            context.drawLayer { layer in
                layer.translateBy(x: x, y: y)
                layer.scaleBy(x: scale, y: scale)
                layer.opacity = presence
                layer.addFilter(.blur(radius: 0.65))
                layer.fill(cloud, with: .linearGradient(Gradient(colors: [
                    .white.opacity(0.55), WaterWave.colors[i].opacity(0.30), .clear
                ]), startPoint: CGPoint(x: 0, y: -7), endPoint: CGPoint(x: 0, y: 7)))
            }
        }
        for i in 0..<5 {
            let x = rect.minX + rect.width * [0.07, 0.39, 0.52, 0.86, 0.96][i]
            let y = rect.maxY + [17.0, 19.0, 15.0, 18.0, 10.0][i]
            let alpha = (0.40 + 0.22 * (0.5 + 0.5 * sin(drift * 2 + Double(i) * 1.7))) * presence
            let radius = i == 1 || i == 3 ? 1.9 : 0.8
            var star = Path()
            if radius > 1 {
                star.move(to: CGPoint(x: x, y: y-radius))
                star.addQuadCurve(to: CGPoint(x: x+radius, y: y), control: CGPoint(x: x+0.3, y: y-0.3))
                star.addQuadCurve(to: CGPoint(x: x, y: y+radius), control: CGPoint(x: x+0.3, y: y+0.3))
                star.addQuadCurve(to: CGPoint(x: x-radius, y: y), control: CGPoint(x: x-0.3, y: y+0.3))
                star.addQuadCurve(to: CGPoint(x: x, y: y-radius), control: CGPoint(x: x-0.3, y: y-0.3))
                star.closeSubpath()
            } else { star.addEllipse(in: CGRect(x: x-radius, y: y-radius, width: radius*2, height: radius*2)) }
            context.fill(star, with: .color(Color(red: 0.87, green: 0.90, blue: 0.98).opacity(alpha)))
        }
        let moonRect = CGRect(x: rect.maxX + 7, y: rect.maxY - 9 + sin(drift) * 0.8, width: 7, height: 7)
        let disc = Path(ellipseIn: moonRect)
        var crescent = disc
        crescent.addEllipse(in: moonRect.offsetBy(dx: 2.3, dy: -1.4))
        var moon = context
        moon.clip(to: disc)
        moon.fill(crescent, with: .color(Color(red: 0.88, green: 0.90, blue: 0.97).opacity(0.65 * presence)), style: FillStyle(eoFill: true))
    }
}

// Integrate the same exponential speed easing analytically, without per-frame state writes.
struct MusicEdgePhase {
    private var phase = 0.0
    private var speed = 0.4
    private var target = 0.4
    private var anchor = Date.now
    private var paused = true
    func value(at date: Date) -> Double {
        let dt = paused ? 0 : max(0, date.timeIntervalSince(anchor))
        return phase + target * dt + (speed - target) * 0.7 * (1 - exp(-dt / 0.7))
    }
    mutating func update(target next: Double, paused nextPaused: Bool, at date: Date) {
        let dt = paused ? 0 : max(0, date.timeIntervalSince(anchor))
        phase = value(at: date)
        speed = target + (speed - target) * exp(-dt / 0.7)
        target = next; paused = nextPaused; anchor = date
    }
}

#if !EDGE_CHECKS
struct MusicEdgeEffect: View, Animatable {
    var shape: NotchShape
    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { shape.animatableData }
        set { shape.animatableData = newValue }
    }
    @ObservedObject private var music = MusicManager.shared
    @ObservedObject private var audio = MusicEdgeAudio.shared
    @AppStorage("musicEdgeStyle") private var style = "off"
    @AppStorage("musicEdgeStrength") private var strength = 1.0
    @AppStorage("musicEdgeReactive") private var reactive = true
    @AppStorage("musicEdgeSky") private var sky = true
    @AppStorage("musicEdgeAlwaysOn") private var alwaysOn = false
    @Environment(\.accessibilityReduceMotion) private var reduced
    @ObservedObject private var motion = NotchMotionEnvironment.shared
    @State private var onScreen = false
    @State private var audioConsumer = UUID()
    @State private var phase = MusicEdgePhase()
    private var musicPlaying: Bool { music.isMusicSource && music.isPlaying }
    private var captureKey: String { "\(onScreen && style != "off" && reactive && musicPlaying && !reduced && !motion.suspended)-\(music.bundleIdentifier ?? "")" }
    var body: some View {
        let playback = MusicEdgePlayback(style: style, alwaysOn: alwaysOn, playing: musicPlaying, energy: reactive ? audio.energy : 0)
        let paused = !onScreen || motion.suspended || !playback.visible || reduced
        TimelineView(.animation(minimumInterval: NotchMotionEnvironment.decorativeFrameInterval(lowPower: playback.ambient || motion.lowPower), paused: paused)) { clock in
            let elapsed = music.elapsedTime + (musicPlaying ? max(0, clock.date.timeIntervalSince(music.timestampDate)) * max(0, music.playbackRate) : 0)
            let ending = CompactLyrics.dissolve(at: elapsed, duration: music.songDuration)
            let period = CompactLyrics.timeOfDay(at: clock.date)
            let tint: Color = period == .dusk ? Color(red: 0.95, green: 0.80, blue: 0.67) : period == .day ? Color(red: 0.97, green: 0.94, blue: 0.86) : Color(white: period == .dawn ? 0.70 : 0.88)
            MusicEdgeFrame(shape: shape, style: style, strength: playback.ambient ? strength * 0.75 : strength, energy: musicPlaying && reactive ? audio.energy : 0,
                           phase: phase.value(at: clock.date), color: tint, reduced: reduced, sky: sky)
                .opacity(!playback.visible ? 0 : alwaysOn && style.hasPrefix("water") ? 0.75 + (musicPlaying ? 0.25 * (1-ending) : 0) : (1-ending) * min(1, max(0, elapsed / 2)))
                .animation(.easeInOut(duration: 0.8), value: musicPlaying)
                .animation(.easeInOut(duration: 0.8), value: alwaysOn)
        }
        .onAppear { onScreen = true }
        .onDisappear {
            onScreen = false
            phase.update(target: playback.speed, paused: true, at: .now)
            audio.setDemand(audioConsumer, bundleID: nil, active: false)
        }
        .onChange(of: paused) { _, value in phase.update(target: playback.speed, paused: value, at: .now) }
        .onChange(of: playback.speed) { _, value in phase.update(target: value, paused: paused, at: .now) }
        .padding(-24 - 48 * shape.rocket)
        .allowsHitTesting(false)
        .task(id: captureKey) { audio.setDemand(audioConsumer, bundleID: music.bundleIdentifier, active: onScreen && style != "off" && reactive && musicPlaying && !reduced && !motion.suspended) }
    }
}

struct MusicEdgeSettings: View {
    @AppStorage("musicEdgeStyle") private var style = "off"
    @AppStorage("musicEdgeStrength") private var strength = 1.0
    @AppStorage("musicEdgeReactive") private var reactive = true
    @AppStorage("musicEdgeSky") private var sky = true
    @AppStorage("musicEdgeAlwaysOn") private var alwaysOn = false
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
            Toggle("水波常驻显示", isOn: $alwaysOn)
            if alwaysOn {
                Text("未播放音乐时，以更慢、更轻柔的节奏持续显示。").font(.caption).foregroundStyle(.secondary)
            }
            Picker("水波颜色", selection: $style) {
                Text("黑色").tag("water")
                Text("白色").tag("waterWhite")
                Text("彩色").tag("waterColor")
            }
        }
        if style == "waterColor" {
            Toggle("云与星月", isOn: $sky)
        }
        if style != "off" {
            Picker("效果强度", selection: $strength) {
                Text("轻柔").tag(0.7); Text("标准").tag(1.0); Text("鲜明").tag(1.3)
            }
            Toggle("跟随音乐强弱", isOn: $reactive)
            if reactive {
                Button("授权 / 重新连接音频") { audio.requestPermissionAndRetry() }
                Text(audio.status).font(.caption).foregroundStyle(.secondary)
                Text("首次使用需要系统的屏幕与系统音频录制权限。仅分析当前播放器音频强度，不保存录音；受保护内容可能无法响应。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

#endif
