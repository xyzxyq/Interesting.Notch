import AppKit
import SwiftUI

// Local card bindings are intentionally never registered as global hotkeys.
enum CodexShortcutAction: String, CaseIterable {
    case confirm, close, ignoreCurrent, ignoreAll, nextRequest, previousRequest, nextOption, previousOption
    case option1, option2, option3, option4, option5, option6, option7, option8, option9, option10

    var optionIndex: Int? {
        guard rawValue.hasPrefix("option"), let number = Int(rawValue.dropFirst(6)) else { return nil }
        return number - 1
    }
    var title: String {
        if let index = optionIndex { return "选择第 \(index + 1) 个选项" }
        switch self {
        case .confirm: return "开始输入 / 确认回复"
        case .close: return "收起交互卡片"
        case .ignoreCurrent: return "忽略当前提醒"
        case .ignoreAll: return "忽略全部提醒"
        case .nextRequest: return "下一条提醒"
        case .previousRequest: return "上一条提醒"
        case .nextOption: return "下一个选项"
        case .previousOption: return "上一个选项"
        default: return ""
        }
    }
    func allows(_ binding: CodexKeyBinding) -> Bool {
        if optionIndex != nil || self == .nextOption || self == .previousOption { return true }
        let functionKeys: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
        return !binding.modifiers.intersection([.command, .control, .option]).isEmpty
            || [36, 53].contains(binding.keyCode) || functionKeys.contains(binding.keyCode)
    }
    var defaultBinding: CodexKeyBinding {
        if let index = optionIndex {
            let codes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]
            return CodexKeyBinding(keyCode: codes[index], characters: index == 9 ? "0" : "\(index + 1)")
        }
        switch self {
        case .confirm: return .init(keyCode: 36, characters: "↩")
        case .close: return .init(keyCode: 53, characters: "⎋")
        case .ignoreCurrent: return .init(keyCode: 51, modifiers: [.command], characters: "⌫")
        case .ignoreAll: return .init(keyCode: 51, modifiers: [.command, .shift], characters: "⌫")
        case .nextRequest: return .init(keyCode: 30, modifiers: [.control], characters: "]")
        case .previousRequest: return .init(keyCode: 33, modifiers: [.control], characters: "[")
        case .nextOption: return .init(keyCode: 125, characters: "↓")
        case .previousOption: return .init(keyCode: 126, characters: "↑")
        default: preconditionFailure("Option defaults handled above")
        }
    }
}

struct CodexKeyBinding: Codable, Equatable {
    let keyCode: UInt16
    let modifierBits: UInt
    let characters: String
    static let modifierMask: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
    var modifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifierBits) }

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags = [], characters: String) {
        let keypad: [UInt16: UInt16] = [76: 36, 82: 29, 83: 18, 84: 19, 85: 20, 86: 21, 87: 23, 88: 22, 89: 26, 91: 28, 92: 25]
        self.keyCode = keypad[keyCode] ?? keyCode
        self.modifierBits = modifiers.intersection(Self.modifierMask).rawValue
        self.characters = characters
    }
    init(event: NSEvent) {
        self.init(keyCode: event.keyCode, modifiers: event.modifierFlags, characters: event.charactersIgnoringModifiers ?? "")
    }
    func matches(_ other: Self) -> Bool { keyCode == other.keyCode && modifierBits == other.modifierBits }
    var label: String {
        let symbols: [UInt16: String] = [36: "↩", 48: "⇥", 49: "空格", 51: "⌫", 53: "⎋", 117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑"]
        let functionKeys: [UInt16: Int] = [122: 1, 120: 2, 99: 3, 118: 4, 96: 5, 97: 6, 98: 7, 100: 8, 101: 9, 109: 10, 103: 11, 111: 12, 105: 13, 107: 14, 113: 15, 106: 16, 64: 17, 79: 18, 80: 19, 90: 20]
        let key = symbols[keyCode] ?? functionKeys[keyCode].map { "F\($0)" } ?? (characters.isEmpty ? "键 \(keyCode)" : characters.uppercased())
        return (modifiers.contains(.control) ? "⌃" : "") + (modifiers.contains(.option) ? "⌥" : "")
            + (modifiers.contains(.shift) ? "⇧" : "") + (modifiers.contains(.command) ? "⌘" : "") + key
    }
    var isValid: Bool {
        keyCode <= 127 && modifierBits == modifiers.intersection(Self.modifierMask).rawValue && characters.count <= 16
    }
    var isNewline: Bool { keyCode == 36 && modifiers == [.shift] }
    var reservedForEditing: Bool {
        // Preserve common text editing, app switching and system input shortcuts.
        isNewline || (modifiers.contains(.command) && [0, 6, 7, 8, 9, 12, 48, 49].contains(keyCode))
            || (modifiers.contains(.control) && keyCode == 49)
            || (modifiers.isEmpty && keyCode == 48)
    }
}

