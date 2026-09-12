import SwiftUI
import AppKit

@main @MainActor struct CodexNotchChecks {
    static func main() throws {
        assert(CodexActivity.modelLabel("gpt-5.6-luna", effort: "medium") == "5.6-Luna mid")
        assert(CodexActivity.modelLabel("gpt-5.6-terra", effort: "medium") == "5.6-Terra mid")
        assert(CodexActivity.modelLabel("gpt-5.6-sol", effort: "high") == "5.6-Sol high")
        assert(CodexActivity.modelLabel("gpt-6-astra", effort: "ultra") == "Astra ultra")
        assert(CodexActivity.modelLabel("gpt-5.5", effort: "medium") == "5.5 mid")
        let fuel = CodexFuel(remainingPercent: 13, windowMinutes: 10080, resetsAt: 1000, updatedAt: 100)
        assert(fuel.valid(at: Date(timeIntervalSince1970: 110)))
        assert(!fuel.valid(at: Date(timeIntervalSince1970: 251)))
        assert(!fuel.valid(at: Date(timeIntervalSince1970: 90)))
        assert(!CodexFuel(remainingPercent: .nan, windowMinutes: 300, resetsAt: 1000, updatedAt: 100).valid(at: Date(timeIntervalSince1970: 110)))
        assert(!CodexFuel(remainingPercent: 50, windowMinutes: 60, resetsAt: 1000, updatedAt: 100).valid(at: Date(timeIntervalSince1970: 110)))
        let id = "01a09362-3f79-7bf3-ba10-7a8bd1c1c2d7"
        let task = CodexTask(id: id, title: "Codex task", state: "waiting", detail: nil)
        assert(task.waiting && task.url?.absoluteString == "codex://threads/\(id)")
        assert(CodexTask(id: "../settings?x=1", title: "", state: "running", detail: nil).url == nil)
        assert(CodexThrust.levels.count == 6)
        for level in 1..<6 {
            assert(CodexThrust.length(level) > CodexThrust.length(level - 1))
            assert(CodexThrust.speed(level) > CodexThrust.speed(level - 1))
        }
        let wakeRect = CGRect(x: 48, y: 48, width: 280, height: 32)
        for lane in 0..<5 {
            for side in [-1.0, 1.0] {
                let start = CodexThrust.wakePoint(0, lane: lane, side: side, rect: wakeRect)
                assert(start == CGPoint(x: wakeRect.minX, y: wakeRect.midY))
                var lastX = start.x
                for t in stride(from: 0.0, through: 1, by: 0.01) {
                    let point = CodexThrust.wakePoint(t, lane: lane, side: side, rect: wakeRect)
                    assert(point.x >= wakeRect.minX && point.x >= lastX)
                    assert((point.y - wakeRect.midY) * side >= 0)
                    lastX = point.x
                }
            }
        }
        let running = CodexTask(id: "running", title: "", state: "running", detail: nil, reasoningEffort: "ultra", model: "gpt-6-astra")
        assert(CodexActivity.headerTask(in: [running, task])?.id == task.id)
        assert(CodexActivity.headerTask(in: [running])?.model == "gpt-6-astra")
        assert(CodexActivity.headerTask(in: []) == nil)
        let now = Date(timeIntervalSince1970: 100)
        assert(CodexSnapshot(connected: true, tasks: [task], updatedAt: 98).fresh(at: now))
        assert(!CodexSnapshot(connected: true, tasks: [], updatedAt: 50).fresh(at: now))
        assert(!CodexSnapshot(connected: true, tasks: [], updatedAt: 120).fresh(at: now))
        assert(!CodexSnapshot(connected: true, tasks: [], updatedAt: .nan).fresh(at: now))
        assert(CodexDropMotion.reminder(at: 0).offset == 0)
        assert(CodexDropMotion.reminder(at: 0).brightness == 1)
        for t in stride(from: 0.0, through: 36, by: 0.03) {
            let sample = CodexDropMotion.reminder(at: t)
            assert(sample.offset >= -3.001 && sample.offset <= 0.001)
            assert(sample.brightness >= 0.439 && sample.brightness <= 1.001)
        }
        assert(abs(CodexDropMotion.reminder(at: 3.6).offset) < 0.001)
        assert(abs(CodexDropMotion.reminder(at: 2.8).brightness - 1) < 0.001)
        let fall = CodexDropMotion.fall
        let rebounds = (1..<(fall.count - 1)).filter {
            fall[$0].progress < fall[$0 - 1].progress && fall[$0].progress < fall[$0 + 1].progress
        }
        assert(rebounds.count == 2)
        assert(fall[rebounds[0]].progress < fall[rebounds[1]].progress)
        assert(fall.last!.progress == 1 && fall.last!.surface == 0)
        assert(CodexDropMotion.returning.last!.progress == 0 && CodexDropMotion.returning.last!.surface == 0)
        let origin = CodexDropMotion.Frame(progress: 0, surface: 0, duration: 0)
        var boundary = 0.0
        for frame in fall.dropLast() {
            boundary += frame.duration
            let epsilon = 0.0001
            let left = CodexDropMotion.sample(fall, initial: origin, time: boundary - epsilon)
            let center = CodexDropMotion.sample(fall, initial: origin, time: boundary)
            let right = CodexDropMotion.sample(fall, initial: origin, time: boundary + epsilon)
            let v1 = (center.progress - left.progress) / epsilon
            let v2 = (right.progress - center.progress) / epsilon
            assert(abs(v1 - v2) < 0.03, "Velocity must remain continuous across keyframes")
        }
        let before = CodexDropMotion.sample(fall, initial: origin, time: 0.239)
        let after = CodexDropMotion.sample(fall, initial: origin, time: 0.241)
        assert((after.progress - before.progress) / 0.002 > 1, "Descent must not pause at stretch node")
        let liquidRect = CGRect(x: 0, y: 0, width: 280, height: 32)
        let liquid = NotchShape(liquid: 8).path(in: liquidRect)
        assert(liquid.contains(CGPoint(x: 140, y: 38)))
        assert(!NotchShape().path(in: liquidRect).contains(CGPoint(x: 140, y: 38)))
        assert(liquid.contains(CGPoint(x: 140, y: 30)))
        let rect = CGRect(x: 100, y: 30, width: 260, height: 32)
        for i in 0...20 {
            let shape = NotchShape(rocket: CGFloat(i) / 20)
            let path = shape.path(in: rect)
            assert(path.contains(CGPoint(x: rect.midX, y: rect.midY)))
            assert(path.boundingRect.minX.isFinite)
            assert(path.boundingRect.width < 310)
        }
        let rocket = NotchShape(rocket: 1).path(in: rect)
        assert(abs(rocket.boundingRect.minX - rect.minX) < 0.01)
        assert(abs(rocket.boundingRect.maxX - rect.maxX) < 0.01)
        assert(abs(rocket.boundingRect.width - rect.width) < 0.01)
        let noseEnd = rect.minX + NotchShape.rocketCoordinate(0, width: rect.width, height: rect.height)
        for x in stride(from: rect.minX + 0.3, to: noseEnd, by: 0.7) {
            for y in stride(from: 0.3, to: rect.height / 2, by: 0.7) {
                assert(rocket.contains(CGPoint(x: x, y: rect.minY + y)) == rocket.contains(CGPoint(x: x, y: rect.maxY - y)))
            }
        }
        // The central hardware area remains opaque at every step of the morph.
        for i in 0...10 {
            let path = NotchShape(rocket: CGFloat(i) / 10).path(in: rect)
            for x in stride(from: 125.0, through: 335.0, by: 10) {
                for y in stride(from: 32.0, through: 59.0, by: 3) { assert(path.contains(CGPoint(x: x, y: y))) }
            }
        }
        let view = VStack(spacing: 48) {
            specimen(progress: 0, label: "普通刘海 · 音乐水波")
            specimen(progress: 0.5, label: "轮廓过渡 · 50%")
            specimen(progress: 1, label: "高 · 速度参照线", effort: 2)
            specimen(progress: 1, label: "Ultra · 更快参照线与更大尾焰", effort: 5)
            HStack(spacing: 54) {
                ForEach([0.25, 0.55, 1.0], id: \.self) { t in
                    VStack(spacing: 0) {
                        NotchShape().fill(.black).frame(width: 140, height: 28)
                        CodexLiquidDrop(progress: t)
                    }
                }
            }
            Text("水滴拉伸 → 分离 → 等待点击（生产视图静态采样，非实际运行截图）")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(44).frame(width: 800).background(Color(red: 0.36, green: 0.44, blue: 0.51))
        let fuels = HStack(spacing: 24) {
            ForEach([85.0, 13.0, 5.0], id: \.self) { value in
                VStack {
                    CodexFuelGauge(fuel: CodexFuel(remainingPercent: value, windowMinutes: 10080, resetsAt: 1000, updatedAt: 100))
                        .frame(width: 22, height: 22)
                    Text("\(Int(value))%").foregroundStyle(.white)
                }
            }
            CodexFuelGauge(fuel: nil).frame(width: 22, height: 22)
        }.padding(24).background(.black)
        let fuelRenderer = ImageRenderer(content: fuels)
        fuelRenderer.scale = 3
        let fuelBitmap = NSBitmapImageRep(cgImage: fuelRenderer.cgImage!)
        try fuelBitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/codex-fuel-preview.png"))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage else { fatalError("render failed") }
        let bitmap = NSBitmapImageRep(cgImage: image)
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/codex-notch-preview.png"))
        print("Codex state freshness, navigation, hardware mask and contour checks passed; preview rendered")
    }
    static func specimen(progress: CGFloat, label: String, effort: Int = -1) -> some View {
        VStack(spacing: 24) {
            ZStack {
                NotchShape(rocket: progress).fill(.black)
                MusicEdgeFrame(shape: NotchShape(rocket: progress), style: "waterColor", strength: 1,
                               energy: 0.6, phase: 2.1, color: .white, reduced: false, sky: false)
                    .padding(-24 - 48 * progress)
                if progress == 1 {
                    CodexSpeedLines(shape: NotchShape(rocket: progress), effort: effort, active: true)
                    CodexFlame(active: true, effort: effort)
                }
            }.frame(width: 280, height: 32)
            Text(label).font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
        }
    }
}
