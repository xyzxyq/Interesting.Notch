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
        print("PASS: lazy shared camera access, lazy settings, updater registration, first open, repeated open, close/reopen, updater replacement")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='notch-startup-check-') as directory:
    folder = Path(directory)
    (folder / 'Check.swift').write_text(controller + fixture.replace('CAMERA_ACCESS', camera_access))
    env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library',
                    str(folder / 'Check.swift'), '-o', str(folder / 'check')], env=env, check=True)
    subprocess.run([str(folder / 'check')], timeout=15, check=True)
