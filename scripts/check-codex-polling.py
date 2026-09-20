#!/usr/bin/env python3
"""Run production polling/lifecycle code with controlled responses, never real tasks."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
activity = (root / 'boringNotch/managers/CodexActivity.swift').read_text()
activity = activity.split('    func open(_ task:', 1)[0] + '    func dismissResolvedRequests() {}\n}\n'
activity = activity.replace('private ', '').replace('UserDefaults.standard', 'testDefaults')
activity = activity.replace('URLSession(configuration:', 'ControlledSession(configuration:')
effects = (root / 'boringNotch/components/Notch/CodexNotchEffect.swift').read_text()
thrust = effects.split('\n}', 1)[0] + '\n}\n'
check = r'''
let suite = "notch-poll-check-" + UUID().uuidString
let testDefaults = UserDefaults(suiteName: suite)!
@MainActor final class NotchMotionEnvironment: ObservableObject {
    static let shared = NotchMotionEnvironment()
    @Published var suspended = false
    static func decorativeFrameInterval(lowPower: Bool) -> Double { lowPower ? 1.0 / 15 : 1.0 / 24 }
}
@MainActor final class ControlledSession {
    static var requests: [CheckedContinuation<(Data, URLResponse), Error>] = []
    static var invalidations = 0
    init(configuration: URLSessionConfiguration) {}
    func invalidateAndCancel() { Self.invalidations += 1 }
    func data(from url: URL) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { Self.requests.append($0) }
    }
    static func reply(_ index: Int, running: Bool) {
        let body: [String: Any] = ["connected": true, "updatedAt": Date.now.timeIntervalSince1970,
            "replyToken": "fixture", "tasks": running ? [["id":"11111111-1111-4111-8111-111111111111",
                "title":"Fixture", "state":"running", "isRunning":true]] : [],
            "idleTaskIds": running ? [] : ["local/11111111-1111-4111-8111-111111111111"]]
        let response = HTTPURLResponse(url: URL(string: "http://127.0.0.1:19427/state")!,
                                       statusCode: 200, httpVersion: nil, headerFields: nil)!
        requests[index].resume(returning: (try! JSONSerialization.data(withJSONObject: body), response))
    }
}
@main struct Check {
    @MainActor static func settle(_ predicate: () -> Bool) async {
        for _ in 0..<1000 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        fatalError("Polling state did not settle")
    }
    @MainActor static func main() async {
        defer { testDefaults.removePersistentDomain(forName: suite) }
        testDefaults.set(false, forKey: "codexRocketEnabled")
        let activity = CodexActivity()
        assert(activity.pollTask == nil && ControlledSession.requests.isEmpty)
        activity.enabled = true
        await settle { ControlledSession.requests.count == 1 }
        activity.enabled = false
        assert(activity.pollTask == nil && !activity.connected && activity.tasks.isEmpty)
        activity.enabled = true
        await settle { ControlledSession.requests.count == 2 }
        ControlledSession.reply(1, running: true)
        await settle { activity.connected }
        ControlledSession.reply(0, running: false) // Old request ignores cancellation on purpose.
        await settle { ControlledSession.invalidations == 1 }
        assert(activity.running && activity.completionSequence == 0, "Late response changed the new session")
        activity.enabled = true // Setting the same value must not start another loop.
        try? await Task.sleep(for: .milliseconds(1150))
        assert(ControlledSession.requests.count == 3, "Repeated enable accumulated polling loops")
        NotchMotionEnvironment.shared.suspended = true
        assert(activity.pollTask == nil && !activity.connected && activity.tasks.isEmpty)
        ControlledSession.requests[2].resume(throwing: URLError(.cancelled))
        await settle { ControlledSession.invalidations == 2 }
        try? await Task.sleep(for: .milliseconds(1150))
        assert(ControlledSession.requests.count == 3, "Sleeping app kept polling")
        NotchMotionEnvironment.shared.suspended = false
        await settle { ControlledSession.requests.count == 4 }
        ControlledSession.reply(3, running: false)
        await settle { activity.connected }
        assert(activity.completionSequence == 0, "Wake was misreported as task completion")
        activity.enabled = false
        await settle { ControlledSession.invalidations == 3 }
        try? await Task.sleep(for: .milliseconds(1150))
        assert(ControlledSession.requests.count == 4 && activity.pollTask == nil, "Disabled feature kept polling")
        print("PASS: disabled startup, enable/disable, late response rejection, single loop, sleep/wake, no false completion, session cleanup")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='notch-poll-check-') as directory:
    path = Path(directory)
    (path / 'Check.swift').write_text(activity + thrust + check)
    env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', str(path / 'Check.swift'), '-o', str(path / 'check')], env=env, check=True)
    subprocess.run([str(path / 'check')], check=True)
