import AppKit
import UserNotifications
import XCTest
@testable import BetterMeetingApp

final class MeetingActionTests: XCTestCase {
    @MainActor
    func testRetranscriptionPreservesSavedFilesOnCancellationAndFailure() async throws {
        let suite = "BetterMeetingReplace.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let fm = FileManager.default
        defaults.set(root, forKey: "outputFolder")
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? fm.removeItem(at: root)
        }
        let folder = try MeetingArtifacts.createDirectory(in: root, title: "Keep this title", recordedAt: Date())
        try MeetingArtifacts.write(title: "Keep this title", recordedAt: Date(), duration: 12, segments: [], titleWasProvided: false, to: folder)
        try "# Keep this title\n\nEdited notes".write(to: folder.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        let names = ["transcript.md", "transcript.json", "metadata.json"]
        let original = try names.map { try Data(contentsOf: folder.appendingPathComponent($0)) }
        let model = AppModel(defaults: defaults)
        await model.historyRefreshTask?.value
        let item = try XCTUnwrap(model.transcriptionHistory.first)
        model.retryTranscription(item)
        XCTAssertTrue(model.canCancelTranscription)
        model.cancelTranscription()
        await model.processingTask?.value
        XCTAssertEqual(model.state, .idle)
        XCTAssertFalse(model.canCancelTranscription)
        XCTAssertEqual(model.completionMessage, "Re-transcription cancelled. Your existing transcript is unchanged.")
        XCTAssertEqual(try names.map { try Data(contentsOf: folder.appendingPathComponent($0)) }, original)
        // Missing source media must fail without marking the saved transcript unfinished.
        model.retryTranscription(item)
        XCTAssertNil(model.completionMessage, "A new attempt must clear the cancellation notice")
        await model.processingTask?.value
        XCTAssertEqual(model.state, .failed)
        XCTAssertEqual(model.primaryButtonTitle, "Retry transcription")
        XCTAssertEqual(model.primaryButtonSymbol, "arrow.clockwise")
        model.primaryAction()
        XCTAssertEqual(model.state, .processing, "Retry must use saved media, not start a new recording")
        await model.processingTask?.value
        XCTAssertEqual(model.state, .failed)
        XCTAssertEqual(try names.map { try Data(contentsOf: folder.appendingPathComponent($0)) }, original)
        XCTAssertFalse(try XCTUnwrap(model.transcriptionHistory.first).needsTranscription)

        let segments = [TranscriptSegment(start: 0, end: 1, text: "Replacement", language: "en")]
        let json = folder.appendingPathComponent("transcript.json")
        try fm.setAttributes([.immutable: true], ofItemAtPath: json.path)
        defer { try? fm.setAttributes([.immutable: false], ofItemAtPath: json.path) }
        XCTAssertThrowsError(try MeetingArtifacts.replaceTranscript(for: item, duration: 12, segments: segments))
        XCTAssertEqual(try names.map { try Data(contentsOf: folder.appendingPathComponent($0)) }, original)
        try fm.setAttributes([.immutable: false], ofItemAtPath: json.path)
        try MeetingArtifacts.replaceTranscript(for: item, duration: 12, segments: segments)
        XCTAssertTrue(try String(contentsOf: folder.appendingPathComponent("transcript.md"), encoding: .utf8).contains("Replacement"))
        let updated = try XCTUnwrap(MeetingArtifacts.meetings(in: root).first)
        XCTAssertEqual(updated.title, item.title)
        XCTAssertFalse(updated.titleWasProvided)
        XCTAssertFalse(try fm.contentsOfDirectory(atPath: folder.path).contains { $0.hasPrefix(".transcript-") })
    }

