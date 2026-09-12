#!/usr/bin/env python3
"""Run fallback selection checks; --live also reports actual video output activity."""
from pathlib import Path
import os
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
controller = (root / 'boringNotch/MediaControllers/NowPlayingController.swift').read_text()
helper = 'import AppKit\nimport CoreAudio\nenum VideoAudioActivity {' + controller.split('enum VideoAudioActivity {', 1)[1]
with tempfile.TemporaryDirectory(prefix='notch-video-check-') as temp:
    source = Path(temp) / 'VideoAudioActivity.swift'
    source.write_text(helper)
    binary = Path(temp) / 'check'
    env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], env=env, text=True).strip()
    subprocess.run(['xcrun', 'swiftc', '-sdk', sdk, str(root / 'boringNotch/models/PlaybackState.swift'),
                    str(source), str(root / 'scripts/VideoAudioChecks.swift'), '-o', str(binary)], env=env, check=True)
    subprocess.run([str(binary), *sys.argv[1:]], check=True)
