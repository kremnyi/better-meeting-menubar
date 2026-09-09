import Foundation
import AppKit
import EventKit
import SwiftUI
import UserNotifications
import XCTest
@testable import BetterMeetingApp

final class MeetingCalendarTests: XCTestCase {
    @MainActor
    func testReminderScheduleUpdatesWithoutDuplicatesAndPreservesOtherNotifications() async throws {
        let center = ReminderCenterFixture()
        let reminders = CalendarReminders(center: center)
        let now = Date()
        let event = try calendarEventFixture(date: now.addingTimeInterval(600))
        let unrelated = UNNotificationRequest(identifier: "transcript-ready", content: UNMutableNotificationContent(), trigger: nil)
        center.pending[unrelated.identifier] = unrelated
        reminders.update(events: [event], enabled: false)
        await reminders.task?.value
        XCTAssertEqual(center.authorizationRequests, 0)
        XCTAssertEqual(center.pending.count, 1)
        XCTAssertTrue(reminders.scheduledEvents.isEmpty)

        reminders.update(events: [event], enabled: true)
        await reminders.task?.value
        let request = try XCTUnwrap(center.pending[CalendarReminder.prefix + event.id])
        XCTAssertEqual(request.content.categoryIdentifier, CalendarReminder.categoryID)
        XCTAssertEqual(request.content.body, event.title)
        XCTAssertEqual(request.content.userInfo.count, 2, "Do not put attendee emails into notifications")
        let trigger = try XCTUnwrap(request.trigger as? UNCalendarNotificationTrigger)
        XCTAssertEqual(trigger.nextTriggerDate(), event.scheduledStart)
        XCTAssertFalse(trigger.repeats)
        XCTAssertEqual(CalendarReminder.category.actions.first?.identifier, CalendarReminder.startActionID)
        XCTAssertTrue(CalendarReminder.category.actions[0].options.contains(.foreground))
        XCTAssertTrue(CalendarReminder.category.actions[0].options.contains(.authenticationRequired))
        reminders.update(events: [event], enabled: true)
        await reminders.task?.value
        XCTAssertEqual(center.adds, 1, "Refreshing the menu must not duplicate or postpone alerts")
        XCTAssertEqual(reminders.scheduledEvents, [event])

        let moved = try calendarEventFixture(date: now.addingTimeInterval(1200))
        center.delivered = [request]
        reminders.update(events: [moved], enabled: true)
        await reminders.task?.value
        XCTAssertEqual(center.adds, 2)
        XCTAssertTrue(center.delivered.isEmpty)
        XCTAssertTrue(CalendarReminder.matches(try XCTUnwrap(center.pending[request.identifier]), event: moved))
        XCTAssertEqual(reminders.scheduledEvents, [moved])
        reminders.update(events: [], enabled: true) // Deleted event, deselected calendar, or revoked calendar access.
        await reminders.task?.value
        XCTAssertEqual(Array(center.pending.keys), [unrelated.identifier])
        XCTAssertTrue(reminders.scheduledEvents.isEmpty)
        reminders.update(events: [try calendarEventFixture(date: now.addingTimeInterval(-60))], enabled: true)
        await reminders.task?.value
        XCTAssertEqual(center.adds, 2, "Never replay alerts for a meeting already started")
        center.allowed = false
        reminders.update(events: [event], enabled: true)
        await reminders.task?.value
        XCTAssertNotNil(reminders.message)
        XCTAssertEqual(center.pending.count, 1)
        XCTAssertTrue(reminders.scheduledEvents.isEmpty)
        XCTAssertFalse(reminders.isUpdating)
    }

    @MainActor
    func testReminderSummaryCountsOnlyConfirmedAlertsAfterPartialFailure() async throws {
        let center = ReminderCenterFixture()
        let reminders = CalendarReminders(center: center)
        let first = try calendarEventFixture(id: "first")
        let failed = try calendarEventFixture(id: "failed", date: Date().addingTimeInterval(1200))
        center.rejectedIDs = [CalendarReminder.prefix + failed.id]
        reminders.update(events: [first, failed], enabled: true)
        await reminders.task?.value
        XCTAssertEqual(reminders.scheduledEvents, [first])
        XCTAssertNotNil(reminders.message)
        XCTAssertFalse(reminders.isUpdating)

        center.rejectedIDs = []
        reminders.update(events: [first, failed], enabled: true)
        await reminders.task?.value
        XCTAssertEqual(reminders.scheduledEvents, [first, failed])
        XCTAssertNil(reminders.message)
        reminders.update(events: [first, failed], enabled: false)
        XCTAssertTrue(reminders.scheduledEvents.isEmpty, "Turning reminders off immediately clears the visible summary")
        await reminders.task?.value
        XCTAssertTrue(center.pending.isEmpty)
    }

