#!/usr/bin/env python3
"""Run MusicManager's actual idle scheduling method without launching the app."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'boringNotch/managers/MusicManager.swift').read_text()
method = source.split('    private func updateIdleState(state: Bool) {', 1)[1].split('    private var workItem:', 1)[0]
method = '    func updateIdleState(state: Bool) {' + method
harness = '''import Foundation
struct Defaults {
    enum Key { case waitInterval }
    static subscript(_ key: Key) -> Double { 0.12 }
}
func withAnimation(_ action: () -> Void) { action() }
@MainActor final class IdleCheck {
    var isPlaying = true
    var isPlayerIdle = false
    var debounceIdleTask: Task<Void, Never>?
''' + method + '''
}
@main struct Check {
    @MainActor static func main() async throws {
        let model = IdleCheck()
        model.isPlaying = false
        model.updateIdleState(state: false)
        try await Task.sleep(for: .milliseconds(20))
        model.isPlaying = true
        model.updateIdleState(state: true)
        // Pause again before the cancelled task has resumed. That old task must
        // not end this new pause's grace period early.
        model.isPlaying = false
        model.updateIdleState(state: false)
        try await Task.sleep(for: .milliseconds(30))
        assert(!model.isPlayerIdle, "Cancelled pause prematurely removed music")
        try await Task.sleep(for: .milliseconds(160))
        assert(model.isPlayerIdle, "Completed pause must enter idle")
        model.isPlaying = true
        model.updateIdleState(state: true)
        assert(!model.isPlayerIdle, "Resume must immediately present music")
        print("Music idle checks passed: rapid pause/resume/pause, grace period and resume")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='notch-idle-check-') as temp:
    swift = Path(temp) / 'Check.swift'
    binary = Path(temp) / 'check'
    swift.write_text(harness)
    env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], env=env, text=True).strip()
    subprocess.run(['xcrun', 'swiftc', '-sdk', sdk, '-parse-as-library', str(swift), '-o', str(binary)], env=env, check=True)
    subprocess.run([str(binary)], check=True)
