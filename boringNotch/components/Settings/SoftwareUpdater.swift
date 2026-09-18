import SwiftUI
import Combine
import Sparkle

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
            CheckForUpdatesView(updater: preferences.updater)
            Link("GitHub Releases", destination: URL(string: "https://github.com/xyzxyq/Interesting.Notch/releases")!)
        }
    }
}
