import Foundation

struct TranscriptSegment: Codable, Equatable, Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
    let language: String?
    var speaker: Int? = nil

    var speakerLabel: String? {
        guard let speaker, speaker >= 0 else { return nil }
        return "Speaker \(speaker + 1)"
    }
}

struct MeetingManifest: Codable {
    let title: String
    let recordedAt: Date
    let duration: TimeInterval
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
    /// Allocated bytes in the folder, read on scan for the menu's storage readout.
    var totalBytes: Int64 = 0
    /// A blocked restore retains its backup and must not be treated as a new transcription.
    var recoveryFolder: URL? = nil

    var recoveryError: String? {
        recoveryFolder.flatMap { MeetingActionError.transcriptRecovery($0).errorDescription }
    }

    var id: URL { folderURL }
}

enum MeetingArtifacts {
    private static let transcriptLock = NSRecursiveLock()
    private static let transcriptFiles = ["transcript.md", "transcript.json", "metadata.json"]

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
        transcriptLock.lock()
        defer { transcriptLock.unlock() }
        try recoverTranscript(in: meeting.folderURL)
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MeetingActionError.emptyTitle
        }
        let title = normalizedTitle(title)
        let markdownURL = meeting.folderURL.appendingPathComponent("transcript.md")
        let metadataURL = meeting.folderURL.appendingPathComponent("metadata.json")
        let fm = FileManager.default
        let originalMarkdown = fm.fileExists(atPath: markdownURL.path) ? try Data(contentsOf: markdownURL) : nil
        if !fm.fileExists(atPath: metadataURL.path) {
            try writeMetadata(title: meeting.title, recordedAt: meeting.recordedAt, duration: meeting.duration,
                              titleWasProvided: meeting.titleWasProvided, to: meeting.folderURL)
        }
        let originalMetadata = try Data(contentsOf: metadataURL)
        guard var metadata = try JSONSerialization.jsonObject(with: originalMetadata) as? [String: Any] else {
            throw MeetingActionError.invalidMeeting
        }
        var updatedMarkdown: String?
        if let originalMarkdown {
            guard let markdown = String(data: originalMarkdown, encoding: .utf8) else { throw MeetingActionError.invalidMeeting }
            updatedMarkdown = markdown.hasPrefix("# ")
                ? "# \(title)" + markdown.drop(while: { !$0.isNewline })
                : "# \(title)\n\n" + markdown
        }
        metadata["title"] = title
        metadata["titleWasProvided"] = true
        let updatedMetadata = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
        do {
            try updatedMarkdown?.write(to: markdownURL, atomically: true, encoding: .utf8)
            try updatedMetadata.write(to: metadataURL, options: .atomic)
            return try renameDirectory(meeting.folderURL, title: title, recordedAt: meeting.recordedAt)
        } catch {
            try originalMarkdown?.write(to: markdownURL, options: .atomic)
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
        recordingFilename: String? = nil,
        to folder: URL
    ) throws {
        let resolvedTitle = resolvedTitle(title, recordedAt: recordedAt)
        let transcript = transcriptMarkdown(
            title: resolvedTitle,
            recordedAt: recordedAt,
            duration: duration,
            segments: segments,
            recordingFilename: recordingFilename ?? recordingURL(in: folder).lastPathComponent
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
        transcriptionComplete: Bool = false,
        titleWasProvided: Bool? = nil,
        speechSettings: SpeechSettings? = nil,
        to folder: URL
    ) throws {
        let manifest = MeetingManifest(
            title: resolvedTitle(title, recordedAt: recordedAt),
            recordedAt: recordedAt,
            duration: duration,
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
        transcriptLock.lock()
        defer { transcriptLock.unlock() }
        try recoverTranscript(in: meeting.folderURL)
        let fm = FileManager.default
        let names = transcriptFiles
        let originals = try names.map { try Data(contentsOf: meeting.folderURL.appendingPathComponent($0)) }
        let staging = meeting.folderURL.appendingPathComponent(".transcript-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        do {
            try write(title: meeting.title, recordedAt: meeting.recordedAt, duration: duration,
                      segments: segments, titleWasProvided: meeting.titleWasProvided, speechSettings: speechSettings,
                      recordingFilename: recordingURL(in: meeting.folderURL).lastPathComponent, to: staging)
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
            // A crash after this marker must keep the new, complete set of files.
            try Data().write(to: staging.appendingPathComponent("committed"), options: .atomic)
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

    /// Restore a complete backup set before reading or replacing a transcript left by
    /// an interrupted process. Serialize with live replacements so history cannot undo one.
    static func recoverTranscript(in folder: URL) throws {
        transcriptLock.lock()
        defer { transcriptLock.unlock() }
        let fm = FileManager.default
        let stages = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            .filter {
                let values = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                return $0.lastPathComponent.hasPrefix(".transcript-")
                    && values?.isDirectory == true && values?.isSymbolicLink != true
            }
        let pending = stages.filter { staging in
            !fm.fileExists(atPath: staging.appendingPathComponent("committed").path)
                && transcriptFiles.allSatisfy { fm.fileExists(atPath: staging.appendingPathComponent("previous-" + $0).path) }
        }
        // Multiple abandoned attempts from older builds need manual recovery; retain every backup.
        guard pending.count <= 1 else { throw MeetingActionError.transcriptRecovery(pending[0]) }
        for staging in stages {
            if !fm.fileExists(atPath: staging.appendingPathComponent("committed").path) {
                let backups = transcriptFiles.map { staging.appendingPathComponent("previous-" + $0) }
                // No destination is changed until every backup has been written.
                guard backups.allSatisfy({ fm.fileExists(atPath: $0.path) }) else { continue }
                do {
                    let originals = try backups.map { try Data(contentsOf: $0) }
                    for (name, data) in zip(transcriptFiles, originals) {
                        try data.write(to: folder.appendingPathComponent(name), options: .atomic)
                    }
                } catch {
                    throw MeetingActionError.transcriptRecovery(staging)
                }
            }
            // Treat cleanup failure as pending recovery, so a later edit cannot be rolled back.
            do { try fm.removeItem(at: staging) }
            catch { throw MeetingActionError.transcriptRecovery(staging) }
        }
    }

    static func speechSettings(in folder: URL) -> SpeechSettings? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("metadata.json")) else { return nil }
        guard var settings = (try? decoder.decode(MeetingManifest.self, from: data))?.speechSettings else { return nil }
        // Meetings saved before Parakeet became the default recorded no engine; Whisper transcribed them.
        settings.engine = settings.engine ?? .whisper
        return settings
    }

    private static func hasMedia(in folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: recordingURL(in: folder).path)
    }

    static func recordingURL(in folder: URL) -> URL {
        let filename = ["recording.mp4", "recording.mov", "audio.m4a"].first {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
        } ?? "recording.mp4"
        return folder.appendingPathComponent(filename)
    }

    // A folder without media holds nothing recoverable; drop it after a failed start.
    static func removeFolderWithoutMedia(_ folder: URL) -> Bool {
        guard !hasMedia(in: folder) else { return false }
        return (try? FileManager.default.removeItem(at: folder)) != nil
    }

    static func meeting(in folder: URL) -> MeetingHistoryItem? {
        transcriptLock.lock()
        defer { transcriptLock.unlock() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let values = try? folder.resourceValues(forKeys: [.isDirectoryKey, .creationDateKey])
        guard values?.isDirectory == true else { return nil }
        var recoveryFolder: URL?
        do { try recoverTranscript(in: folder) }
        catch MeetingActionError.transcriptRecovery(let backup) { recoveryFolder = backup }
        catch { recoveryFolder = folder }

        let metadataURL = folder.appendingPathComponent("metadata.json")
        let manifest = (try? Data(contentsOf: metadataURL)).flatMap {
            try? decoder.decode(MeetingManifest.self, from: $0)
        }
        let hasTranscripts = ["transcript.md", "transcript.json"].allSatisfy {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
        let complete = recoveryFolder == nil && manifest != nil && manifest?.transcriptionComplete != false && hasTranscripts
        guard complete || hasMedia(in: folder) || recoveryFolder != nil else { return nil }

        let nameParts = folder.lastPathComponent.components(separatedBy: " — ")

        return MeetingHistoryItem(
            title: manifest?.title ?? (nameParts.count > 1 ? nameParts.dropFirst().joined(separator: " — ") : folder.lastPathComponent),
            recordedAt: manifest?.recordedAt ?? folderDateFormatter.date(from: nameParts[0]) ?? values?.creationDate ?? .distantPast,
            duration: manifest?.duration ?? 0,
            folderURL: folder,
            needsTranscription: !complete,
            titleWasProvided: manifest?.titleWasProvided ?? true,
            totalBytes: LocalTranscriber.sizeOnDisk(of: folder),
            recoveryFolder: recoveryFolder
        )
    }

    static func transcriptMarkdown(
        title: String,
        recordedAt: Date,
        duration: TimeInterval,
        segments: [TranscriptSegment],
        recordingFilename: String = "recording.mp4"
    ) -> String {
        let date = DateFormatter.localizedString(from: recordedAt, dateStyle: .long, timeStyle: .short)
        var lines = [
            "# \(title)",
            "",
            "- Recorded: \(date)",
            "- Duration: \(Timecode.string(duration))",
            "- Recording: [\(recordingFilename)](\(recordingFilename))",
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

    /// Only filesystem names are shortened; saved titles are not length-limited.
    static func sanitizedTitle(_ title: String) -> String {
        String(normalizedTitle(title).prefix(80))
    }

    private static func normalizedTitle(_ title: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\n\r\t")
        let parts = title.components(separatedBy: invalid)
        let collapsed = parts
            .joined(separator: " ")
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
        return collapsed.isEmpty ? "Meeting" : collapsed
    }

    private static func resolvedTitle(_ title: String, recordedAt: Date) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? folderDateFormatter.string(from: recordedAt) : normalizedTitle(title)
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
    /// "4:05" under an hour and "1:02:33" after, for clocks that tick.
    static func compact(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        return Duration.seconds(seconds).formatted(.time(pattern: seconds < 3_600 ? .minuteSecond : .hourMinuteSecond))
    }

    /// "34 sec", "12 min", or "1 hr, 5 min", for meeting lengths in lists.
    static func readable(_ interval: TimeInterval, locale: Locale = .autoupdatingCurrent) -> String {
        let seconds = max(0, Int(interval.rounded(.down)))
        let duration = Duration.seconds(seconds)
        return seconds < 60
            ? duration.formatted(.units(allowed: [.seconds], width: .abbreviated).locale(locale))
            : duration.formatted(.units(allowed: [.hours, .minutes], width: .abbreviated, fractionalPart: .hide(rounded: .down)).locale(locale))
    }

    static func string(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded(.down)))
        return Duration.seconds(seconds).formatted(
            .time(pattern: .hourMinuteSecond(padHourToLength: 2)).locale(Locale(identifier: "en_US_POSIX"))
        )
    }
}
