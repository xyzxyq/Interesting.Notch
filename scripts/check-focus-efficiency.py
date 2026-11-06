#!/usr/bin/env python3
"""Compile the actual focus components and measure identical, bounded scenes."""
from pathlib import Path
import os, plistlib, shutil, subprocess, sys, tempfile
root = Path(__file__).resolve().parents[1]
baseline = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else None
name = 'baseline' if baseline else 'optimized'
folder = root/'build/focus-efficiency-20261106'/name
folder.mkdir(parents=True, exist_ok=True)
app = Path(tempfile.mkdtemp(prefix='notch-focus-'+name+'-'))/'Focus Efficiency.app'
resources = app/'Contents/Resources'
binary = app/'Contents/MacOS/FocusEfficiency'
resources.mkdir(parents=True, exist_ok=True)
binary.parent.mkdir(parents=True, exist_ok=True)
(app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'local.notch.focus-efficiency',
    'CFBundleExecutable': binary.name, 'CFBundlePackageType': 'APPL', 'LSUIElement': True}))
library = (baseline/'default.metallib' if baseline and (baseline/'default.metallib').exists()
    else Path('/Applications/Interesting Notch.app/Contents/Resources/default.metallib') if baseline
    else root/'build/DerivedData/Build/Products/Release/Interesting Notch.app/Contents/Resources/default.metallib')
shutil.copy2(library, resources/'default.metallib')
paths = ['boringNotch/models/CompactLyrics.swift','boringNotch/models/ImmersiveFocus.swift',
    'boringNotch/components/Music/ImmersiveLyricsView.swift','boringNotch/components/Notch/BoringNotchWindow.swift',
    'boringNotch/components/Notch/FocusIdleView.swift',
    'scripts/FocusEfficiencyChecks.swift']
sources = [str(baseline/p if baseline and (baseline/p).exists() else root/p) for p in paths]
env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
sdk = subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'], env=env, text=True).strip()
subprocess.run(['xcrun','swiftc','-sdk',sdk,'-O','-assert-config','Debug','-swift-version','5',
    '-target','arm64-apple-macos14.0',*(['-D','FOCUS_BASELINE'] if baseline else []),
    *sources,'-o',str(binary)], env=env, check=True)
subprocess.run(['codesign','--force','--sign','-',str(app)], check=True)
result = app.parent/'metrics.json'
subprocess.run(['open','-W','-n',str(app),'--args',str(result)], check=True)
assert result.exists(), 'Profiling app did not complete its checks'
for suffix in ['', '.log', '.err']:
    generated = Path(str(result) + suffix)
    if generated.exists(): shutil.copy2(generated, folder/generated.name)
print(result.read_text())