    func testUpcomingMeetingTimeDistinguishesFutureOngoingAndTomorrow() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-09T12:00:00Z"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let event = try calendarEventFixture(date: now.addingTimeInterval(18 * 60))
        XCTAssertEqual(event.relativeStart(at: now, calendar: calendar), "Starts in 18 min")
        XCTAssertEqual(event.relativeStart(at: event.scheduledStart.addingTimeInterval(-30), calendar: calendar), "Starts in 1 min")
        XCTAssertEqual(event.relativeStart(at: now.addingTimeInterval(-3600), calendar: calendar), "Starts in 1 hr 18 min")
        XCTAssertEqual(event.relativeStart(at: event.scheduledStart, calendar: calendar), "In progress")
        XCTAssertEqual(event.relativeStart(at: event.scheduledEnd, calendar: calendar), "Ended")
        XCTAssertEqual(event.relativeStart(at: now.addingTimeInterval(-86400), calendar: calendar), "Tomorrow")
    }

    @MainActor
    func testDisablingRemindersWinsAnInFlightNotificationAdd() async throws {
        let center = ReminderCenterFixture()
        let reminders = CalendarReminders(center: center)
        let adding = expectation(description: "notification add started")
        var resume: CheckedContinuation<Void, Never>?
        center.beforeAdd = {
            await withCheckedContinuation { continuation in
                resume = continuation
                adding.fulfill()
            }
        }
        reminders.update(events: [try calendarEventFixture()], enabled: true)
        await fulfillment(of: [adding], timeout: 2)
        reminders.update(events: [], enabled: false)
        resume?.resume()
        await reminders.task?.value
        XCTAssertTrue(center.pending.isEmpty)
        XCTAssertTrue(center.delivered.isEmpty)
        XCTAssertTrue(reminders.scheduledEvents.isEmpty)
        XCTAssertFalse(reminders.isUpdating)
    }

    @MainActor
    func testReminderActionsRequireExplicitClickAndCurrentEventWithoutInterruptingCapture() async throws {
        _ = NSApplication.shared
        let suite = "ReminderAction.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defaults.set(root, forKey: "outputFolder")
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let reader = CalendarReaderFixture()
        reader.authorizationStatus = .fullAccess
        let event = try calendarEventFixture()
        reader.events = [event]
        let center = ReminderCenterFixture()
        let calendar = CalendarIntegration(defaults: defaults, reader: reader, reminders: CalendarReminders(center: center))
        XCTAssertFalse(calendar.notifyAtStart)
        calendar.setEnabled(true)
        calendar.select(event.providerCalendarId, enabled: true)
        await calendar.setNotifyAtStart(true)
        await calendar.reminders.task?.value
        XCTAssertEqual(center.authorizationRequests, 1)
        XCTAssertTrue(CalendarIntegration(defaults: defaults, reader: reader).notifyAtStart)
        let model = AppModel(defaults: defaults)
        model.calendar = calendar
        let delegate = AppDelegate()
        delegate.model = model // No menu appearance is required for notification handling.
        let request = CalendarReminder.request(for: event)
        let presented = await delegate.shouldPresentCalendarReminder(request)
        XCTAssertTrue(presented)
        var starts = 0
        await delegate.handleCalendarReminder(request, action: UNNotificationDefaultActionIdentifier) { _ in starts += 1 }
        await delegate.handleCalendarReminder(request, action: UNNotificationDismissActionIdentifier) { _ in starts += 1 }
        XCTAssertEqual(starts, 0)
        await delegate.handleCalendarReminder(request, action: CalendarReminder.startActionID) { selected in
            starts += 1
            XCTAssertEqual(selected.id, event.id)
        }
        XCTAssertEqual(starts, 1)
        model.recordingDidStart(at: Date())
        await delegate.handleCalendarReminder(request, action: CalendarReminder.startActionID) { _ in starts += 1 }
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(model.state, .recording)
        model.fail(AppError.missingRecording)
        model.dismissFailure()
        reader.events = [try calendarEventFixture(date: Date().addingTimeInterval(1800))]
        await delegate.handleCalendarReminder(request, action: CalendarReminder.startActionID) { _ in starts += 1 }
        XCTAssertEqual(starts, 1, "A moved event must not be recorded through its old alert")
        XCTAssertNotNil(model.completionMessage)
        await calendar.setNotifyAtStart(false)
        await calendar.reminders.task?.value
        XCTAssertEqual(center.authorizationRequests, 1)
        XCTAssertTrue(center.pending.isEmpty)
    }

    private let sidecar = """
    {"schemaVersion":1,"meetingId":"fixture","event":{
      "title":"Portfolio discussion","attendees":[
        {"name":"Alex Example","email":"Alex@Example.com","normalizedEmail":"alex@example.com"},
        {"name":null,"email":null,"normalizedEmail":null}],
      "organizer":{"name":"Host Person","email":"host@organizer.test","normalizedEmail":"host@organizer.test"},
      "providerEventId":null},"match":{"confidence":"high"}}
    """

    func testCalendarSearchIsCaseInsensitiveAndLeavesSidecarIntact() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("calendar.json")
        try sidecar.write(to: url, atomically: true, encoding: .utf8)
        let item = MeetingHistoryItem(title: "Recording", recordedAt: Date(), duration: 30,
                                      folderURL: root, needsTranscription: true, titleWasProvided: true)
        for query in ["alex@example.com", "EXAMPLE.COM", "Alex Example", "host@organizer.test", "Portfolio"] {
            XCTAssertEqual(MeetingArtifacts.search([item], query: query), [item])
        }
        XCTAssertTrue(MeetingArtifacts.search([item], query: "unrelated@example.net").isEmpty)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), sidecar)
        try MeetingArtifacts.write(title: "Recording", recordedAt: Date(), duration: 30, segments: [], to: root)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), sidecar, "Transcription must preserve calendar data")
        for invalid in ["{", sidecar.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":2")] {
            try invalid.write(to: url, atomically: true, encoding: .utf8)
            XCTAssertFalse(MeetingCalendar.matches(in: root, query: "example.com"))
            XCTAssertEqual(MeetingArtifacts.search([item], query: "Recording"), [item])
        }
    }

    @MainActor
    func testUnfinishedMeetingCanBeFoundByAttendee() async throws {
        let suite = "BetterMeetingCalendar.\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(root, forKey: "outputFolder")
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let folder = try MeetingArtifacts.createDirectory(in: root, title: "Pending meeting", recordedAt: Date())
        try Data([1]).write(to: folder.appendingPathComponent("audio.m4a"))
        try sidecar.write(to: folder.appendingPathComponent("calendar.json"), atomically: true, encoding: .utf8)
        let model = AppModel(defaults: defaults)
        await model.historyRefreshTask?.value
        XCTAssertTrue(model.transcriptionHistory.isEmpty)
        model.historyQuery = "EXAMPLE.COM"
        await model.historySearchTask?.value
        XCTAssertEqual(model.transcriptionHistory.map(\.title), ["Pending meeting"])
        XCTAssertTrue(model.transcriptionHistory[0].needsTranscription)
        model.historyQuery = ""
        await model.historySearchTask?.value
        XCTAssertTrue(model.transcriptionHistory.isEmpty)
    }

    @MainActor
    func testEventKitOptInSelectionRevocationAndStaleResults() async throws {
        let suite = "CalendarOptIn.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let reader = CalendarReaderFixture()
        let calendar = CalendarIntegration(defaults: defaults, reader: reader)
        await calendar.refresh()
        XCTAssertEqual(reader.loads, 0)
        XCTAssertEqual(reader.requests, 0)
        XCTAssertTrue(calendar.selectedIDs.isEmpty)
        calendar.setEnabled(true)
        await calendar.refresh()
        XCTAssertEqual(reader.loads, 0, "No access before the explicit permission action")
        await calendar.requestAccess()
        XCTAssertEqual(reader.requests, 1)
        XCTAssertTrue(calendar.events.isEmpty)
        calendar.select("fixture-calendar", enabled: true)
        reader.events = [try calendarEventFixture()]
        await calendar.refresh()
        XCTAssertEqual(calendar.events.count, 1)
        XCTAssertEqual(reader.selectedIDs, ["fixture-calendar"])
        XCTAssertEqual(CalendarIntegration(defaults: defaults, reader: reader).selectedIDs, ["fixture-calendar"])
        let selectedEvent = try await calendar.eventForRecording(id: reader.events[0].id)
        XCTAssertEqual(selectedEvent, reader.events[0])

        reader.authorizationStatus = .denied
        await calendar.refresh()
        XCTAssertTrue(calendar.events.isEmpty)
        do { _ = try await calendar.eventForRecording(id: "occurrence"); XCTFail("Revoked access must fail") }
        catch { XCTAssertTrue(error is CalendarRecordingError) }

        reader.authorizationStatus = .fullAccess
        reader.beforeReturn = { calendar.setEnabled(false) }
        await calendar.refresh()
        XCTAssertTrue(calendar.events.isEmpty, "A late read must not restore disconnected data")
        let loads = reader.loads
        await calendar.refresh()
        XCTAssertEqual(reader.loads, loads)
        reader.beforeReturn = nil
    }

    @MainActor
    func testExactOccurrenceOnlyAndPrivateSearchableSnapshot() async throws {
        let suite = "CalendarSnapshot.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let event = try calendarEventFixture()
        let reader = CalendarReaderFixture()
        reader.authorizationStatus = .fullAccess
        reader.events = [event]
        let calendar = CalendarIntegration(defaults: defaults, reader: reader)
        calendar.setEnabled(true)
        calendar.select("fixture-calendar", enabled: true)
        do { _ = try await calendar.eventForRecording(id: "same-title-different-occurrence"); XCTFail("Never guess") }
        catch { XCTAssertTrue(error is CalendarRecordingError) }
        let selected = try await calendar.eventForRecording(id: event.id)
        let actualStart = event.scheduledStart.addingTimeInterval(90)
        try selected.attach(to: root, recordedAt: actualStart)
        let url = root.appendingPathComponent("calendar.json")
        let data = try Data(contentsOf: url)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let link = try XCTUnwrap(json["link"] as? [String: Any])
        XCTAssertEqual(link["method"] as? String, "started_from_calendar_event")
        XCTAssertEqual(link["recordedAtAtLink"] as? String, ISO8601DateFormatter().string(from: actualStart))
        XCTAssertNil(json["match"], "Explicit selection has no matching score")
        XCTAssertEqual((json["event"] as? [String: Any])?["occurrenceId"] as? String, event.id)
        XCTAssertTrue(MeetingCalendar.matches(in: root, query: "EXAMPLE.COM"))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertThrowsError(try selected.attach(to: root, recordedAt: Date()))
        XCTAssertEqual(try Data(contentsOf: url), data)
        try MeetingArtifacts.write(title: event.title, recordedAt: actualStart, duration: 60, segments: [], to: root)
        XCTAssertEqual(try Data(contentsOf: url), data, "Transcription preserves the event snapshot")
    }

    func testEventKitFiltersUnsuitableEventsWithoutRequestingAccess() {
        let event = EKEvent(eventStore: EKEventStore())
        let now = Date()
        event.title = "Portfolio review"
        event.startDate = now.addingTimeInterval(-60)
        event.endDate = now.addingTimeInterval(1800)
        XCTAssertTrue(CalendarEvent.isRecordable(event, now: now), "Include ongoing events")
        event.isAllDay = true
        XCTAssertFalse(CalendarEvent.isRecordable(event, now: now))
        event.isAllDay = false
        event.endDate = now
        XCTAssertFalse(CalendarEvent.isRecordable(event, now: now))
        event.startDate = now.addingTimeInterval(86_401)
        event.endDate = now.addingTimeInterval(87_000)
        XCTAssertFalse(CalendarEvent.isRecordable(event, now: now))
        event.startDate = now
        event.endDate = now.addingTimeInterval(1800)
        event.title = "Canceled: Portfolio review"
        XCTAssertFalse(CalendarEvent.isRecordable(event, now: now))
    }

    @MainActor
    func testCalendarNativeLayouts() async throws {
        _ = NSApplication.shared
        let suite = "CalendarLayout.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defaults.set(root, forKey: "outputFolder")
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let reader = CalendarReaderFixture()
        let notificationCenter = ReminderCenterFixture()
        let calendar = CalendarIntegration(defaults: defaults, reader: reader, reminders: CalendarReminders(center: notificationCenter))
        let model = AppModel(defaults: defaults)
        model.calendar = calendar
        model.prepareSpeechModel { _ in }
        try await model.modelPreparationTask?.value
        for state in ["off", "permission", "denied", "empty", "connected", "notify-on", "notify-denied", "notify-empty", "notify-partial", "long-title"] {
            calendar.setEnabled(state != "off")
            calendar.select("fixture-calendar", enabled: false)
            reader.events = []
            notificationCenter.rejectedIDs = []
            reader.authorizationStatus = state == "denied" ? .denied : state == "permission" ? .notDetermined : .fullAccess
            if state == "connected" || state.hasPrefix("notify-") || state == "long-title" {
                calendar.select("fixture-calendar", enabled: true)
                if state != "notify-empty" {
                    let title = state == "long-title" ? "Portfolio contract and investment discussion with Alexandra and the international product team" : "Portfolio review with Alex"
                    reader.events = [try calendarEventFixture(title: title), try calendarEventFixture(id: "second-occurrence")]
                }
            }
            if state == "notify-partial" { notificationCenter.rejectedIDs = [CalendarReminder.prefix + "second-occurrence"] }
            await calendar.refresh()
            notificationCenter.allowed = state != "notify-denied"
            await calendar.setNotifyAtStart(state.hasPrefix("notify-") || state == "long-title")
            await calendar.reminders.task?.value
            for scheme: ColorScheme in [.light, .dark] {
                let panels: [(String, AnyView)] = [
                    ("options", AnyView(CaptureOptionsView(calendarsPresented: true))),
                    ("menu", AnyView(MenuBarControlView()))
                ]
                for (name, content) in panels {
                    let view = NSHostingView(rootView: content.environmentObject(model).environmentObject(model.updates)
                        .environment(\.colorScheme, scheme).background(Color(nsColor: .windowBackgroundColor)))
                    view.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                    view.frame = NSRect(origin: .zero, size: view.fittingSize)
                    view.layoutSubtreeIfNeeded()
                    XCTAssertEqual(view.fittingSize.width, name == "menu" ? 304 : 360)
                    XCTAssertLessThan(view.fittingSize.height, 700)
                    if let path = ProcessInfo.processInfo.environment["BETTER_MEETING_PANELS_PREVIEW_PATH"] {
                        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                        view.cacheDisplay(in: view.bounds, to: bitmap)
                        let url = URL(fileURLWithPath: path).appendingPathComponent("calendar-\(name)-\(state)-\(scheme).png")
                        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
                    }
                }
            }
        }
    }
}

