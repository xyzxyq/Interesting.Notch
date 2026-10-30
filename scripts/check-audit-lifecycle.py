#!/usr/bin/env python3
"""Exercise production queue, Combine, calendar and temporary-file logic without hardware or user data."""
from pathlib import Path
import os
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
def method(text, signature):
    start = text.index(signature)
    body = text.index('{', start)
    end, depth = body + 1, 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end].replace('private ', '')
webcam = (root/'boringNotch/managers/WebcamManager.swift').read_text()
calendar = (root/'boringNotch/managers/CalendarManager.swift').read_text()
provider = (root/'boringNotch/Providers/CalendarServiceProviding.swift').read_text()
model = (root/'boringNotch/models/BoringViewModel.swift').read_text()
shelf = (root/'boringNotch/components/Shelf/ViewModels/ShelfStateViewModel.swift').read_text()
xpc = (root/'boringNotch/XPCHelperClient/XPCHelperClient.swift').read_text()
subscription = model[model.index('        Publishers.CombineLatest3($dropZoneTargeting'):model.index('        setupDetectorObserver()')]
source = r'''
import AppKit
import Combine
final class FakeCapture {
    var isRunning = false
    static var starts = 0
    func startRunning() { isRunning = true; Self.starts += 1 }
}
final class CameraCheck {
    let sessionQueue = DispatchQueue(label: "camera-check")
    var wantsSession = false
    var captureSession: FakeCapture?
    var isSessionRunning = false
    var setups = 0
    var completions: [(Bool) -> Void] = []
    func setupCaptureSession(completion: @escaping (Bool) -> Void) {
        setups += 1; captureSession = FakeCapture(); completions.append(completion)
    }
    func cleanupExistingSession() { captureSession = nil }
CAMERA_METHODS
}
final class ModelCheck {
    @Published var dropZoneTargeting = false
    @Published var dragDetectorTargeting = false
    @Published var generalDropTargeting = false
    @Published var anyDropZoneTargeting = false
    var cancellables = Set<AnyCancellable>()
    init() {
SUBSCRIPTION
    }
}
struct CalendarModel { let id: String; var isReminder = false }
struct EventModel {
    let id: String
    var start: Date { .distantPast }
    init(id: String) { self.id = id }
    init?(from value: String) { id = value }
}
@MainActor final class CalendarService {
    var requests: [CheckedContinuation<[EventModel], Never>] = []
    func calendars() async -> [CalendarModel] { [CalendarModel(id: "event")] }
    func events(from start: Date, to end: Date, calendars: [String]) async -> [EventModel] {
        await withCheckedContinuation { requests.append($0) }
    }
}
@MainActor final class CalendarCheck {
    let calendarService = CalendarService()
    var eventGeneration = 0
    var currentWeekStartDate = Date()
    var selectedCalendars: [CalendarModel] = []
    var allCalendars: [CalendarModel] = []
    var eventCalendars: [CalendarModel] = []
    var reminderLists: [CalendarModel] = []
    var events: [EventModel] = []
    func updateSelectedCalendars() { selectedCalendars = allCalendars }
CALENDAR_METHODS
}
enum Entity { case event, reminder }
struct StoredCalendar: Equatable { let calendarIdentifier: String }
final class StoreCheck {
    var queries = 0
    func calendars(for kind: Entity) -> [StoredCalendar] { [.init(calendarIdentifier: kind == .event ? "event" : "reminder")] }
    func predicateForEvents(withStart: Date, end: Date, calendars: [StoredCalendar]) -> [StoredCalendar] { queries += 1; return calendars }
    func events(matching: [StoredCalendar]) -> [String] { matching.map(\.calendarIdentifier) }
}
final class ProviderCheck {
    let store = StoreCheck()
    var reminders = 0
    func hasAccess(to: Entity) -> Bool { true }
    func calendars() async -> [CalendarModel] { [.init(id: "event"), .init(id: "reminder", isReminder: true)] }
    func fetchReminders(from: Date, to: Date, calendars: [StoredCalendar]) async -> [EventModel] { reminders += 1; return calendars.map { .init(id: $0.calendarIdentifier) } }
PROVIDER_METHOD
}
final class AuditConnection {
    var interruptionHandler: (() -> Void)?
    var invalidationHandler: (() -> Void)?
    init(serviceName: String) {}
    func resume() {}
}
protocol BoringNotchXPCHelperProtocol {}
final class RemoteXPCService<Service> {
    init(connection: AuditConnection, remoteInterface: Any.Type) {}
}
@MainActor final class XPCCheck {
    let serviceName = "fixture"
    var connection: AuditConnection?
    var remoteService: RemoteXPCService<BoringNotchXPCHelperProtocol>?
XPC_METHOD
}
enum ShelfKind: Equatable { case file(Data), text }
struct ShelfItem {
    let id = UUID()
    var kind: ShelfKind
    var isTemporary: Bool
}
@MainActor struct Bookmark {
    let data: Data
    static var requests: [CheckedContinuation<Bool, Never>] = []
    static var completed = 0
    func validate() async -> Bool {
        let value = await withCheckedContinuation { Self.requests.append($0) }
        Self.completed += 1
        return value
    }
}
@MainActor final class ShelfCheck {
    var items: [ShelfItem] = []
    func remove(_ item: ShelfItem) { items.removeAll { $0.id == item.id } }
SHELF_METHOD
}
@main struct Check {
    @MainActor static func settle(_ predicate: () -> Bool) async {
        for _ in 0..<1000 { if predicate() { return }; try? await Task.sleep(for: .milliseconds(1)) }
        fatalError("Fixture failed to settle")
    }
    static func unzip(_ url: URL, _ extra: [String]) throws -> Data {
        let proc = Process(), pipe = Pipe()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments = extra + [url.path]
        proc.standardOutput = pipe; proc.standardError = FileHandle.nullDevice
        try proc.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit(); assert(proc.terminationStatus == 0)
        return data
    }
    @MainActor static func main() async throws {
        var began = 0, interactionEnds = 0, ended = 0
        let sharing = SharingLifecycleDelegate(id: UUID(), onEnd: { ended += 1 }, onBegin: { began += 1 }, onFinish: { interactionEnds += 1 })
        sharing.markServiceBegan()
        try await Task.sleep(for: .milliseconds(2200))
        assert(began == 1 && interactionEnds == 1 && ended == 0, "UI timeout prematurely ended a file transfer")
        let service = NSSharingService(title: "Fixture", image: NSImage(), alternateImage: nil, handler: { fatalError("Do not transmit in tests") })
        sharing.sharingService(service, didShareItems: [])
        sharing.sharingService(service, didFailToShareItems: [], error: NSError(domain: "fixture", code: 1))
        assert(interactionEnds == 1 && ended == 1, "Sharing cleanup must happen exactly once after completion")
        var cancelled = 0
        let pickerDelegate = SharingLifecycleDelegate(id: UUID(), onEnd: { cancelled += 1 }, onBegin: {}, onFinish: {})
        pickerDelegate.markPickerBegan()
        pickerDelegate.sharingServicePicker(NSSharingServicePicker(items: []), didChoose: nil)
        assert(cancelled == 1)
        let xpc = XPCCheck()
        _ = xpc.ensureRemoteService()
        let oldConnection = xpc.connection!
        oldConnection.interruptionHandler?()
        await settle { xpc.connection == nil }
        _ = xpc.ensureRemoteService()
        let newConnection = xpc.connection!
        oldConnection.invalidationHandler?()
        try await Task.sleep(for: .milliseconds(20))
        assert(xpc.connection === newConnection && xpc.remoteService != nil, "Old XPC invalidation cleared a newer connection")
        newConnection.invalidationHandler?()
        await settle { xpc.connection == nil }
        let camera = CameraCheck()
        camera.startSession(); camera.stopSession(); camera.sessionQueue.sync {}
        camera.completions[0](true); camera.sessionQueue.sync {}
        assert(FakeCapture.starts == 0 && camera.captureSession == nil, "Delayed setup restarted a closed camera")
        camera.startSession(); camera.startSession(); camera.sessionQueue.sync {}
        assert(camera.setups == 2, "Repeated starts created duplicate sessions")
        camera.completions[1](true); camera.sessionQueue.sync {}
        assert(FakeCapture.starts == 1)
        camera.stopSession(); camera.sessionQueue.sync {}
        assert(!camera.wantsSession && camera.captureSession == nil)
        weak var released: ModelCheck?
        autoreleasepool {
            let model = ModelCheck(); released = model
            model.dragDetectorTargeting = true
            assert(model.anyDropZoneTargeting)
        }
        assert(released == nil, "Window model retains itself through its publisher")
        let calendar = CalendarCheck()
        let first = Task { await calendar.updateCurrentDate(Date(timeIntervalSince1970: 100000)) }
        await settle { calendar.calendarService.requests.count == 1 }
        let second = Task { await calendar.updateCurrentDate(Date(timeIntervalSince1970: 200000)) }
        await settle { calendar.calendarService.requests.count == 2 }
        calendar.calendarService.requests[1].resume(returning: [.init(id: "new")]); await second.value
        calendar.calendarService.requests[0].resume(returning: [.init(id: "old")]); await first.value
        assert(calendar.events.map(\.id) == ["new"], "Old date response overwrote current date")
        let refresh = Task { await calendar.reloadCalendarAndReminderLists() }
        await settle { calendar.calendarService.requests.count == 3 }
        calendar.calendarService.requests[2].resume(returning: [.init(id: "store-change")]); await refresh.value
        assert(calendar.events.map(\.id) == ["store-change"])
        let provider = ProviderCheck()
        _ = await provider.events(from: .distantPast, to: .distantFuture, calendars: ["event"])
        assert(provider.store.queries == 1 && provider.reminders == 0)
        _ = await provider.events(from: .distantPast, to: .distantFuture, calendars: ["reminder"])
        assert(provider.store.queries == 1 && provider.reminders == 1)
        let empty = await provider.events(from: .distantPast, to: .distantFuture, calendars: [])
        assert(empty.isEmpty && provider.store.queries == 1 && provider.reminders == 1)
        let shelf = ShelfCheck()
        let regular = ShelfItem(kind: .file(Data([0])), isTemporary: false)
        shelf.items = [ShelfItem(kind: .file(Data([1])), isTemporary: true), regular]
        shelf.cleanupInvalidItems()
        await settle { Bookmark.requests.count == 1 }
        let added = ShelfItem(kind: .text, isTemporary: false)
        shelf.items.append(added)
        Bookmark.requests[0].resume(returning: false)
        await settle { Bookmark.completed == 1 }
        assert(shelf.items.map(\.id) == [regular.id, added.id], "Cleanup lost an offline reference or a newly added item")
        shelf.items = [ShelfItem(kind: .file(Data([1])), isTemporary: true)]
        shelf.cleanupInvalidItems()
        await settle { Bookmark.requests.count == 2 }
        shelf.items[0].kind = .file(Data([2]))
        Bookmark.requests[1].resume(returning: false)
        await settle { Bookmark.completed == 2 }
        assert(shelf.items.count == 1, "Stale validation removed an updated bookmark")
        let manager = FileManager.default, storage = TemporaryFileStorageService.shared
        let fixture = manager.temporaryDirectory.appendingPathComponent("notch-audit-" + UUID().uuidString)
        try manager.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: fixture) }
        let external = fixture.appendingPathComponent("external.txt")
        try Data("keep".utf8).write(to: external)
        storage.removeTemporaryFileIfNeeded(at: external)
        assert(manager.fileExists(atPath: external.path), "Cleanup deleted an unowned temporary file")
        let safe = await storage.createTempFile(for: .data(Data("sample".utf8), suggestedName: "../../escape.txt"))!
        assert(safe.lastPathComponent == "escape.txt" && safe.path.contains("InterestingNotch-Shelf/"))
        storage.removeTemporaryFileIfNeeded(at: safe); assert(!manager.fileExists(atPath: safe.path))
        let link = URL(string: "https://example.com/?a=1&b=2")!
        let webloc = await storage.createTempFile(for: .url(link))!
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: webloc), format: nil) as! [String:String]
        assert(plist["URL"] == link.absoluteString); storage.removeTemporaryFileIfNeeded(at: webloc)
        let dash = fixture.appendingPathComponent("-source.txt")
        try Data("dash".utf8).write(to: dash)
        let dashZip = await storage.createZip(from: [dash])!
        let dashData = try unzip(dashZip, ["-p"]); assert(dashData == Data("dash".utf8)); storage.removeTemporaryFileIfNeeded(at: dashZip)
        let namedArchive = fixture.appendingPathComponent("Archive.zip")
        try Data("original archive".utf8).write(to: namedArchive)
        let result = await storage.createZip(from: [namedArchive, external])!
        let listing = String(decoding: try unzip(result, ["-Z", "-1"]), as: UTF8.self)
        assert(listing.contains("Archive.zip") && listing.contains("external.txt"))
        storage.removeTemporaryFileIfNeeded(at: result)
        let missing = fixture.appendingPathComponent("missing.txt")
        let partial = await storage.createZip(from: [external, missing])
        assert(partial == nil, "Partial archive was reported as success")
        let emptyZip = await storage.createZip(from: [])
        assert(emptyZip == nil)
        print("PASS: stale XPC callback isolation, sharing completion/cancellation vs UI timeout, camera late-start cancellation, window-model release, calendar stale results/selection/refresh, concurrent shelf cleanup, bounded temporary deletion and complete ZIP/webloc output")
    }
}
'''
source = source.replace('CAMERA_METHODS', '\n'.join(method(webcam, s) for s in ['func startSession()', 'private func startRunningCaptureSession()', 'func stopSession()', 'private func updateSessionState()']))
source = source.replace('SUBSCRIPTION', subscription)
source = source.replace('CALENDAR_METHODS', '\n'.join(method(calendar,s) for s in ['func updateCurrentDate(', 'private func updateEvents()', 'func reloadCalendarAndReminderLists()']))
source = source.replace('XPC_METHOD', method(xpc, '    private func ensureRemoteService()').replace('NSXPCConnection(', 'AuditConnection('))
source = source.replace('SHELF_METHOD', method(shelf, '    func cleanupInvalidItems()'))
source = source.replace('PROVIDER_METHOD', method(provider, '    func events(from start: Date, to end: Date, calendars ids:'))
with tempfile.TemporaryDirectory(prefix='notch-audit-compile-') as folder:
    folder = Path(folder); (folder/'Check.swift').write_text(source)
    env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer'); env.pop('SDKROOT', None)
    subprocess.run(['xcrun','swiftc','-swift-version','5',str(root/'boringNotch/components/Shelf/Services/TemporaryFileStorageService.swift'),str(root/'boringNotch/models/SharingStateManager.swift'),str(folder/'Check.swift'),'-o',str(folder/'check')],env=env,check=True)
    subprocess.run([str(folder/'check')],check=True)
