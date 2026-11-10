#!/usr/bin/env python3
"""Exercise production YouTube artwork ownership without a player or network."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
folder = root / 'boringNotch/MediaControllers/YouTube Music Controller'
controller = (folder / 'YouTubeMusicController.swift').read_text()

def method(signature):
    start = controller.index(signature)
    cursor = controller.index('{', start) + 1
    depth = 1
    while depth:
        depth += (controller[cursor] == '{') - (controller[cursor] == '}')
        cursor += 1
    return controller[start:cursor].replace('private ', '')

methods = '\n'.join(method(signature) for signature in [
    '@MainActor private func updatePlaybackState(', '@MainActor private func resetPlaybackState()', 'deinit {'
])
source = r'''
import AppKit
import Foundation
import ImageIO
@MainActor final class ImageService {
    static let shared = ImageService()
    var urls: [URL] = []
    var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    func fetchImageData(from url: URL) async throws -> Data {
        let index = urls.count
        urls.append(url)
        return try await withCheckedThrowingContinuation { pending[index] = $0 }
    }
    func reply(_ index: Int, _ result: Result<Data, Error>) { pending.removeValue(forKey: index)!.resume(with: result) }
}
actor Socket { func disconnect() {} }
@MainActor final class ControllerCheck {
    let configuration = YouTubeMusicConfiguration.default
    var playbackState = PlaybackState(bundleIdentifier: YouTubeMusicConfiguration.default.bundleIdentifier)
    var artworkFetchTask: Task<Void, Never>?
    var artworkURL: URL?
    var active = true
    var updateTimer: Timer?
    var appStateObserver: Task<Void, Never>?
    var reconnectTask: Task<Void, Never>?
    var webSocketClient: Socket?
    func isActive() -> Bool { active }
    METHODS
}
@main @MainActor struct Check {
    static func settle(_ predicate: () -> Bool) async throws {
        for _ in 0..<1000 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        fatalError("Artwork fixture did not settle")
    }
    static func response(_ title: String? = nil, image: String? = nil, time: Double = 1) -> PlaybackResponse {
        PlaybackResponse(isPaused: false, title: title, artist: nil, album: nil,
            elapsedSeconds: time, songDuration: nil, imageSrc: image, repeatMode: nil, isShuffled: nil, volume: nil)
    }
    static func png(_ color: NSColor) -> Data {
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 4, bitsPerPixel: 32)!
        image.setColor(color.usingColorSpace(.deviceRGB)!, atX: 0, y: 0)
        return image.representation(using: .png, properties: [:])!
    }
    static func main() async throws {
        let service = ImageService.shared, imageA = png(.red), imageB = png(.blue)
        let a = "https://fixture.invalid/a.png", b = "https://fixture.invalid/b.png"
        var controller: ControllerCheck? = ControllerCheck()
        await controller!.updatePlaybackState(with: response("A", image: a))
        try await settle { service.urls.count == 1 }
        let first = controller!.artworkFetchTask!
        for time in 2...101 {
            await controller!.updatePlaybackState(with: response(image: time.isMultiple(of: 2) ? a : nil, time: Double(time)))
        }
        assert(service.urls.count == 1 && !first.isCancelled,
               "Same-track progress and partial updates must retain one in-flight image request")
        service.reply(0, .success(imageA))
        await first.value
        assert(controller!.playbackState.artwork == imageA && controller!.artworkFetchTask == nil)
        for time in 102...201 {
            await controller!.updatePlaybackState(with: response(image: time.isMultiple(of: 2) ? a : nil, time: Double(time)))
        }
        assert(service.urls.count == 1 && controller!.playbackState.artwork == imageA,
               "An existing valid cover must survive partial updates without downloading again")

        await controller!.updatePlaybackState(with: response("B", image: a))
        try await settle { service.urls.count == 2 }
        let old = controller!.artworkFetchTask!
        assert(controller!.playbackState.artwork == nil)
        await controller!.updatePlaybackState(with: response("C", image: a))
        try await settle { service.urls.count == 3 }
        let current = controller!.artworkFetchTask!
        service.reply(1, .success(imageB))
        await old.value
        assert(old.isCancelled && controller!.playbackState.artwork == nil && controller!.artworkFetchTask != nil,
               "A cancelled late image must not overwrite the song or clear its replacement task")
        await controller!.updatePlaybackState(with: response(time: 5))
        assert(service.urls.count == 3, "Stale cleanup allowed a duplicate replacement download")
        service.reply(2, .success(imageA))
        await current.value
        assert(controller!.playbackState.artwork == imageA)

        await controller!.updatePlaybackState(with: response("D"))
        assert(controller!.playbackState.artwork == nil && controller!.artworkURL == nil,
               "A new song without an image must not inherit the old cover")
        await controller!.updatePlaybackState(with: response(image: b))
        try await settle { service.urls.count == 4 }
        let failing = controller!.artworkFetchTask!
        service.reply(3, .failure(URLError(.timedOut)))
        await failing.value
        assert(controller!.artworkFetchTask == nil && controller!.playbackState.artwork == nil)
        try await Task.sleep(for: .milliseconds(20))
        assert(service.urls.count == 4, "Failure must not start a background retry loop")
        await controller!.updatePlaybackState(with: response())
        try await settle { service.urls.count == 5 }
        let invalid = controller!.artworkFetchTask!
        service.reply(4, .success(Data("<html>503</html>".utf8)))
        await invalid.value
        assert(controller!.artworkFetchTask == nil && controller!.playbackState.artwork == nil,
               "An error page must not be cached as a successful cover")
        await controller!.updatePlaybackState(with: response())
        try await settle { service.urls.count == 6 }
        let recovered = controller!.artworkFetchTask!
        service.reply(5, .success(imageB))
        await recovered.value
        assert(controller!.playbackState.artwork == imageB)

        await controller!.updatePlaybackState(with: response(image: a))
        try await settle { service.urls.count == 7 }
        let reset = controller!.artworkFetchTask!
        controller!.resetPlaybackState()
        service.reply(6, .success(imageA))
        await reset.value
        assert(reset.isCancelled && controller!.playbackState.artwork == nil && controller!.artworkURL == nil)
        await controller!.updatePlaybackState(with: response("E", image: a))
        try await settle { service.urls.count == 8 }
        let quit = controller!.artworkFetchTask!
        controller!.active = false
        service.reply(7, .success(imageA))
        await quit.value
        assert(controller!.playbackState.artwork == nil, "A player that quit must reject a late image")
        controller!.active = true
        await controller!.updatePlaybackState(with: response("F", image: b))
        try await settle { service.urls.count == 9 }
        let releasedTask = controller!.artworkFetchTask!
        weak var released = controller
        controller = nil
        assert(released == nil && releasedTask.isCancelled, "The download retained its old controller")
        service.reply(8, .success(imageB))
        await releasedTask.value
        assert(service.pending.isEmpty)
        print("PASS: 200 same-track updates use one image request; partial metadata, song/URL changes, stale completion, failure recovery, reset, quit and controller release")
    }
}
'''.replace('METHODS', methods)
with tempfile.TemporaryDirectory(prefix='notch-youtube-artwork-') as directory:
    path = Path(directory)
    (path / 'Check.swift').write_text(source)
    env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', str(path / 'Check.swift'),
                    str(root / 'boringNotch/models/PlaybackState.swift'), str(folder / 'YouTubeMusicModels.swift'),
                    '-o', str(path / 'check')], env=env, check=True)
    subprocess.run([str(path / 'check')], check=True)
