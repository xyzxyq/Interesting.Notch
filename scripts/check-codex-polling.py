#!/usr/bin/env python3
"""Run production polling/lifecycle code with controlled responses, never real tasks."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
activity = (root / 'boringNotch/managers/CodexActivity.swift').read_text()
activity = activity.split('    func open(_ task:', 1)[0] + '    func dismissResolvedRequests() {}\n    func closeRequests() {}\n    func hideRequestsImmediately() {}\n}\n'
activity += '\nenum CodexReminderStyle: String { case droplet, pullCord }\nenum CodexPullCordStyle: String { case classic, donut, orbit, crystal, jellyfish, ufo, moon, capsule, fish }\n@MainActor final class CodexGenieTransition {}\n'
activity = activity.replace('private(set) ', '').replace('private ', '').replace('UserDefaults.standard', 'testDefaults')
activity = activity.replace('URLSession(configuration:', 'ControlledSession(configuration:')
effects = (root / 'boringNotch/components/Notch/CodexNotchEffect.swift').read_text()
thrust = effects.split('\n}', 1)[0] + '\n}\n'
check = r'''
let suite = "notch-poll-check-" + UUID().uuidString
let testDefaults = UserDefaults(suiteName: suite)!
@MainActor final class NotchMotionEnvironment: ObservableObject {
    static let shared = NotchMotionEnvironment()
    @Published var suspended = false
    @Published var energySavingActive = false
    static func decorativeFrameInterval(lowPower: Bool) -> Double { lowPower ? 1.0 / 10 : 1.0 / 20 }
}
@MainActor final class ControlledSession {
    static var requests: [CheckedContinuation<(Data, URLResponse), Error>] = []
    static var invalidations = 0
    init(configuration: URLSessionConfiguration) {}
    func invalidateAndCancel() { Self.invalidations += 1 }
    func data(from url: URL) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { Self.requests.append($0) }
    }
    static func reply(_ index: Int, running: Bool, connected: Bool = true, fuel: Bool = false) {
        var body: [String: Any] = ["connected": connected, "updatedAt": Date.now.timeIntervalSince1970,
            "replyToken": "fixture", "tasks": running ? [["id":"11111111-1111-4111-8111-111111111111",
                "title":"Fixture", "state":"running", "isRunning":true]] : [],
            "idleTaskIds": running ? [] : ["local/11111111-1111-4111-8111-111111111111"]]
        if fuel {
            body["fuel"] = ["remainingPercent": 75, "windowMinutes": 10080,
                "resetsAt": Date.now.timeIntervalSince1970 + 600, "updatedAt": Date.now.timeIntervalSince1970]
        }
        let response = HTTPURLResponse(url: URL(string: "http://127.0.0.1:19427/state")!,
                                       statusCode: 200, httpVersion: nil, headerFields: nil)!
        requests[index].resume(returning: (try! JSONSerialization.data(withJSONObject: body), response))
    }
}
@main struct Check {
    static func checkFishQueue() {
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let taskID = "11111111-1111-4111-8111-111111111111"
        func task(_ ids: [String]?, host: String = "local", state: String = "waiting") -> CodexTask {
            CodexTask(id: taskID, title: "Fixture", state: state, detail: nil,
                      hostId: host, pendingQuestionIds: ids)
        }
        func snapshot(_ tasks: [CodexTask], at seconds: Double, connected: Bool = true,
                      idle: [String] = [], age: Double = 0) -> CodexSnapshot {
            CodexSnapshot(connected: connected, tasks: tasks,
                          updatedAt: start.addingTimeInterval(seconds - age).timeIntervalSince1970, idleTaskIds: idle)
        }
        let local = "local/" + taskID, remote = "remote/" + taskID
        var queue = CodexFishQueue()
        queue.update(snapshot([task(["one", "two"])], at: 0), at: start)
        assert(queue.waitingSince == start, "The first waiting queue starts the fish clock")
        queue.update(snapshot([task(["one", "two", "three"])], at: 10), at: start.addingTimeInterval(10))
        assert(queue.waitingSince == start, "New questions must not reset an existing queue")
        queue.update(snapshot([task(["two", "three"])], at: 20), at: start.addingTimeInterval(20))
        let reset = start.addingTimeInterval(20)
        assert(queue.waitingSince == reset, "Resolving one of several questions resets the remaining queue")
        var activeWaiting = task(["two", "three"])
        activeWaiting.isRunning = true
        queue.update(snapshot([activeWaiting], at: 30, idle: [local]), at: start.addingTimeInterval(30))
        assert(queue.waitingSince == reset, "An active or idle runtime cannot resolve explicitly pending questions")
        queue.update(snapshot([], at: 40, connected: false, idle: [local]), at: start.addingTimeInterval(40))
        assert(queue.waitingSince == reset, "Disconnected snapshots cannot reset or clear the queue")
        queue.update(snapshot([], at: 50, idle: [local], age: 100), at: start.addingTimeInterval(50))
        assert(queue.waitingSince == reset, "Stale snapshots cannot resolve the queue")
        queue.update(snapshot([task(nil)], at: 60), at: start.addingTimeInterval(60))
        assert(queue.waitingSince == reset, "Missing request metadata is not resolution")
        queue.update(snapshot([task(nil, host: "remote", state: "running")], at: 70), at: start.addingTimeInterval(70))
        assert(queue.waitingSince == nil, "A fresh empty visible queue hides the fish")
        queue.update(snapshot([task(["two", "three"])], at: 80), at: start.addingTimeInterval(80))
        assert(queue.waitingSince == reset, "The same queue must recover its age after a missing-task snapshot")
        queue.update(snapshot([], at: 90), at: start.addingTimeInterval(90))
        queue.update(snapshot([task(["new-queue"])], at: 100), at: start.addingTimeInterval(100))
        assert(queue.waitingSince == start.addingTimeInterval(100), "A distinct queue after fresh emptiness starts independently")
        queue.update(snapshot([], at: 110, idle: [local]), at: start.addingTimeInterval(110))
        assert(queue.waitingSince == nil, "Confirmed resolution of the whole queue clears the clock")

        queue = CodexFishQueue()
        queue.update(snapshot([task(["shared"]), task(["shared"], host: "remote")], at: 0), at: start)
        queue.update(snapshot([task(["shared"], host: "remote")], at: 10, idle: [local]), at: start.addingTimeInterval(10))
        assert(queue.waitingSince == start.addingTimeInterval(10), "Request identity must include host and task")
        queue.update(snapshot([], at: 20, idle: [remote]), at: start.addingTimeInterval(20))
        assert(queue.waitingSince == nil)

        queue = CodexFishQueue()
        queue.update(snapshot([task(nil)], at: 0), at: start)
        queue.update(snapshot([task(["identified"])], at: 10), at: start.addingTimeInterval(10))
        assert(queue.waitingSince == start, "Identifying an unknown waiting request must not count as resolution")
        queue.update(snapshot([task(["identified"]), task(["remote"], host: "remote")], at: 20), at: start.addingTimeInterval(20))
        queue.update(snapshot([task([], state: "running"), task(["remote"], host: "remote")], at: 30), at: start.addingTimeInterval(30))
        assert(queue.waitingSince == start.addingTimeInterval(30), "A confirmed transition to running resolves waiting")
        queue.update(snapshot([], at: 40, connected: false), at: start.addingTimeInterval(40))
        queue.update(snapshot([task(["different"], host: "another")], at: 50), at: start.addingTimeInterval(50))
        assert(queue.waitingSince == start.addingTimeInterval(30), "Disconnect cannot fabricate a fresh empty-queue boundary")

        queue = CodexFishQueue()
        var legacy = task(nil)
        legacy.requestId = "legacy-one"
        queue.update(snapshot([legacy], at: 0), at: start)
        legacy.requestId = "legacy-two"
        queue.update(snapshot([legacy], at: 10), at: start.addingTimeInterval(10))
        assert(queue.waitingSince == start, "A legacy requestId without an explicit pending list is not resolution evidence")
        queue.update(snapshot([], at: 20, idle: [local + "/legacy-two"]), at: start.addingTimeInterval(20))
        queue.update(snapshot([legacy], at: 30), at: start.addingTimeInterval(30))
        assert(queue.waitingSince == start, "Only the bridge host/task idle key can confirm a task is idle")
        queue.update(snapshot([], at: 40, idle: [local]), at: start.addingTimeInterval(40))
        queue.update(snapshot([legacy], at: 50), at: start.addingTimeInterval(50))
        assert(queue.waitingSince == start.addingTimeInterval(50), "Confirmed host/task idle clears retained legacy uncertainty")
        print("PASS: fish queue partial resolution, added requests, host isolation, stale/disconnected/missing state, generic IDs and fresh queue boundaries")
    }

    @MainActor static func settle(_ predicate: () -> Bool) async {
        for _ in 0..<1000 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        fatalError("Polling state did not settle")
    }
    @MainActor static func main() async {
        checkFishQueue()
        defer { testDefaults.removePersistentDomain(forName: suite) }
        testDefaults.set(false, forKey: "codexRocketEnabled")
        let activity = CodexActivity()
        assert(activity.pollTask == nil && ControlledSession.requests.isEmpty)
        let fishDate = Date.now.addingTimeInterval(-120)
        let reminder = CodexTask(id: "11111111-1111-4111-8111-111111111111", title: "Fixture",
                                 state: "waiting", detail: nil, pendingQuestionIds: ["one", "two"])
        activity.fishQueue.update(CodexSnapshot(connected: true, tasks: [reminder], updatedAt: fishDate.timeIntervalSince1970), at: fishDate)
        activity.fishQueueWaitingSince = activity.fishQueue.waitingSince
        activity.tasks = [reminder]
        activity.removeRequest(activity.pending[0])
        activity.clearRequests()
        activity.cardPresented = true; activity.cardPresented = false
        activity.pullCordStyle = .fish
        assert(activity.fishWaitingSince == fishDate, "Ignore, card presentation and style selection cannot reset the fish")
        activity.suspended = true; activity.updatePolling()
        assert(activity.fishWaitingSince == fishDate, "Suspending clears presentation without losing the queue clock")
        activity.suspended = false
        activity.preview = "waiting"
        let previewDate = activity.fishWaitingSince
        assert(previewDate != nil && previewDate != fishDate)
        activity.preview = "waiting"
        assert(activity.fishWaitingSince == previewDate, "Repeated preview updates must not restart its fish clock")
        activity.preview = nil
        assert(activity.fishWaitingSince == fishDate, "Preview must not replace the live queue clock")
        activity.readReminders = []
        testDefaults.removeObject(forKey: "codexHiddenQuestionReminders")
        print("PASS: fish ignores presentation/ignore/style/suspend changes and keeps preview time separate")
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
        ControlledSession.reply(3, running: false, connected: false, fuel: true)
        await settle { activity.fuel != nil }
        assert(!activity.connected && !activity.running, "Quota must be independent of the task connection")
        await settle { ControlledSession.requests.count == 5 }
        ControlledSession.reply(4, running: false, fuel: true)
        await settle { activity.connected }
        await settle { ControlledSession.requests.count == 6 }
        ControlledSession.requests[5].resume(throwing: URLError(.cannotConnectToHost))
        await settle { !activity.connected }
        assert(activity.fuel != nil, "A brief task transport failure discarded valid quota")
        assert(activity.completionSequence == 0, "Wake was misreported as task completion")
        activity.enabled = false
        await settle { ControlledSession.invalidations == 3 }
        try? await Task.sleep(for: .milliseconds(1150))
        assert(ControlledSession.requests.count == 6 && activity.pollTask == nil, "Disabled feature kept polling")
        print("PASS: disabled startup, enable/disable, late response rejection, single loop, sleep/wake, no false completion, session cleanup")

        activity.enabled = true
        await settle { ControlledSession.requests.count == 7 }
        var runningTask = reminder
        runningTask.isRunning = true
        activity.tasks = [runningTask]
        activity.connected = true
        activity.removeRequest(activity.pending[0])
        let draftID = activity.pending[0].identity
        activity.answerDrafts[draftID] = CodexAnswerDraft(text: "Unsent custom answer", selection: nil)
        let savedTasks = activity.tasks, savedDrafts = activity.answerDrafts
        let savedRead = activity.readReminders, savedAge = activity.fishWaitingSince
        NotchMotionEnvironment.shared.energySavingActive = true
        assert(activity.pollTask == nil && !activity.connected && !activity.waiting && !activity.running)
        assert(!activity.presentationEnabled && activity.enabled && testDefaults.bool(forKey: "codexRocketEnabled"))
        assert(activity.tasks == savedTasks && activity.answerDrafts == savedDrafts && activity.readReminders == savedRead,
               "Temporary saving must preserve pending, ignored and unsent user data")
        assert(activity.fishWaitingSince == savedAge, "Saving is not resolving the queue")
        activity.demonstrate("waiting")
        assert(activity.preview == nil && activity.previewTask == nil, "Preview must not bypass saving")
        ControlledSession.reply(6, running: false)
        await settle { ControlledSession.invalidations == 4 }
        assert(activity.tasks == savedTasks && activity.answerDrafts == savedDrafts && activity.completionSequence == 0,
               "An in-flight pre-saving response must not mutate the suspended state")
        NotchMotionEnvironment.shared.suspended = true
        NotchMotionEnvironment.shared.suspended = false
        assert(activity.tasks == savedTasks && activity.answerDrafts == savedDrafts,
               "Sleep/wake while saving must not clear the retained queue")
        try? await Task.sleep(for: .milliseconds(1150))
        assert(ControlledSession.requests.count == 7 && activity.pollTask == nil, "Saving kept polling")
        NotchMotionEnvironment.shared.energySavingActive = false
        await settle { ControlledSession.requests.count == 8 }
        assert(!activity.connected && activity.preview == nil, "Restoration must fetch fresh state without replaying preview")
        ControlledSession.reply(7, running: false)
        await settle { activity.connected }
        assert(activity.tasks.isEmpty && activity.answerDrafts.isEmpty && activity.readReminders.isEmpty,
               "Restored polling must reconcile the actual current queue")
        assert(activity.completionSequence == 0, "Cross-saving reconciliation is not a new completion")
        activity.enabled = false
        await settle { ControlledSession.invalidations == 5 }
        print("PASS: smart-saving queue/draft/ignore/age preservation, preview suppression, late-response rejection, no polling and fresh resume without false completion")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='notch-poll-check-') as directory:
    path = Path(directory)
    (path / 'Check.swift').write_text(activity + thrust + check)
    env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', str(root / 'boringNotch/Shortcuts/CodexShortcuts.swift'), str(path / 'Check.swift'), '-o', str(path / 'check')], env=env, check=True)
    subprocess.run([str(path / 'check')], check=True)
