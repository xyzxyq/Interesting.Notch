#!/usr/bin/env python3
"""Run real SwiftUI title lifecycle and extracted production gesture regressions."""
from pathlib import Path
import os
import platform
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
content = (root / 'boringNotch/ContentView.swift').read_text()
gestures = content.split('    private func handleDownGesture', 1)[1].split('\n}\n\nstruct FullScreenDropDelegate', 1)[0]
gestures = '    func handleDownGesture' + gestures.replace('private func handleUpGesture', 'func handleUpGesture')
motion = (root / 'boringNotch/components/Notch/NotchShape.swift').read_text().split('// One shared observer set', 1)[1]
lottie = (root / 'boringNotch/components/LottieView.swift').read_text()
lottie_coordinator = lottie.split('    @MainActor final class Coordinator {', 1)[1].split('    func makeCoordinator()', 1)[0]
lottie_coordinator = '@MainActor final class LottieCoordinator {' + lottie_coordinator
marquee = (root / 'boringNotch/components/Live activities/MarqueeTextView.swift').read_text()
# Observe the installed @State rather than a detached View copy. Production logic is unchanged.
marquee = marquee.replace('accessibilityReduceMotion', 'motionCheckReduced')
marquee = marquee.replace('.onDisappear { reset() }', '''.onDisappear { reset() }
        .onChange(of: "\\(text)-\\(textSize.width)-\\(scrolling)-\\(animate)", initial: true) { _, _ in
            observation = (text, textSize.width, scrolling, animate)
        }''')
