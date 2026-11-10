#!/usr/bin/env python3
"""Exercise shelf share ownership and complete PDF creation using isolated fixtures."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
view_model = (root/'boringNotch/components/Shelf/ViewModels/ShelfItemViewModel.swift').read_text()
images = (root/'boringNotch/components/Shelf/Services/ImageProcessingService.swift').read_text()

def method(source, signature):
    start = source.index(signature)
    end = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end].replace('private ', '')

share = method(view_model, '    func shareItem(from view: NSView?)')
share = share.replace('NSSharingServicePicker(', 'FixturePicker(')
share = share.replace('startAccessingSecurityScopedResource()', 'recordedStart()')
share = share.replace('stopAccessingSecurityScopedResource()', 'recordedStop()')
pdf = method(images, '    func createPDF(from imageURLs:')
errors = images[images.index('enum ImageProcessingError:'):]
source = r'''
import Foundation
import AppKit
import PDFKit
@MainActor enum AccessLedger {
    static var counts: [URL: Int] = [:]
}
extension URL {
    @MainActor func recordedStart() -> Bool {
        AccessLedger.counts[self, default: 0] += 1
        return true
    }
    @MainActor func recordedStop() { AccessLedger.counts[self, default: 0] -= 1 }
}
struct ShelfItem {
    enum Kind { case file, text(String), link(URL) }
    let kind: Kind
    let url: URL
}
@MainActor final class ShelfStateViewModel {
    static let shared = ShelfStateViewModel()
    var items: [ShelfItem] = []
    func resolveAndUpdateBookmark(for item: ShelfItem) -> URL? { item.url }
}
@MainActor final class ShelfSelectionModel {
    static let shared = ShelfSelectionModel()
    func selectedItems(in items: [ShelfItem]) -> [ShelfItem] { items }
}
@MainActor final class FixtureLifecycle {
    let onEnd: () -> Void
    private var finished = false
    init(onEnd: @escaping () -> Void) { self.onEnd = onEnd }
    func markPickerBegan() {}
    func finish() {
        guard !finished else { return }
        finished = true
        onEnd()
    }
    func sharingServicePicker(_ picker: FixturePicker, didChoose: String?) { finish() }
}
@MainActor final class SharingStateManager {
    static let shared = SharingStateManager()
    var delegates: [FixtureLifecycle] = []
    func makeDelegate(onEnd: @escaping () -> Void) -> FixtureLifecycle {
        let delegate = FixtureLifecycle(onEnd: onEnd)
        delegates.append(delegate)
        return delegate
    }
}
@MainActor final class FixturePicker {
    var delegate: FixtureLifecycle?
    init(items: [Any]) {}
    func show(relativeTo: NSRect, of: NSView, preferredEdge: NSRectEdge) {}
}
@MainActor final class ShareCheck {
    let item: ShelfItem
    init(item: ShelfItem) { self.item = item }
    SHARE
}
@MainActor final class ImageProcessingService {
    PDF
}
ERRORS
@main struct Check {
    @MainActor static func settle(_ predicate: () -> Bool) async throws {
        for _ in 0..<1000 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        fatalError("Shelf fixture did not settle")
    }
    @MainActor static func main() async throws {
        let firstURL = URL(fileURLWithPath: "/fixture/first"), secondURL = URL(fileURLWithPath: "/fixture/second")
        let first = ShelfItem(kind: .file, url: firstURL), second = ShelfItem(kind: .file, url: secondURL)
        var model: ShareCheck? = ShareCheck(item: first)
        ShelfStateViewModel.shared.items = [first]
        model!.shareItem(from: NSView())
        try await settle { SharingStateManager.shared.delegates.count == 1 }
        ShelfStateViewModel.shared.items = [second]
        model!.shareItem(from: NSView())
        try await settle { SharingStateManager.shared.delegates.count == 2 }
        assert(AccessLedger.counts[firstURL] == 1 && AccessLedger.counts[secondURL] == 1,
               "Starting a second share revoked the first transfer's access")
        SharingStateManager.shared.delegates[0].finish()
        assert(AccessLedger.counts[firstURL] == 0 && AccessLedger.counts[secondURL] == 1,
               "First completion revoked the wrong transfer's access")
        weak var released = model
        model = nil
        assert(released == nil)
        SharingStateManager.shared.delegates[1].finish()
        assert(AccessLedger.counts[secondURL] == 0, "Closing shelf leaked transfer access after completion")
        let noView = ShareCheck(item: first)
        ShelfStateViewModel.shared.items = [first]
        noView.shareItem(from: nil)
        try await settle { SharingStateManager.shared.delegates.count == 3 }
        assert(AccessLedger.counts[firstURL] == 0, "Unavailable share anchor left unfinished access")

        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("notch-pdf-fixture-" + UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        let valid = directory.appendingPathComponent("valid.png")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let original = bitmap.representation(using: .png, properties: [:])!
        try original.write(to: valid)
        let invalid = directory.appendingPathComponent("invalid.png")
        let corrupt = Data("not an image".utf8)
        try corrupt.write(to: invalid)
        let service = ImageProcessingService()
        let output = try await service.createPDF(from: [valid, valid], outputName: "complete")!
        defer { TemporaryFileStorageService.shared.removeTemporaryFileIfNeeded(at: output) }
        assert(PDFDocument(url: output)?.pageCount == 2, "Complete PDF lost a valid input page")
        for input in [[invalid, valid], [valid, invalid]] {
            do {
                _ = try await service.createPDF(from: input)
                assertionFailure("Invalid input was reported as a successful partial PDF")
            } catch ImageProcessingError.invalidImage {} catch ImageProcessingError.pdfCreationFailed {}
        }
        do {
            _ = try await service.createPDF(from: [])
            assertionFailure("Empty PDF input succeeded")
        } catch ImageProcessingError.noImagesProvided {}
        let cancelled = Task { @MainActor in try await service.createPDF(from: [valid]) }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            assertionFailure("Cancelled PDF work returned a file")
        } catch is CancellationError {}
        let validAfter = try Data(contentsOf: valid), invalidAfter = try Data(contentsOf: invalid)
        assert(validAfter == original && invalidAfter == corrupt, "PDF creation modified a source file")
        print("PASS: isolated share access across overlap/view removal/cancel, complete PDF, invalid first/last input, cancellation and unchanged sources")
    }
}
'''.replace('SHARE', share).replace('PDF\n', pdf + '\n').replace('ERRORS', errors)
with tempfile.TemporaryDirectory(prefix='notch-shelf-transfers-') as temp:
    temp = Path(temp)
    (temp/'Check.swift').write_text(source)
    env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
    env.pop('SDKROOT', None)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library',
                    str(root/'boringNotch/components/Shelf/Services/TemporaryFileStorageService.swift'),
                    str(temp/'Check.swift'), '-o', str(temp/'check')], env=env, check=True)
    subprocess.run([str(temp/'check')], check=True)
