import AppKit
import Combine
import SwiftUI
import OSLog

struct CodexQuestion: Decodable, Equatable {
    let id: String
    let title: String
    let options: [String]
    var replyable: Bool? = nil
    var canReply: Bool { replyable != false }
    static func validAnswer(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.unicodeScalars.count <= 4000
    }
}

// A first confirmation enters the editor; only an explicit selection or editing can send.
struct CodexAnswerDraft: Equatable {
    var text = ""
    var selection: Int?
    enum Confirmation { case edit, cancelEditing, submit, none }
    func confirmation(editing: Bool) -> Confirmation {
        if !editing && selection == nil { return .edit }
        if editing && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .cancelEditing }
        return CodexQuestion.validAnswer(text) ? .submit : .none
    }
    mutating func select(_ index: Int, options: [String], toggle: Bool = true) -> Bool {
        guard options.indices.contains(index) else { return false }
        if toggle && selection == index {
            selection = nil; text = ""; return false
        }
        if ["其他", "自行输入", "自定义", "other"].contains(options[index].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) {
            selection = nil; text = ""; return true
        }
        selection = index; text = options[index]; return false
    }
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
    var serviceTier: String? = nil
    var isFastMode: Bool { serviceTier == "priority" }
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
    var idleTaskIds: [String]? = nil
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

// Viewing or hiding reminders is not resolution; retain uncertain requests across transport gaps.
struct CodexFishQueue {
    private var pending: [String: Set<String?>] = [:]
    private var retainedWaitingSince: Date?
    private(set) var waitingSince: Date?

    mutating func update(_ snapshot: CodexSnapshot, at now: Date) {
        guard snapshot.connected, snapshot.fresh(at: now) else { return }
        let tasks = Dictionary(snapshot.tasks.filter {
            UUID(uuidString: $0.id) != nil && ["running", "waiting"].contains($0.state)
        }.map { ("\($0.hostId ?? "local")/\($0.id)", $0) }, uniquingKeysWith: { first, next in
            next.waiting ? next : first
        })
        let waiting = tasks.filter { $0.value.waiting }.mapValues { task -> Set<String?> in
            let ids = task.pendingQuestionIds ?? []
            return ids.isEmpty ? [nil] : Set(ids.map(Optional.some))
        }
        if waitingSince == nil, !waiting.isEmpty, !waiting.contains(where: { key, ids in
            guard let previous = pending[key] else { return false }
            return ids.contains(nil) || previous.contains(nil) || !ids.isDisjoint(with: previous)
        }) {
            // A wholly new queue after a fresh empty snapshot must not inherit abandoned uncertainty.
            pending.removeAll(); retainedWaitingSince = nil
        }
        let idle = Set(snapshot.idleTaskIds ?? [])
        var resolved = false
        for (key, requests) in pending {
            guard let task = tasks[key] else {
                if idle.contains(key) { pending.removeValue(forKey: key); resolved = true }
                continue
            }
            if task.state == "running" {
                pending.removeValue(forKey: key); resolved = true
            } else if let ids = task.pendingQuestionIds {
                let current = Set(ids.map(Optional.some))
                if requests.contains(where: { $0 != nil && !current.contains($0) }) { resolved = true }
                // A nil ID represents an unclassified waiting flag, not an additional question.
                pending[key] = current.isEmpty ? [nil] : current
            }
        }
        for (key, ids) in waiting {
            if tasks[key]?.pendingQuestionIds != nil {
                pending[key] = ids
            } else if pending[key] == nil {
                pending[key] = [nil]
            }
        }
        if pending.isEmpty { retainedWaitingSince = nil }
        else if retainedWaitingSince == nil || resolved { retainedWaitingSince = now }
        waitingSince = waiting.isEmpty ? nil : retainedWaitingSince
    }
}

@MainActor final class CodexActivity: ObservableObject {
    static let shared = CodexActivity()
    static let log = Logger(subsystem: "theboringteam.boringnotch", category: "CodexActivity")
    @Published var reminderStyle = CodexReminderStyle(rawValue: UserDefaults.standard.string(forKey: "codexReminderStyle") ?? "") ?? .droplet {
        didSet {
            guard reminderStyle != oldValue else { return }
            UserDefaults.standard.set(reminderStyle.rawValue, forKey: "codexReminderStyle")
            closeRequests()
        }
    }
    @Published var pullCordStyle = CodexPullCordStyle(rawValue: UserDefaults.standard.string(forKey: "codexPullCordStyle") ?? "") ?? .classic {
        didSet {
            guard pullCordStyle != oldValue else { return }
            UserDefaults.standard.set(pullCordStyle.rawValue, forKey: "codexPullCordStyle")
        }
    }
    @Published private(set) var presentedStyle = CodexReminderStyle.droplet
    @Published private(set) var cardPresented = false
    @Published private(set) var cardAnimating = false
    private let genie = CodexGenieTransition()
    private var cardSource = CGPoint.zero
    private var automaticCordDismiss = false
    private(set) var usesGenie = false
    var panelTopInset: CGFloat { presentedStyle == .pullCord ? 64 : 0 }
    @Published var enabled = (UserDefaults.standard.object(forKey: "codexRocketEnabled") == nil || UserDefaults.standard.bool(forKey: "codexRocketEnabled")) {
        didSet {
            guard enabled != oldValue else { return }
            UserDefaults.standard.set(enabled, forKey: "codexRocketEnabled")
            updatePolling()
            dismissResolvedRequests()
        }
    }
    @Published private(set) var energySavingActive = false
    var presentationEnabled: Bool { enabled && !energySavingActive }
    @Published private(set) var tasks: [CodexTask] = [] { didSet { dismissResolvedRequests() } }
    @Published private(set) var completionSequence = 0
    @Published private(set) var connected = false { didSet { dismissResolvedRequests() } }
    @Published private(set) var fuel: CodexFuel?
    @Published private(set) var allowances: [CodexFuel] = []
    @Published private(set) var preview: String? {
        didSet {
            if preview != oldValue { previewWaitingSince = preview == "waiting" ? .now : nil }
            dismissResolvedRequests()
        }
    }
    @Published private var fishQueueWaitingSince: Date?
    private var fishQueue = CodexFishQueue()
    private var previewWaitingSince: Date?
    var fishWaitingSince: Date? { preview == "waiting" ? previewWaitingSince : fishQueueWaitingSince }
    @Published var navigationError: String?
    private var stability = CodexTaskStability()
    private var lastSuccess = Date.distantPast
    private var previewTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var motionObservation: AnyCancellable?
    private var suspended = false
    private var window: NSPanel?
    @Published var keyboardRequestID: String?
    @Published private(set) var answerDrafts: [String: CodexAnswerDraft] = [:]
    @Published private(set) var editingRequestID: String?
    @Published private(set) var keyboardOpenSequence = 0
    var displayedRequests: [CodexTask] {
        guard preview != nil else { return pending }
        return (0..<previewCount).map { index in
            CodexTask(id: "11111111-1111-4111-8111-111111111111", title: "交互预览", state: "waiting", detail: nil,
                questions: [CodexQuestion(id: "preview-\(index)", title: "你希望先完善哪一部分？",
                    options: ["水滴与卡片的视觉质感", "交互请求的可靠性", "两部分一起优化"])], requestId: "preview-\(index)")
        }
    }
    var keyboardRequest: CodexTask? {
        displayedRequests.first { $0.identity == keyboardRequestID } ?? displayedRequests.first
    }