@MainActor
private final class CalendarReaderFixture: CalendarReading {
    var authorizationStatus: EKAuthorizationStatus = .notDetermined
    var requests = 0
    var loads = 0
    var selectedIDs: Set<String> = []
    var events: [CalendarEvent] = []
    var beforeReturn: (() -> Void)?

    func requestAccess() async throws -> Bool {
        requests += 1
        authorizationStatus = .fullAccess
        return true
    }

    func load(selectedIDs: Set<String>, now: Date) async -> CalendarSnapshot {
        loads += 1
        self.selectedIDs = selectedIDs
        beforeReturn?()
        return CalendarSnapshot(
            calendars: [CalendarChoice(id: "fixture-calendar", title: "Work", account: "Example account")],
            events: events.filter { selectedIDs.contains($0.providerCalendarId) }
        )
    }
}

private func calendarEventFixture(id: String = "occurrence", date: Date = Date().addingTimeInterval(600), title: String = "Portfolio review with Alex") throws -> CalendarEvent {
    let iso = ISO8601DateFormatter()
    let json = """
    {"calendarKey":"eventkit:fixture","providerCalendarId":"fixture-calendar","providerEventId":"item",
     "externalIdentifier":"external","calendarTitle":"Work","title":"\(title)",
     "scheduledStart":"\(iso.string(from: date))","scheduledEnd":"\(iso.string(from: date.addingTimeInterval(1800)))",
     "recurrenceId":"\(iso.string(from: date))","timeZone":"Europe/Warsaw","sourceUpdatedAt":null,
     "attendees":[{"name":"Alex Example","email":"Alex@example.com","normalizedEmail":"alex@example.com","responseStatus":"accepted"}],
     "organizer":null,"eventId":"event","occurrenceId":"\(id)"}
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(CalendarEvent.self, from: Data(json.utf8))
}

@MainActor
private final class ReminderCenterFixture: CalendarReminderCenter {
    var allowed = true
    var authorizationRequests = 0
    var pending: [String: UNNotificationRequest] = [:]
    var delivered: [UNNotificationRequest] = []
    var adds = 0
    var beforeAdd: (() async -> Void)?
    var rejectedIDs: Set<String> = []

    func calendarAccess(request: Bool) async throws -> Bool {
        if request { authorizationRequests += 1 }
        return allowed
    }
    func pendingNotificationRequests() async -> [UNNotificationRequest] { Array(pending.values) }
    func calendarDeliveredRequests() async -> [UNNotificationRequest] { delivered }
    func add(_ request: UNNotificationRequest) async throws {
        await beforeAdd?()
        if rejectedIDs.contains(request.identifier) { throw NSError(domain: "ReminderFixture", code: 1) }
        adds += 1
        pending[request.identifier] = request
    }
    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        for id in identifiers { pending.removeValue(forKey: id) }
    }
    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        delivered.removeAll { identifiers.contains($0.identifier) }
    }
}
