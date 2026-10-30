import AppKit
import SwiftUI

enum CodexReminderStyle: String, CaseIterable, Identifiable {
    case droplet
    case pullCord

    var id: String { rawValue }
    var title: String { self == .droplet ? "水滴" : "拉绳开关" }
}

enum CodexPullCordStyle: String, CaseIterable, Identifiable {
    case classic, donut, orbit, crystal, jellyfish, ufo, moon, capsule, fish

    var id: String { rawValue }
    var title: String {
        switch self {
        case .classic: "经典灯钮"
        case .donut: "甜甜圈"
        case .orbit: "星环"
        case .crystal: "晶钻"
        case .jellyfish: "漂浮水母"
        case .ufo: "迷你飞碟"
        case .moon: "月亮摇篮"
        case .capsule: "幸运扭蛋"
        case .fish: "上鱼了"
        }
    }
    var lightColor: Color {
        switch self {
        case .classic: Color(red: 1, green: 0.83, blue: 0.48)
        case .donut: Color(red: 1, green: 0.50, blue: 0.61)
        case .orbit: Color(red: 0.43, green: 0.86, blue: 1)
        case .crystal: Color(red: 0.74, green: 0.65, blue: 1)
        case .jellyfish: Color(red: 0.48, green: 0.92, blue: 0.96)
        case .ufo: Color(red: 0.65, green: 1, blue: 0.62)
        case .moon: Color(red: 1, green: 0.82, blue: 0.42)
        case .capsule: Color(red: 1, green: 0.62, blue: 0.72)
        case .fish: Color(red: 1, green: 0.79, blue: 0.36)
        }
    }
}

enum CodexFishStage: CaseIterable {
    case lively, drying, dead, skeleton

    var startsAfter: TimeInterval {
        switch self {
        case .lively: 0
        case .drying: 120
        case .dead: 600
        case .skeleton: 1200
        }
    }
    var title: String {
        switch self {
        case .lively: "刚上钩"
        case .drying: "渐渐安静"
        case .dead: "等待过久"
        case .skeleton: "只剩鱼骨"
        }
    }
    var isAlive: Bool { self == .lively || self == .drying }
    static func at(elapsed: TimeInterval) -> Self {
        guard elapsed.isFinite else { return .lively }
        return allCases.last { $0.startsAfter <= elapsed } ?? .lively
    }
}

struct CodexFishCatchCue {
    private(set) var consumedSince: Date?

    mutating func consume(_ since: Date?, animated: Bool, now: Date = .now) -> Bool {
        guard let since, since != consumedSince else { return false }
        consumedSince = since
        let age = now.timeIntervalSince(since)
        return animated && age >= 0 && age < CodexFishStage.drying.startsAfter
    }
}

struct CodexPullCordButton: View {
    var waiting: Bool
    var expanded = false
    var count: Int
    var isOpen: Bool
    var style: CodexPullCordStyle = .classic
    var waitingSince: Date?
    var action: (CGPoint) -> Void

    @State private var anchorView = NSView(frame: .zero)
    @ObservedObject private var motion = NotchMotionEnvironment.shared
    @Environment(\.accessibilityReduceMotion) private var reduced
    @State private var onScreen = false
    @State private var hovered = false
    @State private var breath: CGFloat = 0
    @State private var tug: CGFloat = 0
    @State private var pullTask: Task<Void, Never>?
    @State private var fishStage = CodexFishStage.lively
    @State private var fishFlapping = true
    @State private var tailSwing: CGFloat = 0
    @State private var catchCue = CodexFishCatchCue()
    @State private var catching = false
    @State private var catchLift: CGFloat = 0
    @State private var catchProgress: CGFloat = 1
    @State private var retainingFish = false
    @State private var fishReel: CGFloat = 0
    @State private var fishRise: CGFloat = 0

    private var visible: Bool { waiting && !expanded }
    private var canMove: Bool { onScreen && visible && !reduced && !motion.suspended }
    private var breathing: Bool { canMove && !isOpen }
    private var fishAgingSince: Date? {
        onScreen && visible && style == .fish && !motion.suspended ? waitingSince : nil
    }
    private var sway: CGFloat { style == .fish && !fishStage.isAlive ? 0 : breath }