    private var replyToken: String?
    @Published private(set) var submitting = Set<String>()
    @Published private(set) var replyErrors: [String: String] = [:]
    @Published private(set) var windowDissolve: CGFloat = 1
    @Published private(set) var windowReveal: CGFloat = 1
    @Published private(set) var panelReady = false
    // Legacy task-wide hides must not silence the next approval in that task.
    @Published private var readReminders = Set((UserDefaults.standard.stringArray(forKey: "codexHiddenQuestionReminders") ?? [])
        .filter { $0.split(separator: "/", maxSplits: 2).count == 3 })
    private var dismissTask: Task<Void, Never>?
    private var panelTask: Task<Void, Never>?
    var waiting: Bool { presentationEnabled && (preview == "waiting" || (preview == nil && !pending.isEmpty)) }
    var running: Bool { presentationEnabled && (preview == "running" || (preview == nil && tasks.contains { $0.working })) }
    // Pending reminders live in the droplet; they must not hide active work.
    static func shouldShowRocket(enabled: Bool, running: Bool) -> Bool {
        enabled && running
    }
    var rocketVisible: Bool { Self.shouldShowRocket(enabled: presentationEnabled, running: running) }
    // The bridge reports active tasks, not success/failure. Only a fresh, connected
    // transition to idle counts; old reminders may remain after work finishes.
    static func didFinishWork(previous: [CodexTask], current: [CodexTask], confirmedIdle: [String], continuousConnection: Bool) -> Bool {
        let working = previous.filter(\.working)
        return continuousConnection && !current.contains(where: \.working) && !working.isEmpty
            && working.allSatisfy { confirmedIdle.contains($0.identity) }
    }

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
    static func retainedReadReminders(_ read: Set<String>, tasks: [CodexTask]) -> Set<String> {
        read.intersection(reminders(in: tasks).map(\.identity))
    }
    private func reconcileRequests(_ current: [CodexTask]) {
        let retained = Self.retainedReadReminders(readReminders, tasks: current)
        if retained != readReminders {
            readReminders = retained
            UserDefaults.standard.set(Array(retained).sorted(), forKey: "codexHiddenQuestionReminders")
        }
        let ids = Set(Self.reminders(in: current).map(\.identity))
        let drafts = answerDrafts.filter { ids.contains($0.key) }
        if drafts != answerDrafts { answerDrafts = drafts }
        if let editingRequestID, !ids.contains(editingRequestID) { self.editingRequestID = nil }
        let activeSubmissions = submitting.intersection(ids)
        if activeSubmissions != submitting { submitting = activeSubmissions }
        let errors = replyErrors.filter { ids.contains($0.key) }
        if errors != replyErrors { replyErrors = errors }
    }
    private func markRead(_ reminders: [CodexTask]) {
        readReminders.formUnion(reminders.map(\.identity))
        UserDefaults.standard.set(Array(readReminders).sorted(), forKey: "codexHiddenQuestionReminders")
        dismissResolvedRequests()
    }
    func removeRequest(_ task: CodexTask) { markRead([task]) }
    func removePreviewRequest() {
        previewCount = max(0, previewCount - 1)
        if previewCount == 0 { demonstrate("running") }
    }
    func clearRequests() {
        if preview != nil { demonstrate("running") }
        else { markRead(pending) }
    }
    var status: String {
        if !enabled { return "Codex 动效已关闭" }
        if energySavingActive { return "智能节能中 · Codex 提醒与动效已暂停" }
        if preview != nil { return "视觉预览 · 20 秒后恢复实时状态" }
        if !connected { return "未连接 Codex 状态桥接服务" }
        if waiting { return "有 \(pending.count) 个请求需要处理" }
        return running ? "Codex 正在运行 · \(effort >= 0 ? CodexThrust.labels[effort] : "思考强度未知")" : "Codex 当前没有运行中的任务"
    }
    private init() {
        let motion = NotchMotionEnvironment.shared
        motionObservation = motion.$suspended.combineLatest(motion.$energySavingActive)
            .removeDuplicates { $0 == $1 }.sink { [weak self] suspended, saving in
            guard let self else { return }
            self.suspended = suspended
            self.energySavingActive = saving
            self.updatePolling()
        }
    }
    private func updatePolling() {
        pollTask?.cancel()
        pollTask = nil
        if energySavingActive && enabled {
            previewTask?.cancel(); previewTask = nil
            preview = nil
            stability.reset()
            connected = false; replyToken = nil; lastSuccess = .distantPast
            hideRequestsImmediately()
            return
        }
        guard enabled && !suspended else {
            previewTask?.cancel(); previewTask = nil
            tasks = []; preview = nil; stability.reset()
            connected = false; replyToken = nil
            fuel = nil; allowances = []; lastSuccess = .distantPast
            return
        }
        pollTask = Task { [weak self] in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 2
            configuration.timeoutIntervalForResource = 3
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            while !Task.isCancelled {
                guard let self, self.presentationEnabled, !self.suspended else { return }
                do {
                    let (data, response) = try await session.data(from: URL(string: "http://127.0.0.1:19427/state")!)
                    try Task.checkCancellation()
                    guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 256_000 else { throw URLError(.badServerResponse) }
                    let snapshot = try JSONDecoder().decode(CodexSnapshot.self, from: data)
                    // Quota has its own freshness; a task-owner disconnect cannot invalidate it.
                    let fuel = [snapshot.fuel, self.fuel].compactMap { $0 }.first { $0.valid(at: .now) }
                    if self.fuel != fuel { self.fuel = fuel }
                    let allowances = ((snapshot.allowances?.isEmpty == false ? snapshot.allowances : self.allowances) ?? [])
                        .filter { $0.valid(at: .now) }.sorted { $0.windowMinutes < $1.windowMinutes }
                    if self.allowances != allowances { self.allowances = allowances }
                    guard snapshot.connected, snapshot.fresh(at: .now) else { throw URLError(.cannotConnectToHost) }
                    self.fishQueue.update(snapshot, at: .now)
                    if self.fishQueueWaitingSince != self.fishQueue.waitingSince {
                        self.fishQueueWaitingSince = self.fishQueue.waitingSince
                    }
                    self.lastSuccess = .now
                    self.replyToken = snapshot.replyToken
                    let tasks = snapshot.tasks.filter { UUID(uuidString: $0.id) != nil && ["running", "waiting"].contains($0.state) }
                    let stable = self.stability.update(tasks, at: .now)
                    let finished = Self.didFinishWork(previous: self.tasks, current: stable,
                                                      confirmedIdle: snapshot.idleTaskIds ?? [], continuousConnection: self.connected)
                    self.reconcileRequests(stable)
                    if self.tasks != stable {
                        self.tasks = stable
                        Self.log.info("Task state updated: active=\(stable.filter(\.working).count, privacy: .public), waiting=\(stable.filter(\.waiting).count, privacy: .public)")
                    }
                    if finished && self.enabled && self.preview == nil {
                        self.completionSequence += 1
                        Self.log.info("Completion accepted: sequence=\(self.completionSequence, privacy: .public)")
                    }
                    if !self.connected {
                        self.connected = true
                        Self.log.info("Task bridge connected")
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    if self.connected {
                        self.connected = false
                        Self.log.info("Task bridge unavailable")
                    }
                    if self.fuel?.valid(at: .now) == false { self.fuel = nil }
                    let validAllowances = self.allowances.filter { $0.valid(at: .now) }
                    if self.allowances != validAllowances { self.allowances = validAllowances }
                    // Retain the presentation for short transport failures; never indefinitely.
                    if Date.now.timeIntervalSince(self.lastSuccess) >= 5 {
                        if !self.tasks.isEmpty { self.tasks = [] }
                        self.stability.reset()
                    }
                }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }
    func demonstrate(_ state: String?) {
        guard !energySavingActive else { return }
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
        guard presentationEnabled, preview == nil, connected, CodexQuestion.validAnswer(answer),
              let question = task.question, question.canReply,
              pending.contains(where: { $0.identity == task.identity }),
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
                // One bounded acknowledgement wait, no extra polling or automatic resend.
                try await Task.sleep(for: .seconds(12))
                if submitting.contains(task.identity) {
                    replyErrors[task.identity] = "回答已发送，尚未收到状态确认。请在 Codex 中查看，避免重复提交。"
                }
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
    private var closingDuration: Double {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.15 : CodexDissolve.duration
    }
    private func releaseResolvedPanelIfHidden() {
        guard Self.shouldDismissRequests(enabled: enabled, preview: preview, connected: connected, pendingCount: pending.count),
              let panel = window, !panel.isVisible, !genie.isAnimating else { return }
        // Keep warm reopening while reminders remain; release the rendered tree when the queue is done.
        panel.initialFirstResponder = nil
        panel.contentView = nil
        panel.close()
        window = nil
    }
    private func dismissResolvedRequests() {
        guard !energySavingActive else { hideRequestsImmediately(); return }
        let resolved = Self.shouldDismissRequests(enabled: enabled, preview: preview, connected: connected, pendingCount: pending.count)
        if resolved { releaseResolvedPanelIfHidden() }
        if usesGenie {
            if resolved {
                guard window?.isVisible == true, windowDissolve == 0 else { return }
                closeRequests()
                automaticCordDismiss = window?.isVisible == true
            } else if automaticCordDismiss && window?.isVisible == true && waiting && !suspended {
                automaticCordDismiss = false
                showRequests(anchor: cardSource)
            }
            return
        }
        guard resolved else {
            if dismissTask != nil {
                dismissTask?.cancel(); dismissTask = nil
                withAnimation(.easeOut(duration: closingDuration)) { windowDissolve = 0; windowReveal = 0 }
                panelReady = true
                cardPresented = true
            }
            return
        }
        guard window?.isVisible == true, dismissTask == nil else { return }
        panelTask?.cancel(); panelTask = nil
        panelReady = false
        cardPresented = false
        withAnimation(.easeInOut(duration: closingDuration)) { windowDissolve = 1 }
        dismissTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(closingDuration + 0.03))
                try Task.checkCancellation()
                window?.orderOut(nil)
                releaseResolvedPanelIfHidden()
                panelReady = false
                dismissTask = nil
            } catch { }
        }
    }

    private func hideRequestsImmediately() {
        panelTask?.cancel(); panelTask = nil
        dismissTask?.cancel(); dismissTask = nil
        genie.cancel()
        cardAnimating = false; cardPresented = false; panelReady = false
        automaticCordDismiss = false
        windowDissolve = 1; windowReveal = 1
        editingRequestID = nil
        window?.orderOut(nil)
        window?.initialFirstResponder = nil
        window?.contentView = nil
        window?.close()
        window = nil
    }

    func openRequestsFromKeyboard() {
        guard waiting, !suspended, !CodexShortcuts.shared.isRecording else { return }
        if let window, window.isVisible, windowDissolve == 0 {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        guard let anchor = reminderAnchor() else { return }
        showRequests(anchor: reminderStyle == .pullCord ? CodexPullCordButton.topAnchor(view: anchor)
                     : CodexDropButton.bottomAnchor(view: anchor, count: preview == nil ? pending.count : previewCount))
    }

    private func reminderAnchor() -> NSView? {
        let identifier = reminderStyle == .pullCord ? "codex-cord-anchor" : "codex-drop-anchor"
        func findAnchor(_ view: NSView) -> NSView? {
            if view.identifier?.rawValue == identifier, !view.isHiddenOrHasHiddenAncestor { return view }
            return view.subviews.lazy.compactMap { findAnchor($0) }.first
        }
        let candidates = NSApp.windows.filter { $0.isVisible }.compactMap { $0.contentView.flatMap(findAnchor) }
        return candidates.first { $0.window?.screen?.frame.contains(NSEvent.mouseLocation) == true } ?? candidates.first
    }
    private func pointerOverReminder() -> Bool {
        guard waiting, let anchor = reminderAnchor(), let owner = anchor.window else { return false }
        return owner.convertToScreen(anchor.convert(anchor.bounds, to: nil)).contains(NSEvent.mouseLocation)
    }

    func setAnswerText(_ text: String, for task: CodexTask) {
        var draft = answerDrafts[task.identity] ?? CodexAnswerDraft()
        draft.text = text
        if let index = draft.selection, task.question?.options.indices.contains(index) != true
            || task.question?.options[index] != text { draft.selection = nil }
        answerDrafts[task.identity] = draft
    }
    func beginAnswerEditing(_ task: CodexTask) {
        guard task.question?.canReply == true, !submitting.contains(task.identity) else { return }
        keyboardRequestID = task.identity
        editingRequestID = task.identity
    }
    func endAnswerEditing() {
        editingRequestID = nil
        window?.makeFirstResponder(window?.contentView)
    }
    func selectOption(_ index: Int, for task: CodexTask, toggle: Bool = true) {
        guard let question = task.question, question.options.indices.contains(index) else { return }
        keyboardRequestID = task.identity
        var draft = answerDrafts[task.identity] ?? CodexAnswerDraft()
        let custom = draft.select(index, options: question.options, toggle: toggle)
        answerDrafts[task.identity] = draft
        if custom { beginAnswerEditing(task) } else { endAnswerEditing() }
    }
    func sendAnswer(for task: CodexTask) {
        let answer = (answerDrafts[task.identity]?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !submitting.contains(task.identity), task.question?.canReply == true,
              CodexQuestion.validAnswer(answer), connected || preview != nil else { return }
        if preview != nil { answerDrafts[task.identity] = nil; removePreviewRequest() }
        else { submit(answer, for: task) }
    }
    @discardableResult
    func handleShortcut(_ action: CodexShortcutAction) -> Bool {
        guard window?.isKeyWindow == true, windowDissolve == 0 else { return false }
        if action == .close { closeRequests(); return true }
        guard panelReady, waiting else { return true }
        if action == .ignoreAll { clearRequests(); return true }
        guard let current = keyboardRequest else { return true }
        switch action {
        case .ignoreCurrent:
            if preview != nil { removePreviewRequest() } else { removeRequest(current) }
        case .nextRequest, .previousRequest:
            let rows = displayedRequests
            let index = rows.firstIndex { $0.identity == current.identity } ?? 0
            endAnswerEditing()
            keyboardRequestID = rows[(index + (action == .nextRequest ? 1 : rows.count - 1)) % rows.count].identity
        default:
            guard let question = current.question, question.canReply, !submitting.contains(current.identity), connected || preview != nil else { return true }
            let draft = answerDrafts[current.identity] ?? CodexAnswerDraft()
            switch action {
            case .confirm:
                switch draft.confirmation(editing: editingRequestID == current.identity) {
                case .edit: beginAnswerEditing(current)
                case .cancelEditing: endAnswerEditing()
                case .submit: sendAnswer(for: current)
                case .none: break
                }
            case .nextOption, .previousOption:
                guard !question.options.isEmpty else { return true }
                let count = question.options.count
                let index = draft.selection.map { ($0 + (action == .nextOption ? 1 : count - 1)) % count }
                    ?? (action == .nextOption ? 0 : count - 1)
                selectOption(index, for: current, toggle: false)
            default:
                if let index = action.optionIndex { selectOption(index, for: current) }
            }
        }
        return true
    }
    func closeRequests() {
        guard window?.isVisible == true, windowDissolve == 0 else { return }
        panelReady = false
        cardPresented = false
        automaticCordDismiss = false
        dismissTask?.cancel(); dismissTask = nil
        panelTask?.cancel(); panelTask = nil
        if usesGenie {
            windowDissolve = 1
            if window?.alphaValue == 0 && !genie.isAnimating {
                window?.orderOut(nil)
                window?.alphaValue = 1
                releaseResolvedPanelIfHidden()
                return
            }
            animateCord(showing: false)
            return
        }
        withAnimation(.easeInOut(duration: closingDuration)) { windowDissolve = 1 }
        panelTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(closingDuration + 0.03))
                try Task.checkCancellation()
                window?.orderOut(nil)
                releaseResolvedPanelIfHidden()
                panelTask = nil
            } catch { }
        }
    }

