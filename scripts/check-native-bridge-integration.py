#!/usr/bin/env python3
"""Exercise the native executable against a fake Codex router, never real user tasks."""
from http.client import HTTPConnection
import json
import os
from pathlib import Path
import queue
import plistlib
import runpy
import socket
import sqlite3
import struct
import subprocess
import sys
import tempfile
import threading
import time
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
TASK = '11111111-1111-4111-8111-111111111111'


def frame(value):
    body = json.dumps(value).encode()
    return struct.pack('<I', len(body)) + body


def receive(peer):
    def exact(count):
        data = b''
        while len(data) < count:
            part = peer.recv(count - len(data))
            if not part:
                raise EOFError()
            data += part
        return data
    length = struct.unpack('<I', exact(4))[0]
    return json.loads(exact(length))


def check_installer(binary):
    # Only the filesystem is real here; never load/unload the user's LaunchAgent.
    original_run = subprocess.run
    original_popen = subprocess.Popen
    with tempfile.TemporaryDirectory(prefix='notch-install-') as directory:
        home = Path(directory)
        plist = home / 'Library/LaunchAgents/local.interestingnotch.codex-bridge.plist'
        plist.parent.mkdir(parents=True)
        previous = plistlib.dumps(dict(Label='local.interestingnotch.codex-bridge',
                                      ProgramArguments=['old-bridge'], EnvironmentVariables={'CODEX_HOME':'preserved'}))
        for scenario in ['preflight-failure', 'bootstrap-failure', 'success']:
            plist.write_bytes(previous)
            launches = []
            def run(command, **kwargs):
                if command[0] != 'launchctl':
                    return original_run(command, **kwargs)
                launches.append(command)
                if scenario == 'bootstrap-failure' and command[1] == 'bootstrap' and sum(c[1] == 'bootstrap' for c in launches) == 1:
                    raise subprocess.CalledProcessError(1, command)
                return subprocess.CompletedProcess(command, 0)
            child = Mock()
            child.poll.return_value = 1 if scenario == 'preflight-failure' else None
            with patch.object(Path, 'home', return_value=home), \
                 patch.object(sys, 'argv', ['installer', '--binary', str(binary.resolve())]), \
                 patch('subprocess.run', side_effect=run), \
                 patch('subprocess.Popen', side_effect=lambda command, **kwargs: original_popen(command, **kwargs) if command[0] == 'codesign' else child), \
                 patch('json.load', return_value=dict(connected=False, tasks=[], replyToken='x'*43)), \
                 patch('urllib.request.build_opener'), patch('builtins.print'):
                try:
                    runpy.run_path(str(ROOT / 'scripts/codex-notch-bridge-install.py'), run_name='__main__')
                    assert scenario == 'success'
                except (RuntimeError, subprocess.CalledProcessError):
                    assert scenario != 'success'
            if scenario == 'success':
                installed = plistlib.loads(plist.read_bytes())
                assert installed['EnvironmentVariables']['CODEX_HOME'] == (os.environ.get('CODEX_HOME') or 'preserved')
                assert Path(installed['ProgramArguments'][0]).is_file()
            else:
                assert plist.read_bytes() == previous
            if scenario == 'preflight-failure':
                assert not launches, 'Preflight failure stopped the working service'
            elif scenario == 'bootstrap-failure':
                assert [c[1] for c in launches] == ['bootout', 'bootstrap', 'bootout', 'bootstrap']
    print('PASS: installer preflight isolation, failed-launch rollback, successful install and preserved environment')


