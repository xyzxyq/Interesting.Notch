import SwiftUI
import Combine
import Sparkle

@MainActor final class SoftwareUpdateNotes: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = SoftwareUpdateNotes()
    @Published private(set) var availableUpdate: SUAppcastItem?

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        availableUpdate = item
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        availableUpdate = nil
    }

    static func summary(for item: SUAppcastItem) -> String? {
        // shortcut: only our plain-text feed is shown here, add formatting support if the feed changes.
        guard item.itemDescriptionFormat == "plain-text",
              let description = item.itemDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
              !description.isEmpty else { return nil }
        return description
    }
}

@MainActor final class UpdaterPreferences: ObservableObject {
    let updater: SPUUpdater
    @Published private(set) var canCheck = false
    @Published private(set) var automaticChecks = false
    @Published private(set) var automaticDownloads = false
    private var observations = Set<AnyCancellable>()

    init(updater: SPUUpdater) {
        self.updater = updater
        updater.publisher(for: \.canCheckForUpdates).removeDuplicates()
            .sink { [weak self] in self?.canCheck = $0 }.store(in: &observations)
        updater.publisher(for: \.automaticallyChecksForUpdates).removeDuplicates()
            .sink { [weak self] in self?.automaticChecks = $0 }.store(in: &observations)
        updater.publisher(for: \.automaticallyDownloadsUpdates).removeDuplicates()
            .sink { [weak self] in self?.automaticDownloads = $0 }.store(in: &observations)
    }
}

struct CheckForUpdatesView: View {
    @StateObject private var preferences: UpdaterPreferences
    init(updater: SPUUpdater) {
        _preferences = StateObject(wrappedValue: UpdaterPreferences(updater: updater))
    }
    var body: some View {
        Button("Check for Updates…") { preferences.updater.checkForUpdates() }
            .disabled(!preferences.canCheck)
    }
}

struct UpdaterSettingsView: View {
    @StateObject private var preferences: UpdaterPreferences
    @ObservedObject private var notes = SoftwareUpdateNotes.shared
    init(updater: SPUUpdater) {
        _preferences = StateObject(wrappedValue: UpdaterPreferences(updater: updater))
    }
    var body: some View {
        Section("Software updates") {
            Toggle(Brand.localized("Automatically check for updates"), isOn: Binding(
                get: { preferences.automaticChecks },
                set: { preferences.updater.automaticallyChecksForUpdates = $0 }))
            Toggle(Brand.localized("Automatically download and install updates"), isOn: Binding(
                get: { preferences.automaticDownloads },
                set: { preferences.updater.automaticallyDownloadsUpdates = $0 }))
                .disabled(!preferences.automaticChecks)
            Text(Brand.localized("Checks GitHub releases daily. Automatic installation finishes when the app quits; you can also restart to update."))
                .font(.caption).foregroundStyle(.secondary)
            if let item = notes.availableUpdate {
                VStack(alignment: .leading, spacing: 8) {
                    Text(Brand.localized("New version available: %@", item.displayVersionString))
                        .font(.headline)
                    Text(SoftwareUpdateNotes.summary(for: item)
                         ?? Brand.localized("This release has no summary. Open GitHub Releases to read the update details."))
                        .font(.callout)
                        .lineLimit(8)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
            CheckForUpdatesView(updater: preferences.updater)
            Link("GitHub Releases", destination: URL(string: "https://github.com/xyzxyq/Interesting.Notch/releases")!)
        }
    }
}
