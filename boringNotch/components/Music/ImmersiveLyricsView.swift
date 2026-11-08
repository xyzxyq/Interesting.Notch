import SwiftUI

/// The playback clock is shared with compact lyrics; only this small surface redraws.
struct ImmersiveLyricsView: View, Equatable {
    static let projectionSize = CGSize(width: 640, height: 66)
    let segments: [LyricSegment]
    let position: Double
    let sampleDate: Date
    let rate: Double
    let duration: Double
    let offset: Double
    let sourceWidth: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.segments == rhs.segments && lhs.position == rhs.position
            && lhs.sampleDate == rhs.sampleDate && lhs.rate == rhs.rate
            && lhs.duration == rhs.duration && lhs.offset == rhs.offset
            && lhs.sourceWidth == rhs.sourceWidth
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Keep the native glass and its mask alive across every lyric and interlude.
            ImmersiveProjectorBackdrop(sourceWidth: sourceWidth,
                time: 0, reducedTransparency: reduceTransparency)
            TimelineView(.explicit(ImmersiveFocus.lyricUpdateDates(segments: segments,
                position: position, sampleDate: sampleDate, rate: rate, duration: duration, offset: offset))) { tick in
                let elapsed = max(0, position + max(0, max(tick.date, Date()).timeIntervalSince(sampleDate)) * max(0, rate))
                let lyricTime = elapsed + offset
                let neighbors = CompactLyrics.neighbors(at: lyricTime, cues: segments)
                let finished = duration > 0 && elapsed >= duration
                let cue = finished ? nil : neighbors.current.flatMap { $0.text.isEmpty ? nil : $0 }
                let outgoing = finished || reduceMotion ? nil : neighbors.outgoing
                ZStack(alignment: .top) {
                    ImmersiveProjectionMotion(sourceWidth: sourceWidth,
                        waiting: cue == nil && outgoing == nil && !finished,
                        animated: !reduceMotion && rate > 0, cue: cue,
                        cueAge: cue.map { lyricTime - $0.start } ?? 0)
                        .frame(width: 200, height: Self.projectionSize.height)
                    if cue != nil || outgoing != nil {
                        ImmersiveAnimatedLyrics(current: cue, outgoing: outgoing,
                            position: position + offset, sampleDate: sampleDate, rate: rate,
                            reduceMotion: reduceMotion)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(cue?.text ?? (finished ? "" : segments.isEmpty ? "音乐播放中，暂无同步歌词" : "音乐间奏"))
            }
        }
        .frame(height: Self.projectionSize.height)
        .allowsHitTesting(false)
    }
}

private struct ImmersiveAnimatedLyrics: View {
    let current: LyricSegment?
    let outgoing: LyricSegment?
    let position: Double
    let sampleDate: Date
    let rate: Double
    let reduceMotion: Bool

    var body: some View {
        // Measuring text belongs to a cue change, not to every animation frame.
        let width = ImmersiveLyricLine.measure(current?.text ?? "")
        let outgoingWidth = ImmersiveLyricLine.measure(outgoing?.text ?? "")
        let age = current.map { position + max(0, Date().timeIntervalSince(sampleDate)) * max(0, rate) - $0.start } ?? 0
        let interval = ImmersiveFocus.lyricFrameInterval(width: min(width, 556),
            duration: current.map { $0.end - $0.start } ?? 0, rate: rate,
            transitioning: outgoing != nil || age < 0.18)
        TimelineView(.animation(minimumInterval: interval, paused: reduceMotion || rate <= 0)) { tick in
            let lyricTime = position + max(0, tick.date.timeIntervalSince(sampleDate)) * max(0, rate)
            ZStack(alignment: .top) {
                if let outgoing {
                    ImmersiveLyricLine(text: outgoing.text,
                        dissolve: ImmersiveFocus.dissolveProgress(at: lyricTime, end: outgoing.end),
                        measuredWidth: outgoingWidth)
                }
                if let current {
                    ImmersiveLyricLine(text: current.text, dissolve: -1,
                        waveProgress: ImmersiveFocus.waveProgress(at: lyricTime, start: current.start, end: current.end),
                        measuredWidth: width)
                        .opacity(reduceMotion ? 1 : min(1, max(0, (lyricTime - current.start) / 0.18)))
                }
            }
        }
    }
}

