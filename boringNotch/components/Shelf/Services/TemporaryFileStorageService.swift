import Foundation

enum TempFileType {
    case data(Data, suggestedName: String?)
    case text(String)
    case url(URL)
}

final class TemporaryFileStorageService {
    static let shared = TemporaryFileStorageService()
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("InterestingNotch-Shelf", isDirectory: true)

    private func filename(_ suggestion: String?, fallback: String) -> String {
        let name = ((suggestion ?? "") as NSString).lastPathComponent
        return name.isEmpty || name == "." || name == ".." ? fallback : name
    }

    func createTempFile(for type: TempFileType) async -> URL? {
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            let data: Data
            let name: String
            switch type {
            case .data(let value, let suggestion):
                data = value; name = filename(suggestion, fallback: "Untitled.dat")
            case .text(let value):
                data = Data(value.utf8); name = "Text.txt"
            case .url(let value):
                data = try PropertyListSerialization.data(fromPropertyList: ["URL": value.absoluteString], format: .xml, options: 0)
                name = filename(value.host, fallback: "Link") + ".webloc"
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent(name)
            try data.write(to: file, options: .atomic)
            return file
        } catch {
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
    }

    func removeTemporaryFileIfNeeded(at url: URL) {
        // Only this service's files may be deleted; never accept an arbitrary /tmp path.
        let file = url.standardizedFileURL
        let directory = file.deletingLastPathComponent()
        guard file.isFileURL, UUID(uuidString: directory.lastPathComponent) != nil,
              directory.deletingLastPathComponent().resolvingSymlinksInPath() == root.resolvingSymlinksInPath(),
              file.resolvingSymlinksInPath().deletingLastPathComponent() == directory.resolvingSymlinksInPath() else { return }
        do {
            try FileManager.default.removeItem(at: file)
            if try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty {
                try FileManager.default.removeItem(at: directory)
            }
        } catch { NSLog("Shelf temporary file cleanup failed: %@", error.localizedDescription) }
    }

    func createZip(from urls: [URL], suggestedName: String? = nil) async -> URL? {
        guard !urls.isEmpty, urls.allSatisfy(\.isFileURL) else { return nil }
        let manager = FileManager.default
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        var succeeded = false
        defer { if !succeeded { try? manager.removeItem(at: directory) } }
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            let fallback = urls.count == 1 ? urls[0].lastPathComponent + ".zip" : "Archive.zip"
            let archive = directory.appendingPathComponent(filename(suggestedName, fallback: fallback))
            let source: URL
            let entries: [String]
            if urls.count == 1 {
                source = urls[0].deletingLastPathComponent()
                // A leading dash in a source name must never become a zip option.
                entries = ["./" + urls[0].lastPathComponent]
            } else {
                source = directory.appendingPathComponent("Contents", isDirectory: true)
                try manager.createDirectory(at: source, withIntermediateDirectories: true)
                for url in urls {
                    var destination = source.appendingPathComponent(url.lastPathComponent)
                    if manager.fileExists(atPath: destination.path) {
                        destination = source.appendingPathComponent(UUID().uuidString + "_" + url.lastPathComponent)
                    }
                    // Any failed copy fails the whole operation; never return a partial archive.
                    try manager.copyItem(at: url, to: destination)
                }
                entries = ["."]
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            process.currentDirectoryURL = source
            process.arguments = ["-r", "-q", archive.path] + entries
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0, manager.fileExists(atPath: archive.path) else { return nil }
            if urls.count > 1 { try manager.removeItem(at: source) }
            succeeded = true
            return archive
        } catch {
            NSLog("Shelf archive creation failed: %@", error.localizedDescription)
            return nil
        }
    }
}
