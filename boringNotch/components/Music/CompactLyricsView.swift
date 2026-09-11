import AppKit
import SwiftUI

enum CompactLyricsLayout {
    static let font = NSFont.systemFont(ofSize: 13, weight: .medium)
    static let slotWidth: CGFloat = 54
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var glyph: PortalGlyph?
    @State private var cover: PortalGlyph?
    @State private var finished = false

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 0.25 : 1.0 / 60,
                                paused: !isPlaying || finished)) { tick in
            let elapsed = max(0, isPlaying ? position + max(0, tick.date.timeIntervalSince(sampleDate)) * max(0, rate) : position)
            let phase = CompactLyrics.phase(at: elapsed, cues: segments, duration: duration)
            let text: String = { if case .lyrics(let cue) = phase { return cue.text }; return "" }()
            PortalLyricsFrame(phase: phase, elapsed: elapsed, duration: duration,
                              sideWidth: sideWidth, gap: gap, tint: tint, reduced: reduceMotion,
                              glyph: glyph?.text == text ? glyph : nil, cover: cover, albumArt: albumArt)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(text)
                .task(id: text) {
                    glyph = text.isEmpty ? nil : PortalGlyph(text: text)
                }
                .onChange(of: phase) { _, phase in finished = phase == .finished }
        }
        .frame(width: sideWidth * 2 + gap, height: height)
        .task(id: ObjectIdentifier(albumArt)) { cover = PortalGlyph(image: albumArt) }
        .onChange(of: revision) { _, _ in finished = false; glyph = nil }
        .onChange(of: sampleDate) { _, _ in finished = false }
    }
}

/// One virtual strip with the physical notch removed: logical x=sideWidth
/// is both the right entrance and the left exit. Nothing is drawn under the notch.
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

    var body: some View {
        Canvas { context, size in
            guard sideWidth > 0, gap >= 0, size.height > 0, elapsed.isFinite else { return }
            if phase == .finished { return }
            let left = CGRect(x: 0, y: 0, width: sideWidth, height: size.height)
            let right = CGRect(x: sideWidth + gap, y: 0, width: sideWidth, height: size.height)
            let ending: Bool = {
                if phase == .outro { return true }
                if case .lyrics(let cue) = phase { return cue.end >= duration - 0.2 }
                return false
            }()
            let dissolve = ending ? CompactLyrics.dissolve(at: elapsed, duration: duration) : 0
            switch phase {
            case .lyrics(let cue):
                let width = glyph?.size.width ?? (cue.text as NSString).size(withAttributes: [.font: CompactLyricsLayout.font]).width
                // Freeze the last visible letters during dissolution, rather than scrolling
                // them completely out of view before they can break into particles.
                let travelEnd = ending ? max(cue.start + 0.1, duration - 1.2) : cue.end
                let p = min(1, max(0, (min(elapsed, travelEnd) - cue.start) / max(0.1, cue.end - cue.start)))
                let travel = (2 * sideWidth + width) * p
                let x = 2 * sideWidth - (reduced ? floor(travel / sideWidth) * sideWidth : travel)
                for (rect, shift) in [(left, CGFloat(0)), (right, gap)] {
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
                    textContext.opacity = pow(1 - dissolve, 2)
                    textContext.draw(Text(cue.text).font(Font(CompactLyricsLayout.font)).foregroundColor(tint),
                                     at: CGPoint(x: x + shift, y: size.height / 2), anchor: .leading)
                    if !reduced, let glyph, dissolve > 0 {
                        dust(glyph, origin: CGPoint(x: x + shift, y: (size.height - glyph.size.height) / 2),
                             progress: dissolve, tint: tint, context: lane)
                    }
                }
            case .outro:
                let remaining = min(1, max(0, (duration - elapsed) / 5))
                waves(in: right, logicalStart: sideWidth, amplitude: 0.15 + 2.7 * remaining * remaining,
                      dissolve: dissolve, context: context)
                let coverSize = min(22, size.height - 2)
                let rect = CGRect(x: (sideWidth - coverSize) / 2, y: (size.height - coverSize) / 2, width: coverSize, height: coverSize)
                var imageContext = context
                imageContext.opacity = pow(1 - dissolve, 2)
                imageContext.clip(to: Path(roundedRect: rect, cornerRadius: 4))
                imageContext.draw(Image(nsImage: albumArt), in: rect)
                if !reduced, let cover, dissolve > 0 {
                    var layer = context
                    layer.clip(to: Path(left))
                    let ratio = coverSize / cover.size.width
                    layer.translateBy(x: rect.minX, y: rect.minY)
                    layer.scaleBy(x: ratio, y: ratio)
                    dust(cover, origin: .zero, progress: dissolve, tint: nil, context: layer)
                }
            case .waves:
                waves(in: left, logicalStart: 0, amplitude: 2.8, dissolve: 0, context: context)
                waves(in: right, logicalStart: sideWidth, amplitude: 2.8, dissolve: 0, context: context)
            case .finished: break
            }
            if !reduced {
                let strength = (1 - dissolve) * (phase == .outro ? min(1, max(0, (duration - elapsed) / 5)) : 1)
                portals(left: left, right: right, strength: strength, context: context)
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

    private func portals(left: CGRect, right: CGRect, strength: Double, context: GraphicsContext) {
        for (rect, edge, sign) in [(left, left.maxX - 1, -1.0), (right, right.minX + 1, 1.0)] {
            var layer = context
            layer.clip(to: Path(rect))
            for index in 0..<22 {
                let p = (elapsed * 0.75 + Double(index) / 22).truncatingRemainder(dividingBy: 1)
                let x = edge + sign * p * 7
                let y = rect.midY + sin(Double(index) * 2.4 + elapsed) * (2 + 6 * p)
                layer.opacity = sin(.pi * p) * 0.6 * strength
                layer.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 0.8, height: 0.8)), with: .color(tint))
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
