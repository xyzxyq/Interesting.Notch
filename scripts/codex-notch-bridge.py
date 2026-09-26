#!/usr/bin/env python3
"""Local bridge for Codex Desktop's private, versioned IPC.

Expose runtime/allowance summaries and pending async question titles/options on
loopback. Token-protected replies bind to an existing question and are sent to
its owning Codex task. Answer prose is not retained in state snapshots.
Codex upgrades can break this API; unknown stream versions fail closed.
Install with codex-notch-bridge-install.py.
"""
import argparse
import secrets
import copy
import math
import select
import subprocess
import json
import os
from pathlib import Path
import socket
import sqlite3
import struct
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = 19427
STREAM_VERSION = 11
MAX_FRAME = 256 * 1024 * 1024


def question_reply_ids(text):
    start, end = '<send_user_message_question_reply>', '</send_user_message_question_reply>'
    if not isinstance(text, str) or not text.strip().startswith(start) or not text.strip().endswith(end):
        return []
    try:
        replies = json.loads(text.strip()[len(start):-len(end)])
        replies = replies if isinstance(replies, list) else [replies]
        return [r['questionItemId'] for r in replies
                if isinstance(r, dict) and isinstance(r.get('questionItemId'), str)]
    except (ValueError, TypeError):
        return []


def project_questions(value, key=''):
    """Retain only question identity and reply acknowledgement, never prose."""
    if key == 'text':
        return question_reply_ids(value)
    if key == 'questions':
        return [dict(title=q.get('title', '')[:4000], options=[o[:1000] for o in (q.get('options') or []) if isinstance(o, str)][:20])
                for q in value if isinstance(q, dict) and isinstance(q.get('title'), str)] if isinstance(value, list) else []
    if isinstance(value, list):
        return [project_questions(item) for item in value]
    if isinstance(value, dict):
        keys = {'turns', 'turnHistory', 'history', 'entitiesByKey', 'items',
                'type', 'id', 'delivery', 'questions', 'content', 'input', 'text', 'status'}
        result = {k: project_questions(v, k) for k, v in value.items()
                  if key == 'entitiesByKey' or k in keys}
        if value.get('type') == 'agentMessage' and value.get('delivery') == 'async':
            result['prompt'] = str(value.get('text', ''))[:4000]
        return result
    return value if key in ('type', 'id', 'delivery', 'status') else None


def update_questions(previous, change):
    if change.get('type') == 'snapshot':
        return project_questions(change.get('conversationState', {}))
    state = copy.deepcopy(previous or {})
    for patch in change.get('patches', []):
        path = patch.get('path', [])
        if not path:
            state = project_questions(patch.get('value', {}))
            continue
        if path[0] not in ('turns', 'turnHistory'):
            continue
        target = state
        for part in path[:-1]:
            if isinstance(target, list):
                target = target[int(part)] if int(part) < len(target) else None
            elif isinstance(target, dict):
                target = target.get(part)
            else:
                target = None
            if target is None:
                break
        if target is None:
            continue  # A field discarded by the privacy projection.
        key = path[-1]
        value = project_questions(patch.get('value'), key)
        if 'questions' in path:
            raw = patch.get('value')
            if isinstance(raw, str):
                value = raw[:4000]
            elif isinstance(raw, dict):
                value = project_questions([raw], 'questions')[0]
            elif isinstance(raw, list) and key == 'options':
                value = [o[:1000] for o in raw if isinstance(o, str)][:20]
        if isinstance(target, list):
            index = int(key)
            if patch['op'] == 'remove':
                target.pop(index)
            elif patch['op'] == 'add':
                target.insert(index, value)
            else:
                target[index] = value
        elif isinstance(target, dict):
            if patch['op'] == 'remove':
                target.pop(key, None)
            elif ('questions' in path and key in ('title', 'options')) or key in project_questions({key: patch.get('value')}) or (len(path) > 1 and path[-2] == 'entitiesByKey'):
                target[key] = value
    return state


def pending_questions(state):
    questions, answered = {}, set()
    def visit(value):
        if isinstance(value, dict):
            if value.get('type') == 'agentMessage' and value.get('delivery') == 'async':
                count = len(value.get('questions') or [])
                for i, question in enumerate(value.get('questions') or []):
                    identifier = json.dumps(['request_user_input_async', value.get('id'), i], separators=(',', ':'))
                    questions[identifier] = dict(id=identifier, title=question.get('title', ''), options=question.get('options', []))
                if not count and value.get('id'):
                    questions[value['id']] = dict(id=value['id'], title=value.get('prompt', ''), options=[])
            if value.get('type') in ('userMessage', 'steeringUserMessage'):
                if value['type'] != 'steeringUserMessage' or value.get('status') == 'accepted':
                    for item in value.get('content', value.get('input', [])):
                        if item.get('type') == 'text':
                            answered.update(item.get('text') or [])
            for child in value.values():
                if isinstance(child, (dict, list)):
                    visit(child)
        elif isinstance(value, list):
            for child in value:
                visit(child)
    visit(state)
    return [questions[key] for key in sorted(questions.keys() - answered)]


