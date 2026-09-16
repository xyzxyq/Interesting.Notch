import SwiftUI
import AppKit

@main @MainActor struct CodexNotchChecks {
    static func main() throws {
        let activeQuestion = try JSONDecoder().decode(CodexTask.self, from: Data(#"{"id":"11111111-1111-1111-1111-111111111111","title":"test","state":"waiting","isRunning":true}"#.utf8))
        assert(activeQuestion.waiting && activeQuestion.working)
        var blockedQuestion = activeQuestion
        blockedQuestion.isRunning = false
        assert(blockedQuestion.waiting && !blockedQuestion.working)
        assert(CodexActivity.shouldShowRocket(enabled: true, running: true))
        assert(CodexActivity.shouldShowRocket(enabled: true, running: activeQuestion.working))
        assert(!CodexActivity.shouldShowRocket(enabled: true, running: false))
        assert(!CodexActivity.shouldShowRocket(enabled: false, running: true))
        let runningTask = CodexTask(id: activeQuestion.id, title: "test", state: "running", detail: nil)
        assert(CodexActivity.didFinishWork(previous: [runningTask], current: [], confirmedIdle: [runningTask.identity], continuousConnection: true))
        assert(!CodexActivity.didFinishWork(previous: [runningTask], current: [activeQuestion], confirmedIdle: [runningTask.identity], continuousConnection: true))
        assert(CodexActivity.didFinishWork(previous: [activeQuestion], current: [], confirmedIdle: [runningTask.identity], continuousConnection: true))
        assert(CodexActivity.didFinishWork(previous: [activeQuestion], current: [blockedQuestion], confirmedIdle: [runningTask.identity], continuousConnection: true))
        assert(!CodexActivity.didFinishWork(previous: [activeQuestion], current: [blockedQuestion], confirmedIdle: [], continuousConnection: true))
        assert(!CodexActivity.didFinishWork(previous: [blockedQuestion], current: [blockedQuestion], confirmedIdle: [runningTask.identity], continuousConnection: true))
        assert(!CodexActivity.didFinishWork(previous: [runningTask], current: [], confirmedIdle: [runningTask.identity], continuousConnection: false))
        assert(!CodexActivity.didFinishWork(previous: [], current: [], confirmedIdle: [runningTask.identity], continuousConnection: true))
        assert(!CodexActivity.didFinishWork(previous: [runningTask, blockedQuestion], current: [runningTask], confirmedIdle: [runningTask.identity], continuousConnection: true))
        assert(!CodexActivity.didFinishWork(previous: [runningTask], current: [], confirmedIdle: [], continuousConnection: true))
        assert(CodexCompletionCue.flameOutDuration > 0 && CodexCompletionCue.ribbonDuration > 0)
        assert(CodexCompletionCue.ribbonDuration == 1.5)
        for index in 0..<CodexCompletionCue.particleCount {
            assert(CodexCompletionCue.particle(index, at: -0.1).opacity == 0)
            assert(CodexCompletionCue.particle(index, at: 0).opacity == 0)
            assert(CodexCompletionCue.particle(index, at: 0.4).opacity > 0.9)
            assert(CodexCompletionCue.particle(index, at: 1.5).opacity == 0)
            var previousX = 0.0
            for elapsed in stride(from: 0.0, through: 1.5, by: 0.025) {
                let piece = CodexCompletionCue.particle(index, at: elapsed)
                assert(piece.position.x.isFinite && piece.position.y.isFinite)
                assert((0...1).contains(piece.opacity))
                assert(piece.position.x >= -1 && piece.position.x < 186)
                assert(piece.position.y > -12 && piece.position.y < 226)
                assert(abs(piece.position.x - previousX) < 10)
                previousX = piece.position.x
            }
        }

        assert(CodexMergeMotion.scale(for: 1) == 1)
        assert(CodexMergeMotion.scale(for: 2) > CodexMergeMotion.scale(for: 1))
        assert(CodexMergeMotion.scale(for: 3) > CodexMergeMotion.scale(for: 2))
        assert(CodexMergeMotion.scale(for: 100) <= 1.7)
        assert(CodexMergeMotion.absorbed(at: 0) == 0)
        assert(CodexMergeMotion.absorbed(at: CodexMergeMotion.duration) == 1)
        assert(CodexMergeMotion.sample(at: 0).radius == 0)
        assert(CodexMergeMotion.sample(at: CodexMergeMotion.duration).radius == 0)
        assert(abs(CodexMergeMotion.sample(at: CodexMergeMotion.duration).pulse) < 0.0001)
        var lastTravel: CGFloat = 0
        for t in stride(from: 0.0, through: CodexMergeMotion.duration, by: 0.01) {
            let merge = CodexMergeMotion.sample(at: t)
            assert(merge.travel >= lastTravel && merge.travel <= 1)
            assert(merge.radius >= 0 && merge.radius <= 7 && abs(merge.pulse) <= 0.1)
            lastTravel = merge.travel
        }
        assert(CodexActivity.shouldDismissRequests(enabled: true, preview: nil, connected: true, pendingCount: 0))
        assert(!CodexActivity.shouldDismissRequests(enabled: true, preview: nil, connected: true, pendingCount: 1))
        assert(!CodexActivity.shouldDismissRequests(enabled: true, preview: nil, connected: false, pendingCount: 0))
        assert(!CodexActivity.shouldDismissRequests(enabled: true, preview: "waiting", connected: true, pendingCount: 0))
        assert(CodexActivity.shouldDismissRequests(enabled: true, preview: "running", connected: false, pendingCount: 0))
        assert(CodexActivity.shouldDismissRequests(enabled: false, preview: nil, connected: false, pendingCount: 1))
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
        var multiQuestion = task
        multiQuestion.pendingQuestionIds = ["question-a", "question-b"]
        let reminders = CodexActivity.reminders(in: [multiQuestion])
        assert(reminders.count == 2 && reminders[0].identity != reminders[1].identity)
        let seen: Set<String> = [reminders[0].identity]
        assert(CodexActivity.unread(reminders, excluding: seen).count == 1)
        assert(CodexActivity.unread(reminders, excluding: Set(reminders.map(\.identity))).isEmpty)
        assert(CodexActivity.unread(reminders, excluding: seen).first?.identity == reminders[1].identity)
        // Deleting one reminder must not hide another host or a new question in the same task.
        var remoteReminder = reminders[0]
        remoteReminder.hostId = "remote"
        var nextReminder = reminders[0]
        nextReminder.requestId = "question-new"
        assert(CodexActivity.unread([reminders[0], reminders[1], remoteReminder, nextReminder], excluding: seen)
            .map(\.identity) == [reminders[1], remoteReminder, nextReminder].map(\.identity))
        multiQuestion.pendingQuestionIds = ["question-b"]
        assert(CodexActivity.reminders(in: [multiQuestion]).count == 1)
        var stability = CodexTaskStability()
        let base = Date(timeIntervalSince1970: 100)
        assert(stability.update([task], at: base) == [task])
        assert(stability.update([], at: base.addingTimeInterval(1)) == [task])
        let resumed = CodexTask(id: id, title: "Codex task", state: "running", detail: nil)
        assert(stability.update([resumed], at: base.addingTimeInterval(1.5)) == [task])
        assert(stability.update([resumed], at: base.addingTimeInterval(2)) == [resumed])
        assert(stability.update([], at: base.addingTimeInterval(4)) == [])
        assert(stability.update([resumed, task], at: base.addingTimeInterval(5)) == [task])
        stability.reset()
        assert(stability.update([], at: base.addingTimeInterval(5.1)) == [])
        var phase = MusicEdgePhase()
        phase.update(target: 0.4, paused: false, at: base)
        assert(abs(phase.value(at: base.addingTimeInterval(2)) - 0.8) < 0.0001)
        phase.update(target: 1, paused: false, at: base.addingTimeInterval(2))
        assert(abs(phase.value(at: base.addingTimeInterval(2)) - 0.8) < 0.0001)
        phase.update(target: 1, paused: true, at: base.addingTimeInterval(3))
        let frozen = phase.value(at: base.addingTimeInterval(3))
        assert(phase.value(at: base.addingTimeInterval(300)) == frozen)
        phase.update(target: 1, paused: false, at: base.addingTimeInterval(300))
        assert(phase.value(at: base.addingTimeInterval(300)) == frozen)
        assert(abs(CodexDropMotion.reminder(at: 120).offset) < 0.001)
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
        let fallDuration = fall.reduce(0) { $0 + $1.duration }
        for t in stride(from: 0.0, through: fallDuration, by: 0.01) {
            let forward = CodexDropMotion.sample(fall, initial: .init(progress: 0, surface: 0, duration: 0), time: fallDuration - t)
            let reverse = CodexDropMotion.sample(CodexDropMotion.returning, initial: .init(progress: 1, surface: 0, duration: 0), time: t)
            assert(abs(forward.progress - reverse.progress) < 0.00001)
            assert(abs(forward.surface - reverse.surface) < 0.00001)
        }
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
        let nozzle = rect.minX + NotchShape.rocketCoordinate(rect.width + rect.height * 0.182, width: rect.width, height: rect.height)
        assert(rocket.contains(CGPoint(x: nozzle - 0.5, y: rect.midY)))
        assert(!rocket.contains(CGPoint(x: nozzle + 0.5, y: rect.midY)))
        for x in stride(from: rect.maxX - 12, to: rect.maxX, by: 0.5) {
            for y in stride(from: 0.3, to: rect.height / 2, by: 0.7) {
                assert(rocket.contains(CGPoint(x: x, y: rect.minY + y)) == rocket.contains(CGPoint(x: x, y: rect.maxY - y)))
            }
        }
        // Keep a tapered nose with only a small rounding at the tip.
        assert(rocket.contains(CGPoint(x: rect.minX + 2, y: rect.midY - 2)))
        assert(rocket.contains(CGPoint(x: rect.minX + 2, y: rect.midY + 2)))
        assert(!rocket.contains(CGPoint(x: rect.minX + 1, y: rect.midY - 6)))
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
        let mergeFrames = HStack(spacing: 30) {
            ForEach([0.0, 0.25, 0.45, 0.6, 0.85], id: \.self) { time in
                VStack(spacing: 0) {
                    NotchShape().fill(.black).frame(width: 100, height: 25)
                    CodexLiquidDrop(progress: 1, mergeElapsed: time, volumeScale: CodexMergeMotion.scale(for: 1 + CodexMergeMotion.absorbed(at: time)))
                    Text(String(format: "%.2f s", time)).font(.caption)
                }
            }
        }.padding(24).background(Color.gray)
        let mergeRenderer = ImageRenderer(content: mergeFrames)
        mergeRenderer.scale = 2
        guard let mergeImage = mergeRenderer.cgImage else { fatalError("merge render failed") }
        try NSBitmapImageRep(cgImage: mergeImage).representation(using: .png, properties: [:])!
            .write(to: URL(fileURLWithPath: "/tmp/codex-merge-preview.png"))
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
                    .overlay { CodexRocketSurface(shape: NotchShape(rocket: progress)) }
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
