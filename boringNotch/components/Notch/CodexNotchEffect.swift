import SwiftUI

enum CodexThrust {
    static let levels = ["low", "medium", "high", "xhigh", "max", "ultra"]
    static let labels = ["轻度", "中度", "高", "极高", "最高", "Ultra"]
    static func length(_ level: Int) -> Double { [0.55, 0.7, 0.85, 1.05, 1.4, 2.0][min(5, max(0, level))] }
    static func speed(_ level: Int) -> Double { [0.65, 0.8, 1, 1.3, 1.9, 3.0][min(5, max(0, level))] }
    @MainActor static func frameInterval(lowPower: Bool) -> Double { NotchMotionEnvironment.decorativeFrameInterval(lowPower: lowPower) }
    static func wakePoint(_ progress: Double, lane: Int, side: Double, rect: CGRect) -> CGPoint {
        let p = min(1, max(0, progress))
        let x = p * (rect.width + 40)
        let spread = (rect.height / 2 + 5 + Double(lane) * 3) * sqrt(1 - exp(-x / 10))
            + p * Double(lane) * 1.5
        return CGPoint(x: rect.minX + x, y: rect.midY + side * spread)
    }

}

enum CodexCompletionCue {
    static let flameOutDuration = 0.25
    static let ribbonDuration = 1.5
    static let particleCount = 88

    struct Particle {
        let position: CGPoint
        let opacity: Double
        let rotation: Double
        let tumble: Double
    }

    // Stable seeds keep each piece on the same trajectory across frames.
    static func seed(_ index: Int, _ salt: Int) -> Double {
        let mixed: Int = index * 127 + salt * 311
        let value: Int = (mixed + index * salt * 73) % 997
        return Double(value) / 997.0
    }

    static func particle(_ index: Int, at elapsed: Double) -> Particle {
        let delay = seed(index, 1) * 0.24
        let age = max(0, elapsed - delay)
        let lifetime = ribbonDuration - delay - seed(index, 10) * 0.18
        let progress = min(1, age / lifetime)
        let resistance = 1.8 + seed(index, 11) * 2.3
        let drag = (1 - exp(-resistance * age)) / resistance
        let flutter = sin(age * 10 + seed(index, 2) * .pi * 2) * (1 - exp(-5 * age))
        let fade = min(1, age / 0.04) * pow(min(1, (1 - progress) / 0.3), 1.5)
        let ribbon = index < 7
        let vx = ribbon ? 170 + seed(index, 3) * 150 : 70 + seed(index, 3) * 265
        let vy = -18 + seed(index, 4) * 180
        return Particle(
            position: CGPoint(x: vx * drag + flutter * age * 4,
                              y: vy * drag + (15 + seed(index, 12) * 30) * age * age + flutter * age * 5),
            opacity: elapsed >= delay && elapsed < ribbonDuration ? fade : 0,
            rotation: seed(index, 5) * .pi * 2 + age * (ribbon ? 1.8 : 4 + seed(index, 6) * 10),
            tumble: cos(age * (7 + seed(index, 7) * 9) + seed(index, 8) * .pi))
    }

}

struct CodexFlame: View {
    var active: Bool
    var effort: Int = -1
    @ObservedObject private var motion = NotchMotionEnvironment.shared
    @State private var onScreen = false
    @Environment(\.accessibilityReduceMotion) private var reduced
    var body: some View {
        TimelineView(.animation(minimumInterval: CodexThrust.frameInterval(lowPower: motion.lowPower), paused: !onScreen || motion.suspended || !active || reduced)) { timeline in
            Canvas { context, size in
                let h = size.height
                let time = reduced ? 0 : timeline.date.timeIntervalSinceReferenceDate * (effort < 0 ? 1 : CodexThrust.speed(effort))
                let pulse = reduced ? 0.0 : sin(time * 7) * 0.09 + sin(time * 13) * 0.04
                let bodyWidth = size.width - 80
                let nozzle = NotchShape.rocketCoordinate(bodyWidth + h * 0.182, width: bodyWidth, height: h)
                for layer in 0..<3 {
                    let scale = [1.0, 0.75, 0.44][layer]
                    let length = h * (reduced ? 0.45 : (effort < 0 ? 0.85 : CodexThrust.length(effort)) + pulse) * scale
                    let radius = h * (effort == 5 ? 0.30 : 0.23) * scale
                    let cy = h * 0.5
                    var flame = Path()
                    flame.move(to: CGPoint(x: nozzle, y: cy - radius))
                    flame.addCurve(to: CGPoint(x: nozzle + length, y: cy + sin(time * 9) * radius * 0.2),
                                   control1: CGPoint(x: nozzle + length * 0.35, y: cy - radius * 1.2),
                                   control2: CGPoint(x: nozzle + length * 0.75, y: cy - radius * 0.25))
                    flame.addCurve(to: CGPoint(x: nozzle, y: cy + radius),
                                   control1: CGPoint(x: nozzle + length * 0.6, y: cy + radius * 0.45),
                                   control2: CGPoint(x: nozzle + length * 0.3, y: cy + radius * 1.2))
                    flame.closeSubpath()
                    let boost = Double(max(0, min(5, effort) - 1)) / 4
                    let colors: [Color] = [Color.orange.opacity(0.45 + boost * 0.4),
                                           Color(red: 1, green: 0.5 + boost * 0.35, blue: boost * 0.3),
                                           Color(red: 1, green: 0.94 + boost * 0.06, blue: 0.72 + boost * 0.28)]
                    if layer == 0 && boost > 0 {
                        var glow = context
                        glow.addFilter(.blur(radius: 2 + boost * 3))
                        glow.fill(flame, with: .color(.orange.opacity(0.25 + boost * 0.3)))
                    }
                    context.fill(flame, with: .linearGradient(Gradient(colors: [colors[layer], colors[layer].opacity(0.2 + boost * 0.35)]),
                                                            startPoint: CGPoint(x: nozzle, y: cy), endPoint: CGPoint(x: nozzle + length, y: cy)))
                }
            }
            .padding(.trailing, -80)
        }
        .opacity(active ? 1 : 0)
        .animation(.easeOut(duration: reduced ? 0.15 : CodexCompletionCue.flameOutDuration), value: active)
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false }
        .allowsHitTesting(false)
    }
}

