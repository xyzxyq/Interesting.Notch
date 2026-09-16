import AppKit
import SwiftUI

@main @MainActor struct CodexDissolveChecks {
    static func main() throws {
        // Exercise native controls in a real hosting view, not just vector artwork.
        // The old Canvas symbol recursively rendered the scroll view and aborted.
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 476, height: 456),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.center()
        for (opening, progress) in [(true, CGFloat(1)), (true, 0.5), (true, 0), (false, 0), (false, 0.5), (false, 1)] {
            panel.contentView = NSHostingView(rootView:
                ScrollView {
                    VStack {
                        Text("Pending request")
                        TextField("Reply", text: .constant(""), axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                        Button("Send") {}
                        ForEach(0..<20) { Text("Reminder \($0)") }
                    }.background(CodexScrollAppearance())
                }.frame(width: 380, height: 360)
                .background(Color(white: 0.09), in: RoundedRectangle(cornerRadius: 20))
                .modifier(CodexDissolve(progress: opening ? 0 : progress))
                .modifier(CodexCardReveal(progress: opening ? progress : 0)).padding(48))
            panel.orderFront(nil)
            panel.contentView?.layoutSubtreeIfNeeded()
            panel.displayIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            if progress == 0 {
                func scrollView(in view: NSView) -> NSScrollView? {
                    if let scroll = view as? NSScrollView { return scroll }
                    return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
                }
                guard let scroll = scrollView(in: panel.contentView!) else { fatalError("Missing native scroll view") }
                assert(scroll.scrollerStyle == .overlay && scroll.autohidesScrollers)
                assert(scroll.verticalScroller?.controlSize == .small)

                let point = panel.convertPoint(toScreen: NSPoint(x: 238, y: 228))
                assert(NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0) == panel.windowNumber,
                       "Visible request content must receive real mouse clicks, not pass through")
            }
        }
        panel.orderOut(nil)
        for progress in [CGFloat(1), 0.38, 0] {
            assert(abs(CodexCardReveal.settlingOffset(progress: progress)) < 0.000001)
        }
        for step in 0...1000 {
            let offset = CodexCardReveal.settlingOffset(progress: CGFloat(step) / 1000)
            assert(offset >= 0 && offset <= 1.2)
        }
        let epsilon: CGFloat = 0.001
        assert(abs(CodexCardReveal.settlingOffset(progress: 0.38 - epsilon) / epsilon) < 0.001)
        assert(abs(CodexCardReveal.settlingOffset(progress: epsilon) / epsilon) < 0.001)
        assert(CodexCardReveal.duration == 0.65)
        let revealSize = CGSize(width: 380, height: 342)
        let initial = CodexCardReveal.outline(size: revealSize, progress: 1).boundingRect
        assert(initial.width == 32 && initial.height == 32 && initial.midX == revealSize.width / 2)
        var previous = initial
        for step in 0...100 {
            let outline = CodexCardReveal.outline(size: revealSize, progress: 1 - CGFloat(step) / 100).boundingRect
            assert(outline.width >= previous.width && outline.height >= previous.height)
            assert(abs(outline.midX - revealSize.width / 2) < 0.001 && outline.minY == 0)
            assert(outline.maxX <= revealSize.width && outline.maxY <= revealSize.height)
            previous = outline
        }
        assert(previous.size == revealSize)
        assert(CodexDissolve.duration == 0.8)
        var coverage: [Int] = []
        var centers: [Double] = []
        for progress in [0.0, 0.25, 0.5, 0.75, 1.0] {
            let renderer = ImageRenderer(content:
                RoundedRectangle(cornerRadius: 12).fill(.black)
                    .frame(width: 120, height: 80)
                    .modifier(CodexDissolve(progress: progress)).padding(48))
            renderer.scale = 1
            guard let image = renderer.cgImage else { fatalError("Missing dissolve render") }
            let bitmap = NSBitmapImageRep(cgImage: image)
            var count = 0
            var sumY = 0.0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    if bitmap.colorAt(x: x, y: y)!.alphaComponent > 0.05 { count += 1; sumY += Double(y) }
                }
            }
            coverage.append(count)
            if count > 0 { centers.append(sumY / Double(count)) }
            if progress == 0.5 {
                assert(bitmap.colorAt(x: 108, y: 56)!.alphaComponent > 0.95,
                       "The droplet attachment area must remain intact while the bottom dissolves")
                for y in 52...60 {
                    for x in 104...112 {
                        assert(bitmap.colorAt(x: x, y: y)!.alphaComponent > 0.95,
                               "The intact center must not contain a visible tile grid")
                    }
                }
                assert(bitmap.colorAt(x: 108, y: 124)!.alphaComponent < 0.05,
                       "The bottom must disappear before the top droplet attachment area")
                assert(bitmap.colorAt(x: 50, y: 88)!.alphaComponent < 0.05,
                       "Dissolve must begin at the edge")
            }
        }
        assert(zip(coverage, coverage.dropFirst()).allSatisfy { $0 > $1 })
        assert(coverage.last == 0)
        assert(zip(centers, centers.dropFirst()).allSatisfy { $0 > $1 },
               "The visible remnant must move upward toward the droplet")
        for progress in [0.0, 1.0] {
            let renderer = ImageRenderer(content: Color.black.frame(width: 120, height: 80)
                .modifier(CodexCardReveal(progress: progress)))
            guard let image = renderer.cgImage else { fatalError("Missing opening render") }
            let bitmap = NSBitmapImageRep(cgImage: image)
            assert(bitmap.colorAt(x: 60, y: 40)!.alphaComponent == 1 - progress)
        }
        print("PASS: native controls survive opening/closing and receive mouse hits; soft reveal, upward-converging monotonic dissolve, transparent completion")
    }
}
