import AppKit
import SwiftUI

struct CodexQuestion: Decodable, Equatable {
    let id: String
    let title: String
    let options: [String]
}

struct CodexTask: Decodable, Identifiable, Equatable {
    let id: String
    let title: String
    let state: String
    let detail: String?
    var isRunning: Bool? = nil
    var working: Bool { isRunning ?? (state == "running") }
    var reasoningEffort: String? = nil
    var hostId: String? = nil
    var model: String? = nil
    var modelProvider: String? = nil
    var pendingQuestionIds: [String]? = nil
    var questions: [CodexQuestion]? = nil
    var question: CodexQuestion? { questions?.first { $0.id == requestId } }
    var requestId: String? = nil
    var identity: String { "\(hostId ?? "local")/\(id)" + (requestId.map { "/" + $0 } ?? "") }
    var waiting: Bool { state == "waiting" }
    var url: URL? {
        guard UUID(uuidString: id) != nil else { return nil }
        return URL(string: "codex://threads/\(id)")
    }
}

struct CodexFuel: Decodable, Equatable {
    let remainingPercent: Double
    let windowMinutes: Int
    let resetsAt: Double
    let updatedAt: Double
    func valid(at now: Date) -> Bool {
        remainingPercent.isFinite && (0...100).contains(remainingPercent)
            && [300, 10080].contains(windowMinutes) && resetsAt.isFinite && updatedAt.isFinite
            && now.timeIntervalSince1970 < resetsAt
            && (-5..<150).contains(now.timeIntervalSince1970 - updatedAt)
    }
    var description: String {
        "Codex · \(windowMinutes == 300 ? "5 小时" : "周")剩余 \(Int(remainingPercent.rounded()))%\n重置时间：\(Date(timeIntervalSince1970: resetsAt).formatted(date: .abbreviated, time: .shortened))"
    }
}

struct CodexSnapshot: Decodable {
    let connected: Bool
    let tasks: [CodexTask]
    let updatedAt: Double
    var fuel: CodexFuel? = nil
    var allowances: [CodexFuel]? = nil
    var replyToken: String? = nil
    func fresh(at now: Date) -> Bool {
        updatedAt.isFinite && now.timeIntervalSince1970 - updatedAt < 35
            && updatedAt - now.timeIntervalSince1970 < 5
    }
}

// Brief missing/running samples must not dismiss a pending request immediately.
struct CodexTaskStability {
    private var retained: [String: (task: CodexTask, seen: Date)] = [:]
    mutating func update(_ incoming: [CodexTask], at now: Date) -> [CodexTask] {
        var result = Dictionary(incoming.map { ($0.identity, $0) }, uniquingKeysWith: { first, next in next.waiting ? next : first })
        for (id, entry) in retained {
            let age = now.timeIntervalSince(entry.seen)
            if age >= 0 && age < 2 && (result[id] == nil || (entry.task.waiting && result[id]?.waiting == false)) {
                result[id] = entry.task
            }
        }
        for task in incoming {
            if result[task.identity] == task { retained[task.identity] = (task, now) }
        }
        retained = retained.filter { result[$0.key] != nil }
        return result.values.sorted { $0.identity < $1.identity }
    }
    mutating func reset() { retained.removeAll() }
}