/// A one-shot completion cue emitted from the rocket nozzle after the flame fades.
struct CodexConfetti: View {
    var active: Bool
    @ObservedObject private var motion = NotchMotionEnvironment.shared
    @State private var onScreen = false
    @State private var startedAt = Date.distantPast
    @Environment(\.accessibilityReduceMotion) private var reduced

    var body: some View {
        TimelineView(.animation(minimumInterval: motion.lowPower ? 1.0 / 30 : 1.0 / 60,
                               paused: !onScreen || motion.suspended || !active || reduced)) { clock in
            Canvas { context, size in
                guard active, !reduced else { return }
                let elapsed = clock.date.timeIntervalSince(startedAt)
                CodexConfettiFrame.draw(in: &context, size: size, elapsed: elapsed)
            }
            .padding(.trailing, -192)
            .padding(.bottom, -200)
        }

        .onAppear { onScreen = true }
        .onDisappear { onScreen = false }
        .onChange(of: active, initial: true) { _, value in
            if value { startedAt = .now }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// Shared drawing allows the production effect to be checked at exact timestamps.
enum CodexConfettiFrame {
    static let colors: [Color] = [
        Color(red: 1, green: 0.76, blue: 0.27),
        Color(red: 1, green: 0.38, blue: 0.53),
        Color(red: 0.65, green: 0.48, blue: 1),
        Color(red: 0.25, green: 0.78, blue: 1),
        Color(red: 0.35, green: 0.91, blue: 0.72),
        Color(red: 1, green: 0.9, blue: 0.65)
    ]

    static func draw(in context: inout GraphicsContext, size: CGSize, elapsed: Double) {
        let height = max(0, size.height - 200)
        let width = max(0, size.width - 192)
        let nozzle = NotchShape.rocketCoordinate(width + height * 0.182, width: width, height: height)
        // A warm, brief muzzle flash precedes the paper; no persistent glow.
        if elapsed > 0 && elapsed < 0.16 {
            let flash = sin(.pi * elapsed / 0.16)
            var light = context
            light.addFilter(.blur(radius: 4))
            light.fill(Path(ellipseIn: CGRect(x: nozzle - 3, y: height / 2 - 5, width: 16, height: 10)),
                       with: .color(colors[0].opacity(flash * 0.65)))
        }
        // Fine distant pieces first, long satin ribbons last.
        for index in (0..<CodexCompletionCue.particleCount).reversed() {
            let particle = CodexCompletionCue.particle(index, at: elapsed)
            guard particle.opacity > 0 else { continue }
            let seed = CodexCompletionCue.seed(index, 9)
            let color = colors[index % colors.count]
            let depth = 0.5 + CodexCompletionCue.seed(index, 13) * 0.7
            var piece = context
            piece.opacity = particle.opacity * (0.65 + depth * 0.28)
            piece.translateBy(x: nozzle + particle.position.x, y: height / 2 + particle.position.y)
            if index < 7 {
                // A narrow filled band has folds and a lit edge, rather than a noodle-like stroke.
                piece.rotate(by: .radians(sin(particle.rotation) * 0.65))
                let length = (28 + seed * 22) * min(1, max(0, elapsed) / 0.2)
                let thickness = 1.6 + seed * 1.2
                var band = Path()
                var edge = Path()
                func point(_ step: Int, _ side: Double) -> CGPoint {
                    let u = Double(step) / 24
                    let curl = sin(u * .pi * 2.6 - elapsed * 8 + seed * 6)
                    return CGPoint(x: (u - 0.5) * length,
                                   y: curl * (3 + u * 3) + side * thickness * (0.4 + 0.6 * abs(cos(u * .pi * 2 - elapsed * 6))))
                }
                for step in 0...24 {
                    let p = point(step, -1)
                    if step == 0 { band.move(to: p); edge.move(to: p) }
                    else { band.addLine(to: p); edge.addLine(to: p) }
                }
                for step in (0...24).reversed() { band.addLine(to: point(step, 1)) }
                band.closeSubpath()
                piece.fill(band, with: .linearGradient(
                    Gradient(stops: [.init(color: color.opacity(0.6), location: 0),
                                     .init(color: color, location: 0.35),
                                     .init(color: .white.opacity(0.9), location: 0.52),
                                     .init(color: color, location: 0.7),
                                     .init(color: color.opacity(0.7), location: 1)]),
                    startPoint: CGPoint(x: -length / 2, y: -4), endPoint: CGPoint(x: length / 2, y: 4)))
                piece.stroke(edge, with: .color(.white.opacity(0.45)), lineWidth: 0.45)
            } else if index.isMultiple(of: 6) {
                // Tiny foil glints provide contrast between larger pieces.
                let radius = (1.4 + seed * 1.4) * depth
                piece.opacity *= 0.55 + 0.45 * abs(particle.tumble)
                var star = Path()
                star.move(to: CGPoint(x: 0, y: -radius * 1.6))
                star.addQuadCurve(to: CGPoint(x: radius, y: 0), control: .zero)
                star.addQuadCurve(to: CGPoint(x: 0, y: radius * 1.6), control: .zero)
                star.addQuadCurve(to: CGPoint(x: -radius, y: 0), control: .zero)
                star.addQuadCurve(to: CGPoint(x: 0, y: -radius * 1.6), control: .zero)
                piece.fill(star, with: .color(index.isMultiple(of: 12) ? colors[0] : .white))
            } else {
                piece.rotate(by: .radians(particle.rotation))
                piece.scaleBy(x: (0.16 + abs(particle.tumble) * 0.84) * depth, y: depth)
                let rect = CGRect(x: -2, y: -3, width: 3 + seed * 2.5, height: 4 + seed * 4)
                let paper = Path(roundedRect: rect, cornerRadius: 0.45)
                piece.fill(paper, with: .linearGradient(Gradient(colors: [color, color.opacity(0.65)]),
                    startPoint: CGPoint(x: rect.minX, y: rect.minY), endPoint: CGPoint(x: rect.maxX, y: rect.maxY)))
                piece.fill(Path(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * 0.3)),
                           with: .color(.white.opacity(max(0, particle.tumble) * 0.45)))
            }
        }
    }
}

struct CodexRocketSurface: View {
    let shape: NotchShape

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            RadialGradient(colors: [.white.opacity(0.22), .white.opacity(0.07), .clear],
                           center: UnitPoint(x: 0.28, y: 0.22),
                           startRadius: 0, endRadius: height * 0.9)
                .frame(width: height * 1.15)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .trailing) {
                    RadialGradient(colors: [.white.opacity(0.14), .white.opacity(0.04), .clear],
                                   center: UnitPoint(x: 0.88, y: 0.25),
                                   startRadius: 0, endRadius: height * 0.65)
                        .frame(width: height * 0.75)
                }
                .overlay {
                    shape.stroke(.white.opacity(0.18), lineWidth: 0.7)
                        .mask {
                            LinearGradient(colors: [.white, .clear], startPoint: .leading, endPoint: .trailing)
                                .frame(width: height * 0.9)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                }
                .clipShape(shape)
                .opacity(Double(min(1, max(0, shape.rocket))))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct CodexSpeedLines: View {
    let shape: NotchShape
    let effort: Int
    let active: Bool
    @ObservedObject private var motion = NotchMotionEnvironment.shared
    @State private var onScreen = false
    @Environment(\.accessibilityReduceMotion) private var reduced
    var body: some View {
        TimelineView(.animation(minimumInterval: CodexThrust.frameInterval(lowPower: motion.lowPower), paused: !onScreen || motion.suspended || !active || effort < 2 || reduced)) { clock in
            Canvas { context, size in
                guard active, effort >= 2, !reduced else { return }
                let rect = CGRect(origin: .zero, size: size).insetBy(dx: 48, dy: 48)
                let outline = shape.path(in: rect)
                let time = clock.date.timeIntervalSinceReferenceDate
                let speed = CodexThrust.speed(effort)
                let boost = Double(effort - 2) / 3
                var mask = Path(CGRect(origin: .zero, size: size))
                mask.addPath(outline)
                context.clip(to: mask, style: FillStyle(eoFill: true))
                // No stroke or glow can appear in front of the physical nose.
                context.clip(to: Path(CGRect(x: rect.minX, y: 0, width: size.width - rect.minX, height: size.height)))
                let lanes = effort == 5 ? 3 : 2
                for i in 0..<(lanes * 2) {
                    let lane = i % lanes
                    let side = (i / lanes) % 2 == 0 ? -1.0 : 1.0
                    let end = (time * speed * 0.30 + Double(i) * 0.61803398875).truncatingRemainder(dividingBy: 1)
                    let start = max(0, end - (16 + boost * 12) / (rect.width + 40))
                    let fade = pow(sin(.pi * end), 2)
                    var line = Path()
                    for step in 0...12 {
                        let point = CodexThrust.wakePoint(start + (end - start) * Double(step) / 12, lane: lane, side: side, rect: rect)
                        if step == 0 { line.move(to: point) } else { line.addLine(to: point) }
                    }
                    let tail = CodexThrust.wakePoint(start, lane: lane, side: side, rect: rect)
                    let head = CodexThrust.wakePoint(end, lane: lane, side: side, rect: rect)
                    let ink = GraphicsContext.Shading.linearGradient(Gradient(colors: [.black.opacity(0), .black.opacity(fade * (0.45 + boost * 0.2))]), startPoint: tail, endPoint: head)
                    context.stroke(line, with: ink, style: StrokeStyle(lineWidth: 0.75 + boost * 0.25, lineCap: .round))
                }
            }
        }.padding(-48).onAppear { onScreen = true }.onDisappear { onScreen = false }.allowsHitTesting(false)
    }
}

struct CodexLiquidDrop: View, Animatable {
    var progress: CGFloat
    var reduced = false
    var symbolOpacity: Double? = nil
    var reminderBrightness: Double = 1
    var hoverOffset: CGFloat = 0
    var mergeElapsed: Double? = nil
    var volumeScale: CGFloat = 1
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(progress, volumeScale) }
        set { progress = newValue.first; volumeScale = newValue.second }
    }
    var body: some View {
        let t = min(1, max(0, progress))
        let cy = -10 + max(0, progress) * 61 + hoverOffset
        Canvas { context, _ in
                if t < 0.78 && !reduced {
                    let neck = max(1, 13 * (1 - t / 0.78))
                    var bridge = Path()
                    bridge.move(to: CGPoint(x: 9, y: 0))
                    bridge.addCurve(to: CGPoint(x: 32 - neck, y: cy),
                                    control1: CGPoint(x: 30, y: 0), control2: CGPoint(x: 32 - neck, y: cy * 0.6))
                    bridge.addLine(to: CGPoint(x: 32 + neck, y: cy))
                    bridge.addCurve(to: CGPoint(x: 55, y: 0),
                                    control1: CGPoint(x: 32 + neck, y: cy * 0.6), control2: CGPoint(x: 34, y: 0))
                    bridge.closeSubpath()
                    var neckContext = context
                    neckContext.opacity = min(1, max(0, (0.78 - t) / 0.18))
                    neckContext.fill(bridge, with: .color(.black))
                }
                let radius: CGFloat = 16 * min(1, t * 1.8) * volumeScale
                let fusion = mergeElapsed.map { CodexMergeMotion.sample(at: $0) }
                let compression = reduced ? 0 : max(0, progress - 1) * 4 + (fusion?.pulse ?? 0)
                let stretch = reduced ? 0 : sin(.pi * min(1, t / 0.78)) * 0.12
                let rx = radius * (1 + compression) / (1 + stretch)
                let ry = radius * (1 + stretch) / (1 + compression)
                var drop = Path()
                let crown = cy - ry - 3 * t * volumeScale
                // Horizontal crown tangents and vertical side tangents avoid a pointed cusp.
                drop.move(to: CGPoint(x: 32, y: crown))
                drop.addCurve(to: CGPoint(x: 32 + rx, y: cy + ry * 0.1),
                              control1: CGPoint(x: 32 + rx * 0.3, y: crown),
                              control2: CGPoint(x: 32 + rx, y: cy - ry * 0.5))
                drop.addCurve(to: CGPoint(x: 32, y: cy + ry),
                              control1: CGPoint(x: 32 + rx, y: cy + ry * 0.65),
                              control2: CGPoint(x: 32 + rx * 0.55, y: cy + ry))
                drop.addCurve(to: CGPoint(x: 32 - rx, y: cy + ry * 0.1),
                              control1: CGPoint(x: 32 - rx * 0.55, y: cy + ry),
                              control2: CGPoint(x: 32 - rx, y: cy + ry * 0.65))
                drop.addCurve(to: CGPoint(x: 32, y: crown),
                              control1: CGPoint(x: 32 - rx, y: cy - ry * 0.5),
                              control2: CGPoint(x: 32 - rx * 0.3, y: crown))
                drop.closeSubpath()
                Self.drawLiquid(drop, center: CGPoint(x: 32, y: cy), in: &context,
                                reflection: Double(min(1, max(0, (t - 0.3) / 0.5))))
                if let fusion, fusion.radius > 0, !reduced {
                    let incomingY = -8 + (cy + 8) * fusion.travel
                    let incoming = Path(ellipseIn: CGRect(x: 32 - fusion.radius, y: incomingY - fusion.radius * 1.25,
                                                          width: fusion.radius * 2, height: fusion.radius * 2.5))
                    Self.drawLiquid(incoming, center: CGPoint(x: 32, y: incomingY), in: &context, reflection: Double(fusion.travel))
                    if fusion.travel < 0.3 {
                        let neck = (1 - fusion.travel / 0.3) * 5
                        var bridge = Path()
                        bridge.move(to: CGPoint(x: 24, y: 0))
                        bridge.addQuadCurve(to: CGPoint(x: 32 - neck, y: incomingY), control: CGPoint(x: 32, y: 0))
                        bridge.addLine(to: CGPoint(x: 32 + neck, y: incomingY))
                        bridge.addQuadCurve(to: CGPoint(x: 40, y: 0), control: CGPoint(x: 32, y: 0))
                        bridge.closeSubpath()
                        context.fill(bridge, with: .color(.black))
                    }
                }
                let alpha = (symbolOpacity ?? max(0, (t - 0.72) / 0.28)) * reminderBrightness
                var light = context
                light.opacity = alpha
                // Scale the symbol and its ring with the same volume as the liquid surface.
                light.translateBy(x: 32, y: cy)
                light.scaleBy(x: volumeScale, y: volumeScale)
                light.translateBy(x: -32, y: -cy)
                let ring = Path(ellipseIn: CGRect(x: 20.5, y: cy - 11.5, width: 23, height: 23))
                light.stroke(ring, with: .color(Color(red: 1, green: 0.9, blue: 0.65).opacity(0.24)), lineWidth: 0.6)
                if let bulb = context.resolveSymbol(id: "bulb") {
                    light.draw(bulb, at: CGPoint(x: 32, y: cy))
                }
        } symbols: {
            Image(systemName: "lightbulb")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color(red: 1, green: 0.9, blue: 0.65))
                .tag("bulb")
        }
        .frame(width: 64, height: 82)
    }

