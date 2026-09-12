#!/usr/bin/env python3
"""Read-only bridge for Codex Desktop's private, versioned local IPC.

Only UUIDs, runtime status, effort and allowance summary leave the process. No transcript, title, command,
model prompt, or approval reply is exposed. Codex upgrades can break this API;
unknown stream versions fail closed. Install with codex-notch-bridge-install.py.
"""
import argparse
import math
import select
import subprocess
import shutil
import json
import os
from pathlib import Path
import socket
import sqlite3
import struct
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = 19427
STREAM_VERSION = 11
MAX_FRAME = 256 * 1024 * 1024


def task_state(runtime):
    if not isinstance(runtime, dict) or runtime.get('type') != 'active':
        return None
    flags = runtime.get('activeFlags', [])
    return 'waiting' if any(x in flags for x in ('waitingOnApproval', 'waitingOnUserInput')) else 'running'


def update_runtime(runtime, change):
    """Project Immer patches onto runtime status, ignoring all conversation text."""
    if change.get('type') == 'snapshot':
        return change['conversationState'].get('threadRuntimeStatus')
    for patch in change.get('patches', []):
        path = patch['path']
        if not path:
            runtime = patch.get('value', {}).get('threadRuntimeStatus')
        elif path[0] == 'threadRuntimeStatus':
            if len(path) == 1:
                runtime = patch.get('value')
            elif len(path) == 2 and runtime is not None:
                if patch['op'] == 'remove':
                    runtime.pop(path[1], None)
                else:
                    runtime[path[1]] = patch['value']
            elif len(path) == 3 and path[1] == 'activeFlags' and runtime is not None:
                flags = runtime.setdefault('activeFlags', [])
                index = int(path[2])
                if patch['op'] == 'remove':
                    flags.pop(index)
                elif patch['op'] == 'add':
                    flags.insert(index, patch['value'])
                else:
                    flags[index] = patch['value']
            else:
                raise ValueError('Unsupported runtime patch')
    return runtime


def update_effort(previous, change):
    if change.get('type') == 'snapshot':
        settings = change.get('conversationState', {}).get('latestThreadSettings') or {}
        previous = settings.get('effort')
    else:
        for patch in change.get('patches', []):
            path = patch.get('path')
            value = patch.get('value')
            if path == []:
                previous = ((value or {}).get('latestThreadSettings') or {}).get('effort')
            elif path == ['latestThreadSettings']:
                previous = (value or {}).get('effort')
            elif path == ['latestThreadSettings', 'effort']:
                previous = value
    return previous if previous in ('low', 'medium', 'high', 'xhigh', 'max', 'ultra') else None


def update_model(previous, change):
    fields = ('model', 'modelProvider')
    values = dict(previous or {})
    if change.get('type') == 'snapshot':
        values = change.get('conversationState', {}).get('latestThreadSettings') or {}
    else:
        for patch in change.get('patches', []):
            path, value = patch.get('path'), patch.get('value')
            if path == []:
                values = (value or {}).get('latestThreadSettings') or {}
            elif path == ['latestThreadSettings']:
                values = value or {}
            elif len(path or []) == 2 and path[0] == 'latestThreadSettings' and path[1] in fields:
                values[path[1]] = value
    return {key: value for key in fields if isinstance(value := values.get(key), str)
            and 0 < len(value) <= 120 and all(c.isalnum() or c in '-_./: ' for c in value)}


def fuel_snapshot(result, now, weekly=False):
    """Only the main Codex allowance; credits and other model buckets are separate."""
    buckets = result.get('rateLimitsByLimitId')
    quota = buckets.get('codex') if isinstance(buckets, dict) else result.get('rateLimits')
    if not isinstance(quota, dict) or quota.get('limitId') not in (None, 'codex'):
        return None
    plan = quota.get('planType')
    minutes = (10080 if weekly else 300) if plan == 'plus' else 10080 if plan in ('pro', 'prolite', 'team', 'business', 'enterprise', 'edu') else None
    if minutes is None:
        return None
    for key in ('primary', 'secondary'):
        window = quota.get(key)
        if not isinstance(window, dict) or window.get('windowDurationMins') != minutes:
            continue
        used, reset = window.get('usedPercent'), window.get('resetsAt')
        if any(isinstance(x, bool) or not isinstance(x, (int, float)) or not math.isfinite(x) for x in (used, reset)):
            return None
        if not 0 <= used <= 100 or reset <= now:
            return None
        return dict(remainingPercent=100-used, windowMinutes=minutes, resetsAt=reset, updatedAt=now)
    return None


