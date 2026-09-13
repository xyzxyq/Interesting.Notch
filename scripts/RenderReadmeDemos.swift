// Component animations, not screen recordings. Run scripts/render-readme-demos.sh.
import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

@main @MainActor struct RenderReadmeDemos {
    static func main() throws {
        for name in ["codex-completion", "codex-droplet", "music-edge", "paper-plane"] {
            let url = URL(fileURLWithPath: "docs/assets/\(name).gif")
            let frames = 100
            let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames, nil)!
            CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
            for frame in 0..<frames {
                let time = Double(frame) / 20
                let renderer = ImageRenderer(content: demo(name, time: time))
                renderer.scale = 1
                guard let image = renderer.cgImage else { fatalError("Failed to render \(name)") }
                CGImageDestinationAddImage(destination, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.05]] as CFDictionary)
            }
            guard CGImageDestinationFinalize(destination) else { fatalError("GIF export failed") }
            print("Rendered \(url.lastPathComponent): 100 frames / 5 seconds")
        }
    }

    static func demo(_ name: String, time: Double) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(["codex-completion": "CODEX · 火箭与完成彩带", "codex-droplet": "CODEX · 液态提醒与合并",
                      "music-edge": "MUSIC · 随音乐流动的边缘", "paper-plane": "POINTER · 黑色折纸指针"][name]!)
                    .font(.system(size: 18, weight: .semibold))
                Spacer()
                Text("3.0.4").font(.system(size: 12, design: .monospaced)).opacity(0.6)
            }.padding(28)
            ZStack {
                if name == "codex-completion" {
                    let rocket = min(1, time / 0.55) * (1 - min(1, max(0, (time - 4) / 0.5)))
                    NotchShape(rocket: rocket).fill(.black)
                        .overlay { CodexFlame(active: time > 0.55 && time < 2.25, effort: 4).opacity(time > 2 ? max(0, (2.25-time)/0.25) : 1) }
                        .overlay(alignment: .topLeading) {
                            Canvas { context, size in
                                CodexConfettiFrame.draw(in: &context, size: size, elapsed: time - 2.25)
                            }.frame(width: 472, height: 232)
                        }
                        .frame(width: 280, height: 32).offset(x: -75, y: -60)
                } else if name == "codex-droplet" {
                    let motion = CodexDropMotion.sample(CodexDropMotion.fall,
                        initial: .init(progress: 0, surface: 0, duration: 0), time: min(time, 1.8))
                    VStack(spacing: 0) {
                        NotchShape(liquid: motion.surface).fill(.black).frame(width: 280, height: 32)
                        CodexLiquidDrop(progress: motion.progress,
                            mergeElapsed: time > 2 ? min(time - 2, CodexMergeMotion.duration) : nil,
                            volumeScale: time > 2 ? CodexMergeMotion.scale(for: 1 + CodexMergeMotion.absorbed(at: time - 2)) : 1)
                    }.offset(y: -30)
                } else if name == "music-edge" {
                    VStack(spacing: 44) {
                        ForEach(["waterColor", "meteor"], id: \.self) { style in
                            ZStack {
                                NotchShape().fill(.black).padding(24)
                                MusicEdgeFrame(shape: NotchShape(), style: style, strength: 1,
                                    energy: 0.5 + sin(time * 3) * 0.4, phase: time * 0.8, color: .cyan, reduced: false, sky: true)
                            }.frame(width: 360, height: 80)
                        }
                    }
                } else {
                    let scale = 1.25 - cos(time * .pi * 2 / 5) * 0.5
                    Image(decorative: PaperPlaneArtwork.image(scale: 4, magnification: scale), scale: 1)
                        .resizable().interpolation(.high).frame(width: 64 * scale, height: 64 * scale)
                    Text("75% — 175% · 默认关闭").font(.system(size: 14)).offset(y: 100)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Text("项目原生组件动画 · 演示数据，非桌面录屏")
                .font(.system(size: 11)).opacity(0.6).padding(18)
        }
        .foregroundStyle(.white)
        .frame(width: 640, height: 360)
        .background(LinearGradient(colors: [Color(red: 0.19, green: 0.24, blue: 0.32), Color(red: 0.10, green: 0.13, blue: 0.20)], startPoint: .topLeading, endPoint: .bottomTrailing))
    }
}