    // Keep every reflection inside the silhouette, including during stretch and fusion.
    private static func drawLiquid(_ path: Path, center: CGPoint, in context: inout GraphicsContext, reflection: Double) {
        let bounds = path.boundingRect
        let materialScale = min(bounds.width / 32, bounds.height / 35)
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: bounds.minX + bounds.width * x, y: bounds.minY + bounds.height * y)
        }
        context.fill(path, with: .color(.black))
        var surface = context
        surface.clip(to: path)
        surface.opacity *= reflection
        surface.fill(path, with: .radialGradient(
            Gradient(stops: [.init(color: Color(white: 0.24), location: 0),
                             .init(color: Color(white: 0.09), location: 0.38),
                             .init(color: .black, location: 0.85)]),
            center: point(0.28, 0.25), startRadius: 0, endRadius: max(1, bounds.height)))
        surface.fill(path, with: .radialGradient(
            Gradient(colors: [Color(red: 0.52, green: 0.61, blue: 0.69).opacity(0.3), .clear]),
            center: point(0.68, 1.06), startRadius: 0, endRadius: max(1, bounds.height * 0.48)))
        var rim = surface
        rim.addFilter(.blur(radius: 0.6 * materialScale))
        rim.stroke(path, with: .linearGradient(
            Gradient(colors: [.white.opacity(0.24), .white.opacity(0.02), .white.opacity(0.12)]),
            startPoint: point(0, 0), endPoint: point(1, 1)), lineWidth: 1.2 * materialScale)

        // Share the bulb ring's center; a soft concentric arc replaces the detached streak.
        let radius = min(bounds.width / 2, bounds.maxY - center.y) * 0.9
        var highlight = Path()
        highlight.addArc(center: center, radius: max(0, radius),
                         startAngle: .degrees(195), endAngle: .degrees(285), clockwise: false)
        var sheen = surface
        sheen.addFilter(.blur(radius: 0.65 * materialScale))
        sheen.stroke(highlight, with: .linearGradient(
            Gradient(colors: [.white.opacity(0.02), .white.opacity(0.32), .white.opacity(0.02)]),
            startPoint: CGPoint(x: center.x - radius, y: center.y),
            endPoint: CGPoint(x: center.x + radius * 0.3, y: center.y - radius)),
            style: StrokeStyle(lineWidth: max(0.8, bounds.width * 0.035), lineCap: .round))
    }

}