check = r'''
import AppKit
import SwiftUI
private struct MotionCheckReducedKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var motionCheckReduced: Bool {
        get { self[MotionCheckReducedKey.self] }
        set { self[MotionCheckReducedKey.self] = newValue }
    }
}
@MainActor var observation: (String, CGFloat, Bool, Bool) = ("", 0, false, false)
enum Key { case gestureSensitivity, enableHaptics }
enum Defaults {
    static subscript(_ key: Key) -> CGFloat { 100 }
    static subscript(_ key: Key) -> Bool { false }
}
enum NotchState { case open, closed }
@MainActor final class VM {
    var notchState = NotchState.closed
    var isHoveringCalendar = false
    var closeCount = 0
    func close() { closeCount += 1; notchState = .closed }
}
@MainActor final class SharingStateManager {
    static let shared = SharingStateManager()
    var preventNotchClose = false
}
@MainActor final class GestureCheck {
    let vm = VM()
    var gestureProgress: CGFloat = 0
    var reducedMotion = false
    var isHovering = false
    var haptics = false
    var opens = 0
    let animationSpring = Animation.linear(duration: 0.01)
    func doOpen() { opens += 1; vm.notchState = .open }
GESTURES
}
@MainActor final class FixtureState: ObservableObject {
    @Published var title = "Short"
    @Published var width: CGFloat = 100
    @Published var reduced = false
    @Published var visible = true
}
struct Fixture: View {
    @ObservedObject var state: FixtureState
    var body: some View {
        if state.visible {
            MarqueeText($state.title, minDuration: 0, frameWidth: state.width)
                .environment(\.motionCheckReduced, state.reduced)
        }
    }
}
// Stub only the library boundary; run the production playback policy below.
@MainActor final class LottieAnimationView {
    var animation: Bool?
    var isAnimationPlaying = false
    var playCount = 0
    func play() { isAnimationPlaying = true; playCount += 1 }
    func pause() { isAnimationPlaying = false }
}
LOTTIE_COORDINATOR
@main @MainActor struct Check {
    static func main() {
        let lottie = LottieCoordinator(), animation = LottieAnimationView()
        lottie.shouldPlay = true
        lottie.applyPlayback(to: animation)
        assert(animation.playCount == 0, "Loading must not start an absent animation")
        animation.animation = true
        lottie.applyPlayback(to: animation)
        lottie.applyPlayback(to: animation)
        assert(animation.playCount == 1, "Unrelated updates must not restart playback")
        lottie.shouldPlay = false
        lottie.applyPlayback(to: animation)
        assert(!animation.isAnimationPlaying)
        lottie.shouldPlay = true
        lottie.applyPlayback(to: animation)
        assert(animation.playCount == 2)
        let gesture = GestureCheck()
        gesture.handleDownGesture(translation: 25, phase: .changed)
        assert(gesture.gestureProgress == 5 && gesture.opens == 0)
        gesture.handleDownGesture(translation: 150, phase: .cancelled)
        assert(gesture.gestureProgress == 0 && gesture.opens == 0)
        gesture.handleDownGesture(translation: 101, phase: .changed)
        assert(gesture.vm.notchState == .open && gesture.opens == 1 && gesture.gestureProgress == 0)
        gesture.handleUpGesture(translation: 150, phase: .ended)
        assert(gesture.vm.closeCount == 0, "An end event must not trigger a second action")
        gesture.handleUpGesture(translation: 25, phase: .changed)
        assert(gesture.gestureProgress == -5)
        gesture.handleUpGesture(translation: 150, phase: .cancelled)
        assert(gesture.vm.closeCount == 0 && gesture.gestureProgress == 0)
        gesture.handleUpGesture(translation: 101, phase: .changed)
        assert(gesture.vm.closeCount == 1 && gesture.gestureProgress == 0)
        gesture.reducedMotion = true
        gesture.handleDownGesture(translation: 25, phase: .changed)
        assert(gesture.gestureProgress == 0)
        gesture.handleDownGesture(translation: 101, phase: .changed)
        assert(gesture.vm.notchState == .open, "Reduced motion must preserve gesture actions")

        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let state = FixtureState()
        let view = NSHostingView(rootView: Fixture(state: state))
        let panel = NSPanel(contentRect: NSRect(x: -10000, y: -10000, width: 400, height: 50),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = view
        panel.orderFront(nil)
        defer { panel.orderOut(nil) }
        func advance() {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
            view.layoutSubtreeIfNeeded()
        }
        advance()
        assert(observation.1 > 0 && observation.1 < 100 && !observation.2 && !observation.3)
        let width = observation.1
        state.width = width + 2
        advance()
        assert(!observation.2, "A fitting title must not scroll because of the duplicate's spacing")
        state.width = width - 2
        advance()
        assert(observation.2 && observation.3)
        state.reduced = true
        advance()
        assert(!observation.2 && !observation.3)
        state.reduced = false
        NotchMotionEnvironment.shared.suspended = true
        advance()
        assert(!observation.2 && !observation.3)
        NotchMotionEnvironment.shared.suspended = false
        advance()
        assert(observation.2 && observation.3)
        state.title = "A long title that should scroll"
        advance()
        state.title = "X"
        advance()
        assert(observation.0 == "X" && !observation.2 && !observation.3, "Old start tasks must be cancelled")
        state.visible = false
        advance()
        state.title = "Another long title"
        state.visible = true
        advance()
        assert(observation.0 == state.title && observation.2 && observation.3)
        print("Motion checks passed: Lottie playback policy; gesture tracking/end/cancellation/reduced motion; real title measurement, resize, sleep/wake, reduced motion, replacement and remount")
    }
}
'''.replace('GESTURES', gestures).replace('LOTTIE_COORDINATOR', lottie_coordinator)
with tempfile.TemporaryDirectory(prefix='notch-motion-check-') as temp:
    folder = Path(temp)
    (folder / 'Motion.swift').write_text('import SwiftUI\n// One shared observer set' + motion.replace('private(set)', ''))
    (folder / 'Marquee.swift').write_text(marquee)
    (folder / 'Check.swift').write_text(check)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-target', f'{platform.machine()}-apple-macos14.0',
                    '-external-plugin-path', env['DEVELOPER_DIR'] + '/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins#' + env['DEVELOPER_DIR'] + '/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-plugin-server', str(folder / 'Motion.swift'),
                    str(folder / 'Marquee.swift'), str(folder / 'Check.swift'), '-o', str(folder / 'check')], env=env, check=True)
    subprocess.run([str(folder / 'check')], check=True)