@MainActor final class CodexActivity: ObservableObject {
    static let shared = CodexActivity()
    @Published var enabled = UserDefaults.standard.object(forKey: "codexRocketEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(enabled, forKey: "codexRocketEnabled"); if !enabled { tasks = []; preview = nil; stability.reset() }; dismissResolvedRequests() }
    }
    @Published private(set) var tasks: [CodexTask] = [] { didSet { dismissResolvedRequests() } }
    @Published private(set) var connected = false { didSet { dismissResolvedRequests() } }
    @Published private(set) var fuel: CodexFuel?
    @Published private(set) var allowances: [CodexFuel] = []
    @Published private(set) var preview: String? { didSet { dismissResolvedRequests() } }
    @Published var navigationError: String?
    private var stability = CodexTaskStability()
    private var lastSuccess = Date.distantPast
    private var previewTask: Task<Void, Never>?
    private var window: NSPanel?
    private var replyToken: String?
    @Published private(set) var submitting = Set<String>()
    @Published private(set) var replyErrors: [String: String] = [:]
    @Published private(set) var windowDissolve: CGFloat = 1
    @Published private(set) var panelReady = false
    @Published private var readReminders = Set(UserDefaults.standard.stringArray(forKey: "codexHiddenQuestionReminders") ?? [])
    private var dismissTask: Task<Void, Never>?
    private var panelTask: Task<Void, Never>?
    var waiting: Bool { enabled && (preview == "waiting" || (preview == nil && !pending.isEmpty)) }
    var running: Bool { enabled && (preview == "running" || (preview == nil && tasks.contains { $0.working })) }
    var effort: Int {
        if preview == "running" { return previewEffort }
        return tasks.filter { $0.working }.compactMap {
            CodexThrust.levels.firstIndex(of: $0.reasoningEffort ?? "")
        }.max() ?? -1
    }
    @Published var previewEffort = 2
    @Published var previewCount = 1
    static func headerTask(in tasks: [CodexTask]) -> CodexTask? {
        tasks.sorted {
            if $0.waiting != $1.waiting { return $0.waiting }
            let left = CodexThrust.levels.firstIndex(of: $0.reasoningEffort ?? "") ?? -1
            let right = CodexThrust.levels.firstIndex(of: $1.reasoningEffort ?? "") ?? -1
            return left == right ? $0.identity < $1.identity : left > right
        }.first
    }
    static func modelLabel(_ model: String?, effort: String?) -> String {
        let names = ["gpt-6-astra": "Astra", "gpt-5.6-luna": "5.6-Luna",
                     "gpt-5.6-terra": "5.6-Terra", "gpt-5.6-sol": "5.6-Sol",
                     "gpt-5.5": "5.5", "gpt-5.3-codex-spark": "5.3-Codex-Spark"]
        let raw = model ?? "模型未知"
        let name = names[raw.lowercased()] ?? (raw.lowercased().hasPrefix("gpt-") ? String(raw.dropFirst(4)) : raw)
        let strength = effort == "medium" ? "mid" : (effort ?? "未知")
        return name + " " + strength
    }

    var headerModel: String {
        guard let task = Self.headerTask(in: tasks) else { return connected ? "暂无任务" : "未连接" }
        return Self.modelLabel(task.model, effort: task.reasoningEffort) + (tasks.count > 1 ? " · \(tasks.count)任务" : "")
    }
    var headerDetail: String {
        guard let task = Self.headerTask(in: tasks) else { return "Codex · " + headerModel }
        return "Codex · \(task.modelProvider ?? "提供方未知")\n\(task.model ?? "模型未知") · \(task.reasoningEffort ?? "未知")\n\(task.waiting ? "等待你处理" : "运行中")" + (tasks.count > 1 ? "\n优先显示等待确认的任务，否则显示思考强度最高的任务" : "")
    }
    var headerAllowance: String {
        fuel.map { "\(Int($0.remainingPercent.rounded()))%" } ?? "—"
    }

