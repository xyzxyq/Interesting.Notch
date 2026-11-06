#!/usr/bin/env python3
"""Exercise the production artwork pipeline with reordered completions and catalog fixtures."""
from pathlib import Path
import os, subprocess, tempfile, sys, json
root = Path(__file__).resolve().parents[1]
source = (root/'boringNotch/managers/MusicManager.swift').read_text()
block = source.split('        // Check for changes in track metadata using last artwork change values\n',1)[1].split('        let timeChanged',1)[0]
method = source.split('    @MainActor private func updateArtwork(',1)[1].split('    private func updateIdleState',1)[0]
method = '    func updateArtwork(' + method
fixture = r'''
import AppKit
import SwiftUI
let defaultImage = NSImage(size: .init(width: 1, height: 1))
func AppIconAsNSImage(for bundle: String) -> NSImage? { nil }
@MainActor enum Fixture {
    static var pending: [String: CheckedContinuation<Data?, Error>] = [:]
    static var calls = 0
    static func fetch(_ state: PlaybackState) async throws -> Data? {
        calls += 1
        return try await withCheckedThrowingContinuation { pending[state.title] = $0 }
    }
}
@MainActor final class Manager {
    var artworkData: Data?
    var artworkTask: Task<Void, Never>?
    var artworkGeneration: UInt64 = 0
    var lastArtworkCatalogID: Int?
    var lastArtworkTitle = "", lastArtworkArtist = "", lastArtworkAlbum = ""
    var lastArtworkBundleIdentifier: String?, lastArtworkTrackIdentifier: String?
    var usingAppIconForArtwork = true, isMusicSource = true
    var albumArt = defaultImage
    func triggerFlipAnimation() {}
    func updateSneakPeek() {}
    func updateAlbumArt(newAlbumArt: NSImage) { albumArt = newAlbumArt }
    func apply(_ state: PlaybackState) {
        isMusicSource = state.isMusicSource
''' + block + '''    }
''' + method.replace('AlbumArtwork.fetch(for: state)', 'Fixture.fetch(state)') + r'''
}
@main @MainActor struct Check {
    static func settle() async { try? await Task.sleep(for: .milliseconds(80)) }
    static func png(_ color: NSColor) -> Data {
        let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
            color.setFill(); rect.fill(); return true
        }
        return NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    }
    static func red(_ image: NSImage) -> Bool {
        NSBitmapImageRep(data: image.tiffRepresentation!)!.colorAt(x: 2, y: 2)!.usingColorSpace(.deviceRGB)!.redComponent > 0.8
    }
    static func state(_ title: String, art: Data? = nil) -> PlaybackState {
        var state = PlaybackState(bundleIdentifier: "com.apple.Music", isPlaying: true,
            title: title, artist: "莫文蔚", album: "不散,不見", duration: 296, artwork: art)
        state.trackIdentifier = title
        return state
    }
    static func main() async throws {
        let redData = png(.red), blueData = png(.blue)
        assert(AlbumArtwork.decode(Data()) == nil && AlbumArtwork.decode(Data("not an image".utf8)) == nil)
        assert(AlbumArtwork.decode(redData)?.isValid == true)
        func catalog(_ artist: String = "莫文蔚", album: String = "不散，不见", title: String = "看看", duration: Int = 295905, id: Int = 42) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["results": [["trackId":id, "trackName":title,
                "artistName":artist, "collectionName":album, "trackTimeMillis":duration,
                "artworkUrl100":"https://is1-ssl.mzstatic.com/test.jpg"]]])
        }
        let song = state("看看")
        assert(try AlbumArtwork.matchedURL(in: catalog(), for: song) != nil)
        for data in [try catalog("wrong artist"), try catalog(album:"另一张精选集"),
                     try catalog(title:"看看 (Live)"), try catalog(duration:628000)] {
            assert(try AlbumArtwork.matchedURL(in: data, for: song) == nil, "Catalog accepted another edition/album/artist")
        }
        var identified = song; identified.catalogID = 99
        assert(try AlbumArtwork.matchedURL(in: catalog(), for: identified) == nil)
        assert(try AlbumArtwork.matchedURL(in: catalog("Localized artist", id:99), for: identified) != nil)
        let payload = try catalog()
        var requests = 0
        let downloaded = try await AlbumArtwork.fetch(for: song) { request in
            requests += 1
            return (request.url!.host!.contains("itunes") ? payload : redData,
                    HTTPURLResponse(url: request.url!, statusCode:200, httpVersion:nil, headerFields:nil)!)
        }
        assert(downloaded == redData && requests == 2)
        var failedRegion = false
        let regionRecovery = try await AlbumArtwork.fetch(for: song) { request in
            if !failedRegion { failedRegion = true; throw URLError(.timedOut) }
            return (request.url!.host!.contains("itunes") ? payload : redData,
                    HTTPURLResponse(url: request.url!, statusCode:200, httpVersion:nil, headerFields:nil)!)
        }
        assert(regionRecovery == redData, "One failed storefront must not prevent a healthy fallback")
        do {
            _ = try await AlbumArtwork.fetch(for: song) { request in
                (Data(), HTTPURLResponse(url:request.url!,statusCode:503,httpVersion:nil,headerFields:nil)!)
            }
            assertionFailure("HTTP failure was accepted")
        } catch {}
        let manager = Manager()
        manager.apply(state("A")); await settle()
        manager.apply(state("B")); await settle()
        Fixture.pending.removeValue(forKey:"B")!.resume(returning:blueData); await settle()
        assert(!manager.usingAppIconForArtwork && !red(manager.albumArt))
        Fixture.pending.removeValue(forKey:"A")!.resume(returning:redData); await settle()
        assert(!red(manager.albumArt), "Late A artwork replaced current B")
        let calls = Fixture.calls
        for _ in 0..<10 { manager.apply(state("B")) }
        await settle()
        assert(Fixture.calls == calls && !manager.usingAppIconForArtwork, "Clock updates restarted artwork or hid a resolved cover")
        manager.apply(state("C", art:redData)); await settle()
        assert(red(manager.albumArt) && !manager.usingAppIconForArtwork)
        manager.apply(state("D", art:redData)); await settle()
        assert(red(manager.albumArt) && !manager.usingAppIconForArtwork, "Shared album artwork disappeared on next song")
        manager.apply(state("bad", art:Data("broken".utf8))); await settle()
        assert(manager.usingAppIconForArtwork && manager.albumArt === defaultImage, "New track retained an old cover while decoding failed")
        Fixture.pending.removeValue(forKey:"bad")!.resume(returning:blueData); await settle()
        assert(!manager.usingAppIconForArtwork && !red(manager.albumArt))
        var video = state("video",art:blueData); video.bundleIdentifier = "test.video"
        manager.apply(video); await settle()
        manager.apply(state("return",art:blueData)); await settle()
        assert(!manager.usingAppIconForArtwork, "Returning music with identical artwork remained hidden")
        manager.apply(state("late")); await settle()
        manager.apply(video)
        Fixture.pending.removeValue(forKey:"late")!.resume(returning:redData); await settle()
        assert(manager.usingAppIconForArtwork && manager.albumArt === defaultImage, "Cancelled music request replaced another source")
        manager.apply(state("retry")); await settle()
        Fixture.pending.removeValue(forKey:"retry")!.resume(throwing:URLError(.timedOut))
        try await Task.sleep(for: .milliseconds(2200))
        Fixture.pending.removeValue(forKey:"retry")!.resume(returning:redData); await settle()
        assert(!manager.usingAppIconForArtwork && red(manager.albumArt), "Transient failure did not recover")
        manager.apply(state("native",art:redData)); await settle()
        manager.apply(state("native")); await settle()
        assert(!manager.usingAppIconForArtwork && red(manager.albumArt), "A temporary gap hid this track's valid cover")
        assert(Fixture.pending["native"] == nil, "A resolved native cover must not start a redundant catalog request")
        assert(!manager.usingAppIconForArtwork && red(manager.albumArt))
        manager.apply(state("catalog-late")); await settle()
        Fixture.pending.removeValue(forKey:"catalog-late")!.resume(returning:nil); await settle()
        var withID = state("catalog-late"); withID.catalogID = 99
        manager.apply(withID); await settle()
        assert(Fixture.pending["catalog-late"] != nil, "Late catalog ID must retry a previously missing cover")
        Fixture.pending.removeValue(forKey:"catalog-late")!.resume(returning:blueData); await settle()
        assert(!manager.usingAppIconForArtwork)
        func update(_ text: String) throws -> NowPlayingUpdate { try JSONDecoder().decode(NowPlayingUpdate.self, from:Data(text.utf8)) }
        let a = state("A",art:redData)
        let unchanged = a.applying(try update(#"{"diff":true,"payload":{"playing":false}}"#))
        assert(unchanged.artwork == redData)
        let b = a.applying(try update(#"{"diff":true,"payload":{"title":"B"}}"#))
        assert(b.artwork == nil, "Track diff retained previous cover")
        let c = a.applying(try update(#"{"diff":true,"payload":{"uniqueIdentifier":"new-track"}}"#))
        assert(c.artwork == nil && c.trackIdentifier == "new-track")
        print("PASS artwork: catalog identity/editions/duration, HTTP errors, decode recovery, reordered A/B completions, shared album, repeated updates, source switching and MediaRemote diffs")
    }
}
'''
# Swift assert autoclosures cannot throw.
fixture = fixture.replace('assert(try AlbumArtwork.matchedURL', 'assert(try! AlbumArtwork.matchedURL')
extra_sources = []
if '--live' in sys.argv:
    fixture = fixture[:fixture.index('@main @MainActor struct Check')]
    fixture = fixture.replace('Fixture.fetch(state)', 'AlbumArtwork.fetch(for: state)')
    extra_sources = [str(root/'boringNotch/helpers/AppleScriptHelper.swift'),
                     str(root/'boringNotch/MediaControllers/MediaControllerProtocol.swift'),
                     str(root/'boringNotch/MediaControllers/AppleMusicController.swift')]
    fixture += r"""
@main @MainActor struct LiveCheck {
    static func main() {
        _ = NSApplication.shared
        Task { @MainActor in
            let player = AppleMusicController(), manager = Manager()
            let update = try! JSONDecoder().decode(NowPlayingUpdate.self,
                from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
            let native = PlaybackState(bundleIdentifier: "").applying(update)
            var latest = PlaybackState(bundleIdentifier: "")
            let observer = player.playbackStatePublisher.receive(on: DispatchQueue.main).sink { state in
                guard state.lastUpdated != .distantPast else { return }
                latest = state
                manager.apply(native.focusingMusic(on: state, hasDedicatedController: true))
            }
            await player.updatePlaybackInfo()
            let deadline = Date().addingTimeInterval(50)
            while manager.usingAppIconForArtwork && Date() < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard !manager.usingAppIconForArtwork, manager.albumArt.isValid else {
                print("LIVE FAILED: title=\(latest.title), album=\(latest.album), native bytes=\(latest.artwork?.count ?? 0)")
                exit(1)
            }
            try? NSBitmapImageRep(data:manager.albumArt.tiffRepresentation!)?.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:"/tmp/notch-live-recovered-cover.png"))
            print("PASS LIVE: \(latest.title) / \(latest.artist) / \(latest.album); native bytes \(latest.artwork?.count ?? 0); recovered \(manager.albumArt.size); playback untouched")
            withExtendedLifetime(observer) {}
            exit(0)
        }
        NSApp.run()
    }
}
"""
with tempfile.TemporaryDirectory(prefix='notch-artwork-') as directory:
    folder=Path(directory); swift=folder/'Check.swift'; swift.write_text(fixture)
    env=dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
    subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library',
        str(root/'boringNotch/models/PlaybackState.swift'),str(root/'boringNotch/models/CompactLyrics.swift'),
        str(root/'boringNotch/models/AlbumArtwork.swift'),str(swift),*extra_sources,'-o',str(folder/'check')],env=env,check=True)
    args = [str(folder/'check')]
    if '--live' in sys.argv:
        app = Path('/Applications/Interesting Notch.app/Contents')
        snapshot = json.loads(subprocess.check_output(['/usr/bin/perl', str(app/'Resources/mediaremote-adapter.pl'),
            str(app/'Frameworks/MediaRemoteAdapter.framework'), 'get'], text=True))
        data = folder/'native.json'
        data.write_text(json.dumps({'diff': False, 'payload': snapshot}))
        args.append(str(data))
    subprocess.run(args,check=True)