def pending_question_ids(state):
    return [q['id'] for q in pending_questions(state)]


def has_pending_questions(state):
    return bool(pending_question_ids(state))


def task_state(runtime, pending_questions=False):
    if pending_questions:
        return 'waiting'
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


def codex_binary(environment, applications='/Applications'):
    candidates = ([environment['CODEX_BRIDGE_CODEX_PATH']] if 'CODEX_BRIDGE_CODEX_PATH' in environment else
                  [f'{applications}/{app}.app/Contents/Resources/{suffix}' for app in ('ChatGPT', 'Codex')
                   for suffix in ('codex-cli/CodexCLI.app/Contents/MacOS/codex', 'codex')] +
                  [f'{p}/codex' for p in environment.get('PATH', '').split(':') if p])
    return next((p for p in candidates if Path(p).is_file() and os.access(p, os.X_OK)), None)


def read_fuel(home):
    # Use the bundled read-only account RPC, never credentials or a model turn.
    binary = codex_binary(os.environ)
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
        self.reply_token = secrets.token_urlsafe(32)
        self.submissions = set()
        self.connected = False
        self.last_contact = 0
        self.runtimes = {}
        self.fuel = None
        self.allowances = []
        self.lock = threading.Lock()

    def snapshot(self):
        with self.lock:
            tasks = []
            idle_task_ids = []
            now = time.time()
            fresh = self.connected and now - self.last_contact < 45
            # Refresh live snapshots periodically: even a silent long tool run
            # stays fresh, while a hung owner cannot leave a phantom rocket.
            if any(task_state(entry['runtime'], entry.get('pendingQuestions', False)) and now - entry.get('receivedAt', now) >= 45
                   for entry in self.runtimes.values()):
                fresh = False
            for (host, task_id), entry in self.runtimes.items():
                state = task_state(entry['runtime'], entry.get('pendingQuestions', False))
                if (entry.get('runtime') or {}).get('type') == 'idle' and now - entry.get('receivedAt', 0) < 35:
                    idle_task_ids.append(f'{host}/{task_id}')
                if state:
                    tasks.append(dict(id=task_id, hostId=host, title='Codex task', state=state,
                                      isRunning=task_state(entry['runtime']) == 'running', reasoningEffort=entry.get('effort'),
                                      model=entry.get('model', {}).get('model'), modelProvider=entry.get('model', {}).get('modelProvider'),
                                      pendingQuestionIds=pending_question_ids(entry.get('questions', {})),
                                      questions=pending_questions(entry.get('questions', {})),
                                      detail='Needs your attention in Codex' if state == 'waiting' else 'Codex is working'))
            return dict(connected=fresh, tasks=tasks if fresh else [], idleTaskIds=idle_task_ids if fresh else [], updatedAt=self.last_contact, replyToken=self.reply_token,
                        allowances=[w for w in self.allowances if now - w['updatedAt'] < 150 and now < w['resetsAt']],
                        fuel=self.fuel if self.fuel and now - self.fuel['updatedAt'] < 150 and now < self.fuel['resetsAt'] else None)

    def answer(self, data):
        if not isinstance(data, dict):
            raise ValueError('Invalid answer request')
        host, task_id, question_id, answer = (data.get(k) for k in ('hostId', 'taskId', 'questionId', 'answer'))
        if not all(isinstance(v, str) for v in (host, task_id, question_id, answer)) or not 0 < len(answer.strip()) <= 4000:
            raise ValueError('请输入有效回答（最多 4000 字）。')
        uuid.UUID(task_id)
        key = (host, task_id, question_id)
        with self.lock:
            entry = self.runtimes.get((host, task_id))
            if not self.connected or not entry or time.time() - entry['receivedAt'] > 35:
                raise ValueError('Codex 连接已失效，请稍后重试。')
            question = next((q for q in pending_questions(entry['questions']) if q['id'] == question_id), None)
            if not question:
                raise ValueError('该问题已处理或不再有效。')
            if key in self.submissions:
                raise ValueError('回答已发送或正在确认，请勿重复提交。')
            self.submissions.add(key)
            owner, active = entry['owner'], (entry.get('runtime') or {}).get('type') == 'active'
        text = '<send_user_message_question_reply>\n' + json.dumps([dict(
            questionItemId=question_id, question=question['title'], answer=answer.strip())], ensure_ascii=False) + '\n</send_user_message_question_reply>'
        inputs = [dict(type='text', text=text, text_elements=[])]
        if active:
            method, version = 'thread-follower-steer-turn', 1
            params = dict(conversationId=task_id, input=inputs, attachments=[], clientUserMessageId=str(uuid.uuid4()),
                          restoreMessage=dict(id=str(uuid.uuid4()), text=text, context={}, createdAt=int(time.time()*1000)))
        else:
            method, version = 'thread-follower-start-turn', 2
            params = dict(conversationId=task_id, turnStart=dict(request=dict(threadId=task_id, input=inputs),
                          context=dict(inheritThreadSettings=True)))
        try:
            result = ipc_request(self.home, method, version, params, owner, host)
        except (OSError, TimeoutError):
            # Delivery may have happened: don't automatically send a duplicate.
            raise ValueError('提交结果暂未确认，请等待 Codex 同步；为避免重复回答，已暂停再次提交。')
        if result.get('resultType') != 'success':
            if any(word in str(result.get('error', '')).lower() for word in ('timeout', 'disconnected')):
                raise ValueError('提交结果暂未确认，请等待 Codex 同步，勿重复提交。')
            with self.lock:
                self.submissions.discard(key)
            raise ValueError('Codex 未接受回答，请刷新后重试。')
        return dict(accepted=True)

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
                        active_keys = [key for key, entry in self.runtimes.items() if task_state(entry['runtime'], entry.get('pendingQuestions', False))]
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
                                questions = update_questions(entry.get('questions') if entry else None, change)
                                runtime = update_runtime(entry['runtime'] if entry else None, change)
                                effort = update_effort(entry.get('effort') if entry else None, change)
                                model = update_model(entry.get('model') if entry else None, change)
                                self.runtimes[key] = dict(runtime=runtime, questions=questions, pendingQuestions=has_pending_questions(questions), effort=effort, model=model, revision=change['revision'], owner=message.get('sourceClientId'), receivedAt=time.time())
                                self.last_contact = time.time()
                        elif method in ('ipc-connection-reset', 'client-status-changed'):
                            if method == 'ipc-connection-reset' or params.get('status') == 'disconnected':
                                with self.lock:
                                    self.runtimes = {k: v for k, v in self.runtimes.items() if method != 'ipc-connection-reset' and v['owner'] != params.get('clientId')}
                                subscribed.clear()
                                next_discovery = 0


