import SwiftUI

struct FocusModeIcon: View {
    var breathing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func path(in rect: CGRect) -> Path {
        var arcs = Path()
        for index in 0..<4 {
            let angle = Double(index) * .pi / 2 + .pi / 15
            arcs.move(to: CGPoint(x: 12 + cos(angle) * 8.4, y: 12 + sin(angle) * 8.4))
            arcs.addArc(center: CGPoint(x: 12, y: 12), radius: 8.4,
                startAngle: .degrees(Double(index) * 90 + 12),
                endAngle: .degrees(Double(index) * 90 + 78), clockwise: false)
        }
        var symbol = arcs.strokedPath(StrokeStyle(lineWidth: 2.2, lineCap: .round))
        symbol.addEllipse(in: CGRect(x: 8.7, y: 8.7, width: 6.6, height: 6.6))
        return symbol.applying(CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 24))
    }

    var body: some View {
        Group {
            if breathing && !reduceMotion {
                FocusIconBreath()
            } else {
                GeometryReader { geometry in
                    Self.path(in: CGRect(origin: .zero, size: geometry.size)).fill(.white)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

struct FocusIconBreath: NSViewRepresentable {
    func makeNSView(context: Context) -> SymbolView { SymbolView() }
    func updateNSView(_ view: SymbolView, context: Context) {}
    static func dismantleNSView(_ view: SymbolView, coordinator: ()) { view.layer?.removeAllAnimations() }

    final class SymbolView: NSView {
        override var isFlipped: Bool { true }
        init() {
            super.init(frame: CGRect(x: 0, y: 0, width: 24, height: 24))
            let symbol = CAShapeLayer()
            symbol.fillColor = NSColor.white.cgColor
            symbol.path = FocusModeIcon.path(in: bounds).cgPath
            layer = symbol
            wantsLayer = true
            let breath = CAKeyframeAnimation(keyPath: "opacity")
            breath.values = [0.55, 1, 0.55]
            breath.duration = 4.8
            breath.repeatCount = .infinity
            breath.calculationMode = .cubic
            breath.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 15)
            symbol.add(breath, forKey: "breath")
        }
        required init?(coder: NSCoder) { nil }
        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            (layer as? CAShapeLayer)?.path = FocusModeIcon.path(in: bounds).cgPath
            CATransaction.commit()
        }
    }
}

struct FocusDurationLabel: View {
    let startedAt: Date
    let now: Date

    var body: some View {
        let label = ImmersiveFocus.elapsedLabel(since: startedAt, now: now)
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(label.value).font(.system(size: 12, weight: .medium)).monospacedDigit()
                Text(label.unit).font(.system(size: 8, weight: .medium)).foregroundStyle(.white.opacity(0.65))
            }.fixedSize(horizontal: true, vertical: false)
            VStack(spacing: 0) {
                Text(label.value).font(.system(size: 11, weight: .medium)).monospacedDigit()
                Text(label.unit).font(.system(size: 6.5, weight: .medium)).foregroundStyle(.white.opacity(0.65))
            }
        }
        .foregroundStyle(.white)
        .lineLimit(1)
        .minimumScaleFactor(0.65)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("专注时长 \(label.value) \(label.unit == "MIN" ? "分钟" : "小时")")
    }
}

struct FocusIdleView: View {
    let startedAt: Date
    let sideWidth: CGFloat
    let gap: CGFloat
    let iconSize: CGFloat
    var breathing = false

    var body: some View {
        HStack(spacing: 0) {
            FocusModeIcon(breathing: breathing)
                .frame(width: iconSize, height: iconSize)
                .frame(width: sideWidth, alignment: .trailing)
            Color.clear.frame(width: gap)
            TimelineView(.periodic(from: startedAt, by: 60)) { timeline in
                FocusDurationLabel(startedAt: startedAt, now: timeline.date)
            }
            .frame(width: sideWidth, alignment: .center)
        }
    }
}