    static func reminders(in tasks: [CodexTask]) -> [CodexTask] {
        tasks.filter(\.waiting).flatMap { task -> [CodexTask] in
            let ids = Array(Set(task.pendingQuestionIds ?? [])).sorted()
            if ids.isEmpty { return [task] }
            return ids.map { id in
                var reminder = task
                reminder.requestId = id
                return reminder
            }
        }
    }
    static func unread(_ reminders: [CodexTask], excluding read: Set<String>) -> [CodexTask] {
        reminders.filter { !read.contains($0.identity) }
    }
    var pending: [CodexTask] { Self.unread(Self.reminders(in: tasks), excluding: readReminders) }
    private func markRead(_ reminders: [CodexTask]) {
        readReminders.formUnion(reminders.map(\.identity))
        UserDefaults.standard.set(Array(readReminders).sorted(), forKey: "codexHiddenQuestionReminders")
        dismissResolvedRequests()
    }
    func clearRequests() {
        if preview != nil { demonstrate("running") }
        else { markRead(pending) }
    }
    var status: String {
        if !enabled { return "Codex 动效已关闭" }
        if preview != nil { return "视觉预览 · 20 秒后恢复实时状态" }
        if !connected { return "未连接 Codex 状态桥接服务" }
        if waiting { return "有 \(pending.count) 个请求需要处理" }
        return running ? "Codex 正在运行 · \(effort >= 0 ? CodexThrust.labels[effort] : "思考强度未知")" : "Codex 当前没有运行中的任务"
    }
    private init() {
        Task { [weak self] in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 2
            configuration.timeoutIntervalForResource = 3
            let session = URLSession(configuration: configuration)
            while !Task.isCancelled {
                guard let self else { return }
                if self.enabled {
                    do {
                        let (data, response) = try await session.data(from: URL(string: "http://127.0.0.1:19427/state")!)
                        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 256_000 else { throw URLError(.badServerResponse) }
                        let snapshot = try JSONDecoder().decode(CodexSnapshot.self, from: data)
                        guard snapshot.connected, snapshot.fresh(at: .now) else { throw URLError(.cannotConnectToHost) }
                        self.lastSuccess = .now
                        self.replyToken = snapshot.replyToken
                        let fuel = snapshot.fuel.flatMap { $0.valid(at: .now) ? $0 : nil }
                        if self.fuel != fuel { self.fuel = fuel }
                        let allowances = (snapshot.allowances ?? []).filter { $0.valid(at: .now) }.sorted { $0.windowMinutes < $1.windowMinutes }
                        if self.allowances != allowances { self.allowances = allowances }
                        let tasks = snapshot.tasks.filter { UUID(uuidString: $0.id) != nil && ["running", "waiting"].contains($0.state) }
                        let stable = self.stability.update(tasks, at: .now)
                        if self.tasks != stable { self.tasks = stable }
                        if !self.connected { self.connected = true }
                    } catch {
                        if self.connected { self.connected = false }
                        // Retain the presentation for short transport failures; never indefinitely.
                        if Date.now.timeIntervalSince(self.lastSuccess) >= 5 {
                            if self.fuel != nil { self.fuel = nil }
                            if !self.allowances.isEmpty { self.allowances = [] }
                            if !self.tasks.isEmpty { self.tasks = [] }
                            self.stability.reset()
                        }
                    }
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
    func demonstrate(_ state: String?) {
        previewTask?.cancel()
        if state == "waiting" { previewCount = 1 }
        preview = state
        if state != nil {
            enabled = true
            previewTask = Task {
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled else { return }
                preview = nil
            }
        }
    }
    func open(_ task: CodexTask) {
        guard preview == nil, let url = task.url else { return }
        guard NSWorkspace.shared.open(url) else {
            navigationError = "无法打开 Codex，请检查应用是否已安装。"
            return
        }
        navigationError = nil

    }
    func submit(_ answer: String, for task: CodexTask) {
        let answer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty, answer.count <= 4000, let question = task.question,
              let replyToken, !submitting.contains(task.identity) else { return }
        submitting.insert(task.identity)
        replyErrors[task.identity] = nil
        Task { @MainActor in
            do {
                var request = URLRequest(url: URL(string: "http://127.0.0.1:19427/answer")!)
                request.httpMethod = "POST"
                request.timeoutInterval = 25
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue(replyToken, forHTTPHeaderField: "X-Notch-Token")
                request.httpBody = try JSONSerialization.data(withJSONObject: [
                    "hostId": task.hostId ?? "local", "taskId": task.id,
                    "questionId": question.id, "answer": answer
                ])
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    let error = (try? JSONSerialization.jsonObject(with: data)) as? [String: String]
                    throw NSError(domain: "CodexAnswer", code: 1, userInfo: [NSLocalizedDescriptionKey: error?["error"] ?? "回答提交失败，请重试。"])
                }
                // Keep the row until Codex publishes the acknowledged reply.
            } catch {
                replyErrors[task.identity] = error.localizedDescription
                submitting.remove(task.identity)
            }
        }
    }

    static func shouldDismissRequests(enabled: Bool, preview: String?, connected: Bool, pendingCount: Int) -> Bool {
        if !enabled { return true }
        if let preview { return preview != "waiting" }
        // A disconnected bridge cannot confirm that the user resolved a request.
        return connected && pendingCount == 0
    }
    private func dismissResolvedRequests() {
        let resolved = Self.shouldDismissRequests(enabled: enabled, preview: preview, connected: connected, pendingCount: pending.count)
        guard resolved else {
            if dismissTask != nil {
                dismissTask?.cancel(); dismissTask = nil
                windowDissolve = 0
                panelReady = true
            }
            return
        }
        guard window?.isVisible == true, dismissTask == nil else { return }
        panelTask?.cancel(); panelTask = nil
        dismissTask = Task { @MainActor in
            withAnimation(.easeOut(duration: 0.65)) { windowDissolve = 1 }
            do {
                try await Task.sleep(for: .milliseconds(700))
                try Task.checkCancellation()
                window?.orderOut(nil)
                panelReady = false
                dismissTask = nil
            } catch { }
        }
    }

    func closeRequests() {
        guard panelReady else { return }
        panelReady = false
        panelTask?.cancel()
        panelTask = Task { @MainActor in
            windowDissolve = 1
            do {
                try await Task.sleep(for: .milliseconds(600))
                try Task.checkCancellation()
                window?.orderOut(nil)
                panelTask = nil
            } catch { }
        }
    }

    func showRequests(anchor: CGPoint) {
        navigationError = nil
        if window?.isVisible == true { closeRequests(); return }
        guard panelTask == nil else { return }
        dismissTask?.cancel(); dismissTask = nil; windowDissolve = 1
        panelTask?.cancel(); panelTask = nil
        panelReady = false
        if window == nil {
            let panel = CodexRequestPanel(contentRect: NSRect(x: 0, y: 0, width: 476, height: 456),
                                          styleMask: [.borderless], backing: .buffered, defer: false)
            panel.onCancel = { [weak self] in self?.closeRequests() }
            panel.title = "Codex · 需要你处理"
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.isReleasedWhenClosed = false
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = NSHostingView(rootView: CodexRequests(activity: self))
            window = panel
        }
        guard let window else { return }
        let screen = NSScreen.screens.first { NSMouseInRect(anchor, $0.frame, false) } ?? NSScreen.main
        if let screen {
            // Keep the expansion's top-center attached to the clicked droplet.
            let x = min(screen.frame.maxX - window.frame.width, max(screen.frame.minX, anchor.x - window.frame.width / 2))
            window.setFrameOrigin(NSPoint(x: x, y: anchor.y + 20 - window.frame.height))
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        panelTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(32))
                try Task.checkCancellation()
                windowDissolve = 0
                try await Task.sleep(for: .milliseconds(600))
                try Task.checkCancellation()
                panelReady = true
                panelTask = nil
            } catch { }
        }
    }
}

private class CodexRequestPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

private struct CodexRequests: View {
    @ObservedObject var activity: CodexActivity
    @Environment(\.accessibilityReduceMotion) private var reduced
    @State private var rows: [CodexTask] = []
    @State private var dissolving = Set<String>()
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("需要你处理", systemImage: "lightbulb").font(.title2.weight(.semibold))
                Spacer()
                Button("收起", action: activity.closeRequests)
                    .buttonStyle(.plain)
            }
            Text(activity.status).font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if activity.preview != nil {
                        Text("这是水滴交互预览，不会提交任何批准或选择。")
                        ForEach(0..<activity.previewCount, id: \.self) { index in
                            Text("待处理提示 \(index + 1)")
                        }
                        Button("追加一个预览请求") { activity.previewCount += 1 }
                        Button("预览恢复运行") { activity.demonstrate("running") }
                    } else if rows.isEmpty {
                        Text(activity.connected ? "待处理请求已在 Codex 中解决。" : "状态连接已断开，请在 Codex 中检查任务。")
                    } else {
                        ForEach(rows, id: \.identity) { task in
                            CodexQuestionRow(activity: activity, task: task)
                            .modifier(CodexDissolve(progress: dissolving.contains(task.identity) ? 1 : 0))
                            .allowsHitTesting(!dissolving.contains(task.identity))
                            Divider()
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                    // Native focus rings extend beyond the field's layout bounds.
                    .padding(4)
            }
            HStack {
                Text("收起保留问题；清空仅隐藏提醒").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("清空提醒", action: activity.clearRequests)
                    .buttonStyle(.plain).foregroundStyle(.secondary).font(.caption)
            }
            if let error = activity.navigationError { Text(error).foregroundStyle(.red).font(.caption) }
        }.padding(20).frame(width: 380, height: 360)
        .background(Color(white: 0.09), in: RoundedRectangle(cornerRadius: 20))
        .modifier(CodexDissolve(progress: activity.windowDissolve))
        .animation(.easeInOut(duration: 0.55), value: activity.windowDissolve)
        .allowsHitTesting(activity.panelReady && activity.windowDissolve == 0)
        .padding(48)
        .preferredColorScheme(.dark)
        .task(id: activity.pending) {
            let incoming = activity.pending
            let ids = Set(incoming.map(\.identity))
            let oldIDs = Set(rows.map(\.identity))
            rows += incoming.filter { !oldIDs.contains($0.identity) }
            withAnimation(.easeOut(duration: 0.65)) { dissolving = Set(rows.map(\.identity)).subtracting(ids) }
            do {
                try await Task.sleep(for: .milliseconds(650))
                try Task.checkCancellation()
                rows = incoming
                dissolving = []
            } catch { }
        }
    }
}