def ipc_request(home, method, version, params, owner, host):
    with socket.socket(socket.AF_UNIX) as sock:
        sock.settimeout(20)
        sock.connect(str(home / 'ipc/ipc.sock'))
        def send(message):
            body = json.dumps(message).encode()
            sock.sendall(struct.pack('<I', len(body)) + body)
        def receive():
            def exact(n):
                data = b''
                while len(data) < n:
                    chunk = sock.recv(n - len(data))
                    if not chunk: raise ConnectionError('IPC closed')
                    data += chunk
                return data
            size = struct.unpack('<I', exact(4))[0]
            if not 0 < size <= MAX_FRAME: raise ValueError('Invalid IPC frame')
            return json.loads(exact(size))
        send(dict(type='request', requestId='reply-init', method='initialize', version=0,
                  params=dict(clientType='interesting-notch-reply')))
        while True:
            message = receive()
            if message.get('requestId') == 'reply-init':
                if message.get('resultType') != 'success': raise ConnectionError('IPC init failed')
                break
        request_id = str(uuid.uuid4())
        send(dict(type='request', requestId=request_id, method=method, version=version + (host != 'local'), params=params,
                  targetClientId=owner, timeoutMs=18000,
                  **(dict(hostId=host) if host != 'local' else {})))
        while True:
            message = receive()
            if message.get('type') == 'response' and message.get('requestId') == request_id:
                return message


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
        def do_POST(self):
            if self.path != '/answer' or self.headers.get('Origin') or self.headers.get('Host') != f'127.0.0.1:{args.port}' or self.headers.get('X-Notch-Token') != bridge.reply_token:
                self.send_error(403)
                return
            try:
                length = int(self.headers.get('Content-Length', '0'))
                if not 0 < length <= 32768: raise ValueError('Invalid request size')
                result = bridge.answer(json.loads(self.rfile.read(length)))
                status = 200
            except (ValueError, TypeError, KeyError) as error:
                result, status = dict(error=str(error)), 409
            body = json.dumps(result).encode()
            self.send_response(status)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        def log_message(self, *_):
            pass
    server = ThreadingHTTPServer(('127.0.0.1', args.port), Handler)
    threading.Thread(target=bridge.run, daemon=True).start()
    threading.Thread(target=bridge.refresh_fuel, daemon=True).start()
    server.serve_forever()


if __name__ == '__main__':
    main()
