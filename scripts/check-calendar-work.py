#!/usr/bin/env python3
"""Check production calendar query counts, same-day reuse and stale async replies."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
service = (root / 'boringNotch/Providers/CalendarServiceProviding.swift').read_text()
events = '    func events(' + service.split('    func events(', 2)[2].split('    private func fetchReminders', 1)[0]
manager = (root / 'boringNotch/managers/CalendarManager.swift').read_text().replace('import Defaults\n', '')
manager = manager.replace('EKEventStore.authorizationStatus', 'FixtureAuthorization.status')
fixture = r'''
import Combine
import EventKit
import Foundation

struct CalendarModel: Equatable { let id: String; let isReminder: Bool }
struct EventModel: Equatable {
    let id: String
    let start: Date
    init(id: String, start: Date) { self.id = id; self.start = start }
    init?(from event: EventModel) { self = event }
}
enum CalendarSelectionState { case all, selected(Set<String>) }
enum Defaults {
    enum Key { case calendarSelectionState }
    static var selection = CalendarSelectionState.all
    static subscript(_ key: Key) -> CalendarSelectionState {
        get { selection }
        set { selection = newValue }
    }
}
enum FixtureAuthorization {
    static var event = EKAuthorizationStatus.fullAccess
    static var reminder = EKAuthorizationStatus.fullAccess
    static func status(for entity: EKEntityType) -> EKAuthorizationStatus { entity == .event ? event : reminder }
}
struct StoreCalendar { let calendarIdentifier: String }
final class StoreProbe {
    var reads: [EKEntityType: Int] = [:]
    var eventFetches = 0
    var eventSelection: [String] = []
    let events = (0..<10).map { StoreCalendar(calendarIdentifier: "e\($0)") }
    let reminders = (0..<10).map { StoreCalendar(calendarIdentifier: "r\($0)") }
    func calendars(for type: EKEntityType) -> [StoreCalendar] {
        reads[type, default: 0] += 1
        return type == .event ? events : reminders
    }
    func predicateForEvents(withStart start: Date, end: Date, calendars: [StoreCalendar]) -> [String] {
        eventSelection = calendars.map(\.calendarIdentifier)
        return eventSelection
    }
    func events(matching ids: [String]) -> [EventModel] {
        eventFetches += 1
        return ids.map { EventModel(id: $0, start: Date(timeIntervalSince1970: 20)) }
    }
}
final class EventQueryProbe {
    let store = StoreProbe()
    var eventAccess = true
    var reminderAccess = true
    var reminderSelection: [String] = []
    func hasAccess(to type: EKEntityType) -> Bool { type == .event ? eventAccess : reminderAccess }
    func fetchReminders(from start: Date, to end: Date, calendars: [StoreCalendar]) async -> [EventModel] {
        reminderSelection = calendars.map(\.calendarIdentifier)
        return reminderSelection.map { EventModel(id: $0, start: Date(timeIntervalSince1970: 10)) }
    }
PRODUCTION_EVENTS
}
@MainActor final class CalendarService {
    struct Query { let start: Date; let calendars: [String] }
    static var queries: [Query] = []
    static var replies: [Int: CheckedContinuation<[EventModel], Never>] = [:]
    static let lists = [CalendarModel(id: "e", isReminder: false), CalendarModel(id: "r", isReminder: true)]
    static var writes = 0
    func calendars() async -> [CalendarModel] {
        Self.lists.filter { FixtureAuthorization.status(for: $0.isReminder ? .reminder : .event) == .fullAccess }
    }
    func requestAccess(to type: EKEntityType) async throws -> Bool { true }
    func events(from start: Date, to end: Date, calendars: [String]) async -> [EventModel] {
        let index = Self.queries.count
        Self.queries.append(Query(start: start, calendars: calendars))
        return await withCheckedContinuation { Self.replies[index] = $0 }
    }
    func setReminderCompleted(reminderID: String, completed: Bool) async { Self.writes += 1 }
    static func reply(_ index: Int, id: String?) {
        replies.removeValue(forKey: index)!.resume(returning: id.map { [EventModel(id: $0, start: queries[index].start)] } ?? [])
    }
}
@main @MainActor struct Check {
    static func waitFor(_ predicate: () -> Bool) async {
        for _ in 0..<200 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        fatalError("Calendar request did not settle")
    }
    static func main() async {
        let probe = EventQueryProbe()
        let ids = probe.store.events.map(\.calendarIdentifier) + probe.store.reminders.map(\.calendarIdentifier)
        let now = Date()
        let result = await probe.events(from: now, to: now.addingTimeInterval(86400), calendars: ids)
        assert(result.count == 20 && result.prefix(10).allSatisfy { $0.id.hasPrefix("r") })
        assert(probe.store.reads[.event] == 1 && probe.store.reads[.reminder] == 1,
               "A query must enumerate each calendar type once, independent of calendar count")
        assert(Set(probe.store.eventSelection) == Set(ids.filter { $0.hasPrefix("e") }))
        assert(Set(probe.reminderSelection) == Set(ids.filter { $0.hasPrefix("r") }))
        let empty = EventQueryProbe()
        let emptyResult = await empty.events(from: now, to: now, calendars: [])
        assert(emptyResult.isEmpty)
        assert(empty.store.reads.isEmpty && empty.store.eventFetches == 0)
        let restricted = EventQueryProbe()
        restricted.reminderAccess = false
        let selected = await restricted.events(from: now, to: now, calendars: ["e2", "e2", "r1", "missing"])
        assert(selected.map(\.id) == ["e2"] && restricted.store.reads[.reminder] == nil)
        assert(restricted.reminderSelection.isEmpty, "Unauthorized reminder lists must not be read")

        let manager = CalendarManager.shared
        await waitFor { CalendarService.queries.count == 1 }
        let today = manager.currentWeekStartDate
        var datePublications = 0
        let observation = manager.$currentWeekStartDate.dropFirst().sink { _ in datePublications += 1 }
        await manager.updateCurrentDate(today.addingTimeInterval(60))
        await manager.updateCurrentDate(today.addingTimeInterval(120))
        assert(CalendarService.queries.count == 1 && datePublications == 0,
               "Appear/selection callbacks for the same day must share the initial refresh")
        CalendarService.reply(0, id: "initial")
        await waitFor { manager.events.first?.id == "initial" }
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today)!
        let nextDay = Calendar.current.date(byAdding: .day, value: 2, to: today)!
        let firstNavigation = Task { await manager.updateCurrentDate(tomorrow) }
        await waitFor { CalendarService.queries.count == 2 }
        let secondNavigation = Task { await manager.updateCurrentDate(nextDay) }
        await waitFor { CalendarService.queries.count == 3 }
        NotificationCenter.default.post(name: .EKEventStoreChanged, object: nil)
        await waitFor { CalendarService.queries.count == 4 }
        assert(CalendarService.queries[3].start == nextDay, "Store changes must refresh the selected day")
        CalendarService.reply(3, id: "fresh-store")
        await waitFor { manager.events.first?.id == "fresh-store" }
        CalendarService.reply(2, id: "stale-same-day")
        CalendarService.reply(1, id: "stale-old-day")
        await firstNavigation.value
        await secondNavigation.value
        assert(manager.events.first?.id == "fresh-store", "Late navigation results overwrote store changes")
        await manager.updateCurrentDate(nextDay.addingTimeInterval(60))
        assert(CalendarService.queries.count == 4)
        let permissions = Task { await manager.checkCalendarAuthorization() }
        await waitFor { CalendarService.queries.count == 5 }
        CalendarService.reply(4, id: "permissions")
        await permissions.value
        assert(manager.events.first?.id == "permissions", "Explicit authorization reload must refresh the same day")
        let selection = Task { await manager.setCalendarSelected(CalendarService.lists[0], isSelected: false) }
        await waitFor { CalendarService.queries.count == 6 }
        assert(CalendarService.queries[5].calendars == ["r"])
        CalendarService.reply(5, id: "selected")
        await selection.value
        let completion = Task { await manager.setReminderCompleted(reminderID: "r", completed: true) }
        await waitFor { CalendarService.queries.count == 7 }
        CalendarService.reply(6, id: "completed")
        await completion.value
        assert(CalendarService.writes == 1 && manager.events.first?.id == "completed")
        FixtureAuthorization.event = .denied
        let deniedEvents = Task { await manager.checkCalendarAuthorization() }
        await waitFor { CalendarService.queries.count == 8 }
        assert(manager.eventCalendars.isEmpty && manager.reminderLists.count == 1)
        assert(CalendarService.queries[7].calendars == ["r"])
        CalendarService.reply(7, id: "still-authorized-reminder")
        await deniedEvents.value
        FixtureAuthorization.reminder = .denied
        let deniedReminders = Task { await manager.checkReminderAuthorization() }
        await waitFor { CalendarService.queries.count == 9 }
        assert(manager.allCalendars.isEmpty && CalendarService.queries[8].calendars.isEmpty)
        CalendarService.reply(8, id: nil)
        await deniedReminders.value
        assert(manager.events.isEmpty, "Revoked permissions must clear the selected day's data")
        assert(CalendarService.replies.isEmpty && datePublications == 2)
        withExtendedLifetime(observation) {}
        print("PASS: 20 calendars require 2 store reads; same-day reuse; navigation/store races; permission grant/revoke, selection and reminder refresh")
    }
}
'''.replace('PRODUCTION_EVENTS', events)
with tempfile.TemporaryDirectory(prefix='notch-calendar-work-') as directory:
    folder = Path(directory)
    (folder / 'Manager.swift').write_text(manager)
    (folder / 'Check.swift').write_text(fixture)
    env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', str(folder / 'Manager.swift'),
                    str(folder / 'Check.swift'), '-o', str(folder / 'check')], env=env, check=True)
    subprocess.run([str(folder / 'check')], check=True)