def read_fuel(home):
    # Use the bundled read-only account RPC, never credentials or a model turn.
    candidates = [Path('/Applications/ChatGPT.app/Contents/Resources/codex'),
                  Path('/Applications/Codex.app/Contents/Resources/codex')]
    binary = next((str(p) for p in candidates if p.is_file()), None) or shutil.which('codex')
    if not binary:
        return None
    env = dict(os.environ, CODEX_HOME=str(home))
    with subprocess.Popen([binary, 'app-server'], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                          stderr=subprocess.DEVNULL, env=env) as process:
        def send(message):
            process.stdin.write((json.dumps(message) + '\n').encode())
            process.stdin.flush()
        try:
            send(dict(id=1, method='initialize', params=dict(clientInfo=dict(name='interesting_notch', version='1.0'))))
            buffer = b''
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline:
                if not select.select([process.stdout], [], [], 1)[0]:
                    continue
                chunk = os.read(process.stdout.fileno(), 65536)
                if not chunk:
                    break
                buffer += chunk
                if len(buffer) > 2_000_000:
                    break
                while b'\n' in buffer:
                    line, buffer = buffer.split(b'\n', 1)
                    message = json.loads(line)
                    if message.get('id') == 1:
                        if 'error' in message:
                            return None
                        send(dict(method='initialized'))
                        send(dict(id=2, method='account/rateLimits/read'))
                    elif message.get('id') == 2:
                        result, now = message.get('result') or {}, time.time()
                        primary = fuel_snapshot(result, now)
                        week = fuel_snapshot(result, now, weekly=True)
                        windows = {w['windowMinutes']: w for w in (primary, week) if w}
                        return dict(fuel=primary, allowances=list(windows.values()))
        finally:
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
    return None


