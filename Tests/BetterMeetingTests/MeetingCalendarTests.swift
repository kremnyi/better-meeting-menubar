import Foundation
import AppKit
import EventKit
import SwiftUI
import XCTest
@testable import BetterMeetingApp

final class MeetingCalendarTests: XCTestCase {
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
        let calendar = CalendarIntegration(defaults: defaults, reader: reader)
        let model = AppModel(defaults: defaults)
        model.calendar = calendar
        model.prepareSpeechModel { _ in }
        try await model.modelPreparationTask?.value
        for state in ["off", "permission", "denied", "empty", "connected"] {
            calendar.setEnabled(state != "off")
            reader.authorizationStatus = state == "denied" ? .denied : state == "permission" ? .notDetermined : .fullAccess
            if state == "connected" {
                calendar.select("fixture-calendar", enabled: true)
                reader.events = [try calendarEventFixture(), try calendarEventFixture(id: "second-occurrence")]
            }
            await calendar.refresh()
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

private func calendarEventFixture(id: String = "occurrence") throws -> CalendarEvent {
    let date = Date().addingTimeInterval(600)
    let iso = ISO8601DateFormatter()
    let json = """
    {"calendarKey":"eventkit:fixture","providerCalendarId":"fixture-calendar","providerEventId":"item",
     "externalIdentifier":"external","calendarTitle":"Work","title":"Portfolio review with Alex",
     "scheduledStart":"\(iso.string(from: date))","scheduledEnd":"\(iso.string(from: date.addingTimeInterval(1800)))",
     "recurrenceId":"\(iso.string(from: date))","timeZone":"Europe/Warsaw","sourceUpdatedAt":null,
     "attendees":[{"name":"Alex Example","email":"Alex@example.com","normalizedEmail":"alex@example.com","responseStatus":"accepted"}],
     "organizer":null,"eventId":"event","occurrenceId":"\(id)"}
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(CalendarEvent.self, from: Data(json.utf8))
}
