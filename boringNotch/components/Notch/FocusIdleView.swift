import SwiftUI

struct FocusModeIcon: View {
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ForEach(0..<4) { index in
                    let arc = Path { path in
                        path.addArc(center: CGPoint(x: 12, y: 12), radius: 8.4,
                            startAngle: .degrees(Double(index) * 90 + 12),
                            endAngle: .degrees(Double(index) * 90 + 78), clockwise: false)
                    }
                    arc.stroke(LinearGradient(stops: [
                        .init(color: .white.opacity(0.96), location: 0),
                        .init(color: .white.opacity(0.76), location: 0.45),
                        .init(color: .white.opacity(0.92), location: 0.65),
                        .init(color: .white.opacity(0.50), location: 1)
                    ], startPoint: .topLeading, endPoint: .bottomTrailing),
                        style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                    arc.stroke(.white.opacity(0.35), style: StrokeStyle(lineWidth: 0.55, lineCap: .round))
                        .offset(y: -0.35)
                }
                Circle()
                    .fill(RadialGradient(colors: [.white, Color(white: 0.84), Color(white: 0.40)],
                        center: .init(x: 0.3, y: 0.2), startRadius: 0, endRadius: 6))
                    .overlay(Circle().stroke(LinearGradient(colors: [.white.opacity(0.9), .white.opacity(0.1)],
                        startPoint: .top, endPoint: .bottom), lineWidth: 0.45))
                    .frame(width: 6.6, height: 6.6)
                    .position(x: 12, y: 12)
            }
            .frame(width: 24, height: 24)
            .scaleEffect(geometry.size.width / 24, anchor: .topLeading)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
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

    var body: some View {
        HStack(spacing: 0) {
            FocusModeIcon()
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
