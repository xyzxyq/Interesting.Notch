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
        for progress in [1.0, 0.5, 0.0, 0.5, 1.0] {
            panel.contentView = NSHostingView(rootView:
                ScrollView {
                    VStack {
                        Text("Pending request")
                        TextField("Reply", text: .constant(""), axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                        Button("Send") {}
                    }
                }.frame(width: 380, height: 360)
                .background(Color(white: 0.09), in: RoundedRectangle(cornerRadius: 20))
                .modifier(CodexDissolve(progress: progress)).padding(48))
            panel.orderFront(nil)
            panel.contentView?.layoutSubtreeIfNeeded()
            panel.displayIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            if progress == 0 {
                let point = panel.convertPoint(toScreen: NSPoint(x: 238, y: 228))
                assert(NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0) == panel.windowNumber,
                       "Visible request content must receive real mouse clicks, not pass through")
            }
        }
        panel.orderOut(nil)
        var coverage: [Int] = []
        for progress in [0.0, 0.5, 1.0] {
            let renderer = ImageRenderer(content:
                RoundedRectangle(cornerRadius: 12).fill(.black)
                    .frame(width: 120, height: 80)
                    .modifier(CodexDissolve(progress: progress)).padding(48))
            renderer.scale = 1
            guard let image = renderer.cgImage else { fatalError("Missing dissolve render") }
            let bitmap = NSBitmapImageRep(cgImage: image)
            var count = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    if bitmap.colorAt(x: x, y: y)!.alphaComponent > 0.05 { count += 1 }
                }
            }
            coverage.append(count)
        }
        assert(coverage[0] > coverage[1] && coverage[1] > 0)
        assert(coverage[2] == 0)
        print("PASS: native controls survive opening/closing and receive mouse hits; visible content, particle breakup, transparent completion")
    }
}
