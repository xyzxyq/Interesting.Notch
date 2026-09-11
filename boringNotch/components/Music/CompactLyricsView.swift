import AppKit
import SwiftUI

enum CompactLyricsLayout {
    static let font = NSFont.systemFont(ofSize: 13, weight: .medium)
    static let slotWidth: CGFloat = 54
    // Normalized, fixed surface features keep the moon stable while its phase changes.
    static let moonCraters: [(CGFloat, CGFloat, CGFloat)] = [
        (-0.32, -0.38, 0.23), (0.3, -0.13, 0.29), (-0.24, 0.24, 0.2),
        (0.3, 0.48, 0.14), (-0.55, -0.02, 0.1), (0.15, -0.62, 0.09)
    ]

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
                              entrance: min(1, max(0, elapsed / 2)))
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
        .frame(width: sideWidth * 2 + gap, height: height)
        .task(id: ObjectIdentifier(albumArt)) { cover = PortalGlyph(image: albumArt) }
        .onChange(of: revision) { _, _ in finished = false }
        .onChange(of: sampleDate) { _, _ in finished = false }
    }
}

/// Artwork and progress moon on the left, timestamp-driven lyrics on the right.
struct PortalLyricsFrame: View {
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
            moon(in: left, dissolve: dissolve, context: context)
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

