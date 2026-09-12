"""Run with python3 scripts/test_codex_notch_bridge.py; no Codex session needed."""
import importlib.util
from pathlib import Path

spec = importlib.util.spec_from_file_location('bridge', Path(__file__).with_name('codex-notch-bridge.py'))
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)
for level in ['low', 'medium', 'high', 'xhigh', 'max', 'ultra']:
    assert bridge.update_effort(None, {'type': 'snapshot', 'conversationState': {'latestThreadSettings': {'effort': level}}}) == level
assert bridge.update_effort('high', {'type': 'patches', 'patches': [{'op': 'replace', 'path': ['latestThreadSettings', 'effort'], 'value': 'ultra'}]}) == 'ultra'
assert bridge.update_effort('ultra', {'type': 'patches', 'patches': [{'op': 'remove', 'path': ['latestThreadSettings', 'effort']}]}) is None
assert bridge.update_effort(None, {'type': 'snapshot', 'conversationState': {}}) is None
assert bridge.update_effort(None, {'type': 'snapshot', 'conversationState': {'latestThreadSettings': {'effort': 'unrecognized'}}}) is None
runtime = bridge.update_runtime(None, dict(type='snapshot', conversationState={
    'threadRuntimeStatus': {'type': 'active', 'activeFlags': []}, 'title': 'PRIVATE'}))
assert bridge.task_state(runtime) == 'running'
runtime = bridge.update_runtime(runtime, dict(type='patches', patches=[
    dict(op='add', path=['threadRuntimeStatus', 'activeFlags', 0], value='waitingOnApproval'),
    dict(op='replace', path=['title'], value='PRIVATE')]))
assert bridge.task_state(runtime) == 'waiting'
runtime = bridge.update_runtime(runtime, dict(type='patches', patches=[
    dict(op='replace', path=['threadRuntimeStatus', 'activeFlags', 0], value='waitingOnUserInput')]))
assert bridge.task_state(runtime) == 'waiting'
runtime = bridge.update_runtime(runtime, dict(type='patches', patches=[
    dict(op='remove', path=['threadRuntimeStatus', 'activeFlags', 0])]))
assert bridge.task_state(runtime) == 'running'
runtime = bridge.update_runtime(runtime, dict(type='patches', patches=[
    dict(op='replace', path=['threadRuntimeStatus'], value={'type': 'idle'})]))
assert bridge.task_state(runtime) is None
assert bridge.task_state(None) is None
b = bridge.Bridge(Path('/tmp'))
b.runtimes[('local', 'test')] = {'runtime': {'type': 'active', 'activeFlags': []}}
b.connected = True
b.last_contact = __import__('time').time()
snapshot = b.snapshot()
assert snapshot['tasks'][0]['title'] == 'Codex task'
assert 'PRIVATE' not in str(snapshot)
b.runtimes[('local', 'test')]['receivedAt'] = b.last_contact - 46
assert b.snapshot()['connected'] is False
assert b.snapshot()['tasks'] == []
print('PASS: running, approval, user input, resume, completion, unavailable and privacy projection')

# Exercise real framing, partial reads, revision sequencing and disconnect cleanup.
import json
import socket
import sqlite3
import struct
import tempfile
import threading
import time

with tempfile.TemporaryDirectory() as folder:
    home = Path(folder)
    (home / 'ipc').mkdir()
    with sqlite3.connect(home / 'state_5.sqlite') as conn:
        conn.execute('CREATE TABLE threads (id TEXT, archived INTEGER, updated_at INTEGER)')
    server = socket.socket(socket.AF_UNIX)
    server.bind(str(home / 'ipc' / 'ipc.sock'))
    server.listen()
    live = bridge.Bridge(home)
    threading.Thread(target=live.run, daemon=True).start()
    peer, _ = server.accept()
    def emit(message):
        body = json.dumps(message).encode()
        frame = struct.pack('<I', len(body)) + body
        peer.sendall(frame[:2])
        peer.sendall(frame[2:])
    def expect(state, connected=True):
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            result = live.snapshot()
            actual = result['tasks'][0]['state'] if result['tasks'] else None
            if actual == state and result['connected'] == connected:
                return
            time.sleep(.01)
        raise AssertionError(result)
    def stream(change, version=11):
        emit(dict(type='broadcast', method='thread-stream-state-changed', version=version,
                  sourceClientId='owner', params=dict(hostId='local',
                  conversationId='00000000-0000-4000-8000-000000000001', change=change)))
    emit(dict(type='response', requestId='notch-init', resultType='success'))
    stream(dict(type='snapshot', revision=1, conversationState=dict(
        threadRuntimeStatus=dict(type='active', activeFlags=[]))))
    expect('running')
    stream(dict(type='patches', baseRevision=1, revision=2, patches=[
        dict(op='add', path=['threadRuntimeStatus', 'activeFlags', 0], value='waitingOnApproval')]))
    expect('waiting')
    stream(dict(type='patches', baseRevision=2, revision=3, patches=[
        dict(op='remove', path=['threadRuntimeStatus', 'activeFlags', 0])]))
    expect('running')
    # A missed revision must remove stale activity until a fresh snapshot arrives.
    stream(dict(type='patches', baseRevision=9, revision=10, patches=[]))
    expect(None)
    stream(dict(type='snapshot', revision=10, conversationState=dict(
        threadRuntimeStatus=dict(type='active', activeFlags=['waitingOnUserInput']))))
    expect('waiting')
    stream(dict(type='patches', baseRevision=10, revision=11, patches=[
        dict(op='remove', path=['threadRuntimeStatus'])]))
    expect(None)
    stream(dict(type='snapshot', revision=12, conversationState=dict(
        threadRuntimeStatus=dict(type='active', activeFlags=[]))))
    expect('running')
    emit(dict(type='broadcast', method='client-status-changed',
              params=dict(clientId='owner', clientType='desktop', status='disconnected')))
    expect(None)
    stream(dict(type='snapshot', revision=13, conversationState=dict(
        threadRuntimeStatus=dict(type='active', activeFlags=[]))))
    expect('running')
    peer.close()
    expect(None, connected=False)
    server.settimeout(4)
    peer, _ = server.accept()
    emit(dict(type='response', requestId='notch-init', resultType='success'))
    stream(dict(type='snapshot', revision=1, conversationState=dict(
        threadRuntimeStatus=dict(type='active', activeFlags=[]))))
    expect('running')
    stream(dict(type='snapshot', revision=2, conversationState={}), version=999)
    expect(None, connected=False)
    peer.close()
    server.close()