    func showRequests(anchor: CGPoint) {
        guard presentationEnabled, !suspended, waiting else { return }
        navigationError = nil
        endAnswerEditing()
        keyboardRequestID = displayedRequests.first?.identity
        keyboardOpenSequence += 1
        if window?.isVisible == true && presentedStyle != reminderStyle {
            panelTask?.cancel(); panelTask = nil
            dismissTask?.cancel(); dismissTask = nil
            genie.cancel()
            cardAnimating = false
            window?.orderOut(nil)
        }
        if window?.isVisible == true {
            if windowDissolve == 0 { closeRequests(); return }
            panelTask?.cancel(); panelTask = nil
            dismissTask?.cancel(); dismissTask = nil
            panelReady = true
            cardPresented = true
            automaticCordDismiss = false
            if usesGenie {
                windowDissolve = 0
                animateCord(showing: true)
                NSApp.activate(ignoringOtherApps: true)
                window?.makeKeyAndOrderFront(nil)
                return
            }
            withAnimation(.easeOut(duration: closingDuration)) { windowDissolve = 0; windowReveal = 0 }
            return
        }
        panelTask?.cancel(); panelTask = nil
        dismissTask?.cancel(); dismissTask = nil
        genie.cancel()
        cardAnimating = false
        automaticCordDismiss = false
        presentedStyle = reminderStyle
        usesGenie = presentedStyle == .pullCord && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        cardSource = anchor
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) { windowDissolve = 0; windowReveal = usesGenie ? 0 : 1 }
        panelTask?.cancel(); panelTask = nil
        panelReady = false
        cardPresented = true
        if window == nil {
            let panel = CodexRequestPanel(contentRect: NSRect(x: 0, y: 0, width: 516, height: 536),
                                          styleMask: [.borderless], backing: .buffered, defer: false)
            panel.onCancel = { [weak self] in self?.closeRequests() }
            panel.onShortcut = { [weak self] action in self?.handleShortcut(action) ?? false }
            panel.isEditingAnswer = { [weak self] in self?.editingRequestID != nil }
            panel.keepOpenOnResign = { [weak self] in self?.pointerOverReminder() == true }
            panel.title = "Codex · 需要你处理"
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            // SwiftUI owns the reveal; AppKit must not animate window ordering over it.
            panel.animationBehavior = .none
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = CodexRequestsHost(rootView: CodexRequests(activity: self))
            panel.initialFirstResponder = panel.contentView
            window = panel
        }
        guard let window else { return }
        (window as? CodexRequestPanel)?.spansMenuBar = presentedStyle == .pullCord
        window.setContentSize(NSSize(width: 516, height: 536 + panelTopInset))
        window.alphaValue = usesGenie ? 0 : 1
        let screen = NSScreen.screens.first { NSMouseInRect(anchor, $0.frame, false) } ?? NSScreen.main
        if let screen {
            // Keep the expansion attached to the clicked reminder's screen-space anchor.
            let bounds = screen.visibleFrame
            let x = max(bounds.minX, min(bounds.maxX - window.frame.width, anchor.x - window.frame.width / 2))
            let gap: CGFloat = presentedStyle == .pullCord ? 80 : CodexCardReveal.dropGap
            let y = max(bounds.minY, min(screen.frame.maxY - window.frame.height, anchor.y + CodexCardReveal.panelInset + panelTopInset - gap - window.frame.height))
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(window.contentView)
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        panelTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(16))
                try Task.checkCancellation()
                let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.15 : CodexCardReveal.duration
                // SwiftUI can mount its field editor after makeKeyAndOrderFront.
                if editingRequestID == nil { window.makeFirstResponder(window.contentView) }
                panelReady = true
                if usesGenie {
                    animateCord(showing: true)
                    panelTask = nil
                    return
                }
                withAnimation(.linear(duration: duration)) { windowReveal = 0 }
                try await Task.sleep(for: .seconds(duration + 0.03))
                try Task.checkCancellation()
                panelReady = true
                panelTask = nil
            } catch { }
        }
    }

    private func animateCord(showing: Bool) {
        guard let window, let host = window.contentView else { return }
        let point = host.convert(window.convertPoint(fromScreen: cardSource), from: nil)
        let source = CGPoint(x: point.x, y: host.isFlipped ? point.y : host.bounds.height - point.y)
        let rect = CGRect(x: 0, y: panelTopInset, width: host.bounds.width, height: host.bounds.height - panelTopInset)
        let finish = { [weak self] in
            guard let self, self.windowDissolve == (showing ? 0 : 1) else { return }
            self.cardAnimating = false
            self.automaticCordDismiss = false
            if !showing {
                self.window?.orderOut(nil)
                self.releaseResolvedPanelIfHidden()
            }
        }
        cardAnimating = genie.animate(host: host, snapshotRect: rect, source: source, showing: showing, completion: finish)
        window.alphaValue = 1
        if !cardAnimating { finish() }
    }
}

