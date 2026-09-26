//
//  NotchShape.swift
//  boringNotch
//
// Created by Kai Azim on 2023-08-24.
// Original source: https://github.com/MrKai77/DynamicNotchKit
// Modified by Alexander on 2025-05-18.

import SwiftUI

struct NotchShape: Shape {
    private var topCornerRadius: CGFloat
    private var bottomCornerRadius: CGFloat
    var liquid: CGFloat
    var rocket: CGFloat

    init(
        topCornerRadius: CGFloat? = nil,
        bottomCornerRadius: CGFloat? = nil,
        rocket: CGFloat = 0,
        liquid: CGFloat = 0
    ) {
        self.topCornerRadius = topCornerRadius ?? 6
        self.bottomCornerRadius = bottomCornerRadius ?? 14
        self.rocket = rocket
        self.liquid = liquid
    }

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { .init(.init(topCornerRadius, bottomCornerRadius), .init(rocket, liquid)) }
        set {
            topCornerRadius = newValue.first.first
            bottomCornerRadius = newValue.first.second
            rocket = newValue.second.first
            liquid = newValue.second.second
        }
    }

    static func rocketCoordinate(_ x: CGFloat, width: CGFloat, height: CGFloat) -> CGFloat {
        let head = height * 0.45, tail = height * 0.28
        return (x + head) * width / max(1, width + head + tail)
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let r = topCornerRadius, b = bottomCornerRadius
        let t = min(1, max(0, rocket))
        let head = h * 0.45, tail = h * 0.28
        func point(_ x: CGFloat, _ y: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> CGPoint {
            let insideX = Self.rocketCoordinate(rx, width: w, height: h)
            return CGPoint(x: rect.minX + x + (insideX - x) * t,
                           y: rect.minY + y + (ry - y) * t)
        }
        var path = Path()
        path.move(to: point(0, 0, 0, 0))
        path.addCurve(to: point(r, r, -head, h * 0.5),
                      control1: point(r * 2 / 3, 0, -head * 0.30, h * 0.15),
                      control2: point(r, r / 3, -head, h * 0.42))
        path.addLine(to: point(r, h - b, -head, h * 0.5))
        path.addCurve(to: point(r + b, h, 0, h),
                      control1: point(r, h - b / 3, -head, h * 0.58),
                      control2: point(r + b / 3, h, -head * 0.30, h * 0.85))
        let depth = max(0, liquid) * (1 - t)
        let span = min(60, max(0, (w - 2 * (r + b)) / 3))
        path.addLine(to: point(w / 2 - span, h, w / 2 - span, h))
        path.addCurve(to: CGPoint(x: rect.midX, y: rect.maxY + depth),
                      control1: CGPoint(x: rect.midX - span * 0.55, y: rect.maxY),
                      control2: CGPoint(x: rect.midX - span * 0.35, y: rect.maxY + depth))
        path.addCurve(to: point(w / 2 + span, h, w / 2 + span, h),
                      control1: CGPoint(x: rect.midX + span * 0.35, y: rect.maxY + depth),
                      control2: CGPoint(x: rect.midX + span * 0.55, y: rect.maxY))
        path.addLine(to: point(w - r - b, h, w - h * 0.2, h))
        path.addQuadCurve(to: point(w - r, h - b, w + tail, h * 0.96),
                          control: point(w - r, h, w + tail, h))
        path.addCurve(to: point(w - r, h - b, w + tail * 0.65, h * 0.7),
                      control1: point(w - r, h - b, w + tail, h * 0.88),
                      control2: point(w - r, h - b, w + tail * 0.65, h * 0.79))
        path.addLine(to: point(w - r, r, w + tail * 0.65, h * 0.3))
        path.addCurve(to: point(w - r, r, w + tail, h * 0.04),
                      control1: point(w - r, r, w + tail * 0.65, h * 0.21),
                      control2: point(w - r, r, w + tail, h * 0.12))
        path.addQuadCurve(to: point(w, 0, w - h * 0.2, 0),
                          control: point(w - r, 0, w + tail, 0))
        path.closeSubpath()
        return path
    }

}

#Preview {
    NotchShape(topCornerRadius: 6, bottomCornerRadius: 14)
        .frame(width: 200, height: 32)
        .padding(10)
}


// One shared observer set for decorative animation across all notch windows.
@MainActor final class NotchMotionEnvironment: NSObject, ObservableObject {
    static let shared = NotchMotionEnvironment()
    static var interactionAnimation: Animation {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? .easeOut(duration: 0.15)
            : .spring(response: 0.28, dampingFraction: 0.9)
    }
    static func expansionAnimation(opening: Bool, reduced: Bool) -> Animation {
        reduced ? .easeInOut(duration: 0.18)
            : .spring(response: opening ? 0.42 : 0.38, dampingFraction: opening ? 0.9 : 1)
    }
    static var transientAnimation: Animation {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? .easeInOut(duration: 0.18)
            : .spring(response: 0.46, dampingFraction: 0.9)
    }
    static func decorativeFrameInterval(lowPower: Bool) -> Double {
        lowPower ? 1.0 / 15 : 1.0 / 24
    }
    static func lyricsFrameInterval(lowPower: Bool) -> Double {
        lowPower ? 1.0 / 15 : 1.0 / 35
    }
    @Published private(set) var suspended = false
    @Published private(set) var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    private override init() {
        super.init()
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(sleeping), name: NSWorkspace.screensDidSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(sleeping), name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(waking), name: NSWorkspace.screensDidWakeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(powerChanged), name: .NSProcessInfoPowerStateDidChange, object: nil)
    }
    @objc private func sleeping() { suspended = true }
    @objc private func waking() { suspended = false; powerChanged() }
    @objc private func powerChanged() { lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled }
}