struct CodexDropButton: View {
    var waiting: Bool
    var expanded = false
    var count: Int
    var action: (CGPoint) -> Void
    @State private var anchorView = NSView(frame: .zero)
    @Binding var surface: CGFloat
    @ObservedObject private var motion = NotchMotionEnvironment.shared
    @State private var onScreen = false
    @Environment(\.accessibilityReduceMotion) private var reduced
    @State private var progress: CGFloat = 0
    @State private var visible = false
    @State private var symbolVisible = false
    @State private var idleSince: Date?
    @State private var targetCount = 0
    @State private var mergedCount = 0
    @State private var mergeStarted: Date?
    @State private var mergeTask: Task<Void, Never>?

    var body: some View {
        Button {
            let local = NSPoint(x: anchorView.bounds.midX, y: anchorView.bounds.maxY - 51)
            let anchor = anchorView.window?.convertPoint(toScreen: anchorView.convert(local, to: nil)) ?? NSEvent.mouseLocation
            action(anchor)
        } label: {
            TimelineView(.animation(minimumInterval: CodexThrust.frameInterval(lowPower: motion.lowPower), paused: !onScreen || motion.suspended || idleSince == nil || reduced)) { clock in
                let reminder = idleSince.map { CodexDropMotion.reminder(at: clock.date.timeIntervalSince($0)) }
                let idleOffset = reduced ? 0 : reminder?.offset ?? 0
                let brightness = reduced ? 1 : reminder?.brightness ?? 1
                let mergeTime = mergeStarted.map { clock.date.timeIntervalSince($0) }
                let addition = mergeTime.map { CodexMergeMotion.absorbed(at: $0) } ?? 0
                CodexLiquidDrop(progress: progress, reduced: reduced, symbolOpacity: symbolVisible ? 1 : 0, reminderBrightness: brightness, hoverOffset: idleOffset, mergeElapsed: mergeTime,
                                volumeScale: CodexMergeMotion.scale(for: Double(max(1, mergedCount)) + addition))
                .overlay(alignment: .bottomTrailing) {
                    if count > 1 {
                        Text("\(count)").font(.system(size: 9, weight: .bold)).padding(3)
                            .background(.orange, in: Circle()).padding(.trailing, 8).padding(.bottom, 8)
                    }
                }
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .background(CodexDropAnchor(view: anchorView))
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false; idleSince = nil; surface = 0; cancelMerging() }
        .onChange(of: count, initial: true) { _, value in
            if value < targetCount { cancelMerging() }
            targetCount = max(0, value)
            if targetCount > 0 && targetCount < mergedCount {
                withAnimation(reduced ? nil : .easeInOut(duration: 0.3)) { mergedCount = targetCount }
            }
            startMerging()
        }
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(waiting && visible && !expanded)
        .accessibilityLabel("Codex 有 \(count) 个请求需要你处理")
        .accessibilityHint("打开待处理任务窗口")
        .accessibilityHidden(!visible || expanded)
        .help("查看 Codex 的待处理请求")
        .task(id: "\(waiting)-\(reduced)-\(motion.suspended)") {
            if !waiting || reduced || motion.suspended { cancelMerging() }
            if motion.suspended {
                mergedCount = count
                idleSince = nil; surface = 0; progress = waiting ? 1 : 0
                visible = waiting; symbolVisible = waiting
                return
            }
            do {
                if reduced {
                    mergedCount = count
                    idleSince = nil
                    surface = 0
                    symbolVisible = waiting
                    progress = waiting ? 1 : 0
                    withAnimation(.easeInOut(duration: 0.15)) { visible = waiting }
                } else if waiting {
                    if !visible { try await Task.sleep(for: .milliseconds(550)) }
                    try Task.checkCancellation()
                    let alreadySettled = visible && progress == 1
                    visible = true
                    if !alreadySettled { try await move(CodexDropMotion.fall, reveal: true) }
                    if mergedCount == 0 { mergedCount = 1 }
                    idleSince = .now
                    startMerging()
                } else if visible {
                    idleSince = nil
                    surface = 0
                    try await move(CodexDropMotion.returning, reveal: false)
                    try Task.checkCancellation()
                    visible = false
                    symbolVisible = false
                    progress = 0
                    mergedCount = 0
                } else {
                    surface = 0
                }
            } catch { /* A new state continues from the current presentation values. */ }
        }
        // Hovering changes presentation only; keep the reminder's fall, size and idle phase alive.
        .opacity(expanded ? 0 : 1)
        .offset(y: expanded && !reduced ? -16 : 0)
        .animation(.easeInOut(duration: reduced ? 0.15 : 0.24), value: expanded)
    }

    private func cancelMerging() {
        mergeTask?.cancel(); mergeTask = nil; mergeStarted = nil
    }
    private func startMerging() {
        guard waiting, visible, idleSince != nil, !reduced, !motion.suspended,
              mergeTask == nil, targetCount > mergedCount else { return }
        mergeTask = Task { @MainActor in
            do {
                while mergedCount < targetCount {
                    try Task.checkCancellation()
                    mergeStarted = .now
                    try await Task.sleep(for: .seconds(CodexMergeMotion.duration))
                    try Task.checkCancellation()
                    mergedCount = min(targetCount, mergedCount + 1)
                    mergeStarted = nil
                }
                mergeTask = nil
            } catch { /* Lifecycle change already reset the merge state. */ }
        }
    }

    private func move(_ frames: [CodexDropMotion.Frame], reveal: Bool) async throws {
        let initial = CodexDropMotion.Frame(progress: progress, surface: surface, duration: 0)
        let started = ProcessInfo.processInfo.systemUptime
        let duration = frames.reduce(0) { $0 + $1.duration }
        while true {
            try Task.checkCancellation()
            let elapsed = min(duration, ProcessInfo.processInfo.systemUptime - started)
            let sample = CodexDropMotion.sample(frames, initial: initial, time: elapsed)
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                progress = sample.progress
                surface = sample.surface
            }
            if reveal && progress > 0.86 { symbolVisible = true }
            if !reveal { symbolVisible = progress > 0.86 }
            if elapsed >= duration { return }
            try await Task.sleep(for: .milliseconds(16))
        }
    }

}

