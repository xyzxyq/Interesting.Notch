#!/usr/bin/env python3
"""Check isolated production card lifecycle; --preview [--cord --cord-style donut] shows a local fixture."""
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys

cord_style = None
if '--cord-style' in sys.argv:
    index = sys.argv.index('--cord-style')
    if index + 1 >= len(sys.argv) or sys.argv[index + 1].startswith('--'):
        raise SystemExit('--cord-style requires classic, donut, orbit, or crystal')
    cord_style = sys.argv[index + 1]

root = Path(__file__).resolve().parents[1]
folder = root / 'build/components-20261029'
folder.mkdir(parents=True, exist_ok=True)
activity = (Path(sys.argv[sys.argv.index('--activity-source') + 1]) if '--activity-source' in sys.argv else root / 'boringNotch/managers/CodexActivity.swift').read_text()
activity = activity.replace('private(set) ', '').replace('private ', '').replace('UserDefaults.standard', 'testDefaults')
# The production lifecycle and views are retained; the fixture never polls or sends answers.
activity = activity.replace('guard enabled && !suspended else {', 'guard false else {')
activity = activity.replace('let (data, response) = try await URLSession.shared.data(for: request)', 'throw URLError(.unsupportedURL)\n                let (data, response) = try await URLSession.shared.data(for: request)')
content = (root / 'boringNotch/ContentView.swift').read_text()

def property(name):
    start = content.index('    private var ' + name + ':')
    begin = content.index('{', start)
    depth = 1
    end = begin + 1
    while depth:
        depth += (content[end] == '{') - (content[end] == '}')
        end += 1
    return content[start:end].replace('private ', '')