def main():
    binary = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / 'build/CodexBridge/codex-notch-bridge'
    if not binary.is_file():
        raise SystemExit(f'Build the native bridge first or pass its executable path: {binary}')
    check_installer(binary)
    with tempfile.TemporaryDirectory(prefix='notch-ipc-', dir='/tmp') as directory:
        home = Path(directory)
        (home / 'ipc').mkdir()
        with sqlite3.connect(home / 'state_5.sqlite') as db:
            db.execute('CREATE TABLE threads (id TEXT, archived INTEGER, updated_at INTEGER)')
            db.execute('INSERT INTO threads VALUES (?, 0, 1)', (TASK,))
        fake = home / 'codex'
        fake.write_text('''#!/usr/bin/python3
import json,sys,time
for line in sys.stdin:
    item=json.loads(line)
    if item.get('id') == 1: print(json.dumps({'id':1,'result':{}}),flush=True)
    if item.get('id') == 2:
        print(json.dumps({'id':2,'result':{'rateLimitsByLimitId':{'codex':{'planType':'plus',
            'primary':{'usedPercent':25,'windowDurationMins':300,'resetsAt':time.time()+600},
            'secondary':{'usedPercent':40,'windowDurationMins':10080,'resetsAt':time.time()+600}}}}}),flush=True)
''')
        fake.chmod(0o700)
        server = socket.socket(socket.AF_UNIX)
        server.bind(str(home / 'ipc/ipc.sock')); server.listen(); server.settimeout(0.2)
        streams, replies = queue.Queue(), queue.Queue()
        stop = threading.Event()
        sockets = []
        reply_mode = ['success']

        def client(peer):
            try:
                while not stop.is_set():
                    message = receive(peer)
                    if message.get('method') == 'initialize':
                        peer.sendall(frame(dict(type='response', requestId=message['requestId'], resultType='success')))
                        if message['requestId'] == 'notch-init':
                            streams.put(peer)
                    elif message.get('type') == 'request':
                        replies.put(message)
                        if reply_mode[0] == 'disconnect':
                            peer.shutdown(socket.SHUT_RDWR); peer.close(); return
                        peer.sendall(frame(dict(type='response', requestId=message['requestId'], resultType=reply_mode[0], error='rejected' if reply_mode[0] != 'success' else None)))
            except (OSError, EOFError):
                pass

        def accept():
            while not stop.is_set():
                try:
                    peer, _ = server.accept(); sockets.append(peer)
                    threading.Thread(target=client, args=(peer,), daemon=True).start()
                except socket.timeout:
                    continue
                except OSError:
                    return

        threading.Thread(target=accept, daemon=True).start()
        with socket.socket() as reserve:
            reserve.bind(('127.0.0.1', 0)); port = reserve.getsockname()[1]
        env = dict(os.environ, CODEX_HOME=str(home), CODEX_BRIDGE_CODEX_PATH=str(fake))
        process = subprocess.Popen([str(binary), '--port', str(port)], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        def http(method='GET', path='/state', data=None, headers=None):
            conn = HTTPConnection('127.0.0.1', port, timeout=3)
            try:
                conn.request(method, path, body=json.dumps(data).encode() if data is not None else None, headers=headers or {})
                response = conn.getresponse()
                body = response.read()
                return response.status, json.loads(body) if body else {}
            finally:
                conn.close()

        def expect(predicate):
            end = time.monotonic() + 6
            value = None
            while time.monotonic() < end:
                assert process.poll() is None, process.stderr.read().decode()
                try:
                    status, value = http()
                    if status == 200 and predicate(value):
                        return value
                except OSError:
                    pass
                time.sleep(.02)
            raise AssertionError(value)

        try:
            peer = streams.get(timeout=6)
            snapshot = expect(lambda v: v['connected'] and v['fuel'] is not None)
            assert snapshot['fuel']['remainingPercent'] == 75
            assert len(snapshot['allowances']) == 2
            token = snapshot['replyToken']
            assert len(token) >= 40
            def emit(change, version=11, host='local'):
                message = dict(type='broadcast', method='thread-stream-state-changed', version=version,
                               sourceClientId='owner', params=dict(hostId=host, conversationId=TASK, change=change))
                payload = frame(message)
                peer.sendall(payload[:2]); peer.sendall(payload[2:])

            def state(runtime, revision, **values):
                emit(dict(type='snapshot', revision=revision, conversationState=dict(threadRuntimeStatus=runtime, **values)))

            state(dict(type='active'), 1, latestThreadSettings=dict(effort='high', model='gpt-6-astra', cwd='PRIVATE'))
            snapshot = expect(lambda v: len(v['tasks']) == 1)
            assert snapshot['tasks'][0]['state'] == 'running' and 'PRIVATE' not in json.dumps(snapshot)
            emit(dict(type='patches', baseRevision=1, revision=2, patches=[dict(op='add', path=['threadRuntimeStatus','activeFlags',0], value='waitingOnApproval')]))
            expect(lambda v: v['tasks'] and not v['tasks'][0]['isRunning'])
            emit(dict(type='patches', baseRevision=2, revision=3, patches=[dict(op='remove', path=['threadRuntimeStatus','activeFlags',0])]))
            expect(lambda v: v['tasks'] and v['tasks'][0]['isRunning'])
            emit(dict(type='patches', baseRevision=99, revision=100, patches=[]))
            snapshot = expect(lambda v: not v['tasks'])
            assert not snapshot['idleTaskIds'], 'A revision gap is not completion'

            question = dict(type='agentMessage', id='q1', delivery='async', questions=[dict(title='Fixture question', options=['A','B'])])
            state(dict(type='active'), 5, turns=[dict(items=[question])])
            snapshot = expect(lambda v: v['tasks'] and v['tasks'][0]['pendingQuestionIds'])
            item = snapshot['tasks'][0]
            assert item['state'] == 'waiting' and item['isRunning']
            request = dict(hostId='local', taskId=TASK, questionId=item['pendingQuestionIds'][0], answer='PRIVATE_ANSWER')
            assert http('GET', headers={'Origin':'https://example.com'})[0] == 403
            assert http('GET', headers={'Host':'example.com'})[0] == 403
            assert http('POST', '/answer', request)[0] == 403
            assert http('POST', '/answer', request, {'X-Notch-Token':'wrong'})[0] == 403
            auth = {'X-Notch-Token':token}
            assert http('POST', '/answer', dict(request, questionId='stale'), auth)[0] == 409
            assert http('POST', '/answer', request, auth) == (200, {'accepted':True})
            sent = replies.get(timeout=2)
            assert sent['method'] == 'thread-follower-steer-turn' and sent['version'] == 1
            assert sent['params']['restoreMessage']['context'] == {}
            assert 'PRIVATE_ANSWER' not in json.dumps(http()[1])
            assert http('POST', '/answer', request, auth)[0] == 409
            assert replies.empty(), 'Duplicate submission reached Codex'
            question['id'] = 'q2'
            state(dict(type='idle'), 6, turns=[dict(items=[question])])
            snapshot = expect(lambda v: v['idleTaskIds'])
            assert snapshot['tasks'][0]['state'] == 'waiting' and not snapshot['tasks'][0]['isRunning']
            request['questionId'] = snapshot['tasks'][0]['pendingQuestionIds'][0]
            assert http('POST', '/answer', request, auth)[0] == 200
            sent = replies.get(timeout=2)
            assert sent['method'] == 'thread-follower-start-turn' and sent['params']['turnStart']['context']['inheritThreadSettings']
            question['id'] = 'q3'
            state(dict(type='active'), 7, turns=[dict(items=[question])])
            snapshot = expect(lambda v: v['tasks'] and 'q3' in v['tasks'][0]['pendingQuestionIds'][0])
            request['questionId'] = snapshot['tasks'][0]['pendingQuestionIds'][0]
            reply_mode[0] = 'disconnect'
            assert http('POST', '/answer', request, auth)[0] == 409
            replies.get(timeout=2)
            assert http('POST', '/answer', request, auth)[0] == 409 and replies.empty()

            # A definite rejection permits retry; a remote task uses its host-aware RPC.
            question['id'] = 'remote-question'
            emit(dict(type='snapshot', revision=1, conversationState=dict(
                threadRuntimeStatus=dict(type='active'), turns=[dict(items=[question])])), host='remote-test')
            snapshot = expect(lambda v: any(t['hostId'] == 'remote-test' for t in v['tasks']))
            remote = next(t for t in snapshot['tasks'] if t['hostId'] == 'remote-test')
            request = dict(request, hostId='remote-test', questionId=remote['pendingQuestionIds'][0])
            reply_mode[0] = 'error'
            assert http('POST', '/answer', request, auth)[0] == 409
            sent = replies.get(timeout=2)
            assert sent['version'] == 2 and sent['hostId'] == 'remote-test' and sent['targetClientId'] == 'owner'
            reply_mode[0] = 'success'
            assert http('POST', '/answer', request, auth)[0] == 200
            replies.get(timeout=2)
            assert http('POST', '/answer', dict(request, answer='x' * 4001), auth)[0] == 409
            assert http('POST', '/answer', request, dict(auth, Origin='https://example.com'))[0] == 403
            assert http('POST', '/answer', request, dict(auth, **{'Transfer-Encoding':'chunked'}))[0] == 403

            peer.sendall(frame(dict(type='broadcast', method='client-status-changed', params=dict(clientId='owner', status='disconnected'))))
            snapshot = expect(lambda v: not v['tasks'])
            assert not snapshot['idleTaskIds']
            peer.shutdown(socket.SHUT_RDWR); peer.close()
            expect(lambda v: not v['connected'])
            peer = streams.get(timeout=6)
            expect(lambda v: v['connected'])
            state(dict(type='active'), 1)
            expect(lambda v: v['tasks'])
            emit(dict(type='snapshot', revision=2, conversationState={}), version=999)
            expect(lambda v: not v['connected'] and not v['tasks'])
            print('PASS: native fragmented IPC, runtime, approval, revision gap, quota, privacy, authenticated replies, duplicates, uncertain delivery, explicit rejection, remote replies, reconnect and unsupported version')
        finally:
            process.terminate()
            try: process.wait(timeout=5)
            except subprocess.TimeoutExpired: process.kill(); process.wait()
            stop.set(); server.close()
            for peer in sockets:
                try: peer.shutdown(socket.SHUT_RDWR); peer.close()
                except OSError: pass


if __name__ == '__main__':
    main()
