import SwiftUI
import Sparkle

// This fork distributes updates through GitHub until it has its own signed appcast.
struct CheckForUpdatesView: View {
    init(updater: SPUUpdater) {}
    var body: some View {
        Link("Check for Updates…", destination: URL(string: "https://github.com/xyzxyq/Interesting.Notch/releases")!)
    }
}

struct UpdaterSettingsView: View {
    init(updater: SPUUpdater) {}
    var body: some View {
        Section("Software updates") {
            CheckForUpdatesLink()
            Text(Brand.localized("Download updates from this project's GitHub Releases."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct CheckForUpdatesLink: View {
    var body: some View {
        Link("GitHub Releases", destination: URL(string: "https://github.com/xyzxyq/Interesting.Notch/releases")!)
    }
}
