import AppKit
import SwiftUI

enum CompactLyricsLayout {
    static let font = NSFont.systemFont(ofSize: 13, weight: .medium)
    static let slotWidth: CGFloat = 54
    static func sunCollapse(elapsed: Double, duration: Double) -> Double {
        guard duration > 0 else { return 0 }
        let t = min(1, max(0, elapsed - (duration - 2.5)))
        return t * t * (3 - 2 * t)
    }
    static func moonBoundary(progress: Double, angle: Double) -> Double {
        let p = min(1, max(0, progress))
        let arc = cos(angle)
        // Stylized curved terminator: retain curvature at half progress as well.
        return (2 * p - 1) * arc + 1.4 * p * (1 - p) * arc * arc
    }
    static func entranceEdge(sideWidth: CGFloat, gap: CGFloat, progress: Double) -> CGFloat {
        // Spend the two-second reveal on visible content, not the physical notch.
        let visible = 2 * sideWidth * min(1, max(0, progress))
        return visible + (visible >= sideWidth ? gap : 0)
    }

    static func textX(_ text: String, width: CGFloat, sideWidth: CGFloat, progress: Double) -> CGFloat {
        let lastWidth = (String(text.trimmingCharacters(in: .whitespacesAndNewlines).last ?? " ") as NSString)
            .size(withAttributes: [.font: font]).width
        let end = sideWidth / 2 - width + lastWidth / 2
        return sideWidth + (end - sideWidth) * min(1, max(0, progress))
    }
}

struct CompactLyricsView: View {
    let segments: [LyricSegment]
    let revision: UInt64
    let position: Double
    let sampleDate: Date
    let rate: Double
    let duration: Double
    let isPlaying: Bool
    let tint: Color
    let albumArt: NSImage
    let sideWidth: CGFloat
    let gap: CGFloat
    let height: CGFloat
    var lyricOffset: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var glyph: PortalGlyph?
    @State private var cover: PortalGlyph?
    @State private var outgoingGlyph: PortalGlyph?
    @State private var finished = false

    var body: some View {
        // Keep local day/night selection live even when music is paused.
        TimelineView(.periodic(from: .now, by: 1)) { clock in
        let daylight: Double = {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--preview-sun") { return 1 }
            #endif
            return CompactLyrics.isDaytime(at: clock.date) ? 1 : 0
        }()
        TimelineView(.animation(minimumInterval: reduceMotion ? 0.25 : 1.0 / 60,
                                paused: !isPlaying || finished)) { tick in
            let elapsed = max(0, isPlaying ? position + max(0, tick.date.timeIntervalSince(sampleDate)) * max(0, rate) : position)
            let lyricTime = max(0, elapsed + lyricOffset)
            let phase = elapsed >= duration - 0.2 && duration > 0 ? LyricPhase.finished : CompactLyrics.phase(at: min(lyricTime, max(0, duration - 0.201)), cues: segments, duration: duration)
            let text: String = { if case .lyrics(let cue) = phase { return cue.text }; return "" }()
            let outgoing = segments.last { $0.end <= lyricTime && lyricTime < $0.end + 0.4 }
            PortalLyricsFrame(phase: phase, elapsed: elapsed, duration: duration,
                              sideWidth: sideWidth, gap: gap, tint: tint, reduced: reduceMotion,
                              glyph: glyph?.text == text ? glyph : nil, cover: cover, albumArt: albumArt, lyricTime: lyricTime,
                              outgoing: outgoing, outgoingGlyph: outgoingGlyph?.text == outgoing?.text ? outgoingGlyph : nil,
                              entrance: min(1, max(0, elapsed / 2)), daylight: daylight)
                .animation(.easeInOut(duration: 1), value: daylight)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(text)
                .task(id: text) {
                    glyph = text.isEmpty ? nil : PortalGlyph(text: text)
                }
                .task(id: outgoing?.text) {
                    outgoingGlyph = outgoing.map { PortalGlyph(text: $0.text) }
                }
                .onChange(of: phase) { _, phase in finished = phase == .finished }
        }
        }
        .frame(width: sideWidth * 2 + gap, height: height)
        .task(id: ObjectIdentifier(albumArt)) { cover = PortalGlyph(image: albumArt) }
        .onChange(of: revision) { _, _ in finished = false }
        .onChange(of: sampleDate) { _, _ in finished = false }
    }
}

/// Artwork and progress moon on the left, timestamp-driven lyrics on the right.
struct PortalLyricsFrame: View, Animatable {
    let phase: LyricPhase
    let elapsed: Double
    let duration: Double
    let sideWidth: CGFloat
    let gap: CGFloat
    let tint: Color
    let reduced: Bool
    let glyph: PortalGlyph?
    let cover: PortalGlyph?
    let albumArt: NSImage

