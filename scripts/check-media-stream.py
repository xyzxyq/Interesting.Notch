#!/usr/bin/env python3
"""Exercise the production pipe reader with fragmented UTF-8 and delayed artwork."""
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'boringNotch/MediaControllers/NowPlayingController.swift').read_text()
reader = source[source.index('actor JSONLinesPipeHandler {'):source.index('// MARK: - Audio-only video presence')]
check = r'''
actor Recorder {
    var states: [PlaybackState] = []
    func accept(_ update: NowPlayingUpdate) {
        states.append((states.last ?? PlaybackState(bundleIdentifier: "")).applying(update))
    }
}
@main struct Check {
    static func main() async throws {
        let handler = JSONLinesPipeHandler()
        let pipe = await handler.getPipe()
        let recorder = Recorder()
        let reading = Task {
            await handler.readJSONLines(as: NowPlayingUpdate.self) { await recorder.accept($0) }
        }
        let artwork = Data(repeating: 42, count: 150_000)
        let first = Data(#"{"payload":{"bundleIdentifier":"com.apple.Music","title":"旧歌","artworkData":"AQ=="}}"#.utf8)
        let next = Data(#"{"payload":{"bundleIdentifier":"com.apple.Music","title":"新歌"}}"#.utf8)
        let art = Data("{\"diff\":true,\"payload\":{\"artworkData\":\"\(artwork.base64EncodedString())\"}}\n".utf8)
        // Force a pipe read to end in the middle of the first Chinese character.
        let split = first.firstIndex(of: 0xE6)!
        let prefix = Data(first[...split])
        let suffix = Data(first[(split + 1)...]) + Data([10]) + next + Data([10])
        let writer = Task.detached {
            try pipe.fileHandleForWriting.write(contentsOf: prefix)
            try await Task.sleep(for: .milliseconds(100))
            try pipe.fileHandleForWriting.write(contentsOf: suffix)
            try await Task.sleep(for: .milliseconds(100))
            try pipe.fileHandleForWriting.write(contentsOf: art)
            try pipe.fileHandleForWriting.close()
        }
        try await writer.value
        await reading.value
        let states = await recorder.states
        assert(states.count == 3, "Every complete event must survive chunk boundaries")
        assert(states[0].title == "旧歌" && states[0].artwork == Data([1]))
        assert(states[1].title == "新歌" && states[1].artwork == nil)
        assert(states[2].title == "新歌" && states[2].artwork == artwork)
        print("Media stream checks passed: split UTF-8, multiple lines, large delayed artwork, track replacement")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='interesting-media-check-') as temp:
    path = Path(temp)
    (path / 'Check.swift').write_text('import Foundation\n' + reader + check)
    env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
    subprocess.run(['xcrun', 'swiftc', str(root / 'boringNotch/models/PlaybackState.swift'), str(path / 'Check.swift'), '-o', str(path / 'check')], env=env, check=True)
    subprocess.run([str(path / 'check')], timeout=15, check=True)
