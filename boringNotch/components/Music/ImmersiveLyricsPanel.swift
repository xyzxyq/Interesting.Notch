import AppKit
import SwiftUI

/// A child panel keeps projection pixels outside the notch's interactive rectangle.
struct ImmersiveLyricsPanel: NSViewRepresentable {
    let visible: Bool
    let topInset: CGFloat
    let hideFromRecording: Bool
    var focusEnabled = false
    var allowsFocusTransition = true
    let content: ImmersiveLyricsView
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> Anchor { Anchor() }

    func updateNSView(_ view: Anchor, context: Context) {
        view.presentation = self
        view.updatePanel()
    }

    static func dismantleNSView(_ view: Anchor, coordinator: ()) { view.removePanel() }

    final class Anchor: NSView {
        var presentation: ImmersiveLyricsPanel?
        private var panel: BoringNotchWindow?
        private var hosting: NSHostingView<ImmersiveLyricsView>?
        private var wasFocused = false
        private var fadingOut = false
        private var transitionGeneration = 0

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updatePanel()
        }

        func updatePanel() {
            guard let presentation else { removePanel(); return }
            let focusChanged = wasFocused != presentation.focusEnabled
            wasFocused = presentation.focusEnabled
            guard presentation.visible, let parent = window else {
                if window != nil, presentation.allowsFocusTransition, !presentation.focusEnabled,
                   let panel, focusChanged || fadingOut {
                    if !fadingOut {
                        fadingOut = true
                        transitionGeneration += 1
                        let generation = transitionGeneration
                        NSAnimationContext.runAnimationGroup { context in
                            context.duration = ImmersiveFocus.transitionDuration(enabled: false, reducedMotion: presentation.reduceMotion)
                            panel.animator().alphaValue = 0
                        } completionHandler: { [weak self, weak panel] in
                            guard let self, let panel, self.panel === panel, self.fadingOut,
                                  self.transitionGeneration == generation else { return }
                            self.removePanel()
                        }
                    }
                    return
                }
                removePanel()
                return
            }
            let reversingExit = fadingOut
            if reversingExit { transitionGeneration += 1 }
            fadingOut = false
            let width = min(ImmersiveLyricsView.projectionSize.width, max(280, (parent.screen?.frame.width ?? 900) - 80))
            if panel == nil {
                let newPanel = BoringNotchWindow(contentRect: .zero,
                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                newPanel.ignoresMouseEvents = true
                newPanel.hidesOnDeactivate = false
                let host = NSHostingView(rootView: presentation.content)
                newPanel.contentView = host
                hosting = host
                panel = newPanel
                if presentation.focusEnabled && presentation.allowsFocusTransition { newPanel.alphaValue = 0 }
            }
            guard let panel else { return }
            hosting?.rootView = presentation.content
            panel.sharingType = presentation.hideFromRecording ? .none : .readOnly
            panel.setFrame(NSRect(x: parent.frame.midX - width / 2,
                                  y: parent.frame.maxY - presentation.topInset - ImmersiveLyricsView.projectionSize.height,
                                  width: width, height: ImmersiveLyricsView.projectionSize.height), display: true)
            if panel.parent !== parent {
                panel.parent?.removeChildWindow(panel)
                parent.addChildWindow(panel, ordered: .below)
            }
            panel.orderFrontRegardless()
            if panel.alphaValue < 1 || reversingExit {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = presentation.allowsFocusTransition
                        ? ImmersiveFocus.transitionDuration(enabled: true, reducedMotion: presentation.reduceMotion) : 0
                    context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
                    panel.animator().alphaValue = 1
                }
            }
        }

        func removePanel() {
            fadingOut = false
            transitionGeneration += 1
            guard let panel else { return }
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            panel.contentView = nil
            hosting = nil
            self.panel = nil
        }
    }
}
