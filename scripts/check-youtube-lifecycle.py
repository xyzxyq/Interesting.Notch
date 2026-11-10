#!/usr/bin/env python3
"""Exercise production YouTube observer/socket lifecycle without a player or network."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
folder = root / 'boringNotch/MediaControllers/YouTube Music Controller'
controller = (folder / 'YouTubeMusicController.swift').read_text()
networking = (folder / 'YouTubeMusicNetworking.swift').read_text()

def method(source, signature):
    start = source.index(signature)
    cursor = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[cursor] == '{') - (source[cursor] == '}')
        cursor += 1
    return source[start:cursor].replace('private ', '')

socket = networking.split('actor YouTubeMusicWebSocketClient {', 1)[1].split('// MARK: - WebSocket URL Helper', 1)[0]
socket = ('actor YouTubeMusicWebSocketClient {' + socket).replace('URLSessionWebSocketTask', 'FixtureSocket').replace('URLSession', 'FixtureSession')
methods = '\n'.join(method(controller, signature) for signature in [
    'deinit {', 'private func setupAppStateObserver()', 'private func handleAppLaunched(',
    'private func handleAppTerminated(', 'private func stopPeriodicUpdates()',
    'private func initializeIfAppActive()', 'private func scheduleReconnect()'
]).replace('NSWorkspace', 'FixtureWorkspace').replace('NSRunningApplication', 'FixtureApplication')
source = r'''
import Foundation
final class FixtureSocket: @unchecked Sendable {
    enum Message { case data(Data), string(String) }
    enum CloseCode { case goingAway }
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Message, Error>?
    private var cancellations = 0
    var waiting: Bool { lock.withLock { continuation != nil } }
    var cancelCount: Int { lock.withLock { cancellations } }
    func resume() {}
    func cancel(with: CloseCode, reason: Data?) { lock.withLock { cancellations += 1 } }
    func receive() async throws -> Message {
        try await withCheckedThrowingContinuation { value in lock.withLock { continuation = value } }
    }
    func finish(_ result: Result<Message, Error>) {
        let value = lock.withLock { let value = continuation; continuation = nil; return value }
        precondition(value != nil)
        value!.resume(with: result)
    }
}
final class FixtureSession: @unchecked Sendable {
    static let shared = FixtureSession()
    private let lock = NSLock()
    private var values: [FixtureSocket] = []
    var sockets: [FixtureSocket] { lock.withLock { values } }
    func webSocketTask(with: URLRequest) -> FixtureSocket {
        let socket = FixtureSocket()
        lock.withLock { values.append(socket) }
        return socket
    }
}
SOCKET
struct FixtureApplication { let bundleIdentifier = "fixture.youtube" }
final class FixtureWorkspace: @unchecked Sendable {
    static let shared = FixtureWorkspace()
    static let didLaunchApplicationNotification = Notification.Name("fixture.launch")
    static let didTerminateApplicationNotification = Notification.Name("fixture.terminate")
    static let applicationUserInfoKey = "app"
    let notificationCenter = NotificationCenter()
}
actor Messages {
    var messages: [Data] = []
    var disconnects = 0
    func message(_ data: Data) { messages.append(data) }
    func disconnect() { disconnects += 1 }
    func state() -> (Int, Int) { (messages.count, disconnects) }
}
@MainActor final class ControllerCheck {
    let configuration = (bundleIdentifier: "fixture.youtube", reconnectDelay: 0.05...1.0)
    @MainActor final class Auth {
        var calls = 0, fails = false
        func authenticate() async throws -> String {
            calls += 1
            if fails { throw URLError(.cannotConnectToHost) }
            return "fixture"
        }
    }
    let authManager = Auth()
    var updateTimer: Timer?
    var appStateObserver: Task<Void, Never>?
    var reconnectTask: Task<Void, Never>?
    var reconnectDelay: TimeInterval = 1
    var artworkFetchTask: Task<Void, Never>?
    var webSocketClient: YouTubeMusicWebSocketClient?
    var launches: Int { authManager.calls }
    var resets = 0
    init() { setupAppStateObserver() }
    func isActive() -> Bool { true }
    func setupWebSocketIfPossible(token: String) async {}
    func startPeriodicUpdates() async {}
    func updatePlaybackInfo() async {}
    func resetPlaybackState() { resets += 1 }
    METHODS
}
@main struct Check {
    static func settle(_ predicate: () async -> Bool) async throws {
        for _ in 0..<1000 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        fatalError("Lifecycle fixture did not settle")
    }
    @MainActor static func main() async throws {
        let session = FixtureSession(), messages = Messages()
        let socket = YouTubeMusicWebSocketClient(onMessage: { await messages.message($0) },
            onDisconnect: { await messages.disconnect() }, session: session)
        let url = URL(string: "ws://127.0.0.1/fixture")!
        try await socket.connect(to: url, with: "fixture")
        let old = session.sockets[0]
        try await settle { old.waiting }
        try await socket.connect(to: url, with: "fixture")
        let current = session.sockets[1]
        try await settle { current.waiting }
        old.finish(.success(.string("stale")))
        try await Task.sleep(for: .milliseconds(20))
        let connected = await socket.isConnected
        let firstState = await messages.state()
        assert(connected && firstState == (0, 0), "Stale receive replaced current socket or published old metadata")
        current.finish(.success(.string("current")))
        try await settle { await messages.state().0 == 1 }
        try await settle { current.waiting }
        try await socket.connect(to: url, with: "fixture")
        let replacement = session.sockets[2]
        try await settle { replacement.waiting }
        current.finish(.failure(URLError(.networkConnectionLost)))
        try await Task.sleep(for: .milliseconds(20))
        let stillConnected = await socket.isConnected
        let staleFailureState = await messages.state()
        assert(stillConnected && staleFailureState == (1, 0), "Old socket failure cleared the replacement connection")
        replacement.finish(.failure(URLError(.networkConnectionLost)))
        try await settle { await messages.state().1 == 1 }
        let disconnected = await socket.isConnected
        assert(!disconnected, "Real disconnect must clear socket and notify fallback")
        try await socket.connect(to: url, with: "fixture")
        let intentional = session.sockets[3]
        try await settle { intentional.waiting }
        await socket.disconnect()
        intentional.finish(.failure(URLError(.cancelled)))
        try await Task.sleep(for: .milliseconds(20))
        let finalState = await messages.state()
        assert(finalState == (1, 1), "Intentional disconnect must not schedule a reconnect")

        var controller: ControllerCheck? = ControllerCheck()
        // Allow both notification sequences to install their observers.
        try await Task.sleep(for: .milliseconds(30))
        let center = FixtureWorkspace.shared.notificationCenter
        let info: [AnyHashable: Any] = [FixtureWorkspace.applicationUserInfoKey: FixtureApplication()]
        await controller!.scheduleReconnect()
        let pendingReconnect = controller!.reconnectTask!
        center.post(name: FixtureWorkspace.didTerminateApplicationNotification, object: nil, userInfo: info)
        try await settle { await MainActor.run { controller!.resets == 1 } }
        try await settle { pendingReconnect.isCancelled }
        assert(controller!.appStateObserver?.isCancelled == false, "Player quit must preserve the launch observer")
        center.post(name: FixtureWorkspace.didLaunchApplicationNotification, object: nil, userInfo: info)
        try await settle { await MainActor.run { controller!.launches == 1 } }
        let observer = controller!.appStateObserver!
        let artwork = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        let timer = Timer(timeInterval: 60, repeats: true) { _ in }
        RunLoop.main.add(timer, forMode: .common)
        controller!.artworkFetchTask = artwork; controller!.updateTimer = timer
        try await socket.connect(to: url, with: "fixture")
        let closing = session.sockets[4]
        try await settle { closing.waiting }
        controller!.webSocketClient = socket
        weak var released = controller
        controller = nil
        assert(released == nil, "Controller is retained by its application observer")
        assert(observer.isCancelled && artwork.isCancelled && !timer.isValid, "Controller teardown left background work alive")
        try await settle { closing.cancelCount == 1 }
        closing.finish(.failure(URLError(.cancelled)))
        var retrying: ControllerCheck? = ControllerCheck()
        retrying!.authManager.fails = true
        await retrying!.initializeIfAppActive()
        assert(retrying!.authManager.calls == 1 && retrying!.reconnectTask != nil,
               "Failed API initialization must return after scheduling one retry")
        let retry = retrying!.reconnectTask!
        weak var releasedRetry = retrying
        retrying = nil
        assert(releasedRetry == nil && retry.isCancelled, "Unavailable API retained the old controller through retries")
        print("PASS: YouTube quit/reopen, controller teardown, weak/cancellable API retry, stale socket data, reconnect ownership and intentional disconnect")
    }
}
'''.replace('SOCKET', socket).replace('METHODS', methods)
with tempfile.TemporaryDirectory(prefix='notch-youtube-lifecycle-') as tmp:
    tmp = Path(tmp)
    (tmp / 'Check.swift').write_text(source)
    env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
    env.pop('SDKROOT', None)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', str(tmp / 'Check.swift'), '-o', str(tmp / 'check')], env=env, check=True)
    subprocess.run([str(tmp / 'check')], check=True)