// Keep initial keyboard focus on the card instead of AppKit's first editable field.
private final class CodexRequestsHost: NSHostingView<CodexRequests> {
    override var acceptsFirstResponder: Bool { true }
}

private class CodexRequestPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    var spansMenuBar = false
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        // The transparent transition area must reach the notch above the menu-bar safe area.
        spansMenuBar ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }
    var onCancel: (() -> Void)?
    var onShortcut: ((CodexShortcutAction) -> Bool)?
    var isEditingAnswer: () -> Bool = { false }
    var keepOpenOnResign: () -> Bool = { false }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, CodexKeyBinding(event: event).isNewline,
           isEditingAnswer(), let editor = firstResponder as? NSTextView,
           editor.isEditable, !editor.hasMarkedText() {
            // A multiline field editor otherwise treats Return as an editing command.
            if !event.isARepeat { editor.insertText("\n", replacementRange: editor.selectedRange()) }
            return
        }
        if event.type == .keyDown, let action = CodexShortcuts.shared.action(for: event) {
            let editor = firstResponder as? NSTextView
            // Let the text system commit marked text and keep number/navigation keys as typing.
            if editor?.hasMarkedText() != true,
               editor == nil || !isEditingAnswer() || [.confirm, .close, .ignoreCurrent, .ignoreAll, .nextRequest, .previousRequest].contains(action) {
                if event.isARepeat { return }
                if onShortcut?(action) == true { return }
            }
        }
        super.sendEvent(event)
    }
    override func cancelOperation(_ sender: Any?) {
        // Configured key events are handled in sendEvent; unbound Escape must stay unbound.
        if NSApp.currentEvent?.type != .keyDown { onCancel?() }
    }
    override func resignKey() {
        super.resignKey()
        if !keepOpenOnResign() { onCancel?() }
    }
}

