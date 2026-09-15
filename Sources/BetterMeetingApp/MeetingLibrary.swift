import Foundation
import os

/// Meetings recorded on the same day, in list order.
struct MeetingDayGroup: Identifiable, Equatable {
    let day: Date
    var items: [MeetingHistoryItem]
    var id: Date { day }

    /// Runs of meetings from the same day, keeping the list's order.
    static func groups(_ items: [MeetingHistoryItem], calendar: Calendar = .current) -> [MeetingDayGroup] {
        var groups: [MeetingDayGroup] = []
        for item in items {
            let day = calendar.startOfDay(for: item.recordedAt)
            if groups.last?.day == day {
                groups[groups.count - 1].items.append(item)
            } else {
                groups.append(MeetingDayGroup(day: day, items: [item]))
            }
        }
        return groups
    }
}

/// Reads meeting folders for the menu and remembers what it parsed between scans and searches.
/// Entries are keyed by modification dates and sizes, so edits made in Finder or a text editor
/// are read again on the next scan or search.
final class MeetingLibrary: Sendable {
    private struct Stamp: Equatable, Sendable {
        let modified: Date?
        let size: Int?
    }

    private struct Folder: Sendable {
        let stamps: [Stamp]
        let meeting: MeetingHistoryItem?
    }

    private struct SearchText: Sendable {
        let stamps: [Stamp]
        let transcript: String?
        let calendarFields: [String]
    }

    private struct Cache: Sendable {
        var folders: [URL: Folder] = [:]
        var text: [URL: SearchText] = [:]
    }

    private let cache = OSAllocatedUnfairLock(initialState: Cache())

    func meetings(in root: URL) -> [MeetingHistoryItem] {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        var scanned: [URL: Folder] = [:]
        let meetings = folders.compactMap { folder -> MeetingHistoryItem? in
            guard !Task.isCancelled else { return nil }
            // The folder's date changes when files are added, removed, or replaced atomically.
            let stamps = [Self.stamp(folder), Self.stamp(folder.appendingPathComponent("metadata.json"))]
            let meeting: MeetingHistoryItem?
            if let cached = cache.withLock({ $0.folders[folder] }), cached.stamps == stamps {
                meeting = cached.meeting
            } else {
                meeting = MeetingArtifacts.meeting(in: folder)
            }
            if Self.isSettled(stamps) { scanned[folder] = Folder(stamps: stamps, meeting: meeting) }
            return meeting
        }
        .sorted { $0.recordedAt > $1.recordedAt }
        let kept = scanned
        if !Task.isCancelled { cache.withLock { $0.folders = kept } }
        return meetings
    }

    func search(_ meetings: [MeetingHistoryItem], query: String) -> [MeetingHistoryItem] {
        var matches: [MeetingHistoryItem] = []
        for meeting in meetings {
            guard !Task.isCancelled else { return [] }
            if meeting.title.localizedStandardContains(query) {
                matches.append(meeting)
                continue
            }
            let text = searchText(in: meeting.folderURL)
            if MeetingCalendar.matches(text.calendarFields, query: query)
                || text.transcript?.localizedStandardContains(query) == true {
                matches.append(meeting)
            }
        }
        let listed = Set(meetings.map(\.folderURL))
        cache.withLock { $0.text = $0.text.filter { listed.contains($0.key) } }
        return matches
    }

    private func searchText(in folder: URL) -> SearchText {
        let transcriptURL = folder.appendingPathComponent("transcript.md")
        let stamps = [Self.stamp(transcriptURL), Self.stamp(folder.appendingPathComponent("calendar.json"))]
        if let cached = cache.withLock({ $0.text[folder] }), cached.stamps == stamps { return cached }
        let text = SearchText(
            stamps: stamps,
            transcript: try? String(contentsOf: transcriptURL, encoding: .utf8),
            calendarFields: MeetingCalendar.searchFields(in: folder)
        )
        if Self.isSettled(stamps) { cache.withLock { $0.text[folder] = text } }
        return text
    }

    private static func stamp(_ url: URL) -> Stamp {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return Stamp(modified: values?.contentModificationDate, size: values?.fileSize)
    }

    /// Some file systems store whole seconds, so a file changed within the last two seconds
    /// could change again without a new date. Read those fresh until they settle.
    private static func isSettled(_ stamps: [Stamp]) -> Bool {
        let settled = Date().addingTimeInterval(-2)
        return stamps.allSatisfy { ($0.modified ?? .distantPast) < settled }
    }
}
