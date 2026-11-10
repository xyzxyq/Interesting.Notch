#!/usr/bin/env python3
"""Run production display routing against disconnected/reconnected screen fixtures."""
import os
import re
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'boringNotch/boringNotchApp.swift').read_text()


def body(signature):
    start = source.index('{', source.index(signature)) + 1
    depth, end = 1, start
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end - 1]


observer = source.split('forName: Notification.Name.automaticallySwitchDisplayChanged', 1)[1].split('NotificationCenter.default.addObserver', 1)[0]
assert 'adjustWindowPosition()' in observer and 'setupDragDetectors()' in observer
detectors = body('private func setupDragDetectors(')
assert 'guard let window else { return }' in detectors
assert 'addObserver' not in body('private func createBoringNotchWindow(')
registration = re.search(
    r'NotificationCenter.default.addObserver\(\s*self, selector: #selector\(notchWindowDidChangeScreen\(_:\)\),\s*name: NSWindow.didChangeScreenNotification, object: nil\s*\)',
    source).group()

swift = '''import Foundation
enum Key { case showOnAllDisplays, showOnLockScreen, automaticallySwitchDisplay }
enum Defaults {
    static var values: [Key: Bool] = [:]
    static subscript(key: Key) -> Bool { values[key] ?? false }
}
final class NSScreen {
    let displayUUID: String?
    init(_ uuid: String) { displayUUID = uuid }
    static var screens: [NSScreen] = []
    static var main: NSScreen? { screens.first }
    static func screen(withUUID uuid: String) -> NSScreen? { screens.first { $0.displayUUID == uuid } }
}
enum NotchState { case closed, open }
final class BoringViewModel {
    var screenUUID: String?
    var notchSize = 0
    var notchState = NotchState.closed
    init(screenUUID: String? = nil) { self.screenUUID = screenUUID }
    func close() { notchState = .closed }
}
final class Window: NSObject {
    static let didChangeScreenNotification = Notification.Name("fixture.screenChanged")
    var closed = false
    var screen: NSScreen?
    func close() { closed = true }
}
typealias NSWindow = Window
final class NotchSpaceManager {
    static let shared = NotchSpaceManager()
    var notchSpace: NotchSpaceManager { self }
    var windows: Set<Window> = []
}
final class Coordinator {
    var preferredScreenUUID: String? = "preferred"
    var selectedScreenUUID = "preferred"
}
func getClosedNotchSize(screenUUID: String?) -> Int { 1 }
@MainActor final class Harness: NSObject {
    var isScreenLocked = false
    var windows: [String: Window] = [:]
    var viewModels: [String: BoringViewModel] = [:]
    var window: Window?
    let coordinator = Coordinator()
    let vm = BoringViewModel()
    var detectorCount = 1
    var creations = 0
    var detectorRefreshes = 0
    override init() {
        super.init()
REGISTRATION
    }
    deinit { NotificationCenter.default.removeObserver(self) }
    func setupDragDetectors() { detectorRefreshes += 1 }
    @objc private func notchWindowDidChangeScreen(_ notification: Notification) {
SCREEN_CHANGED
    }
    func cleanupDragDetectors() { detectorCount = 0 }
    func createBoringNotchWindow(for screen: NSScreen, with vm: BoringViewModel) -> Window {
        creations += 1
        let window = Window()
        window.screen = screen
        NotchSpaceManager.shared.windows.insert(window)
        return window
    }
    func positionWindow(_ window: Window, on screen: NSScreen, changeAlpha: Bool) { window.screen = screen }
    func cleanupWindows(shouldInvert: Bool = false) {
CLEANUP
    }
    func adjustWindowPosition(changeAlpha: Bool = false) {
ADJUST
    }
}
@main struct Check {
    @MainActor static func main() async throws {
        let preferred = NSScreen("preferred"), fallback = NSScreen("fallback")
        NSScreen.screens = [preferred, fallback]
        let h = Harness()
        h.adjustWindowPosition()
        assert(h.window?.screen === preferred && h.creations == 1)
        weak var released = h.window
        NSScreen.screens = [fallback]
        h.adjustWindowPosition()
        assert(h.window == nil && released == nil && h.detectorCount == 0)
        assert(NotchSpaceManager.shared.windows.isEmpty, "Hidden hosting window must be released")
        h.adjustWindowPosition()
        assert(h.creations == 1, "Repeated disconnected events must stay idle")
        Defaults.values[.automaticallySwitchDisplay] = true
        h.adjustWindowPosition()
        assert(h.window?.screen === fallback && h.creations == 2, "Re-enable must restore fallback")
        Defaults.values[.automaticallySwitchDisplay] = false
        h.adjustWindowPosition()
        assert(h.window == nil, "Disabling fallback releases its render tree")
        NSScreen.screens = [preferred, fallback]
        h.adjustWindowPosition()
        assert(h.window?.screen === preferred && h.creations == 3)
        h.adjustWindowPosition()
        assert(h.creations == 3, "Unchanged display must reuse its window")
        h.cleanupWindows()
        Defaults.values[.showOnAllDisplays] = true
        h.adjustWindowPosition()
        assert(h.windows.count == 2)
        NSScreen.screens = [fallback]
        h.adjustWindowPosition()
        assert(h.windows.count == 1 && h.viewModels.count == 1)
        h.cleanupWindows()
        assert(NotchSpaceManager.shared.windows.isEmpty)
        for _ in 0..<100 {
            NSScreen.screens = [preferred, fallback]
            h.adjustWindowPosition()
            let first = h.windows["preferred"]!, second = h.windows["fallback"]!
            let before = h.detectorRefreshes
            NotificationCenter.default.post(name: Window.didChangeScreenNotification, object: first)
            NotificationCenter.default.post(name: Window.didChangeScreenNotification, object: second)
            for _ in 0..<100 {
                if h.detectorRefreshes >= before + 2 { break }
                try await Task.sleep(for: .milliseconds(1))
            }
            assert(h.detectorRefreshes == before + 2, "Reconnect accumulated duplicate callbacks")
            h.cleanupWindows()
            NotificationCenter.default.post(name: Window.didChangeScreenNotification, object: first)
            NotificationCenter.default.post(name: Window.didChangeScreenNotification, object: Window())
            try await Task.sleep(for: .milliseconds(2))
            assert(h.detectorRefreshes == before + 2, "Closed/settings windows must not reset drag monitors")
        }
        print("PASS: disconnected display releases window, fallback/reconnect restore, all-display cleanup, 100 two-screen cycles retain exactly one observer and ignore closed/unrelated windows")
    }
}
'''
for key, value in [('CLEANUP', body('private func cleanupWindows(')), ('ADJUST', body('func adjustWindowPosition(')),
                   ('REGISTRATION', registration), ('SCREEN_CHANGED', body('private func notchWindowDidChangeScreen('))]:
    swift = swift.replace('\n' + key + '\n', '\n' + value + '\n')

with tempfile.TemporaryDirectory(prefix='notch-display-check-') as directory:
    folder = Path(directory)
    (folder / 'Check.swift').write_text(swift)
    env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', str(folder / 'Check.swift'), '-o', str(folder / 'check')], env=env, check=True)
    subprocess.run([str(folder / 'check')], timeout=10, check=True)
