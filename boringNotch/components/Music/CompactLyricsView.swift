import AppKit
import SwiftUI

enum CompactLyricsLayout {
    static let font = NSFont.systemFont(ofSize: 13, weight: .medium)
    static let slotWidth = ceil(("歌颂你" as NSString).size(withAttributes: [.font: font]).width) + 8
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

    @State private var current: LyricSegment?

    private struct Clock: Equatable {
        let revision: UInt64
        let position: Double
        let date: Date
        let rate: Double
        let playing: Bool
    }

    private var clock: Clock {
        Clock(revision: revision, position: position, date: sampleDate, rate: rate, playing: isPlaying)
    }

    var body: some View {
        Group {
            if let current {
                Text(current.text)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.1)
                    .padding(.horizontal, 4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                fallback()
            }
        }
        .task(id: clock) {
            while !Task.isCancelled {
                let now = Date()
                let elapsed = isPlaying ? position + max(0, now.timeIntervalSince(sampleDate)) * rate : position
                guard elapsed.isFinite else { current = nil; return }
                current = CompactLyrics.segment(at: max(0, elapsed), in: segments)
                guard isPlaying, rate.isFinite, rate > 0,
                      let next = CompactLyrics.nextBoundary(after: elapsed, in: segments) else { return }
                do {
                    try await Task.sleep(for: .seconds(max(0.001, (next - elapsed) / rate)))
                } catch { return }
            }
        }
    }
}