class Bridge:
    def __init__(self, home):
        self.home = home
        self.connected = False
        self.last_contact = 0
        self.runtimes = {}
        self.fuel = None
        self.allowances = []
        self.lock = threading.Lock()

    def snapshot(self):
        with self.lock:
            tasks = []
            now = time.time()
            fresh = self.connected and now - self.last_contact < 45
            # Refresh live snapshots periodically: even a silent long tool run
            # stays fresh, while a hung owner cannot leave a phantom rocket.
            if any(task_state(entry['runtime']) and now - entry.get('receivedAt', now) >= 45
                   for entry in self.runtimes.values()):
                fresh = False
            for (host, task_id), entry in self.runtimes.items():
                state = task_state(entry['runtime'])
                if state:
                    tasks.append(dict(id=task_id, hostId=host, title='Codex task', state=state, reasoningEffort=entry.get('effort'),
                                      model=entry.get('model', {}).get('model'), modelProvider=entry.get('model', {}).get('modelProvider'),
                                      detail='Needs your attention in Codex' if state == 'waiting' else 'Codex is working'))
            return dict(connected=fresh, tasks=tasks if fresh else [], updatedAt=self.last_contact,
                        allowances=[w for w in self.allowances if now - w['updatedAt'] < 150 and now < w['resetsAt']],
                        fuel=self.fuel if self.fuel and now - self.fuel['updatedAt'] < 150 and now < self.fuel['resetsAt'] else None)

    def refresh_fuel(self):
        while True:
            try:
                value = read_fuel(self.home)
            except (OSError, ValueError, TypeError, AttributeError):
                value = None
            with self.lock:
                self.fuel = (value or {}).get('fuel')
                self.allowances = (value or {}).get('allowances', [])
            time.sleep(60)

    def ids(self):
        # ponytail: bootstrap 100 recent local tasks; runtime broadcasts discover
        # newly active tasks. Add a supported global catalog when Codex exposes one.
        db = self.home / 'state_5.sqlite'
        with sqlite3.connect(db.as_uri() + '?mode=ro', uri=True) as conn:
            return [row[0] for row in conn.execute(
                'SELECT id FROM threads WHERE archived = 0 ORDER BY updated_at DESC LIMIT 100')]

    def run(self):
        while True:
            try:
                self.listen()
            except (OSError, ValueError, KeyError, TypeError, IndexError, sqlite3.Error):
                pass  # No sensitive IPC payloads enter logs.
            with self.lock:
                self.connected = False
                self.runtimes.clear()
            time.sleep(2)

    def listen(self):
        with socket.socket(socket.AF_UNIX) as sock:
            sock.settimeout(1)
            sock.connect(str(self.home / 'ipc' / 'ipc.sock'))
            def send(message):
                body = json.dumps(message).encode()
                sock.sendall(struct.pack('<I', len(body)) + body)
            def follow(host, task_id):
                uuid.UUID(task_id)
                send(dict(type='broadcast', method='thread-stream-following-changed', version=1,
                          params=dict(conversationId=task_id, hostId=host, following=True)))
            send(dict(type='request', requestId='notch-init', method='initialize', version=0,
                      params=dict(clientType='interesting-notch')))
            subscribed = set()
            buffer = bytearray()
            next_discovery = 0
            next_refresh = time.monotonic() + 15
            while True:
                if time.monotonic() >= next_discovery:
                    for task_id in self.ids():
                        key = ('local', task_id)
                        if key not in subscribed:
                            follow(*key)
                            subscribed.add(key)
                    next_discovery = time.monotonic() + 10
                if time.monotonic() >= next_refresh:
                    # Re-registering is a read-only router heartbeat; existing
                    # follower=true requests resend snapshots without task mutation.
                    send(dict(type='request', requestId='notch-init', method='initialize', version=0,
                              params=dict(clientType='interesting-notch')))
                    with self.lock:
                        active_keys = [key for key, entry in self.runtimes.items() if task_state(entry['runtime'])]
                    for key in active_keys:
                        follow(*key)
                    next_refresh = time.monotonic() + 15
                try:
                    chunk = sock.recv(65536)
                except socket.timeout:
                    continue
                if not chunk:
                    raise ConnectionError('IPC closed')
                buffer.extend(chunk)
                while len(buffer) >= 4:
                    size = struct.unpack_from('<I', buffer)[0]
                    if not 0 < size <= MAX_FRAME:
                        raise ValueError('Invalid frame size')
                    if len(buffer) < size + 4:
                        break
                    message = json.loads(buffer[4:size + 4])
                    del buffer[:size + 4]
                    kind = message.get('type')
                    if kind == 'client-discovery-request':
                        send(dict(type='client-discovery-response', requestId=message['requestId'],
                                  response=dict(canHandle=False)))
                    elif kind == 'response' and message.get('requestId') == 'notch-init':
                        if message.get('resultType') != 'success':
                            raise ValueError('IPC initialization failed')
                        with self.lock:
                            self.connected = True
                            self.last_contact = time.time()
                    elif kind == 'broadcast':
                        method = message.get('method')
                        params = message.get('params', {})
                        if method in ('thread-stream-following-status-requested', 'thread-stream-following-changed'):
                            key = (params.get('hostId', 'local'), params['conversationId'])
                            if key not in subscribed:
                                follow(*key)
                                subscribed.add(key)
                        elif method == 'thread-stream-state-changed':
                            if message.get('version') != STREAM_VERSION:
                                raise ValueError('Unsupported Codex stream version')
                            key = (params['hostId'], params['conversationId'])
                            uuid.UUID(key[1])
                            change = params['change']
                            with self.lock:
                                entry = self.runtimes.get(key)
                                if change['type'] == 'patches' and (entry is None or entry['revision'] != change['baseRevision']):
                                    self.runtimes.pop(key, None)
                                    follow(*key)
                                    continue
                                runtime = update_runtime(entry['runtime'] if entry else None, change)
                                effort = update_effort(entry.get('effort') if entry else None, change)
                                model = update_model(entry.get('model') if entry else None, change)
                                self.runtimes[key] = dict(runtime=runtime, effort=effort, model=model, revision=change['revision'], owner=message.get('sourceClientId'), receivedAt=time.time())
                                self.last_contact = time.time()
                        elif method in ('ipc-connection-reset', 'client-status-changed'):
                            if method == 'ipc-connection-reset' or params.get('status') == 'disconnected':
                                with self.lock:
                                    self.runtimes = {k: v for k, v in self.runtimes.items() if method != 'ipc-connection-reset' and v['owner'] != params.get('clientId')}
                                subscribed.clear()
                                next_discovery = 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', type=int, default=PORT)
    args = parser.parse_args()
    bridge = Bridge(Path(os.environ.get('CODEX_HOME', str(Path.home() / '.codex'))).resolve())
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            # Reject browser origins and DNS rebinding; no CORS and no write API.
            if self.headers.get('Origin') or self.headers.get('Host') != f'127.0.0.1:{args.port}':
                self.send_error(403)
                return
            if self.path != '/state':
                self.send_error(404)
                return
            body = json.dumps(bridge.snapshot()).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Cache-Control', 'no-store')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        def log_message(self, *_):
            pass
    server = HTTPServer(('127.0.0.1', args.port), Handler)
    threading.Thread(target=bridge.run, daemon=True).start()
    threading.Thread(target=bridge.refresh_fuel, daemon=True).start()
    server.serve_forever()


if __name__ == '__main__':
    main()
