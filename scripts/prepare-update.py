#!/usr/bin/env python3
"""Create a signed GitHub Release appcast locally; never uploads or publishes."""
import argparse
import base64
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[1]
FEED = 'https://github.com/xyzxyq/Interesting.Notch/releases/latest/download/appcast.xml'
NS = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'


def validate_feed(path, archive, tag):
    items = ET.parse(path).getroot().findall('./channel/item')
    if len(items) != 1:
        raise ValueError('Expected exactly one release in the generated feed')
    item = items[0]
    enclosure = item.find('enclosure')
    version = item.findtext(NS + 'shortVersionString')
    build = item.findtext(NS + 'version')
    expected = f'https://github.com/xyzxyq/Interesting.Notch/releases/download/{tag}/{archive.name}'
    if enclosure is None or enclosure.get('url') != expected:
        raise ValueError('Update must download from this fork and exact release tag')
    if version != tag.removeprefix('v') or not build or not build.isdigit():
        raise ValueError('Release tag does not match the app version/build number')
    if enclosure.get('length') != str(archive.stat().st_size) or not enclosure.get(NS + 'edSignature'):
        raise ValueError('Missing update signature or incorrect archive length')
    signature = enclosure.get(NS + 'edSignature')
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise ValueError('Invalid Ed25519 signature format')
    return signature


def archive_info(archive):
    if archive.suffix == '.zip':
        with zipfile.ZipFile(archive) as source:
            entries = [name for name in source.namelist()
                       if re.fullmatch(r'[^/]+\.app/Contents/Info\.plist', name)]
            if len(entries) != 1:
                raise ValueError('Update archive must contain exactly one top-level app')
            return plistlib.loads(source.read(entries[0]))
    attached = subprocess.check_output(['hdiutil', 'attach', '-readonly', '-nobrowse', '-plist', str(archive)])
    mounts = [Path(entity['mount-point']) for entity in plistlib.loads(attached)['system-entities'] if 'mount-point' in entity]
    try:
        entries = [entry for mount in mounts for entry in mount.glob('*.app/Contents/Info.plist')]
        if len(entries) != 1:
            raise ValueError('Update volume must contain exactly one app')
        return plistlib.loads(entries[0].read_bytes())
    finally:
        for mount in mounts:
            subprocess.run(['hdiutil', 'detach', str(mount), '-quiet'], check=True)


def validate_bundle(bundle, expected, tag):
    if bundle.get('CFBundleIdentifier') != 'theboringteam.boringnotch':
        raise ValueError('Only the Release app can enter the public update channel')
    if bundle.get('SUFeedURL') != FEED or bundle.get('SUPublicEDKey') != expected['SUPublicEDKey']:
        raise ValueError('Archive update feed/key differs from the shipping configuration')
    if bundle.get('CFBundleShortVersionString') != tag.removeprefix('v'):
        raise ValueError('Archive version differs from release tag')
    build = str(bundle.get('CFBundleVersion', ''))
    if not build.isdigit() or int(build) <= 0:
        raise ValueError('Archive needs a positive build number')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive', type=Path, help='Signed .dmg or .zip containing the release app')
    parser.add_argument('tag', help='Stable version tag, e.g. v3.0.7')
    parser.add_argument('output', type=Path, help='New output directory for archive and appcast.xml')
    parser.add_argument('--sparkle-bin', required=True, type=Path)
    parser.add_argument('--key-file', type=Path, help='CI secret file; defaults to the project Keychain account')
    args = parser.parse_args()
    archive = args.archive.resolve()
    if not archive.is_file() or archive.suffix not in ('.dmg', '.zip'):
        parser.error('Expected an existing .dmg or .zip archive')
    if not re.fullmatch(r'v\d+\.\d+\.\d+', args.tag) or not re.fullmatch(r'[A-Za-z0-9._-]+', archive.name):
        parser.error('Use a stable vX.Y.Z tag and an archive filename without spaces')
    if args.output.exists():
        parser.error('Output directory already exists; refusing to overwrite')
    info = plistlib.loads((ROOT / 'boringNotch/Info.plist').read_bytes())
    if info.get('SUFeedURL') != FEED:
        parser.error('Unexpected update feed configuration')
    validate_bundle(archive_info(archive), info, args.tag)
    tools = args.sparkle_bin.resolve()
    signing = ['--ed-key-file', str(args.key_file.resolve())] if args.key_file else ['--account', 'xyzxyq.Interesting.Notch']
    with tempfile.TemporaryDirectory(prefix='notch-update-') as directory:
        staging = Path(directory)
        copied = staging / archive.name
        shutil.copy2(archive, copied)
        subprocess.run([str(tools / 'generate_appcast'), *signing, '--maximum-deltas', '0',
                        '--link', 'https://github.com/xyzxyq/Interesting.Notch/releases',
                        '--download-url-prefix', f'https://github.com/xyzxyq/Interesting.Notch/releases/download/{args.tag}/',
                        '-o', str(staging / 'appcast.xml'), str(staging)], check=True)
        signature = validate_feed(staging / 'appcast.xml', copied, args.tag)
        subprocess.run([str(tools / 'sign_update'), *signing, '--verify', str(copied), signature], check=True)
        subprocess.run(['xcrun', 'swift', str(ROOT / 'scripts/VerifyUpdate.swift'),
                        str(copied), signature, info['SUPublicEDKey']], check=True)
        args.output.mkdir(parents=True)
        shutil.copy2(staging / 'appcast.xml', args.output / 'appcast.xml')
        shutil.copy2(copied, args.output / copied.name)
    print(f'Verified update assets: {args.output.resolve()}')


if __name__ == '__main__':
    main()
