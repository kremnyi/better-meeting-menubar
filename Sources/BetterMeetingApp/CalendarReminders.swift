import Combine
import Foundation
import UserNotifications

enum CalendarReminder {
    static let categoryID = "calendar-meeting-start"
    static let startActionID = "start-calendar-recording"
    static let prefix = "calendar-start:"

    static var category: UNNotificationCategory {
        UNNotificationCategory(identifier: categoryID, actions: [
            UNNotificationAction(identifier: startActionID, title: "Start recording", options: [.foreground, .authenticationRequired])
        ], intentIdentifiers: [])
    }

    static func request(for event: CalendarEvent) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "Meeting starting"
        content.body = event.title
        content.categoryIdentifier = categoryID
        content.sound = .default
        content.userInfo = ["occurrenceId": event.id, "scheduledStart": event.scheduledStart.timeIntervalSince1970]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents([.calendar, .timeZone, .year, .month, .day, .hour, .minute, .second], from: event.scheduledStart)
        return UNNotificationRequest(identifier: prefix + event.id, content: content,
                                     trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
    }

    static func matches(_ request: UNNotificationRequest, event: CalendarEvent) -> Bool {
        request.content.categoryIdentifier == categoryID
            && request.identifier == prefix + event.id
            && request.content.userInfo["occurrenceId"] as? String == event.id
            && request.content.userInfo["scheduledStart"] as? Double == event.scheduledStart.timeIntervalSince1970
    }
}

@MainActor
protocol CalendarReminderCenter {
    func calendarAccess(request: Bool) async throws -> Bool
    func pendingNotificationRequests() async -> [UNNotificationRequest]
    func calendarDeliveredRequests() async -> [UNNotificationRequest]
    func add(_ request: UNNotificationRequest) async throws
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
    func removeDeliveredNotifications(withIdentifiers identifiers: [String])
}

extension UNUserNotificationCenter: CalendarReminderCenter {
    func calendarAccess(request: Bool) async throws -> Bool {
        if request { _ = try await requestAuthorization(options: [.alert, .sound]) }
        let settings = await notificationSettings()
        return (settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional)
            && settings.alertSetting == .enabled
    }

    func calendarDeliveredRequests() async -> [UNNotificationRequest] {
        await deliveredNotifications().map(\.request)
    }
}

@MainActor
final class CalendarReminders: ObservableObject {
    @Published private(set) var message: String?
    @Published private(set) var requestingAccess = false
    @Published private(set) var scheduledEvents: [CalendarEvent] = []
    private let center: (any CalendarReminderCenter)?
    private var revision = 0
    private(set) var task: Task<Void, Never>?

    init(center: (any CalendarReminderCenter)? = MeetingNotifications.center) { self.center = center }

    func authorize() async {
        guard !requestingAccess else { return }
        requestingAccess = true
        defer { requestingAccess = false }
        do {
            let allowed = try await center?.calendarAccess(request: true) ?? false
            message = allowed ? nil : "Allow notifications for Better Meeting in System Settings."
        } catch {
            message = "Couldn’t request notifications. Check System Settings and try again."
        }
    }

    func update(events: [CalendarEvent], enabled: Bool, now: Date = Date()) {
        revision += 1
        if !enabled { scheduledEvents = [] }
        let version = revision
        let previous = task
        // Serialize OS mutations: disabling must remove even an add that was already in flight.
        task = Task { [weak self] in
            await previous?.value
            guard let self, version == self.revision else { return }
            await self.reconcile(events: events, enabled: enabled, now: now, version: version)
        }
    }

    private func reconcile(events: [CalendarEvent], enabled: Bool, now: Date, version: Int) async {
        guard let center else {
            scheduledEvents = []
            message = enabled ? "Notifications are unavailable." : nil
            return
        }
        let allowed: Bool
        if enabled { allowed = (try? await center.calendarAccess(request: false)) == true }
        else { allowed = false }
        var failure: String? = !enabled || allowed ? nil : "Allow notifications for Better Meeting in System Settings."
        let valid = allowed ? events.filter { $0.scheduledEnd > now } : []
        let byID = Dictionary(valid.map { (CalendarReminder.prefix + $0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let pending = await center.pendingNotificationRequests().filter { $0.identifier.hasPrefix(CalendarReminder.prefix) }
        let delivered = await center.calendarDeliveredRequests().filter { $0.identifier.hasPrefix(CalendarReminder.prefix) }
        func current(_ request: UNNotificationRequest) -> Bool {
            byID[request.identifier].map { CalendarReminder.matches(request, event: $0) } ?? false
        }
        center.removePendingNotificationRequests(withIdentifiers: pending.filter { !current($0) }.map(\.identifier))
        center.removeDeliveredNotifications(withIdentifiers: delivered.filter { !current($0) }.map(\.identifier))
        for event in valid where event.scheduledStart > max(now, Date()) {
            if pending.contains(where: { CalendarReminder.matches($0, event: event) && $0.content.body == event.title }) { continue }
            do { try await center.add(CalendarReminder.request(for: event)) }
            catch { failure = "Some meeting notifications couldn’t be scheduled. Try again." }
        }
        let confirmed = await center.pendingNotificationRequests()
        guard version == revision else { return }
        let future = max(now, Date())
        scheduledEvents = byID.values.filter { event in
            event.scheduledStart > future && confirmed.contains { CalendarReminder.matches($0, event: event) }
        }.sorted { ($0.scheduledStart, $0.id) < ($1.scheduledStart, $1.id) }
        message = failure
    }
}
