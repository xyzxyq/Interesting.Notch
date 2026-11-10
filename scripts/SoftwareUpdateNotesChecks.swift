import AppKit
import Combine
import Sparkle
import SwiftUI

// This standalone harness compiles the production updater view without the rest of the app.
enum Brand {
    static func localized(_ key: String) -> String { key }
    static func localized(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: key, arguments: arguments)
    }
}

@main @MainActor struct SoftwareUpdateNotesChecks {
    static func item(description: String? = nil, format: String = "plain-text", version: String = "3.1.3") -> SUAppcastItem {
        var properties: [String: Any] = [
            "sparkle:version": "3103",
            "sparkle:shortVersionString": version,
            "link": "https://github.com/xyzxyq/Interesting.Notch/releases"
        ]
        if let description {
            properties["description"] = ["content": description, "format": format]
        }
        // Sparkle's deprecated initializer is confined to fixtures; production receives parsed items.
        return SUAppcastItem(dictionary: properties)!
    }

    static func main() {
        let notes = SoftwareUpdateNotes.shared
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: notes, userDriverDelegate: nil)
        let release = item(description: "  - Reduced background work\n- Added update highlights  ")
        assert(SoftwareUpdateNotes.summary(for: release) == "- Reduced background work\n- Added update highlights")
        assert(SoftwareUpdateNotes.summary(for: item()) == nil)
        assert(SoftwareUpdateNotes.summary(for: item(description: " \n ")) == nil)
        assert(SoftwareUpdateNotes.summary(for: item(description: "<script>test</script>", format: "html")) == nil)
        var discoveries = 0
        let observation = notes.$availableUpdate.dropFirst().sink { _ in discoveries += 1 }
        notes.updater(controller.updater, didFindValidUpdate: release)
        assert(notes.availableUpdate?.displayVersionString == "3.1.3")
        assert(SoftwareUpdateNotes.summary(for: notes.availableUpdate!)?.contains("update highlights") == true)
        notes.updater(controller.updater, didFindValidUpdate: item(description: "- Newer changes", version: "3.1.4"))
        assert(notes.availableUpdate?.displayVersionString == "3.1.4")
        notes.updaterDidNotFindUpdate(controller.updater)
        assert(notes.availableUpdate == nil && discoveries == 3)
        withExtendedLifetime(observation) {}
        print("Software update notes passed: plain text, missing/empty/HTML fallback, replacement, observation and clearing")
    }
}
