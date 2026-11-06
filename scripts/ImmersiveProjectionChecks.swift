import AppKit
import SwiftUI
import Metal
import ImageIO
import UniformTypeIdentifiers

@main @MainActor struct ImmersiveProjectionChecks {
    static func main() throws {
        if CommandLine.arguments.count > 1 {
            let folder = URL(fileURLWithPath: CommandLine.arguments[1])
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            freopen(folder.appendingPathComponent("checks.log").path, "w", stdout)
            freopen(folder.appendingPathComponent("checks.err").path, "w", stderr)
        }
        setbuf(stdout, nil)
        _ = NSApplication.shared
        guard let device = MTLCreateSystemDefaultDevice() else { fatalError("Metal device unavailable") }
        let library = try device.makeDefaultLibrary(bundle: .main)
        assert(library.functionNames.contains("immersiveLyricWave"))
        assert(library.functionNames.contains("immersiveProjector"))
        assert(library.functionNames.contains("immersiveParticleDissolve"))
        assert(library.functionNames.contains("immersiveLyricOutline"))
        print("Loaded projection shaders on \(device.name)")
        assert(ImmersiveLyricLine.measure("") == 0)
        for line in ["让这一刻，慢慢流淌", "a long English lyric", "🎵✨"] {
            let expected = (line as NSString).size(withAttributes: [
                .font: NSFont.systemFont(ofSize: 26, weight: .medium), .kern: 1]).width
            assert(ImmersiveLyricLine.measure(line) == expected)
            assert(ImmersiveLyricLine.measure(line) == expected, "Cached glyph width must preserve layout")
        }
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/tmp/immersive-projection")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        func content(text: String = "让这一刻，慢慢流淌") -> ImmersiveLyricsView {
            ImmersiveLyricsView(segments: [.init(id: 0, start: 0, end: 120, text: text)],
                position: 60, sampleDate: Date(), rate: 0,
                duration: 180, offset: 0,
                sourceWidth: 280)
        }
        func particleImage(text: String = "让这一刻，慢慢流淌", time: Double, progress: Double) -> CGImage {
            let view = ImmersiveLyricLine(text: text, dissolve: progress)
                .frame(width: 640, height: 66)
                .background(Color(red: 0.08, green: 0.13, blue: 0.17))
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            return renderer.cgImage!
        }
        var highlightCounts: [Int] = []
        for (name, progress) in [("particle-reading", -1.0), ("particle-breakup", 0.18),
                                  ("particle-drift", 0.55), ("particle-gone", 1.0)] {
            let bitmap = NSBitmapImageRep(cgImage: particleImage(time: 1, progress: progress))
            var highlights = 0
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
                for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                    if let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                       max(pixel.redComponent, pixel.greenComponent, pixel.blueComponent) > 0.4 { highlights += 1 }
                }
            }
            highlightCounts.append(highlights)
            try bitmap.representation(using: .png, properties: [:])!.write(
                to: output.appendingPathComponent("\(name).png"))
        }
        assert(highlightCounts[0] > 100 && highlightCounts[1] > 10 && highlightCounts[2] > 5,
               "Glyph-derived particles must remain visible while dispersing")
        assert(highlightCounts[3] == 0, "Finished particles must leave no stale glyph")
        let animationURL = output.appendingPathComponent("particle-flow.gif")
        let frameCount = 60
        guard let animation = CGImageDestinationCreateWithURL(animationURL as CFURL,
            UTType.gif.identifier as CFString, frameCount, nil) else { fatalError("Could not create animation") }
        CGImageDestinationSetProperties(animation, [kCGImagePropertyGIFDictionary:
            [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for frame in 0..<frameCount {
            let time = Double(frame) / 30
            let progress = time < 0.8 ? -1 : time < 1.2 ? (time - 0.8) / 0.4 : -1
            let line = time < 1.2 ? "让这一刻，慢慢流淌" : "让光沿着字迹，慢慢散开"
            CGImageDestinationAddImage(animation, particleImage(text: line, time: time, progress: progress),
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / 30]] as CFDictionary)
        }
        assert(CGImageDestinationFinalize(animation))
        print("Particle dissolve rendered: \(highlightCounts)")
        func projectorPreview(time: Double, progress: Double) -> CGImage {
            let line = "让这一刻，慢慢流淌"
            func scene(_ background: Color, busy: Bool = false) -> some View {
                ZStack(alignment: .top) {
                    if busy {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(0..<4) { _ in Text("工作区文档　项目说明与当前工作内容　阅读、编辑与专注") }
                        }.font(.system(size: 15)).foregroundStyle(.black.opacity(0.8))
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 18)
                    }
                    VStack(spacing: 0) {
                        UnevenRoundedRectangle(bottomLeadingRadius: 16, bottomTrailingRadius: 16)
                            .fill(.black).frame(width: 280, height: 30)
                        ZStack {
                            if progress < 1 {
                                ImmersiveProjectorBackdrop(sourceWidth: 280, time: time)
                                ImmersiveLyricLine(text: line, dissolve: progress, waveProgress: min(1, time / 3.2))
                            }
                        }.frame(width: 640, height: 66)
                    }
                }.frame(width: 640, height: 116, alignment: .top).background(background)
            }
            let view = VStack(spacing: 1) {
                HStack(spacing: 1) { scene(.white); scene(Color(white: 0.06)) }
                HStack(spacing: 1) { scene(Color(red: 0.18, green: 0.40, blue: 0.32)); scene(.white, busy: true) }
            }.background(Color.gray)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            return renderer.cgImage!
        }
        let preview = NSBitmapImageRep(cgImage: projectorPreview(time: 0, progress: -1))
        try preview.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("projector-document.png"))
        let previewURL = output.appendingPathComponent("projector-document-flow.gif")
        let projectorAnimation = CGImageDestinationCreateWithURL(previewURL as CFURL, UTType.gif.identifier as CFString, 120, nil)!
        CGImageDestinationSetProperties(projectorAnimation, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for frame in 0..<120 {
            let time = Double(frame) / 30
            let progress = time < 3.2 ? -1 : min(1, (time - 3.2) / 0.4)
            CGImageDestinationAddImage(projectorAnimation, projectorPreview(time: time, progress: progress),
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / 30]] as CFDictionary)
        }
        assert(CGImageDestinationFinalize(projectorAnimation))

        // A straight translucent line exposes extra crests and any painted, opaque wave band.
        func lensProbe(_ progress: Double) -> NSBitmapImageRep {
            let renderer = ImageRenderer(content: Rectangle().fill(.white.opacity(0.42))
                .frame(width: 640, height: 2).position(x: 320, y: 41)
                .frame(width: 640, height: 66)
                .layerEffect(ShaderLibrary.immersiveLyricWave(.float2(640, 66), .float(400),
                    .float(progress), .float(1)), maxSampleOffset: CGSize(width: 2, height: 4)))
            renderer.scale = 2
            return NSBitmapImageRep(cgImage: renderer.cgImage!)
        }
        let straight = lensProbe(-1), bent = lensProbe(0.5)
        var shifts: [Double] = []
        for x in 0..<bent.pixelsWide {
            var baseMass = 0.0, bentMass = 0.0, baseY = 0.0, bentY = 0.0
            for y in 0..<bent.pixelsHigh {
                let a = straight.colorAt(x: x, y: y)!.alphaComponent
                let b = bent.colorAt(x: x, y: y)!.alphaComponent
                baseMass += a; baseY += a * Double(y)
                bentMass += b; bentY += b * Double(y)
                assert(b <= 0.43, "The lens must preserve transparency, without painting an opaque band")
            }
            assert(bentMass > baseMass * 0.95, "Refraction must not erase the passing line")
            shifts.append(bentY / bentMass - baseY / baseMass)
        }
        let peak = shifts.max()!, peakIndex = shifts.firstIndex(of: peak)!
        assert(peak > 1 && peak < 4 && shifts.min()! > -0.08, "Expected one small crest without troughs")
        var crestCount = 0, insideCrest = false
        for x in shifts.indices {
            let raised = shifts[x] > peak * 0.15
            if raised && !insideCrest { crestCount += 1 }
            insideCrest = raised
            if x > 0 {
                assert(x <= peakIndex ? shifts[x] >= shifts[x - 1] - 0.05 : shifts[x] <= shifts[x - 1] + 0.05,
                       "The glass lens must have one crest, not repeated ripples")
            }
            if abs(x - 640) > 46 { assert(abs(shifts[x]) < 0.01, "Refraction escaped the narrowed lens") }
        }
        assert(crestCount == 1, "Each lyric must have exactly one traveling wave")
        let halfHeightWidth = Double(shifts.filter { $0 >= peak * 0.5 }.count) / 2
        assert((18...23).contains(halfHeightWidth), "Wave width must be half the previous approximately 41-point half-height width")
        print("Single transparent lens: one crest, peak displacement \(peak / 2) points, half-height width \(halfHeightWidth) points")

        func waveFrame(_ progress: Double, text: String = "让这一刻，慢慢流淌") -> NSBitmapImageRep {
            let renderer = ImageRenderer(content: ImmersiveLyricLine(text: text, dissolve: -1,
                waveProgress: progress).frame(width: 640, height: 66))
            renderer.scale = 2
            return NSBitmapImageRep(cgImage: renderer.cgImage!)
        }
        let resting = waveFrame(-1)
        let restingData = resting.representation(using: .png, properties: [:])!
        assert(waveFrame(0).representation(using: .png, properties: [:])! == restingData)
        assert(waveFrame(1).representation(using: .png, properties: [:])! == restingData,
               "After the wave passes, the full lyric must return unchanged")
        var waveCenters: [Double] = []
        for progress in [0.25, 0.5, 0.75] {
            let wave = waveFrame(progress)
            var delta = 0.0, weightedX = 0.0, baseMass = 0.0, waveMass = 0.0
            var baseLeft = 0.0, waveLeft = 0.0
            for y in stride(from: 0, to: wave.pixelsHigh, by: 2) {
                for x in stride(from: 0, to: wave.pixelsWide, by: 2) {
                    let base = resting.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
                    let pixel = wave.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
                    let difference = abs(base.alphaComponent - pixel.alphaComponent)
                        + abs(base.redComponent - pixel.redComponent) * max(base.alphaComponent, pixel.alphaComponent)
                    delta += difference; weightedX += difference * Double(x)
                    baseMass += base.alphaComponent; waveMass += pixel.alphaComponent
                    if x < 560 { baseLeft += base.alphaComponent; waveLeft += pixel.alphaComponent }
                }
            }
            assert(delta > 30, "Wave did not visibly refract the glyphs")
            assert(waveMass > baseMass * 0.90, "Wave erased part of the lyric")
            if progress == 0.75 {
                assert(abs(waveLeft - baseLeft) < baseLeft * 0.02, "Text behind the wave must remain")
            }
            waveCenters.append(weightedX / delta)
            try wave.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("wave-\(progress).png"))
        }
        assert(waveCenters[0] + 60 < waveCenters[1] && waveCenters[1] + 60 < waveCenters[2],
               "Wave must travel left to right: \(waveCenters)")
        let longWave = waveFrame(0.5, text: "Even a longer lyric stays complete while the wave moves from left to right")
        assert(longWave.pixelsWide == resting.pixelsWide && longWave.pixelsHigh == resting.pixelsHigh)
        print("Wave centers move left to right; no text erased: \(waveCenters)")

        let glassFill = ImmersiveProjectionFill.GlassView(frame: .zero)
        let glassShape = ImmersiveProjectionGlass(sourceWidth: 36, receiverWidth: 120)
        glassFill.setProjection(glassShape)
        assert(glassFill.blendingMode == .behindWindow && glassFill.state == .active,
               "The V interior must blend the desktop behind the nonactivating panel")
        let originalMask = glassFill.maskImage!
        let glassMask = NSBitmapImageRep(cgImage: originalMask.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
        func maskAlpha(x: CGFloat, y: CGFloat) -> CGFloat {
            glassMask.colorAt(x: Int(x * CGFloat(glassMask.pixelsWide) / originalMask.size.width),
                              y: Int(y * CGFloat(glassMask.pixelsHigh) / originalMask.size.height))!.alphaComponent
        }
        let interiorAlpha = [CGFloat(0), 2, 5, 9, 14].map { maskAlpha(x: 61, y: $0) }
        assert((0.4...0.55).contains(interiorAlpha[0]) && (0.1...0.25).contains(interiorAlpha[1])
               && interiorAlpha[2] > 0 && interiorAlpha[2] < 0.08
               && interiorAlpha[3] < 0.01 && interiorAlpha[4] < 0.01,
               "Interior must be lighter and fully fade by half height: \(interiorAlpha)")
        assert(maskAlpha(x: 20, y: 2) < 0.01,
               "Interior material escaped the V outline")
        glassFill.setProjection(glassShape)
        assert(glassFill.maskImage === originalMask, "Animation ticks must reuse the native fill mask")
        glassFill.setProjection(.init(sourceWidth: 24, receiverWidth: 80))
        assert(glassFill.maskImage!.size == CGSize(width: 82, height: 16), "Resized V retained a stale fill mask")
        print("Native V interior: behind-window material, descending alpha \(interiorAlpha), cached geometry")

        // Glass and edge highlights must leave the lyric row transparent.
        var projectorFrames: [Data] = []
        for time in [0.0, 4.0] {
            let scene = Color.white.frame(width: 640, height: 66)
                .colorEffect(ShaderLibrary.immersiveProjector(.float2(640, 16), .float(36), .float(120), .float(time)))
            let renderer = ImageRenderer(content: scene)
            renderer.scale = 2
            let bitmap = NSBitmapImageRep(cgImage: renderer.cgImage!)
            assert(bitmap.colorAt(x: 640, y: 82)!.alphaComponent < 0.01, "No backing is allowed under the lyrics")
            assert(bitmap.colorAt(x: 2, y: 82)!.alphaComponent < 0.01)
            let seam = (0..<16).map { bitmap.colorAt(x: 640, y: $0)!.usingColorSpace(.deviceRGB)! }
            let blackBackground = seam.map { $0.redComponent * $0.alphaComponent }
            assert(blackBackground[0] < 0.01 && seam[0].alphaComponent > 0.98,
                   "The seam must join the black island and cover the native glass rim")
            assert(blackBackground[1] < blackBackground[3] && blackBackground[3] < blackBackground[6]
                   && blackBackground[6] > 0.25 && blackBackground[14] < 0.04,
                   "The aperture must brighten gradually and fade back into glass")
            assert(zip(blackBackground, blackBackground.dropFirst()).allSatisfy { abs($0 - $1) < 0.12 },
                   "The aperture still contains a hard bright stripe")
            assert(bitmap.colorAt(x: 718, y: 16)!.alphaComponent > 0.15, "V-shaped glass edge missing")
            assert(bitmap.colorAt(x: 400, y: 16)!.alphaComponent < 0.01, "Light spread beyond the compact center")
            assert(bitmap.colorAt(x: 718, y: 40)!.alphaComponent < 0.01, "Light extends below its 16-point limit")
            let data = bitmap.representation(using: .png, properties: [:])!
            try data.write(to: output.appendingPathComponent("glass-edges-\(Int(time)).png"))
            projectorFrames.append(data)
        }
        assert(projectorFrames[0] != projectorFrames[1], "Edge reflections must move with their clock")
        // Inspect the seam separately: ImageRenderer cannot export the AppKit desktop glass.
        let seamCloseup = Color.white.frame(width: 120, height: 16)
            .colorEffect(ShaderLibrary.immersiveProjector(.float2(120, 16), .float(36), .float(120), .float(0)))
            .padding(.top, 8).background(.black)
            .scaleEffect(4).frame(width: 480, height: 96)
        let seamRenderer = ImageRenderer(content: seamCloseup)
        seamRenderer.scale = 2
        try NSBitmapImageRep(cgImage: seamRenderer.cgImage!).representation(using: .png, properties: [:])!
            .write(to: output.appendingPathComponent("seam-black-closeup.png"))
        for reduced in [false, true] {
            let renderer = ImageRenderer(content: ImmersiveProjectorBackdrop(sourceWidth: 280, time: 0, reducedTransparency: reduced).frame(width: 640, height: 66))
            renderer.scale = 2
            let bitmap = NSBitmapImageRep(cgImage: renderer.cgImage!)
            assert(bitmap.colorAt(x: 640, y: 82)!.alphaComponent < 0.01,
                   "System glass or accessibility fallback introduced a lyric backing")
        }

        func luminance(_ color: NSColor) -> Double {
            let c = color.usingColorSpace(.sRGB)!
            func linear(_ value: Double) -> Double { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent) + 0.0722 * linear(c.blueComponent)
        }
        let letterRenderer = ImageRenderer(content: ImmersiveLyricLine(text: "让这一刻，慢慢流淌", dissolve: -1)
            .frame(width: 640, height: 66))
        letterRenderer.scale = 2
        let letters = NSBitmapImageRep(cgImage: letterRenderer.cgImage!)
        var darkContour = 0, glassInk = 0, glassRim = 0, opaqueWhite = 0
        var maximumChroma = 0.0
        for y in 0..<letters.pixelsHigh {
            for x in 0..<letters.pixelsWide {
                let pixel = letters.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
                if pixel.alphaComponent > 0.7 && luminance(pixel) < 0.06 { darkContour += 1 }
                if (0.88...0.98).contains(pixel.alphaComponent) && luminance(pixel) > 0.85 { glassInk += 1 }
                if (0.94...0.98).contains(pixel.alphaComponent) && luminance(pixel) > 0.8 { glassRim += 1 }
                if pixel.alphaComponent > 0.98 && luminance(pixel) > 0.95 { opaqueWhite += 1 }
                if pixel.alphaComponent > 0.2 {
                    maximumChroma = max(maximumChroma,
                        max(pixel.redComponent, pixel.greenComponent, pixel.blueComponent)
                        - min(pixel.redComponent, pixel.greenComponent, pixel.blueComponent))
                }
            }
        }
        assert(darkContour > 200 && glassInk > 500 && glassRim > 100,
               "Restored glass letters need a readable near-opaque white fill, a reflective rim and a legible contour")
        assert(opaqueWhite == 0, "Glass letters must not return to opaque white")
        assert(maximumChroma < 0.015, "Neutral glass letters must not have a blue or colored cast")
        let accessible = ImageRenderer(content: Text("让这一刻，慢慢流淌")
            .font(.system(size: 26, weight: .medium)).foregroundStyle(.white)
            .frame(width: 640, height: 66)
            .layerEffect(ShaderLibrary.immersiveLyricOutline(.float(1)),
                         maxSampleOffset: CGSize(width: 1, height: 1)))
        accessible.scale = 2
        let solidLetters = NSBitmapImageRep(cgImage: accessible.cgImage!)
        var solidFill = 0
        for y in stride(from: 0, to: solidLetters.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: solidLetters.pixelsWide, by: 2) {
                let pixel = solidLetters.colorAt(x: x, y: y)!
                if pixel.alphaComponent > 0.99 && luminance(pixel) > 0.45 { solidFill += 1 }
            }
        }
        assert(solidFill > 500, "Reduce Transparency must restore opaque letter interiors")
        var contrastCounts: [Int] = []
        for background in [Color.white, .black, Color(white: 0.5), .yellow, .blue] {
            let renderer = ImageRenderer(content: ImmersiveLyricLine(text: "让这一刻，慢慢流淌", dissolve: -1)
                .frame(width: 640, height: 66).background(background))
            renderer.scale = 2
            let bitmap = NSBitmapImageRep(cgImage: renderer.cgImage!)
            let base = luminance(bitmap.colorAt(x: 0, y: 0)!)
            var visible = 0
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
                for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                    let value = luminance(bitmap.colorAt(x: x, y: y)!)
                    if (max(value, base) + 0.05) / (min(value, base) + 0.05) >= 3 { visible += 1 }
                }
            }
            assert(visible > 300, "No visible contour or ink on a test background")
            contrastCounts.append(visible)
        }
        print("Glass glyph samples: dark contour \(darkContour), transmissive fill \(glassInk), reflective rim \(glassRim), opaque white \(opaqueWhite); visible on five backgrounds: \(contrastCounts)")
        let view = content().frame(width: 640, height: 66)
            .background(Color(red: 0.08, green: 0.13, blue: 0.17))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = renderer.cgImage!
        let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
        assert(NSBitmapImageRep(cgImage: image).colorAt(x: 640, y: 4)!.redComponent > 0.4)
        try data.write(to: output.appendingPathComponent("particles.png"))
        let dust = NSBitmapImageRep(cgImage: particleImage(time: 1, progress: 0.35))
        var hueBins = Set<Int>()
        for y in 0..<dust.pixelsHigh {
            for x in 0..<dust.pixelsWide {
                let color = dust.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                if color.saturationComponent > 0.25 && color.brightnessComponent > 0.45 {
                    hueBins.insert(Int(color.hueComponent * 12))
                }
            }
        }
        assert(hueBins.count >= 8, "Particles must retain many independent colors through the outline shader")
        print("Colored particles retain \(hueBins.count) hue bins")
        for (name, line) in [("light", "你总是有办法轻易做到"), ("long", "Even a longer lyric stays on a single line close to the notch"), ("empty", "")] {
            let view = VStack(spacing: 0) {
                UnevenRoundedRectangle(bottomLeadingRadius: 16, bottomTrailingRadius: 16)
                    .fill(.black).frame(width: 280, height: 30)
                content(text: line).frame(width: 640, height: 66)
            }
            .frame(width: 680, height: 112, alignment: .top)
            .background(Color(white: 0.96))
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.cgImage,
                  let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                fatalError("Could not render compact layout")
            }
            assert(image.width == 1360 && image.height == 224)
            try data.write(to: output.appendingPathComponent("\(name).png"))
        }
        let parent = BoringNotchWindow(contentRect: NSRect(x: 100, y: 400, width: 788, height: 292),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let anchor = ImmersiveLyricsPanel.Anchor()
        parent.contentView = anchor
        anchor.presentation = ImmersiveLyricsPanel(visible: true, topInset: 35,
                                                   hideFromRecording: true, content: content())
        anchor.updatePanel()
        guard let panel = parent.childWindows?.first else { fatalError("Projection was not attached") }
        assert(panel.ignoresMouseEvents && !panel.canBecomeKey && !panel.canBecomeMain)
        assert(panel.sharingType == .none)
        assert(panel.frame.width <= 640 && panel.frame.height == 66, "Projection must stay compact")
        assert(abs(panel.frame.midX - parent.frame.midX) < 1)
        assert(abs(panel.frame.maxY - (parent.frame.maxY - 35)) < 1)
        anchor.updatePanel()
        assert(parent.childWindows?.count == 1, "Repeated updates created duplicate windows")
        anchor.presentation = ImmersiveLyricsPanel(visible: false, topInset: 35,
                                                   hideFromRecording: true, content: content())
        anchor.updatePanel()
        assert(parent.childWindows?.isEmpty ?? true)
        assert(!panel.isVisible && panel.contentView == nil, "Inactive mode kept its renderer alive")
        anchor.presentation = ImmersiveLyricsPanel(visible: true, topInset: 35,
                                                   hideFromRecording: false, content: content())
        anchor.updatePanel()
        assert(parent.childWindows?.first?.sharingType == .readOnly)
        anchor.removePanel()
        assert(parent.childWindows?.isEmpty ?? true)
        func focus(_ visible: Bool, allowed: Bool = true) {
            anchor.presentation = ImmersiveLyricsPanel(visible: visible, topInset: 35,
                hideFromRecording: true, focusEnabled: visible, allowsFocusTransition: allowed, content: content())
            anchor.updatePanel()
        }
        focus(true)
        let transitioning = parent.childWindows!.first!
        focus(false)
        assert(parent.childWindows?.first === transitioning, "Focus exit must remain attached while fading")
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        focus(true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        assert(parent.childWindows?.first === transitioning && transitioning.isVisible,
               "An interrupted exit must not remove the reopened projection")
        focus(false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.45))
        assert(parent.childWindows?.isEmpty ?? true, "Completed focus exit must release its renderer")
        focus(true)
        focus(false, allowed: false)
        assert(parent.childWindows?.isEmpty ?? true, "Lock/sleep visibility loss must remove projection immediately")
        assert(ImmersiveFocus.transitionDuration(enabled: true, reducedMotion: true) == 0.12)
        assert(ImmersiveFocus.transitionDuration(enabled: false, reducedMotion: false)
               < ImmersiveFocus.transitionDuration(enabled: true, reducedMotion: false))
        print("Focus entry/exit, interruption, immediate privacy teardown and reduced motion passed")
        print("Projection lifecycle, click-through, privacy and particle projection passed: \(output.path)")
    }
}