// Read the actual drop position; click location varies across its hit area.
private struct CodexDropAnchor: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// Shared keyframes make the two landing rebounds and the return sequence testable.
enum CodexDropMotion {
    static func reminder(at elapsed: Double) -> (offset: CGFloat, brightness: Double) {
        let t = max(0, elapsed)
        let settling = exp(-max(0, t - 12) / 8)
        return (-1.5 * settling * (1 - cos(t * 2 * .pi / 3.6)),
                0.86 + 0.14 * settling + (0.08 + 0.20 * settling) * (cos(t * 2 * .pi / 2.8) - 1))
    }

    struct Frame {
        let progress: CGFloat
        let surface: CGFloat
        let duration: Double
    }
    // Continuous monotone Hermite interpolation preserves velocity across descent
    // nodes; only actual bounce extrema settle to zero velocity.
    static func sample(_ frames: [Frame], initial: Frame, time: Double) -> Frame {
        let nodes = [initial] + frames
        let times = frames.reduce(into: [0.0]) { $0.append($0.last! + $1.duration) }
        guard let segment = (1..<times.count).first(where: { time < times[$0] }) else { return nodes.last! }
        let i = segment - 1
        let h = times[i + 1] - times[i]
        let u = min(1, max(0, (time - times[i]) / h))
        func interpolate(_ value: (Frame) -> CGFloat) -> CGFloat {
            func slope(_ j: Int) -> Double {
                guard j > 0, j < nodes.count - 1 else { return 0 }
                let a = Double(value(nodes[j]) - value(nodes[j - 1])) / (times[j] - times[j - 1])
                let b = Double(value(nodes[j + 1]) - value(nodes[j])) / (times[j + 1] - times[j])
                return a * b > 0 ? 2 * a * b / (a + b) : 0
            }
            return CGFloat((2*u*u*u - 3*u*u + 1) * Double(value(nodes[i]))
                + (u*u*u - 2*u*u + u) * h * slope(i)
                + (-2*u*u*u + 3*u*u) * Double(value(nodes[i + 1]))
                + (u*u*u - u*u) * h * slope(i + 1))
        }
        return Frame(progress: interpolate { $0.progress }, surface: interpolate { $0.surface }, duration: 0)
    }
    static let fall: [Frame] = [
        .init(progress: 0.38, surface: 8, duration: 0.24),
        .init(progress: 0.76, surface: 4, duration: 0.18),
        .init(progress: 1.06, surface: 0, duration: 0.18),
        .init(progress: 0.79, surface: 3.5, duration: 0.17),
        .init(progress: 1.025, surface: 0, duration: 0.17),
        .init(progress: 0.93, surface: 1.2, duration: 0.13),
        .init(progress: 1, surface: 0, duration: 0.17)
    ]
    // Reverse both the destinations and segment durations of the birth animation.
    static let returning: [Frame] = fall.indices.reversed().map { index in
        let destination = index == 0 ? Frame(progress: 0, surface: 0, duration: 0) : fall[index - 1]
        return Frame(progress: destination.progress, surface: destination.surface, duration: fall[index].duration)
    }

}