/// One persistent native stage shares timing between the spirits and the projector.
struct ImmersiveProjectionMotion: NSViewRepresentable {
    let sourceWidth: CGFloat
    let waiting: Bool
    let animated: Bool
    let cue: LyricSegment?
    let cueAge: Double

    func makeNSView(context: Context) -> Stage { Stage() }
    func updateNSView(_ view: Stage, context: Context) {
        view.update(sourceWidth: sourceWidth, waiting: waiting, animated: animated, cue: cue, cueAge: cueAge)
    }
    static func dismantleNSView(_ view: Stage, coordinator: ()) { view.stop() }

    final class Stage: NSView {
        private let glow = CAShapeLayer()
        private let pulse = CAGradientLayer()
        private let spirits = (0..<3).map { _ in CALayer() }
        private let echoes = (0..<3).map { _ in CAGradientLayer() }
        private var sourceWidth: CGFloat = 0
        private var waiting = false
        private var animated = false
        private var lastCue: LyricSegment?
        override var isFlipped: Bool { true }

        init() {
            super.init(frame: NSRect(x: 0, y: 0, width: 200, height: 66))
            wantsLayer = true
            glow.fillColor = nil
            glow.strokeColor = NSColor.white.withAlphaComponent(0.7).cgColor
            glow.lineWidth = 1.2
            glow.lineCap = .round
            glow.shadowColor = NSColor.white.cgColor
            glow.shadowRadius = 2
            glow.shadowOpacity = 0.3
            glow.shadowOffset = .zero
            glow.opacity = 0
            layer?.addSublayer(glow)
            pulse.bounds = CGRect(x: 0, y: 0, width: 160, height: 48)
            pulse.anchorPoint = CGPoint(x: 0.5, y: 0)
            pulse.position = CGPoint(x: 100, y: 2)
            pulse.colors = [NSColor.clear.cgColor, NSColor.white.withAlphaComponent(0.65).cgColor,
                            NSColor.white.withAlphaComponent(0.65).cgColor, NSColor.clear.cgColor]
            pulse.locations = [0, 0.25, 0.75, 1]
            pulse.startPoint = CGPoint(x: 0, y: 0.5)
            pulse.endPoint = CGPoint(x: 1, y: 0.5)
            let arc = CAShapeLayer()
            arc.frame = pulse.bounds
            let wavefront = CGMutablePath()
            wavefront.addArc(center: .zero, radius: 44, startAngle: .pi / 6, endAngle: .pi * 5 / 6,
                             clockwise: false, transform: CGAffineTransform(a: 1.7, b: 0, c: 0, d: 1, tx: 80, ty: 0))
            arc.path = wavefront
            arc.fillColor = nil
            arc.strokeColor = NSColor.white.cgColor
            arc.lineWidth = 1.6
            arc.lineCap = .round
            pulse.mask = arc
            pulse.shadowColor = NSColor.black.cgColor
            pulse.shadowOpacity = 0.15
            pulse.shadowRadius = 1
            pulse.shadowOffset = .zero
            pulse.opacity = 0
            layer?.addSublayer(pulse)
            for index in 0..<3 {
                let echo = echoes[index]
                echo.isHidden = true
                echo.frame = CGRect(x: 80, y: 0, width: 40, height: 18)
                echo.type = .radial
                echo.startPoint = CGPoint(x: 0.5, y: 0.2)
                echo.endPoint = CGPoint(x: 1, y: 1)
                echo.colors = [NSColor.white.withAlphaComponent(0.6).cgColor, NSColor.clear.cgColor]
                layer?.addSublayer(echo)
                let spirit = spirits[index]
                spirit.isHidden = true
                spirit.bounds = CGRect(x: 0, y: 0, width: 6, height: 6)
                spirit.position = CGPoint(x: 82 + index * 18, y: 41)
                spirit.cornerRadius = 3
                spirit.masksToBounds = true
                spirit.backgroundColor = NSColor.black.cgColor
                layer?.addSublayer(spirit)
            }
        }

