#!/usr/bin/env python3
"""Run the production source router with isolated players, applications and system commands."""
from pathlib import Path
import os
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'boringNotch/MediaControllers/NowPlayingController.swift').read_text()
source = source.replace('import Defaults\n', '').replace('private(set) ', '').replace('private ', '')
start = source.index('    init?() {')
body = source.index('{', start)
end, depth = body + 1, 1
while depth:
    depth += (source[end] == '{') - (source[end] == '}')
    end += 1
source = source[:start] + '''    init?() {
        mediaRemoteBundle = CFBundleGetMainBundle()
        MRMediaRemoteSendCommandFunction = { _, _ in systemCommands += 1 }
        MRMediaRemoteSetElapsedTimeFunction = { _ in systemCommands += 1 }
        MRMediaRemoteSetShuffleModeFunction = { _ in systemCommands += 1 }
        MRMediaRemoteSetRepeatModeFunction = { _ in systemCommands += 1 }
    }
''' + source[end:]
source = source.replace('Set(NSWorkspace.shared.runningApplications.compactMap(\\.bundleIdentifier))', 'Fixture.running')
fixture = r'''
import SwiftUI
var systemCommands = 0
enum Fixture { static var running: Set<String> = [] }
enum Defaults {
    enum Key { case immersiveFocusEnabled }
    struct Change { var newValue: Bool }
    static let changes = CurrentValueSubject<Change, Never>(.init(newValue: false))
    static subscript(_ key: Key) -> Bool { changes.value.newValue }
    static func publisher(_ key: Key) -> AnyPublisher<Change, Never> { changes.eraseToAnyPublisher() }
    static func focus(_ value: Bool) { changes.send(.init(newValue: value)) }
}
final class NotchMotionEnvironment: ObservableObject {
    static let shared = NotchMotionEnvironment()
    @Published var suspended = false
}
enum AppleScriptHelper {
    static func execute(_ text: String) async throws -> NSAppleEventDescriptor? { nil }
    static func executeVoid(_ text: String) async throws {}
}
class MockPlayer: MediaControllerProtocol {
    static var created: [MockPlayer] = []
    let subject = CurrentValueSubject<PlaybackState, Never>(PlaybackState(bundleIdentifier: ""))
    var calls: [String] = []
    init() { Self.created.append(self) }
    var playbackStatePublisher: AnyPublisher<PlaybackState, Never> { subject.eraseToAnyPublisher() }
    var supportsFavorite: Bool { true }
    var supportsVolumeControl: Bool { true }
    func isActive() -> Bool { true }
    func updatePlaybackInfo() async { calls.append("refresh") }
    func play() async { calls.append("play") }
    func pause() async { calls.append("pause") }
    func togglePlay() async { calls.append("toggle") }
    func nextTrack() async { calls.append("next") }
    func previousTrack() async { calls.append("previous") }
    func seek(to time: Double) async { calls.append("seek") }
    func toggleShuffle() async { calls.append("shuffle") }
    func toggleRepeat() async { calls.append("repeat") }
    func setVolume(_ value: Double) async { calls.append("volume") }
    func setFavorite(_ value: Bool) async { calls.append("favorite") }
}
final class AppleMusicController: MockPlayer {}
final class SpotifyController: MockPlayer {}
final class YouTubeMusicController: MockPlayer {}

@main @MainActor struct Check {
    static func settle() async { try? await Task.sleep(for: .milliseconds(40)) }
    static func update(_ source: String, title: String = "Video", playing: Bool = true) throws -> NowPlayingUpdate {
        let data = try JSONSerialization.data(withJSONObject: ["diff": false, "payload": [
            "bundleIdentifier": source, "title": title, "artist": "Author", "album": "Album",
            "playing": playing, "elapsedTime": 90, "duration": 200, "artworkData": "AQID"]])
        return try JSONDecoder().decode(NowPlayingUpdate.self, from: data)
    }
    static func main() async throws {
        var native = PlaybackState(bundleIdentifier: "com.apple.Music", isPlaying: true, title: "Same song",
            artist: "Singer", album: "Album", currentTime: 90, duration: 220, artwork: Data([1, 2]))
        native.catalogID = 42
        var dedicated = native
        dedicated.artwork = nil; dedicated.catalogID = nil; dedicated.currentTime = 10
        let recovered = native.focusingMusic(on: dedicated, hasDedicatedController: true)
        assert(recovered.artwork == native.artwork && recovered.catalogID == 42 && recovered.currentTime == 10,
               "Same-song native artwork must fill the AppleScript gap without borrowing its clock")
        var wrongID = dedicated; wrongID.catalogID = 99
        assert(native.focusingMusic(on: wrongID, hasDedicatedController: true).artwork == nil)
        for mismatch in 0..<5 {
            var other = native
            switch mismatch {
            case 0: other.bundleIdentifier = "test.video"
            case 1: other.title = "Different song"
            case 2: other.artist = "Different singer"
            case 3: other.album = "Live album"
            default: other.duration += 10
            }
            assert(other.focusingMusic(on: dedicated, hasDedicatedController: true).artwork == nil,
                   "A different source/edition must never supply the cover")
        }
        for source in ["com.apple.Music", "com.spotify.client", "com.github.th-ch.youtube-music"] {
            Defaults.focus(true); Fixture.running = [source]
            let router = NowPlayingController()!
            await router.handleAdapterUpdate(try update(source, title: "Original song"))
            let player = MockPlayer.created.last!
            assert(router.focusedController === player)
            var music = PlaybackState(bundleIdentifier: source, isPlaying: true, title: "Original song",
                artist: "Singer", album: "Music album", currentTime: 12, duration: 180,
                playbackRate: 1, lastUpdated: Date(), artwork: Data([8, 9]))
            player.subject.send(music); await settle()
            for other in ["com.apple.Safari", "com.douyin.desktop", "test.audio", ""] {
                await router.handleAdapterUpdate(try update(other))
                assert(router.playbackState == music && router.playbackState.lastUpdated == music.lastUpdated,
                    "Other media replaced the focused metadata, artwork or lyric clock")
                assert(router.focusedController === player, "Other media recreated the music connection")
            }
            await router.handleAdapterUpdate(try update("test.video"))
            music.isPlaying = false; music.playbackRate = 0; music.currentTime = 22; music.lastUpdated = Date()
            player.subject.send(music); await settle()
            assert(router.playbackState == music && !router.playbackState.isPlaying,
                   "A real music pause must win even while video keeps playing")
            music.isPlaying = true; music.playbackRate = 1; music.title = "Next song"
            music.currentTime = 0; music.artwork = Data([4, 5]); music.lastUpdated = Date()
            player.subject.send(music); await settle()
            assert(router.playbackState == music, "Background music changes must reach both notch layouts")
            await router.play(); await router.pause(); await router.togglePlay()
            await router.nextTrack(); await router.previousTrack(); await router.seek(to: 30)
            await router.toggleShuffle(); await router.toggleRepeat(); await router.setVolume(0.4)
            await router.setFavorite(true); await router.updatePlaybackInfo()
            assert(player.calls == ["play", "pause", "toggle", "next", "previous", "seek", "shuffle", "repeat", "volume", "favorite", "refresh"])
            assert(systemCommands == 0, "Focused controls reached the system's unrelated video player")
            Defaults.focus(false); router.refreshVideoAudio(forceNative: true)
            assert(router.focusedController == nil && router.playbackState.bundleIdentifier == "test.video",
                   "Disabling focus must restore the current system source")
            player.subject.send(music); await settle()
            assert(router.playbackState.bundleIdentifier == "test.video", "A late player update escaped cancellation")
            Defaults.focus(true); router.refreshVideoAudio(forceNative: true)
            assert(router.focusedController != nil, "Focus must find running music even when video already owns Now Playing")
            Fixture.running = []; router.refreshVideoAudio(forceNative: true)
            assert(router.focusedController == nil && router.playbackState.bundleIdentifier.isEmpty,
                   "Quitting music must clear the focused source instead of falling back to video")
            await router.togglePlay(); await router.seek(to: 10)
            assert(systemCommands == 0, "Empty focus must not control unrelated media")
        }
        Defaults.focus(true); Fixture.running = ["com.apple.Music", "com.netease.163music"]
        let router = NowPlayingController()!
        await router.handleAdapterUpdate(try update("com.netease.163music", title: "Native music"))
        assert(router.focusedController == nil && router.playbackState.bundleIdentifier == "com.netease.163music",
               "An unrelated idle direct player must not replace the active music client")
        print("PASS: production router preserves music across four competing sources; live pause/track/clock/art changes, 11 targeted controls, focus enable/disable, late updates, cold start and app exit")
    }
}
'''
live = '--live' in sys.argv
extra_sources = []
if live:
    fixture = fixture[:fixture.index('@main @MainActor struct Check')]
    a = fixture.index('enum AppleScriptHelper {')
    b = fixture.index('class MockPlayer:', a)
    fixture = fixture[:a] + fixture[b:]
    fixture = fixture.replace('final class AppleMusicController: MockPlayer {}\n', '')
    extra_sources = [str(root / 'boringNotch/helpers/AppleScriptHelper.swift'),
                     str(root / 'boringNotch/MediaControllers/AppleMusicController.swift')]
    fixture += r'''
@main @MainActor struct LiveCheck {
    static func main() {
        _ = NSApplication.shared
        Task { @MainActor in
            Defaults.focus(true); Fixture.running = ["com.apple.Music"]
            let router = NowPlayingController()!
            router.refreshVideoAudio(forceNative: true)
            let deadline = Date().addingTimeInterval(8)
            while router.playbackState.lastUpdated == .distantPast && Date() < deadline {
                try? await Task.sleep(for: .milliseconds(30))
            }
            let before = router.playbackState
            assert(before.bundleIdentifier == "com.apple.Music" && before.isPlaying, "Live music read unavailable")
            if let artwork = before.artwork {
                assert(NSImage(data: artwork)?.isValid == true, "Native album artwork is not decodable")
            }
            let data = Data(#"{"diff":false,"payload":{"bundleIdentifier":"test.competing-video","title":"Video takeover","playing":true,"elapsedTime":900}}"#.utf8)
            let update = try! JSONDecoder().decode(NowPlayingUpdate.self, from: data)
            await router.handleAdapterUpdate(update)
            assert(router.playbackState == before && router.playbackState.lastUpdated == before.lastUpdated,
                   "The video takeover replaced actual music data")
            try? await Task.sleep(for: .seconds(1))
            await router.updatePlaybackInfo()
            try? await Task.sleep(for: .milliseconds(50))
            let after = router.playbackState
            assert(after.bundleIdentifier == "com.apple.Music" && after.isPlaying
                   && after.title == before.title && after.currentTime > before.currentTime,
                   "Focused music stopped receiving real updates after the takeover")
            print("PASS LIVE: actual Apple Music, \(before.artwork?.count ?? 0) artwork bytes; clock \(before.currentTime) → \(after.currentTime) after simulated video takeover; playback unchanged")
            exit(0)
        }
        NSApp.run()
    }
}
'''
with tempfile.TemporaryDirectory(prefix='notch-focused-media-') as directory:
    folder = Path(directory)
    swift = folder / 'Check.swift'
    swift.write_text(source + fixture)
    env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
    binary = folder / 'check'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library',
        str(root / 'boringNotch/models/PlaybackState.swift'),
        str(root / 'boringNotch/MediaControllers/MediaControllerProtocol.swift'), str(swift),
        *extra_sources, '-o', str(binary)], env=env, check=True)
    subprocess.run([str(binary)], check=True)
