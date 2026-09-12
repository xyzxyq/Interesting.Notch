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
edge_mode = edge.split('private var musicPlaying: Bool {', 1)[1].split('}', 1)[0].strip().replace('music.isMusicSource', 'state.isMusicSource').replace('music.isPlaying', 'state.isPlaying')
harness = '''import Foundation
func accepts(_ state: PlaybackState) -> Bool { return !(''' + rejected + ''') }
func lyrics(_ state: PlaybackState, enableCompactLyrics: Bool) -> Bool { ''' + lyrics_mode + ''' }
func edge(_ state: PlaybackState) -> Bool { ''' + edge_mode + ''' }
@main struct Check {
    static func main() throws {
        for source in ["com.apple.Music", "com.tencent.QQMusic", "com.netease.163music",
                       "com.spotify.client", "com.github.th-ch.youtube-music"] {
            assert(accepts(PlaybackState(bundleIdentifier: source)) && PlaybackState(bundleIdentifier: source).isMusicSource, "Music client rejected: \\(source)")
        }
        var song = PlaybackState(bundleIdentifier: "com.apple.Music")
        song.isPlaying = true
        assert(lyrics(song, enableCompactLyrics: true) && edge(song))
        assert(!lyrics(song, enableCompactLyrics: false))
        song.isPlaying = false
        assert(!edge(song))
        // Synthetic video/unknown identities: rejection must not depend on a Douyin blacklist.
        for source in ["com.ss.iphone.ugc.Aweme", "com.douyin.desktop", "com.apple.Safari",
                       "com.google.Chrome", "test.unknown", "com.apple.Music.helper"] {
            var state = PlaybackState(bundleIdentifier: source)
            state.isPlaying = true
            assert(!lyrics(state, enableCompactLyrics: true) && !edge(state), "Video must not activate music-only effects")
            assert(accepts(state) && !state.isMusicSource, "Video must retain basic media UI without music mode: \\(source)")
        }
        func update(_ json: String) throws -> NowPlayingUpdate {
            try JSONDecoder().decode(NowPlayingUpdate.self, from: Data(json.utf8))
        }
        var state = PlaybackState(bundleIdentifier: "com.apple.Music")
        state.isPlaying = true
        state = state.applying(try update(#"{"diff":true,"payload":{"parentApplicationBundleIdentifier":"com.douyin.desktop","bundleIdentifier":"com.apple.Music","playing":true}}"#))
        assert(accepts(state) && !state.isMusicSource, "Video parent must take precedence over child identity")
        for playing in [false, true, false, true] {
            state = state.applying(try update("{\\"diff\\":true,\\"payload\\":{\\"playing\\":\\(playing)}}"))
            assert(accepts(state) && !state.isMusicSource, "Video diffs must retain basic media UI")
        }
        state = state.applying(try update(#"{"diff":true,"payload":{"bundleIdentifier":"com.netease.163music","playing":true}}"#))
        assert(accepts(state) && state.isPlaying, "Returning to music must reactivate")
        state = state.applying(try update(#"{"diff":true,"payload":{"playing":false}}"#))
        assert(accepts(state) && !state.isPlaying, "Music pause must retain normal idle handling")
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
                    str(swift), '-o', str(binary)], env=env, check=True)
    subprocess.run([str(binary)], check=True)
