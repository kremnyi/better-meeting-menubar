import CryptoKit
import EventKit
import Foundation

struct CalendarEvent: Codable, Identifiable, Equatable, Sendable {
    struct Participant: Codable, Equatable, Sendable {
        let name: String?
        let email: String?
        let responseStatus: String

        init(name: String?, email: String?, responseStatus: String) {
            self.name = name
            self.email = email
            self.responseStatus = responseStatus
        }

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
    }

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