width = content.split('    private var closedPlaybackContent: some View {', 1)[1].split('        return ZStack', 1)[0]
slot = (root / 'boringNotch/components/Music/CompactLyricsView.swift').read_text().split('    static let slotWidth:', 1)[1].split('\n', 1)[0]
fixture = r'''
import QuartzCore

let suite = "notch-interaction-check-" + UUID().uuidString
let testDefaults = UserDefaults(suiteName: suite)!
struct LayoutVM {
    var effectiveClosedNotchHeight: CGFloat = 32
    var closedNotchSize = CGSize(width: 200, height: 32)
    var hideOnClosed = false
}
struct LayoutFixture {
    var vm = LayoutVM()
    var compactLyricsMode = false
    var musicPresented = false
    var rocketPresented = true
    var idleFacePresented = false
    let cornerRadiusInsets = (closed: (top: CGFloat(6), bottom: CGFloat(14)), opened: 0)
PROPERTIES
    func width() -> CGFloat {
WIDTH
        return width
    }
}
enum CompactLyricsLayout { static let slotWidth:SLOT }
final class KeyboardEditorProbe: NSTextView {
    var marked = false
    var received: [UInt16] = []
    override func hasMarkedText() -> Bool { marked }
    override func keyDown(with event: NSEvent) { received.append(event.keyCode) }
}
final class FlippedAnchorView: NSView { override var isFlipped: Bool { true } }
@MainActor enum CardRevealProbe {
    static var enabled = false
    static var values: [CGFloat] = []
    static func record(_ progress: CGFloat) { if enabled { values.append(progress) } }
}
struct DropFixture: View {
    @State private var surface: CGFloat = 0
    @ObservedObject var activity: CodexActivity
    var body: some View {
        NotchShape(liquid: surface).fill(.black).frame(width: 260, height: 32)
            .overlay(alignment: .bottom) {
                if activity.reminderStyle == .pullCord {
                    CodexPullCordButton(waiting: activity.waiting, count: activity.previewCount,
                        isOpen: activity.cardPresented, style: activity.pullCordStyle,
                        waitingSince: activity.fishWaitingSince, action: activity.showRequests).offset(y: 82)
                } else {
                    CodexDropButton(waiting: activity.waiting, count: activity.previewCount, action: activity.showRequests, surface: $surface).offset(y: 82)
                }
            }.frame(width: 420, height: 160, alignment: .top)
    }
}
@main @MainActor struct InteractionCheck {
    static func main() throws {
        _ = NSApplication.shared
        // Synthetic reopen events lack the user activation of a real reminder click.
        let visualPreview = CommandLine.arguments.contains("--preview") || CommandLine.arguments.contains("--profile")
        NSApp.setActivationPolicy(visualPreview ? .accessory : .regular)
        NSApp.finishLaunching()
        for (progress, scale) in [(CGFloat(0), CGFloat(1)), (1, 1), (1, 1.7)] {
            let renderer = ImageRenderer(content: CodexLiquidDrop(progress: progress, reduced: true, volumeScale: scale))
            renderer.scale = 2
            guard let image = renderer.cgImage else { fatalError("Missing waterdrop render") }
            let bitmap = NSBitmapImageRep(cgImage: image)
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide where progress == 0 || x == 0 || x == bitmap.pixelsWide - 1 || y == bitmap.pixelsHigh - 1 {
                    assert(bitmap.colorAt(x: x, y: y)!.alphaComponent < 0.01,
                           "Hidden drop or maximum-volume shadow leaks at the canvas boundary")
                }
            }
        }
        assert(CodexQuestion.validAnswer(String(repeating: "答", count: 4000)))
        assert(!CodexQuestion.validAnswer("   "))
        assert(!CodexQuestion.validAnswer(String(repeating: "👨‍👩‍👧‍👦", count: 1000)), "Client must use the bridge's Unicode-scalar limit")
        testDefaults.set("NO", forKey: "codexRocketEnabled")
        assert(!CodexActivity().enabled, "Launch-only idle control must override defaults")
        testDefaults.removeObject(forKey: "codexRocketEnabled")
        let activity = CodexActivity()
        assert(activity.enabled, "Missing preference must preserve the enabled default")
        activity.motionObservation?.cancel(); activity.motionObservation = nil
        let sample = CodexTask(id: "11111111-1111-4111-8111-111111111111", title: "Fixture", state: "waiting", detail: nil)
        activity.tasks = [sample]
        activity.removeRequest(sample)
        assert(!activity.waiting)
        activity.reconcileRequests([])
        activity.tasks = []
        activity.tasks = [sample]
        assert(activity.waiting, "A second approval in the same task stayed hidden")
        activity.submitting.insert(sample.identity)
        activity.replyErrors[sample.identity] = "fixture"
        activity.reconcileRequests([])
        assert(activity.submitting.isEmpty && activity.replyErrors.isEmpty)
        var layout = LayoutFixture()
        let compact = layout.width()
        layout.compactLyricsMode = true
        assert(layout.width() == compact, "Old music metadata widened the Codex-only rocket")
        layout.musicPresented = true
        assert(layout.width() > compact, "Music needs its original lyric slots")
        activity.preview = "waiting"
        activity.tasks = []
        let screen = NSScreen.main!.frame
        let anchor = CGPoint(x: screen.midX, y: screen.maxY - 10 - 32 - 67)
        func advance(_ seconds: Double) {
            let end = Date(timeIntervalSinceNow: seconds)
            while Date() < end {
                if let event = NSApp.nextEvent(matching: .any, until: min(end, Date(timeIntervalSinceNow: 0.01)), inMode: .default, dequeue: true) {
                    NSApp.sendEvent(event)
                }
                RunLoop.main.run(until: min(end, Date(timeIntervalSinceNow: 0.001)))
            }
        }
        // This style belongs only to the UUID-scoped fixture defaults, never the running app.
        if CommandLine.arguments.contains("--preview") || CommandLine.arguments.contains("--profile") {
            if CommandLine.arguments.contains("--cord") || CommandLine.arguments.contains("--cord-style") {
                activity.reminderStyle = .pullCord
            }
            if let index = CommandLine.arguments.firstIndex(of: "--cord-style") {
                guard index + 1 < CommandLine.arguments.count,
                      let style = CodexPullCordStyle(rawValue: CommandLine.arguments[index + 1]) else {
                    fatalError("--cord-style requires classic, donut, orbit, or crystal")
                }
                activity.pullCordStyle = style
            }
        }
        func reminderAnchor(_ panel: NSPanel) -> CGPoint {
            let identifier = activity.reminderStyle == .pullCord ? "codex-cord-anchor" : "codex-drop-anchor"
            func find(_ view: NSView) -> NSView? {
                if view.identifier?.rawValue == identifier { return view }
                return view.subviews.lazy.compactMap { find($0) }.first
            }
            panel.contentView!.layoutSubtreeIfNeeded()
            guard let view = find(panel.contentView!) else { fatalError("Missing mounted reminder anchor") }
            return activity.reminderStyle == .pullCord ? CodexPullCordButton.topAnchor(view: view)
                : CodexDropButton.bottomAnchor(view: view, count: activity.previewCount)
        }
        if CommandLine.arguments.contains("--preview") {
            let drop = NSPanel(contentRect: CGRect(x: screen.midX - 210, y: screen.maxY - 170, width: 420, height: 160),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            drop.title = "Notch · \(activity.reminderStyle.title)预览"
            drop.isOpaque = false; drop.backgroundColor = .clear; drop.hasShadow = false
            drop.level = .mainMenu + 3; drop.isReleasedWhenClosed = false
            drop.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            drop.contentView = NSHostingView(rootView: DropFixture(activity: activity))
            drop.orderFront(nil)
            let attachedAnchor = reminderAnchor(drop)
            activity.showRequests(anchor: attachedAnchor)
            // Keep visual inspection stable across tool focus changes; normal tests retain production dismissal.
            (activity.window as? CodexRequestPanel)?.onCancel = nil
            let geometry: [String: Double] = ["dropBottom": attachedAnchor.y, "reminderAnchor": attachedAnchor.y,
                "cardTop": activity.window!.frame.maxY - CodexCardReveal.panelInset - activity.panelTopInset]
            try! JSONSerialization.data(withJSONObject: geometry).write(to: URL(fileURLWithPath: "/tmp/notch-attachment-geometry.json"))
            if CommandLine.arguments.contains("--handoff-preview") {
                advance(0.04)
                let genie = activity.genie
                if genie.isAnimating {
                    let delay = max(0, genie.startedAt + genie.runningDuration * Double((1 + CodexGenieGeometry.handoffPhase) / 2) - CACurrentMediaTime())
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        guard let layer = genie.overlay?.layer else { return }
                        let pausedTime = layer.convertTime(CACurrentMediaTime(), from: nil)
                        CATransaction.begin(); CATransaction.setDisableActions(true)
                        layer.speed = 0; layer.timeOffset = pausedTime
                        CATransaction.commit()
                        genie.completionWork?.cancel(); genie.completionWork = nil
                        let record: [String: Any] = ["phase": "frozen-handoff-preview",
                            "progress": Double(genie.progress(at: CACurrentMediaTime())),
                            "hostAlpha": activity.window?.contentView?.alphaValue ?? -1,
                            "overlayOpacity": layer.presentation().map { Double($0.opacity) } as Any? ?? NSNull()]
                        let data = try! JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
                        FileHandle.standardOutput.write(Data("DIAG ".utf8) + data + Data("\n".utf8))
                        try! data.write(to: URL(fileURLWithPath: "/tmp/notch-handoff-preview.json"))
                    }
                }
            }
            withExtendedLifetime(drop) { NSApp.run() }
            testDefaults.removePersistentDomain(forName: suite)
            return
        }
        let anchorPanel = NSPanel(contentRect: CGRect(x: 200, y: 200, width: 200, height: 200),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
        anchorPanel.isReleasedWhenClosed = false
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        anchorPanel.contentView = container
        for view in [NSView(frame: CGRect(x: 30, y: 40, width: 64, height: 82)),
                     FlippedAnchorView(frame: CGRect(x: 30, y: 40, width: 64, height: 82))] {
            container.addSubview(view)
            let bottom = CodexDropButton.bottomAnchor(view: view, count: 1)
            assert(abs(bottom.y - 255) < 0.5 && abs(bottom.x - 262) < 0.5,
                   "Flipped and unflipped mounted anchors must share the same screen bottom")
            assert(CodexDropButton.bottomAnchor(view: view, count: 4).y < bottom.y,
                   "A larger multi-request drop must move the card down")
            view.removeFromSuperview()
        }
        for opening in ["initial", "cached"] {
            CardRevealProbe.values.removeAll(keepingCapacity: true)
            CardRevealProbe.enabled = true
            activity.showRequests(anchor: anchor)
            advance(CodexCardReveal.duration + 0.15)
            let values = CardRevealProbe.values
            assert(values.contains { $0 > 0.75 && $0 < 0.999 }
                   && values.contains { $0 > 0.35 && $0 < 0.65 }
                   && values.contains { $0 > 0.001 && $0 < 0.25 }
                   && values.contains { $0 == 0 },
                   "\(opening) open must render early, middle and late reveal progress, not only the final state")
            let settledCount = values.count
            advance(0.12)
            assert(CardRevealProbe.values.count == settledCount,
                   "\(opening) card reveal kept redrawing after settling")
            CardRevealProbe.enabled = false
            activity.closeRequests()
            advance(0.5)
        }
        activity.showRequests(anchor: anchor)
        advance(0.06)
        assert(activity.window!.animationBehavior == .none,
               "AppKit window ordering must not obscure the custom card reveal")
        assert(abs(activity.window!.frame.maxY - CodexCardReveal.panelInset - (anchor.y - 6)) < 0.5,
               "Card must attach six points below the droplet bottom")
        activity.closeRequests() // Escape/close during the reveal must work.
        advance(0.5)
        assert(activity.window?.isVisible == false && !activity.panelReady)
        activity.showRequests(anchor: anchor)
        advance(0.07)
        activity.closeRequests()
        advance(0.03)
        activity.showRequests(anchor: anchor) // Reopen while the previous close is in flight.
        advance(0.6)
        assert(activity.window?.isVisible == true && activity.panelReady && activity.windowDissolve == 0)
        activity.closeRequests()
        advance(0.5)
        activity.showRequests(anchor: anchor)
        activity.closeRequests() // Close before the delayed reveal begins.
        activity.showRequests(anchor: anchor)
        advance(0.5)
        assert(activity.windowReveal == 0 && activity.panelReady, "Immediate reopen retained the hidden reveal mask")
        activity.clearRequests()
        advance(0.5)
        assert(activity.window == nil && !activity.waiting, "Ignore must release the card and hide its droplet")
        func key(_ code: UInt16, _ chars: String = "", modifiers: NSEvent.ModifierFlags = [], repeatKey: Bool = false) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: activity.window?.windowNumber ?? 0,
                context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: repeatKey, keyCode: code)!
        }
        let bindings = CodexShortcuts.shared
        bindings.reset()
        for action in CodexShortcutAction.allCases {
            let binding = action.defaultBinding
            assert(bindings.action(for: key(binding.keyCode, binding.characters, modifiers: binding.modifiers)) == action)
        }
        assert(bindings.action(for: key(76, "\r", modifiers: [.numericPad])) == .confirm, "Keypad Enter must confirm")
        assert(bindings.action(for: key(18, "1", modifiers: [.capsLock])) == .option1, "Caps Lock must not break digit selection")
        assert(!bindings.set(.init(keyCode: 36, characters: "\r"), for: .close), "Local duplicate must be rejected")
        assert(bindings.set(.init(keyCode: 40, modifiers: [.command, .option], characters: "k"), for: .close))
        assert(CodexShortcuts(defaults: testDefaults).binding(for: .close)?.keyCode == 40, "Custom binding must persist")
        assert(bindings.set(nil, for: .close))
        assert(CodexShortcuts(defaults: testDefaults).binding(for: .close) == nil, "Cleared binding must stay cleared")
        bindings.reset()
        let modelRows = try JSONDecoder().decode([CodexTask].self, from: Data(#"[{"id":"33333333-3333-4333-8333-333333333333","title":"A","state":"waiting","hostId":"local","model":"gpt-6-astra","reasoningEffort":"ultra","serviceTier":"priority","pendingQuestionIds":["a"]},{"id":"33333333-3333-4333-8333-333333333333","title":"B","state":"waiting","hostId":"remote","model":"gpt-6-sol","reasoningEffort":"low","serviceTier":"default","pendingQuestionIds":["b"]}]"#.utf8))
        let modelReminders = CodexActivity.reminders(in: modelRows)
        assert(modelReminders[0].model == "gpt-6-astra" && modelReminders[0].reasoningEffort == "ultra" && modelReminders[0].isFastMode)
        assert(modelReminders[1].model == "gpt-6-sol" && modelReminders[1].reasoningEffort == "low" && !modelReminders[1].isFastMode)
        assert(modelReminders[0].identity != modelReminders[1].identity, "Model metadata must stay with its host and conversation")
        var unknownSpeed = modelRows[0]; unknownSpeed.serviceTier = nil
        assert(!unknownSpeed.isFastMode, "Missing speed metadata must not imply fast mode")
        var draft = CodexAnswerDraft()
        assert(draft.confirmation(editing: false) == .edit)
        assert(draft.confirmation(editing: true) == .cancelEditing)
        draft.text = "自由回答 123"
        assert(draft.confirmation(editing: false) == .edit, "Unfocused free text must first enter editing")
        assert(draft.confirmation(editing: true) == .submit)
        assert(!draft.select(1, options: ["第一项", "第二项", "其他"]))
        assert(draft.selection == 1 && draft.text == "第二项" && draft.confirmation(editing: false) == .submit)
        assert(!draft.select(9, options: ["第一项"]) && draft.selection == 1, "Out-of-range option must not change the answer")
        assert(!draft.select(1, options: ["第一项", "第二项", "其他"]))
        assert(draft.selection == nil && draft.text.isEmpty && draft.confirmation(editing: false) == .edit,
               "Selecting the same option again must clear it and allow Enter to begin custom input")
        assert(!draft.select(1, options: ["第一项", "第二项"], toggle: false))
        assert(!draft.select(1, options: ["第一项", "第二项"], toggle: false) && draft.selection == 1,
               "Arrow navigation must retain its selected option")
        assert(draft.select(2, options: ["第一项", "第二项", "其他"]))
        assert(draft.text.isEmpty && draft.selection == nil)
        draft.text = " \n "
        assert(draft.confirmation(editing: true) == .cancelEditing)

        draft.text = String(repeating: "答", count: 4001)
        assert(draft.confirmation(editing: true) == .none, "An overlong draft must remain editable, not cancel editing")

        // Use the actual mounted production row, not a second implementation of dispatch.
        activity.preview = "waiting"; activity.previewCount = 1
        activity.showRequests(anchor: anchor)
        advance(0.65)
        var panel = activity.window as! CodexRequestPanel
        assert(panel.isKeyWindow && activity.panelReady, "Key=\(panel.isKeyWindow) ready=\(activity.panelReady) active=\(NSApp.isActive) visible=\(panel.isVisible) dissolve=\(activity.windowDissolve)")
        assert(activity.editingRequestID == nil, "Opening must start in option-browsing mode")
        assert(!(panel.firstResponder is NSTextView), "Normal opening must focus the card, not an automatic field editor")
        let firstPreview = activity.keyboardRequest!
        panel.sendEvent(key(19, "2"))
        assert(activity.answerDrafts[firstPreview.identity]?.selection == 1, "Normal opening must accept digits without test-only focus resets")
        activity.closeRequests(); advance(0.5)
        activity.showRequests(anchor: anchor); advance(0.65)
        assert(activity.editingRequestID == nil && panel.isKeyWindow, "Reopening must restore browsing mode and key status")
        assert(!(panel.firstResponder is NSTextView), "Reopening must not restore the answer field editor")
        panel.sendEvent(key(18, "1"))
        assert(activity.answerDrafts[activity.keyboardRequest!.identity]?.selection == 0)
        panel.sendEvent(key(18, "1"))
        assert(activity.answerDrafts[activity.keyboardRequest!.identity]?.selection == nil)
        assert(activity.answerDrafts[activity.keyboardRequest!.identity]?.text == "")
        panel.sendEvent(key(18, "1"))
        panel.sendEvent(key(36, "\r")) // No runloop/render between these two events.
        assert(activity.previewCount == 0, "Rapid digit then Enter lost the selection or confirmation")
        panel.sendEvent(key(36, "\r", repeatKey: true))
        assert(activity.previewCount == 0, "A held confirmation key must not consume another reminder")
        advance(0.5)
        assert(activity.window == nil && panel.contentView == nil,
               "Answering the last preview request must release the completed panel")

        activity.preview = "waiting"; activity.previewCount = 2
        activity.showRequests(anchor: anchor)
        advance(0.65)
        panel = activity.window as! CodexRequestPanel
        panel.sendEvent(key(51, "", modifiers: [.command]))
        assert(activity.previewCount == 1 && activity.waiting, "Ignore-current must retain remaining reminders")
        panel.sendEvent(key(53))
        advance(0.5)
        assert(activity.waiting && !panel.isVisible, "Close must retain the droplet")
        activity.showRequests(anchor: anchor)
        advance(0.65)

        let editor = KeyboardEditorProbe(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        panel.contentView!.addSubview(editor)
        assert(panel.makeFirstResponder(editor))
        let currentPreview = activity.keyboardRequest!
        assert(activity.editingRequestID == nil)
        panel.sendEvent(key(20, "3"))
        assert(editor.received.isEmpty && activity.answerDrafts[currentPreview.identity]?.selection == 2,
               "An automatically restored NSTextView must not steal option digits before deliberate editing")
        activity.beginAnswerEditing(currentPreview)
        advance(0.05)
        assert(panel.makeFirstResponder(editor))
        var intercepted: [CodexShortcutAction] = []
        let originalHandler = panel.onShortcut
        panel.onShortcut = { intercepted.append($0); return true }
        panel.sendEvent(key(18, "1"))
        assert(editor.received == [18] && intercepted.isEmpty, "Typing digits must not select options")
        editor.marked = true
        panel.sendEvent(key(36, "\r"))
        panel.sendEvent(key(53))
        panel.sendEvent(key(36, "\r", modifiers: [.shift]))
        assert(editor.received == [18, 36, 53, 36] && intercepted.isEmpty, "IME composition keys must reach the editor")
        editor.marked = false
        panel.sendEvent(key(36, "\r"))
        assert(intercepted == [.confirm], "Unmarked Enter must use configured confirmation")
        panel.sendEvent(key(36, "\r", repeatKey: true))
        assert(intercepted == [.confirm], "Key repeat must not resubmit")
        panel.onShortcut = originalHandler
        activity.endAnswerEditing(); editor.removeFromSuperview()
        panel.sendEvent(key(51, "", modifiers: [.command, .shift]))
        advance(0.5)
        assert(!activity.waiting && !panel.isVisible, "Ignore-all must hide both card and droplet")
        // New offscreen rows have not mounted: commands must not depend on a LazyVStack subscriber.
        activity.preview = "waiting"; activity.previewCount = 30
        activity.showRequests(anchor: anchor); advance(0.65)
        panel = activity.window as! CodexRequestPanel
        let offscreen = activity.displayedRequests.last!
        activity.keyboardRequestID = offscreen.identity
        assert(activity.handleShortcut(.option2))
        assert(activity.answerDrafts[offscreen.identity]?.selection == 1, "Offscreen request lost its keyboard selection")
        activity.beginAnswerEditing(offscreen)
        activity.closeRequests(); advance(0.5)
        activity.showRequests(anchor: anchor); advance(0.65)
        assert(activity.editingRequestID == nil && activity.keyboardRequest?.identity == activity.displayedRequests.first?.identity,
               "Reopen must not restore editing on a stale offscreen target")
        panel.sendEvent(key(18, "1"))
        assert(activity.answerDrafts[activity.keyboardRequest!.identity]?.selection == 0)
        activity.clearRequests(); advance(0.5)

        let optionTask = CodexTask(id: "33333333-3333-4333-8333-333333333333", title: "Option fixture", state: "waiting", detail: nil,
            pendingQuestionIds: ["options"], questions: [CodexQuestion(id: "options", title: "可选择或自行输入", options: ["第一项", "第二项", "第三项"])], requestId: "options")
        activity.preview = nil; activity.connected = true; activity.tasks = [optionTask]; activity.replyToken = "fixture-no-network"
        activity.showRequests(anchor: anchor); advance(0.65)
        panel = activity.window as! CodexRequestPanel
        panel.sendEvent(key(36, "\r")); advance(0.05)
        assert(activity.editingRequestID == optionTask.identity)
        panel.sendEvent(key(36, "\r", repeatKey: true)); advance(0.05)
        assert(activity.editingRequestID == optionTask.identity, "Held Enter must not immediately cancel input")
        panel.sendEvent(key(36, "\r")); advance(0.05)
        assert(activity.editingRequestID == nil && !(panel.firstResponder is NSTextView) && activity.waiting,
               "Enter on empty input must return focus to browsing without hiding the reminder")
        panel.sendEvent(key(18, "1"))
        assert(activity.answerDrafts[optionTask.identity]?.selection == 0, "Digits must select after cancelling empty input")
        panel.sendEvent(key(18, "1"))
        panel.sendEvent(key(36, "\r")); advance(0.05)
        guard let optionEditor = panel.firstResponder as? NSTextView else { fatalError("Unselected option question must enter custom input on Enter") }
        assert(activity.editingRequestID == optionTask.identity && activity.submitting.isEmpty)
        optionEditor.insertText("自定义 123", replacementRange: NSRange(location: NSNotFound, length: 0)); advance(0.05)
        assert(activity.answerDrafts[optionTask.identity]?.text == "自定义 123" && activity.answerDrafts[optionTask.identity]?.selection == nil)
        activity.selectOption(1, for: optionTask); advance(0.05)
        assert(activity.editingRequestID == nil && activity.answerDrafts[optionTask.identity]?.selection == 1)
        activity.beginAnswerEditing(optionTask); advance(0.05)
        guard let changedEditor = panel.firstResponder as? NSTextView else { fatalError("Selecting an option must not prevent returning to the input field") }
        changedEditor.insertText("修改后的自定义 456", replacementRange: NSRange(location: 0, length: changedEditor.string.utf16.count)); advance(0.05)
        assert(activity.answerDrafts[optionTask.identity]?.text == "修改后的自定义 456" && activity.answerDrafts[optionTask.identity]?.selection == nil,
               "Native editing after an option choice must update the shared draft and clear selection")
        panel.sendEvent(key(36, "\r"))
        assert(activity.submitting.contains(optionTask.identity), "Enter must submit the edited custom option answer")
        activity.clearRequests(); advance(0.5)
        activity.reconcileRequests([]); activity.tasks = []

        let freeText = CodexTask(id: "22222222-2222-4222-8222-222222222222", title: "Text fixture", state: "waiting", detail: nil,
            pendingQuestionIds: ["free-text"], questions: [CodexQuestion(id: "free-text", title: "请输入测试答案", options: [])], requestId: "free-text")
        activity.preview = nil; activity.connected = true; activity.tasks = [freeText]; activity.replyToken = "fixture-no-network"
        activity.showRequests(anchor: anchor)
        advance(0.65)
        panel = activity.window as! CodexRequestPanel
        panel.sendEvent(key(36, "\r"))
        advance(0.05)
        guard let textEditor = panel.firstResponder as? NSTextView else { fatalError("First Enter did not focus the free-text answer") }
        assert(activity.submitting.isEmpty, "First Enter must not submit an empty answer")
        textEditor.insertText(" \n ", replacementRange: NSRange(location: NSNotFound, length: 0)); advance(0.05)
        panel.sendEvent(key(36, "\r")); advance(0.05)
        assert(activity.editingRequestID == nil && activity.submitting.isEmpty, "Whitespace-only input must exit editing")
        panel.sendEvent(key(36, "\r")); advance(0.05)
        guard let multilineEditor = panel.firstResponder as? NSTextView else { fatalError("Could not re-enter input") }
        multilineEditor.insertText("键盘测试答案 123", replacementRange: NSRange(location: 0, length: multilineEditor.string.utf16.count))
        advance(0.05)
        panel.sendEvent(key(36, "\r", modifiers: [.shift])); advance(0.05)
        assert(activity.answerDrafts[freeText.identity]?.text == "键盘测试答案 123\n",
               "Shift+Enter must insert a real newline into the production text binding")
        assert(activity.editingRequestID == freeText.identity && activity.submitting.isEmpty)
        multilineEditor.insertText("第二行", replacementRange: NSRange(location: NSNotFound, length: 0)); advance(0.05)
        panel.sendEvent(key(76, "\r", modifiers: [.shift, .numericPad])); advance(0.05)
        assert(activity.answerDrafts[freeText.identity]?.text == "键盘测试答案 123\n第二行\n", "Shift+keypad Enter must also insert newline")
        multilineEditor.insertText("第三行", replacementRange: NSRange(location: NSNotFound, length: 0)); advance(0.05)
        assert(activity.submitting.isEmpty)
        panel.sendEvent(key(36, "\r"))
        assert(activity.submitting.contains(freeText.identity), "Second Enter must submit the typed answer")
        panel.sendEvent(key(36, "\r", repeatKey: true))
        assert(activity.submitting == [freeText.identity], "Repeat must not add another submission")
        activity.clearRequests(); advance(0.5)
        print("PASS: normal/reopened/restored focus, offscreen commands, option-to-custom editing, Enter focus/submit, IME protection, repeats and scoped ignore")

        // Keep the established droplet suite above unchanged; exercise the optional style separately.
        assert(activity.reminderStyle == .droplet && testDefaults.object(forKey: "codexReminderStyle") == nil,
               "A missing style preference must preserve the existing droplet")
        testDefaults.set("future-unknown-style", forKey: "codexReminderStyle")
        let unknownStyle = CodexActivity()
        unknownStyle.motionObservation?.cancel(); unknownStyle.motionObservation = nil
        assert(unknownStyle.reminderStyle == .droplet, "An unknown persisted style must fall back to the droplet")
        testDefaults.removeObject(forKey: "codexReminderStyle")
        activity.reminderStyle = .pullCord
        assert(testDefaults.string(forKey: "codexReminderStyle") == "pullCord")
        let reloadedStyle = CodexActivity()
        reloadedStyle.motionObservation?.cancel(); reloadedStyle.motionObservation = nil
        assert(reloadedStyle.reminderStyle == .pullCord, "The selected reminder style must survive relaunch")
        assert(activity.pullCordStyle == .classic && testDefaults.object(forKey: "codexPullCordStyle") == nil,
               "A missing cord appearance preference must preserve the classic switch")
        testDefaults.set("future-unknown-cord-style", forKey: "codexPullCordStyle")
        let unknownCordStyle = CodexActivity()
        unknownCordStyle.motionObservation?.cancel(); unknownCordStyle.motionObservation = nil
        assert(unknownCordStyle.pullCordStyle == .classic, "An unknown persisted cord appearance must fall back to classic")
        testDefaults.removeObject(forKey: "codexPullCordStyle")
        let cordStyles = CodexPullCordStyle.allCases.filter { $0 != .classic } + [.classic]
        for style in cordStyles {
            activity.pullCordStyle = style
            assert(testDefaults.string(forKey: "codexPullCordStyle") == style.rawValue)
            let reloadedCordStyle = CodexActivity()
            reloadedCordStyle.motionObservation?.cancel(); reloadedCordStyle.motionObservation = nil
            assert(reloadedCordStyle.pullCordStyle == style, "The selected cord appearance must survive relaunch")
        }
        activity.pullCordStyle = .classic
        for view in [NSView(frame: CGRect(x: 30, y: 40, width: 64, height: 82)),
                     FlippedAnchorView(frame: CGRect(x: 30, y: 40, width: 64, height: 82))] {
            container.addSubview(view)
            let top = CodexPullCordButton.topAnchor(view: view)
            assert(abs(top.y - 322) < 0.5 && abs(top.x - 262) < 0.5,
                   "Flipped and unflipped cord anchors must share the notch-side screen top")
            view.removeFromSuperview()
        }
        activity.answerDrafts.removeAll(); activity.submitting.removeAll(); activity.replyErrors.removeAll()
        activity.preview = "waiting"; activity.previewCount = 1; activity.tasks = []
        let cordAnchor = CGPoint(x: screen.midX, y: screen.maxY - 42)
        let cordQueueSince = activity.fishWaitingSince
        assert(cordQueueSince != nil, "Waiting preview must expose a fish queue start time")
        let cordSettle = CodexGenieTransition.duration + 0.25
        let materialMidpoint = Double((1 + CodexGenieGeometry.handoffPhase) / 2)
        let closingMorphPhase = Double(CodexGenieGeometry.handoffPhase) * (0.60 / 0.67)
        let supportsGenie = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        func hostOpacityAnimations() -> [String] {
            func changesOpacity(_ animation: CAAnimation) -> Bool {
                if let property = animation as? CAPropertyAnimation, property.keyPath == "opacity" { return true }
                return (animation as? CAAnimationGroup)?.animations?.contains { changesOpacity($0) } ?? false
            }
            guard let layer = activity.window?.contentView?.layer else { return [] }
            return (layer.animationKeys() ?? []).filter { key in
                layer.animation(forKey: key).map { changesOpacity($0) } ?? false
            }
        }
        func assertLiveHandoff(_ phase: String) {
            assert(activity.window?.contentView?.alphaValue == 1,
                   "\(phase): the live glass must stay at full view opacity throughout snapshot handoff")
            assert(hostOpacityAnimations().isEmpty, "\(phase): the live glass must not run an opacity animation")
            guard let opacity = activity.genie.overlay?.layer?.presentation()?.opacity else {
                fatalError("\(phase): missing snapshot presentation layer during handoff")
            }
            assert((0.1...0.9).contains(opacity), "\(phase): expected partially fading snapshot, got \(opacity)")
        }
        func diagnoseCordHandoff(_ phase: String) {
            func layerState(_ layer: CALayer?) -> [String: Any] {
                guard let layer else { return ["exists": false] }
                var state: [String: Any] = ["exists": true, "class": String(describing: type(of: layer)),
                    "modelOpacity": Double(layer.opacity), "animationKeys": layer.animationKeys() ?? []]
                state["presentationOpacity"] = layer.presentation().map { Double($0.opacity) } as Any? ?? NSNull()
                return state
            }
            let genie = activity.genie
            let host = activity.window?.contentView
            let record: [String: Any] = ["phase": phase, "elapsed": CACurrentMediaTime() - genie.startedAt,
                "progress": Double(genie.progress(at: CACurrentMediaTime())), "duration": genie.runningDuration,
                "isAnimating": genie.isAnimating, "windowAlpha": activity.window?.alphaValue ?? -1,
                "hostWantsLayer": host?.wantsLayer ?? false, "hostAlpha": host?.alphaValue ?? -1,
                "hostLayer": layerState(host?.layer), "overlayRoot": layerState(genie.overlay?.layer),
                "hostOpacityAnimations": hostOpacityAnimations()]
            let json = try! JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            FileHandle.standardOutput.write(Data("DIAG ".utf8) + json + Data("\n".utf8))
        }
        func assertCordSettled(_ visible: Bool, _ message: String) {
            assert((activity.window?.isVisible ?? false) == visible && activity.cardPresented == visible,
                   "\(message): window=\(activity.window?.isVisible ?? false), presented=\(activity.cardPresented), dissolve=\(activity.windowDissolve), appActive=\(NSApp.isActive)")
            assert(!activity.genie.isAnimating && !activity.cardAnimating, "\(message): transition overlay survived completion")
            assert(activity.genie.overlay == nil && activity.genie.completionWork == nil && activity.genie.handoffWork == nil,
                   "\(message): transient overlay, handoff boundary or completion callback survived cleanup")
            assert(hostOpacityAnimations().isEmpty, "\(message): host opacity animation survived cleanup")
            if let window = activity.window {
                assert(window.alphaValue == 1 && window.contentView?.alphaValue == 1,
                       "\(message): snapshot transition did not restore the live window/host")
            }
            if visible { assert(activity.panelReady && activity.windowDissolve == 0, "\(message): live controls remained gated") }
        }
        activity.showRequests(anchor: cordAnchor)
        advance(0.04)
        diagnoseCordHandoff("open-40ms")
        var cordPanel = activity.window as! CodexRequestPanel
        assert(activity.presentedStyle == .pullCord && activity.panelTopInset == 64)
        assert(abs(cordPanel.frame.height - 600) < 0.5)
        assert(abs(cordPanel.frame.maxY - CodexCardReveal.panelInset - activity.panelTopInset - (cordAnchor.y - 80)) < 0.5,
               "The cord and visible card must retain a separate hit area: frame=\(cordPanel.frame), cordAnchor=\(cordAnchor), screen=\(screen), visibleFrame=\(NSScreen.main!.visibleFrame), windowScreen=\(String(describing: cordPanel.screen?.frame)), panelInset=\(CodexCardReveal.panelInset), topInset=\(activity.panelTopInset), expectedWindowTop=\(cordAnchor.y + CodexCardReveal.panelInset + activity.panelTopInset - 80), actualCardTop=\(cordPanel.frame.maxY - CodexCardReveal.panelInset - activity.panelTopInset), expectedCardTop=\(cordAnchor.y - 80)")
        if supportsGenie {
            assert(activity.genie.isAnimating && activity.cardAnimating, "Cord opening skipped its snapshot deformation")
        }
        let cordRequest = activity.keyboardRequest!
        cordPanel.sendEvent(key(18, "1"))
        assert(activity.answerDrafts[cordRequest.identity]?.selection == 0,
               "A digit within the first 40 ms of cord opening was swallowed while the snapshot animates")
        if supportsGenie {
            let firstCordStartedAt = activity.genie.startedAt
            let firstCordDuration = activity.genie.runningDuration
            advance(max(0, firstCordStartedAt + firstCordDuration * materialMidpoint - CACurrentMediaTime()))
            diagnoseCordHandoff("open-handoff-midpoint")
            assertLiveHandoff("open-handoff-midpoint")
            advance(max(0, firstCordStartedAt + firstCordDuration + 0.25 - CACurrentMediaTime()))
        } else {
            advance(cordSettle)
        }
        diagnoseCordHandoff("open-settled")
        assertCordSettled(true, "Cord opening did not settle")
        let originalCordFrame = cordPanel.frame
        for style in cordStyles {
            activity.pullCordStyle = style
            advance(0.02)
            assertCordSettled(true, "Changing cord appearance dismissed or animated an open card")
            assert(activity.window === cordPanel && cordPanel.frame == originalCordFrame,
                   "Changing cord appearance must preserve the open panel and its position")
            assert(activity.answerDrafts[cordRequest.identity]?.selection == 0,
                   "Changing cord appearance must preserve the selected answer")
        }
        activity.pullCordStyle = .classic
        activity.closeRequests()
        if supportsGenie {
            let closeStartedAt = activity.genie.startedAt
            let closeDuration = activity.genie.runningDuration
            advance(max(0, closeStartedAt + (closeDuration - CodexGenieGeometry.timelineTime(at: CGFloat(materialMidpoint), showing: false)) - CACurrentMediaTime()))
            diagnoseCordHandoff("close-handoff-midpoint")
            assertLiveHandoff("close-handoff-midpoint")
            advance(max(0, closeStartedAt + (closeDuration - CodexGenieGeometry.timelineTime(at: CGFloat(closingMorphPhase), showing: false)) - CACurrentMediaTime()))
            diagnoseCordHandoff("close-morph-after-handoff")
            assert(activity.window?.contentView?.alphaValue == 0 && activity.genie.isAnimating,
                   "The live host must hide once the opaque snapshot begins collapsing")
            advance(max(0, closeStartedAt + closeDuration + 0.25 - CACurrentMediaTime()))
        } else {
            advance(cordSettle)
        }
        assertCordSettled(false, "Cord closing did not settle")
        assert(activity.window === cordPanel && cordPanel.contentView != nil,
               "Manual closing while a request remains must preserve the warm panel")

        activity.showRequests(anchor: cordAnchor)
        activity.closeRequests() // Before the delayed mount/snapshot starts.
        advance(cordSettle)
        assertCordSettled(false, "Closing before the first animation frame left an invisible or stale panel")
        activity.showRequests(anchor: cordAnchor)
        advance(0.09)
        activity.closeRequests(); advance(0.04)
        activity.showRequests(anchor: cordAnchor)
        advance(cordSettle)
        assertCordSettled(true, "Rapid open/close/open allowed an old completion to hide the new card")
        activity.closeRequests(); advance(cordSettle)
        activity.showRequests(anchor: cordAnchor)
        activity.closeRequests()
        activity.showRequests(anchor: cordAnchor)
        advance(cordSettle)
        assertCordSettled(true, "Immediate close/reopen retained a hidden snapshot or reveal mask")
        assert(activity.fishWaitingSince == cordQueueSince,
               "Opening, closing, selecting an option or switching appearances must not rejuvenate the fish")

        // Confirmed resolution of the last real queue item must start closing promptly.
        activity.tasks = [optionTask]; activity.connected = true; activity.preview = nil
        advance(0.05)
        let resolvedAt = CACurrentMediaTime()
        activity.reconcileRequests([]); activity.tasks = []
        if supportsGenie {
            assert(activity.genie.isAnimating && activity.automaticCordDismiss)
            let closeStartedAt = activity.genie.startedAt
            let closeDuration = activity.genie.runningDuration
            assert(abs(closeDuration - 0.7096) < 0.0001)
            advance(max(0, closeStartedAt + 0.20 - CACurrentMediaTime()))
            let phase = activity.genie.progress(at: CACurrentMediaTime())
            assert(phase < CodexGenieGeometry.handoffPhase && activity.window?.contentView?.alphaValue == 0,
                   "Last-item resolution must deform the card promptly, without the long opening fade")
            print("LAST_REQUEST_CLOSE setup_ms=\((closeStartedAt - resolvedAt) * 1000) material_ms=120 total_ms=\(closeDuration * 1000)")
        }
        advance(cordSettle)
        assertCordSettled(false, "Resolving the last request left the panel visible")
        assert(activity.window == nil && cordPanel.contentView == nil,
               "The resolved queue must release its hidden hosted views and backing layers")
        activity.preview = "waiting"
        activity.showRequests(anchor: cordAnchor); advance(cordSettle)
        cordPanel = activity.window as! CodexRequestPanel

        activity.preview = "running"
        advance(0.05)
        activity.preview = "waiting"
        advance(cordSettle)
        assertCordSettled(true, "A new request during automatic dismissal did not recover the cord card")
        assert(!activity.automaticCordDismiss, "The recovered card retained automatic-dismiss ownership")

        activity.preview = "running"; advance(0.05)
        activity.suspended = true
        activity.updatePolling() // Production pause clears requests, preview and finally connected.
        assert(!activity.waiting && !activity.connected && !activity.cardPresented && activity.windowDissolve == 1,
               "Pause/disconnect reversed automatic dismissal despite having no pending request")
        advance(cordSettle)
        assertCordSettled(false, "Pause/disconnect reopened an empty card during automatic dismissal")
        activity.suspended = false
        activity.preview = "waiting"
        activity.showRequests(anchor: cordAnchor); advance(cordSettle)
        cordPanel = activity.window as! CodexRequestPanel

        // Model the resign-key event that arrives before the reminder's button action.
        let normalResignPredicate = cordPanel.keepOpenOnResign
        cordPanel.keepOpenOnResign = { true }
        cordPanel.resignKey()
        assert(activity.cardPresented && activity.windowDissolve == 0,
               "Resigning to the reminder closed the card before its toggle action")
        activity.showRequests(anchor: cordAnchor)
        advance(cordSettle)
        assertCordSettled(false, "One reminder click closed and then reopened the card")
        activity.showRequests(anchor: cordAnchor); advance(cordSettle)
        cordPanel.keepOpenOnResign = { false }
        cordPanel.resignKey(); advance(cordSettle)
        assertCordSettled(false, "An ordinary outside click no longer dismisses the card")
        cordPanel.keepOpenOnResign = normalResignPredicate
        activity.showRequests(anchor: cordAnchor); advance(0.04)
        cordPanel.sendEvent(key(53, "\u{1b}")); advance(cordSettle)
        assertCordSettled(false, "Escape during cord expansion failed to close")

        activity.showRequests(anchor: cordAnchor); advance(0.07)
        activity.reminderStyle = .droplet
        assert(activity.presentedStyle == .pullCord && activity.panelTopInset == 64,
               "Changing preference changed geometry underneath the closing cord snapshot")
        activity.showRequests(anchor: anchor); advance(CodexCardReveal.duration + 0.25)
        assert(activity.presentedStyle == .droplet && activity.panelTopInset == 0)
        assert(abs(cordPanel.frame.height - 536) < 0.5
               && abs(cordPanel.frame.maxY - CodexCardReveal.panelInset - (anchor.y - 6)) < 0.5,
               "Returning to droplets retained the cord's panel height or attachment gap")
        assertCordSettled(true, "Changing style left an old genie completion or hidden host")
        assert(testDefaults.string(forKey: "codexReminderStyle") == "droplet")
        activity.clearRequests(); advance(0.5)
        for style in [CodexReminderStyle.droplet, .pullCord] {
            weak var releasedPanel: NSPanel?
            weak var releasedTree: NSView?
            // This fixture pumps events manually instead of NSApplication.run(). Drain its
            // AppKit autoreleases and release the test's own panel before asserting deinit.
            autoreleasepool {
                activity.reminderStyle = style
                activity.preview = nil; activity.connected = true; activity.tasks = [optionTask]
                activity.reconcileRequests([optionTask])
                activity.showRequests(anchor: anchor); advance(cordSettle)
                activity.selectOption(0, for: optionTask)
                let cachedPanel = activity.window!
                releasedPanel = cachedPanel
                releasedTree = cachedPanel.contentView
                activity.closeRequests(); advance(cordSettle)
                assert(activity.window === cachedPanel && releasedTree != nil,
                       "Unresolved hidden requests must keep their reusable panel")
                assert(activity.answerDrafts[optionTask.identity]?.selection == 0,
                       "Hiding must retain the selected answer")
                activity.connected = false; activity.tasks = []
                assert(activity.window === cachedPanel && releasedTree != nil,
                       "Disconnect cannot confirm resolution or discard the cached panel")
                activity.connected = true
                assert(activity.window == nil,
                       "\(style): hidden confirmed resolution must clear activity's panel ownership")
                assert(cachedPanel.contentView == nil,
                       "\(style): the released panel must detach its hosting tree")
                assert(activity.answerDrafts[optionTask.identity]?.selection == 0,
                       "View release must not itself clear answer data")
                activity.reconcileRequests([])
            }
            advance(0.05)
            assert(releasedPanel == nil,
                   "\(style): resolved panel must deallocate after AppKit autoreleases drain")
            assert(releasedTree == nil,
                   "\(style): resolved hosting tree must deallocate after AppKit autoreleases drain")
        }

        for style in [CodexReminderStyle.droplet, .pullCord] {
            for phase in ["opening", "open", "closing"] {
                activity.energySavingActive = false
                activity.reminderStyle = style
                activity.preview = nil; activity.connected = true; activity.tasks = [optionTask]
                activity.reconcileRequests([optionTask])
                activity.showRequests(anchor: anchor)
                advance(phase == "opening" ? 0.04 : cordSettle)
                activity.selectOption(0, for: optionTask)
                if phase == "closing" { activity.closeRequests(); advance(0.04) }
                let drafts = activity.answerDrafts, ignored = activity.readReminders
                let completion = activity.completionSequence
                let preference = testDefaults.object(forKey: "codexRocketEnabled") as? Bool
                let panel = activity.window!
                activity.energySavingActive = true
                activity.updatePolling()
                assert(activity.window == nil && panel.contentView == nil && !panel.isVisible,
                       "\(style)/\(phase): saving must synchronously release even an in-flight card")
                assert(!activity.genie.isAnimating && !activity.cardAnimating && !activity.cardPresented
                       && activity.panelTask == nil && activity.dismissTask == nil && activity.pollTask == nil)
                assert(activity.tasks == [optionTask] && activity.answerDrafts == drafts && activity.readReminders == ignored,
                       "Saving must preserve real pending items, input drafts and local ignore history")
                assert(!activity.connected && activity.replyToken == nil && !activity.waiting && !activity.rocketVisible)
                activity.showRequests(anchor: anchor)
                activity.openRequestsFromKeyboard()
                activity.demonstrate("waiting")
                activity.submit("must not send", for: optionTask)
                advance(0.15)
                assert(activity.window == nil && activity.preview == nil && !activity.submitting.contains(optionTask.identity),
                       "Card, preview or reply entry point bypassed saving")
                assert(activity.completionSequence == completion && activity.enabled
                       && (testDefaults.object(forKey: "codexRocketEnabled") as? Bool) == preference)
                activity.energySavingActive = false
                assert(activity.waiting && activity.window == nil, "Restoration must retain reminders without auto-opening")
                activity.connected = true
                activity.showRequests(anchor: anchor); advance(0.04)
                assert(activity.window?.isVisible == true && activity.answerDrafts == drafts)
                activity.energySavingActive = true; activity.updatePolling()
            }
        }
        activity.energySavingActive = false
        print("PASS: smart saving cancels opening/open/closing droplet and Genie cards, preserves drafts/queue/preferences, blocks shortcuts and preview, and restores manual access")
        print("PASS: resolved hidden panels release hosted trees; pending drafts and rapid reopening stay intact")
        print("PASS: cord/reminder style persistence/fallback, live appearance changes preserve the card and selection, flipped anchors, early keyboard input, snapshot cleanup, rapid reversal, automatic-dismiss recovery, reminder resign-key toggle and switching back to droplets")
        activity.previewTask?.cancel()
        testDefaults.removePersistentDomain(forName: suite)
        print("PASS: reminder reset, submission cleanup, media-independent rocket width, initial/cached reveal interpolation and idle, early close, immediate reopening and ignore hides card/drop")
    }
}
'''
fixture = fixture.replace('PROPERTIES', '\n'.join(property(p) for p in ['rocketSideWidth', 'musicSideWidth', 'fuelGap']))
fixture = fixture.replace('WIDTH', width).replace('SLOT', slot)
shape = folder / 'NotchShape.swift'
shape_source = (root / 'boringNotch/components/Notch/NotchShape.swift').read_text().split('// One shared observer set', 1)[0]
shape_source = re.sub(r'#Preview \{.*?\n\}', '', shape_source, flags=re.S).replace('import Defaults\n', '')
shape.write_text(shape_source + '''
@MainActor final class NotchMotionEnvironment: ObservableObject {
    static let shared = NotchMotionEnvironment()
    @Published var suspended = false
    @Published var energySavingActive = false
    var lowPower = false
    static func decorativeFrameInterval(lowPower: Bool) -> Double { lowPower ? 1.0 / 10 : 1.0 / 20 }
}
''')
source = folder / 'InteractionCheck.swift'
genie = folder / 'InteractionGenie.swift'
# Expose diagnostics only in this generated fixture; production source retains its access control.
genie_source = (root / 'boringNotch/components/Notch/CodexGenieTransition.swift').read_text().replace('private(set) ', '').replace('private ', '')
if '--timing' in sys.argv:
    genie_source = genie_source.replace('        guard let parent = host.superview,', '        let setupStart = CACurrentMediaTime()\n        defer { print("GENIE_SETUP_MS showing=\\(showing) ms=\\((CACurrentMediaTime() - setupStart) * 1000)") }\n        guard let parent = host.superview,')
    genie_source = genie_source.replace('            host.layoutSubtreeIfNeeded()', '            let snapshotStart = CACurrentMediaTime()\n            host.layoutSubtreeIfNeeded()')
    genie_source = genie_source.replace('            let overlay = Overlay(frame: host.frame)', '            print("GENIE_SNAPSHOT_MS showing=\\(showing) ms=\\((CACurrentMediaTime() - snapshotStart) * 1000)")\n            let overlay = Overlay(frame: host.frame)')
