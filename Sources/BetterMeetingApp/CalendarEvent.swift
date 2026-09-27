import CryptoKit
import EventKit
import Foundation

struct CalendarEvent: Codable, Identifiable, Equatable, Sendable {
    struct Participant: Codable, Equatable, Sendable {
        let name: String?
        let email: String?
        let responseStatus: String

        init(_ person: EKParticipant) {
            name = person.name
            email = person.url.scheme?.lowercased() == "mailto"
                ? String(person.url.absoluteString.dropFirst(7)).removingPercentEncoding : nil
            responseStatus = switch person.participantStatus {
            case .accepted: "accepted"
            case .declined: "declined"
            case .tentative: "tentative"
            case .pending: "needs-action"
            case .delegated: "delegated"
            case .completed: "completed"
            case .inProcess: "in-process"
            default: "unknown"
            }
        }
    }

    let calendarKey: String
    let providerCalendarId: String
    let providerEventId: String
    let externalIdentifier: String?
    let calendarTitle: String
    let title: String
    let scheduledStart: Date
    let scheduledEnd: Date
    let recurrenceId: Date?
    let timeZone: String?
    let sourceUpdatedAt: Date?
    let attendees: [Participant]
    let organizer: Participant?
    let eventId: String
    let occurrenceId: String
    /// Video-call link found on the event. Menu-only: it is left out of `calendar.json`
    /// because invite links can carry meeting passwords.
    var joinURL: URL?

    private enum CodingKeys: String, CodingKey {
        case calendarKey, providerCalendarId, providerEventId, externalIdentifier, calendarTitle, title,
             scheduledStart, scheduledEnd, recurrenceId, timeZone, sourceUpdatedAt, attendees, organizer,
             eventId, occurrenceId
    }

    var id: String { occurrenceId }

    static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    init(_ event: EKEvent) {
        providerCalendarId = event.calendar.calendarIdentifier
        calendarKey = "eventkit:" + Self.hash(event.calendar.source.sourceIdentifier + "\n" + providerCalendarId)
        providerEventId = event.calendarItemIdentifier
        externalIdentifier = event.calendarItemExternalIdentifier
        calendarTitle = event.calendar.title
        let name = (event.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        title = name.isEmpty ? "Untitled event" : name
        scheduledStart = event.startDate
        scheduledEnd = event.endDate
        recurrenceId = event.hasRecurrenceRules || event.isDetached ? event.occurrenceDate : nil
        timeZone = event.timeZone?.identifier
        sourceUpdatedAt = event.lastModifiedDate
        attendees = (event.attendees ?? []).map(Participant.init)
        organizer = event.organizer.map(Participant.init)
        let eventId = Self.hash(calendarKey + "\n" + (externalIdentifier ?? providerEventId))
        self.eventId = eventId
        occurrenceId = recurrenceId.map {
            Self.hash(eventId + "\n" + ISO8601DateFormatter().string(from: $0))
        } ?? eventId
        joinURL = Self.joinURL(url: event.url, location: event.location, notes: event.notes)
    }

    /// The first Google Meet, Zoom, Teams, or Webex join link in the event's URL, location, then notes.
    /// Invites also carry help, dial-in, and download links on the same hosts, so only join paths count.
    static func joinURL(url: URL?, location: String?, notes: String?) -> URL? {
        if let url, joinService(for: url) != nil { return url }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        for text in [location, notes].compactMap({ $0 }) {
            let matches = detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
            if let link = matches.lazy.compactMap(\.url).first(where: { joinService(for: $0) != nil }) { return link }
        }
        return nil
    }

    static func joinService(for url: URL) -> String? {
        guard ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased() else { return nil }
        let path = url.path.lowercased()
        func within(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
        if host == "meet.google.com", path.count > 1 { return "Google Meet" }
        if within("zoom.us") || within("zoomgov.com"),
           ["/j/", "/my/", "/w/"].contains(where: path.hasPrefix) { return "Zoom" }
        if host == "teams.microsoft.com" || host == "teams.live.com",
           ["/l/meetup-join/", "/meet/"].contains(where: path.hasPrefix) { return "Teams" }
        if within("webex.com"), ["/meet/", "/join/", "/j.php"].contains(where: path.contains) { return "Webex" }
        return nil
    }

    var joinService: String? { joinURL.flatMap(Self.joinService(for:)) }

    static func isRecordable(_ event: EKEvent, now: Date) -> Bool {
        guard !event.isAllDay, event.status != .canceled,
              let start = event.startDate, let end = event.endDate,
              end > now, end > start, start < now.addingTimeInterval(86_400),
              !(event.attendees ?? []).contains(where: { $0.isCurrentUser && $0.participantStatus == .declined })
        else { return false }
        let title = (event.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !title.hasPrefix("canceled:") && !title.hasPrefix("cancelled:")
    }

    func attach(to folder: URL, recordedAt: Date) throws {
        struct Attachment: Encodable {
            let schemaVersion = 1
            let event: CalendarEvent
            let link: Link
        }
        struct Link: Encodable {
            let method = "started_from_calendar_event"
            let linkedAt: Date
            let recordedAtAtLink: Date
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Attachment(event: self, link: Link(linkedAt: Date(), recordedAtAtLink: recordedAt)))
        let url = folder.appendingPathComponent("calendar.json")
        // Exclusive creation protects existing attachments; personal data is private from the first byte.
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        try file.write(contentsOf: data)
    }
}
