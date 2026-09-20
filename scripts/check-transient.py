#!/usr/bin/env python3
"""Run the production transient event methods with no media keys or power writes."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "boringNotch/BoringViewCoordinator.swift").read_text()
types = source[source.index("enum SneakContentType"):source.index("@MainActor")]
methods = source[source.index("    func toggleSneakPeek("):source.index("    func showEmpty()")]
check = '''import AppKit
import Combine
import SwiftUI
enum Defaults {
    enum Key { case hudReplacement, showPowerStatusNotifications }
    static subscript(_ key: Key) -> Bool { true }
}
''' + types + '''
@MainActor final class Coordinator: ObservableObject {
    static let shared = Coordinator()
    var currentMicStatus = true
''' + methods + '''
}
typealias BoringViewCoordinator = Coordinator
@MainActor func checkLayout() {
    for (active, width) in [(0, 220.0), (1, 380.0), (2, 330.0), (3, 460.0)] {
        let view = TransientHeaderLayout(active: active) {
            Color.white.frame(width: 220, height: 32).layoutValue(key: TransientHeaderID.self, value: 0)
            Color.white.frame(width: 380, height: 32).layoutValue(key: TransientHeaderID.self, value: 1)
            Color.white.frame(width: 330, height: 32).layoutValue(key: TransientHeaderID.self, value: 2)
            Color.white.frame(width: 460, height: 32).opacity(0.9).layoutValue(key: TransientHeaderID.self, value: 3)
        }.fixedSize()
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        assert(renderer.cgImage?.width == Int(width), "Outgoing content must not hold the old width")
    }
    print("Header geometry checks passed: music, HUD and battery use incoming size during overlap")
}

@main struct Check {
    @MainActor static func main() async throws {
        checkLayout()
        let coordinator = Coordinator()
        var hudEvents = 0, batteryEvents = 0
        let hud = coordinator.$sneakPeek.dropFirst().sink { _ in hudEvents += 1 }
        let battery = coordinator.$expandingView.dropFirst().sink { _ in batteryEvents += 1 }
        coordinator.toggleSneakPeek(status: true, type: .volume, duration: 0.08, value: 0.4)
        try await Task.sleep(for: .milliseconds(20))
        assert(hudEvents == 1, "One HUD event must publish one complete state, got \\(hudEvents)")
        coordinator.toggleSneakPeek(status: true, type: .brightness, duration: 0.16, value: 0.7)
        try await Task.sleep(for: .milliseconds(90))
        assert(coordinator.sneakPeek.show && coordinator.sneakPeek.type == .brightness,
               "A stale timer must not hide a newer event")
        try await Task.sleep(for: .milliseconds(110))
        assert(!coordinator.sneakPeek.show && coordinator.sneakPeek.type == .brightness,
               "Dismissal must retain outgoing content, not switch it to music")
        coordinator.toggleExpandingView(status: true, type: .battery)
        try await Task.sleep(for: .milliseconds(20))
        assert(batteryEvents == 1, "Battery presentation must publish one complete state")
        coordinator.toggleExpandingView(status: false, type: .battery)
        withExtendedLifetime((hud, battery)) {}
        let model = BatteryStatusViewModel.shared
        var info = BatteryInfo(isPluggedIn: false, isCharging: false, currentCapacity: 80,
                               maxCapacity: 100, isInLowPowerMode: false, timeToFullCharge: 0)
        model.updateBatteryInfo(info)
        var notifications = 0, updates = 0
        let notice = Coordinator.shared.$expandingView.dropFirst().sink { _ in notifications += 1 }
        let changes = model.objectWillChange.sink { updates += 1 }
        model.updateBatteryInfo(info, notify: true)
        assert(notifications == 0 && updates == 0, "Unchanged battery snapshots must do no work")
        info.isPluggedIn = true; info.isCharging = true
        model.updateBatteryInfo(info, notify: true)
        assert(notifications == 1 && model.statusText == "Charging battery")
        info.isCharging = false; info.currentCapacity = 100
        model.updateBatteryInfo(info, notify: true)
        assert(notifications == 2 && model.statusText == "Full charge")
        info.isPluggedIn = false
        model.updateBatteryInfo(info, notify: true)
        assert(notifications == 3 && model.statusText == "Unplugged")
        info.isPluggedIn = true; info.currentCapacity = 80
        model.updateBatteryInfo(info, notify: true)
        assert(model.statusText == "Not charging")
        info.isInLowPowerMode = true
        model.updateBatteryInfo(info, notify: true)
        assert(model.statusText == "Low Power: On")
        withExtendedLifetime((notice, changes)) {}
        print("Battery checks passed: unchanged, charging, full, unplugged, paused charging, low power")
        print("Transient checks passed: atomic updates, replacement, stale timer, dismissal content")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="notch-transient-") as directory:
    path = Path(directory)
    layout = (root / "boringNotch/ContentView.swift").read_text().split("private struct TransientHeaderID:", 1)[1]
    (path / "Check.swift").write_text(check + "\nprivate struct TransientHeaderID:" + layout)
    motion = (root / "boringNotch/components/Notch/NotchShape.swift").read_text().split("// One shared observer set", 1)[1]
    (path / "Motion.swift").write_text("import SwiftUI\n// One shared observer set" + motion)
    battery = (root / "boringNotch/models/BatteryStatusViewModel.swift").read_text()
    (path / "Battery.swift").write_text(battery.replace("import Defaults\n", "").replace("private func updateBatteryInfo", "func updateBatteryInfo"))
    env = dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer")
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-D", "EDGE_CHECKS",
                    str(path / "Motion.swift"),
                    str(path / "Check.swift"), str(path / "Battery.swift"),
                    str(root / "boringNotch/managers/BatteryActivityManager.swift"), "-o", str(path / "check")], env=env, check=True)
    subprocess.run([str(path / "check")], check=True)
