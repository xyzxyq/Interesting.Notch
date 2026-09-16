import AppKit
import SwiftUI

@MainActor private final class HoverState: ObservableObject {
    @Published var expanded = false
}

private struct HoverFixture: View {
    @ObservedObject var state: HoverState
    var body: some View {
        CodexDropButton(waiting: true, expanded: state.expanded, count: 4,
                        action: { _ in }, surface: .constant(0))
            .padding(20)
    }
}

@main @MainActor struct CodexHoverChecks {
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let state = HoverState()
        let view = NSHostingView(rootView: HoverFixture(state: state))
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 104, height: 122),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.contentView = view
        panel.center()
        panel.orderFront(nil)
        defer { panel.orderOut(nil) }
        func advance(_ seconds: Double) {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
            view.layoutSubtreeIfNeeded()
            panel.displayIfNeeded()
        }
        func coverage() -> Double {
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                fatalError("Missing droplet render")
            }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            var alpha = 0.0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    alpha += bitmap.colorAt(x: x, y: y)!.alphaComponent
                }
            }
            return alpha
        }
        advance(5) // Initial drop plus three request-merge animations.
        let settled = coverage()
        assert(settled > 100)
        state.expanded = true
        advance(0.35)
        assert(coverage() < settled * 0.05, "Expanded notch must hide the droplet")
        state.expanded = false
        advance(0.35)
        assert(coverage() > settled * 0.9, "Restore the existing size without replaying the fall")
        for _ in 0..<5 {
            state.expanded = true
            advance(0.07)
            state.expanded = false
            advance(0.07)
        }
        advance(0.35)
        assert(coverage() > settled * 0.9, "Rapid hover reversals must preserve the four-request droplet")
        print("PASS: expanded hiding, immediate size restoration and five rapid hover reversals")
    }
}