@MainActor final class CodexShortcuts: ObservableObject {
    static let shared = CodexShortcuts()
    @Published private(set) var bindings: [String: CodexKeyBinding]
    @Published var error: String?
    @Published var isRecording = false
    private let defaults: UserDefaults
    private let preferenceKey = "codexCardKeyboardBindings.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let initial = Dictionary(uniqueKeysWithValues: CodexShortcutAction.allCases.map { ($0.rawValue, $0.defaultBinding) })
        if let data = defaults.data(forKey: preferenceKey),
           let stored = try? JSONDecoder().decode([String: CodexKeyBinding].self, from: data),
           stored.allSatisfy({ entry in
               guard let action = CodexShortcutAction(rawValue: entry.key) else { return false }
               return entry.value.isValid && (!entry.value.reservedForEditing || entry.value.isNewline) && action.allows(entry.value)
           }) {
            var accepted: [String: CodexKeyBinding] = [:]
            for action in CodexShortcutAction.allCases {
                if let binding = stored[action.rawValue], !binding.isNewline, !accepted.values.contains(where: { $0.matches(binding) }) {
                    accepted[action.rawValue] = binding
                }
            }
            bindings = accepted
            if stored.values.contains(where: \.isNewline) {
                persist()
                error = "Shift+Enter 已保留为换行键；与它冲突的旧快捷键已清除，其他设置保持不变。"
            }
        } else { bindings = initial }
    }
    func binding(for action: CodexShortcutAction) -> CodexKeyBinding? { bindings[action.rawValue] }
    func label(for action: CodexShortcutAction) -> String { binding(for: action)?.label ?? "未设置" }
    func action(for event: NSEvent) -> CodexShortcutAction? {
        guard event.type == .keyDown, !isRecording else { return nil }
        let candidate = CodexKeyBinding(event: event)
        return CodexShortcutAction.allCases.first { binding(for: $0)?.matches(candidate) == true }
    }
    @discardableResult func set(_ binding: CodexKeyBinding?, for action: CodexShortcutAction) -> Bool {
        if let binding {
            guard binding.isValid, !binding.reservedForEditing else {
                error = "此组合用于文字编辑或系统操作，请选择其他按键。"; return false
            }
            guard action.allows(binding) else {
                error = "此操作在输入时也会生效，请使用 ⌘ / ⌃ / ⌥ 组合键、Enter、Esc 或功能键。"; return false
            }
            if let conflict = CodexShortcutAction.allCases.first(where: { $0 != action && self.binding(for: $0)?.matches(binding) == true }) {
                error = "已用于“\(conflict.title)”，请先更改或清除该快捷键。"; return false
            }
        }
        bindings[action.rawValue] = binding
        persist(); error = nil
        return true
    }
    func reset() {
        bindings = Dictionary(uniqueKeysWithValues: CodexShortcutAction.allCases.map { ($0.rawValue, $0.defaultBinding) })
        persist(); error = nil
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(bindings) { defaults.set(data, forKey: preferenceKey) }
    }
}

struct CodexLocalShortcutRecorder: NSViewRepresentable {
    var label: String
    var accessibilityName: String
    var record: (CodexKeyBinding) -> Bool
    var recordingChanged: (Bool) -> Void
    final class RecorderButton: NSButton {
        var bindingLabel = ""
        var record: ((CodexKeyBinding) -> Bool)?
        var recordingChanged: ((Bool) -> Void)?
        private var recording = false
        private var keyObservation: NSObjectProtocol?
        deinit { if let keyObservation { NotificationCenter.default.removeObserver(keyObservation) } }
        override var acceptsFirstResponder: Bool { true }
        @objc func toggleRecording() {
            if recording { endRecording(); window?.makeFirstResponder(nil) }
            else if window?.makeFirstResponder(self) == true {
                recording = true; title = "请按快捷键…"; recordingChanged?(true)
                keyObservation = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                    self?.endRecording()
                }
            }
        }
        private func endRecording() {
            guard recording else { return }
            recording = false; title = bindingLabel
            if let keyObservation { NotificationCenter.default.removeObserver(keyObservation) }
            keyObservation = nil
            recordingChanged?(false)
        }
        override func resignFirstResponder() -> Bool { endRecording(); return super.resignFirstResponder() }
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { endRecording() }
            super.viewWillMove(toWindow: newWindow)
        }
        private func capture(_ event: NSEvent) -> Bool {
            guard recording else { return false }
            if !event.isARepeat, record?(CodexKeyBinding(event: event)) == true {
                endRecording(); window?.makeFirstResponder(nil)
            }
            return true
        }
        override func keyDown(with event: NSEvent) {
            if !capture(event) { super.keyDown(with: event) }
        }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if window?.firstResponder === self, capture(event) { return true }
            return super.performKeyEquivalent(with: event)
        }
        func updateLabel(_ value: String) { bindingLabel = value; if !recording { title = value } }
    }
    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton(title: label, target: nil, action: nil)
        button.bezelStyle = .rounded
        button.target = button; button.action = #selector(RecorderButton.toggleRecording)
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }
    func updateNSView(_ view: RecorderButton, context: Context) {
        view.updateLabel(label); view.record = record; view.recordingChanged = recordingChanged
        view.setAccessibilityLabel(accessibilityName)
        view.toolTip = "点击后按下组合键；再次点击或移开焦点取消录制。"
    }
}