    var body: some View {
        Button {
            pull()
            action(Self.topAnchor(view: anchorView))
        } label: {
            CodexPullCordArtwork(stretch: sway + tug + catchLift, isOpen: isOpen, style: style,
                                 hovered: hovered, count: count, glow: breathing ? breath / 2 : 0,
                                 fishStage: fishStage, fishFlapping: breathing && fishFlapping,
                                 tailSwing: tailSwing, catching: catching, catchProgress: catchProgress,
                                 retraction: fishReel, rise: fishRise)
                .rotationEffect(.degrees(style == .fish ? 0 : Double(sway) * 0.35), anchor: .top)
                .frame(width: 64, height: 82, alignment: .top)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity((style == .fish ? retainingFish : visible) ? 1 : 0)
        .offset(y: style == .fish || visible || reduced ? 0 : -14)
        .animation(style == .fish ? nil : .easeInOut(duration: reduced ? 0.15 : 0.24), value: visible)
        .background(CodexDropAnchor(view: anchorView, identifier: "codex-cord-anchor"))
        .disabled(!visible || motion.suspended)
        .allowsHitTesting(visible && !motion.suspended)
        .accessibilityLabel("\(style.title)拉绳开关，Codex 有 \(count) 个请求需要你处理")
        .accessibilityValue((style == .fish ? fishStage.title + "，" : "") + (isOpen ? "已展开" : "已收起"))
        .accessibilityHint(isOpen ? "轻拉收起交互卡片" : "轻拉展开交互卡片")
        .accessibilityHidden(!visible)
        .help(isOpen ? "轻拉收起交互卡片" : "轻拉展开交互卡片")
        .onHover { hovered = $0 }
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false; hovered = false; retainingFish = false; stopMotion() }
        .onChange(of: canMove) { _, value in if !value { stopMotion() } }
        .task(id: [visible, style == .fish, reduced, motion.suspended]) {
            guard style == .fish else {
                retainingFish = false; fishReel = 0; fishRise = 0
                return
            }
            if visible {
                let reversing = retainingFish && !reduced && !motion.suspended
                retainingFish = true
                if reversing {
                    withAnimation(.easeOut(duration: 0.28)) { fishReel = 0; fishRise = 0 }
                } else {
                    var reset = Transaction(); reset.disablesAnimations = true
                    withTransaction(reset) { fishReel = 0; fishRise = 0 }
                }
                return
            }
            guard retainingFish else { return }
            guard !reduced && !motion.suspended else {
                retainingFish = false; fishReel = 1; fishRise = 36
                return
            }
            do {
                withAnimation(.easeInOut(duration: 0.36)) { fishReel = 1 }
                try await Task.sleep(for: .milliseconds(240))
                try Task.checkCancellation()
                withAnimation(.timingCurve(0.32, 0, 0.20, 1, duration: 0.42)) { fishRise = 36 }
                try await Task.sleep(for: .milliseconds(460))
                try Task.checkCancellation()
                retainingFish = false
            } catch { }
        }
        .task(id: fishAgingSince) {
            guard let since = fishAgingSince else { return }
            fishStage = .at(elapsed: Date.now.timeIntervalSince(since))
            do {
                for stage in CodexFishStage.allCases.dropFirst() {
                    let delay = since.addingTimeInterval(stage.startsAfter).timeIntervalSinceNow
                    if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
                    try Task.checkCancellation()
                    withAnimation(reduced ? nil : .easeInOut(duration: 0.8)) {
                        fishStage = .at(elapsed: Date.now.timeIntervalSince(since))
                    }
                }
            } catch { }
        }
        .task(id: canMove && !isOpen ? fishAgingSince : nil) {
            guard catchCue.consume(fishAgingSince, animated: canMove && !isOpen) else {
                resetCatch()
                return
            }
            var initial = Transaction(); initial.disablesAnimations = true
            withTransaction(initial) { catching = true; catchProgress = 0; catchLift = 7 }
            do {
                // Give the initial pose a display turn before the line pulls the fish upwards.
                try await Task.sleep(for: .milliseconds(80))
                try Task.checkCancellation()
                withAnimation(.linear(duration: 1.35)) { catchProgress = 1 }
                withAnimation(.spring(response: 0.45, dampingFraction: 0.76)) { catchLift = -4 }
                try await Task.sleep(for: .milliseconds(420))
                try Task.checkCancellation()
                withAnimation(.spring(response: 0.45, dampingFraction: 0.78)) { catchLift = 1.5 }
                try await Task.sleep(for: .milliseconds(420))
                try Task.checkCancellation()
                withAnimation(.easeOut(duration: 0.45)) { catchLift = 0 }
                try await Task.sleep(for: .milliseconds(550))
                try Task.checkCancellation()
                catching = false
            } catch { }
        }
        .task(id: breathing ? "\(style.rawValue):\(fishStage.isAlive)" : nil) {
            guard breathing else {
                var reset = Transaction(); reset.disablesAnimations = true
                withTransaction(reset) { breath = 0; tailSwing = 0 }
                return
            }
            do {
                while !Task.isCancelled {
                    withAnimation(.easeInOut(duration: 1.8)) { breath = 2 }
                    if style == .fish && fishStage.isAlive {
                        fishFlapping = true
                        for target in [CGFloat(0.9), -1, 1, -0.8, 0.55, 0] {
                            withAnimation(.easeInOut(duration: 0.3)) { tailSwing = target }
                            try await Task.sleep(for: .milliseconds(300))
                            try Task.checkCancellation()
                        }
                        fishFlapping = false
                    } else {
                        try await Task.sleep(for: .seconds(1.8))
                        try Task.checkCancellation()
                    }
                    withAnimation(.easeInOut(duration: 1.8)) { breath = 0 }
                    try await Task.sleep(for: .seconds(1.8))
                    try Task.checkCancellation()
                }
            } catch { }
        }
    }

    static func topAnchor(view: NSView) -> CGPoint {
        guard let window = view.window else { return NSEvent.mouseLocation }
        let bounds = window.convertToScreen(view.convert(view.bounds, to: nil))
        return CGPoint(x: bounds.midX, y: bounds.maxY)
    }

