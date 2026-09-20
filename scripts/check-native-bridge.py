#!/usr/bin/env python3
"""Compare native projections with the retained Python implementation, then test IPC/HTTP."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('legacy', ROOT / 'scripts/codex-notch-bridge.py')
legacy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(legacy)


def main():
    assert (ROOT / 'CodexBridge/Projection.swift').exists(), 'Native bridge implementation is missing'
    fixtures = []

    def compare(function, *args):
        fixtures.append((dict(function=function, args=copy.deepcopy(args)), copy.deepcopy(getattr(legacy, function)(*copy.deepcopy(args)))))

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
        runner = path / 'Check.swift'
        runner.write_text('''import Foundation
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
            case "update_runtime": result = try Projection.updateRuntime(args[0], change: args[1] as! [String: Any])
            case "update_effort": result = Projection.effort(args[0], change: args[1] as! [String: Any])
            case "update_model": result = Projection.model(args[0], change: args[1] as! [String: Any])
            case "fuel_snapshot": result = Projection.fuel(args[0] as! [String: Any], now: args[1] as! Double, weekly: args[2] as! Bool) as Any? ?? NSNull()
            default: fatalError("Unknown fixture")
            }
            let data = try JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes])
            print(String(decoding: data, as: UTF8.self))
        }
    }
}
''')
        env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
        subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', str(ROOT / 'CodexBridge/Projection.swift'),
                        str(runner), '-o', str(path / 'check')], env=env, check=True)
        result = subprocess.run([str(path / 'check')], input=''.join(json.dumps(f[0], ensure_ascii=False)+'\n' for f in fixtures),
                                text=True, capture_output=True)
        assert result.returncode == 0, (len(result.stdout.splitlines()), result.stderr)
        actual = [json.loads(line) for line in result.stdout.splitlines()]
        assert len(actual) == len(fixtures)
        for (request, expected), value in zip(fixtures, actual):
            assert value == expected, (request, expected, value)
        print(f'PASS: {len(fixtures)} native/Python projection parity cases')


if __name__ == '__main__':
    main()
