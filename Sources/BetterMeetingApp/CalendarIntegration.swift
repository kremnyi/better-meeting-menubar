import Combine
import AppKit
import EventKit
import Foundation

struct CalendarChoice: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let account: String
}

struct CalendarSnapshot: Sendable {
    let calendars: [CalendarChoice]
    let events: [CalendarEvent]
}

@MainActor
protocol CalendarReading {
    var authorizationStatus: EKAuthorizationStatus { get }
    func requestAccess() async throws -> Bool
    func load(selectedIDs: Set<String>, now: Date) async -> CalendarSnapshot
}

@MainActor
final class EventKitCalendarReader: CalendarReading {
    private lazy var store = EKEventStore()
    private var lastRefreshSources = Date.distantPast
    var authorizationStatus: EKAuthorizationStatus { EKEventStore.authorizationStatus(for: .event) }

    func requestAccess() async throws -> Bool { try await store.requestFullAccessToEvents() }

    func load(selectedIDs: Set<String>, now: Date) async -> CalendarSnapshot {
        guard authorizationStatus == .fullAccess else { return CalendarSnapshot(calendars: [], events: []) }
        let store = store
        if now.timeIntervalSince(lastRefreshSources) >= 60 {
            lastRefreshSources = now
            store.refreshSourcesIfNecessary()
        }
        return await Task.detached(priority: .userInitiated) {
            let calendars = store.calendars(for: .event)
            let choices = calendars.map {
                CalendarChoice(id: $0.calendarIdentifier, title: $0.title, account: $0.source.title)
            }.sorted { ($0.account, $0.title, $0.id) < ($1.account, $1.title, $1.id) }
            let selected = calendars.filter { selectedIDs.contains($0.calendarIdentifier) }
            // Passing nil calendars would read every calendar. An empty selection reads no events.
            guard !selected.isEmpty else { return CalendarSnapshot(calendars: choices, events: []) }
            let predicate = store.predicateForEvents(withStart: now, end: now.addingTimeInterval(86_400), calendars: selected)
            let events = store.events(matching: predicate)
                .filter { CalendarEvent.isRecordable($0, now: now) }
                .map(CalendarEvent.init)
                .sorted { ($0.scheduledStart, $0.id) < ($1.scheduledStart, $1.id) }
            return CalendarSnapshot(calendars: choices, events: events)
        }.value
    }
}

@MainActor
final class CalendarIntegration: ObservableObject {
    @Published private(set) var enabled: Bool
    @Published private(set) var authorization: EKAuthorizationStatus
    @Published private(set) var calendars: [CalendarChoice] = []
    @Published private(set) var selectedIDs: Set<String>
    @Published private(set) var events: [CalendarEvent] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoaded = false
    @Published private(set) var requestingAccess = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var notifyAtStart: Bool
    @Published private(set) var menuBarPreview: Bool
    let reminders: CalendarReminders

    private let defaults: UserDefaults
    private let reader: any CalendarReading
    private var revision = 0
    private var loadTask: Task<Void, Never>?
    private var loadToken = 0
    private var monitoring: AnyCancellable?

    init(defaults: UserDefaults = .standard, reader: (any CalendarReading)? = nil, reminders: CalendarReminders? = nil) {
        self.defaults = defaults
        let reader = reader ?? EventKitCalendarReader()
        self.reader = reader
        self.reminders = reminders ?? CalendarReminders()
        notifyAtStart = defaults.bool(forKey: "calendarNotifyAtStart")
        menuBarPreview = defaults.object(forKey: "calendarMenuBarPreview") as? Bool ?? true
        enabled = defaults.bool(forKey: "calendarIntegrationEnabled")
        selectedIDs = Set(defaults.stringArray(forKey: "selectedCalendarIDs") ?? [])
        authorization = reader.authorizationStatus
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        defaults.set(value, forKey: "calendarIntegrationEnabled")
        revision += 1
        events = []
        calendars = []
        errorMessage = nil
        isLoading = false
        reminders.update(events: [], enabled: false)
    }

    func select(_ id: String, enabled: Bool) {
        if enabled { selectedIDs.insert(id) } else { selectedIDs.remove(id) }
        defaults.set(selectedIDs.sorted(), forKey: "selectedCalendarIDs")
        revision += 1
        events = []
        reminders.update(events: [], enabled: false)
    }

    func setNotifyAtStart(_ value: Bool) async {
        notifyAtStart = value
        defaults.set(value, forKey: "calendarNotifyAtStart")
        if value { await reminders.authorize() }
        else { reminders.update(events: [], enabled: false) }
        await refresh()
    }

    func setMenuBarPreview(_ value: Bool) {
        menuBarPreview = value
        defaults.set(value, forKey: "calendarMenuBarPreview")
    }

    func startMonitoring() {
        guard monitoring == nil else { return }
        let changes = NotificationCenter.default.publisher(for: .EKEventStoreChanged).map { _ in () }
        let wake = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification).map { _ in () }
        let active = NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification).map { _ in () }
        let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect().map { _ in () }
        monitoring = Publishers.Merge4(changes, wake, active, timer).sink { [weak self] in
            Task { @MainActor [weak self] in
            guard let self, self.enabled && (self.notifyAtStart || self.menuBarPreview) else { return }
                await self.refresh()
            }
        }
        Task { await refresh() }
    }

    func requestAccess() async {
        guard enabled, !requestingAccess else { return }
        requestingAccess = true
        errorMessage = nil
        defer { requestingAccess = false }
        do {
            _ = try await reader.requestAccess()
        } catch {
            if enabled { errorMessage = "Couldn’t access calendars. Try again or check Calendar privacy settings." }
        }
        await refresh()
    }

    func refresh(now: Date = Date()) async {
        revision += 1
        let currentRevision = revision
        // Coalesce bursts from timers and notifications: wait for the load already
        // running, then load again only if no later call superseded this one.
        if let loadTask { await loadTask.value }
        guard revision == currentRevision else { return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performRefresh(now: now, revision: currentRevision)
        }
        loadTask = task
        loadToken += 1
        let token = loadToken
        await task.value
        if loadToken == token { loadTask = nil }
    }

    private func performRefresh(now: Date, revision currentRevision: Int) async {
        guard revision == currentRevision else { return }
        authorization = reader.authorizationStatus
        guard enabled, authorization == .fullAccess else {
            events = []
            calendars = []
            isLoading = false
            reminders.update(events: [], enabled: false)
            return
        }
        isLoading = true
        let snapshot = await reader.load(selectedIDs: selectedIDs, now: now)
        guard revision == currentRevision else { return }
        authorization = reader.authorizationStatus
        isLoading = false
        guard enabled, authorization == .fullAccess else {
            events = []
            calendars = []
            reminders.update(events: [], enabled: false)
            return
        }
        calendars = snapshot.calendars
        events = snapshot.events
        hasLoaded = true
        reminders.update(events: events, enabled: notifyAtStart, now: now)
    }

    func eventForRecording(id: String) async throws -> CalendarEvent {
        await refresh()
        guard enabled, authorization == .fullAccess, !isLoading,
              let event = events.first(where: { $0.id == id && selectedIDs.contains($0.providerCalendarId) }),
              event.scheduledEnd > Date() else { throw CalendarRecordingError.eventUnavailable }
        return event
    }
}

enum CalendarRecordingError: LocalizedError {
    case eventUnavailable

    var errorDescription: String? {
        "This calendar event is no longer available. Check your selected calendars, or start a manual recording."
    }
}
