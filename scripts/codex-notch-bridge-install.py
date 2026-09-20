#!/usr/bin/env python3
"""Install/update or remove the current user's local Codex notch bridge."""
import argparse
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import os
import hashlib
import json
import socket
import tempfile
import time
import urllib.request

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--uninstall', action='store_true')
parser.add_argument('--python', action='store_true', help='Restore the retained Python implementation')
parser.add_argument('--binary', type=Path, help='Install a prebuilt native bridge instead of building from source')
args = parser.parse_args()
if args.python and args.binary:
    parser.error('--python and --binary are mutually exclusive')
label = 'local.interestingnotch.codex-bridge'
folder = Path.home() / 'Library/Application Support/InterestingNotch/CodexBridge'
plist = Path.home() / 'Library/LaunchAgents' / (label + '.plist')
domain = 'gui/' + str(os.getuid())
previous = plist.read_bytes() if plist.exists() else None
if args.uninstall:
    subprocess.run(['launchctl', 'bootout', domain, str(plist)], capture_output=True)
    plist.unlink(missing_ok=True)
    print('Bridge stopped and LaunchAgent removed. Installed files retained at ' + str(folder))
else:
    folder.mkdir(parents=True, exist_ok=True)
    old_config = plistlib.loads(previous) if previous else {}
    environment = dict(old_config.get('EnvironmentVariables', {}))
    if os.environ.get('CODEX_HOME'):
        environment['CODEX_HOME'] = os.environ['CODEX_HOME']
    if args.python:
        target = folder / 'codex-notch-bridge.py'
        shutil.copy2(Path(__file__).with_name(target.name), target)
        program = [str(Path(sys.executable).resolve()), str(target)]
    else:
        root = Path(__file__).resolve().parents[1]
        binary = args.binary.resolve() if args.binary else root / 'build/CodexBridge/codex-notch-bridge'
        if not args.binary:
            subprocess.run([str(Path(__file__).with_name('build-codex-bridge.sh')), str(binary)], check=True)
        subprocess.run(['codesign', '--verify', '--strict', str(binary)], check=True)
        # Versioned files keep the running executable and its rollback intact.
        digest = hashlib.sha256(binary.read_bytes()).hexdigest()[:16]
        target = folder / ('codex-notch-bridge-' + digest)
        if not target.exists():
            shutil.copy2(binary, target)
        elif target.read_bytes() != binary.read_bytes():
            raise SystemExit('Existing native bridge does not match its content hash.')
        target.chmod(0o755)
        subprocess.run(['codesign', '--verify', '--strict', str(target)], check=True)
        program = [str(target)]

    def health(port):
        # A launch must not depend on whether the user has Codex open right now.
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(f'http://127.0.0.1:{port}/state', timeout=1) as response:
            value = json.load(response)
            assert isinstance(value['connected'], bool) and isinstance(value['tasks'], list)
            assert len(value['replyToken']) >= 40

    # Preflight the complete executable before stopping the working service.
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 0))
        port = probe.getsockname()[1]
    child = subprocess.Popen(program + ['--port', str(port)],
                             env={**os.environ, **environment, 'CODEX_BRIDGE_CODEX_PATH': '/nonexistent'},
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(40):
            if child.poll() is not None:
                raise RuntimeError('Bridge preflight exited; previous service was left running.')
            try:
                health(port)
                break
            except (OSError, ValueError, KeyError, AssertionError):
                time.sleep(.1)
        else:
            raise RuntimeError('Bridge preflight failed; previous service was left running.')
    finally:
        child.terminate()
        try: child.wait(timeout=3)
        except subprocess.TimeoutExpired: child.kill(); child.wait()

    plist.parent.mkdir(parents=True, exist_ok=True)
    config = dict(Label=label, ProgramArguments=program,
                  RunAtLoad=True, KeepAlive=True, ThrottleInterval=10,
                  StandardOutPath=str(folder / 'bridge.log'), StandardErrorPath=str(folder / 'bridge.log'))
    if environment:
        config['EnvironmentVariables'] = environment
    if previous:
        with (folder / ('launch-agent-backup-' + str(time.time_ns()) + '.plist')).open('wb') as stream:
            stream.write(previous)
    subprocess.run(['launchctl', 'bootout', domain, str(plist)], capture_output=True)
    try:
        with tempfile.NamedTemporaryFile(dir=plist.parent, delete=False) as stream:
            plistlib.dump(config, stream)
            staged_plist = Path(stream.name)
        staged_plist.replace(plist)
        subprocess.run(['launchctl', 'bootstrap', domain, str(plist)], check=True)
        for _ in range(50):
            try:
                health(19427)
                break
            except (OSError, ValueError, KeyError, AssertionError):
                time.sleep(.1)
        else:
            raise RuntimeError('Installed bridge did not become healthy')
    except BaseException:
        subprocess.run(['launchctl', 'bootout', domain, str(plist)], capture_output=True)
        if previous:
            plist.write_bytes(previous)
            subprocess.run(['launchctl', 'bootstrap', domain, str(plist)], check=True)
        else:
            plist.unlink(missing_ok=True)
        raise
    print(('Installed Python fallback: ' if args.python else 'Installed native Swift bridge: ') + str(target))
    print('Read-only state: http://127.0.0.1:19427/state')
