#!/usr/bin/env python3
"""Exercise production smart-energy observers with isolated power and preference inputs."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
motion = (root / 'boringNotch/components/Notch/NotchShape.swift').read_text().split('// One shared observer set', 1)[1]
# Only replace system input boundaries; the production observers and state transitions run unchanged.
motion = motion.replace('ProcessInfo.processInfo', 'powerFixture')
battery = (root / 'boringNotch/managers/BatteryActivityManager.swift').read_text().split('struct BatteryInfo:', 1)[1]
check = r'''
import AppKit
import Combine
import SwiftUI
@MainActor final class PowerFixture {
    var isLowPowerModeEnabled = false
    var thermalState = ProcessInfo.ThermalState.nominal
}
@MainActor let powerFixture = PowerFixture()
@MainActor enum Defaults {
    enum Key { case smartEnergySaving }
    static let value = CurrentValueSubject<Bool, Never>(false)
    static subscript(_ key: Key) -> Bool { value.value }
    static func publisher(_ key: Key) -> AnyPublisher<Bool, Never> { value.eraseToAnyPublisher() }
}
@MainActor final class BatteryActivityManager {
    static let shared = BatteryActivityManager()
    var info = BatteryInfo(isPluggedIn: false, isCharging: false, currentCapacity: 80,
                           maxCapacity: 100, isInLowPowerMode: false, timeToFullCharge: 0)
    var observers: [Int: @MainActor (BatteryInfo) -> Void] = [:]
    func initializeBatteryInfo() -> BatteryInfo { info }
    func addObserver(_ observer: @escaping @MainActor (BatteryInfo) -> Void) -> Int {
        let id = observers.count; observers[id] = observer; return id
    }
    func removeObserver(byId id: Int) { observers.removeValue(forKey: id) }
    func send(_ update: (inout BatteryInfo) -> Void) {
        update(&info)
        for observer in observers.values { observer(info) }
    }
}
@main struct Check {
    @MainActor static func settle(_ predicate: () -> Bool) async {
        for _ in 0..<200 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        fatalError("Smart-energy observer did not settle")
    }
    @MainActor static func main() async {
        let motion = NotchMotionEnvironment.shared
        let battery = BatteryActivityManager.shared
        assert(!motion.energySavingActive, "An opt-in feature must preserve battery behavior while disabled")
        assert(battery.observers.count == 1, "Reuse one battery observer, not a polling timer")
        var updates = 0
        let observer = motion.$energySavingActive.dropFirst().sink { _ in updates += 1 }
        Defaults.value.send(true)
        await settle { motion.energySavingActive }
        assert(updates == 1 && !motion.suspended, "Saving must not masquerade as display sleep")
        battery.send { $0.currentCapacity = 79 }
        assert(updates == 1, "Percentage-only changes must not rebuild the effective state")

        battery.send { $0.isPluggedIn = true; $0.isCharging = true }
        assert(!motion.energySavingActive)
        battery.send { $0.isCharging = false; $0.currentCapacity = 100 }
        assert(!motion.energySavingActive, "AC at full charge is not battery supply")
        battery.send { $0.currentCapacity = 80 }
        assert(!motion.energySavingActive, "Paused AC charging must not activate saving")
        battery.send { $0.isPluggedIn = false; $0.maxCapacity = 0 }
        assert(!motion.energySavingActive, "Desktop/unknown battery data is not confirmed battery supply")
        battery.send { $0.maxCapacity = 100 }
        assert(motion.energySavingActive, "Unplugging must enter saving without waiting for a timer")
        Defaults.value.send(false)
        await settle { !motion.energySavingActive }
        assert(!motion.suspended)

        battery.send { $0.isPluggedIn = true }
        powerFixture.isLowPowerModeEnabled = true
        NotificationCenter.default.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        await settle { motion.lowPower }
        assert(!motion.energySavingActive, "System low-power alone must respect the preference")
        Defaults.value.send(true)
        await settle { motion.energySavingActive }
        powerFixture.isLowPowerModeEnabled = false
        NotificationCenter.default.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        await settle { !motion.energySavingActive && !motion.lowPower }
        for state in [ProcessInfo.ThermalState.serious, .fair, .critical, .nominal] {
            powerFixture.thermalState = state
            NotificationCenter.default.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
            let expected = state == .serious || state == .critical
            await settle { motion.energySavingActive == expected }
        }
        powerFixture.thermalState = .critical
        NotificationCenter.default.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        await settle { motion.energySavingActive }
        Defaults.value.send(false)
        await settle { !motion.energySavingActive }
        assert(!motion.suspended, "Thermal policy must not stop original media state tracking")

        powerFixture.thermalState = .nominal
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        assert(motion.suspended)
        Defaults.value.send(true)
        battery.info.isPluggedIn = false
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        assert(!motion.suspended && motion.energySavingActive, "Wake must re-read battery power")
        battery.send { $0.isPluggedIn = true }
        assert(!motion.energySavingActive, "Restoring normal conditions must restore enhanced mode")
        let count = updates
        for _ in 0..<100 { battery.send { $0.currentCapacity = 75 } }
        assert(updates == count, "Unchanged effective mode must publish no repeated view invalidations")
        assert(Defaults.value.value, "Temporary saving must not rewrite the user's preference")
        withExtendedLifetime(observer) {}
        print("PASS: opt-in default, battery/AC, full and paused charging, desktop/unknown power, low-power and thermal events, sleep/wake refresh, restoration and deduplicated publication")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='notch-smart-energy-') as directory:
    path = Path(directory)
    (path / 'Motion.swift').write_text('import SwiftUI\nimport Combine\n// One shared observer set' + motion)
    (path / 'Check.swift').write_text(check + '\nstruct BatteryInfo:' + battery)
    env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library',
                    str(path / 'Motion.swift'), str(path / 'Check.swift'), '-o', str(path / 'check')], env=env, check=True)
    subprocess.run([str(path / 'check')], check=True)