print('PASS: fragmented IPC frames, approval/resume, revision gap, status removal, disconnect/reconnect, unsupported version')

# Allowance is remaining main Codex quota, selected by duration, not field order.
def allowance(plan, primary, secondary=None):
    return {'rateLimitsByLimitId': {'codex': {'planType': plan, 'primary': primary, 'secondary': secondary},
                                    'codex_bengalfox': {'planType': 'pro', 'primary': primary}}}
five = dict(usedPercent=25, windowDurationMins=300, resetsAt=200)
week = dict(usedPercent=87, windowDurationMins=10080, resetsAt=200)
assert bridge.fuel_snapshot(allowance('plus', week, five), 100)['remainingPercent'] == 75
assert bridge.fuel_snapshot(allowance('prolite', week), 100)['remainingPercent'] == 13
assert bridge.fuel_snapshot(allowance('pro', five, week), 100)['windowMinutes'] == 10080
assert bridge.fuel_snapshot(allowance('plus', week), 100) is None
assert bridge.fuel_snapshot(allowance('unknown', week), 100) is None
assert bridge.fuel_snapshot(allowance('pro', week), 201) is None
assert bridge.fuel_snapshot({'rateLimitsByLimitId': {'codex_bengalfox': {'primary': week}}}, 100) is None
for value in [float('nan'), float('inf'), -1, 101, True, '13']:
    assert bridge.fuel_snapshot(allowance('pro', dict(week, usedPercent=value)), 100) is None
print('PASS: fuel plan/window selection, remaining percentage, expiry, malformed data, bucket isolation')
assert bridge.fuel_snapshot(allowance('plus', five, week), 100, weekly=True)['remainingPercent'] == 13
assert bridge.fuel_snapshot(allowance('pro', five, week), 100, weekly=True)['windowMinutes'] == 10080
model = bridge.update_model(None, {'type': 'snapshot', 'conversationState': {'latestThreadSettings': {'model': 'gpt-6-astra', 'modelProvider': 'openai', 'cwd': 'PRIVATE'}}})
assert model == {'model': 'gpt-6-astra', 'modelProvider': 'openai'}
assert bridge.update_model(model, {'type': 'patches', 'patches': [{'op': 'replace', 'path': ['latestThreadSettings', 'model'], 'value': 'gpt-5.5'}]})['model'] == 'gpt-5.5'
assert 'model' not in bridge.update_model(model, {'type': 'patches', 'patches': [{'op': 'remove', 'path': ['latestThreadSettings', 'model']}]})
assert bridge.update_model(model, {'type': 'patches', 'patches': [{'op': 'replace', 'path': ['latestThreadSettings'], 'value': {}}]}) == {}
assert bridge.update_model(None, {'type': 'snapshot', 'conversationState': {'latestThreadSettings': {'model': 'bad\nname'}}}) == {}
print('PASS: Plus weekly allowance and model snapshot/patch/removal/privacy projection')

# Async questions do not set waitingOnUserInput; acknowledgement is a separate message.
question = dict(type='agentMessage', id='q1', delivery='async', text='private question',
                questions=[dict(title='private title', options=['private option'])])
state = bridge.update_questions(None, dict(type='snapshot', conversationState=dict(
    turns=[], turnHistory=dict(history=dict(entitiesByKey={'turn1': dict(items=[question])})))))