    var lyricTime: Double? = nil
    var outgoing: LyricSegment? = nil
    var outgoingGlyph: PortalGlyph? = nil
    var entrance: Double = 1
    var daylight: Double = 0
    var animatableData: Double {
        get { daylight }
        set { daylight = newValue }
    }

    var body: some View {
        Canvas { baseContext, size in
            var context = baseContext
            guard sideWidth > 0, gap >= 0, size.height > 0, elapsed.isFinite else { return }
            if phase == .finished { return }
            let left = CGRect(x: 0, y: 0, width: sideWidth, height: size.height)
            let right = CGRect(x: sideWidth + gap, y: 0, width: sideWidth, height: size.height)
            let reveal = min(1, max(0, entrance))
            let edge = CompactLyricsLayout.entranceEdge(sideWidth: sideWidth, gap: gap, progress: reveal)
            if reduced { context.opacity = reveal }
            else { context.clip(to: Path(CGRect(x: 0, y: 0, width: edge, height: size.height))) }
            let dissolve = CompactLyrics.dissolve(at: elapsed, duration: duration)
            artwork(in: left, dissolve: dissolve, context: context)
            if daylight < 1 { moon(in: left, dissolve: dissolve, visibility: 1 - daylight, context: context) }
            if daylight > 0 { sun(in: left, dissolve: dissolve, visibility: daylight, context: context) }
            switch phase {
            case .lyrics(let cue):
                let width = glyph?.size.width ?? (cue.text as NSString).size(withAttributes: [.font: CompactLyricsLayout.font]).width
                // One constant velocity for the entire line, including entry from the right.
                // No separate entrance impulse: the last character still ends at the center.
                let p = min(1, max(0, ((lyricTime ?? elapsed) - cue.start) / max(0.1, cue.end - cue.start)))
                let motion = reduced ? floor(p * 3) / 3 : p
                let x = right.minX + CompactLyricsLayout.textX(cue.text, width: width, sideWidth: sideWidth, progress: motion)
                for rect in [right] {
                    var lane = context
                    lane.clip(to: Path(rect))
                    lane.clipToLayer { mask in
                        let stops: [Gradient.Stop] = [
                            .init(color: .clear, location: 0), .init(color: .white, location: 0.14),
                            .init(color: .white, location: 0.86), .init(color: .clear, location: 1)
                        ]
                        mask.fill(Path(rect), with: .linearGradient(Gradient(stops: stops), startPoint: CGPoint(x: rect.minX, y: 0), endPoint: CGPoint(x: rect.maxX, y: 0)))
                    }
                    var textContext = lane
                    let appearing = outgoing == nil ? 1 : min(1, max(0.15, ((lyricTime ?? elapsed) - cue.start) / 0.25))
                    textContext.opacity = pow(1 - dissolve, 2) * appearing
                    textContext.draw(Text(cue.text).font(Font(CompactLyricsLayout.font)).foregroundColor(tint),
                                     at: CGPoint(x: x, y: size.height / 2), anchor: .leading)
                    if !reduced, let glyph, dissolve > 0 {
                        dust(glyph, origin: CGPoint(x: x, y: (size.height - glyph.size.height) / 2),
                             progress: dissolve, tint: tint, context: lane)
                    }
                }
            case .outro:
                let remaining = min(1, max(0, (duration - elapsed) / 5))
                waves(in: right, logicalStart: sideWidth, amplitude: 0.15 + 2.7 * remaining * remaining,
                      dissolve: dissolve, context: context)
            case .waves:
                waves(in: right, logicalStart: sideWidth, amplitude: 2.8, dissolve: dissolve, context: context)
            case .finished: break
            }
            if let outgoing, let asset = outgoingGlyph {
                let p = min(1, max(0, ((lyricTime ?? elapsed) - outgoing.end) / 0.4))
                let x = right.minX + CompactLyricsLayout.textX(outgoing.text, width: asset.size.width, sideWidth: sideWidth, progress: 1)
                var old = context
                old.clip(to: Path(right))
                old.opacity = pow(1 - p, 2) * (1 - dissolve)
                old.draw(Text(outgoing.text).font(Font(CompactLyricsLayout.font)).foregroundColor(tint),
                         at: CGPoint(x: x, y: size.height / 2), anchor: .leading)
                if !reduced {
                    dust(asset, origin: CGPoint(x: x, y: (size.height - asset.size.height) / 2),
                         progress: p, tint: tint, context: old)
                }
            }
            if !reduced, reveal > 0, reveal < 1 {
                var portal = baseContext
                portal.clip(to: Path(CGRect(origin: .zero, size: size)))
                portal.opacity = sin(.pi * reveal)
                let beam = CGRect(x: edge - 0.7, y: 1, width: 1.4, height: size.height - 2)
                portal.fill(Path(roundedRect: beam, cornerRadius: 1), with: .color(tint.opacity(0.8)))
                for i in 0..<42 {
                    let phase = (reveal * 3 + Double(i) / 42).truncatingRemainder(dividingBy: 1)
                    let x = edge - phase * 15
                    let y = size.height * Double(i) / 42 + sin(Double(i) * 2.4) * phase * 4
                    portal.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 0.9, height: 0.9)), with: .color(tint.opacity(1 - phase)))
                }
            }
        }
    }

    private func waves(in rect: CGRect, logicalStart: CGFloat, amplitude: Double, dissolve: Double, context: GraphicsContext) {
        var layer = context
        layer.clip(to: Path(rect))
        let time = reduced ? 0 : elapsed
        for band in 0..<3 {
            var path = Path()
            for step in 0...Int(ceil(rect.width)) {
                let local = CGFloat(step)
                let phase = (logicalStart + local) / 15 + time * 2.4 + Double(band) * 0.55
                let y = rect.midY + sin(phase) * amplitude * (1 - Double(band) * 0.2)
                let point = CGPoint(x: rect.minX + local, y: y)
                if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
                if !reduced, dissolve > 0, step % 3 == 0 {
                    let drift = CGPoint(x: point.x - dissolve * 8, y: point.y + sin(Double(step * 7)) * dissolve * 7)
                    layer.opacity = sin(.pi * dissolve) * 0.55
                    layer.fill(Path(ellipseIn: CGRect(x: drift.x, y: drift.y, width: 0.9, height: 0.9)), with: .color(tint))
                }
            }
            layer.opacity = (0.65 - Double(band) * 0.17) * pow(1 - dissolve, 2)
            layer.stroke(path, with: .color(tint), style: StrokeStyle(lineWidth: band == 0 ? 1.2 : 0.7, lineCap: .round))
        }
    }

    private func artwork(in lane: CGRect, dissolve: Double, context: GraphicsContext) {
        let rect = CGRect(x: lane.minX + 2, y: lane.midY - 11, width: 22, height: 22)
        var layer = context
        layer.opacity = pow(1 - dissolve, 2)
        layer.clip(to: Path(roundedRect: rect, cornerRadius: 4))
        layer.draw(Image(nsImage: albumArt), in: rect)
        if !reduced, let cover, dissolve > 0 {
            var particles = context
            particles.clip(to: Path(lane))
            dust(cover, origin: rect.origin, progress: dissolve, tint: nil, context: particles)
        }
    }

    private func sun(in lane: CGRect, dissolve: Double, visibility: Double, context: GraphicsContext) {
        let center = CGPoint(x: lane.maxX - 13, y: lane.midY)
        let progress = duration > 0 ? min(1, max(0, elapsed / duration)) : 0
        let collapse = CompactLyricsLayout.sunCollapse(elapsed: elapsed, duration: duration)
        var layer = context
        layer.clip(to: Path(lane))
        layer.opacity = visibility * pow(1 - dissolve, 2)
        let tint = Color(red: 0.96, green: 0.94, blue: 0.87)
        let discRadius = 4 - 2.5 * collapse
        let disc = Path(ellipseIn: CGRect(x: center.x - discRadius, y: center.y - discRadius,
                                         width: discRadius * 2, height: discRadius * 2))
        layer.fill(disc, with: .color(tint.opacity(1 - progress * (1 - collapse))))
        layer.stroke(disc, with: .color(tint), lineWidth: 0.8)
        // Finish the one-second contraction before the existing particle dissolve begins.
        for ray in 0..<8 {
            let angle = Double(ray) * .pi / 4
            var path = Path()
            for step in 0...16 {
                let t = Double(step) / 16
                let radius = 1.5 * collapse + (5.8 + t * (4 - 2.5 * progress)) * (1 - collapse)
                let bend = sin(t * 2 * .pi) * 0.85 * (1 - progress) * (1 - collapse)
                let point = CGPoint(x: center.x + cos(angle) * radius - sin(angle) * bend,
                                    y: center.y + sin(angle) * radius + cos(angle) * bend)
                if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            layer.stroke(path, with: .color(tint.opacity(0.85 * (1 - collapse))),
                         style: StrokeStyle(lineWidth: 0.8, lineCap: .round, lineJoin: .round))
        }
        celestialDust(at: center, progress: dissolve, visibility: visibility, lane: lane, context: context)
    }

    private func moon(in lane: CGRect, dissolve: Double, visibility: Double, context: GraphicsContext) {
        let center = CGPoint(x: lane.maxX - 13, y: lane.midY)
        let radius: CGFloat = 7
        let progress = duration > 0 ? min(1, max(0, elapsed / duration)) : 0
        let star = duration > 0 ? min(1, max(0, elapsed - (duration - 2.5))) : 0
        var layer = context
        layer.clip(to: Path(lane))
        layer.opacity = visibility * (1 - star) * pow(1 - dissolve, 2)
        let disc = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        layer.fill(disc, with: .color(Color(white: 0.12)))
        var shape = Path()
        for i in 0...40 {
            let angle = -.pi / 2 + Double(i) * .pi / 40
            let point = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
            if i == 0 { shape.move(to: point) } else { shape.addLine(to: point) }
        }
        for i in 0...40 {
            let angle = .pi / 2 - Double(i) * .pi / 40
            shape.addLine(to: CGPoint(x: center.x + radius * CompactLyricsLayout.moonBoundary(progress: progress, angle: angle),
                                     y: center.y + radius * sin(angle)))
        }
        shape.closeSubpath()
        layer.fill(shape, with: .radialGradient(
            Gradient(colors: [Color(white: 0.95), Color(white: 0.67)]),
            center: CGPoint(x: center.x - 3, y: center.y - 3), startRadius: 0, endRadius: radius * 1.8))
        layer.stroke(disc, with: .color(.white.opacity(0.12)), lineWidth: 0.35)
        layer.opacity = visibility * star * pow(1 - dissolve, 2)
        layer.draw(Text(Image(systemName: "star.fill"))
            .font(.system(size: 14, weight: .regular)).foregroundColor(Color(white: 0.9)), at: center)
        celestialDust(at: center, progress: dissolve, visibility: visibility * star, lane: lane, context: context)
    }

    private func celestialDust(at center: CGPoint, progress: Double, visibility: Double, lane: CGRect, context: GraphicsContext) {
        guard !reduced, progress > 0 else { return }
        var layer = context
        layer.clip(to: Path(lane))
        layer.opacity = visibility * sin(.pi * progress) * 0.55
        for i in 0..<16 {
            let angle = Double(i) * 2.4
            let radius = Double(i % 4) * 0.6 + progress * 5
            let point = CGPoint(x: center.x + cos(angle) * radius - progress * 3, y: center.y + sin(angle) * radius)
            layer.fill(Path(ellipseIn: CGRect(x: point.x, y: point.y, width: 0.7, height: 0.7)),
                       with: .color(Color(white: 0.9)))
        }
    }

    private func dust(_ asset: PortalGlyph, origin: CGPoint, progress: Double, tint: Color?, context: GraphicsContext) {
        var layer = context
        layer.opacity = sin(.pi * progress) * 0.85
        for (index, point) in asset.points.enumerated() {
            let drift = CGFloat(4 + index % 7) * progress
            let x = origin.x + point.position.x - drift
            let y = origin.y + point.position.y + sin(Double(index) * 2.4) * drift
            layer.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1, height: 1)), with: .color(tint ?? point.color))
        }
    }
}