genie.write_text(genie_source)
shortcuts = folder / 'CodexShortcuts.swift'
shortcuts.write_text((root / 'boringNotch/Shortcuts/CodexShortcuts.swift').read_text().replace('UserDefaults = .standard', 'UserDefaults = testDefaults'))
if '--profile' in sys.argv:
    probe = r'''
@MainActor enum FrameProbe {
    static var phase = "setup"
    static var rows: [[String: Any]] = []
    static var marks: [[String: Any]] = []
    static func record(_ kind: String, _ value: Double) {
        rows.append(["time": ProcessInfo.processInfo.systemUptime, "phase": phase, "kind": kind, "value": value])
    }
    static func mark(_ name: String) {
        phase = name
        marks.append(["time": ProcessInfo.processInfo.systemUptime, "phase": name, "epoch": Date().timeIntervalSince1970])
    }
}
'''
    profile = r'''
        if CommandLine.arguments.contains("--profile") {
            let awake = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Bounded component frame measurement")
            activity.preview = nil; activity.tasks = []
            let drop = NSPanel(contentRect: CGRect(x: screen.midX - 210, y: screen.maxY - 170, width: 420, height: 160),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            drop.isOpaque = false; drop.backgroundColor = .clear; drop.hasShadow = false
            drop.level = .mainMenu + 3; drop.isReleasedWhenClosed = false
            drop.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            drop.contentView = NSHostingView(rootView: DropFixture(activity: activity))
            drop.orderFront(nil)
            func at(_ time: Double, _ name: String, _ action: @escaping () -> Void) {
                DispatchQueue.main.asyncAfter(deadline: .now() + time) { FrameProbe.mark(name); action() }
            }
            let usesGenie = activity.reminderStyle == .pullCord && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            let openWait = usesGenie ? CodexGenieTransition.duration + 0.15 : 0.9
            let closeWait = usesGenie ? CodexGenieTransition.duration + 0.15 : 0.6
            let cyclePeriod = max(4, 1.3 + openWait + closeWait + 1.2)
            at(2, "hidden-idle") {}
            at(12, "drop-appear") { activity.preview = "waiting" }
            at(14, "drop-idle") {}
            at(22, "card-open") { activity.showRequests(anchor: reminderAnchor(drop)) }
            at(22 + max(1, openWait), "card-idle") {}
            at(31, "card-close") { activity.closeRequests() }
            at(31 + max(1, closeWait), "drop-retract") { activity.preview = nil }
            at(31 + max(3, closeWait + 2), "hidden-again") {}
            for cycle in 0..<6 {
                let t = 42 + Double(cycle) * cyclePeriod
                at(t, "appear-\(cycle)") { activity.preview = "waiting" }
                at(t + 1.3, "open-\(cycle)") { activity.showRequests(anchor: reminderAnchor(drop)) }
                at(t + 1.3 + openWait, "close-\(cycle)") { activity.closeRequests() }
                at(t + 1.3 + openWait + closeWait, "retract-\(cycle)") { activity.preview = nil }
            }
            at(42 + 6 * cyclePeriod + 1, "finished") {
                let result: [String: Any] = ["frames": FrameProbe.rows, "marks": FrameProbe.marks,
                    "screenHz": NSScreen.main?.maximumFramesPerSecond ?? 0]
                let data = try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                try! data.write(to: URL(fileURLWithPath: CommandLine.arguments.last!))
                ProcessInfo.processInfo.endActivity(awake)
                testDefaults.removePersistentDomain(forName: suite)
                exit(0)
            }
            NSApp.activate(ignoringOtherApps: true)
            withExtendedLifetime(drop) { NSApp.run() }
            return
        }
'''
    fixture = fixture.replace('        if CommandLine.arguments.contains("--preview") {', profile + '        if CommandLine.arguments.contains("--preview") {')
    effects = (root / 'boringNotch/components/Notch/CodexNotchEffect.swift').read_text()
    effects = effects.replace('        let cy = -10 + max(0, progress) * 61 + hoverOffset', '        let _ = FrameProbe.record("drop", Double(progress))\n        let cy = -10 + max(0, progress) * 61 + hoverOffset')
    effects = effects.replace('    func body(content: Content) -> some View {\n        let t = 1 - min(1, max(0, progress))', '    func body(content: Content) -> some View {\n        let _ = FrameProbe.record("reveal", Double(progress))\n        let t = 1 - min(1, max(0, progress))')
    effects = effects.replace('    func body(content: Content) -> some View {\n        content.mask {', '    func body(content: Content) -> some View {\n        let _ = FrameProbe.record("collapse", Double(progress))\n        content.mask {')
    (folder / 'ProfileEffects.swift').write_text(effects + probe)