        required init?(coder: NSCoder) { nil }

        func update(sourceWidth: CGFloat, waiting: Bool, animated: Bool, cue: LyricSegment?, cueAge: Double) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }
            if self.sourceWidth != sourceWidth {
                self.sourceWidth = sourceWidth
                let aperture = min(36, sourceWidth * 0.15) / 2
                let receiver = min(120, sourceWidth * 0.5) / 2
                let path = CGMutablePath()
                path.move(to: CGPoint(x: 100 - aperture, y: 2))
                path.addLine(to: CGPoint(x: 100 - receiver, y: 15))
                path.move(to: CGPoint(x: 100 + aperture, y: 2))
                path.addLine(to: CGPoint(x: 100 + receiver, y: 15))
                glow.path = path
            }
            if self.animated != animated {
                glow.removeAllAnimations()
                glow.opacity = animated ? 0.18 : 0
                if animated {
                    let breath = CAKeyframeAnimation(keyPath: "opacity")
                    breath.values = [0.06, 0.20, 0.06]
                    breath.duration = 5.6
                    breath.repeatCount = .infinity
                    breath.calculationMode = .cubic
                    breath.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
                    glow.add(breath, forKey: "breath")
                }
            }
            if self.waiting != waiting || self.animated != animated {
                for index in 0..<3 {
                    spirits[index].removeAllAnimations()
                    echoes[index].removeAllAnimations()
                    spirits[index].isHidden = !waiting
                    echoes[index].isHidden = !waiting || !animated
                    echoes[index].opacity = 0
                    if waiting && animated { animateSpirit(index) }
                }
            }
            if cue != lastCue || self.animated != animated {
                pulse.removeAllAnimations()
                if animated, cue != nil, cueAge.isFinite, (0..<0.62).contains(cueAge) {
                    let expand = CAKeyframeAnimation(keyPath: "transform.scale")
                    expand.values = [0.05, 0.35, 0.8, 1.05]
                    let fade = CAKeyframeAnimation(keyPath: "opacity")
                    fade.values = [0, 0.55, 0.28, 0]
                    for animation in [expand, fade] {
                        animation.keyTimes = [0, 0.22, 0.65, 1]
                        animation.duration = 0.62
                        animation.calculationMode = .cubic
                    }
                    let burst = CAAnimationGroup()
                    burst.animations = [expand, fade]
                    burst.duration = 0.62
                    burst.beginTime = pulse.convertTime(CACurrentMediaTime() - cueAge, from: nil)
                    burst.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 30, preferred: 30)
                    pulse.add(burst, forKey: "projection")
                }
            }
            self.waiting = waiting
            self.animated = animated
            lastCue = cue
        }

        private func animateSpirit(_ index: Int) {
            let flight = CAKeyframeAnimation(keyPath: "position")
            // One closed route lets every spirit visit all three positions without a loop-end jump.
            flight.values = [CGPoint(x: 82, y: 41), CGPoint(x: 91, y: 32), CGPoint(x: 109, y: 34),
                CGPoint(x: 118, y: 41), CGPoint(x: 124, y: 29), CGPoint(x: 110, y: 14),
                CGPoint(x: 100, y: 8), CGPoint(x: 94, y: 17), CGPoint(x: 100, y: 41),
                CGPoint(x: 109, y: 47), CGPoint(x: 88, y: 48), CGPoint(x: 82, y: 41)]
                .map { NSValue(point: $0) }
            let scale = CAKeyframeAnimation(keyPath: "transform.scale")
            scale.values = [0.85, 1.08, 0.9, 0.85, 1, 0.8, 1.1, 0.9, 0.85, 1.05, 0.8, 0.85]
            let echo = CAKeyframeAnimation(keyPath: "opacity")
            echo.values = [0, 0, 0, 0, 0, 0.22, 0.85, 0.25, 0, 0, 0, 0]
            for animation in [flight, scale, echo] {
                animation.keyTimes = [0, 0.12, 0.22, NSNumber(value: 1.0 / 3), 0.43, 0.50,
                                      0.55, 0.60, NSNumber(value: 2.0 / 3), 0.78, 0.90, 1]
                animation.duration = 7.2
                animation.calculationMode = .cubic
            }
            let group = CAAnimationGroup()
            group.animations = [flight, scale]
            group.duration = 7.2
            group.timeOffset = Double(index) * 2.4
            group.repeatCount = .infinity
            group.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)
            spirits[index].add(group, forKey: "spirit")
            echo.timeOffset = group.timeOffset
            echo.repeatCount = .infinity
            echo.preferredFrameRateRange = group.preferredFrameRateRange
            echoes[index].add(echo, forKey: "echo")
        }

        func stop() {
            layer?.sublayers?.forEach { $0.removeAllAnimations() }
            animated = false
        }
    }
}

