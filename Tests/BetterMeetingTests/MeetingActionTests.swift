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
    func testInterruptedTranscriptReplacementRecoversBeforeHistoryLoads() async throws {
        let fm = FileManager.default
        for committed in [false, true] {
            let (defaults, suite, root) = try makeTempDefaults("TranscriptRecovery")
            defer { removeTempDefaults(defaults, suite: suite, root: root) }
            let date = Date()
            let folder = try MeetingArtifacts.createDirectory(in: root, title: "Saved meeting", recordedAt: date)
            try MeetingArtifacts.write(title: "Saved meeting", recordedAt: date, duration: 12,
                                       segments: [TranscriptSegment(start: 0, end: 1, text: "Original", language: "en")], to: folder)
            try "# Saved meeting\n\nManual edits".write(to: folder.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
            let names = ["transcript.md", "transcript.json", "metadata.json"]
            let originals = try names.map { try Data(contentsOf: folder.appendingPathComponent($0)) }
            let stale = try XCTUnwrap(MeetingArtifacts.meeting(in: folder))
            let library = MeetingLibrary()
            let staging = folder.appendingPathComponent(".transcript-interrupted")
            try fm.createDirectory(at: staging, withIntermediateDirectories: false)
            for (name, data) in zip(names, originals) {
                try data.write(to: staging.appendingPathComponent("previous-" + name))
            }
            if committed {
                try MeetingArtifacts.write(title: "Saved meeting", recordedAt: date, duration: 20,
                                           segments: [TranscriptSegment(start: 0, end: 1, text: "New result", language: "en")], to: folder)
                try Data().write(to: staging.appendingPathComponent("committed"))
            } else {
                try "Partial replacement".write(to: folder.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
                // A blocked restore must keep backups and must not be reported as complete.
                let blockedFile = folder.appendingPathComponent("transcript.md")
                try fm.setAttributes([.immutable: true], ofItemAtPath: blockedFile.path)
                defer { try? fm.setAttributes([.immutable: false], ofItemAtPath: blockedFile.path) }
                // Settled stamps let the library cache the blocked result; fixing permissions
                // changes neither stamp, so recovery must be retried rather than using that cache.
                let settled = Date().addingTimeInterval(-10)
                try fm.setAttributes([.modificationDate: settled], ofItemAtPath: folder.appendingPathComponent("metadata.json").path)
                try fm.setAttributes([.modificationDate: settled], ofItemAtPath: folder.path)
                let blocked = try XCTUnwrap(library.meetings(in: root).first)
                XCTAssertTrue(blocked.needsTranscription)
                XCTAssertEqual(blocked.recoveryFolder?.resolvingSymlinksInPath().path, staging.resolvingSymlinksInPath().path)
                XCTAssertTrue(MeetingHistorySection.rowHelp(blocked).contains("could not be restored"))
                let model = AppModel(defaults: defaults)
                await model.historyRefreshTask?.value
                for scheme: ColorScheme in [.light, .dark] {
                    let view = hostingView(MenuBarControlView(), model: model, scheme: scheme)
                    XCTAssertEqual(view.fittingSize.width, 304, "Recovery controls must fit the menu")
                }
                model.retryTranscription(blocked)
                XCTAssertNil(model.processing.task, "Recovery-blocked meetings cannot start transcription")
                XCTAssertNotNil(model.errorMessage)
                model.transcribeAllRecordings()
                XCTAssertNil(model.processing.task, "Bulk transcription must exclude recovery-blocked meetings")
                let unchanged = try names.map { try Data(contentsOf: folder.appendingPathComponent($0)) }
                // A job enqueued with stale history must also stop before reading media or writing files.
                model.processing.enqueue(ProcessingRun(folder: folder, recordedAt: date, title: stale.title,
                                            titleWasProvided: true, replacing: stale, languages: ["en"], hints: "",
                                            settings: SpeechSettings(engine: .whisper)))
                await model.processing.task?.value
                await model.historyRefreshTask?.value
                XCTAssertTrue(try XCTUnwrap(model.errorMessage).contains("could not be restored"))
                XCTAssertEqual(try names.map { try Data(contentsOf: folder.appendingPathComponent($0)) }, unchanged)
                XCTAssertTrue(fm.fileExists(atPath: staging.appendingPathComponent("previous-transcript.md").path))
                try fm.setAttributes([.immutable: false], ofItemAtPath: blockedFile.path)
                XCTAssertNil(try XCTUnwrap(library.meetings(in: root).first).recoveryFolder,
                             "Cached recovery failures must be retried after permissions are fixed")
                model.retryTranscriptRecovery(blocked)
                await model.historyRefreshTask?.value
                XCTAssertNil(model.errorMessage)
                XCTAssertNil(try XCTUnwrap(model.transcriptionHistory.first).recoveryFolder)
            }
            let item = try XCTUnwrap(library.meetings(in: root).first)
            XCTAssertFalse(item.needsTranscription)
            if committed {
                XCTAssertEqual(item.duration, 20)
                XCTAssertTrue(try String(contentsOf: folder.appendingPathComponent("transcript.md")).contains("New result"))
            } else {
                XCTAssertEqual(try names.map { try Data(contentsOf: folder.appendingPathComponent($0)) }, originals,
                               "Recovery must restore the whole saved set, including manual edits")
            }
            XCTAssertFalse(fm.fileExists(atPath: staging.path))
        }
    }

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
        await model.processing.task?.value
        XCTAssertEqual(model.state, .idle)
        XCTAssertFalse(model.canCancelTranscription)
        XCTAssertEqual(model.completionMessage, "Re-transcription cancelled. Your existing transcript is unchanged.")
        XCTAssertEqual(try names.map { try Data(contentsOf: folder.appendingPathComponent($0)) }, original)
        // Missing source media must fail without marking the saved transcript unfinished.
        model.retryTranscription(item)
        XCTAssertNil(model.completionMessage, "A new attempt must clear the cancellation notice")
        await model.processing.task?.value
        XCTAssertEqual(model.state, .idle, "A failed transcription must not take the place of Start recording")
        XCTAssertEqual(model.primaryButtonTitle, "Start recording")
        XCTAssertEqual(model.failedTranscriptionMeeting?.title, item.title)
        XCTAssertEqual(model.failureTitle, "Couldn’t transcribe “\(item.title)”")
        model.retryFailedTranscription()
        XCTAssertTrue(model.isProcessing, "Retry must use saved media, not start a new recording")
        await model.processing.task?.value
        XCTAssertEqual(model.state, .idle)
        XCTAssertNotNil(model.failedTranscriptionMeeting)
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
        let updated = try XCTUnwrap(MeetingLibrary().meetings(in: root).first)
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
        let item = try XCTUnwrap(MeetingLibrary().meetings(in: root).first)
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

        for legacy in [false, true] {
            let pending = root.appendingPathComponent(legacy ? "Legacy capture" : "Pending capture")
            try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: false)
            try media.write(to: pending.appendingPathComponent("recording.mp4"))
            if !legacy {
                try MeetingArtifacts.writeMetadata(title: "Pending capture", recordedAt: date, duration: 8, to: pending)
            }
            let unfinished = try XCTUnwrap(MeetingArtifacts.meeting(in: pending))
            let renamedPending = try MeetingArtifacts.renameMeeting(unfinished, to: "Named before transcription")
            let reloaded = try XCTUnwrap(MeetingArtifacts.meeting(in: renamedPending))
            XCTAssertEqual(reloaded.title, "Named before transcription")
            XCTAssertTrue(reloaded.needsTranscription)
            XCTAssertTrue(reloaded.titleWasProvided)
            XCTAssertEqual(try Data(contentsOf: renamedPending.appendingPathComponent("recording.mp4")), media)
            XCTAssertFalse(FileManager.default.fileExists(atPath: renamedPending.appendingPathComponent("transcript.md").path))
        }
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
        model.recording.didStart(at: Date())
        let request = MeetingNotifications.audioWarning(recordingID: try XCTUnwrap(model.recordingID))
        XCTAssertEqual(request.content.title, "Check your recording")
        XCTAssertNil(MeetingNotifications.folder(from: request.content))
        model.recording.checkAudio(elapsed: 30, audioDetected: false)
        XCTAssertTrue(delegate.shouldPresentAudioWarning(request))
        model.recording.checkDiskSpace(RecordingDiskSpace(availableBytes: 1_000_000_000))
        let disk = MeetingNotifications.diskWarning(recordingID: try XCTUnwrap(model.recordingID), message: "Low space")
        XCTAssertTrue(delegate.shouldPresentDiskWarning(disk))
        delegate.openNotification(request)
        XCTAssertEqual(clicks.count, 1, "A click must activate the existing native menu button")
        let view = hostingView(MenuBarControlView(), model: model)
        window.contentView = view
        XCTAssertTrue(model.menuWindow === window, "The menu must track its own native window")
        window.orderFront(nil)
        XCTAssertTrue(window.isVisible)
        XCTAssertFalse(delegate.shouldPresentAudioWarning(request), "The open menu already shows the warning")
        XCTAssertFalse(delegate.shouldPresentDiskWarning(disk))
        delegate.openNotification(request)
        XCTAssertEqual(clicks.count, 1, "Clicking with the menu open must not toggle it closed")
        window.orderOut(nil)
        model.recording.checkAudio(elapsed: 31, audioDetected: true)
        XCTAssertFalse(delegate.shouldPresentAudioWarning(request))
        model.recording.didStart(at: Date())
        model.recording.checkAudio(elapsed: 30, audioDetected: false)
        XCTAssertFalse(delegate.shouldPresentAudioWarning(request))
        delegate.openNotification(request)
        XCTAssertEqual(clicks.count, 1, "Old notifications must not open a later recording")
        XCTAssertFalse(delegate.shouldPresentDiskWarning(disk))
        delegate.openNotification(disk)
        XCTAssertEqual(clicks.count, 1, "Old disk warnings must not open a later recording")
        model.recording.checkDiskSpace(RecordingDiskSpace(availableBytes: 1_000_000_000))
        let currentDisk = MeetingNotifications.diskWarning(recordingID: try XCTUnwrap(model.recordingID), message: "Low space")
        delegate.openNotification(currentDisk)
        XCTAssertEqual(clicks.count, 2)
        model.recording.checkDiskSpace(RecordingDiskSpace(availableBytes: 3_000_000_000))
        XCTAssertFalse(delegate.shouldPresentDiskWarning(currentDisk))
        let current = MeetingNotifications.audioWarning(recordingID: try XCTUnwrap(model.recordingID))
        model.fail(AppError.missingRecording)
        delegate.openNotification(current)
        delegate.openNotification(currentDisk)
        XCTAssertEqual(clicks.count, 2, "Stopped recordings must ignore late clicks")
    }

    func testFailedRenameRestoresOriginalFiles() throws {
        let root = makeTempRoot()
        let fm = FileManager.default
        defer { removeTempRoot(root) }
        let date = Date()
        let folder = try MeetingArtifacts.createDirectory(in: root, title: "Original", recordedAt: date)
        try MeetingArtifacts.write(title: "Original", recordedAt: date, duration: 0, segments: [], to: folder)
        let item = try XCTUnwrap(MeetingLibrary().meetings(in: root).first)
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
    func testCopyUsesSavedMarkdownAndKeepsClipboardOnReadFailure() throws {
        let (defaults, suite, root) = try makeTempDefaults("BetterMeetingActions")
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(suite))
        defer {
            removeTempDefaults(defaults, suite: suite, root: root)
            pasteboard.releaseGlobally()
        }
        let date = Date()
        let folder = try MeetingArtifacts.createDirectory(in: root, title: "Copy me", recordedAt: date)
        let markdownURL = folder.appendingPathComponent("transcript.md")
        let text = "# My notes\n\nAn edited transcript.\n"
        try text.write(to: markdownURL, atomically: true, encoding: .utf8)
        try AppModel.copyTranscript(in: folder, to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), text)
        try FileManager.default.removeItem(at: markdownURL)
        XCTAssertThrowsError(try AppModel.copyTranscript(in: folder, to: pasteboard))
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
    func testCancelRecordingTrashesOnlyTheActiveRecordingAfterConfirmation() async throws {
        let (defaults, suite, root) = try makeTempDefaults("BetterMeetingCancel")
        defer { removeTempDefaults(defaults, suite: suite, root: root) }
        let date = Date()
        let kept = try MeetingArtifacts.createDirectory(in: root, title: "Earlier meeting", recordedAt: date)
        try MeetingArtifacts.write(title: "Earlier meeting", recordedAt: date, duration: 60, segments: [], to: kept)
        let active = try MeetingArtifacts.createDirectory(in: root, title: "Nobody came", recordedAt: date)
        let model = AppModel(defaults: defaults)
        model.recording.activeFolder = active
        model.recording.didStart(at: date)
        let stopping = expectation(description: "capture stop requested")
        var finishStop: CheckedContinuation<Void, Never>?
        model.recording.stopCapture = {
            await withCheckedContinuation { continuation in
                finishStop = continuation
                stopping.fulfill()
            }
        }
        var trashed: [URL] = []
        let done = expectation(description: "trashed")
        // Tests must not fill the real Trash; removing the folder stands in for it.
        let trash: (URL) throws -> Void = { url in
            trashed.append(url)
            try FileManager.default.removeItem(at: url)
            done.fulfill()
        }

        model.recording.cancel(confirm: { _ in .alertFirstButtonReturn }, trash: trash)
        XCTAssertEqual(model.state, .recording, "Keep recording must leave the recording running")
        XCTAssertTrue(trashed.isEmpty)

        model.recording.cancel(confirm: { _ in .alertSecondButtonReturn }, trash: trash)
        XCTAssertEqual(model.state, .stopping)
        model.primaryAction()
        model.startRecording()
        XCTAssertEqual(model.state, .stopping, "Capture shutdown must finish before another recording can start")
        XCTAssertTrue(model.fileSettingsLocked)
        XCTAssertTrue(model.updates.isBusy())
        XCTAssertEqual(model.terminationReply(confirm: { _ in .alertFirstButtonReturn }), .terminateCancel)
        var quitRequests = 0
        model.completeTermination(true) { quitRequests += 1 }
        XCTAssertEqual(quitRequests, 1, "Quit while stopping must wait for completion")
        model.completeTermination(false) // Keep the test runner open after checking deferred quit.
        await fulfillment(of: [stopping], timeout: 5)
        XCTAssertTrue(trashed.isEmpty, "Do not trash a recording that capture still owns")
        XCTAssertTrue(FileManager.default.fileExists(atPath: active.path))
        try XCTUnwrap(finishStop).resume()
        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(model.state, .idle)
        XCTAssertEqual(trashed, [active])
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path), "Other meetings must stay")
        XCTAssertFalse(model.isProcessing, "A canceled recording must not be transcribed")

        // A failed stop keeps the original files and reports the failure instead of trashing them.
        model.recording.activeFolder = kept
        model.recording.didStart(at: date)
        model.recording.stopCapture = { throw URLError(.cannotWriteToFile) }
        let failed = expectation(description: "stop failure shown")
        let observation = model.recording.$state.sink { if $0 == .failed { failed.fulfill() } }
        defer { observation.cancel() }
        model.recording.cancel(confirm: { _ in .alertSecondButtonReturn }, trash: trash)
        await fulfillment(of: [failed], timeout: 5)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(trashed, [active])
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
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
        XCTAssertEqual(items.prefix(3).map { MeetingHistorySection.dayTitle($0.recordedAt, now: now, calendar: calendar) },
                       ["Today", "Today", "Yesterday"])
    }

    func testLibraryReusesUnchangedFoldersAndRereadsEditedOnes() throws {
        let root = makeTempRoot()
        defer { removeTempRoot(root) }
        let date = Date(timeIntervalSince1970: 1_788_530_400)
        let folder = try MeetingArtifacts.createDirectory(in: root, title: "Alpha", recordedAt: date)
        try MeetingArtifacts.write(title: "Alpha", recordedAt: date, duration: 60, segments: [], to: folder)
        let metadata = folder.appendingPathComponent("metadata.json")
        let transcript = folder.appendingPathComponent("transcript.md")
        // The library only keeps entries whose files are more than a couple of seconds old.
        let past = Date().addingTimeInterval(-3_600)
        func settle() throws {
            for url in [metadata, transcript, folder] {
                try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: url.path)
            }
        }
        try settle()
        let library = MeetingLibrary()
        let meetings = try library.meetings(in: root)
        XCTAssertEqual(meetings.map(\.title), ["Alpha"])
        XCTAssertTrue(library.search(meetings, query: "pricing").isEmpty)

        // Same size and date: the parsed folder is reused, so this in-place edit stays unseen.
        let edited = try String(contentsOf: metadata, encoding: .utf8).replacingOccurrences(of: "Alpha", with: "Omega")
        try edited.write(to: metadata, atomically: false, encoding: .utf8)
        try settle()
        XCTAssertEqual(try library.meetings(in: root).map(\.title), ["Alpha"])
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: metadata.path)
        XCTAssertEqual(try library.meetings(in: root).map(\.title), ["Omega"], "A changed date reads the folder again")

        try "# Alpha\n\nPricing notes\n".write(to: transcript, atomically: false, encoding: .utf8)
        XCTAssertEqual(library.search(meetings, query: "pricing"), meetings, "An edited transcript is searched again")
        XCTAssertEqual(MeetingLibrary().search(meetings, query: "pricing"), meetings)
    }
}