    private func pull() {
        pullTask?.cancel()
        guard canMove else { return }
        withAnimation(.easeOut(duration: 0.10)) { tug = 8 }
        pullTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(100))
                try Task.checkCancellation()
                withAnimation(.spring(response: 0.34, dampingFraction: 0.7)) { tug = 0 }
                try await Task.sleep(for: .milliseconds(420))
                try Task.checkCancellation()
                pullTask = nil
            } catch { }
        }
    }

    private func stopMotion() {
        pullTask?.cancel(); pullTask = nil
        var reset = Transaction(); reset.disablesAnimations = true
        withTransaction(reset) { breath = 0; tug = 0; tailSwing = 0 }
        resetCatch()
    }

    private func resetCatch() {
        var reset = Transaction(); reset.disablesAnimations = true
        withTransaction(reset) { catching = false; catchLift = 0; catchProgress = 1 }
    }
}

// Separate artwork lets boundary checks include the fully stretched pull without starting an idle task.
struct CodexPullCordArtwork: View {
    var stretch: CGFloat
    var isOpen: Bool
    var style: CodexPullCordStyle = .classic
    var hovered = false
    var count: Int
    var glow: CGFloat = 0
    var fishStage: CodexFishStage = .lively
    var fishFlapping = true
    var tailSwing: CGFloat = 0
    var catching = false
    var catchProgress: CGFloat = 1
    var retraction: CGFloat = 0
    var rise: CGFloat = 0

    private var light: CGFloat { isOpen ? 0.85 : 0.18 + 0.82 * min(1, max(0, glow)) }

    var body: some View {
        Group {
            if style == .fish {
                surface.offset(y: -rise).frame(width: 64, height: 82, alignment: .top).clipped()
            } else {
                surface
            }
        }
        .animation(.easeOut(duration: 0.16), value: hovered)
        .animation(.easeOut(duration: 0.18), value: isOpen)
    }

