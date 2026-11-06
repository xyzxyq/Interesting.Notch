#!/usr/bin/env python3
"""Exercise the production MusicManager source gate and MediaRemote diff reducer."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
manager = (root / 'boringNotch/managers/MusicManager.swift').read_text()
method = manager.split('private func updateFromPlaybackState(_ state: PlaybackState) {', 1)[1]
rejected = method.split('if ', 1)[1].split(' {', 1)[0]
ui = (root / 'boringNotch/ContentView.swift').read_text()
edge = (root / 'boringNotch/components/Notch/MusicEdgeEffect.swift').read_text()
lyrics_mode = ui.split('private var compactLyricsMode: Bool {', 1)[1].split('}', 1)[0].strip().replace('musicManager.isMusicSource', 'state.isMusicSource')
media_mode = ui.split('private var musicPresented: Bool {', 1)[1].split('}', 1)[0].strip()
edge_mode = edge.split('private var musicPlaying: Bool {', 1)[1].split('}', 1)[0].strip().replace('music.isMusicSource', 'state.isMusicSource').replace('music.isPlaying', 'state.isPlaying')
harness = '''import Foundation
struct Motion { let energySavingActive = false }
let motion = Motion()
func accepts(_ state: PlaybackState) -> Bool { return !(''' + rejected + ''') }
func lyrics(_ state: PlaybackState, enableCompactLyrics: Bool, immersiveFocusEnabled: Bool = false) -> Bool { ''' + lyrics_mode + ''' }
func edge(_ state: PlaybackState) -> Bool { ''' + edge_mode + ''' }
enum ContentType { case music, battery }
struct Coordinator {
    let expandingView = (show: false, type: ContentType.music)
    let musicLiveActivityEnabled = true
}
struct ViewModel { let hideOnClosed = false }
func focusedMedia(_ state: PlaybackState, idle: Bool = false, immersiveFocusEnabled: Bool = true) -> Bool {
    let coordinator = Coordinator(), vm = ViewModel()
    let musicManager = (isMusicSource: state.isMusicSource, isPlaying: state.isPlaying, isPlayerIdle: idle)
    return ''' + media_mode + '''
}
@main struct Check {
    static func main() throws {
        for source in ["com.apple.Music", "com.tencent.QQMusic", "com.netease.163music",
                       "com.spotify.client", "com.github.th-ch.youtube-music"] {
            assert(accepts(PlaybackState(bundleIdentifier: source)) && PlaybackState(bundleIdentifier: source).isMusicSource, "Music client rejected: \\(source)")
        }
        var song = PlaybackState(bundleIdentifier: "com.apple.Music")
        song.isPlaying = true
        assert(lyrics(song, enableCompactLyrics: true) && edge(song))
        assert(focusedMedia(song))
        assert(!lyrics(song, enableCompactLyrics: true, immersiveFocusEnabled: true), "Focus reserves the slot for album art")
        assert(!lyrics(song, enableCompactLyrics: false))
        song.isPlaying = false
        assert(!edge(song))
        assert(!focusedMedia(song), "Paused music must collapse immediately, even within the idle grace period")
        assert(focusedMedia(song, immersiveFocusEnabled: false), "Ordinary pause grace period must return after focus")
        // Synthetic video/unknown identities: rejection must not depend on a Douyin blacklist.
        for source in ["com.ss.iphone.ugc.Aweme", "com.douyin.desktop", "com.apple.Safari",
                       "com.google.Chrome", "test.unknown", "com.apple.Music.helper"] {
            var state = PlaybackState(bundleIdentifier: source)
            state.isPlaying = true
            assert(!lyrics(state, enableCompactLyrics: true) && !edge(state), "Video must not activate music-only effects")
            assert(accepts(state) && !state.isMusicSource, "Video must retain basic media UI without music mode: \\(source)")
            assert(!focusedMedia(state), "Non-music cannot take the focused slot: \\(source)")
            assert(focusedMedia(state, immersiveFocusEnabled: false), "Ordinary media must return after focus")
        }
        func update(_ json: String) throws -> NowPlayingUpdate {
            try JSONDecoder().decode(NowPlayingUpdate.self, from: Data(json.utf8))
        }
        var state = PlaybackState(bundleIdentifier: "com.apple.Music")
        state.isPlaying = true
        state = state.applying(try update(#"{"diff":true,"payload":{"parentApplicationBundleIdentifier":"com.douyin.desktop","bundleIdentifier":"com.apple.Music","playing":true}}"#))
        assert(accepts(state) && !state.isMusicSource, "Video parent must take precedence over child identity")
        assert(!focusedMedia(state), "Changing sources while still playing must hide non-music immediately")
        for playing in [false, true, false, true] {
            state = state.applying(try update("{\\"diff\\":true,\\"payload\\":{\\"playing\\":\\(playing)}}"))
            assert(accepts(state) && !state.isMusicSource, "Video diffs must retain basic media UI")
        }
        state = state.applying(try update(#"{"diff":true,"payload":{"bundleIdentifier":"com.netease.163music","playing":true}}"#))
        assert(accepts(state) && state.isPlaying, "Returning to music must reactivate")
        assert(focusedMedia(state), "Returning to playing music must restore the focused slot")
        state = state.applying(try update(#"{"diff":true,"payload":{"playing":false}}"#))
        assert(accepts(state) && !state.isPlaying, "Music pause must retain normal idle handling")
        assert(!focusedMedia(state))
        state = state.applying(try update(#"{"diff":false,"payload":{}}"#))
        assert(!accepts(state), "Missing source must end activity")
        print("Music source checks passed: clients, video/browser basic UI, parent identity, diffs and return to music")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='notch-source-check-') as temp:
    swift = Path(temp) / 'Check.swift'
    binary = Path(temp) / 'check'
    swift.write_text(harness)
    env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], env=env, text=True).strip()
    subprocess.run(['xcrun', 'swiftc', '-sdk', sdk, str(root / 'boringNotch/models/PlaybackState.swift'),
                    str(root / 'boringNotch/models/ImmersiveFocus.swift'),
                    str(root / 'boringNotch/models/CompactLyrics.swift'),
                    str(swift), '-o', str(binary)], env=env, check=True)
    subprocess.run([str(binary)], check=True)
