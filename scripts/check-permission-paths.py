#!/usr/bin/env python3
"""Guard permission ownership and the absence of prompts on background paths."""
from pathlib import Path
root = Path(__file__).resolve().parents[1] / 'boringNotch'
audio = (root / 'managers/MusicEdgeAudio.swift').read_text()
configure = audio.split('func configure(', 1)[1].split('func stream(', 1)[0]
assert configure.index('guard CGPreflightScreenCaptureAccess()') < configure.index('SCShareableContent.')
assert 'CGRequestScreenCaptureAccess' not in configure
assert audio.count('CGRequestScreenCaptureAccess()') == 1
client = (root / 'XPCHelperClient/XPCHelperClient.swift').read_text()
auth = client.split('// MARK: - Accessibility', 1)[1].split('// MARK: - Keyboard Brightness', 1)[0]
assert 'ensureRemoteService' not in auth and 'AXIsProcessTrusted()' in auth
assert 'AXIsProcessTrustedWithOptions' in auth
coordinator = (root / 'BoringViewCoordinator.swift').read_text()
assert 'ensureAccessibilityAuthorization(promptIfNeeded: true)' not in coordinator
assert 'startMonitoringAccessibilityAuthorization()' in coordinator
interceptor = (root / 'observers/MediaKeyInterceptor.swift').read_text()
assert '.tapDisabledByTimeout' in interceptor and '.tapDisabledByUserInput' in interceptor
assert 'Unmanaged.passRetained(cgEvent)' not in interceptor
print('Permission path checks passed.')
