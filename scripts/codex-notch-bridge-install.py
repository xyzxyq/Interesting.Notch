#!/usr/bin/env python3
"""Install/update or remove the current user's read-only Codex notch bridge."""
import argparse
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import os

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--uninstall', action='store_true')
args = parser.parse_args()
label = 'local.interestingnotch.codex-bridge'
folder = Path.home() / 'Library/Application Support/InterestingNotch/CodexBridge'
plist = Path.home() / 'Library/LaunchAgents' / (label + '.plist')
domain = 'gui/' + str(os.getuid())
if plist.exists():
    subprocess.run(['launchctl', 'bootout', domain, str(plist)], capture_output=True)
if args.uninstall:
    plist.unlink(missing_ok=True)
    print('Bridge stopped and LaunchAgent removed. Installed script retained at ' + str(folder))
else:
    folder.mkdir(parents=True, exist_ok=True)
    target = folder / 'codex-notch-bridge.py'
    shutil.copy2(Path(__file__).with_name(target.name), target)
    plist.parent.mkdir(parents=True, exist_ok=True)
    config = dict(Label=label, ProgramArguments=[str(Path(sys.executable).resolve()), str(target)],
                  RunAtLoad=True, KeepAlive=True, ThrottleInterval=10,
                  StandardOutPath=str(folder / 'bridge.log'), StandardErrorPath=str(folder / 'bridge.log'))
    if os.environ.get('CODEX_HOME'):
        config['EnvironmentVariables'] = {'CODEX_HOME': os.environ['CODEX_HOME']}
    with plist.open('wb') as stream:
        plistlib.dump(config, stream)
    subprocess.run(['launchctl', 'bootstrap', domain, str(plist)], check=True)
    print('Installed ' + str(plist))
    print('Read-only state: http://127.0.0.1:19427/state')
