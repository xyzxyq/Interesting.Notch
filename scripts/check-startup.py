#!/usr/bin/env python3
"""Check the real settings-window lifecycle with a lightweight settings view."""
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
controller = (root / 'boringNotch/components/Settings/SettingsWindowController.swift').read_text()
controller = controller.replace('import Defaults\n', '').replace('import Sparkle\n', '')
view_model = (root / 'boringNotch/models/BoringViewModel.swift').read_text()
camera_access = next(line for line in view_model.splitlines() if 'var webcamManager:' in line)
assert 'WebcamManager.shared' not in (root / 'boringNotch/ContentView.swift').read_text()
app_delegate = (root / 'boringNotch/boringNotchApp.swift').read_text()
activation_methods = app_delegate.split('    func applicationShouldHandleReopen(', 1)[1].split('    func applicationWillTerminate', 1)[0]
activation_methods = '    func applicationShouldHandleReopen(' + activation_methods
activation_method = view_model.split('    func animateActivation()', 1)[1].split('    func open()', 1)[0]
activation_motion = (root / 'boringNotch/animations/HelloAnimation.swift').read_text().split('struct NotchActivationMotion:', 1)[1].split('extension View where Self: Shape', 1)[0]
activation_motion = 'struct NotchActivationMotion:' + activation_motion
activation_motion = activation_motion.replace('.task(id: sequence)', '.onChange(of: pulse, initial: true) { _, value in activationPulse = value }\n            .task(id: sequence)')
fixture = r'''
final class WebcamManager {
    static var creations = 0
    static let shared = WebcamManager()
    private init() { Self.creations += 1 }
}
final class StartupModel {
CAMERA_ACCESS
}

final class SPUStandardUpdaterController {}
enum Brand { static func localized(_ text: String) -> String { text } }
@MainActor struct SettingsView: View {
    static var creations = 0
    static var updater: SPUStandardUpdaterController?
    init(updaterController: SPUStandardUpdaterController?) {
        Self.creations += 1
        Self.updater = updaterController
    }
    var body: some View { Text("Startup lifecycle check") }
}
@MainActor final class ActivationVM {
    var activationSequence = 0
    func animateActivation() ACTIVATION_METHOD
}
@MainActor final class ActivationWindow {
    var alphaValue = 1.0
    var frontCount = 0
    func orderFrontRegardless() { frontCount += 1 }
}
@MainActor final class ActivationCoordinator {
    var firstLaunch = false
    var helloAnimationRunning = false
}
@MainActor enum Defaults {
    enum Key { case showOnAllDisplays }
    static var allDisplays = false
    static subscript(_ key: Key) -> Bool { allDisplays }
}
@MainActor final class ActivationDelegate {
    var isScreenLocked = false
    let coordinator = ActivationCoordinator()
    let vm = ActivationVM()
    var window: ActivationWindow? = ActivationWindow()
    var windows: [String: ActivationWindow] = [:]
    var viewModels: [String: ActivationVM] = [:]
    var onboardingCount = 0
    func showOnboardingWindow() { onboardingCount += 1 }
    func adjustWindowPosition() { window = ActivationWindow() }
    ACTIVATION_METHODS
}
@MainActor var activationPulse: CGFloat = -1
ACTIVATION_MOTION
@MainActor final class ActivationState: ObservableObject {
    @Published var sequence = 0
    @Published var visible = true
    @Published var reduced = false
}
struct ActivationFixture: View {
    @ObservedObject var state: ActivationState
    var body: some View {
        if state.visible {
            Color.white.frame(width: 200, height: 32)
                .modifier(NotchActivationMotion(sequence: state.sequence, expanded: false, reduced: state.reduced))
        }
    }
}
@MainActor func checkActivation() {
    let delegate = ActivationDelegate()
    delegate.coordinator.firstLaunch = true
    assert(!delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true))
    assert(delegate.onboardingCount == 1 && delegate.vm.activationSequence == 0)
    delegate.coordinator.firstLaunch = false
    delegate.isScreenLocked = true
    assert(!delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
    assert(delegate.vm.activationSequence == 0, "Locked app must not reveal or animate the notch")
    delegate.isScreenLocked = false
    delegate.coordinator.helloAnimationRunning = true
    _ = delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true)
    assert(delegate.vm.activationSequence == 0, "Returning animation must not interrupt Hello")
    delegate.coordinator.helloAnimationRunning = false
    assert(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true),
           "Normal reopening must preserve AppKit window restoration")
    assert(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
    assert(delegate.vm.activationSequence == 2 && delegate.window?.frontCount == 2)
    delegate.window?.alphaValue = 0
    _ = delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true)
    assert(delegate.vm.activationSequence == 2, "Hidden display must stay hidden")
    Defaults.allDisplays = true
    let first = ActivationVM(), second = ActivationVM()
    delegate.windows = ["first": ActivationWindow(), "second": ActivationWindow()]
    delegate.viewModels = ["first": first, "second": second]
    _ = delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true)
    assert(first.activationSequence == 1 && second.activationSequence == 1)

    let state = ActivationState()
    let view = NSHostingView(rootView: ActivationFixture(state: state))
    let panel = NSPanel(contentRect: NSRect(x: -10000, y: -10000, width: 260, height: 80),
                        styleMask: [.borderless], backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    panel.contentView = view
    panel.orderFront(nil)
    defer { panel.orderOut(nil) }
    func advance(_ duration: Double) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: duration))
        view.layoutSubtreeIfNeeded()
    }
    advance(0.1)
    assert(activationPulse == 0, "Unrequested mounting must not animate")
    state.sequence = 1
    advance(0.1)
    assert(activationPulse == 1)
    state.sequence = 2
    advance(0.1)
    assert(activationPulse == 1, "Superseded task must not end a new activation")
    advance(0.1)
    assert(activationPulse == 0, "Activation must settle without an idle loop")
    state.visible = false
    advance(0.05)
    state.reduced = true
    state.sequence = 3
    state.visible = true
    advance(0.1)
    assert(activationPulse == 1, "Activation requested before mounting must still play")
    advance(0.1)
    assert(activationPulse == 0)
    print("PASS: first-run/reopen separation, lock and hidden-display guards, multi-display replay; mounted animation, cancellation, reduced-motion remount and settling")
}
@main @MainActor struct Check {
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let first = StartupModel(), second = StartupModel()
        assert(WebcamManager.creations == 0, "Closed notch must not enumerate camera devices at startup")
        assert(first.webcamManager === second.webcamManager && WebcamManager.creations == 1,
               "First camera access must create one shared manager across displays")
        let controller = SettingsWindowController.shared
        let updater = SPUStandardUpdaterController()
        assert(controller.window == nil && SettingsView.creations == 0,
               "App startup must not construct the settings window or its view")
        controller.setUpdaterController(updater)
        assert(controller.window == nil && SettingsView.creations == 0,
               "Registering the updater must not load settings")
        controller.showWindow()
        guard let window = controller.window else { fatalError("Settings did not open") }
        assert(window.isVisible && SettingsView.creations == 1 && SettingsView.updater === updater)
        controller.showWindow()
        assert(controller.window === window && SettingsView.creations == 1)
        controller.close()
        assert(!window.isVisible)
        controller.showWindow()
        assert(controller.window === window && window.isVisible && SettingsView.creations == 1,
               "Reopening settings must reuse its window and preserve view state")
        let replacement = SPUStandardUpdaterController()
        controller.setUpdaterController(replacement)
        assert(controller.window === window && SettingsView.updater === replacement)
        controller.close()
        checkActivation()
        print("PASS: lazy shared camera access, lazy settings, updater registration, first open, repeated open, close/reopen, updater replacement")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='notch-startup-check-') as directory:
    folder = Path(directory)
    (folder / 'Check.swift').write_text(controller + fixture.replace('CAMERA_ACCESS', camera_access).replace('ACTIVATION_METHODS', activation_methods).replace('ACTIVATION_METHOD', activation_method).replace('ACTIVATION_MOTION', activation_motion))
    env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library',
                    '-external-plugin-path', env['DEVELOPER_DIR'] + '/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins#' + env['DEVELOPER_DIR'] + '/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-plugin-server',
                    str(folder / 'Check.swift'), '-o', str(folder / 'check')], env=env, check=True)
    subprocess.run([str(folder / 'check')], timeout=15, check=True)
