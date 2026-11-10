#!/usr/bin/env python3
"""Exercise production preview selection and access balancing without opening Quick Look."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
production = (root/'boringNotch/components/Shelf/Services/QuickLookService.swift').read_text()

def method(signature):
    start = production.index(signature)
    end = production.index('{', start) + 1
    depth = 1
    while depth:
        depth += (production[end] == '{') - (production[end] == '}')
        end += 1
    return production[start:end].replace('private ', '')

methods = '\n'.join(method(s) for s in ['    func show(urls:', '    func hide()',
    '    private func stopAccessingCurrentURLs()', '    func updateSelection(urls:',
    '    @objc private func previewPanelWillClose('])
methods = methods.replace('startAccessingSecurityScopedResource()', 'recordedStart()')
methods = methods.replace('stopAccessingSecurityScopedResource()', 'recordedStop()')
source = r'''
import AppKit
import Foundation
@MainActor enum AccessLedger {
    static var scoped = Set<URL>()
    static var starts: [URL: Int] = [:]
    static var stops: [URL: Int] = [:]
}
extension URL {
    @MainActor func recordedStart() -> Bool {
        AccessLedger.starts[self, default: 0] += 1
        return AccessLedger.scoped.contains(self)
    }
    @MainActor func recordedStop() { AccessLedger.stops[self, default: 0] += 1 }
}
@MainActor final class QLPreviewPanel: NSObject {
    static let panel = QLPreviewPanel()
    static func shared() -> QLPreviewPanel? { panel }
    var isVisible = false
    func orderOut(_ sender: Any?) { isVisible = false }
}
@MainActor final class PreviewCheck: NSObject {
    var urls: [URL] = []
    var selectedURL: URL?
    var isQuickLookOpen = false
    var previewPanel: QLPreviewPanel?
    var accessingURLs: [URL] = []
    METHODS
}
@main struct Check {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("notch-quicklook-fixture-" + UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        let ordinary = directory.appendingPathComponent("readable.txt")
        let original = Data("owned readable fixture".utf8)
        try original.write(to: ordinary)
        // Scope acquisition is controlled at the boundary; the fixture file is actually readable.
        let read = try Data(contentsOf: ordinary)
        assert(read == original)
        let scoped = directory.appendingPathComponent("scoped.txt")
        try Data("scoped fixture".utf8).write(to: scoped)
        let missing = directory.appendingPathComponent("missing.txt")
        let remote = URL(string: "https://example.com/fixture")!
        AccessLedger.scoped.insert(scoped)
        let preview = PreviewCheck()
        let input = [ordinary, scoped, remote, missing]
        preview.show(urls: input)
        assert(preview.urls == input && preview.selectedURL == ordinary && preview.isQuickLookOpen,
               "Readable unscoped files or original selection were dropped from Quick Look")
        assert(preview.accessingURLs == [scoped], "Only acquired file scopes belong in the cleanup list")
        assert(AccessLedger.starts[remote] == nil, "Web URL was treated as a security-scoped file")
        preview.updateSelection(urls: [scoped, ordinary])
        assert(preview.urls == [scoped, ordinary] && preview.selectedURL == scoped)
        assert(AccessLedger.starts[scoped] == 2 && AccessLedger.stops[scoped] == 1)
        preview.hide()
        preview.hide()
        assert(preview.urls.isEmpty && preview.selectedURL == nil && !preview.isQuickLookOpen)
        assert(AccessLedger.stops[scoped] == 2, "Hide must stop each acquisition exactly once")
        assert(AccessLedger.stops[ordinary] == nil && AccessLedger.stops[remote] == nil && AccessLedger.stops[missing] == nil,
               "Cleanup stopped a scope that was never acquired")
        preview.show(urls: [missing])
        assert(preview.urls == [missing] && preview.selectedURL == missing && preview.accessingURLs.isEmpty,
               "Unavailable file must remain a preview request without inventing acquired access")
        preview.hide()
        preview.show(urls: [scoped])
        preview.previewPanelWillClose(Notification(name: NSWindow.willCloseNotification, object: QLPreviewPanel.panel))
        for _ in 0..<1000 {
            if !preview.isQuickLookOpen { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        assert(!preview.isQuickLookOpen && preview.accessingURLs.isEmpty && AccessLedger.stops[scoped] == 3,
               "External preview close leaked acquired scope")
        let remaining = try Data(contentsOf: ordinary)
        assert(remaining == original)
        print("PASS: readable unscoped file, scoped/web/missing mixed URLs, original selection, balanced hide/selection/external-close scope cleanup")
    }
}
'''.replace('METHODS', methods)
with tempfile.TemporaryDirectory(prefix='notch-quicklook-check-') as temp:
    temp = Path(temp)
    (temp/'Check.swift').write_text(source)
    env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
    env.pop('SDKROOT', None)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', str(temp/'Check.swift'), '-o', str(temp/'check')], env=env, check=True)
    subprocess.run([str(temp/'check')], check=True)
