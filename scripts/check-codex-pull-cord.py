#!/usr/bin/env python3
"""Check the production pull-cord artwork and anchor with isolated motion/anchor fixtures."""
import os
from pathlib import Path
import platform
import subprocess

root = Path(__file__).resolve().parents[1]
folder = root / 'build/pull-cord'
folder.mkdir(parents=True, exist_ok=True)
environment = folder / 'FixtureEnvironment.swift'
environment.write_text('''import AppKit
import SwiftUI

@MainActor final class NotchMotionEnvironment: ObservableObject {
    static let shared = NotchMotionEnvironment()
    @Published var suspended = false
}

struct CodexDropAnchor: NSViewRepresentable {
    let view: NSView
    var identifier = "codex-drop-anchor"
    func makeNSView(context: Context) -> NSView {
        view.identifier = NSUserInterfaceItemIdentifier(identifier)
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
''')
env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
env.pop('SDKROOT', None)
binary = folder / 'checks'
subprocess.run(['xcrun', 'swiftc', '-O', '-assert-config', 'Debug', '-swift-version', '5',
                '-target', f'{platform.machine()}-apple-macos14.0', str(environment),
                str(root / 'boringNotch/components/Notch/CodexPullCord.swift'),
                str(root / 'scripts/CodexPullCordChecks.swift'), '-o', str(binary)], env=env, check=True)
subprocess.run([str(binary), str(folder)], check=True)