else:
    effects = (root / 'boringNotch/components/Notch/CodexNotchEffect.swift').read_text()
    reveal_body = '    func body(content: Content) -> some View {\n        let t = 1 - min(1, max(0, progress))'
    assert effects.count(reveal_body) == 1, 'Production reveal probe insertion point changed'
    effects = effects.replace(reveal_body, '    func body(content: Content) -> some View {\n        let _ = CardRevealProbe.record(progress)\n        let t = 1 - min(1, max(0, progress))')
    (folder / 'InteractionEffects.swift').write_text(effects)
source.write_text(activity + fixture)
app = folder / 'Notch Component Preview.app'
(app / 'Contents/MacOS').mkdir(parents=True, exist_ok=True)
(app / 'Contents/Info.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier='local.interestingnotch.component-preview',
    CFBundleExecutable='Notch Component Preview', CFBundleName='Notch Component Preview', CFBundlePackageType='APPL', LSUIElement=True)))
binary = app / 'Contents/MacOS/Notch Component Preview'
env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
env.pop('SDKROOT', None)
subprocess.run(['xcrun', 'swiftc', '-O', '-assert-config', 'Debug', '-swift-version', '5', '-D', 'EDGE_CHECKS',
    str(shortcuts), str(shape), str(root / 'boringNotch/components/Notch/MusicEdgeEffect.swift'),
    str(root / 'boringNotch/components/Notch/CodexPullCord.swift'),
    str(genie),
    str(folder / ('ProfileEffects.swift' if '--profile' in sys.argv else 'InteractionEffects.swift')), str(source), '-o', str(binary)], env=env, check=True)
if '--profile' in sys.argv:
    print(str(app))
elif '--preview' in sys.argv or '--handoff-preview' in sys.argv:
    preview_args = ['--preview']
    if '--cord' in sys.argv or '--handoff-preview' in sys.argv or cord_style is not None:
        preview_args.append('--cord')
    if cord_style is not None:
        preview_args.extend(['--cord-style', cord_style])
    if '--handoff-preview' in sys.argv:
        preview_args.append('--handoff-preview')
    subprocess.run(['open', '-n', str(app), '--args'] + preview_args, check=True)
else:
    subprocess.run([str(binary)], check=True)
