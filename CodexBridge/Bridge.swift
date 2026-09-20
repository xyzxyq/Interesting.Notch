import Foundation
import Security

struct TaskKey: Hashable {
    let host: String
    let id: String
    var identity: String { "\(host)/\(id)" }
}
struct Entry {
    var runtime: Any = null
    var questions: Any = Object()
    var pending: [Object] = []
    var effort: Any = null
    var model: Object = [:]
    var revision = 0.0
    var owner = ""
    var receivedAt = 0.0
    var state: String? { Projection.taskState(runtime, pending: !pending.isEmpty) }
}
struct Submission: Hashable { let task: TaskKey; let question: String }

final class Bridge {
    let home: URL
    private let lock = NSLock()
    private let token: String
    private var connected = false
    private var lastContact = 0.0
    private var entries: [TaskKey: Entry] = [:]
    private var submissions = Set<Submission>()
    private var fuel: Object?
    private var allowances: [Object] = []

    init(home: URL) throws {
        self.home = home
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw BridgeError.invalid("Random source unavailable") }
        token = Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    func validToken(_ value: String?) -> Bool {
        guard let value, value.utf8.count == token.utf8.count else { return false }
        return zip(value.utf8, token.utf8).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    func snapshot(now: Double = Date().timeIntervalSince1970) -> Object {
        lock.lock(); defer { lock.unlock() }
        let fresh = connected && now - lastContact < 45 && !entries.values.contains { $0.state != nil && now - $0.receivedAt >= 45 }
        var tasks: [Object] = [], idle: [String] = []
        if fresh {
            for (key, entry) in entries.sorted(by: { $0.key.identity < $1.key.identity }) {
                if text(object(entry.runtime)["type"]) == "idle", now - entry.receivedAt < 35 { idle.append(key.identity) }
                if let state = entry.state {
                    tasks.append(["id": key.id, "hostId": key.host, "title": "Codex task", "state": state,
                                  "isRunning": Projection.taskState(entry.runtime) == "running", "reasoningEffort": entry.effort,
                                  "model": entry.model["model"] ?? null, "modelProvider": entry.model["modelProvider"] ?? null,
                                  "pendingQuestionIds": entry.pending.compactMap { $0["id"] as? String }, "questions": entry.pending,
                                  "detail": state == "waiting" ? "Needs your attention in Codex" : "Codex is working"])
                }
            }
        }
        func valid(_ value: Object) -> Bool {
            guard let date = number(value["updatedAt"]), let reset = number(value["resetsAt"]) else { return false }
            return now - date < 150 && now < reset
        }
        return ["connected": fresh, "tasks": tasks, "idleTaskIds": idle, "updatedAt": lastContact, "replyToken": token,
                "allowances": allowances.filter(valid), "fuel": fuel.flatMap { valid($0) ? $0 : nil } as Any? ?? null]
    }

    func answer(_ data: Object) throws -> Object {
        guard let host = data["hostId"] as? String, let id = data["taskId"] as? String,
              let questionID = data["questionId"] as? String, let raw = data["answer"] as? String,
              UUID(uuidString: id) != nil else { throw BridgeError.invalid("Invalid answer request") }
        let answer = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty, answer.unicodeScalars.count <= 4000 else { throw BridgeError.invalid("请输入有效回答（最多 4000 字）。") }
        let key = TaskKey(host: host, id: id), submission = Submission(task: key, question: questionID)
        let entry: Entry, question: Object
        lock.lock()
        do {
            defer { lock.unlock() }
            guard connected, let current = entries[key], Date().timeIntervalSince1970 - current.receivedAt <= 35, !current.owner.isEmpty else { throw BridgeError.invalid("Codex 连接已失效，请稍后重试。") }
            guard let pending = current.pending.first(where: { text($0["id"]) == questionID }) else { throw BridgeError.invalid("该问题已处理或不再有效。") }
            guard !submissions.contains(submission) else { throw BridgeError.invalid("回答已发送或正在确认，请勿重复提交。") }
            submissions.insert(submission)
            entry = current; question = pending
        }
        let body = try json([["questionItemId": questionID, "question": question["title"] ?? "", "answer": answer]])
        let reply = "<send_user_message_question_reply>\n" + String(decoding: body, as: UTF8.self) + "\n</send_user_message_question_reply>"
        let inputs: [Object] = [["type": "text", "text": reply, "text_elements": [Any]()]]
        let active = text(object(entry.runtime)["type"]) == "active"
        let params: Object = active
            ? ["conversationId": id, "input": inputs, "attachments": [Any](), "clientUserMessageId": UUID().uuidString.lowercased(),
               "restoreMessage": ["id": UUID().uuidString.lowercased(), "text": reply, "context": Object(), "createdAt": Int(Date().timeIntervalSince1970 * 1000)]]
            : ["conversationId": id, "turnStart": ["request": ["threadId": id, "input": inputs], "context": ["inheritThreadSettings": true]]]
        // On uncertain delivery retain the reservation: retrying may send an answer twice.
        let result = try ipcRequest(home: home, method: active ? "thread-follower-steer-turn" : "thread-follower-start-turn",
                                    version: active ? 1 : 2, params: params, owner: entry.owner, host: host)
        guard text(result["resultType"]) == "success" else {
            let error = String(describing: result["error"] ?? "").lowercased()
            if error.contains("timeout") || error.contains("disconnected") { throw BridgeError.timeout }
            lock.lock(); submissions.remove(submission); lock.unlock()
            throw BridgeError.invalid("Codex 未接受回答，请刷新后重试。")
        }
        return ["accepted": true]
    }

    func start() {
        Thread.detachNewThread { [self] in
            while true {
                autoreleasepool {
                    do { try listen() } catch { /* Private protocol failures never enter logs. */ }
                    lock.lock(); connected = false; entries.removeAll(); lock.unlock()
                }
                Thread.sleep(forTimeInterval: 2)
            }
        }
        Thread.detachNewThread { [self] in
            while true {
                autoreleasepool {
                    let result = readFuel(home: home)
                    lock.lock(); fuel = result.0; allowances = result.1; lock.unlock()
                }
                Thread.sleep(forTimeInterval: 60)
            }
        }
    }

    private func listen() throws {
        let socket = try Socket.unix(home.appendingPathComponent("ipc/ipc.sock").path)
        func initialize() throws {
            try socket.send(["type": "request", "requestId": "notch-init", "method": "initialize", "version": 0, "params": ["clientType": "interesting-notch"]])
        }
        func follow(_ key: TaskKey) throws {
            guard UUID(uuidString: key.id) != nil else { throw BridgeError.invalid("Invalid task identity") }
            try socket.send(["type": "broadcast", "method": "thread-stream-following-changed", "version": 1,
                             "params": ["conversationId": key.id, "hostId": key.host, "following": true]])
        }
        try initialize()
        var subscribed = Set<TaskKey>(), frames = Frames(), nextDiscovery = 0.0, nextRefresh = monotonic() + 15
        while true {
            if monotonic() >= nextDiscovery {
                for id in try recentIDs(home: home) {
                    let key = TaskKey(host: "local", id: id)
                    if subscribed.insert(key).inserted { try follow(key) }
                }
                nextDiscovery = monotonic() + 10
            }
            if monotonic() >= nextRefresh {
                try initialize()
                lock.lock(); let active = entries.filter { $0.value.state != nil }.map(\.key); lock.unlock()
                for key in active { try follow(key) }
                nextRefresh = monotonic() + 15
            }
            do {
                try autoreleasepool {
                    for message in try frames.append(socket.read(until: min(nextDiscovery, nextRefresh))) {
                        let kind = text(message["type"]), method = text(message["method"]), params = object(message["params"])
                        if kind == "client-discovery-request" {
                            try socket.send(["type": "client-discovery-response", "requestId": message["requestId"] ?? null, "response": ["canHandle": false]])
                        } else if kind == "response", text(message["requestId"]) == "notch-init" {
                            guard text(message["resultType"]) == "success" else { throw BridgeError.invalid("IPC initialization failed") }
                            lock.lock(); connected = true; lastContact = Date().timeIntervalSince1970; lock.unlock()
                        } else if kind == "broadcast" {
                            if ["thread-stream-following-status-requested", "thread-stream-following-changed"].contains(method) {
                                let key = TaskKey(host: params["hostId"] as? String ?? "local", id: text(params["conversationId"]))
                                if subscribed.insert(key).inserted { try follow(key) }
                            } else if method == "thread-stream-state-changed" {
                                guard number(message["version"]) == 11 else { throw BridgeError.invalid("Unsupported stream version") }
                                let key = TaskKey(host: text(params["hostId"]), id: text(params["conversationId"]))
                                guard !key.host.isEmpty, UUID(uuidString: key.id) != nil else { throw BridgeError.invalid("Invalid task identity") }
                                let change = object(params["change"])
                                guard ["snapshot", "patches"].contains(text(change["type"])), let revision = number(change["revision"]) else { throw BridgeError.invalid("Invalid change") }
                                lock.lock(); let previous = entries[key]; lock.unlock()
                                if text(change["type"]) == "patches", previous == nil || previous!.revision != number(change["baseRevision"]) {
                                    lock.lock(); entries.removeValue(forKey: key); lock.unlock()
                                    try follow(key); continue
                                }
                                var entry = previous ?? Entry()
                                entry.questions = try Projection.updateQuestions(entry.questions, change: change)
                                entry.pending = Projection.pending(entry.questions)
                                entry.runtime = try Projection.updateRuntime(entry.runtime, change: change)
                                entry.effort = Projection.effort(entry.effort, change: change)
                                entry.model = Projection.model(entry.model, change: change)
                                entry.revision = revision; entry.owner = text(message["sourceClientId"]); entry.receivedAt = Date().timeIntervalSince1970
                                lock.lock(); entries[key] = entry; lastContact = entry.receivedAt; lock.unlock()
                            } else if method == "ipc-connection-reset" || (method == "client-status-changed" && text(params["status"]) == "disconnected") {
                                lock.lock()
                                entries = entries.filter { method != "ipc-connection-reset" && $0.value.owner != text(params["clientId"]) }
                                lock.unlock()
                                subscribed.removeAll(); nextDiscovery = 0
                            }
                        }
                    }
                }
            } catch BridgeError.timeout { continue }
        }
    }
}
