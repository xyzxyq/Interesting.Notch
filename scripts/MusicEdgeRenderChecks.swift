import AppKit
import SwiftUI

/// Compile with EDGE_CHECKS and the production edge/shape sources. Optional output
/// directory writes fixed-time frames and enlarged corners; otherwise benchmarks only.
@main @MainActor struct MusicEdgeRenderChecks {
    static let styles = ["water", "waterWhite", "waterColor", "ripple", "dust", "meteor", "mist"]
    static let shape = NotchShape(topCornerRadius: 6, bottomCornerRadius: 12)
    static func effect(_ style: String, phase: Double, energy: Double = 1) -> some View {
        MusicEdgeFrame(shape: shape, style: style, strength: 1, energy: energy, phase: phase,
                       color: .white, reduced: false).frame(width: 352, height: 80)
    }
    static func main() throws {
        if let directory = CommandLine.arguments.dropFirst().first {
            let folder = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for style in styles { for phase in [0.1, 0.7, 1.2] {
                let renderer = ImageRenderer(content: effect(style, phase: phase)); renderer.scale = 2
                try NSBitmapImageRep(cgImage: renderer.cgImage!).representation(using: .png, properties: [:])!
                    .write(to: folder.appendingPathComponent("\(style)-\(phase).png"))
            } }
            let contact = VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(styles.prefix(4)), id: \.self) { style in
                    HStack {
                        Text(style).frame(width: 100)
                        ForEach([0.1, 0.7, 1.2], id: \.self) { phase in
                            ZStack {
                                Color(white: style == "water" ? 0.6 : 0.1)
                                shape.fill(.black).padding(24)
                                effect(style, phase: phase)
                            }.frame(width: 352, height: 80)
                                .frame(width: 75, height: 55, alignment: .bottomTrailing).clipped()
                                .scaleEffect(3, anchor: .topLeading)
                                .frame(width: 225, height: 165, alignment: .topLeading)
                        }
                    }
                }
            }.padding(16).foregroundStyle(.white).background(Color(white: 0.13))
            let renderer = ImageRenderer(content: contact); renderer.scale = 2
            try NSBitmapImageRep(cgImage: renderer.cgImage!).representation(using: .png, properties: [:])!
                .write(to: folder.appendingPathComponent("corners.png"))
        }
        for style in styles {
            var samples: [Double] = []
            for index in 0..<160 {
                let time: Double = autoreleasepool {
                    let start = ProcessInfo.processInfo.systemUptime
                    let renderer = ImageRenderer(content: effect(style, phase: Double(index) / 31)); renderer.scale = 2
                    guard renderer.cgImage != nil else { fatalError("Effect did not render") }
                    return (ProcessInfo.processInfo.systemUptime - start) * 1000
                }
                if index >= 40 { samples.append(time) }
            }
            samples.sort()
            print(String(format: "%@ median=%.4f p95=%.4f ms", style, samples[60], samples[114]))
        }
    }
}
