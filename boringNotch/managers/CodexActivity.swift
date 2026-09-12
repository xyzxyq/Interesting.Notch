import AppKit
import SwiftUI

struct CodexTask: Decodable, Identifiable, Equatable {
    let id: String
    let title: String
    let state: String
    let detail: String?
    var reasoningEffort: String? = nil
    var hostId: String? = nil
    var model: String? = nil
    var modelProvider: String? = nil
    var identity: String { "\(hostId ?? "local")/\(id)" }
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
    var waiting: Bool { enabled && (preview == "waiting" || (preview == nil && tasks.contains(where: \.waiting))) }
    var running: Bool { enabled && !waiting && (preview == "running" || (preview == nil && tasks.contains { $0.state == "running" })) }
    var effort: Int {
        if preview == "running" { return previewEffort }
        return tasks.filter { $0.state == "running" }.compactMap {
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

    var pending: [CodexTask] { tasks.filter(\.waiting) }
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
        navigationError = NSWorkspace.shared.open(url) ? nil : "无法打开 Codex，请检查应用是否已安装。"
    }
    static func shouldDismissRequests(enabled: Bool, preview: String?, connected: Bool, pendingCount: Int) -> Bool {
        if !enabled { return true }
        if let preview { return preview != "waiting" }
        // A disconnected bridge cannot confirm that the user resolved a request.
        return connected && pendingCount == 0
    }
    private func dismissResolvedRequests() {
        if Self.shouldDismissRequests(enabled: enabled, preview: preview, connected: connected, pendingCount: pending.count) {
            window?.orderOut(nil)
        }
    }

    func showRequests() {
        navigationError = nil
        if window == nil {
            let panel = CodexRequestPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 360),
                                          styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
            panel.title = "Codex · 需要你处理"
            panel.isReleasedWhenClosed = false
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = NSHostingView(rootView: CodexRequests(activity: self))
            window = panel
        }
        guard let window else { return }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let screen {
            window.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - window.frame.width / 2,
                                          y: screen.visibleFrame.maxY - window.frame.height - 85))
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

private class CodexRequestPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func resignKey() { super.resignKey(); orderOut(nil) }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
}

private struct CodexRequests: View {
    @ObservedObject var activity: CodexActivity
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("需要你处理", systemImage: "lightbulb")
                .font(.title2.weight(.semibold))
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
                    } else if activity.pending.isEmpty {
                        Text(activity.connected ? "待处理请求已在 Codex 中解决。" : "状态连接已断开，请在 Codex 中检查任务。")
                    } else {
                        ForEach(activity.pending, id: \.identity) { task in
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Codex 任务 · \(String(task.id.suffix(8)))").font(.headline)
                                Text("此任务正在等待批准、确认或补充信息。请在原任务中核对完整请求并处理。")
                                    .font(.callout).foregroundStyle(.secondary)
                                Button("在 Codex 中查看并处理") { activity.open(task) }
                            }
                            Divider()
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error = activity.navigationError { Text(error).foregroundStyle(.red).font(.caption) }
        }.padding(20).frame(width: 380, height: 360).preferredColorScheme(.dark)
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
