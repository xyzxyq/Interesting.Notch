#!/usr/bin/env python3
"""Exercise production thumbnail cache lifecycle with controlled Quick Look completions."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
thumbnail = (root/'boringNotch/components/Shelf/Services/ThumbnailService.swift').read_text()
state = (root/'boringNotch/components/Shelf/ViewModels/ShelfStateViewModel.swift').read_text()

def method(source, signature):
    start = source.index(signature)
    end = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end].replace('private ', '')

actor = thumbnail[thumbnail.index('actor ThumbnailService {'):thumbnail.index('    // MARK: - Private Methods')]
actor = actor.replace('    private let thumbnailGenerator = QLThumbnailGenerator.shared\n', '').replace('private ', '')
source = r'''
import Foundation
import AppKit
THUMBNAIL
    var requests: [String: [CheckedContinuation<NSImage?, Never>]] = [:]
    func generateQuickLookThumbnail(for url: URL, size: CGSize) async -> NSImage? {
        await withCheckedContinuation { requests[url.path, default: []].append($0) }
    }
    func requestCount(_ url: URL) -> Int { requests[url.path]?.count ?? 0 }
    func finish(_ url: URL, image: NSImage) { requests[url.path]!.removeFirst().resume(returning: image) }
    func cached(_ url: URL) -> Bool { cache.keys.contains { $0.hasPrefix(url.standardizedFileURL.path + "\u{0}") } }
}
@MainActor struct ShelfItem {
    let id = UUID()
    var fileURL: URL?
    func cleanupStoredData() {}
}
@MainActor final class ShelfCheck {
    var items: [ShelfItem] = []
    REMOVE
}
@main struct Check {
    static let size = CGSize(width: 56, height: 56)
    static func settle(_ predicate: () async -> Bool) async throws {
        for _ in 0..<1000 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        fatalError("Thumbnail fixture did not settle")
    }
    static func load(_ url: URL) async throws -> NSImage {
        let service = ThumbnailService.shared
        let loading = Task { await service.thumbnail(for: url, size: size) }
        try await settle { await service.requestCount(url) == 1 }
        let image = NSImage(size: size)
        await service.finish(url, image: image)
        let result = await loading.value
        assert(result === image)
        return image
    }
    @MainActor static func main() async throws {
        let service = ThumbnailService.shared
        let file = URL(fileURLWithPath: "/fixture/file")
        let sibling = URL(fileURLWithPath: "/fixture/file-extra")
        let image = try await load(file)
        _ = try await load(sibling)
        let hit = await service.thumbnail(for: file, size: size)
        let duplicateRequests = await service.requestCount(file)
        assert(hit === image && duplicateRequests == 0, "Visible shelf item failed to reuse its thumbnail")

        let shelf = ShelfCheck(), first = ShelfItem(fileURL: file), duplicate = ShelfItem(fileURL: file)
        shelf.items = [first, duplicate]
        shelf.remove(first)
        try await Task.sleep(for: .milliseconds(20))
        let sharedStillCached = await service.cached(file)
        assert(sharedStillCached, "Removing one duplicate reference evicted a thumbnail still used on the shelf")
        shelf.remove(duplicate)
        try await settle { !(await service.cached(file)) }
        let siblingRetained = await service.cached(sibling)
        assert(siblingRetained, "Exact URL eviction cleared a different file with the same path prefix")

        let slow = URL(fileURLWithPath: "/fixture/slow")
        let old = Task { await service.thumbnail(for: slow, size: size) }
        try await settle { await service.requestCount(slow) == 1 }
        let slowItem = ShelfItem(fileURL: slow)
        shelf.items = [slowItem]
        shelf.remove(slowItem)
        try await settle { await service.pendingRequests.isEmpty }
        let newer = Task { await service.thumbnail(for: slow, size: size) }
        try await settle { await service.requestCount(slow) == 2 }
        await service.finish(slow, image: NSImage(size: size))
        let rejected = await old.value
        let afterOld = await service.cached(slow), pendingAfterOld = await service.pendingRequests.count
        assert(rejected == nil && !afterOld && pendingAfterOld == 1,
               "Old completion repopulated cache or removed the new request for the same URL")
        let newImage = NSImage(size: size)
        await service.finish(slow, image: newImage)
        let accepted = await newer.value
        let newHit = await service.thumbnail(for: slow, size: size)
        assert(accepted === newImage && newHit === newImage, "Re-added URL lost the current thumbnail")

        let immediate = ShelfItem(fileURL: slow)
        shelf.items = [immediate]
        shelf.remove(immediate)
        shelf.items.append(ShelfItem(fileURL: slow))
        try await Task.sleep(for: .milliseconds(20))
        let retainedAfterReadd = await service.cached(slow)
        assert(retainedAfterReadd, "Deferred removal discarded a thumbnail re-added before eviction")

        let last = URL(fileURLWithPath: "/fixture/last")
        let loading = Task { await service.thumbnail(for: last, size: size) }
        try await settle { await service.requestCount(last) == 1 }
        await service.clearCache()
        await service.finish(last, image: NSImage(size: size))
        let late = await loading.value
        let cacheCount = await service.cache.count, pendingCount = await service.pendingRequests.count
        assert(late == nil && cacheCount == 0 && pendingCount == 0,
               "Clearing all thumbnails allowed an in-flight result to restore retained images")
        print("PASS: thumbnail hits, last-reference eviction, exact URL matching, late completion isolation, same-URL re-add and full clear")
    }
}
'''.replace('THUMBNAIL', actor).replace('REMOVE', method(state, '    func remove(_ item: ShelfItem)'))
with tempfile.TemporaryDirectory(prefix='notch-thumbnail-check-') as temp:
    temp = Path(temp)
    (temp/'Check.swift').write_text(source)
    env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
    env.pop('SDKROOT', None)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', str(temp/'Check.swift'), '-o', str(temp/'check')], env=env, check=True)
    subprocess.run([str(temp/'check')], check=True)
