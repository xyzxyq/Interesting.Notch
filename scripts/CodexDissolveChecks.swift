import AppKit
import SwiftUI

@main @MainActor struct CodexDissolveChecks {
    static func main() throws {
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
        print("PASS: visible content, particle breakup, fully transparent completion")
    }
}