/// Fixed housing; only the fuel surface moves, so the symbol stays crisp.
struct CodexFuelGauge: View {
    let fuel: CodexFuel?
    @ObservedObject private var motion = NotchMotionEnvironment.shared
    @State private var onScreen = false
    @Environment(\.accessibilityReduceMotion) private var reduced
    private var tint: Color {
        guard let fuel else { return .gray }
        return fuel.remainingPercent < 10 ? Color(red: 1, green: 0.48, blue: 0.43)
            : fuel.remainingPercent < 20 ? Color(red: 1, green: 0.76, blue: 0.35)
            : Color(white: 0.85)
    }
    var body: some View {
        TimelineView(.animation(minimumInterval: motion.lowPower ? 1.0 / 15 : 1.0 / 30, paused: !onScreen || motion.suspended || reduced || fuel == nil)) { tick in
            CodexFuelFrame(level: (fuel?.remainingPercent ?? 0) / 100,
                           phase: reduced ? 0 : tick.date.timeIntervalSinceReferenceDate,
                           tint: tint, available: fuel != nil)
                .animation(reduced ? nil : .easeInOut(duration: 0.8), value: fuel?.remainingPercent)
        }
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false }
        .help(fuel?.description ?? "Codex · 额度暂不可用")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(fuel?.description ?? "Codex · 额度暂不可用")
    }
}

