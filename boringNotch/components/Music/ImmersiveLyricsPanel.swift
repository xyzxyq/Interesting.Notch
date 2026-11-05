import AppKit
import SwiftUI

/// A child panel keeps projection pixels outside the notch's interactive rectangle.
struct ImmersiveLyricsPanel: NSViewRepresentable {
    let visible: Bool
    let topInset: CGFloat
    let hideFromRecording: Bool
    let content: ImmersiveLyricsView

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

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updatePanel()
        }

        func updatePanel() {
            guard let presentation, presentation.visible, let parent = window else {
                removePanel()
                return
            }
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
        }

        func removePanel() {
            guard let panel else { return }
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            panel.contentView = nil
            hosting = nil
            self.panel = nil
        }
    }
}
