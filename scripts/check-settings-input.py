#!/usr/bin/env python3
"""Exercise the settings URL validator without starting the app or making requests."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'boringNotch/components/Settings/SettingsView.swift').read_text()
start = source.index('    private static func visualizerURL(')
end = source.index('\n    }', start) + len('\n    }')
method = source[start:end].replace('private static func', 'static func', 1)
checks = r'''
for input in ["", " \n ", "relative.json", "/tmp/animation.json", "file:///tmp/a.json",
              "javascript:alert(1)", "data:application/json,{}", "ftp://example.com/a.json",
              "https:///a.json", "https://", "http://[", "https://exa mple.com/a.json"] {
    assert(SettingsInput.visualizerURL(input) == nil, "Accepted invalid URL: \(input)")
}
let expected = "https://example.com/animation.json?version=2#intro"
assert(SettingsInput.visualizerURL(" \n" + expected + " \n")?.absoluteString == expected)
assert(SettingsInput.visualizerURL("http://localhost:8080/animation.json")?.host == "localhost")
assert(SettingsInput.visualizerURL("HTTPS://example.com/animation.json") != nil)
assert(SettingsInput.visualizerURL("https://example.com/中文.json") != nil)
print("Settings URL input passed: empty, relative, unsupported schemes, malformed hosts, whitespace, query, case and Unicode")
'''
with tempfile.TemporaryDirectory(prefix='notch-settings-input-') as temporary:
    check = Path(temporary) / 'SettingsInputChecks.swift'
    check.write_text('import Foundation\nenum SettingsInput {\n' + method + '\n}\n' + checks)
    subprocess.run(['xcrun', 'swift', str(check)], check=True)

assert 'guard !trimmedName.isEmpty, let validatedURL = Self.visualizerURL(url)' in source
assert '.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || Self.visualizerURL(url) == nil)' in source
assert '.onChange(of: NSScreen.screens)' not in source
assert '.onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification))' in source
assert 'Text("\\(speed, specifier: "%.1f")×")' in source
print('Settings wiring passed: disabled invalid input, guarded submission and view-scoped screen notification')
