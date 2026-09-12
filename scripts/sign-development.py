#!/usr/bin/env python3
"""Sign local builds with one persistent, private identity (no system trust changes)."""
import os
from pathlib import Path
import secrets
import shlex
import subprocess
import sys
import tempfile

os.umask(0o077)
state = Path.home() / 'Library/Application Support/InterestingNotch/Signing'
state.mkdir(parents=True, exist_ok=True)
keychain = state / 'development.keychain-db'
password_file = state / 'keychain-password'
identity = 'InterestingNotch Local Development'

def run(*args):
    result = subprocess.run(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if result.returncode:
        raise SystemExit(f"{args[0]} failed (exit {result.returncode}); signing stopped.")

if not keychain.exists():
    if password_file.exists():
        raise SystemExit('Signing keychain missing: restore it before replacing the signing identity.')
    password = secrets.token_urlsafe(32)
    password_file.write_text(password)
    run('security', 'create-keychain', '-p', password, str(keychain))
    with tempfile.TemporaryDirectory() as temp:
        root = Path(temp)
        config = root / 'cert.cnf'
        config.write_text('''[req]
prompt = no
distinguished_name = dn
x509_extensions = ext
[dn]
CN = InterestingNotch Local Development
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
''')
        run('/usr/bin/openssl', 'req', '-x509', '-newkey', 'rsa:3072', '-nodes', '-days', '3650',
            '-config', str(config), '-keyout', str(root / 'key.pem'), '-out', str(state / 'certificate.pem'))
        run('/usr/bin/openssl', 'pkcs12', '-export', '-inkey', str(root / 'key.pem'),
            '-in', str(state / 'certificate.pem'), '-name', identity,
            '-out', str(root / 'identity.p12'), '-passout', 'pass:' + password)
        run('security', 'import', str(root / 'identity.p12'), '-k', str(keychain), '-P', password,
            '-T', '/usr/bin/codesign')
password = password_file.read_text()
run('security', 'unlock-keychain', '-p', password, str(keychain))
search_list = shlex.split(subprocess.check_output(['security', 'list-keychains', '-d', 'user'], text=True))
try:
    run('security', 'list-keychains', '-d', 'user', '-s', *search_list, str(keychain))
    run('codesign' , '--force', '--deep', '--sign', identity, '--keychain', str(keychain),
        '--timestamp=none', sys.argv[1])
    run('codesign', '--verify', '--deep', '--strict', sys.argv[1])
finally:
    run('security', 'list-keychains', '-d', 'user', '-s', *search_list)
    run('security', 'lock-keychain', str(keychain))
print('Stable development signature verified.')
