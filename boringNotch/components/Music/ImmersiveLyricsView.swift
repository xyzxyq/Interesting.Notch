import SwiftUI

/// The playback clock is shared with compact lyrics; only this small surface redraws.
struct ImmersiveLyricsView: View {
    static let projectionSize = CGSize(width: 640, height: 66)
    let segments: [LyricSegment]
    let position: Double
    let sampleDate: Date
    let rate: Double
    let duration: Double
    let offset: Double
    let style: ImmersiveLyricStyle
    let sourceWidth: CGFloat
    @State private var animationEpoch = Date()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 0.25 : 1.0 / 30)) { tick in
            let elapsed = max(0, position + max(0, tick.date.timeIntervalSince(sampleDate)) * max(0, rate))
            let lyricTime = elapsed + offset
            let neighbors = CompactLyrics.neighbors(at: lyricTime, cues: segments)
            let cue = neighbors.current
            let finished = duration > 0 && elapsed >= duration
            let line = finished ? "" : cue?.text ?? ""
            let time = reduceMotion ? 0 : max(0, tick.date.timeIntervalSince(animationEpoch))
            ZStack(alignment: .top) {
                let receiverText = !line.isEmpty ? line : (style == .particles && !reduceMotion ? neighbors.outgoing?.text ?? "" : "")
                if !receiverText.isEmpty {
                    ImmersiveProjectorBackdrop(sourceWidth: sourceWidth,
                                               time: time, reducedTransparency: reduceTransparency)
                }
                if style == .particles && !reduceMotion, let outgoing = neighbors.outgoing {
                    ImmersiveLyricLine(text: outgoing.text, time: time,
                        dissolve: ImmersiveFocus.dissolveProgress(at: lyricTime, end: outgoing.end))
                }
                if let cue, !finished {
                    ImmersiveLyricLine(text: cue.text, time: time, dissolve: -1,
                        waveProgress: ImmersiveFocus.waveProgress(at: lyricTime, start: cue.start, end: cue.end),
                        style: style)
                        .opacity(style != .particles || neighbors.outgoing == nil || reduceMotion
                                 ? 1 : min(1, max(0, (lyricTime - cue.start) / 0.12)))
                        .contentTransition(.opacity)
                        .animation(reduceMotion || style == .particles ? nil : .easeInOut(duration: 0.4), value: cue.id)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(line)
        }
        .frame(height: Self.projectionSize.height)
        .allowsHitTesting(false)
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
    let time: Double
    let dissolve: Double
    var waveProgress: Double = -1
    var style: ImmersiveLyricStyle = .particles
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let textWidth = (text as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 26, weight: .medium), .kern: 1
        ]).width
        let progress = reduceMotion ? -1 : waveProgress
        let strength = style == .glow ? 0.45 : style == .ripple ? 1.15 : 1.0
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
            .layerEffect(ShaderLibrary.immersiveParticleDissolve(.float(time), .float(dissolve)),
                         maxSampleOffset: CGSize(width: 64, height: 28),
                         isEnabled: style == .particles && !reduceMotion)
            .layerEffect(ShaderLibrary.immersiveLyricOutline(.float(reduceTransparency ? 1 : 0)),
                         maxSampleOffset: CGSize(width: 1, height: 1))
            .visualEffect { content, geometry in
                content.layerEffect(ShaderLibrary.immersiveLyricWave(
                    .float2(geometry.size), .float(min(textWidth, max(1, geometry.size.width - 84))),
                    .float(progress), .float(strength)), maxSampleOffset: CGSize(width: 2, height: 4),
                    isEnabled: progress > 0 && progress < 1)
            }
    }
}
