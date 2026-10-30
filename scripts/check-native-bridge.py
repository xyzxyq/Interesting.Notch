#!/usr/bin/env python3
"""Compare native projections with the retained Python implementation, then test IPC/HTTP."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sqlite3
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('legacy', ROOT / 'scripts/codex-notch-bridge.py')
legacy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(legacy)


def main():
    assert (ROOT / 'CodexBridge/Projection.swift').exists(), 'Native bridge implementation is missing'
    fixtures = []

    def compare(function, *args):
        expected = copy.deepcopy(getattr(legacy, function)(*copy.deepcopy(args)))
        fixtures.append((dict(function=function, args=copy.deepcopy(args)), expected))
        if function == 'update_questions':
            fixtures.append((dict(function='pending_update', args=copy.deepcopy(args)),
                             dict(state=expected, pending=legacy.pending_questions(expected))))

    for runtime in [None, {}, dict(type='idle'), dict(type='active'),
                    dict(type='active', activeFlags=['waitingOnApproval']),
                    dict(type='active', activeFlags=['waitingOnUserInput'])]:
        for pending in [False, True]:
            compare('task_state', runtime, pending)
    for effort in ['low', 'medium', 'high', 'xhigh', 'max', 'ultra', 'bad', None]:
        change = dict(type='snapshot', conversationState=dict(latestThreadSettings=dict(effort=effort)))
        compare('update_effort', None, change)
        compare('update_effort', 'high', dict(type='patches', patches=[dict(op='remove', path=['latestThreadSettings', 'effort'])]))
    for name in ['gpt-6-astra', 'gpt-5.5', 'a/b:c', 'bad\nname', '', None, '中', 'x'*121]:
        compare('update_model', None, dict(type='snapshot', conversationState=dict(latestThreadSettings=dict(model=name, modelProvider='openai', cwd='PRIVATE'))))
    fast = dict(model='gpt-6-astra', modelProvider='openai', serviceTier='priority')
    for tier in ['priority', 'default', 'fast', 'flex', 'unknown', None, 1, {}, []]:
        compare('update_model', fast, dict(type='snapshot', conversationState=dict(
            latestThreadSettings=dict(model='gpt-6-astra', serviceTier=tier, cwd='PRIVATE'))))
        compare('update_model', fast, dict(type='patches', patches=[dict(op='replace', path=['latestThreadSettings', 'serviceTier'], value=tier)]))
    for change in [dict(type='snapshot', conversationState=dict(latestThreadSettings=dict(model='gpt-6-luna'))),
                   dict(type='patches', patches=[dict(op='remove', path=['latestThreadSettings', 'serviceTier'])]),
                   dict(type='patches', patches=[dict(op='remove', path=['latestThreadSettings'])]),
                   dict(type='patches', patches=[dict(op='replace', path=[], value={})]),
                   dict(type='patches', patches=[dict(op='replace', path=['latestThreadSettings', 'model'], value='gpt-6-luna')])]:
        compare('update_model', fast, change)
    runtime = dict(type='active', activeFlags=[])
    compare('update_runtime', dict(type='active'), dict(type='patches', patches=[
        dict(op='add', path=['threadRuntimeStatus', 'activeFlags', 0], value='waitingOnUserInput')]))
    for patch in [dict(op='add', path=['threadRuntimeStatus', 'activeFlags', 0], value='waitingOnApproval'),
                  dict(op='remove', path=['threadRuntimeStatus', 'activeFlags', 0]),
                  dict(op='replace', path=['threadRuntimeStatus'], value=dict(type='idle')),
                  dict(op='remove', path=['threadRuntimeStatus'])]:
        change = dict(type='patches', patches=[patch])
        compare('update_runtime', json.loads(json.dumps(runtime)), change)
        runtime = legacy.update_runtime(runtime, change)
    question = dict(type='agentMessage', id='q1', delivery='async', text='private prose',
                    questions=[dict(title='选择环境', options=['A', 'B']), dict(title='Name', options=None)])
    original = dict(turns=[dict(items=[question])], secret='PRIVATE')
    compare('project_questions', original)
    state = legacy.project_questions(original)
    compare('pending_questions', state)
    reply = dict(type='steeringUserMessage', status='pending', input=[dict(type='text', text=
        '<send_user_message_question_reply>\n' + json.dumps([dict(questionItemId='["request_user_input_async","q1",0]', answer='PRIVATE')]) + '\n</send_user_message_question_reply>')])
    patches = [dict(op='add', path=['turns', 0, 'items', 1], value=reply),
               dict(op='replace', path=['turns', 0, 'items', 1, 'status'], value='accepted'),
               dict(op='replace', path=['turns', 0, 'items', 0, 'questions', 0, 'title'], value='Changed'),
               dict(op='remove', path=['turns', 0, 'items', 1]),
               dict(op='remove', path=['turns', 0, 'items', 0])]
    for patch in patches:
        change = dict(type='patches', patches=[patch])
        compare('update_questions', state, change)
        state = legacy.update_questions(state, change)
        compare('pending_questions', state)
    # The gate shares the projection's accepted paths: skipped deltas preserve pending
    # answers; accepted deltas, root/ancestor edits and removals refresh immediately.
    state = legacy.project_questions(dict(turns=[dict(items=[question])],
                                         requests=[dict(id=1, method='item/commandExecution/requestApproval')]))
    gate_cases = [
        (dict(type='patches', patches=[]), False),
        (dict(type='snapshot', conversationState=original), True),
        (dict(type='patches', patches=[dict(op='replace', path=[], value=original)]), True),
    ]
    for patch, refresh in [
        (dict(op='replace', path=['threadRuntimeStatus', 'activeFlags'], value=['waitingOnApproval']), False),
        (dict(op='remove', path=['threadRuntimeStatus']), False),
        (dict(op='replace', path=['latestThreadSettings', 'model'], value='gpt-6-astra'), False),
        (dict(op='replace', path=['requests', 0, 'params', 'secret'], value='PRIVATE'), False),
        (dict(op='replace', path=['requests', 0, 'params'], value={}), False),
        (dict(op='replace', path=['turns', 0, 'items', 0, 'streamingState'], value='delta'), False),
        (dict(op='replace', path=['turnHistory', 'irrelevant'], value='delta'), False),
        (dict(op='replace', path=['turns', 0], value=dict(items=[question])), True),
        (dict(op='remove', path=['turns', 0]), True),
        (dict(op='add', path=['turns', 0, 'items', 1], value=reply), True),
        (dict(op='replace', path=['turns', 0, 'items', 0, 'questions', 0, 'options', 1], value='C'), True),
        (dict(op='remove', path=['turns', 0, 'items', 0, 'questions', 0, 'options', 0]), True),
        (dict(op='replace', path=['turns', 0, 'items', 0, 'text'], value='Ordinary prose'), True),
        (dict(op='replace', path=['turns', 99, 'items', 0, 'status'], value='accepted'), True),
        (dict(op='remove', path=['turns', 0, 'absentPrivateField']), True),
        (dict(op='replace', path=['requests', 0, 'completed'], value=True), True),
        (dict(op='remove', path=['requests', 0]), True),
    ]:
        gate_cases.append((dict(type='patches', patches=[patch]), refresh))
    gate_cases.append((dict(type='patches', patches=[
        dict(op='replace', path=['latestThreadSettings', 'model'], value='gpt-6-astra'),
        dict(op='replace', path=['turns', 0, 'items', 0, 'questions', 0, 'title'], value='Immediate change'),
        dict(op='replace', path=['requests', 0, 'params'], value={})]), True))
    for change, refresh in gate_cases:
        compare('update_questions', state, change)
        fixtures.append((dict(function='question_refresh', args=[state, change]), refresh))
    # The established native root-removal shape is null; legacy normalizes it to {}.
    # Both have no pending questions. Preserve the native contract rather than changing
    # it in a work-elision patch merely to make a new structural parity case agree.
    root_removal = dict(type='patches', patches=[dict(op='remove', path=[])])
    fixtures.append((dict(function='pending_update', args=[state, root_removal]), dict(state=None, pending=[])))
    fixtures.append((dict(function='question_refresh', args=[state, root_removal]), True))
    for patch in [dict(op='add', path=['turns', 5], value={}),
                  dict(op='remove', path=['turns', -1]),
                  dict(op='replace', path=['turns', 0.5], value={}),
                  dict(op='replace', path=['turns', 0, 'items', 0, 'questions', 0], value={})]:
        fixtures.append((dict(function='question_error', args=[state, dict(type='patches', patches=[patch])]), True))
    for delivery in [None, 'async', 'normal']:
        message = dict(type='agentMessage', id='modern', questions=[dict(title='Choose', options=['A', 'B'])])
        if delivery: message['delivery'] = delivery
        raw = dict(turns=[dict(items=[message])])
        compare('project_questions', raw)
        compare('pending_questions', legacy.project_questions(raw))
    raw = dict(requests=[dict(id=1, method='item/commandExecution/requestApproval', params=dict(secret='PRIVATE'))])
    compare('project_questions', raw)
    state = legacy.project_questions(raw)
    compare('pending_questions', state)
    for patch in [dict(op='add', path=['requests', 1], value=dict(id='next', method='item/tool/requestUserInput', params=dict(secret='PRIVATE'))),
                  dict(op='replace', path=['requests', 1, 'method'], value='item/tool/requestOptionPicker'),
                  dict(op='add', path=['requests', 0, 'completed'], value=True),
                  dict(op='remove', path=['requests', 0]),
                  dict(op='replace', path=['requests', 0, 'params', 'secret'], value='PRIVATE'),
                  dict(op='replace', path=['requests'], value=[]),
                  dict(op='add', path=['requests', 0], value=dict(id='计划', method='item/plan/requestImplementation'))]:
        change = dict(type='patches', patches=[patch])
        compare('update_questions', state, change)
        state = legacy.update_questions(state, change)
        compare('pending_questions', state)
    for plan in ['plus', 'pro', 'prolite', 'team', 'business', 'enterprise', 'edu', 'unknown']:
        for used in [0, 25, 100, -1, 101, True, '13', None]:
            quota = dict(planType=plan, primary=dict(usedPercent=used, windowDurationMins=10080, resetsAt=200),
                         secondary=dict(usedPercent=25, windowDurationMins=300, resetsAt=200))
            result = dict(rateLimitsByLimitId=dict(codex=quota))
            for weekly in [False, True]:
                compare('fuel_snapshot', result, 100, weekly)
    compare('fuel_snapshot', dict(rateLimitsByLimitId={'other': {}}), 100, False)
    compare('fuel_snapshot', dict(rateLimits=dict(planType='pro', primary=dict(usedPercent=-1, windowDurationMins=10080, resetsAt=200),
                                                 secondary=dict(usedPercent=0, windowDurationMins=10080, resetsAt=200))), 100, False)
    with tempfile.TemporaryDirectory(prefix='native-bridge-check-') as directory:
        path = Path(directory)
        # LaunchAgents have a minimal PATH. Exercise real executable discovery
        # without touching /Applications or using the machine's installed Codex.
        modern = 'codex-cli/CodexCLI.app/Contents/MacOS/codex'
        layouts = [(app, suffix, old) for app in ('ChatGPT', 'Codex')
                   for suffix, old in ((modern, False), (modern, True), ('codex', False))]
        for index, (app, suffix, include_old) in enumerate(layouts):
            applications = path / str(index)
            binary = applications / f'{app}.app/Contents/Resources/{suffix}'
            binary.parent.mkdir(parents=True)
            binary.write_text('#!/bin/sh\nexit 0\n'); binary.chmod(0o700)
            cases = [({}, str(binary)), ({'CODEX_BRIDGE_CODEX_PATH': '/nonexistent'}, None)]
            if include_old:
                old = applications / f'{app}.app/Contents/Resources/codex'
                old.write_text('#!/bin/sh\nexit 0\n'); old.chmod(0o700)
            for environment, expected in cases:
                args = [environment, str(applications)]
                fixtures.append((dict(function='codex_binary', args=args), expected))
        fallback = path / 'bin/codex'
        fallback.parent.mkdir(); fallback.write_text('#!/bin/sh\nexit 0\n'); fallback.chmod(0o700)
        for environment, expected in [({'PATH': str(fallback.parent)}, str(fallback)),
                                      ({'CODEX_BRIDGE_CODEX_PATH': str(fallback)}, str(fallback)),
                                      ({}, None), ({'CODEX_BRIDGE_CODEX_PATH': str(path)}, None)]:
            fixtures.append((dict(function='codex_binary', args=[environment, str(path / 'absent')]), expected))
        for request, expected in fixtures:
            if request['function'] == 'codex_binary':
                assert legacy.codex_binary(*request['args']) == expected, ('Python resolver', request, expected)
        # Test the real locked snapshot at a deterministic clock, independently of legacy behavior.
        for args, expected in [
            ([100, 100, 100, 54], {"connected": True, "tasks": ["local/live"], "fuel": 75}),
            ([100, 100, 54, 100], {"connected": True, "tasks": ["remote/stale"], "fuel": 75}),
            ([146, 146, 100, 146], {"connected": True, "tasks": ["remote/stale"], "fuel": 75}),
            ([251, 251, 251, 251], {"connected": True, "tasks": ["local/live", "remote/stale"], "fuel": None}),
        ]:
            fixtures.append((dict(function='bridge_snapshot', args=args), expected))
        fixtures.append((dict(function='fuel_refresh', args=[]), 75))
        remote_id = '22222222-2222-4222-8222-222222222222'
        second_id = '33333333-3333-4333-8333-333333333333'
        for index, state in enumerate([
            {'thread-project-membership-host-ids': {remote_id: 'remote-test', 'invalid': 'remote-test'},
             'thread-project-assignments': {second_id: {'hostId': 'remote-other'}}, 'private': 'PRIVATE'},
            {'thread-project-membership-host-ids': [], 'thread-project-assignments': None},
            None, 'malformed-json',
        ]):
            home = path / f'discovery-{index}'
            home.mkdir()
            with sqlite3.connect(home / 'state_5.sqlite') as db:
                db.execute('CREATE TABLE threads (id TEXT, archived INTEGER, updated_at INTEGER)')
            (home / '.codex-global-state.json').write_text('{' if state == 'malformed-json' else json.dumps(state))
            expected = [host + '/' + task for host, task in legacy.Bridge(home).keys()]
            if index == 0:
                assert set(expected) == {'remote-test/' + remote_id, 'remote-other/' + second_id}
            fixtures.append((dict(function='recent_tasks', args=[str(home)]), expected))
        bridge_source = (ROOT / 'CodexBridge/Bridge.swift').read_text().replace('private ', '')
        (path / 'Bridge.swift').write_text(bridge_source)
        refresh = bridge_source.split('                    let result = readFuel(home: home)', 1)[1].split('                }', 1)[0]
        runner = path / 'Check.swift'
        runner.write_text('''import Foundation
import Darwin
@main struct Check {
    static func main() throws {
        while let line = readLine() {
            let request = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
            let args = request["args"] as! [Any]
            let result: Any
            switch request["function"] as! String {
            case "task_state": result = Projection.taskState(args[0], pending: args[1] as! Bool) as Any? ?? NSNull()
            case "project_questions": result = Projection.questions(args[0])
            case "pending_questions": result = Projection.pending(args[0])
            case "update_questions": result = try Projection.updateQuestions(args[0], change: args[1] as! [String: Any])
            case "pending_update":
                var refresh = true
                let pending = Projection.pending(args[0])
                let updated = try Projection.updateQuestions(args[0], change: args[1] as! Object, refreshPending: &refresh)
                result = ["state": updated, "pending": refresh ? Projection.pending(updated) : pending]
            case "question_refresh":
                var refresh = true
                _ = try Projection.updateQuestions(args[0], change: args[1] as! Object, refreshPending: &refresh)
                result = refresh
            case "question_error":
                var refresh = false
                do {
                    _ = try Projection.updateQuestions(args[0], change: args[1] as! Object, refreshPending: &refresh)
                    result = false
                } catch { result = true }
            case "pending_benchmark":
                let history = args[0] as! Int, iterations = args[1] as! Int
                let initial = Projection.questions(["turns": (0..<history).map { index -> Object in
                    let question: Object = ["type": "agentMessage", "id": "history-\\(index)", "delivery": "async",
                                            "questions": [["title": "Choice \\(index)", "options": ["A", "B"]]]]
                    return ["items": [question]]
                }])
                let changes: [Object] = [
                    ["type": "patches", "patches": [["op": "replace", "path": ["threadRuntimeStatus", "activeFlags"], "value": [String]()]]],
                    ["type": "patches", "patches": [["op": "replace", "path": ["latestThreadSettings", "model"], "value": "gpt-6-astra"]]],
                    ["type": "patches", "patches": [["op": "replace", "path": ["turns", 0, "items", 0, "streamingState"], "value": "delta"]]]
                ]
                func cpu() -> Double {
                    var usage = rusage()
                    getrusage(RUSAGE_SELF, &usage)
                    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                        + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
                }
                var rows: [Object] = []
                for round in 0..<3 {
                    for gated in (round % 2 == 0 ? [false, true] : [true, false]) {
                        var state = initial, pending = Projection.pending(initial), scans = 0, checksum = 0
                        let startCPU = cpu(), startWall = ProcessInfo.processInfo.systemUptime
                        for index in 0..<iterations {
                            try autoreleasepool {
                                var refresh = false
                                state = try Projection.updateQuestions(state, change: changes[index % changes.count], refreshPending: &refresh)
                                if !gated || refresh { pending = Projection.pending(state); scans += 1 }
                                checksum += pending.count
                            }
                        }
                        rows.append(["gated": gated, "round": round, "history": history, "iterations": iterations,
                                     "cpu_ms": (cpu() - startCPU) * 1000,
                                     "elapsed_ms": (ProcessInfo.processInfo.systemUptime - startWall) * 1000,
                                     "pending_scans": scans, "checksum": checksum])
                    }
                }
                result = rows
            case "update_runtime": result = try Projection.updateRuntime(args[0], change: args[1] as! [String: Any])
            case "update_effort": result = Projection.effort(args[0], change: args[1] as! [String: Any])
            case "update_model": result = Projection.model(args[0], change: args[1] as! [String: Any])
            case "fuel_snapshot": result = Projection.fuel(args[0] as! [String: Any], now: args[1] as! Double, weekly: args[2] as! Bool) as Any? ?? NSNull()
            case "fuel_refresh":
                let lock = NSLock()
                var fuel: Object? = ["remainingPercent": 75, "windowMinutes": 10080, "updatedAt": 100, "resetsAt": 1000]
                var allowances: [Object] = [fuel!]
                let refreshResult: (Object?, [Object]) = (nil, [])
REFRESH_BODY
                assert(allowances.count == 1, "Failed quota refresh discarded valid windows")
                result = fuel?["remainingPercent"] ?? null
            case "bridge_snapshot":
                let bridge = try Bridge(home: URL(fileURLWithPath: "/tmp"))
                bridge.connected = true; bridge.lastContact = args[1] as! Double
                bridge.entries[TaskKey(host: "local", id: "live")] = Entry(runtime: ["type": "active"], receivedAt: args[2] as! Double)
                bridge.entries[TaskKey(host: "remote", id: "stale")] = Entry(runtime: ["type": "active"], receivedAt: args[3] as! Double)
                bridge.fuel = ["remainingPercent": 75, "windowMinutes": 10080, "updatedAt": 100, "resetsAt": 1000]
                let snapshot = bridge.snapshot(now: args[0] as! Double)
                result = ["connected": snapshot["connected"]!, "tasks": (snapshot["tasks"] as! [Object]).map { text($0["hostId"]) + "/" + text($0["id"]) },
                          "fuel": object(snapshot["fuel"])["remainingPercent"] ?? null]
            case "codex_binary": result = codexBinary(environment: args[0] as! [String: String], applications: args[1] as! String) as Any? ?? NSNull()
            case "recent_tasks": result = try recentTasks(home: URL(fileURLWithPath: args[0] as! String)).map(\.identity)
            default: fatalError("Unknown fixture")
            }
            let data = try JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes])
            print(String(decoding: data, as: UTF8.self))
        }
    }
}
'''.replace('REFRESH_BODY', refresh.replace('result.', 'refreshResult.')))
        env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
        optimization = ['-O', '-assert-config', 'Debug'] if '--benchmark' in sys.argv else []
        subprocess.run(['xcrun', 'swiftc'] + optimization + ['-swift-version', '5', str(ROOT / 'CodexBridge/Projection.swift'),
                        str(ROOT / 'CodexBridge/Transport.swift'), str(path / 'Bridge.swift'),
                        str(runner), '-o', str(path / 'check')], env=env, check=True)
        result = subprocess.run([str(path / 'check')], input=''.join(json.dumps(f[0], ensure_ascii=False)+'\n' for f in fixtures),
                                text=True, capture_output=True)
        assert result.returncode == 0, (len(result.stdout.splitlines()), result.stderr)
        actual = [json.loads(line) for line in result.stdout.splitlines()]
        assert len(actual) == len(fixtures)
        for (request, expected), value in zip(fixtures, actual):
            assert value == expected, (request, expected, value)
        print(f'PASS: {len(fixtures)} native/Python projection and executable discovery cases')
        if '--benchmark' in sys.argv:
            result = subprocess.run([str(path / 'check')],
                                    input=json.dumps(dict(function='pending_benchmark', args=[100, 500]))+'\n',
                                    text=True, capture_output=True, check=True)
            rows = json.loads(result.stdout)
            assert all(row['checksum'] == 50_000 for row in rows)
            assert all(row['pending_scans'] == (0 if row['gated'] else 500) for row in rows)
            print('BENCHMARK ' + json.dumps(rows, sort_keys=True))


if __name__ == '__main__':
    main()
