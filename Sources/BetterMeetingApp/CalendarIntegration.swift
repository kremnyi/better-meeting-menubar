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
    func requestAccess() async throws
    func load(selectedIDs: Set<String>, now: Date) async throws -> CalendarSnapshot
}

@MainActor
final class EventKitCalendarReader: CalendarReading {
    private lazy var store = EKEventStore()
    private var lastRefreshSources = Date.distantPast
    var authorizationStatus: EKAuthorizationStatus { EKEventStore.authorizationStatus(for: .event) }

    func requestAccess() async throws { _ = try await store.requestFullAccessToEvents() }

    func load(selectedIDs: Set<String>, now: Date) async throws -> CalendarSnapshot {
        guard authorizationStatus == .fullAccess else { return CalendarSnapshot(calendars: [], events: []) }
        let store = store
        // Decided here so the detached load below touches no mutable state.
        let refreshSources = now.timeIntervalSince(lastRefreshSources) >= 60
        if refreshSources { lastRefreshSources = now }
        return try await Task.detached(priority: .userInitiated) { () throws -> CalendarSnapshot in
            try Task.checkCancellation()
            if refreshSources { store.refreshSourcesIfNecessary() }
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
    @Published private(set) var lastSuccessfulRefresh: Date?
    @Published private(set) var isStale = false
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

    var diagnosticSummary: String {
        let access = authorization == .fullAccess ? "access granted" : "access needed"
        let refresh: String
        if isStale {
            refresh = "last refresh failed; showing saved meetings"
        } else if let lastSuccessfulRefresh {
            refresh = "updated \(lastSuccessfulRefresh.formatted(date: .omitted, time: .shortened))"
        } else {
            refresh = "not refreshed yet"
        }
        return "Calendar: \(access) · \(refresh)"
    }

    private func clearSnapshot() {
        events = []
        calendars = []
        hasLoaded = false
        lastSuccessfulRefresh = nil
        isStale = false
        isLoading = false
        reminders.update(events: [], enabled: false)
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        defaults.set(value, forKey: "calendarIntegrationEnabled")
        revision += 1
        errorMessage = nil
        clearSnapshot()
    }

    func select(_ id: String, enabled: Bool) {
        if enabled { selectedIDs.insert(id) } else { selectedIDs.remove(id) }
        defaults.set(selectedIDs.sorted(), forKey: "selectedCalendarIDs")
        revision += 1
        events = []
        hasLoaded = false
        lastSuccessfulRefresh = nil
        isStale = false
        errorMessage = nil
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
            guard let self, self.enabled else { return }
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
            try await reader.requestAccess()
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
        // Still the latest refresh, and still allowed to show events; clears them when not allowed.
        func stillCurrent() -> Bool {
            guard revision == currentRevision else { return false }
            authorization = reader.authorizationStatus
            guard enabled, authorization == .fullAccess else {
                clearSnapshot()
                return false
            }
            return true
        }
        guard stillCurrent() else { return }
        isLoading = true
        let snapshot: CalendarSnapshot
        do {
            snapshot = try await reader.load(selectedIDs: selectedIDs, now: now)
        } catch is CancellationError {
            if revision == currentRevision { isLoading = false }
            return
        } catch {
            guard stillCurrent() else { return }
            isStale = hasLoaded
            errorMessage = isStale
                ? "Calendar refresh failed. Showing the last available meetings."
                : "Couldn’t refresh calendars. Try again."
            isLoading = false
            return
        }
        guard stillCurrent() else { return }
        calendars = snapshot.calendars
        events = snapshot.events
        hasLoaded = true
        lastSuccessfulRefresh = now
        isStale = false
        errorMessage = nil
        isLoading = false
        reminders.update(events: events, enabled: notifyAtStart, now: now)
    }

    func eventForRecording(id: String) async throws -> CalendarEvent {
        await refresh()
        // Start recording brings the app forward, and that activation's refresh can supersede ours.
        while let loadTask {
            await loadTask.value
            await Task.yield()
        }
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
