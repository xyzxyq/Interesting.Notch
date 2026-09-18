#!/usr/bin/env python3
"""Verify fork-only update configuration and reject malformed release feeds."""
from pathlib import Path
import base64
import importlib.util
import plistlib
import tempfile
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('prepare_update', root / 'scripts/prepare-update.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
info = plistlib.loads((root / 'boringNotch/Info.plist').read_bytes())
assert info['SUFeedURL'] == module.FEED
assert len(base64.b64decode(info['SUPublicEDKey'], validate=True)) == 32
assert info['SUScheduledCheckInterval'] >= 86400
assert info['SUEnableAutomaticChecks'] and not info['SUAutomaticallyUpdate']
assert 'startingUpdater: true' in (root / 'boringNotch/boringNotchApp.swift').read_text()
view = (root / 'boringNotch/components/Settings/SoftwareUpdater.swift').read_text()
assert 'updater.checkForUpdates()' in view
assert 'automaticallyChecksForUpdates = $0' in view and 'automaticallyDownloadsUpdates = $0' in view
assert 'TheBoredTeam' not in view
bundle = dict(info, CFBundleIdentifier='theboringteam.boringnotch', CFBundleShortVersionString='3.0.7', CFBundleVersion='307')
module.validate_bundle(bundle, info, 'v3.0.7')
for key, value in [('CFBundleIdentifier', 'theboringteam.boringnotch.preview'),
                   ('SUPublicEDKey', 'wrong-key'), ('SUFeedURL', 'https://example.com/feed'),
                   ('CFBundleVersion', '0'), ('CFBundleShortVersionString', '3.0.6')]:
    invalid = dict(bundle, **{key: value})
    try:
        module.validate_bundle(invalid, info, 'v3.0.7')
        raise AssertionError(f'Accepted invalid bundle {key}')
    except ValueError:
        pass
with tempfile.TemporaryDirectory() as temp:
    archive = Path(temp) / 'InterestingNotch.dmg'
    archive.write_bytes(b'test archive')
    feed = Path(temp) / 'appcast.xml'
    rss = ET.Element('rss')
    item = ET.SubElement(ET.SubElement(rss, 'channel'), 'item')
    version = ET.SubElement(item, module.NS + 'shortVersionString')
    version.text = '3.0.7'
    ET.SubElement(item, module.NS + 'version').text = '307'
    enclosure = ET.SubElement(item, 'enclosure', {
        'url': 'https://github.com/xyzxyq/Interesting.Notch/releases/download/v3.0.7/InterestingNotch.dmg',
        'length': str(archive.stat().st_size), module.NS + 'edSignature': base64.b64encode(bytes(64)).decode()})
    def check():
        ET.ElementTree(rss).write(feed)
        return module.validate_feed(feed, archive, 'v3.0.7')
    assert check() == base64.b64encode(bytes(64)).decode()
    for key, bad in [('url', 'https://github.com/TheBoredTeam/boring.notch/releases/download/v3.0.7/a.dmg'),
                     ('url', enclosure.get('url').replace('v3.0.7', 'v3.0.6')),
                     ('length', '1'), (module.NS + 'edSignature', ''), (module.NS + 'edSignature', 'malformed')]:
        old = enclosure.get(key)
        enclosure.set(key, bad)
        try:
            check()
            raise AssertionError(f'Accepted invalid {key}')
        except ValueError:
            pass
        enclosure.set(key, old)
    version.text = '3.0.6'
    try:
        check()
        raise AssertionError('Accepted wrong version')
    except ValueError:
        pass
print('Update checks passed: fork isolation, opt-in installation, version, URL, size and signature presence')
