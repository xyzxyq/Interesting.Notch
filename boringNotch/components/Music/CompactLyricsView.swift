import AppKit
import SwiftUI

// Shared by the text renderer and the closed-notch width calculation.
enum CompactLyricsLayout {
    static let font = NSFont.systemFont(ofSize: 13, weight: .medium)
    static let slotWidth = ceil(("歌颂你" as NSString).size(withAttributes: [.font: font]).width) + 8

    static func font(for text: String, in size: CGSize) -> NSFont {
        let measured = (text as NSString).size(withAttributes: [.font: font])
        let scale = min(1, max(0, size.width - 8) / max(1, measured.width), max(0, size.height) / max(1, measured.height))
        return NSFont.systemFont(ofSize: max(1, 13 * scale), weight: .medium)
    }
}

struct CompactLyricsView<Fallback: View>: View {
    let segments: [LyricSegment]
    let revision: UInt64
    let position: Double
    let sampleDate: Date
    let rate: Double
    let isPlaying: Bool
    let tint: Color
    @ViewBuilder let fallback: () -> Fallback

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    @State private var current: LyricSegment?
    @State private var renderedRevision: UInt64?
    @State private var transition: LyricTransition?

    private struct Clock: Equatable {
        let revision: UInt64
        let position: Double
        let date: Date
        let rate: Double
        let playing: Bool
        let size: CGSize
        let reduced: Bool
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                if let transition {
                    TimelineView(.animation) { tick in
                        LyricTransitionCanvas(transition: transition, date: tick.date, tint: tint)
                    }
                } else if let current {
                    Text(current.text)
                        .font(Font(CompactLyricsLayout.font(for: current.text, in: size)))
                        .foregroundStyle(tint)
                        .lineLimit(1)
                } else {
                    fallback()
                }
            }
            .frame(width: size.width, height: size.height)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(current?.text ?? "")
            .task(id: Clock(revision: revision, position: position, date: sampleDate, rate: rate,
                            playing: isPlaying, size: size, reduced: reduceMotion)) {
                // Playback publications recalibrate the next wakeup; no frame timer in steady state.
                var isBoundaryWake = false
                while !Task.isCancelled {
                    let now = Date()
                    let elapsed = isPlaying ? position + max(0, now.timeIntervalSince(sampleDate)) * rate : position
                    guard elapsed.isFinite else { current = nil; transition = nil; return }
                    let target = CompactLyrics.segment(at: max(0, elapsed), in: segments)
                    // A sample arriving just after a boundary can beat our timer. Animate only
                    // adjacent targets near their start; large seeks snap directly to the target.
                    let adjacent = isPlaying && (current.map { old in target.map { $0.id == old.id + 1 && elapsed - $0.start < 0.12 } ?? false } ?? false)
                    update(target, animate: renderedRevision == revision && (isBoundaryWake || adjacent), size: size)
                    renderedRevision = revision
                    guard isPlaying, rate.isFinite, rate > 0,
                          let next = CompactLyrics.nextBoundary(after: elapsed, in: segments) else { return }
                    do {
                        try await Task.sleep(for: .seconds(max(0.001, (next - elapsed) / rate)))
                    } catch { return }
                    isBoundaryWake = true
                }
            }
            .task(id: transition?.id) {
                guard let active = transition else { return }
                do { try await Task.sleep(for: .seconds(active.duration)) } catch { return }
                guard transition?.id == active.id else { return }
                transition = nil
            }
            .onChange(of: reduceMotion) { _, _ in transition = nil }
            .onChange(of: size) { _, _ in transition = nil }
            .onDisappear { transition = nil; current = nil; renderedRevision = nil }
        }
    }

    private func update(_ target: LyricSegment?, animate: Bool, size: CGSize) {
        guard renderedRevision != revision || current?.id != target?.id else { return }
        let old = current
        current = target
        transition = nil
        guard animate, let target, size.width > 0, size.height > 0 else { return }
        let duration = min(reduceMotion ? 0.1 : 0.280, CompactLyrics.transitionDuration(for: target))
        guard duration > 0 else { return }
        let outgoing = old.map { LyricGlyph(text: $0.text, size: size, scale: displayScale, seed: $0.id, sample: !reduceMotion) }
        let incoming = LyricGlyph(text: target.text, size: size, scale: displayScale, seed: target.id, sample: !reduceMotion)
        // Bitmap failure is a normal-text fallback, never a missing lyric.
        guard reduceMotion || (!incoming.particles.isEmpty && (outgoing?.particles.isEmpty != true)) else { return }
        transition = LyricTransition(outgoing: outgoing, incoming: incoming, duration: duration, reduced: reduceMotion)
    }
}

