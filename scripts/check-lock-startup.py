#!/usr/bin/env python3
"""Exercise production lock/startup guards without creating an application or windows."""
import os
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


launch = body('func applicationDidFinishLaunching(')
seed = next(line for line in launch.splitlines() if 'isScreenLocked = (CGSessionCopyCurrentDictionary()' in line)
assert launch.index('screenUnlockedObserver =') < launch.index(seed)
assert launch.index(seed) < launch.index('createBoringNotchWindow(')
startup_start = launch.index('        if !Defaults[.showOnAllDisplays] &&')
startup_end = launch.index('        setupDragDetectors()', startup_start) + len('        setupDragDetectors()')
startup = seed + '\n' + launch[startup_start:startup_end]
adjust = body('func adjustWindowPosition(').split('        if Defaults[.showOnAllDisplays] {', 1)[0]
detectors = body('private func setupDragDetectors(').split('        if Defaults[.showOnAllDisplays] {', 1)[0]
assert detectors.index('cleanupDragDetectors()') < detectors.index('guard ')
locked = body('func onScreenLocked(')
unlocked = body('func onScreenUnlocked(')
assert 'setupDragDetectors()' in locked and 'setupDragDetectors()' in unlocked

swift = '''import Foundation
enum Key { case showOnLockScreen, showOnAllDisplays, expandedDragDetection }
enum Defaults {
    static var values: [Key: Bool] = [:]
    static subscript(key: Key) -> Bool { values[key] ?? false }
}
var injectedSession: Any?
func CGSessionCopyCurrentDictionary() -> Any? { injectedSession }
enum NSScreen { static let main: Int? = 1; static let screens = [1, 2] }
final class Harness {
    var isScreenLocked = false
    let vm = 0
    var window: Int?
    var multiWindows = 0
    var detectorCount = 0
    var creations = 0
    var skyLight = false
    var windowCount: Int { multiWindows + (window == nil ? 0 : 1) }
    func createBoringNotchWindow(for screen: Int, with viewModel: Int) -> Int { creations += 1; return creations }
    func cleanupWindows() { window = nil; multiWindows = 0 }
    func cleanupDragDetectors() { detectorCount = 0 }
    func enableSkyLightOnAllWindows() { skyLight = true }
    func disableSkyLightOnAllWindows() { skyLight = false }
    func start() {
STARTUP
    }
    func adjustWindowPosition(changeAlpha: Bool = false) {
ADJUST
        if Defaults[.showOnAllDisplays] {
            if multiWindows == 0 { multiWindows = 2; creations += 2 }
        } else if window == nil { window = createBoringNotchWindow(for: 1, with: vm) }
    }
    func setupDragDetectors() {
DETECTORS
        detectorCount = Defaults[.showOnAllDisplays] ? 2 : 1
    }
    func onScreenLocked(_ notification: Notification) {
LOCKED
    }
    func onScreenUnlocked(_ notification: Notification) {
UNLOCKED
    }
}
@main struct Check {
    static func main() {
        let notification = Notification(name: .init("fixture"))
        for initialLock in [false, true] {
          for allow in [false, true] {
            for all in [false, true] {
              for expanded in [false, true] {
                Defaults.values = [.showOnLockScreen: allow, .showOnAllDisplays: all, .expandedDragDetection: expanded]
                injectedSession = ["CGSSessionScreenIsLocked": initialLock]
                let h = Harness(); h.start()
                let count = all ? 2 : 1
                let visible = !initialLock || allow
                assert(h.isScreenLocked == initialLock)
                assert(h.windowCount == (visible ? count : 0), "Startup policy bypassed")
                assert(h.detectorCount == (visible && expanded ? count : 0))
                h.onScreenLocked(notification)
                let created = h.creations
                for _ in 0..<3 { h.adjustWindowPosition(); h.setupDragDetectors() }
                assert(h.windowCount == (allow ? count : 0), "Display changes recreated locked windows")
                assert(h.creations == created, "Repeated display events should not add windows")
                assert(h.detectorCount == (allow && expanded ? count : 0))
                h.onScreenUnlocked(notification)
                assert(!h.isScreenLocked && h.windowCount == count)
                assert(h.detectorCount == (expanded ? count : 0), "Unlock must restore detectors")
                h.onScreenLocked(notification)
                assert(h.windowCount == (allow ? count : 0) && h.detectorCount == (allow && expanded ? count : 0))
              }
            }
          }
        }
        Defaults.values = [.showOnLockScreen: false, .expandedDragDetection: true]
        for session: Any? in [nil, [:] as [String: Any], ["CGSSessionScreenIsLocked": "unexpected"],
                              ["CGSSessionScreenIsLocked": NSNumber(value: false)]] {
            injectedSession = session
            let h = Harness(); h.start()
            assert(!h.isScreenLocked && h.windowCount == 1 && h.detectorCount == 1,
                   "Unavailable or unrecognized optional session state must fail open")
        }
        injectedSession = ["CGSSessionScreenIsLocked": NSNumber(value: true)]
        let h = Harness(); h.start()
        assert(h.isScreenLocked && h.creations == 0 && h.detectorCount == 0)
        print("PASS: source-derived locked startup, single/all displays, opt-in, detector cleanup, lock/unlock, repeat display events and optional-key fallback")
    }
}
'''
for key, value in [('STARTUP', startup), ('ADJUST', adjust), ('DETECTORS', detectors), ('LOCKED', locked), ('UNLOCKED', unlocked)]:
    swift = swift.replace('\n' + key + '\n', '\n' + value + '\n')
with tempfile.TemporaryDirectory(prefix='notch-lock-startup-') as directory:
    folder = Path(directory)
    (folder / 'Check.swift').write_text(swift)
    env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library',
                    str(folder / 'Check.swift'), '-o', str(folder / 'check')], env=env, check=True)
    subprocess.run([str(folder / 'check')], timeout=10, check=True)
