import Foundation

// Read only the search fields; never re-encode this projection over the full sidecar.
enum MeetingCalendar {
    private struct Attachment: Decodable {
        let schemaVersion: Int
        let event: Event
    }

    private struct Event: Decodable {
        let title: String
        let attendees: [Participant]
        let organizer: Participant?
    }

    private struct Participant: Decodable {
        let email: String?
        let name: String?
    }

    static func matches(in folder: URL, query: String) -> Bool {
        matches(searchFields(in: folder), query: query)
    }

    static func matches(_ fields: [String], query: String) -> Bool {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return fields.contains { $0.localizedStandardContains(query) }
    }

    /// The event title and participant names and emails; empty when the sidecar is missing or unreadable.
    static func searchFields(in folder: URL) -> [String] {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("calendar.json")),
              let attachment = try? JSONDecoder().decode(Attachment.self, from: data),
              attachment.schemaVersion == 1 else { return [] }
        let event = attachment.event
        let people = event.attendees + [event.organizer].compactMap { $0 }
        return [event.title] + people.flatMap { [$0.email, $0.name].compactMap { $0 } }
    }
}