assert bridge.has_pending_questions(state)
assert bridge.task_state(dict(type='idle'), True) == 'waiting'
assert bridge.pending_questions(state)[0]['title'] == 'private title'
reply = dict(type='steeringUserMessage', status='pending', input=[dict(type='text', text=
    '<send_user_message_question_reply>\n' + json.dumps([dict(
        questionItemId='["request_user_input_async","q1",0]', question='private', answer='private')]) +
    '\n</send_user_message_question_reply>')])
path = ['turnHistory', 'history', 'entitiesByKey', 'turn1', 'items']
state = bridge.update_questions(state, dict(type='patches', patches=[dict(op='add', path=path+[1], value=reply)]))
assert bridge.has_pending_questions(state)  # Unaccepted steering is not an answer yet.
state = bridge.update_questions(state, dict(type='patches', patches=[dict(op='replace', path=path+[1,'status'], value='accepted')]))
assert not bridge.has_pending_questions(state)
assert 'private option' in json.dumps(state) and '<send_user_message_question_reply>' not in json.dumps(state)
state = bridge.update_questions(state, dict(type='patches', patches=[dict(op='remove', path=path+[1])]))
assert bridge.has_pending_questions(state)
state = bridge.update_questions(state, dict(type='patches', patches=[dict(op='remove', path=path+[0])]))
assert not bridge.has_pending_questions(state)
print('PASS: async question, idle pending state, accepted reply, removal and private-text exclusion')
question['questions'].append(dict(title='second private question'))
state = bridge.project_questions(dict(turns=[dict(items=[question])]))
assert len(bridge.pending_question_ids(state)) == 2
reply['status'] = 'accepted'
state = bridge.update_questions(state, dict(type='patches', patches=[dict(
    op='add', path=['turns', 0, 'items', 1], value=reply)]))
assert len(bridge.pending_question_ids(state)) == 1
print('PASS: answering one of two questions decrements reminder count by one')


# Direct replies bind to an existing pending question; raw reply content never enters snapshots.
bridge_state = bridge.Bridge(Path('/tmp'))
bridge_state.connected = True
bridge_state.last_contact = time.time()
thread = '11111111-1111-1111-1111-111111111111'
bridge_state.runtimes[('local', thread)] = dict(runtime=dict(type='active'), owner='owner',
    receivedAt=time.time(), questions=bridge.project_questions(dict(turns=[dict(items=[question])])) )
question_id = bridge.pending_question_ids(bridge_state.runtimes[('local', thread)]['questions'])[0]
recorded = []
original_rpc = bridge.ipc_request
bridge.ipc_request = lambda *args: recorded.append(args) or dict(resultType='success')
try:
    result = bridge_state.answer(dict(hostId='local', taskId=thread, questionId=question_id, answer='test reply'))
    assert result['accepted'] and recorded[0][1] == 'thread-follower-steer-turn'
    assert 'test reply' in recorded[0][3]['input'][0]['text']
    assert recorded[0][3]['restoreMessage']['context'] == {}
    assert 'additionalContext' not in recorded[0][3]
    assert 'test reply' not in json.dumps(bridge_state.snapshot())
    try:
        bridge_state.answer(dict(hostId='local', taskId=thread, questionId=question_id, answer='duplicate'))
        raise AssertionError('duplicate accepted')
    except ValueError: pass
    try:
        bridge_state.answer(dict(hostId='local', taskId=thread, questionId='stale', answer='bad'))
        raise AssertionError('stale question accepted')
    except ValueError: pass
    bridge_state.submissions.clear()
    bridge_state.runtimes[('local', thread)]['runtime'] = dict(type='idle')
    bridge_state.answer(dict(hostId='local', taskId=thread, questionId=question_id, answer='idle test'))
    assert recorded[-1][1] == 'thread-follower-start-turn'
    assert recorded[-1][3]['turnStart']['context']['inheritThreadSettings']
finally:
    bridge.ipc_request = original_rpc
print('PASS: bound direct reply, duplicate prevention, stale rejection and answer privacy')

assert bridge.pending_questions(bridge.project_questions(dict(turns=[dict(items=[dict(type='agentMessage', id='null-options', delivery='async', questions=[dict(title='Input', options=None)])])])))[0]['options'] == []

# Async reminders coexist with execution; blocking approvals do not.
activity = bridge.Bridge(Path('/tmp'))
activity.connected = True
activity.last_contact = time.time()
entry = dict(runtime=dict(type='active', activeFlags=[]), pendingQuestions=True, receivedAt=time.time())
activity.runtimes[('local', thread)] = entry
assert activity.snapshot()['tasks'][0]['state'] == 'waiting'
assert activity.snapshot()['tasks'][0]['isRunning'] is True
entry['runtime']['activeFlags'] = ['waitingOnApproval']
assert activity.snapshot()['tasks'][0]['isRunning'] is False
entry['runtime'] = dict(type='idle')
assert activity.snapshot()['tasks'][0]['isRunning'] is False
print('PASS: async reminders preserve running state; blocking and idle states stop rocket')
