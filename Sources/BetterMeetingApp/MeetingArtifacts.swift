import Foundation

struct TranscriptSegment: Codable, Equatable, Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
    let language: String?
    var speaker: Int? = nil

    var speakerLabel: String? {
        guard let speaker, speaker >= 0, speaker < Int.max else { return nil }
        return "Speaker \(speaker + 1)"
    }
}

struct MeetingManifest: Codable {
    let title: String
    let recordedAt: Date
    let duration: TimeInterval
    let recording: String
    let audio: String
    let transcript: String
    let segmentCount: Int
    var transcriptionComplete: Bool? = nil
    var titleWasProvided: Bool? = nil
    var speechSettings: SpeechSettings? = nil
}

struct MeetingHistoryItem: Identifiable, Equatable, Sendable {
    let title: String
    let recordedAt: Date
    let duration: TimeInterval
    let folderURL: URL
    let needsTranscription: Bool
    let titleWasProvided: Bool

    var id: URL { folderURL }
}

enum MeetingArtifacts {
    static func createDirectory(in root: URL, title: String, recordedAt: Date) throws -> URL {
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )

        let timestamp = folderDateFormatter.string(from: recordedAt)
        let baseName = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? timestamp : "\(timestamp) — \(sanitizedTitle(title))"
        let candidate = availableDirectory(in: root, named: baseName)

        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: false)
        try writeMetadata(title: title, recordedAt: recordedAt, duration: 0, to: candidate)
        return candidate
    }

    static func renameDirectory(_ folder: URL, title: String, recordedAt: Date) throws -> URL {
        let baseName = "\(folderDateFormatter.string(from: recordedAt)) — \(sanitizedTitle(title))"
        let destination = availableDirectory(in: folder.deletingLastPathComponent(), named: baseName, current: folder)
        if destination.standardizedFileURL.path != folder.standardizedFileURL.path {
            try FileManager.default.moveItem(at: folder, to: destination)
        }
        return destination
    }

    static func renameMeeting(_ meeting: MeetingHistoryItem, to title: String) throws -> URL {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MeetingActionError.emptyTitle
        }
        let title = sanitizedTitle(title)
        let markdownURL = meeting.folderURL.appendingPathComponent("transcript.md")
        let metadataURL = meeting.folderURL.appendingPathComponent("metadata.json")
        let originalMarkdown = try Data(contentsOf: markdownURL)
        let originalMetadata = try Data(contentsOf: metadataURL)
        guard let markdown = String(data: originalMarkdown, encoding: .utf8),
              var metadata = try JSONSerialization.jsonObject(with: originalMetadata) as? [String: Any] else {
            throw MeetingActionError.invalidMeeting
        }
        let updatedMarkdown = markdown.hasPrefix("# ")
            ? "# \(title)" + markdown.drop(while: { !$0.isNewline })
            : "# \(title)\n\n" + markdown
        metadata["title"] = title
        metadata["titleWasProvided"] = true
        let updatedMetadata = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
        do {
            try updatedMarkdown.write(to: markdownURL, atomically: true, encoding: .utf8)
            try updatedMetadata.write(to: metadataURL, options: .atomic)
            return try renameDirectory(meeting.folderURL, title: title, recordedAt: meeting.recordedAt)
        } catch {
            try originalMarkdown.write(to: markdownURL, options: .atomic)
            try originalMetadata.write(to: metadataURL, options: .atomic)
            throw error
        }
    }

    private static func availableDirectory(in root: URL, named baseName: String, current: URL? = nil) -> URL {
        // Keep whole characters and leave room for a collision suffix within 255 UTF-8 bytes.
        var bytes = 0
        let baseName = String(baseName.prefix {
            bytes += $0.utf8.count
            return bytes <= 255 - 1 - String(Int.max).utf8.count
        })
        var candidate = root.appendingPathComponent(baseName, isDirectory: true)
        var suffix = 2

        while candidate.standardizedFileURL.path != current?.standardizedFileURL.path
                && FileManager.default.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent("\(baseName) \(suffix)", isDirectory: true)
            suffix += 1
        }

        return candidate
    }

    static func write(
        title: String,
        recordedAt: Date,
        duration: TimeInterval,
        segments: [TranscriptSegment],
        titleWasProvided: Bool? = nil,
        speechSettings: SpeechSettings? = nil,
        to folder: URL
    ) throws {
        let resolvedTitle = resolvedTitle(title, recordedAt: recordedAt)
        let transcript = transcriptMarkdown(
            title: resolvedTitle,
            recordedAt: recordedAt,
            duration: duration,
            segments: segments
        )
        try transcript.write(
            to: folder.appendingPathComponent("transcript.md"),
            atomically: true,
            encoding: .utf8
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

        let transcriptData = try encoder.encode(segments)
        try transcriptData.write(
            to: folder.appendingPathComponent("transcript.json"),
            options: .atomic
        )

        try writeMetadata(
            title: resolvedTitle,
            recordedAt: recordedAt,
            duration: duration,
            segmentCount: segments.count,
            transcriptionComplete: true,
            titleWasProvided: titleWasProvided ?? !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            speechSettings: speechSettings,
            to: folder
        )
    }

    static func writeMetadata(
        title: String,
        recordedAt: Date,
        duration: TimeInterval,
        segmentCount: Int = 0,
        transcriptionComplete: Bool = false,
        titleWasProvided: Bool? = nil,
        speechSettings: SpeechSettings? = nil,
        to folder: URL
    ) throws {
        let manifest = MeetingManifest(
            title: resolvedTitle(title, recordedAt: recordedAt),
            recordedAt: recordedAt,
            duration: duration,
            recording: "recording.mp4",
            audio: "audio.m4a",
            transcript: "transcript.md",
            segmentCount: segmentCount,
            transcriptionComplete: transcriptionComplete,
            titleWasProvided: titleWasProvided ?? !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            speechSettings: speechSettings
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let manifestData = try encoder.encode(manifest)
        try manifestData.write(
            to: folder.appendingPathComponent("metadata.json"),
            options: .atomic
        )
    }

    static func replaceTranscript(
        for meeting: MeetingHistoryItem, duration: TimeInterval, segments: [TranscriptSegment],
        speechSettings: SpeechSettings? = nil
    ) throws {
        let fm = FileManager.default
        let names = ["transcript.md", "transcript.json", "metadata.json"]
        let originals = try names.map { try Data(contentsOf: meeting.folderURL.appendingPathComponent($0)) }
        let staging = meeting.folderURL.appendingPathComponent(".transcript-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        do {
            try write(title: meeting.title, recordedAt: meeting.recordedAt, duration: duration,
                      segments: segments, titleWasProvided: meeting.titleWasProvided, speechSettings: speechSettings, to: staging)
            // Keep durable backups until all replacements succeed, including across an interrupted write.
            for (name, original) in zip(names, originals) {
                try original.write(to: staging.appendingPathComponent("previous-" + name), options: .atomic)
            }
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        var replaced: [Int] = []
        do {
            for (index, name) in names.enumerated() {
                let data = try Data(contentsOf: staging.appendingPathComponent(name))
                try data.write(to: meeting.folderURL.appendingPathComponent(name), options: .atomic)
                replaced.append(index)
            }
        } catch {
            do {
                for index in replaced {
                    try originals[index].write(to: meeting.folderURL.appendingPathComponent(names[index]), options: .atomic)
                }
            } catch {
                throw MeetingActionError.transcriptRecovery(staging)
            }
            try? fm.removeItem(at: staging)
            throw error
        }
        try? fm.removeItem(at: staging)
    }

    static func speechSettings(in folder: URL) -> SpeechSettings? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("metadata.json")) else { return nil }
        return (try? decoder.decode(MeetingManifest.self, from: data))?.speechSettings
    }

    static func meetings(in root: URL) -> [MeetingHistoryItem] {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return folders.compactMap { folder in
            Task.isCancelled ? nil : meeting(in: folder)
        }
        .sorted { $0.recordedAt > $1.recordedAt }
    }

    static func meeting(in folder: URL) -> MeetingHistoryItem? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let values = try? folder.resourceValues(forKeys: [.isDirectoryKey, .creationDateKey])
        guard values?.isDirectory == true else { return nil }

        let metadataURL = folder.appendingPathComponent("metadata.json")
        let manifest = (try? Data(contentsOf: metadataURL)).flatMap {
            try? decoder.decode(MeetingManifest.self, from: $0)
        }
        let hasTranscripts = ["transcript.md", "transcript.json"].allSatisfy {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
        let complete = manifest != nil && manifest?.transcriptionComplete != false && hasTranscripts
        let hasRecording = ["recording.mp4", "audio.m4a"].contains {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
        guard complete || hasRecording else { return nil }

        let nameParts = folder.lastPathComponent.components(separatedBy: " — ")

        return MeetingHistoryItem(
            title: manifest?.title ?? (nameParts.count > 1 ? nameParts.dropFirst().joined(separator: " — ") : folder.lastPathComponent),
            recordedAt: manifest?.recordedAt ?? folderDateFormatter.date(from: nameParts[0]) ?? values?.creationDate ?? .distantPast,
            duration: manifest?.duration ?? 0,
            folderURL: folder,
            needsTranscription: !complete,
            titleWasProvided: manifest?.titleWasProvided ?? true
        )
    }

    static func transcriptMarkdown(
        title: String,
        recordedAt: Date,
        duration: TimeInterval,
        segments: [TranscriptSegment]
    ) -> String {
        let date = DateFormatter.localizedString(from: recordedAt, dateStyle: .long, timeStyle: .short)
        var lines = [
            "# \(title)",
            "",
            "- Recorded: \(date)",
            "- Duration: \(Timecode.string(duration))",
            "- Recording: [recording.mp4](recording.mp4)",
            "",
            "## Transcript",
            "",
        ]

        if segments.isEmpty {
            lines.append("No speech was detected.")
        } else {
            lines.append(contentsOf: segments.map { segment in
                let language = segment.language.map { " [\($0)]" } ?? ""
                let speaker = segment.speakerLabel.map { " \($0):" } ?? ""
                return "[\(Timecode.string(segment.start))]\(language)\(speaker) \(segment.text)"
            })
        }

        lines.append("")
        return lines.joined(separator: "\n")
    }

    // ponytail: scan saved Markdown on demand; add an index if large libraries make search slow.
    static func search(_ meetings: [MeetingHistoryItem], query: String) -> [MeetingHistoryItem] {
        var matches: [MeetingHistoryItem] = []
        for meeting in meetings {
            guard !Task.isCancelled else { return [] }
            if meeting.title.localizedStandardContains(query)
                || MeetingCalendar.matches(in: meeting.folderURL, query: query)
                || (try? String(contentsOf: meeting.folderURL.appendingPathComponent("transcript.md"), encoding: .utf8)
                    .localizedStandardContains(query)) == true {
                matches.append(meeting)
            }
        }
        return matches
    }

    static func sanitizedTitle(_ title: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\n\r\t")
        let parts = title.components(separatedBy: invalid)
        let collapsed = parts
            .joined(separator: " ")
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
        let resolved = collapsed.isEmpty ? "Meeting" : collapsed
        return String(resolved.prefix(80))
    }

    private static func resolvedTitle(_ title: String, recordedAt: Date) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? folderDateFormatter.string(from: recordedAt) : sanitizedTitle(title)
    }

    private static let folderDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter
    }()
}

enum MeetingActionError: LocalizedError {
    case emptyTitle
    case invalidMeeting
    case clipboardUnavailable
    case transcriptRecovery(URL)

    var errorDescription: String? {
        switch self {
        case .emptyTitle: "Enter a meeting name."
        case .invalidMeeting: "The meeting's transcript or metadata could not be read."
        case .clipboardUnavailable: "The transcript could not be copied to the clipboard."
        case .transcriptRecovery(let folder): "The transcript could not be restored. Previous files are saved in \(folder.path)."
        }
    }
}

enum Timecode {
    static func string(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded(.down)))
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainder = seconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, remainder)
    }
}