    private func moon(in lane: CGRect, dissolve: Double, context: GraphicsContext) {
        let center = CGPoint(x: lane.maxX - 13, y: lane.midY)
        let radius: CGFloat = 8
        let progress = duration > 0 ? min(1, max(0, elapsed / duration)) : 0
        let star = duration > 0 ? min(1, max(0, (elapsed - (duration - 2.5)) / 1.0)) : 0
        var layer = context
        layer.opacity = (1 - star) * pow(1 - dissolve, 2)
        let moonCenter = CGPoint(x: center.x, y: center.y - 1.5)
        let moonRadius: CGFloat = 6.8
        // Lit limb is a semicircle plus an elliptical terminator: full -> half -> crescent.
        var shape = Path()
        for i in 0...40 {
            let angle = -.pi / 2 + Double(i) * .pi / 40
            let point = CGPoint(x: moonCenter.x + moonRadius * cos(angle), y: moonCenter.y + moonRadius * sin(angle))
            if i == 0 { shape.move(to: point) } else { shape.addLine(to: point) }
        }
        for i in 0...40 {
            let angle = .pi / 2 - Double(i) * .pi / 40
            shape.addLine(to: CGPoint(x: moonCenter.x + moonRadius * (2 * progress - 1) * cos(angle), y: moonCenter.y + moonRadius * sin(angle)))
        }
        shape.closeSubpath()
        var surface = layer
        surface.clip(to: shape)
        surface.fill(shape, with: .radialGradient(
            Gradient(colors: [Color(white: 0.98), Color(red: 0.75, green: 0.78, blue: 0.82), Color(white: 0.38)]),
            center: CGPoint(x: moonCenter.x - moonRadius * 0.35, y: moonCenter.y - moonRadius * 0.4),
            startRadius: 0, endRadius: moonRadius * 1.8))
        for (x, y, scale) in CompactLyricsLayout.moonCraters {
            let r = moonRadius * scale
            let pit = CGRect(x: moonCenter.x + x * moonRadius - r, y: moonCenter.y + y * moonRadius - r,
                             width: r * 2, height: r * 1.7)
            surface.fill(Path(ellipseIn: pit), with: .radialGradient(
                Gradient(colors: [Color(white: 0.22).opacity(0.55), Color(white: 0.45).opacity(0.12)]),
                center: CGPoint(x: pit.midX - r * 0.2, y: pit.midY - r * 0.2),
                startRadius: 0, endRadius: r))
            var rim = Path()
            rim.addArc(center: CGPoint(x: pit.midX, y: pit.midY), radius: r * 0.8,
                       startAngle: .degrees(15), endAngle: .degrees(140), clockwise: false)
            surface.stroke(rim, with: .color(.white.opacity(0.35)), lineWidth: 0.45)
        }
        // Small silver strands share the moon's fade and playback clock.
        var fringe = layer
        fringe.clip(to: Path(lane))
        for i in 0..<3 {
            let angle = (38 + Double(i) * 21) * .pi / 180
            let root = CGPoint(x: moonCenter.x + cos(angle) * moonRadius * 0.98,
                               y: moonCenter.y + sin(angle) * moonRadius * 0.98)
            let sway = reduced ? 0 : sin(elapsed * 1.8 + Double(i) * 0.7) * 0.85
            let tip = CGPoint(x: root.x + sway - 0.4,
                              y: min(lane.maxY - 0.8, root.y + 3.5 + Double(i) * 0.45))
            var thread = Path()
            thread.move(to: root)
            thread.addCurve(to: tip,
                            control1: CGPoint(x: root.x - 0.7, y: root.y + 1.2),
                            control2: CGPoint(x: tip.x + sway * 0.5, y: tip.y - 1))
            fringe.stroke(thread, with: .linearGradient(
                Gradient(colors: [Color(white: 0.92).opacity(0.8), Color(red: 0.65, green: 0.77, blue: 0.92).opacity(0.45)]),
                startPoint: root, endPoint: tip), style: StrokeStyle(lineWidth: 0.5, lineCap: .round))
            fringe.fill(Path(ellipseIn: CGRect(x: tip.x - 0.45, y: tip.y - 0.45, width: 0.9, height: 0.9)),
                        with: .color(Color(white: 0.95).opacity(0.8)))
        }
        var starPath = Path()
        for i in 0..<10 {
            let angle = -.pi / 2 + Double(i) * .pi / 5
            let r = i % 2 == 0 ? radius : radius * 0.43
            let point = CGPoint(x: center.x + cos(angle) * r, y: center.y + sin(angle) * r)
            if i == 0 { starPath.move(to: point) } else { starPath.addLine(to: point) }
        }
        starPath.closeSubpath()
        layer.opacity = star * pow(1 - dissolve, 2)
        layer.clip(to: Path(lane))
        let gold = Color(red: 1, green: 0.76, blue: 0.32)
        let shimmer = reduced ? 1 : 0.92 + 0.08 * sin(elapsed * 3)
        layer.fill(Path(ellipseIn: CGRect(x: center.x - 11, y: center.y - 11, width: 22, height: 22)),
                   with: .radialGradient(Gradient(colors: [gold.opacity(0.3 * shimmer), gold.opacity(0)]),
                                         center: center, startRadius: 2, endRadius: 11))
        layer.fill(starPath, with: .linearGradient(
            Gradient(colors: [Color(red: 1, green: 0.97, blue: 0.8), gold, Color(red: 0.72, green: 0.4, blue: 0.12)]),
            startPoint: CGPoint(x: center.x - 4, y: center.y - 8), endPoint: CGPoint(x: center.x + 5, y: center.y + 8)))
        for i in 0..<5 {
            let angle = -.pi / 2 + Double(i) * .pi * 2 / 5
            var facet = Path()
            facet.move(to: center)
            facet.addLine(to: CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius))
            facet.addLine(to: CGPoint(x: center.x + cos(angle + .pi / 5) * radius * 0.43,
                                     y: center.y + sin(angle + .pi / 5) * radius * 0.43))
            facet.closeSubpath()
            layer.fill(facet, with: .color(.white.opacity(0.25 * shimmer)))
        }
        layer.stroke(starPath, with: .color(Color(red: 1, green: 0.91, blue: 0.6).opacity(0.65)), lineWidth: 0.4)
        let glint = CGPoint(x: center.x + 8, y: center.y - 6)
        var rays = Path()
        rays.move(to: CGPoint(x: glint.x - 1.8 * shimmer, y: glint.y))
        rays.addLine(to: CGPoint(x: glint.x + 1.8 * shimmer, y: glint.y))
        rays.move(to: CGPoint(x: glint.x, y: glint.y - 2.4 * shimmer))
        rays.addLine(to: CGPoint(x: glint.x, y: glint.y + 2.4 * shimmer))
        layer.stroke(rays, with: .color(.white.opacity(0.75 * shimmer)), style: StrokeStyle(lineWidth: 0.6, lineCap: .round))
        if !reduced, dissolve > 0 {
            layer.opacity = sin(.pi * dissolve) * star
            for i in 0..<48 {
                let angle = Double(i) * 2.4
                let r = Double(i % 8)
                let point = CGPoint(x: center.x + cos(angle) * r, y: center.y + sin(angle) * r)
                if starPath.contains(point) {
                    let rect = CGRect(x: point.x - dissolve * 8, y: point.y + sin(Double(i)) * dissolve * 8, width: 1, height: 1)
                    layer.fill(Path(ellipseIn: rect), with: .color(gold))
                }
            }
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
