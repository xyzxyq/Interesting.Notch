#!/usr/bin/env python3
"""Compile/check production card shortcut preferences with an isolated defaults suite."""
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
fixture = r'''
import AppKit
@main @MainActor struct ModelCheck {
    static func main() {
        let suite = "codex-shortcut-check-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = CodexShortcuts(defaults: defaults)
        assert(model.label(for: .confirm) == "↩")
        func event(_ code: UInt16, _ mods: NSEvent.ModifierFlags = [], _ chars: String = "") -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0,
                windowNumber: 0, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                isARepeat: false, keyCode: code)!
        }
        assert(model.action(for: event(18, [.capsLock, .numericPad], "1")) == .option1)
        assert(model.action(for: event(76, .numericPad, "\r")) == .confirm)
        assert(model.action(for: event(83, .numericPad, "1")) == .option1)
        assert(model.action(for: event(82, .numericPad, "0")) == .option10)
        let newline = CodexKeyBinding(event: event(36, .shift, "\r"))
        let keypadNewline = CodexKeyBinding(event: event(76, [.shift, .numericPad], "\r"))
        assert(newline.isNewline && newline.reservedForEditing)
        assert(keypadNewline.isNewline && keypadNewline.reservedForEditing)
        assert(!CodexKeyBinding(event: event(36, [.shift, .command], "\r")).isNewline)
        assert(!model.set(newline, for: .confirm), "Shift+Enter must not be assigned to submission")
        assert(!model.set(keypadNewline, for: .option1), "Keypad Shift+Enter must also stay reserved")
        assert(!model.set(model.binding(for: .confirm), for: .close))
        assert(model.binding(for: .close)?.keyCode == 53)
        assert(!model.set(.init(keyCode: 8, modifiers: .command, characters: "c"), for: .close))
        assert(!model.set(.init(keyCode: 17, characters: "t"), for: .confirm))
        assert(!model.set(.init(keyCode: 18, modifiers: .shift, characters: "!"), for: .ignoreCurrent))
        assert(model.set(.init(keyCode: 17, modifiers: [.control, .option], characters: "t"), for: .confirm))
        assert(model.set(nil, for: .option1))
        let reloaded = CodexShortcuts(defaults: defaults)
        assert(reloaded.binding(for: .confirm)?.keyCode == 17)
        assert(reloaded.binding(for: .option1) == nil)
        model.isRecording = true
        assert(model.action(for: event(19, [], "2")) == nil)
        reloaded.reset()
        assert(reloaded.action(for: event(19, [], "2")) == .option2)
        assert(Set(CodexShortcutAction.allCases.compactMap(\.optionIndex)) == Set(0..<10))
        defaults.set(Data("invalid".utf8), forKey: "codexCardKeyboardBindings.v1")
        assert(CodexShortcuts(defaults: defaults).binding(for: .confirm)?.keyCode == 36)
        let unsafe = ["confirm": CodexKeyBinding(keyCode: 17, characters: "t")]
        defaults.set(try! JSONEncoder().encode(unsafe), forKey: "codexCardKeyboardBindings.v1")
        assert(CodexShortcuts(defaults: defaults).binding(for: .confirm)?.keyCode == 36)
        var legacy = Dictionary(uniqueKeysWithValues: CodexShortcutAction.allCases.map { ($0.rawValue, $0.defaultBinding) })
        legacy["confirm"] = keypadNewline
        let customClose = CodexKeyBinding(keyCode: 40, modifiers: [.control, .option], characters: "k")
        legacy["close"] = customClose
        legacy["option1"] = nil
        legacy["ignoreAll"] = nil
        defaults.set(try! JSONEncoder().encode(legacy), forKey: "codexCardKeyboardBindings.v1")
        let migrated = CodexShortcuts(defaults: defaults)
        assert(migrated.binding(for: .confirm) == nil, "Only the legacy Shift+Enter conflict should be cleared")
        assert(migrated.binding(for: .close) == customClose, "Migration must preserve unrelated custom keys")
        assert(migrated.binding(for: .option1) == nil && migrated.binding(for: .ignoreAll) == nil,
               "Migration must preserve intentionally cleared shortcuts")
        assert(migrated.binding(for: .option2) == CodexShortcutAction.option2.defaultBinding)
        assert(migrated.error != nil, "The user must be told about the conflicting shortcut")
        let persisted = try! JSONDecoder().decode([String: CodexKeyBinding].self,
            from: defaults.data(forKey: "codexCardKeyboardBindings.v1")!)
        assert(persisted["confirm"] == nil && persisted["close"] == customClose)
        let migratedReload = CodexShortcuts(defaults: defaults)
        assert(migratedReload.bindings == migrated.bindings && migratedReload.error == nil,
               "Migration should persist once without resetting preferences on the next launch")
        print("PASS: defaults, normalization, duplicate rejection, text editing protection, newline reservation/legacy migration, custom persistence, clearing, recording and reset")
    }
}
'''
env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
env.pop('SDKROOT', None)
with tempfile.TemporaryDirectory(prefix='notch-shortcut-check-') as folder:
    folder = Path(folder)
    source = folder / 'ModelCheck.swift'
    source.write_text(fixture)
    binary = folder / 'ModelCheck'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-D', 'EDGE_CHECKS',
        str(root / 'boringNotch/Shortcuts/CodexShortcuts.swift'), str(source), '-o', str(binary)],
        env=env, check=True)
    subprocess.run([str(binary)], env=env, check=True)