    private var surface: some View {
        let extendedLength = (style == .fish ? 36 : 38) + min(10, max(style == .fish ? -5 : 0, stretch))
        let length = extendedLength * (style == .fish ? 1 - min(1, max(0, retraction)) : 1)
        return ZStack(alignment: .top) {
            if style == .fish {
                CodexFishLine(length: length)
                    .fishStroke(LinearGradient(colors: [Color(white: 0.95), Color(white: 0.82)],
                                               startPoint: .top, endPoint: .bottom), width: 1.2)
                    .frame(width: 34, height: length + 3.5)
                Circle().fill(Color(white: 0.95))
                    .overlay { Circle().stroke(Color(white: 0.08).opacity(0.9), lineWidth: 0.6) }
                    .frame(width: 3.2, height: 3.2).offset(y: 0.3)
            } else {
                Capsule()
                    .fill(LinearGradient(colors: [Color(white: 0.74), Color(white: 0.25), Color(white: 0.57)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: 2, height: length + 2)
                    .overlay(alignment: .leading) {
                        Path { path in
                            path.move(to: CGPoint(x: 0.5, y: 1))
                            path.addLine(to: CGPoint(x: 0.5, y: length))
                        }.stroke(.white.opacity(0.6), style: StrokeStyle(lineWidth: 0.7, lineCap: .round, dash: [1, 2.5]))
                    }
                    .shadow(color: .black.opacity(0.24), radius: 0.7, x: 0.5, y: 0.5)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(LinearGradient(colors: [Color(white: 0.28), .black], startPoint: .top, endPoint: .bottom))
                    .frame(width: 9, height: 3)
                Circle()
                    .fill(RadialGradient(colors: [style.lightColor.opacity(0.46), style.lightColor.opacity(0.12), .clear],
                                         center: .center, startRadius: 0, endRadius: 19))
                    .frame(width: 38, height: 38)
                    .opacity(light)
                    .offset(y: length - 7)
            }
            handle
                .brightness(hovered ? 0.07 : 0)
                .shadow(color: .black.opacity(style == .fish ? 0 : 0.22), radius: 2, y: 2)
                .offset(y: length)
            if style == .fish && catching {
                CodexFishSplash(progress: catchProgress)
                    .frame(width: 64, height: 82)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            if count > 1 {
                Text(count > 99 ? "99+" : "\(count)").font(.system(size: 8, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(red: 0.98, green: 0.86, blue: 0.65))
                    .padding(.horizontal, 4).frame(minWidth: 14, minHeight: 14)
                    .background(Color(white: 0.12), in: Capsule())
                    .overlay { Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 0.5) }
                    .offset(x: 14, y: length - (style == .fish ? 16 : 3))
            }
        }
        .frame(width: 64, height: 82, alignment: .top)
    }

    @ViewBuilder private var handle: some View {
        switch style {
        case .classic: classic
        case .donut: donut
        case .orbit: orbit
        case .crystal: crystal
        case .jellyfish: jellyfish
        case .ufo: ufo
        case .moon: moon
        case .capsule: capsule
        case .fish: fish
        }
    }

    private var classic: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(LinearGradient(stops: [.init(color: Color(white: 0.32), location: 0),
                                            .init(color: Color(white: 0.11), location: 0.45),
                                            .init(color: Color(white: 0.035), location: 0.75),
                                            .init(color: Color(white: 0.16), location: 1)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.52), .white.opacity(0.045), .white.opacity(0.22)],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.7)
                }
                .overlay(alignment: .top) {
                    Capsule().fill(Color(red: 0.79, green: 0.69, blue: 0.48).opacity(0.85))
                        .frame(width: 10, height: 1.5).padding(.top, 3)
                }
                .overlay {
                    Capsule().fill(style.lightColor)
                        .frame(width: 3, height: 7)
                        .opacity(0.35 + 0.65 * light)
                }
                .frame(width: 18, height: 22)
    }

    private var donut: some View {
        ZStack {
            Circle().strokeBorder(LinearGradient(colors: [Color(red: 0.98, green: 0.77, blue: 0.43),
                Color(red: 0.62, green: 0.30, blue: 0.12), Color(red: 0.91, green: 0.57, blue: 0.27)],
                startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 8)
            CodexDonutIcing().fill(LinearGradient(colors: [Color(red: 1, green: 0.80, blue: 0.84),
                Color(red: 0.87, green: 0.36, blue: 0.52)], startPoint: .topLeading, endPoint: .bottomTrailing),
                style: FillStyle(eoFill: true))
            Circle().trim(from: 0.53, to: 0.84).stroke(.white.opacity(0.65), style: StrokeStyle(lineWidth: 0.8, lineCap: .round))
                .frame(width: 21, height: 21).offset(x: -0.4, y: -0.4)
            Circle().strokeBorder(Color(red: 0.43, green: 0.19, blue: 0.12).opacity(0.65), lineWidth: 0.7)
                .frame(width: 10, height: 10)
            Path { p in
                p.move(to: CGPoint(x: 8, y: 5)); p.addLine(to: CGPoint(x: 9.5, y: 6.1))
                p.move(to: CGPoint(x: 19, y: 14)); p.addLine(to: CGPoint(x: 21, y: 13.5))
                p.move(to: CGPoint(x: 9, y: 21)); p.addLine(to: CGPoint(x: 10.4, y: 19.7))
            }.stroke(Color(red: 1, green: 0.91, blue: 0.63), style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
            Path { p in
                p.move(to: CGPoint(x: 17, y: 5)); p.addLine(to: CGPoint(x: 18, y: 6.5))
                p.move(to: CGPoint(x: 5, y: 13)); p.addLine(to: CGPoint(x: 6.7, y: 14))
                p.move(to: CGPoint(x: 17, y: 21)); p.addLine(to: CGPoint(x: 18.5, y: 20))
            }.stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
            Circle().trim(from: 0.03, to: 0.45).stroke(style.lightColor, lineWidth: 1)
                .frame(width: 24, height: 24).opacity(light * 0.8)
        }
        .frame(width: 26, height: 26)
    }

    private var orbit: some View {
        ZStack {
            Capsule().fill(Color(white: 0.64)).frame(width: 2.5, height: 6).offset(y: -10)
            Ellipse().stroke(LinearGradient(colors: [Color(red: 0.97, green: 0.83, blue: 0.56),
                Color(red: 0.41, green: 0.47, blue: 0.55)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 2)
                .frame(width: 30, height: 10).rotationEffect(.degrees(-24))
            Circle().fill(RadialGradient(colors: [Color(red: 0.78, green: 0.94, blue: 0.98),
                Color(red: 0.25, green: 0.61, blue: 0.76), Color(red: 0.08, green: 0.20, blue: 0.39)],
                center: .topLeading, startRadius: 0, endRadius: 21))
                .overlay {
                    VStack(spacing: 3) {
                        Rectangle().fill(.white.opacity(0.17)).frame(height: 1)
                        Rectangle().fill(Color(red: 0.09, green: 0.34, blue: 0.48).opacity(0.3)).frame(height: 2)
                    }.rotationEffect(.degrees(-24)).clipShape(Circle())
                }
                .overlay { Circle().strokeBorder(.white.opacity(0.34), lineWidth: 0.6) }
                .frame(width: 19, height: 19)
            Ellipse().trim(from: 0, to: 0.5)
                .stroke(LinearGradient(colors: [Color(red: 1, green: 0.91, blue: 0.72), Color(red: 0.72, green: 0.57, blue: 0.36)],
                    startPoint: .leading, endPoint: .trailing), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                .frame(width: 30, height: 10).rotationEffect(.degrees(-24))
            Circle().fill(.white).frame(width: 2.4, height: 2.4)
                .overlay { Circle().fill(style.lightColor).frame(width: 5, height: 5).opacity(light * 0.6) }
                .offset(x: 11, y: -10).opacity(0.4 + light * 0.6)
        }
        .frame(width: 32, height: 26)
    }

    private var crystal: some View {
        ZStack {
            Path { p in
                p.move(to: CGPoint(x: 6, y: 0)); p.addLine(to: CGPoint(x: 16, y: 0))
                p.addLine(to: CGPoint(x: 22, y: 8)); p.addLine(to: CGPoint(x: 11, y: 26))
                p.addLine(to: CGPoint(x: 0, y: 8)); p.closeSubpath()
            }.fill(LinearGradient(colors: [Color(red: 0.87, green: 0.91, blue: 1),
                Color(red: 0.40, green: 0.35, blue: 0.76)], startPoint: .topLeading, endPoint: .bottomTrailing))
            Path { p in
                p.move(to: CGPoint(x: 6, y: 0)); p.addLine(to: CGPoint(x: 11, y: 9))
                p.addLine(to: CGPoint(x: 0, y: 8)); p.closeSubpath()
            }.fill(Color(red: 0.82, green: 0.95, blue: 1).opacity(0.85))
            Path { p in
                p.move(to: CGPoint(x: 16, y: 0)); p.addLine(to: CGPoint(x: 22, y: 8))
                p.addLine(to: CGPoint(x: 11, y: 9)); p.closeSubpath()
            }.fill(Color(red: 0.65, green: 0.54, blue: 0.91))
            Path { p in
                p.move(to: CGPoint(x: 0, y: 8)); p.addLine(to: CGPoint(x: 11, y: 9))
                p.addLine(to: CGPoint(x: 11, y: 26)); p.closeSubpath()
            }.fill(LinearGradient(colors: [.white.opacity(0.65), Color(red: 0.31, green: 0.63, blue: 0.83)],
                startPoint: .topLeading, endPoint: .bottomTrailing))
            Path { p in
                p.move(to: CGPoint(x: 6, y: 0)); p.addLine(to: CGPoint(x: 11, y: 9))
                p.addLine(to: CGPoint(x: 16, y: 0)); p.move(to: CGPoint(x: 0, y: 8))
                p.addLine(to: CGPoint(x: 11, y: 9)); p.addLine(to: CGPoint(x: 22, y: 8))
                p.move(to: CGPoint(x: 11, y: 9)); p.addLine(to: CGPoint(x: 11, y: 26))
            }.stroke(.white.opacity(0.42), style: StrokeStyle(lineWidth: 0.6, lineJoin: .round))
            Path { p in
                p.move(to: CGPoint(x: 6, y: 0.6)); p.addLine(to: CGPoint(x: 1, y: 8))
                p.addLine(to: CGPoint(x: 11, y: 24))
            }.stroke(.white.opacity(0.8), style: StrokeStyle(lineWidth: 0.8, lineCap: .round, lineJoin: .round))
            Circle().fill(.white).frame(width: 2, height: 2)
                .offset(x: -5, y: -10).opacity(0.25 + light * 0.75)
            Path { p in
                p.move(to: CGPoint(x: 11, y: 9)); p.addLine(to: CGPoint(x: 22, y: 8))
                p.addLine(to: CGPoint(x: 11, y: 26)); p.closeSubpath()
            }.fill(style.lightColor.opacity(light * 0.28))
        }
        .frame(width: 22, height: 26)
    }

    private var jellyfish: some View {
        let bell = Path { p in
            p.move(to: CGPoint(x: 1, y: 13))
            p.addCurve(to: CGPoint(x: 13, y: 1), control1: CGPoint(x: 1, y: 5), control2: CGPoint(x: 6, y: 1))
            p.addCurve(to: CGPoint(x: 25, y: 13), control1: CGPoint(x: 20, y: 1), control2: CGPoint(x: 25, y: 5))
            p.addCurve(to: CGPoint(x: 1, y: 13), control1: CGPoint(x: 19, y: 17), control2: CGPoint(x: 7, y: 17))
            p.closeSubpath()
        }
        return ZStack {
            Path { p in
                p.move(to: CGPoint(x: 6, y: 13))
                p.addCurve(to: CGPoint(x: 5, y: 25), control1: CGPoint(x: 0, y: 18), control2: CGPoint(x: 12, y: 21))
                p.move(to: CGPoint(x: 11, y: 14))
                p.addCurve(to: CGPoint(x: 10, y: 26), control1: CGPoint(x: 7, y: 20), control2: CGPoint(x: 14, y: 22))
                p.move(to: CGPoint(x: 16, y: 14))
                p.addCurve(to: CGPoint(x: 17, y: 26), control1: CGPoint(x: 21, y: 19), control2: CGPoint(x: 12, y: 23))
                p.move(to: CGPoint(x: 21, y: 13))
                p.addCurve(to: CGPoint(x: 22, y: 24), control1: CGPoint(x: 26, y: 18), control2: CGPoint(x: 17, y: 21))
            }.stroke(LinearGradient(colors: [Color(red: 0.77, green: 0.96, blue: 1), Color(red: 0.63, green: 0.48, blue: 0.97).opacity(0.7)],
                startPoint: .top, endPoint: .bottom), style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
            bell.fill(LinearGradient(colors: [Color(red: 0.82, green: 0.98, blue: 1).opacity(0.94),
                Color(red: 0.23, green: 0.66, blue: 0.80).opacity(0.78), Color(red: 0.51, green: 0.38, blue: 0.77).opacity(0.85)],
                startPoint: .topLeading, endPoint: .bottomTrailing))
            bell.stroke(.white.opacity(0.46), lineWidth: 0.6)
            Path { p in
                p.move(to: CGPoint(x: 10, y: 3)); p.addQuadCurve(to: CGPoint(x: 9, y: 13), control: CGPoint(x: 5, y: 8))
                p.move(to: CGPoint(x: 16, y: 3)); p.addQuadCurve(to: CGPoint(x: 17, y: 13), control: CGPoint(x: 21, y: 8))
            }.stroke(.white.opacity(0.27), style: StrokeStyle(lineWidth: 0.7, lineCap: .round))
            Ellipse().fill(style.lightColor).frame(width: 15, height: 3)
                .position(x: 13, y: 13.5).opacity(0.3 + light * 0.7)
            Ellipse().fill(.white.opacity(0.7)).frame(width: 6, height: 2)
                .rotationEffect(.degrees(-30)).position(x: 8, y: 5)
        }.frame(width: 26, height: 27)
    }

    private var ufo: some View {
        ZStack {
            Ellipse().fill(style.lightColor.opacity(light * 0.7)).frame(width: 11, height: 3).position(x: 15, y: 23)
            Ellipse().fill(LinearGradient(colors: [Color(white: 0.43), Color(white: 0.11)], startPoint: .top, endPoint: .bottom))
                .frame(width: 24, height: 9).position(x: 15, y: 18)
            Ellipse().fill(LinearGradient(colors: [Color(white: 0.88), Color(white: 0.48), Color(white: 0.20)],
                startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay { Ellipse().strokeBorder(.white.opacity(0.56), lineWidth: 0.7) }
                .frame(width: 30, height: 10).position(x: 15, y: 15.5)
            UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 3, bottomTrailingRadius: 3, topTrailingRadius: 10)
                .fill(LinearGradient(colors: [Color(red: 0.80, green: 1, blue: 0.91),
                    Color(red: 0.14, green: 0.48, blue: 0.43).opacity(0.85)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay {
                    UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 3, bottomTrailingRadius: 3, topTrailingRadius: 10)
                        .strokeBorder(.white.opacity(0.55), lineWidth: 0.6)
                }
                .frame(width: 18, height: 13).position(x: 15, y: 7.5)
            Ellipse().fill(.white.opacity(0.70)).frame(width: 6, height: 2.4)
                .rotationEffect(.degrees(-33)).position(x: 11, y: 5)
            HStack(spacing: 3) {
                ForEach(0..<5) { _ in Circle().fill(style.lightColor).frame(width: 2, height: 2) }
            }.opacity(0.4 + light * 0.6).position(x: 15, y: 18)
            Path { p in
                p.move(to: CGPoint(x: 4, y: 14)); p.addQuadCurve(to: CGPoint(x: 26, y: 14), control: CGPoint(x: 15, y: 19))
            }.stroke(.white.opacity(0.35), lineWidth: 0.6)
        }.frame(width: 30, height: 26)
    }

    private var moon: some View {
        let crescent = Path { p in
            p.move(to: CGPoint(x: 15, y: 1))
            p.addCurve(to: CGPoint(x: 14, y: 26), control1: CGPoint(x: -4, y: 1), control2: CGPoint(x: -1, y: 25))
            p.addCurve(to: CGPoint(x: 26, y: 14), control1: CGPoint(x: 21, y: 27), control2: CGPoint(x: 26, y: 21))
            p.addCurve(to: CGPoint(x: 15, y: 1), control1: CGPoint(x: 7, y: 23), control2: CGPoint(x: 5, y: 5))
            p.closeSubpath()
        }
        return ZStack {
            crescent.fill(LinearGradient(colors: [Color(red: 1, green: 0.94, blue: 0.68),
                Color(red: 0.80, green: 0.57, blue: 0.22), Color(red: 0.98, green: 0.80, blue: 0.41)],
                startPoint: .topLeading, endPoint: .bottomTrailing))
            crescent.stroke(LinearGradient(colors: [.white.opacity(0.9), Color(red: 0.63, green: 0.40, blue: 0.16)],
                startPoint: .topLeading, endPoint: .bottomTrailing), style: StrokeStyle(lineWidth: 0.6, lineJoin: .round))
            Path { p in
                p.move(to: CGPoint(x: 10, y: 3)); p.addCurve(to: CGPoint(x: 9, y: 23),
                    control1: CGPoint(x: 1, y: 6), control2: CGPoint(x: 2, y: 19))
            }.stroke(.white.opacity(0.5), style: StrokeStyle(lineWidth: 0.8, lineCap: .round))
            CodexCordStar().fill(LinearGradient(colors: [.white, Color(red: 1, green: 0.76, blue: 0.30)],
                startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay { CodexCordStar().stroke(.white.opacity(0.6), lineWidth: 0.5) }
                .frame(width: 10, height: 10).rotationEffect(.degrees(12)).position(x: 19, y: 10)
                .opacity(0.55 + light * 0.45)
        }.frame(width: 27, height: 27)
    }

    private var capsule: some View {
        ZStack {
            Capsule().fill(LinearGradient(colors: [Color(red: 0.79, green: 0.94, blue: 1).opacity(0.8),
                Color(red: 0.24, green: 0.51, blue: 0.69).opacity(0.65)], startPoint: .topLeading, endPoint: .bottomTrailing))
            CodexCordStar().fill(LinearGradient(colors: [Color(red: 1, green: 0.96, blue: 0.66),
                Color(red: 0.98, green: 0.65, blue: 0.23)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 10, height: 10).rotationEffect(.degrees(-15)).offset(x: 0.5, y: -1)
                .opacity(0.7 + light * 0.3)
            Capsule().fill(LinearGradient(colors: [Color(red: 1, green: 0.65, blue: 0.76).opacity(0.75),
                Color(red: 0.64, green: 0.22, blue: 0.44).opacity(0.9)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .mask(alignment: .bottom) { Rectangle().frame(height: 13) }
            Path { p in
                p.move(to: CGPoint(x: 0.5, y: 13)); p.addQuadCurve(to: CGPoint(x: 21.5, y: 13), control: CGPoint(x: 11, y: 16))
            }.stroke(.white.opacity(0.75), lineWidth: 0.7)
            Capsule().strokeBorder(LinearGradient(colors: [.white.opacity(0.8), .white.opacity(0.10), .white.opacity(0.4)],
                startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.7)
            Capsule().fill(.white.opacity(0.72)).frame(width: 2.5, height: 7)
                .rotationEffect(.degrees(25)).offset(x: -6, y: -6)
            Capsule().fill(style.lightColor).frame(width: 5, height: 1.5).offset(y: 9).opacity(0.4 + light * 0.6)
        }.frame(width: 22, height: 27).clipShape(Capsule())
    }

    private var fish: some View {
        let strength: CGFloat = fishStage == .lively ? 1 : fishStage == .drying ? 0.25 : 0
        let halo: CGFloat = (isOpen ? 0.51 : 0.108 + 0.842 * min(1, max(0, glow)))
            * (1 - min(1, max(0, retraction)))
        let ink = LinearGradient(colors: [Color(white: 0.98), Color(white: 0.88), Color(white: 0.96)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing)
        return ZStack(alignment: .topLeading) {
            CodexLineFishShape(tailShift: fishFlapping ? tailSwing * strength * 2.4 : 0,
                               skeleton: fishStage == .skeleton)
                .fishStroke(ink, halo: halo)
            if fishStage == .skeleton {
                Path { p in
                    p.move(to: CGPoint(x: 17, y: 9)); p.addLine(to: CGPoint(x: 17, y: 25))
                    for (y, width) in [(13.0, 5.0), (17, 4.3), (21, 3.3)] {
                        p.move(to: CGPoint(x: 17 - width, y: y))
                        p.addLine(to: CGPoint(x: 17 + width, y: y))
                    }
                }.fishStroke(ink, halo: halo)
            }
            fishEye.position(x: 18, y: fishStage == .skeleton ? 6.2 : 9)
            if fishStage.isAlive {
                Path { p in
                    for side in [CGFloat(-1), 1] {
                        p.move(to: CGPoint(x: 17 + side * 6.2, y: 24.5))
                        p.addQuadCurve(to: CGPoint(x: 17 + side * 6.7, y: 28), control: CGPoint(x: 17 + side * 7.4, y: 26))
                        p.move(to: CGPoint(x: 17 + side * 8.5, y: 23.5))
                        p.addQuadCurve(to: CGPoint(x: 17 + side * 9.3, y: 28), control: CGPoint(x: 17 + side * 10.2, y: 25.6))
                    }
                }.fishStroke(style.lightColor, width: 0.9)
                    .opacity((0.16 + glow * (fishFlapping ? 0.84 : 0.32)) * strength)
                Path { p in
                    p.move(to: CGPoint(x: 20.3, y: 12))
                    p.addQuadCurve(to: CGPoint(x: 20.3, y: 15), control: CGPoint(x: 19.4, y: 13.5))
                }.fishStroke(ink, width: 0.65)
                    .opacity(fishFlapping ? 0 : glow * strength * 0.6)
            }
        }.frame(width: 34, height: 32)
    }
    @ViewBuilder private var fishEye: some View {
        if fishStage == .dead {
            let cross = Path { p in
                p.move(to: CGPoint(x: 0.4, y: 0.4)); p.addLine(to: CGPoint(x: 2.2, y: 2.2))
                p.move(to: CGPoint(x: 2.2, y: 0.4)); p.addLine(to: CGPoint(x: 0.4, y: 2.2))
            }
            cross.stroke(Color(white: 0.10).opacity(0.85), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .overlay { cross.stroke(Color(white: 0.92), style: StrokeStyle(lineWidth: 0.75, lineCap: .round)) }
                .frame(width: 2.6, height: 2.6)
        } else if fishStage == .skeleton {
            Ellipse().fill(Color(white: 0.10))
                .overlay { Ellipse().stroke(Color(white: 0.88), lineWidth: 0.45) }
                .frame(width: 1.65, height: 1.9)
        } else {
            let quiet = fishStage == .drying
            let gazeX: CGFloat = hovered ? 0.03 : 0.08 + (quiet ? 0.10 : 0.45) * tailSwing
            let gazeY: CGFloat = quiet ? 0 : hovered ? -0.38 : -0.16 - 0.12 * glow
            Ellipse()
                .fill(LinearGradient(colors: [Color(white: 0.96), Color(white: 0.78)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay { Ellipse().stroke(Color(white: 0.10).opacity(0.9), lineWidth: 0.45) }
                .frame(width: 2.7, height: quiet ? 1.4 : 3)
                .overlay {
                    Ellipse().fill(Color(red: 0.055, green: 0.07, blue: 0.09))
                        .frame(width: 1.05, height: quiet ? 0.8 : 1.65)
                        .offset(x: gazeX, y: gazeY)
                    if !quiet {
                        Circle().fill(.white.opacity(0.85)).frame(width: 0.4, height: 0.4)
                            .offset(x: gazeX - 0.20, y: gazeY - 0.45)
                    }
                }
                .rotationEffect(.degrees(quiet ? 0 : -8 + Double(tailSwing) * 4))
        }
    }

}

struct CodexFishLine: Shape {
    var length: CGFloat
    var animatableData: CGFloat {
        get { length }
        set { length = newValue }
    }
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.midX, y: 1.5))
            p.addLine(to: CGPoint(x: rect.midX, y: length + 3.5))
        }
    }
}

// Six short ballistic droplets; this view exists only during the one-shot catch cue.
struct CodexFishSplash: View, Animatable {
    var progress: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let t = min(1, max(0, progress))
        let fade = sin(.pi * t)
        Path { p in
            for side in [CGFloat(-1), 1] {
                for index in 0..<3 {
                    let n = CGFloat(index)
                    let x = 32 + side * (5 + (9 + n * 4) * t)
                    let y = 68 - (26 + n * 4) * t + 23 * t * t
                    p.move(to: CGPoint(x: x, y: y))
                    p.addLine(to: CGPoint(x: x + side * (0.6 + n * 0.15), y: y + 2.5 - t))
                }
                p.move(to: CGPoint(x: 32 + side * (6 + 8 * t), y: 70))
                p.addQuadCurve(to: CGPoint(x: 32 + side * (11 + 10 * t), y: 70),
                               control: CGPoint(x: 32 + side * (9 + 9 * t), y: 71.5))
            }
        }
        .fishStroke(Color(red: 0.80, green: 0.92, blue: 1), width: 0.95)
        .opacity(fade * 0.95)
    }
}

private extension Shape {
    // A fixed dark keyline stays readable over light windows without sampling the desktop.
    func fishStroke<S: ShapeStyle>(_ ink: S, width: CGFloat = 1.5, halo: CGFloat? = nil) -> some View {
        stroke(Color(white: 0.08).opacity(0.9),
               style: StrokeStyle(lineWidth: width + 1.8, lineCap: .round, lineJoin: .round))
            .overlay {
                stroke(ink, style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
            }
            .background {
                if let halo {
                    stroke(Color(red: 1, green: 0.87, blue: 0.56),
                           style: StrokeStyle(lineWidth: width + 3.4, lineCap: .round, lineJoin: .round))
                    .blur(radius: 1)
                    .opacity(halo)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
    }
}

// Animate only the lower contour so the line stays seated in the mouth throughout a tug.
struct CodexLineFishShape: Shape {
    var tailShift: CGFloat
    var skeleton: Bool
    var animatableData: CGFloat {
        get { tailShift }
        set { tailShift = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 15.1, y: 1))
        p.addCurve(to: CGPoint(x: 18.9, y: 1), control1: CGPoint(x: 16, y: 4.4), control2: CGPoint(x: 18, y: 4.4))
        if skeleton {
            p.addQuadCurve(to: CGPoint(x: 21.7, y: 9), control: CGPoint(x: 22, y: 5))
            p.addLine(to: CGPoint(x: 12.3, y: 9))
            p.addQuadCurve(to: CGPoint(x: 15.1, y: 1), control: CGPoint(x: 12, y: 5))
            p.closeSubpath()
            p.move(to: CGPoint(x: 17, y: 25))
            p.addCurve(to: CGPoint(x: 13.4, y: 30), control1: CGPoint(x: 13, y: 25.5), control2: CGPoint(x: 12, y: 29.3))
            p.addQuadCurve(to: CGPoint(x: 17, y: 28), control: CGPoint(x: 15, y: 30.7))
            p.addQuadCurve(to: CGPoint(x: 20.6, y: 30), control: CGPoint(x: 19, y: 30.7))
            p.addCurve(to: CGPoint(x: 17, y: 25), control1: CGPoint(x: 22, y: 29.3), control2: CGPoint(x: 21, y: 25.5))
        } else {
            let dx = tailShift
            p.addCurve(to: CGPoint(x: 18.4 + dx * 0.35, y: 24), control1: CGPoint(x: 24.5, y: 10), control2: CGPoint(x: 22.8, y: 17))
            p.addCurve(to: CGPoint(x: 20.6 + dx, y: 30), control1: CGPoint(x: 21.7 + dx, y: 27), control2: CGPoint(x: 22.2 + dx, y: 29.6))
            p.addQuadCurve(to: CGPoint(x: 17 + dx, y: 27.6), control: CGPoint(x: 18.6 + dx, y: 31))
            p.addQuadCurve(to: CGPoint(x: 13.4 + dx, y: 30), control: CGPoint(x: 15.4 + dx, y: 31))
            p.addCurve(to: CGPoint(x: 15.6 + dx * 0.35, y: 24), control1: CGPoint(x: 11.8 + dx, y: 29.6), control2: CGPoint(x: 12.3 + dx, y: 27))
            p.addCurve(to: CGPoint(x: 15.1, y: 1), control1: CGPoint(x: 11.2, y: 17), control2: CGPoint(x: 9.5, y: 10))
        }
        p.closeSubpath()
        return p.applying(CGAffineTransform(scaleX: rect.width / 34, y: rect.height / 32)
            .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
    }
}

private struct CodexCordStar: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for index in 0..<10 {
            let angle = CGFloat(index) * .pi / 5 - .pi / 2
            let radius = min(rect.width, rect.height) * (index.isMultiple(of: 2) ? 0.5 : 0.23)
            let point = CGPoint(x: rect.midX + cos(angle) * radius, y: rect.midY + sin(angle) * radius)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

private struct CodexDonutIcing: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        for step in 0...80 {
            let angle = CGFloat(step) / 80 * .pi * 2
            let radius = rect.width * (0.425 + 0.025 * sin(angle * 7))
            let point = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        path.addEllipse(in: rect.insetBy(dx: rect.width * 0.31, dy: rect.height * 0.31))
        return path
    }
}
