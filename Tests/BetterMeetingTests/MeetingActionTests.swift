import AppKit
import SwiftUI
import UserNotifications
import XCTest
@testable import BetterMeetingApp

@MainActor
private final class NotificationMenuClicks: NSObject {
    var count = 0
    @objc func click() { count += 1 }
}

final class MeetingActionTests: XCTestCase {
    @MainActor
    func testRetranscriptionPreservesSavedFilesOnCancellationAndFailure() async throws {
        let (defaults, suite, root) = try makeTempDefaults("BetterMeetingReplace")
        let fm = FileManager.default
        defer { removeTempDefaults(defaults, suite: suite, root: root) }
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
        XCTAssertTrue(model.isProcessing, "Retry must use saved media, not start a new recording")
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

    func testFailedStartDropsOnlyFoldersWithoutMedia() throws {
        let root = makeTempRoot()
        let fm = FileManager.default
        defer { removeTempRoot(root) }
        for name in ["recording.mp4", "audio.m4a"] {
            let folder = try MeetingArtifacts.createDirectory(in: root, title: name, recordedAt: Date())
            try Data([1]).write(to: folder.appendingPathComponent(name))
            XCTAssertFalse(MeetingArtifacts.removeFolderWithoutMedia(folder))
            XCTAssertTrue(fm.fileExists(atPath: folder.path), "Saved media must survive a failed start")
        }
        let empty = try MeetingArtifacts.createDirectory(in: root, title: "Never started", recordedAt: Date())
        XCTAssertTrue(MeetingArtifacts.removeFolderWithoutMedia(empty))
        XCTAssertFalse(fm.fileExists(atPath: empty.path))

        let locked = try MeetingArtifacts.createDirectory(in: root, title: "Locked", recordedAt: Date())
        try fm.setAttributes([.immutable: true], ofItemAtPath: locked.path)
        defer { try? fm.setAttributes([.immutable: false], ofItemAtPath: locked.path) }
        XCTAssertFalse(MeetingArtifacts.removeFolderWithoutMedia(locked),
                       "A folder that survives deletion must not report success")
        XCTAssertTrue(fm.fileExists(atPath: locked.path))
        try fm.setAttributes([.immutable: false], ofItemAtPath: locked.path)
        XCTAssertTrue(MeetingArtifacts.removeFolderWithoutMedia(locked))
    }

    func testRenamePreservesMeetingContents() throws {
        let root = makeTempRoot()
        defer { removeTempRoot(root) }
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
        let root = makeTempRoot()
        defer { removeTempRoot(root) }
        let date = Date()
        let folder = try MeetingArtifacts.createDirectory(in: root, title: "Original", recordedAt: date)
        let notification = try MeetingNotifications.content(title: "Original", folder: folder, failed: false)
        let renamed = try MeetingArtifacts.renameDirectory(folder, title: "New name", recordedAt: date)
        XCTAssertEqual(notification.title, "Transcript ready")
        XCTAssertEqual(notification.body, "Original")
        XCTAssertEqual(notification.categoryIdentifier, MeetingNotifications.transcriptReadyCategory)
        XCTAssertEqual(MeetingNotifications.transcriptReady.actions.map(\.title),
                       ["Open Transcript", "Copy Transcript", "Show in Finder"])
        XCTAssertEqual(MeetingNotifications.folder(from: notification)?.resolvingSymlinksInPath().path,
                       renamed.resolvingSymlinksInPath().path)
        let failure = try MeetingNotifications.content(title: "", folder: renamed, failed: true)
        XCTAssertEqual(failure.title, "Transcription needs attention")
        XCTAssertEqual(failure.body, renamed.lastPathComponent)
        XCTAssertEqual(failure.categoryIdentifier, "", "A failure opens the folder and offers no transcript actions")
        XCTAssertNil(MeetingNotifications.folder(from: UNMutableNotificationContent()))
    }

    @MainActor
    func testAudioWarningNotificationOpensControlsAndIgnoresStaleRecordings() throws {
        _ = NSApplication.shared
        let (defaults, suite, root) = try makeTempDefaults("BetterMeetingAudioNotification")
        let model = AppModel(defaults: defaults)
        let delegate = AppDelegate()
        delegate.model = model
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let clicks = NotificationMenuClicks()
        item.button?.target = clicks
        item.button?.action = #selector(NotificationMenuClicks.click)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 304, height: 300),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.alphaValue = 0
        defer {
            window.orderOut(nil)
            NSStatusBar.system.removeStatusItem(item)
            model.fail(AppError.missingRecording)
            removeTempDefaults(defaults, suite: suite, root: root)
        }
        model.recordingDidStart(at: Date())
        let request = MeetingNotifications.audioWarning(recordingID: try XCTUnwrap(model.recordingID))
        XCTAssertEqual(request.content.title, "Check your recording")
        XCTAssertNil(MeetingNotifications.folder(from: request.content))
        model.checkRecordingAudio(elapsed: 30, audioDetected: false)
        XCTAssertTrue(delegate.shouldPresentAudioWarning(request))
        delegate.openNotification(request)
        XCTAssertEqual(clicks.count, 1, "A click must activate the existing native menu button")
        let view = hostingView(MenuBarControlView(), model: model)
        window.contentView = view
        XCTAssertTrue(model.menuWindow === window, "The menu must track its own native window")
        window.orderFront(nil)
        XCTAssertTrue(window.isVisible)
        XCTAssertFalse(delegate.shouldPresentAudioWarning(request), "The open menu already shows the warning")
        delegate.openNotification(request)
        XCTAssertEqual(clicks.count, 1, "Clicking with the menu open must not toggle it closed")
        window.orderOut(nil)
        model.checkRecordingAudio(elapsed: 31, audioDetected: true)
        XCTAssertFalse(delegate.shouldPresentAudioWarning(request))
        model.recordingDidStart(at: Date())
        model.checkRecordingAudio(elapsed: 30, audioDetected: false)
        XCTAssertFalse(delegate.shouldPresentAudioWarning(request))
        delegate.openNotification(request)
        XCTAssertEqual(clicks.count, 1, "Old notifications must not open a later recording")
        let current = MeetingNotifications.audioWarning(recordingID: try XCTUnwrap(model.recordingID))
        model.fail(AppError.missingRecording)
        delegate.openNotification(current)
        XCTAssertEqual(clicks.count, 1, "Stopped recordings must ignore late clicks")
    }

    func testFailedRenameRestoresOriginalFiles() throws {
        let root = makeTempRoot()
        let fm = FileManager.default
        defer { removeTempRoot(root) }
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
        let (defaults, suite, root) = try makeTempDefaults("BetterMeetingActions")
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(suite))
        defer {
            removeTempDefaults(defaults, suite: suite, root: root)
            pasteboard.releaseGlobally()
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

    @MainActor
    func testMoveToTrashRemovesTheMeetingFromTheList() async throws {
        let (defaults, suite, root) = try makeTempDefaults("BetterMeetingTrash")
        defer { removeTempDefaults(defaults, suite: suite, root: root) }
        let date = Date()
        for title in ["Keep me", "Trash me"] {
            let folder = try MeetingArtifacts.createDirectory(in: root, title: title, recordedAt: date)
            try MeetingArtifacts.write(title: title, recordedAt: date, duration: 60, segments: [], to: folder)
        }
        let model = AppModel(defaults: defaults)
        await model.historyRefreshTask?.value
        let item = try XCTUnwrap(model.transcriptionHistory.first { $0.title == "Trash me" })
        var trashed: [URL] = []
        // Tests must not fill the real Trash; removing the folder stands in for it.
        model.moveMeetingToTrash(item) { url in
            trashed.append(url)
            try FileManager.default.removeItem(at: url)
        }
        await model.historyRefreshTask?.value
        XCTAssertEqual(trashed, [item.folderURL])
        XCTAssertEqual(model.transcriptionHistory.map(\.title), ["Keep me"])
        XCTAssertEqual(model.completionMessage, "Moved “Trash me” to the Trash.")
    }

    @MainActor
    func testListTimesAndDayGroupsReadNaturally() throws {
        XCTAssertEqual(Timecode.compact(0), "0:00")
        XCTAssertEqual(Timecode.compact(245), "4:05")
        XCTAssertEqual(Timecode.compact(3_753), "1:02:33")
        let english = Locale(identifier: "en_US")
        XCTAssertEqual(Timecode.readable(34, locale: english), "34 sec")
        XCTAssertEqual(Timecode.readable(779, locale: english), "12 min")
        XCTAssertEqual(Timecode.readable(3_600, locale: english), "1 hr")
        XCTAssertEqual(Timecode.readable(3_934, locale: english), "1 hr, 5 min")

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let dates = ISO8601DateFormatter()
        let now = try XCTUnwrap(dates.date(from: "2026-09-15T12:00:00Z"))
        let items = try ["2026-09-15T09:00:00Z", "2026-09-15T08:00:00Z", "2026-09-14T17:00:00Z", "2026-09-04T14:00:00Z"]
            .map { iso in
                MeetingHistoryItem(title: iso, recordedAt: try XCTUnwrap(dates.date(from: iso)), duration: 60,
                                   folderURL: URL(fileURLWithPath: "/tmp/\(iso)"), needsTranscription: false, titleWasProvided: true)
            }
        let groups = MenuBarControlView.dayGroups(items, calendar: calendar)
        XCTAssertEqual(groups.map(\.items.count), [2, 1, 1])
        XCTAssertEqual(groups.prefix(2).map { MenuBarControlView.dayTitle($0.day, now: now, calendar: calendar) },
                       ["Today", "Yesterday"])
    }
}
