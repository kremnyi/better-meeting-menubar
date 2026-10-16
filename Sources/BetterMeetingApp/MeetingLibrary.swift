import Foundation
import os

final class MeetingLibrary: Sendable {
    private struct Stamp: Equatable, Sendable {
        let modified: Date?
        let size: Int?
    }

    private struct Folder: Sendable {
        let stamps: [Stamp]
        let meeting: MeetingHistoryItem?
    }

    private struct Cache: Sendable {
        var folders: [URL: Folder] = [:]
    }

    private let cache = OSAllocatedUnfairLock(initialState: Cache())

    func meetings(in root: URL) throws -> [MeetingHistoryItem] {
        let folders = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        var scanned: [URL: Folder] = [:]
        let meetings = folders.compactMap { folder -> MeetingHistoryItem? in
            guard !Task.isCancelled else { return nil }
            // The folder's date changes when files are added, removed, or replaced atomically.
            let stamps = [Self.stamp(folder), Self.stamp(folder.appendingPathComponent("metadata.json"))]
            let meeting: MeetingHistoryItem?
            if let cached = cache.withLock({ $0.folders[folder] }), cached.stamps == stamps,
               cached.meeting?.recoveryFolder == nil {
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

    // ponytail: scan saved Markdown on demand; add an index if large libraries make search slow.
    func search(_ meetings: [MeetingHistoryItem], query: String) -> [MeetingHistoryItem] {
        var matches: [MeetingHistoryItem] = []
        for meeting in meetings {
            guard !Task.isCancelled else { return [] }
            if meeting.title.localizedStandardContains(query) {
                matches.append(meeting)
                continue
            }
            let transcript = try? String(contentsOf: meeting.folderURL.appendingPathComponent("transcript.md"), encoding: .utf8)
            if transcript?.localizedStandardContains(query) == true
                || MeetingCalendar.searchFields(in: meeting.folderURL).contains(where: { $0.localizedStandardContains(query) }) {
                matches.append(meeting)
            }
        }
        return matches
    }

    private static func stamp(_ url: URL) -> Stamp {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return Stamp(modified: values?.contentModificationDate, size: values?.fileSize)
    }

    /// Some file systems store whole seconds, so files changed in the last two seconds are read fresh until they settle.
    private static func isSettled(_ stamps: [Stamp]) -> Bool {
        let settled = Date().addingTimeInterval(-2)
        return stamps.allSatisfy { ($0.modified ?? .distantPast) < settled }
    }
}