// Keep AppKit's overlay fading and drag behavior; only use the compact scroller size.
struct CodexScrollAppearance: NSViewRepresentable {
    final class Probe: NSView {
        func configure() {
            guard let scroll = enclosingScrollView else { return }
            scroll.scrollerStyle = .overlay
            scroll.autohidesScrollers = true
            scroll.verticalScroller?.controlSize = .small
        }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); configure() }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); configure() }
    }
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ nsView: Probe, context: Context) { nsView.configure() }
}

private struct CodexOptionButtonStyle: ButtonStyle {
    var selected = false
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduced
    @Environment(\.colorSchemeContrast) private var contrast
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(LinearGradient(colors: [Color.white.opacity(configuration.isPressed ? 0.05 : selected ? 0.18 : hovered ? 0.11 : 0.065),
                                                  Color.white.opacity(selected ? 0.07 : 0.025)],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(LinearGradient(colors: [
                                selected ? Color(red: 0.95, green: 0.83, blue: 0.62).opacity(0.75) : .white.opacity(contrast == .increased ? 0.5 : hovered ? 0.25 : 0.18),
                                selected ? Color(red: 0.82, green: 0.69, blue: 0.46).opacity(0.38) : .white.opacity(contrast == .increased ? 0.3 : 0.045)
                            ], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: contrast == .increased ? 1 : 0.7)
                    }
                    .shadow(color: .black.opacity(configuration.isPressed ? 0.05 : 0.16), radius: 1.5, y: 1)
            }
            .scaleEffect(configuration.isPressed && !reduced ? 0.985 : 1)
            .opacity(enabled ? 1 : 0.5)
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.12), value: hovered)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct CodexRequests: View {
    @ObservedObject var activity: CodexActivity
    @Environment(\.accessibilityReduceMotion) private var reduced
    @Environment(\.colorSchemeContrast) private var contrast
    @ObservedObject private var shortcuts = CodexShortcuts.shared
    @State private var rows: [CodexTask] = []
    @State private var dissolving = Set<String>()
    private let cardShape = RoundedRectangle(cornerRadius: 24, style: .continuous)
    var body: some View {
        let usesGenie = activity.usesGenie
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) {
                Image(systemName: "lightbulb.fill")
                    .font(.system(size: 15, weight: .medium)).foregroundStyle(Color(red: 0.96, green: 0.83, blue: 0.59))
                    .frame(width: 30, height: 30)
                    .background {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(LinearGradient(colors: [.white.opacity(0.13), .white.opacity(0.035)], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .overlay {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.6)
                            }
                            .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                    }
                VStack(alignment: .leading, spacing: 3) {
                    Text("需要你处理").font(.system(size: 15, weight: .semibold))
                    Text(activity.preview != nil ? "交互预览" : "Codex · \(activity.pending.count) 个待处理请求")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Button(action: activity.clearRequests) {
                    Label("忽略", systemImage: "eye.slash")
                        .font(.system(size: 11, weight: .medium)).padding(.horizontal, 9).padding(.vertical, 7)
                }.buttonStyle(CodexOptionButtonStyle())
                    .help("隐藏当前卡片和提醒，不会处理 Codex 请求")
                    .accessibilityLabel("忽略当前提醒，隐藏交互组件")
                Button(action: activity.closeRequests) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).frame(width: 27, height: 27)
                }.buttonStyle(CodexOptionButtonStyle()).help("收起（\(shortcuts.label(for: .close))）").accessibilityLabel("收起")
            }
            ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    if rows.isEmpty {
                        Label(activity.connected ? "当前请求已处理" : "连接暂时中断，请在 Codex 中查看", systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary).padding(.vertical, 28)
                    } else {
                        ForEach(rows, id: \.identity) { task in
                            CodexQuestionRow(activity: activity, task: task)
                                .id(task.identity)
                                .opacity(dissolving.contains(task.identity) ? 0 : 1)
                                .offset(y: reduced || !dissolving.contains(task.identity) ? 0 : -4)
                                .allowsHitTesting(!dissolving.contains(task.identity))
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .padding(2).padding(.trailing, 6)
                    .background(CodexScrollAppearance())
            }
            .onChange(of: activity.keyboardRequest?.identity) { _, id in
                if let id { reader.scrollTo(id, anchor: .top) }
            }
            .onChange(of: activity.keyboardOpenSequence) { _, _ in
                if let id = activity.keyboardRequest?.identity { reader.scrollTo(id, anchor: .top) }
            }
            }
            if let error = activity.navigationError { Text(error).foregroundStyle(.orange).font(.caption) }
            HStack {
                Circle().fill(activity.connected || activity.preview != nil ? Color.green.opacity(0.75) : .orange).frame(width: 5, height: 5)
                Text(activity.preview != nil ? "预览不会发送回答" : activity.connected ? "选择后发送，也可以自行输入" : "等待重新连接")
                Spacer()
                Text(shortcuts.label(for: .close)).font(.system(size: 9, weight: .medium, design: .rounded))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(.white.opacity(0.1), lineWidth: 0.5) }
                    .accessibilityLabel("收起快捷键")
            }.font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .opacity(usesGenie || (activity.windowReveal == 0 && activity.windowDissolve == 0) ? 1 : 0)
        .animation(.easeOut(duration: reduced ? 0.15 : 0.2).delay(reduced ? 0 : 0.14), value: activity.windowReveal)
        .animation(.easeOut(duration: 0.15), value: activity.windowDissolve)
        .padding(22).frame(width: 420, height: 440)
        .background {
            cardShape.fill(.black)
                .overlay {
                    cardShape.inset(by: 0.9)
                        .strokeBorder(LinearGradient(stops: [
                            .init(color: .white.opacity(0.24), location: 0),
                            .init(color: .white.opacity(0.025), location: 0.35),
                            .init(color: .white.opacity(0.012), location: 0.65),
                            .init(color: .white.opacity(0.12), location: 1)
                        ], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 3.2)
                        .blur(radius: 1.1)
                }
                .overlay {
                    cardShape
                        .strokeBorder(LinearGradient(stops: [
                            .init(color: .white.opacity(contrast == .increased ? 0.80 : 0.50), location: 0),
                            .init(color: .white.opacity(contrast == .increased ? 0.45 : 0.06), location: 0.45),
                            .init(color: .white.opacity(contrast == .increased ? 0.60 : 0.23), location: 1)
                        ], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: contrast == .increased ? 1.2 : 0.7)
                }
        }
        .clipShape(cardShape)
        .modifier(CodexDissolve(progress: usesGenie ? 0 : activity.windowDissolve))
        .modifier(CodexCardReveal(progress: usesGenie ? 0 : activity.windowReveal))
        .compositingGroup()
        .shadow(color: .black.opacity(0.30), radius: 18, y: 10)
        .shadow(color: .black.opacity(0.26), radius: 3, y: 1)
        .allowsHitTesting(activity.panelReady && activity.windowDissolve == 0 && !activity.cardAnimating)
        .padding(CodexCardReveal.panelInset)
        .padding(.top, activity.panelTopInset)
        .preferredColorScheme(.dark)
        .task(id: activity.displayedRequests) {
            let incoming = activity.displayedRequests
            let ids = Set(incoming.map(\.identity))
            let oldIDs = Set(rows.map(\.identity))
            rows += incoming.filter { !oldIDs.contains($0.identity) }
            let removed = Set(rows.map(\.identity)).subtracting(ids)
            guard !removed.isEmpty else { rows = incoming; dissolving = []; return }
            withAnimation(.easeOut(duration: reduced ? 0.15 : 0.22)) { dissolving = removed }
            do {
                try await Task.sleep(for: .seconds(reduced ? 0.15 : 0.22))
                try Task.checkCancellation()
                withAnimation(reduced ? nil : .easeInOut(duration: 0.22)) { rows = incoming; dissolving = [] }
            } catch { }
        }
    }
}

