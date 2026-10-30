import AppKit
import SwiftUI

private final class FlippedCordAnchor: NSView {
    override var isFlipped: Bool { true }
}

@MainActor private final class FishMotionFixture: ObservableObject {
    @Published var waiting = true
    @Published var isOpen = false
    @Published var since = Date.now
}

private struct FishMotionFixtureView: View {
    @ObservedObject var state: FishMotionFixture
    var body: some View {
        CodexPullCordButton(waiting: state.waiting, count: state.waiting ? 1 : 0,
            isOpen: state.isOpen, style: .fish, waitingSince: state.since, action: { _ in })
    }
}

@main @MainActor struct CodexPullCordChecks {
    static func main() async throws {
        _ = NSApplication.shared
        assert(CodexReminderStyle.allCases.map(\.rawValue) == ["droplet", "pullCord"])
        assert(CodexReminderStyle.droplet.title == "水滴")
        assert(CodexReminderStyle.pullCord.title == "拉绳开关")
        assert(CodexPullCordStyle.allCases.map(\.rawValue) == ["classic", "donut", "orbit", "crystal", "jellyfish", "ufo", "moon", "capsule", "fish"])
        assert(Set(CodexPullCordStyle.allCases.map(\.title)).count == 9)
        assert(CodexFishStage.allCases.map(\.startsAfter) == [0, 120, 600, 1200])
        for elapsed in [-100.0, 0, 119.9] { assert(CodexFishStage.at(elapsed: elapsed) == .lively) }
        for elapsed in [120.0, 599.9] { assert(CodexFishStage.at(elapsed: elapsed) == .drying) }
        for elapsed in [600.0, 1199.9] { assert(CodexFishStage.at(elapsed: elapsed) == .dead) }
        for elapsed in [1200.0, 3600] { assert(CodexFishStage.at(elapsed: elapsed) == .skeleton) }
        for elapsed in [Double.nan, .infinity, -.infinity] {
            assert(CodexFishStage.at(elapsed: elapsed) == .lively, "Invalid clocks must fall back safely")
        }
        assert(CodexFishStage.lively.isAlive && CodexFishStage.drying.isAlive)
        assert(!CodexFishStage.dead.isAlive && !CodexFishStage.skeleton.isAlive)

        let now = Date(timeIntervalSince1970: 1_000)
        var cue = CodexFishCatchCue()
        assert(!cue.consume(nil, animated: true, now: now))
        assert(cue.consume(now, animated: true, now: now))
        assert(!cue.consume(now, animated: true, now: now), "Opening/closing or reappearing cannot replay a consumed catch")
        assert(!cue.consume(now.addingTimeInterval(-200), animated: true, now: now), "Old fish must not replay an arrival")
        let next = now.addingTimeInterval(1)
        assert(!cue.consume(next, animated: false, now: next), "Reduced motion / already open cards skip arrival")
        assert(!cue.consume(next, animated: true, now: next), "Skipped arrivals must not replay after motion resumes")
        assert(cue.consume(next.addingTimeInterval(1), animated: true, now: next.addingTimeInterval(1)))

        let panel = NSPanel(contentRect: CGRect(x: 200, y: 200, width: 200, height: 200),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        panel.contentView = container
        for view in [NSView(frame: CGRect(x: 30, y: 40, width: 64, height: 82)),
                     FlippedCordAnchor(frame: CGRect(x: 30, y: 40, width: 64, height: 82))] {
            container.addSubview(view)
            let anchor = CodexPullCordButton.topAnchor(view: view)
            assert(abs(anchor.x - 262) < 0.001 && abs(anchor.y - 322) < 0.001,
                   "Cord must originate at the mounted slot's screen top regardless of flipped coordinates")
            view.removeFromSuperview()
        }

        for style in CodexPullCordStyle.allCases {
          for stretch in [CGFloat(0), 2, 8, 10] {
            for count in [1, 9, 99, 1000] {
              for glow in [CGFloat(0), 1] {
               for scale in [CGFloat(1), 2] {
                let renderer = ImageRenderer(content: CodexPullCordArtwork(stretch: stretch, isOpen: false,
                    style: style, count: count, glow: glow))
                renderer.scale = scale
                guard let image = renderer.cgImage else { fatalError("Missing pull-cord render") }
                let bitmap = NSBitmapImageRep(cgImage: image)
                assert(bitmap.pixelsWide == Int(64 * scale) && bitmap.pixelsHigh == Int(82 * scale))
                if CommandLine.arguments.count > 1 && style == .fish && stretch == 0 && glow == 0 && count > 1 && scale == 2 {
                    let url = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("cord-fish-count-\(count)-2x.png")
                    try bitmap.representation(using: .png, properties: [:])!.write(to: url)
                }
                for y in 0..<bitmap.pixelsHigh {
                    for x in [0, bitmap.pixelsWide - 1] {
                        assert(bitmap.colorAt(x: x, y: y)!.alphaComponent < 0.01,
                               "Cord or count badge clips at a horizontal slot edge")
                    }
                }
                for x in 0..<bitmap.pixelsWide {
                    assert(bitmap.colorAt(x: x, y: bitmap.pixelsHigh - 1)!.alphaComponent < 0.01,
                           "Handle/shadow clips: \(style), stretch \(stretch), count \(count), glow \(glow), scale \(scale)")
                }
                if style == .donut && count == 1 && glow == 0 {
                    assert(bitmap.colorAt(x: Int(32 * scale), y: Int((51 + stretch) * scale))!.alphaComponent < 0.3,
                           "The donut must retain a transparent central hole")
                }
               }
              }
            }
          }
          let lampSamples = [CGFloat(0), 1].map { glow -> CGFloat in
            let renderer = ImageRenderer(content: CodexPullCordArtwork(stretch: 0, isOpen: false,
                style: style, count: 1, glow: glow))
            renderer.scale = 2
            return NSBitmapImageRep(cgImage: renderer.cgImage!).colorAt(x: style == .fish ? 46 : 44, y: style == .fish ? 124 : 80)!.alphaComponent
          }
          assert(lampSamples[1] > lampSamples[0] + 0.01, "Every style must visibly brighten during its breathing cycle")
        }
        let fishStages: [CodexFishStage] = [.lively, .drying, .dead, .skeleton]
        for stage in fishStages {
            let halo = [CGFloat(0), 1].map { glow -> CGFloat in
                let renderer = ImageRenderer(content: CodexPullCordArtwork(stretch: 0, isOpen: false,
                    style: .fish, count: 1, glow: glow, fishStage: stage))
                renderer.scale = 2
                let bitmap = NSBitmapImageRep(cgImage: renderer.cgImage!)
                return bitmap.colorAt(x: 77, y: 84)!.alphaComponent
            }
            assert(halo[1] > halo[0] + 0.05, "The halo outside the fish must breathe in every waiting stage")
        }
        // The mouth stays on the cord while only the lower contour deforms.
        for skeleton in [false, true] {
            for shift in [CGFloat(-2.4), -1.2, 0, 1.2, 2.4] {
                let path = CodexLineFishShape(tailShift: shift, skeleton: skeleton)
                    .path(in: CGRect(x: 0, y: 0, width: 34, height: 32))
                let ink = path.cgPath.copy(strokingWithWidth: 1.15, lineCap: .round, lineJoin: .round, miterLimit: 1)
                assert(ink.contains(CGPoint(x: 17, y: 3.5)), "The cord endpoint must meet the mouth in every pose")
                assert(!ink.contains(CGPoint(x: 17, y: 5)), "The cord must stop at the mouth, not cross the face")
                assert(path.boundingRect.height > path.boundingRect.width * 2, "Fish must stay upright and slender")
            }
        }
        var leftTail: CGPoint?
        var rightTail: CGPoint?
        for shift in [CGFloat(-2.4), 2.4] {
            let outline = CodexLineFishShape(tailShift: shift, skeleton: false)
                .path(in: CGRect(x: 0, y: 0, width: 34, height: 32))
            let tail = outline.cgPath.copy(strokingWithWidth: 1.5, lineCap: .round, lineJoin: .round, miterLimit: 1)
            let expected = CGPoint(x: 17 + shift, y: 27.6)
            assert(tail.contains(expected), "Tail tip must travel to both sides of the fixed mouth")
            if shift < 0 { leftTail = expected } else { rightTail = expected }
        }
        assert(leftTail!.x < 17 && rightTail!.x > 17)
        var eyePoses = Set<Data>()
        for (swing, hover) in [(CGFloat(-1), false), (1, false), (0, true)] {
            let renderer = ImageRenderer(content: CodexPullCordArtwork(stretch: 0, isOpen: false,
                style: .fish, hovered: hover, count: 1, glow: 0.5, tailSwing: swing))
            renderer.scale = 4
            let eye = renderer.cgImage!.cropping(to: CGRect(x: 31 * 4, y: 43 * 4, width: 4 * 4, height: 4 * 4))!
            eyePoses.insert(NSBitmapImageRep(cgImage: eye).representation(using: .png, properties: [:])!)
        }
        assert(eyePoses.count == 3, "The eye must respond to both tail directions and hover")
        var catchFrames = Set<Data>()
        for scale in [CGFloat(1), 2] {
            for progress in [CGFloat(0), 0.25, 0.5, 0.75, 1] {
                for stretch in [CGFloat(-5), 0, 10] {
                    for swing in [CGFloat(-1), 1] {
                        let view = CodexPullCordArtwork(stretch: stretch, isOpen: false, style: .fish,
                            count: 1000, glow: 1, tailSwing: swing, catching: true, catchProgress: progress)
                        let renderer = ImageRenderer(content: view)
                        renderer.scale = scale
                        let bitmap = NSBitmapImageRep(cgImage: renderer.cgImage!)
                        for y in 0..<bitmap.pixelsHigh {
                            for x in [0, bitmap.pixelsWide - 1] { assert(bitmap.colorAt(x: x, y: y)!.alphaComponent < 0.01) }
                        }
                        for x in 0..<bitmap.pixelsWide {
                            assert(bitmap.colorAt(x: x, y: bitmap.pixelsHigh - 1)!.alphaComponent < 0.01,
                                   "Catch splash, tail and tug must stay inside the reminder slot")
                        }
                        if scale == 2 && stretch == 0 && swing == 1 {
                            catchFrames.insert(bitmap.representation(using: .png, properties: [:])!)
                        }
                    }
                }
            }
        }
        assert(catchFrames.count == 4, "Splash must have three distinct intermediate poses and identical invisible endpoints")
        let reelPoses: [(CGFloat, CGFloat)] = [(0, 0), (0.4, 0), (0.9, 8), (1, 23), (1, 36)]
        for scale in [CGFloat(1), 2] {
            var previousBottom = Int.max
            for (reel, rise) in reelPoses {
                let renderer = ImageRenderer(content: CodexPullCordArtwork(stretch: 0, isOpen: false,
                    style: .fish, count: 1, retraction: reel, rise: rise))
                renderer.scale = scale
                let bitmap = NSBitmapImageRep(cgImage: renderer.cgImage!)
                var lowestPixel = -1
                for y in 0..<bitmap.pixelsHigh {
                    for x in 0..<bitmap.pixelsWide where bitmap.colorAt(x: x, y: y)!.alphaComponent > 0.01 {
                        lowestPixel = max(lowestPixel, y)
                    }
                }
                assert(lowestPixel < previousBottom, "Retraction must continuously move the fish into the island")
                previousBottom = lowestPixel
                if rise == 36 { assert(lowestPixel == -1, "No fish, cord or shadow may remain after retraction") }
            }
        }
        var fishImages = Set<Data>()
        for stage in fishStages {
            var restingImages: [NSBitmapImageRep] = []
            for stretch in [CGFloat(0), 10] {
                for glow in [CGFloat(0), 1] {
                    for flapping in [false, true] {
                        let renderer = ImageRenderer(content: CodexPullCordArtwork(stretch: stretch, isOpen: false,
                            style: .fish, count: 1000, glow: glow, fishStage: stage, fishFlapping: flapping))
                        renderer.scale = 2
                        let bitmap = NSBitmapImageRep(cgImage: renderer.cgImage!)
                        for y in 0..<bitmap.pixelsHigh {
                            assert(bitmap.colorAt(x: 0, y: y)!.alphaComponent < 0.01)
                            assert(bitmap.colorAt(x: bitmap.pixelsWide - 1, y: y)!.alphaComponent < 0.01)
                        }
                        for x in 0..<bitmap.pixelsWide {
                            assert(bitmap.colorAt(x: x, y: bitmap.pixelsHigh - 1)!.alphaComponent < 0.01,
                                   "Fish phase or tail swing clips at the bottom of its slot")
                        }
                        if stretch == 0 && glow == 0 && !flapping {
                            fishImages.insert(bitmap.representation(using: .png, properties: [:])!)
                            if stage == .lively {
                                let unbadged = ImageRenderer(content: CodexPullCordArtwork(stretch: 0, isOpen: false,
                                    style: .fish, count: 1, glow: 0, fishStage: .lively, fishFlapping: false))
                                unbadged.scale = 2
                                let reference = NSBitmapImageRep(cgImage: unbadged.cgImage!)
                                var bodyBounds = CGRect.null
                                for y in 76..<bitmap.pixelsHigh {
                                    for x in 0..<bitmap.pixelsWide {
                                        let color = reference.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                                        if color.alphaComponent > 0.7 && color.redComponent > 0.7 && abs(color.blueComponent - color.redComponent) < 0.08 {
                                            bodyBounds = bodyBounds.union(CGRect(x: x, y: y, width: 1, height: 1))
                                            let badged = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                                            assert(abs(color.redComponent - badged.redComponent) < 0.03 &&
                                                   abs(color.greenComponent - badged.greenComponent) < 0.03 &&
                                                   abs(color.blueComponent - badged.blueComponent) < 0.03,
                                                   "The 99+ badge must not cover the hanging fish")
                                        }
                                    }
                                }
                                assert(!bodyBounds.isNull && bodyBounds.height > bodyBounds.width * 1.3,
                                       "The outline fish must hang vertically, not return to a sideways pose")
                            }
                        }
                        if stretch == 0 && glow == 0 {
                            restingImages.append(bitmap)
                        }
                    }
                }
            }
            assert(restingImages.count == 2)
            var restDifference: CGFloat = 0
            for y in 0..<restingImages[0].pixelsHigh {
                for x in 0..<restingImages[0].pixelsWide {
                    let a = restingImages[0].colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                    let b = restingImages[1].colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                    restDifference = max(restDifference, abs(a.alphaComponent - b.alphaComponent),
                        abs(a.redComponent * a.alphaComponent - b.redComponent * b.alphaComponent),
                        abs(a.greenComponent * a.alphaComponent - b.greenComponent * b.alphaComponent),
                        abs(a.blueComponent * a.alphaComponent - b.blueComponent * b.alphaComponent))
                }
            }
            // Compare rendered pixels, allowing one quantization step in the soft gradient.
            assert(restDifference < 0.005, "Tail/gill phases must share the same resting frame: \(restDifference)")
        }
        assert(fishImages.count == 4, "Lively, drying, dead and skeleton fish must render distinct silhouettes/materials")
        if CommandLine.arguments.count > 1 {
            let sheet = VStack(spacing: 24) {
                ForEach(0..<3) { row in
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(Array(CodexPullCordStyle.allCases.dropFirst(row * 3).prefix(3))) { style in
                            VStack(spacing: 12) {
                                CodexPullCordArtwork(stretch: 2, isOpen: false, style: style, count: 1, glow: 1)
                                Text(style.title).font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                            }.frame(width: 104)
                        }
                    }
                }
            }.padding(24).background(Color(white: 0.10)).environment(\.colorScheme, .dark)
            let fishDetail = HStack(spacing: 20) {
                ForEach(0..<4) { index in
                    VStack(spacing: 12) {
                        CodexPullCordArtwork(stretch: 0, isOpen: false, style: .fish, count: 1, glow: 0.6,
                            fishStage: fishStages[index], fishFlapping: false)
                            .offset(y: -30).frame(width: 64, height: 52, alignment: .top).clipped()
                            .scaleEffect(3).frame(width: 192, height: 156)
                        Text(["刚上钩", "渐渐安静", "等待过久", "只剩鱼骨"][index]).font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                    }.frame(width: 208)
                }
            }.padding(24).background(Color(white: 0.10)).environment(\.colorScheme, .dark)
            let fishSheet = HStack(spacing: 20) {
                ForEach(0..<4) { index in
                    VStack(spacing: 12) {
                        CodexPullCordArtwork(stretch: 0, isOpen: false, style: .fish, count: 1, glow: 0.6,
                            fishStage: fishStages[index], fishFlapping: false)
                        Text(["刚上钩", "渐渐安静", "等待过久", "只剩鱼骨"][index]).font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                    }.frame(width: 104)
                }
            }.padding(24).background(Color(white: 0.10)).environment(\.colorScheme, .dark)
            let contactSheet = VStack(spacing: 18) {
                ForEach(0..<3) { phase in
                    HStack(spacing: 16) {
                        ForEach(0..<4) { index in
                            VStack(spacing: 8) {
                                CodexPullCordArtwork(stretch: 0, isOpen: false, style: .fish, count: 1,
                                    glow: CGFloat(phase) / 2, fishStage: fishStages[index], fishFlapping: true)
                                    .offset(x: -20, y: -35).frame(width: 28, height: 24, alignment: .topLeading).clipped()
                                    .scaleEffect(5).frame(width: 140, height: 120)
                                Text(["活鱼", "干涩", "死鱼", "鱼骨"][index] + " · " + ["静止", "半程", "甩动末端"][phase])
                                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.white)
                            }.frame(width: 148)
                        }
                    }
                }
            }.padding(24).background(Color(white: 0.10)).environment(\.colorScheme, .dark)
            for scale in [CGFloat(1), 2] {
                let renderer = ImageRenderer(content: sheet)
                renderer.scale = scale
                let bitmap = NSBitmapImageRep(cgImage: renderer.cgImage!)
                let url = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("cord-styles-\(Int(scale))x.png")
                try bitmap.representation(using: .png, properties: [:])!.write(to: url)
                let fishRenderer = ImageRenderer(content: fishSheet)
                fishRenderer.scale = scale
                let fishBitmap = NSBitmapImageRep(cgImage: fishRenderer.cgImage!)
                let fishURL = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("cord-fish-stages-\(Int(scale))x.png")
                try fishBitmap.representation(using: .png, properties: [:])!.write(to: fishURL)
            }
            let contrastSheet = VStack(spacing: 0) {
                ForEach([0.0, 0.5, 1.0], id: \.self) { background in
                    HStack(spacing: 24) {
                        ForEach(0..<4) { index in
                            VStack(spacing: 8) {
                                CodexPullCordArtwork(stretch: 0, isOpen: false, style: .fish, count: 1,
                                    glow: 0.6, fishStage: fishStages[index])
                                    .scaleEffect(2).frame(width: 128, height: 164)
                                Text(fishStages[index].title).font(.system(size: 12))
                                    .foregroundStyle(background > 0.7 ? .black : .white)
                            }
                        }
                    }.padding(20).background(Color(white: background))
                }
            }
            let contrastRenderer = ImageRenderer(content: contrastSheet)
            contrastRenderer.scale = 2
            let contrastBitmap = NSBitmapImageRep(cgImage: contrastRenderer.cgImage!)
            try contrastBitmap.representation(using: .png, properties: [:])!.write(to:
                URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("cord-fish-background-contrast.png"))
            let catchSheet = HStack(spacing: 12) {
                ForEach(0..<5) { index in
                    VStack(spacing: 10) {
                        CodexPullCordArtwork(stretch: [7, -4, 1.5, 0, 0][index], isOpen: false,
                            style: .fish, count: 1, glow: 0.7, tailSwing: [0, 0.9, -1, 0.55, 0][index],
                            catching: true, catchProgress: CGFloat(index) / 4)
                            .scaleEffect(2.5).frame(width: 160, height: 205)
                        Text(["入场", "提起", "回弹", "水花消散", "落稳"][index])
                            .font(.system(size: 12)).foregroundStyle(.white)
                    }
                }
            }.padding(20).background(Color(white: 0.12))
            let catchRenderer = ImageRenderer(content: catchSheet)
            catchRenderer.scale = 2
            try NSBitmapImageRep(cgImage: catchRenderer.cgImage!).representation(using: .png, properties: [:])!.write(to:
                URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("cord-fish-catch-storyboard.png"))
            let reelSheet = HStack(spacing: 12) {
                ForEach(0..<reelPoses.count, id: \.self) { index in
                    VStack(spacing: 10) {
                        CodexPullCordArtwork(stretch: 0, isOpen: false, style: .fish, count: 1,
                            retraction: reelPoses[index].0, rise: reelPoses[index].1)
                            .scaleEffect(2.5).frame(width: 160, height: 205)
                        Text(["开始收线", "吊线缩短", "上提", "收进岛内", "完成"][index])
                            .font(.system(size: 12)).foregroundStyle(.white)
                    }
                }
            }.padding(20).background(Color(white: 0.12))
            let reelRenderer = ImageRenderer(content: reelSheet)
            reelRenderer.scale = 2
            try NSBitmapImageRep(cgImage: reelRenderer.cgImage!).representation(using: .png, properties: [:])!.write(to:
                URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("cord-fish-retraction-storyboard.png"))
            let detailRenderer = ImageRenderer(content: fishDetail)
            detailRenderer.scale = 2
            let detail = NSBitmapImageRep(cgImage: detailRenderer.cgImage!)
            let detailURL = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("cord-fish-material-detail-2x.png")
            try detail.representation(using: .png, properties: [:])!.write(to: detailURL)
            let contactRenderer = ImageRenderer(content: contactSheet)
            contactRenderer.scale = 2
            let contact = NSBitmapImageRep(cgImage: contactRenderer.cgImage!)
            let contactURL = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("cord-fish-hook-contact-2x.png")
            try contact.representation(using: .png, properties: [:])!.write(to: contactURL)
        }
        for background in [0.0, 0.5, 1.0] {
            for stage in fishStages {
                for scale in [CGFloat(1), 2] {
                    let renderer = ImageRenderer(content: CodexPullCordArtwork(stretch: 0, isOpen: false,
                        style: .fish, count: 1, glow: 0, fishStage: stage)
                        .background(Color(white: background)))
                    renderer.scale = scale
                    let bitmap = NSBitmapImageRep(cgImage: renderer.cgImage!)
                    let backdrop = bitmap.colorAt(x: 0, y: 0)!.usingColorSpace(.deviceRGB)!.redComponent
                    // Check short contour segments: individual antialiased junction pixels can blend into mid-gray.
                    for row in Array(stride(from: 5, to: 33, by: 3)) + Array(stride(from: 38, to: 65, by: 3)) {
                        var contrast: CGFloat = 0
                        for y in Int(CGFloat(row) * scale)..<Int(CGFloat(row + 3) * scale) {
                            for x in Int(24 * scale)..<Int(40 * scale) {
                                let color = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                                contrast = max(contrast, abs(color.redComponent - backdrop))
                            }
                        }
                        assert(contrast > (background == 0.5 ? 0.10 : 0.18), "Fish/cord disappears on background \(background), stage \(stage), row \(row), scale \(scale), contrast \(contrast)")
                    }
                }
            }
        }
        // Mount the real button so task cancellation and retained exit drawing are exercised.
        let live = FishMotionFixture()
        let host = NSHostingView(rootView: FishMotionFixtureView(state: live))
        panel.setContentSize(NSSize(width: 64, height: 82))
        panel.contentView = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.orderFrontRegardless()
        func brightPixels(_ name: String) throws -> Int {
            host.layoutSubtreeIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if CommandLine.arguments.count > 1 {
                try bitmap.representation(using: .png, properties: [:])!.write(to:
                    URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("live-fish-\(name).png"))
            }
            if name == "reeling" {
                let scale = CGFloat(bitmap.pixelsWide) / 64
                let y = Int(10 * scale)
                let lineVisible = (Int(30 * scale)...Int(34 * scale)).contains { x in
                    let color = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                    return color.alphaComponent > 0.2 && color.redComponent > 0.6
                }
                assert(lineVisible, "The cord must shorten with the fish instead of snapping to its final length")
            }
            var bright = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    let color = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                    if color.alphaComponent > 0.2 && color.redComponent > 0.6 { bright += 1 }
                }
            }
            return bright
        }
        try await Task.sleep(for: .milliseconds(1800))
        assert(try! brightPixels("visible") > 10, "The live fish must appear")
        live.waiting = false
        try await Task.sleep(for: .milliseconds(160))
        assert(try! brightPixels("reeling") > 10, "Queue completion must retain the fish while reeling")
        try await Task.sleep(for: .milliseconds(650))
        assert(try! brightPixels("gone") == 0, "The live fish must disappear after retraction")
        live.waiting = true; live.since = .now
        try await Task.sleep(for: .milliseconds(250))
        live.waiting = false
        try await Task.sleep(for: .milliseconds(120))
        live.waiting = true; live.since = .now
        try await Task.sleep(for: .milliseconds(850))
        assert(try! brightPixels("reversed") > 10, "A cancelled exit must not hide a new request")
        live.isOpen = true
        try await Task.sleep(for: .milliseconds(100))
        assert(try! brightPixels("card-open") > 10, "Opening the card must not retract the fish")
        NotchMotionEnvironment.shared.suspended = true; live.waiting = false
        try await Task.sleep(for: .milliseconds(120))
        assert(try! brightPixels("suspended") == 0, "Suspending must skip the reeling animation")
        panel.orderOut(nil)
        print("PASS: nine styles, flipped anchors, 1x/2x idle/tug/glow bounds, donut hole, badges, four stages, light/dark contrast, bidirectional tail, one-shot catch lifecycle, splash bounds and full upward retraction")
    }
}
