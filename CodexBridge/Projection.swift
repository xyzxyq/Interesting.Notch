import Foundation
import CoreFoundation

typealias Object = [String: Any]
enum BridgeError: Error { case invalid(String), disconnected, timeout }
let null = NSNull()

func object(_ value: Any?) -> Object { value as? Object ?? [:] }
func text(_ value: Any?) -> String { value as? String ?? "" }
func bounded(_ value: String, _ count: Int) -> String { String(String.UnicodeScalarView(value.unicodeScalars.prefix(count))) }
func json(_ value: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes])
}
func number(_ value: Any?) -> Double? {
    guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
    return value.doubleValue
}

enum Projection {
    private static let questionKeys: Set<String> = ["turns", "turnHistory", "history", "entitiesByKey", "items", "type", "id", "delivery", "questions", "content", "input", "text", "status"]

    static func replyIDs(_ value: Any) -> [String] {
        guard let raw = value as? String else { return [] }
        let source = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let start = "<send_user_message_question_reply>", end = "</send_user_message_question_reply>"
        guard source.hasPrefix(start), source.hasSuffix(end), source.count >= start.count + end.count,
              let value = try? JSONSerialization.jsonObject(with: Data(source.dropFirst(start.count).dropLast(end.count).utf8), options: .fragmentsAllowed) else { return [] }
        return (value as? [Any] ?? [value]).compactMap { object($0)["questionItemId"] as? String }
    }

    static func questions(_ value: Any, key: String = "") -> Any {
        if key == "text" { return replyIDs(value) }
        if key == "questions" {
            return (value as? [Any] ?? []).compactMap { item -> Object? in
                let item = object(item)
                guard let title = item["title"] as? String else { return nil }
                return ["title": bounded(title, 4000), "options": Array((item["options"] as? [Any] ?? []).compactMap { $0 as? String }.prefix(20)).map { bounded($0, 1000) }]
            }
        }
        if let array = value as? [Any] { return array.map { questions($0) } }
        if let dictionary = value as? Object {
            var result = dictionary.filter { key == "entitiesByKey" || questionKeys.contains($0.key) }.mapValues { $0 }
            for (name, item) in result { result[name] = questions(item, key: name) }
            if text(dictionary["type"]) == "agentMessage", text(dictionary["delivery"]) == "async" {
                result["prompt"] = bounded(text(dictionary["text"]), 4000)
            }
            return result
        }
        return ["type", "id", "delivery", "status"].contains(key) ? value : null
    }

    // Apply only projected paths. Missing ancestors belong to discarded private fields.
    private static func patch(_ root: Any, path: ArraySlice<Any>, operation: String, value: Any) throws -> Any {
        guard let head = path.first else { return value }
        if var array = root as? [Any] {
            guard let n = number(head), n >= 0, n < Double(Int.max), n.rounded() == n else { throw BridgeError.invalid("Invalid patch index") }
            let index = Int(n)
            if path.count > 1 {
                guard index < array.count else { return root }
                array[index] = try patch(array[index], path: path.dropFirst(), operation: operation, value: value)
            } else if operation == "add" {
                guard index <= array.count else { throw BridgeError.invalid("Invalid insertion") }
                array.insert(value, at: index)
            } else {
                guard index < array.count else { throw BridgeError.invalid("Invalid replacement") }
                if operation == "remove" { array.remove(at: index) } else { array[index] = value }
            }
            return array
        }
        if var dictionary = root as? Object, let key = head as? String {
            if path.count > 1 {
                guard let child = dictionary[key] else { return root }
                dictionary[key] = try patch(child, path: path.dropFirst(), operation: operation, value: value)
            } else if operation == "remove" { dictionary.removeValue(forKey: key) }
            else { dictionary[key] = value }
            return dictionary
        }
        return root
    }

    static func updateQuestions(_ previous: Any, change: Object) throws -> Any {
        if text(change["type"]) == "snapshot" { return questions(change["conversationState"] ?? [:]) }
        var state: Any = previous is NSNull ? Object() : previous
        for change in change["patches"] as? [Object] ?? [] {
            let path = change["path"] as? [Any] ?? []
            let raw = change["value"] ?? null
            if path.isEmpty { state = questions(raw); continue }
            guard ["turns", "turnHistory"].contains(text(path.first)) else { continue }
            let key = text(path.last), operation = text(change["op"])
            var value = questions(raw, key: key)
            let inQuestions = path.contains { text($0) == "questions" }
            if inQuestions {
                if let raw = raw as? String { value = bounded(raw, 4000) }
                else if raw is Object {
                    guard let item = (questions([raw], key: "questions") as? [Object])?.first else { throw BridgeError.invalid("Malformed question") }
                    value = item
                } else if let raw = raw as? [Any], key == "options" {
                    value = Array(raw.compactMap { $0 as? String }.prefix(20)).map { bounded($0, 1000) }
                }
            }
            if operation != "remove", path.last is String,
               !questionKeys.contains(key), !(inQuestions && ["title", "options"].contains(key)),
               !(path.count > 1 && text(path[path.count - 2]) == "entitiesByKey") { continue }
            state = try patch(state, path: path[...], operation: operation, value: value)
        }
        return state
    }