private struct CodexFuelFrame: View, Animatable {
    var level: Double
    let phase: Double
    let tint: Color
    let available: Bool
    var animatableData: Double {
        get { level }
        set { level = newValue }
    }
    var body: some View {
        Canvas { context, size in
            let box = CGRect(x: size.width * 0.16, y: 1,
                             width: size.width * 0.68, height: max(0, size.height - 2))
            let shell = Path(roundedRect: box, cornerRadius: 4)
            context.fill(shell, with: .color(Color(white: 0.12)))
            if available && level > 0 {
                let inset = box.insetBy(dx: 1.5, dy: 1.5)
                let surface = inset.maxY - inset.height * min(1, max(0, level))
                var liquid = Path()
                liquid.move(to: CGPoint(x: inset.minX, y: surface))
                liquid.addCurve(to: CGPoint(x: inset.maxX, y: surface),
                                control1: CGPoint(x: inset.minX + inset.width / 3, y: surface + sin(phase * 1.4) * 0.65),
                                control2: CGPoint(x: inset.maxX - inset.width / 3, y: surface - sin(phase * 1.4) * 0.65))
                liquid.addLine(to: CGPoint(x: inset.maxX, y: inset.maxY))
                liquid.addLine(to: CGPoint(x: inset.minX, y: inset.maxY))
                liquid.closeSubpath()
                var fill = context
                fill.clip(to: Path(roundedRect: inset, cornerRadius: 2.5))
                fill.fill(liquid, with: .color(tint.opacity(0.8)))
            }
            context.stroke(shell, with: .color(tint.opacity(available ? 0.85 : 0.5)), lineWidth: 1)
            var symbol = context.resolve(Image(systemName: available ? "fuelpump.fill" : "questionmark"))
            symbol.shading = .color(.white.opacity(0.95))
            context.draw(symbol,
                         in: CGRect(x: size.width / 2 - 4.5, y: size.height / 2 - 4.5, width: 9, height: 9))
        }
    }
}