/// A compact glass projection stays at the island center, above the unbacked glyphs.
struct ImmersiveProjectorBackdrop: View {
    static let lightSize = CGSize(width: 120, height: 16)
    let sourceWidth: CGFloat
    let time: Double
    var reducedTransparency = false

    var body: some View {
        GeometryReader { geometry in
            let aperture = min(36, sourceWidth * 0.15)
            let receiver = min(Self.lightSize.width, sourceWidth * 0.5)
            ZStack(alignment: .top) {
                if !reducedTransparency {
                    let shape = ImmersiveProjectionGlass(sourceWidth: aperture, receiverWidth: receiver)
                    ImmersiveProjectionFill(shape: shape)
                        .frame(width: receiver + 2, height: Self.lightSize.height)
                    Group {
                        if #available(macOS 26.0, *) {
                            Color.clear.glassEffect(.clear, in: shape)
                        } else {
                            shape.fill(.ultraThinMaterial)
                        }
                    }
                    .frame(height: Self.lightSize.height)
                    .mask(LinearGradient(stops: [.init(color: .white, location: 0),
                                                 .init(color: .white.opacity(0.7), location: 0.35),
                                                 .init(color: .clear, location: 1)],
                                         startPoint: .top, endPoint: .bottom))
                }
                Color.white
                    .colorEffect(ShaderLibrary.immersiveProjector(
                        .float2(CGSize(width: geometry.size.width, height: Self.lightSize.height)),
                        .float(aperture), .float(receiver), .float(time)))
                    .frame(height: Self.lightSize.height)
            }
        }
        .accessibilityHidden(true)
    }
}

struct ImmersiveProjectionGlass: Shape, Equatable {
    let sourceWidth: CGFloat
    let receiverWidth: CGFloat

    func path(in rect: CGRect) -> Path {
        let top = min(sourceWidth, rect.width - 2) / 2
        let bottom = min(receiverWidth, rect.width - 2) / 2
        return Path { path in
            path.move(to: CGPoint(x: rect.midX - top, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX + top, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX + bottom, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.midX - bottom, y: rect.maxY))
            path.closeSubpath()
        }
    }
}

/// Behind-window material fills the V with the desktop, not the transparent lyric panel.
struct ImmersiveProjectionFill: NSViewRepresentable {
    let shape: ImmersiveProjectionGlass

    func makeNSView(context: Context) -> GlassView { GlassView() }

    func updateNSView(_ view: GlassView, context: Context) { view.setProjection(shape) }

    final class GlassView: NSVisualEffectView {
        private var projection: ImmersiveProjectionGlass?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            material = .underWindowBackground
            blendingMode = .behindWindow
            state = .active
        }

        required init?(coder: NSCoder) { super.init(coder: coder) }

