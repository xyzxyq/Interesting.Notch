#!/usr/bin/env python3
"""Ensure fork releases cannot start the upstream updater."""
from pathlib import Path
import plistlib
root = Path(__file__).resolve().parents[1] / 'boringNotch'
info = plistlib.loads((root / 'Info.plist').read_bytes())
assert 'SUFeedURL' not in info and 'SUPublicEDKey' not in info
assert 'startingUpdater: true' not in (root / 'boringNotchApp.swift').read_text()
view = (root / 'components/Settings/SoftwareUpdater.swift').read_text()
assert 'https://github.com/xyzxyq/Interesting.Notch/releases' in view
assert 'updater.checkForUpdates' not in view
print('Release update isolation checks passed.')