    static func pending(_ state: Any) -> [Object] {
        var found: [String: Object] = [:], answered = Set<String>()
        func visit(_ value: Any) {
            if let value = value as? Object {
                if text(value["type"]) == "agentMessage", text(value["delivery"]) == "async" {
                    let list = value["questions"] as? [Object] ?? []
                    for (index, question) in list.enumerated() {
                        let idJSON = try! json(["request_user_input_async", value["id"] ?? null, index])
                        // Match Python's canonical IDs, including non-ASCII message IDs.
                        let id = String(decoding: idJSON, as: UTF8.self).utf16.map { $0 < 128 ? String(UnicodeScalar($0)!) : String(format: "\\u%04x", $0) }.joined()
                        found[id] = ["id": id, "title": question["title"] ?? "", "options": question["options"] ?? []]
                    }
                    if list.isEmpty, let id = value["id"] as? String, !id.isEmpty {
                        found[id] = ["id": id, "title": value["prompt"] ?? "", "options": [String]()]
                    }
                }
                if text(value["type"]) == "userMessage" || (text(value["type"]) == "steeringUserMessage" && text(value["status"]) == "accepted") {
                    for item in (value["content"] ?? value["input"]) as? [Object] ?? [] where text(item["type"]) == "text" {
                        answered.formUnion(item["text"] as? [String] ?? [])
                    }
                }
                for item in value.values { visit(item) }
            } else if let array = value as? [Any] { array.forEach(visit) }
        }
        visit(state)
        return found.keys.filter { !answered.contains($0) }.sorted().compactMap { found[$0] }
    }

    static func taskState(_ runtime: Any, pending: Bool = false) -> String? {
        if pending { return "waiting" }
        let runtime = object(runtime)
        guard text(runtime["type"]) == "active" else { return nil }
        return (runtime["activeFlags"] as? [String] ?? []).contains { ["waitingOnApproval", "waitingOnUserInput"].contains($0) } ? "waiting" : "running"
    }

    static func updateRuntime(_ previous: Any, change: Object) throws -> Any {
        if text(change["type"]) == "snapshot" { return object(change["conversationState"])["threadRuntimeStatus"] ?? null }
        var runtime = previous
        for item in change["patches"] as? [Object] ?? [] {
            let path = item["path"] as? [Any] ?? []
            if path.isEmpty { runtime = object(item["value"])["threadRuntimeStatus"] ?? null }
            else if text(path.first) == "threadRuntimeStatus" {
                if path.count == 1 { runtime = item["value"] ?? null }
                else if path.count == 2 || (path.count == 3 && text(path[1]) == "activeFlags") {
                    guard !(runtime is NSNull) else { throw BridgeError.invalid("Missing runtime") }
                    if path.count == 3, var fields = runtime as? Object, fields["activeFlags"] == nil {
                        fields["activeFlags"] = [String](); runtime = fields
                    }
                    runtime = try patch(runtime, path: path.dropFirst(), operation: text(item["op"]), value: item["value"] ?? null)
                } else { throw BridgeError.invalid("Unsupported runtime patch") }
            }
        }
        return runtime
    }

    private static func settings(_ previous: Object, change: Object) -> Object {
        if text(change["type"]) == "snapshot" { return object(object(change["conversationState"])["latestThreadSettings"]) }
        var result = previous
        for item in change["patches"] as? [Object] ?? [] {
            let path = item["path"] as? [String] ?? ["ignored"]
            if path.isEmpty { result = object(object(item["value"])["latestThreadSettings"]) }
            else if path == ["latestThreadSettings"] { result = object(item["value"]) }
            else if path.count == 2 && path[0] == "latestThreadSettings" { result[path[1]] = item["value"] ?? null }
        }
        return result
    }
    static func effort(_ previous: Any, change: Object) -> Any {
        let value = settings(["effort": previous], change: change)["effort"]
        return ["low", "medium", "high", "xhigh", "max", "ultra"].contains(text(value)) ? value! : null
    }
    static func model(_ previous: Any, change: Object) -> Object {
        settings(object(previous), change: change).filter { key, value in
            guard ["model", "modelProvider"].contains(key), let name = value as? String, !name.isEmpty, name.unicodeScalars.count <= 120 else { return false }
            return name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "-_./: ".unicodeScalars.contains($0) }
        }
    }
    static func fuel(_ result: Object, now: Double, weekly: Bool = false) -> Object? {
        let quota = object((result["rateLimitsByLimitId"] as? Object).map { $0["codex"] ?? null } ?? result["rateLimits"])
        guard quota["limitId"] == nil || quota["limitId"] is NSNull || text(quota["limitId"]) == "codex" else { return nil }
        let plan = text(quota["planType"])
        guard plan == "plus" || ["pro", "prolite", "team", "business", "enterprise", "edu"].contains(plan) else { return nil }
        let minutes = plan == "plus" && !weekly ? 300 : 10080
        for key in ["primary", "secondary"] {
            let window = object(quota[key])
            guard number(window["windowDurationMins"]) == Double(minutes) else { continue }
            guard let used = number(window["usedPercent"]), let reset = number(window["resetsAt"]), used >= 0, used <= 100, reset > now else { return nil }
            return ["remainingPercent": 100 - used, "windowMinutes": minutes, "resetsAt": reset, "updatedAt": now]
        }
        return nil
    }
}
