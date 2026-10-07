#!/usr/bin/env python3
"""Run the production completion task through surface changes and cancellation."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'boringNotch/ContentView.swift').read_text()
body = source.split('.task(id: "\\(rocketRequested)-', 1)[1].split(') {', 1)[1].split('\n        .onChange(of: vm.anyDropZoneTargeting)', 1)[0].rsplit('\n        }', 1)[0]
check = r'''
import SwiftUI
import OSLog
@MainActor final class CodexActivity {
    static let log = Logger(subsystem: "notch-completion-check", category: "Codex")
    var completionSequence = 0
    var enabled = true
    var preview: String? = nil
}
enum CodexCompletionCue {
    static let flameOutDuration = 0.25
    static let ribbonDuration = 1.5
}
@MainActor final class Fixture {
    let codex = CodexActivity()
    var rocketSurfaceAvailable = false
    var running = false
    var rocketRequested: Bool { running && rocketSurfaceAvailable }
    var reducedMotion = false
    var handledCompletion = 0
    var rocketProgress: CGFloat = 0
    var flameActive = false
    var confettiActive = false { didSet { if confettiActive { emissions += 1 } } }
    var emissions = 0
    func animate() async {
BODY
    }
}
@main struct Check {
    @MainActor static func main() async throws {
        let f = Fixture()
        f.codex.completionSequence = 1
        await f.animate()
        assert(f.handledCompletion == 0 && f.emissions == 0, "Expanded notch consumed completion")
        f.rocketSurfaceAvailable = true
        var task = Task { await f.animate() }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel(); await task.value
        assert(f.handledCompletion == 0 && f.emissions == 0, "Cancelled setup consumed completion")
        task = Task { await f.animate() }
        try await Task.sleep(for: .milliseconds(500))
        assert(f.emissions == 1 && f.handledCompletion == 1, "Deferred completion did not play")
        task.cancel(); await task.value
        await f.animate()
        assert(f.emissions == 1, "Surface change replayed an already emitted cue")
        f.codex.completionSequence = 2
        f.running = true
        await f.animate()
        assert(f.handledCompletion == 1 && f.emissions == 1, "Running branch consumed pending completion")
        f.running = false
        await f.animate()
        assert(f.handledCompletion == 2 && f.emissions == 2)
        f.codex.completionSequence = 3
        f.reducedMotion = true
        await f.animate()
        assert(f.handledCompletion == 3 && f.emissions == 2)
        f.reducedMotion = false
        await f.animate()
        assert(f.emissions == 2, "Reduced-motion completion replayed later")
        f.codex.completionSequence = 4
        f.codex.enabled = false
        f.rocketSurfaceAvailable = false
        await f.animate()
        assert(f.handledCompletion == 4, "Disabled feature retained a cue for later")
        print("PASS: deferred completion, cancelled setup, exactly one emission, active work, reduced motion and disable")
    }
}
'''.replace('BODY', body)
with tempfile.TemporaryDirectory(prefix='notch-completion-check-') as directory:
    path = Path(directory)
    (path / 'Check.swift').write_text(check)
    env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', str(path / 'Check.swift'), '-o', str(path / 'check')], env=env, check=True)
    subprocess.run([str(path / 'check')], check=True)