private struct CodexQuestionRow: View {
    @ObservedObject var activity: CodexActivity
    let task: CodexTask
    @ObservedObject private var shortcuts = CodexShortcuts.shared
    @Environment(\.colorSchemeContrast) private var contrast
    private var response: CodexAnswerDraft { activity.answerDrafts[task.identity] ?? CodexAnswerDraft() }
    private var text: Binding<String> {
        Binding(get: { response.text }, set: { activity.setAnswerText($0, for: task) })
    }
    @FocusState private var editing: Bool
    private var sending: Bool { activity.submitting.contains(task.identity) }
    private var answer: String { response.text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private func send() { activity.sendAnswer(for: task) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(activity.preview != nil ? "演示数据 · 非真实对话" : CodexActivity.modelLabel(task.model, effort: task.reasoningEffort))
                    .font(.system(size: 10, weight: task.isFastMode ? .semibold : .medium))
                    .foregroundStyle(task.isFastMode ? Color(red: 1, green: 0.87, blue: 0.62) : .secondary)
                    .shadow(color: task.isFastMode ? Color(red: 1, green: 0.75, blue: 0.32).opacity(0.55) : .clear, radius: 4)
                if task.isFastMode && activity.preview == nil {
                    Label("快速", systemImage: "bolt.fill")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color(red: 1, green: 0.87, blue: 0.62))
                        .accessibilityLabel("当前对话使用快速模式")
                }
                Spacer()
                Button {
                    if activity.preview != nil { activity.removePreviewRequest() } else { activity.removeRequest(task) }
                } label: { Image(systemName: "eye.slash").frame(width: 22, height: 20) }
                    .buttonStyle(.plain).help("隐藏这条提醒，不会处理 Codex 请求").accessibilityLabel("隐藏这条提醒")
            }.foregroundStyle(.secondary)
            Text(task.question?.title ?? "Codex 有一个请求需要你确认")
                .font(.system(size: 15, weight: .medium)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            if let question = task.question, question.canReply {
                VStack(spacing: 7) {
                    ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                        Button {
                            activity.selectOption(index, for: task)
                        } label: {
                            HStack(alignment: .top, spacing: 9) {
                                Image(systemName: response.selection == index ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(response.selection == index ? Color(red: 0.92, green: 0.81, blue: 0.61) : .white.opacity(0.3)).padding(.top, 1)
                                Text(option).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                                if let key = CodexShortcutAction.allCases.first(where: { $0.optionIndex == index }) {
                                    Text(shortcuts.label(for: key)).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
                                        .padding(.horizontal, 4).frame(minWidth: 17, minHeight: 17)
                                        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 4))
                                }
                            }.font(.system(size: 12)).padding(.horizontal, 11).padding(.vertical, 10)
                                .frame(maxWidth: .infinity, alignment: .leading).contentShape(RoundedRectangle(cornerRadius: 11))
                        }.buttonStyle(CodexOptionButtonStyle(selected: response.selection == index))
                    }
                    TextField("自行输入回答…", text: text, axis: .vertical)
                        .font(.system(size: 12)).lineLimit(1...4).textFieldStyle(.plain).focused($editing)
                        .padding(11).background {
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(LinearGradient(colors: [.black.opacity(0.23), .black.opacity(0.13)], startPoint: .top, endPoint: .bottom))
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .strokeBorder(editing ? Color(red: 0.95, green: 0.83, blue: 0.62).opacity(0.65) : .white.opacity(contrast == .increased ? 0.45 : 0.13), lineWidth: editing || contrast == .increased ? 1 : 0.7)
                                .allowsHitTesting(false)
                        }
                        .simultaneousGesture(TapGesture().onEnded {
                            activity.beginAnswerEditing(task)
                            editing = true
                        })
                    HStack {
                        if answer.unicodeScalars.count > 4000 { Text("最多 4000 字").foregroundStyle(.orange).font(.caption) }
                        Text(activity.editingRequestID == task.identity && answer.isEmpty
                             ? "\(shortcuts.label(for: .confirm)) 退出输入 · ⇧↩ 换行"
                             : "\(shortcuts.label(for: .confirm)) 输入 / 发送 · ⇧↩ 换行")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                        Spacer()
                        Button(action: send) {
                            Label(sending ? "已发送" : "发送回答", systemImage: sending ? "checkmark" : "arrow.up")
                                .font(.system(size: 12, weight: .medium)).padding(.horizontal, 13).padding(.vertical, 8)
                        }.buttonStyle(CodexOptionButtonStyle(selected: true))
                            .disabled(!CodexQuestion.validAnswer(answer))
                    }
                }.disabled(sending || (!activity.connected && activity.preview == nil))
                if sending { Label("等待 Codex 确认", systemImage: "clock").font(.caption).foregroundStyle(.secondary) }
                if let error = activity.replyErrors[task.identity] { Text(error).foregroundStyle(.orange).font(.caption) }
            } else {
                Text("在 Codex 中查看完整内容并处理。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if activity.preview == nil {
                Button { activity.open(task) } label: {
                    Label("在 Codex 中打开", systemImage: "arrow.up.right").font(.system(size: 11, weight: .medium))
                }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 1).padding(.vertical, 4)
        .overlay(alignment: .leading) {
            if activity.keyboardRequest?.identity == task.identity {
                Capsule().fill(Color(red: 0.92, green: 0.81, blue: 0.61).opacity(0.65))
                    .frame(width: 2).padding(.leading, -6).allowsHitTesting(false)
            }
        }
        .onChange(of: activity.editingRequestID) { _, id in
            editing = id == task.identity
        }
        .onChange(of: editing) { _, value in
            // Tab navigation is intentional input; opening/restoring a field is not.
            if value, NSApp.currentEvent?.type == .keyDown, NSApp.currentEvent?.keyCode == 48 {
                activity.beginAnswerEditing(task)
            }
        }
        .onAppear { editing = activity.editingRequestID == task.identity }

    }
}