    func testRenamePreservesMeetingContents() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let date = Date(timeIntervalSince1970: 1_788_530_400)
        let folder = try MeetingArtifacts.createDirectory(in: root, title: "Original", recordedAt: date)
        try MeetingArtifacts.write(title: "Original", recordedAt: date, duration: 20, segments: [], to: folder)
        let body = "\r\n\r\nMy edited transcript.\r\n[recording.mp4](recording.mp4)\r\n"
        try ("# Original" + body).write(to: folder.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        let media = Data("recording data".utf8)
        try media.write(to: folder.appendingPathComponent("recording.mp4"))
        let transcriptJSON = try Data(contentsOf: folder.appendingPathComponent("transcript.json"))
        let metadataURL = folder.appendingPathComponent("metadata.json")
        var metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any])
        metadata["customField"] = "Keep this"
        try JSONSerialization.data(withJSONObject: metadata).write(to: metadataURL)
        let item = try XCTUnwrap(MeetingArtifacts.meetings(in: root).first)
        _ = try MeetingArtifacts.createDirectory(in: root, title: "Pricing Review", recordedAt: date)

        let renamed = try MeetingArtifacts.renameMeeting(item, to: " Pricing / Review ")

        XCTAssertTrue(renamed.lastPathComponent.hasSuffix(" — Pricing Review 2"))
        XCTAssertEqual(try String(contentsOf: renamed.appendingPathComponent("transcript.md"), encoding: .utf8), "# Pricing Review" + body)
        XCTAssertEqual(try Data(contentsOf: renamed.appendingPathComponent("recording.mp4")), media)
        XCTAssertEqual(try Data(contentsOf: renamed.appendingPathComponent("transcript.json")), transcriptJSON)
        let updated = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: renamed.appendingPathComponent("metadata.json"))) as? [String: Any])
        XCTAssertEqual(updated["title"] as? String, "Pricing Review")
        XCTAssertEqual(updated["titleWasProvided"] as? Bool, true)
        XCTAssertEqual(updated["customField"] as? String, "Keep this")
    }

    func testNotificationFollowsRenamedFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let date = Date()
        let folder = try MeetingArtifacts.createDirectory(in: root, title: "Original", recordedAt: date)
        let notification = try MeetingNotifications.content(title: "Original", folder: folder, failed: false)
        let renamed = try MeetingArtifacts.renameDirectory(folder, title: "New name", recordedAt: date)
        XCTAssertEqual(notification.title, "Transcript ready")
        XCTAssertEqual(notification.body, "Original")
        XCTAssertEqual(MeetingNotifications.folder(from: notification)?.resolvingSymlinksInPath().path,
                       renamed.resolvingSymlinksInPath().path)
        let failure = try MeetingNotifications.content(title: "", folder: renamed, failed: true)
        XCTAssertEqual(failure.title, "Transcription needs attention")
        XCTAssertEqual(failure.body, renamed.lastPathComponent)
        XCTAssertNil(MeetingNotifications.folder(from: UNMutableNotificationContent()))
    }

    func testFailedRenameRestoresOriginalFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fm = FileManager.default
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            try? fm.removeItem(at: root)
        }
        let date = Date()
        let folder = try MeetingArtifacts.createDirectory(in: root, title: "Original", recordedAt: date)
        try MeetingArtifacts.write(title: "Original", recordedAt: date, duration: 0, segments: [], to: folder)
        let item = try XCTUnwrap(MeetingArtifacts.meetings(in: root).first)
        let markdown = try Data(contentsOf: folder.appendingPathComponent("transcript.md"))
        let metadata = try Data(contentsOf: folder.appendingPathComponent("metadata.json"))
        XCTAssertThrowsError(try MeetingArtifacts.renameMeeting(item, to: " \n "))
        // File edits remain possible, but moving the folder must fail.
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        XCTAssertThrowsError(try MeetingArtifacts.renameMeeting(item, to: "New name"))
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("transcript.md")), markdown)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("metadata.json")), metadata)
    }

    @MainActor
    func testCopyUsesSavedMarkdownAndKeepsClipboardOnReadFailure() async throws {
        let suite = "BetterMeetingActions.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defaults.set(root, forKey: "outputFolder")
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            pasteboard.releaseGlobally()
            try? FileManager.default.removeItem(at: root)
        }
        let date = Date()
        let folder = try MeetingArtifacts.createDirectory(in: root, title: "Copy me", recordedAt: date)
        try MeetingArtifacts.write(title: "Copy me", recordedAt: date, duration: 0, segments: [], to: folder)
        let model = AppModel(defaults: defaults)
        await model.historyRefreshTask?.value
        let item = try XCTUnwrap(model.transcriptionHistory.first)
        let markdownURL = folder.appendingPathComponent("transcript.md")
        let text = "# My notes\n\nAn edited transcript.\n"
        try text.write(to: markdownURL, atomically: true, encoding: .utf8)
        try model.copyTranscript(item, to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), text)
        try FileManager.default.removeItem(at: markdownURL)
        XCTAssertThrowsError(try model.copyTranscript(item, to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), text)
    }
}
