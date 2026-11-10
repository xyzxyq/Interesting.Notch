#!/usr/bin/env python3
"""Mount the production edge view and verify audio cannot schedule extra frames."""
from pathlib import Path
import os
import platform
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
edge = (root / 'boringNotch/components/Notch/MusicEdgeEffect.swift').read_text()
edge = edge.split('struct MusicEdgeSettings: View {', 1)[0].replace('#if !EDGE_CHECKS\n', '')
# Counters observe production bodies and Canvas calls; timing and drawing stay unchanged.
edge = edge.replace('Canvas { context, size in', 'Canvas { context, size in\n            recordFrame(energy: energy, phase: phase)')
edge = edge.replace('        let playback = MusicEdgePlayback(style: style,',
                    '        let _ = recordBody()\n        let playback = MusicEdgePlayback(style: style,')
shape = (root / 'boringNotch/components/Notch/NotchShape.swift').read_text()
shape = shape.split('#Preview', 1)[0].replace('import Defaults\n', '')
fixture = r'''
import AppKit
import Combine
import SwiftUI

@MainActor final class NotchMotionEnvironment: ObservableObject {
    static let shared = NotchMotionEnvironment()
    @Published var suspended = false
    @Published var lowPower = false
    static func decorativeFrameInterval(lowPower: Bool) -> Double { lowPower ? 0.1 : 0.05 }
}
@MainActor final class MusicManager: ObservableObject {
    static let shared = MusicManager()
    @Published var isMusicSource = true
    @Published var isPlaying = true
    let elapsedTime = 10.0
    let timestampDate = Date.now
    let playbackRate = 1.0
    let songDuration = 240.0
    let bundleIdentifier: String? = "fixture.music"
}
@MainActor final class MusicEdgeAudio: ObservableObject {
    static let shared = MusicEdgeAudio()
    @Published var energy = 0.0
    var demand = false
    func setDemand(_ consumer: UUID, bundleID: String?, active: Bool) { demand = active }
}
@MainActor var bodies = 0
@MainActor var energies: [Double] = []
@MainActor var phases: [Double] = []
@MainActor func recordBody() { bodies += 1 }
@MainActor func recordFrame(energy: Double, phase: Double) {
    energies.append(energy)
    phases.append(phase)
}
@main @MainActor struct Check {
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let suite = "local.notch.edge-cadence.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set("water", forKey: "musicEdgeStyle")
        defaults.set(true, forKey: "musicEdgeReactive")
        defer { defaults.removePersistentDomain(forName: suite) }
        let panel = NSPanel(contentRect: NSRect(x: 30, y: 30, width: 400, height: 120),
            styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: MusicEdgeEffect(shape: NotchShape())
            .frame(width: 300, height: 32).padding(40).defaultAppStorage(defaults))
        panel.contentView = hosting
        panel.orderFront(nil)
        defer { panel.orderOut(nil) }
        func advance(_ seconds: Double) {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
            hosting.layoutSubtreeIfNeeded()
        }
        func clear() { bodies = 0; energies = []; phases = [] }
        advance(0.4)
        assert(MusicEdgeAudio.shared.demand, "Visible playback must request audio")
        clear()
        var publications = 0
        let timer = Timer.scheduledTimer(withTimeInterval: 0.0137, repeats: true) { _ in
            MainActor.assumeIsolated {
                publications += 1
                MusicEdgeAudio.shared.energy = Double(publications % 100) / 100
            }
        }
        advance(2)
        assert(publications > 80, "Audio fixture must outpace the visual clock")
        assert(bodies == 0, "Audio invalidated the view body \(bodies) times")
        assert(energies.count >= 10 && energies.count <= 48,
            "20 Hz timeline produced \(energies.count) draws in 2 seconds")
        assert(Set(energies).count >= 8, "Timeline must read fresh audio samples")
        assert(phases.last! > phases.first!, "Audio phase must keep moving")
        print("Active: \(publications) audio publications, \(bodies) outer updates, \(energies.count) Canvas draws")
        NotchMotionEnvironment.shared.suspended = true
        advance(0.2)
        assert(!MusicEdgeAudio.shared.demand, "Sleep must release audio capture")
        clear()
        advance(0.3)
        assert(bodies == 0 && energies.isEmpty, "Suspended audio must not wake rendering")
        NotchMotionEnvironment.shared.suspended = false
        advance(0.3)
        assert(MusicEdgeAudio.shared.demand && !energies.isEmpty, "Wake must restore drawing and demand")
        timer.invalidate()
        let phase = MusicEdgePhase()
        let start = Date(timeIntervalSinceReferenceDate: 1234)
        phase.update(target: 1, paused: false, at: start)
        let changed = start.addingTimeInterval(2)
        let before = phase.value(at: changed)
        phase.update(target: 3, paused: false, at: changed)
        assert(abs(phase.value(at: changed) - before) < 1e-10)
        let sleeping = changed.addingTimeInterval(1)
        let frozen = phase.value(at: sleeping)
        phase.update(target: 3, paused: true, at: sleeping)
        assert(phase.value(at: sleeping.addingTimeInterval(3600)) == frozen)
        phase.update(target: 1, paused: false, at: sleeping.addingTimeInterval(3600))
        assert(phase.value(at: sleeping.addingTimeInterval(3600)) == frozen)
        print("PASS: one draw clock, fresh amplitude, sleep/wake capture, continuous phase")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='notch-edge-cadence-') as directory:
    path = Path(directory)
    for name, content in [('Edge.swift', edge), ('Shape.swift', shape), ('Check.swift', fixture)]:
        (path / name).write_text(content)
    env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-target',
                    f'{platform.machine()}-apple-macos14.0',
                    '-external-plugin-path', env['DEVELOPER_DIR'] + '/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins#' + env['DEVELOPER_DIR'] + '/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-plugin-server',
                    str(path / 'Edge.swift'), str(path / 'Shape.swift'), str(path / 'Check.swift'),
                    str(root / 'boringNotch/models/CompactLyrics.swift'), '-o', str(path / 'check')],
                   env=env, check=True)
    subprocess.run([str(path / 'check')], check=True)