struct CodexActivitySettings: View {
    @ObservedObject private var activity = CodexActivity.shared
    var body: some View {
        Toggle("Codex 火箭与交互提醒", isOn: $activity.enabled)
        Text(activity.status).font(.caption).foregroundStyle(.secondary)
        if activity.enabled {
            Picker("提醒样式", selection: $activity.reminderStyle) {
                ForEach(CodexReminderStyle.allCases) { style in Text(style.title).tag(style) }
            }
            Text(activity.reminderStyle == .pullCord
                 ? "有待处理请求时垂下拉绳。轻点拉绳展开卡片，再点一次收起。"
                 : "有待处理请求时显示水滴。点击水滴打开交互卡片。")
                .font(.caption).foregroundStyle(.secondary)
            if activity.reminderStyle == .pullCord {
                VStack(alignment: .leading, spacing: 10) {
                    Text("拉绳外观")
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                        ForEach([CodexPullCordStyle.fish] + CodexPullCordStyle.allCases.filter { $0 != .fish }) { style in
                            Button { activity.pullCordStyle = style } label: {
                                VStack(spacing: 4) {
                                    CodexPullCordArtwork(stretch: 0, isOpen: true, style: style, count: 1)
                                        .accessibilityHidden(true)
                                    Text(style.title).font(.caption)
                                }
                                .frame(maxWidth: .infinity).padding(.bottom, 10)
                                .foregroundStyle(.white.opacity(0.9))
                                .background(Color(white: 0.09), in: RoundedRectangle(cornerRadius: 12))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 12)
                                        .strokeBorder(activity.pullCordStyle == style ? Color.accentColor : .white.opacity(0.12),
                                                      lineWidth: activity.pullCordStyle == style ? 2 : 0.7)
                                }
                                .contentShape(RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(style.title)
                            .accessibilityAddTraits(activity.pullCordStyle == style ? [.isSelected] : [])
                        }
                    }
                    Text("等待时柔和呼吸，打开卡片后保持常亮。")
                        .font(.caption).foregroundStyle(.secondary)
                    if activity.pullCordStyle == .fish {
                        Text("上鱼了：银白小鱼轻轻甩尾，暖金波纹与轻柔鳃动交替。未解决事项满 2 / 10 / 20 分钟后，依次渐渐安静、等待过久、只剩鱼骨。解决任一队列事项后恢复活力；查看卡片或忽略提醒不会重置。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Text("尾焰反映所选思考强度，不表示真实 token 速度；高及以上显示速度参照线。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