        func setProjection(_ shape: ImmersiveProjectionGlass) {
            guard projection != shape else { return }
            projection = shape
            let size = CGSize(width: shape.receiverWidth + 2, height: ImmersiveProjectorBackdrop.lightSize.height)
            // Cache the native mask per geometry; lyric animation must not redraw it at 30 Hz.
            maskImage = NSImage(size: size, flipped: true) { rect in
                guard let context = NSGraphicsContext.current?.cgContext else { return false }
                context.saveGState()
                defer { context.restoreGState() }
                context.addPath(shape.path(in: rect).cgPath)
                context.clip()
                let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(),
                    colors: [CGColor(gray: 1, alpha: 0.5), CGColor(gray: 1, alpha: 0.22),
                             CGColor(gray: 1, alpha: 0.06), CGColor(gray: 1, alpha: 0)] as CFArray,
                    locations: [0, 0.12, 0.3, 0.5])!
                context.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.minY),
                                           end: CGPoint(x: rect.midX, y: rect.maxY), options: [])
                return true
            }
        }
    }
}

/// Padding is part of the sampled layer so particles can leave the glyphs without clipping.
struct ImmersiveLyricLine: View {
    let text: String
    let dissolve: Double
    var waveProgress: Double = -1
    var measuredWidth: CGFloat? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.displayScale) private var displayScale

    @MainActor private static let glyphCache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.totalCostLimit = 4 * 1024 * 1024
        cache.countLimit = 8
        return cache
    }()

    @MainActor private static let widthCache: NSCache<NSString, NSNumber> = {
        let cache = NSCache<NSString, NSNumber>()
        cache.countLimit = 32
        return cache
    }()

    @MainActor static func measure(_ text: String) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let key = text as NSString
        if let width = widthCache.object(forKey: key) { return CGFloat(width.doubleValue) }
        let width = key.size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 26, weight: .medium), .kern: 1
        ]).width
        widthCache.setObject(NSNumber(value: Double(width)), forKey: key)
        return width
    }

    private var glyph: some View {
        Text(text)
            .font(.system(size: 26, weight: .medium))
            .tracking(1)
            .lineLimit(1)
            .minimumScaleFactor(0.55)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 38, maxHeight: 38)
            .padding(.horizontal, 42)
            .padding(.top, 22)
            .padding(.bottom, 6)
    }

    @MainActor private func cachedGlyph(width: CGFloat, outlined: Bool) -> CGImage? {
        let key = "\(displayScale):\(width):\(outlined):\(reduceTransparency):\(text)" as NSString
        if let image = Self.glyphCache.object(forKey: key) { return image }
        // Bake stable glyphs once per cue; only the moving lens and outgoing dust redraw.
        let renderer = ImageRenderer(content: glyph
            .layerEffect(ShaderLibrary.immersiveLyricOutline(.float(reduceTransparency ? 1 : 0)),
                         maxSampleOffset: CGSize(width: 1, height: 1), isEnabled: outlined)
            .frame(width: width, height: ImmersiveLyricsView.projectionSize.height))
        renderer.scale = displayScale
        guard let image = renderer.cgImage else { return nil }
        Self.glyphCache.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }

    var body: some View {
        let textWidth = measuredWidth ?? Self.measure(text)
        let width = min(ImmersiveLyricsView.projectionSize.width, ceil(textWidth) + 128)
        let progress = reduceMotion ? -1 : waveProgress
        let outlined = dissolve < 0 || reduceMotion
        let image = cachedGlyph(width: width, outlined: outlined)
        Group {
            if let image {
                Image(decorative: image, scale: displayScale)
            } else {
                glyph
            }
        }
            .layerEffect(ShaderLibrary.immersiveParticleDissolve(.float(dissolve)),
                         maxSampleOffset: CGSize(width: 64, height: 28),
                         isEnabled: !reduceMotion && dissolve >= 0)
            .layerEffect(ShaderLibrary.immersiveLyricOutline(.float(reduceTransparency ? 1 : 0)),
                         maxSampleOffset: CGSize(width: 1, height: 1), isEnabled: !outlined || image == nil)
            .layerEffect(ShaderLibrary.immersiveLyricWave(
                .float2(CGSize(width: width, height: ImmersiveLyricsView.projectionSize.height)),
                .float(min(textWidth, max(1, width - 84))), .float(progress), .float(1)),
                maxSampleOffset: CGSize(width: 2, height: 4), isEnabled: progress > 0 && progress < 1)
            .frame(width: width)
    }
}