/// Raster sampling happens only when a line or artwork changes, never per frame.
struct PortalGlyph {
    struct Point { let position: CGPoint; let color: Color }
    let text: String
    let size: CGSize
    let points: [Point]

    init(text: String) {
        let measured = (text as NSString).size(withAttributes: [.font: CompactLyricsLayout.font])
        self.init(text: text, size: CGSize(width: min(4096, max(1, ceil(measured.width))), height: ceil(measured.height))) { rect in
            (text as NSString).draw(at: .zero, withAttributes: [.font: CompactLyricsLayout.font, .foregroundColor: NSColor.white])
        }
    }

    init(image: NSImage) {
        self.init(text: "", size: CGSize(width: 22, height: 22)) { rect in image.draw(in: rect) }
    }

    private init(text: String, size: CGSize, draw: (CGRect) -> Void) {
        self.text = text
        self.size = size
        let width = Int(size.width * 2), height = Int(size.height * 2)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32),
              let graphics = NSGraphicsContext(bitmapImageRep: bitmap), let bytes = bitmap.bitmapData else { points = []; return }
        bytes.initialize(repeating: 0, count: bitmap.bytesPerRow * height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        graphics.cgContext.scaleBy(x: 2, y: 2)
        draw(CGRect(origin: .zero, size: size))
        graphics.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        var samples: [Point] = []
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bitmap.bytesPerRow + x * 4
                guard bytes[offset + 3] > 64 else { continue }
                samples.append(Point(position: CGPoint(x: CGFloat(x) / 2, y: CGFloat(y) / 2),
                                     color: Color(red: Double(bytes[offset]) / 255, green: Double(bytes[offset + 1]) / 255, blue: Double(bytes[offset + 2]) / 255)))
            }
        }
        let count = min(320, samples.count)
        points = (0..<count).map { samples[$0 * samples.count / count] }
    }
}