// Internal to this file's renderer, also usable by the standalone visual check.
struct LyricGlyph {
    struct Particle {
        let origin: CGPoint
        let drift: CGVector
        let radius: CGFloat
    }
    let text: String
    let font: NSFont
    let particles: [Particle]

    init(text: String, size: CGSize, scale: CGFloat, seed: Int, sample: Bool) {
        self.text = text
        font = CompactLyricsLayout.font(for: text, in: size)
        guard sample, size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite else {
            particles = []; return
        }
        let scale = max(1, min(3, scale))
        let width = Int(ceil(size.width * scale))
        let height = Int(ceil(size.height * scale))
        guard width > 0, height > 0, width <= 1024, height <= 256,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                             isPlanar: false, colorSpaceName: .deviceRGB,
                                             bytesPerRow: width * 4, bitsPerPixel: 32),
              let graphics = NSGraphicsContext(bitmapImageRep: bitmap), let bytes = bitmap.bitmapData else {
            particles = []; return
        }
        bytes.initialize(repeating: 0, count: bitmap.bytesPerRow * height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        graphics.cgContext.scaleBy(x: scale, y: scale)
        let measured = (text as NSString).size(withAttributes: [.font: font])
        (text as NSString).draw(at: CGPoint(x: (size.width - measured.width) / 2, y: (size.height - measured.height) / 2),
                               withAttributes: [.font: font, .foregroundColor: NSColor.white])
        graphics.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        var points: [CGPoint] = []
        for y in 0..<height {
            for x in 0..<width where bytes[y * bitmap.bytesPerRow + x * 4 + 3] > 64 {
                // Bitmap rows are top-to-bottom, as are Canvas coordinates.
                points.append(CGPoint(x: (CGFloat(x) + 0.5) / scale, y: (CGFloat(y) + 0.5) / scale))
            }
        }
        let count = min(160, points.count)
        particles = (0..<count).map { index in
            // Fixed by glyph identity and sample index, not by the render frame.
            let phase = Double(index &* 73 &+ seed &* 37)
            let angle = phase * 2.399963229728653
            let distance = 2 + Double(index % 7) / 2
            return Particle(origin: points[index * points.count / count],
                            drift: CGVector(dx: cos(angle) * distance, dy: sin(angle) * distance),
                            radius: 0.35 + CGFloat(index % 3) * 0.08)
        }
    }
}

struct LyricTransition {
    let id = UUID()
    let startedAt = Date()
    let outgoing: LyricGlyph?
    let incoming: LyricGlyph
    let duration: Double
    let reduced: Bool
}

struct LyricTransitionCanvas: View {
    let transition: LyricTransition
    let date: Date
    let tint: Color

    var body: some View {
        Canvas { context, size in
            let p = min(1, max(0, date.timeIntervalSince(transition.startedAt) / transition.duration))
            let eased = p * p * (3 - 2 * p)
            if let outgoing = transition.outgoing {
                draw(outgoing, amount: eased, incoming: false, in: context, size: size)
            }
            draw(transition.incoming, amount: eased, incoming: true, in: context, size: size)
        }
    }

    private func draw(_ glyph: LyricGlyph, amount: Double, incoming: Bool, in context: GraphicsContext, size: CGSize) {
        let visibility = incoming ? amount : 1 - amount
        var textContext = context
        textContext.opacity = transition.reduced ? visibility : pow(visibility, 3)
        textContext.draw(Text(glyph.text).font(Font(glyph.font)).foregroundColor(tint),
                         at: CGPoint(x: size.width / 2, y: size.height / 2))
        guard !transition.reduced else { return }
        let spread = incoming ? 1 - amount : amount
        var dust = context
        dust.opacity = sin(.pi * visibility) * 0.55
        for particle in glyph.particles {
            let point = CGPoint(x: particle.origin.x + particle.drift.dx * spread,
                                y: particle.origin.y + particle.drift.dy * spread)
            dust.fill(Path(ellipseIn: CGRect(x: point.x - particle.radius, y: point.y - particle.radius,
                                             width: particle.radius * 2, height: particle.radius * 2)), with: .color(tint))
        }
    }
}