// Growth follows absorption; cap radius to keep the clickable drop inside its 64x82 slot.
enum CodexMergeMotion {
    static let duration = 0.85
    static func scale(for count: Double) -> CGFloat {
        guard count.isFinite else { return 1 }
        return CGFloat(min(1.7, 1 + 0.25 * log2(max(1, count))))
    }
    static func absorbed(at elapsed: Double) -> Double {
        let t = min(1, max(0, (elapsed / duration - 0.5) / 0.5))
        return t * t * (3 - 2 * t)
    }
    static func sample(at elapsed: Double) -> (travel: CGFloat, radius: CGFloat, pulse: CGFloat) {
        let t = min(1, max(0, elapsed / duration))
        let travel = min(1, pow(t / 0.68, 2))
        let radius = 7 * min(1, t / 0.10) * max(0, min(1, (0.75 - t) / 0.18))
        let impact = max(0, min(1, (t - 0.55) / 0.45))
        return (travel, radius, sin(impact * .pi * 2) * 0.10 * (1 - impact))
    }
}


// Keep native controls live: never render the card through a Canvas symbol.
struct CodexCardReveal: AnimatableModifier {
    static let duration = 0.65
    var progress: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduced
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    static func outline(size: CGSize, progress: CGFloat) -> Path {
        let t = 1 - min(1, max(0, progress))
        if t == 1 { return Path(CGRect(origin: .zero, size: size)) }
        func smooth(_ value: CGFloat) -> CGFloat {
            let u = min(1, max(0, value))
            return u * u * (3 - 2 * u)
        }
        let seed = min(32, size.width, size.height)
        let width = seed + (size.width - seed) * smooth(t / 0.72)
        let height = seed + (size.height - seed) * smooth((t - 0.08) / 0.82)
        let radius = 16 + 4 * t + 28 * sin(.pi * t)
        return Path(roundedRect: CGRect(x: (size.width - width) / 2, y: 0, width: width, height: height),
                    cornerRadius: min(radius, width / 2, height / 2))
    }

    static func settlingOffset(progress: CGFloat) -> CGFloat {
        let t = 1 - min(1, max(0, progress))
        let settle = min(1, max(0, (t - 0.62) / 0.38))
        let wave = sin(.pi * settle)
        // Zero velocity and acceleration at both ends avoid the old abrupt stop.
        return 1.2 * wave * wave * wave
    }

    func body(content: Content) -> some View {
        let t = 1 - min(1, max(0, progress))
        content
            // Reveal the native controls without stretching their text or taking snapshots.
            .overlay {
                GeometryReader { geometry in
                    Self.outline(size: geometry.size, progress: progress)
                        .stroke(.white.opacity(reduced ? 0 : Double(sin(.pi * t)) * 0.12), lineWidth: 0.8)
                }.allowsHitTesting(false)
            }
            .mask {
                GeometryReader { geometry in
                    Self.outline(size: geometry.size, progress: reduced ? 0 : progress).fill(.white)
                }
            }
            .opacity(reduced ? Double(t) : Double(min(1, t / 0.12)))
            .offset(y: reduced ? 0 : Self.settlingOffset(progress: progress))
    }
}

// The dissolving boundary converges on the top-center droplet attachment point.
// The mask retains hit testing so native fields and buttons don't become click-through.
struct CodexDissolve: AnimatableModifier {
    static let duration = 0.8
    var progress: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduced
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }
    func body(content: Content) -> some View {
        content.mask {
            if reduced {
                Color.white.opacity(1 - Double(min(1, max(0, progress))))
            } else {
                Canvas { context, size in
                    let p = min(1, max(0, progress))
                    guard p < 1, size.width > 0, size.height > 0 else { return }
                    if p == 0 {
                        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
                        return
                    }
                    let columns = max(1, Int(ceil(size.width / 5)))
                    let rows = max(1, Int(ceil(size.height / 5)))
                    let w = size.width / CGFloat(columns), h = size.height / CGFloat(rows)
                    for row in 0..<rows {
                        for column in 0..<columns {
                            let x = (CGFloat(column) + 0.5) / CGFloat(columns)
                            let y = (CGFloat(row) + 0.5) / CGFloat(rows)
                            // Bottom and side edges dissolve first; the final remnant stays by the droplet.
                            let depth = 1 - min(1, hypot((x - 0.5) * 2, y))
                            let seed = CGFloat((row * 73 + column * 137 + row * column * 19) % 101) / 100
                            let local = min(1, max(0, (p - depth * 0.62 - seed * 0.12) / 0.26))
                            let fade = local * local * (3 - 2 * local)
                            guard fade < 1 else { continue }
                            let inset = fade * min(w, h) * 0.32
                            let rect = CGRect(x: CGFloat(column) * w + inset,
                                              y: CGFloat(row) * h + inset,
                                              width: w - inset * 2, height: h - inset * 2)
                                // Overlap intact cells to avoid antialiasing seams in the solid center.
                                .insetBy(dx: -0.35 * (1 - fade), dy: -0.35 * (1 - fade))
                                .offsetBy(dx: (0.5 - x) * fade * 5, dy: -fade * (2 + y * 4))
                            context.fill(Path(roundedRect: rect, cornerRadius: inset),
                                         with: .color(.white.opacity(Double(1 - fade))))
                        }
                    }
                }
            }
        }
    }
}