private struct CodexQuestionRow: View {
    @ObservedObject var activity: CodexActivity
    let task: CodexTask
    @State private var draft = ""
    @FocusState private var editing: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let question = task.question {
                Text(question.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                    Button {
                        if ["其他", "自行输入", "自定义", "other"].contains(where: { option.lowercased().contains($0) }) {
                            editing = true
                        } else { activity.submit(option, for: task) }
                    } label: {
                        Text(option).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 5)
                    }.buttonStyle(.bordered)
                }
                HStack(alignment: .bottom) {
                    TextField("或自行输入，回车提交", text: $draft, axis: .vertical)
                        .lineLimit(1...)
                        .fixedSize(horizontal: false, vertical: true)
                        .textFieldStyle(.roundedBorder).focused($editing)
                        .onSubmit { activity.submit(draft, for: task) }
                    Button("发送") { activity.submit(draft, for: task) }
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if activity.submitting.contains(task.identity) {
                    Label("正在提交，等待 Codex 确认…", systemImage: "clock").font(.caption)
                }
                if let error = activity.replyErrors[task.identity] {
                    Text(error).foregroundStyle(.orange).font(.caption)
                }
            } else {
                Text("此请求需要在 Codex 中核对完整内容。")
                Button("在 Codex 中查看") { activity.open(task) }
            }
        }
        .disabled(activity.submitting.contains(task.identity))
    }
}

struct CodexActivitySettings: View {
    @ObservedObject private var activity = CodexActivity.shared
    var body: some View {
        Toggle("Codex 火箭与提醒水滴", isOn: $activity.enabled)
        Text(activity.status).font(.caption).foregroundStyle(.secondary)
        if activity.enabled {
            HStack {
                Button("预览火箭") { activity.demonstrate("running") }
                Button("预览水滴") { activity.demonstrate("waiting") }
                if activity.preview != nil { Button("结束预览") { activity.demonstrate(nil) } }
            }
            if activity.preview == "running" {
                Picker("预览思考强度", selection: $activity.previewEffort) {
                    ForEach(0..<CodexThrust.labels.count, id: \.self) { index in
                        Text(CodexThrust.labels[index]).tag(index)
                    }
                }
            }
            Text("尾焰反映所选思考强度，不表示真实 token 速度；高及以上显示速度参照线。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
