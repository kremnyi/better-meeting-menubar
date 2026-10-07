import AppKit
import AVFoundation
import SwiftUI
import XCTest
@testable import BetterMeetingApp

@MainActor
final class TranscriptionQueueTests: XCTestCase {
    func testStopRecordingWaitsForCaptureBeforeProcessingOrRestart() async throws {
        let (defaults, suite, root) = try makeTempDefaults("CaptureStopQueue")
        defer { removeTempDefaults(defaults, suite: suite, root: root) }
        let date = Date()
        let folder = try MeetingArtifacts.createDirectory(in: root, title: "Still saving", recordedAt: date)
        let recording = folder.appendingPathComponent("recording.mp4")
        let bytes = Data([1, 2, 3])
        try bytes.write(to: recording)
        let settings = SpeechSettings(engine: .whisper, speakerLabels: false)
        let source = root.appendingPathComponent("sample.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600))
        buffer.frameLength = buffer.frameCapacity
        try XCTUnwrap(buffer.floatChannelData)[0].update(repeating: 0, count: Int(buffer.frameLength))
        do { let file = try AVAudioFile(forWriting: source, settings: format.settings); try file.write(from: buffer) }
        let audio = folder.appendingPathComponent("audio.m4a")
        try await AudioExtractor.extract(from: source, to: audio) { _ in }
        _ = try await TranscriptionPasses.run(audioURL: audio, languages: ["en"], settings: settings, progressHandler: { _ in }) { _, _ in
            [ScoredSegment(start: 0, end: 0.1, text: "The recording finished saving.", lang: "en", score: -0.1, nospeech: 0)]
        }
        let model = AppModel(defaults: defaults)
        model.speechSettings = settings
        model.transcriptionLanguages = ["en"]
        model.meetingTitle = "Still saving"
        model.activeFolder = folder
        model.recordingDidStart(at: date)
        let stopping = expectation(description: "capture stop requested")
        var finishStop: CheckedContinuation<Void, Never>?
        model.stopCapture = {
            await withCheckedContinuation { continuation in
                finishStop = continuation
                stopping.fulfill()
            }
        }
        model.primaryAction()
        XCTAssertEqual(model.state, .stopping)
        XCTAssertTrue(model.isCapturing)
        XCTAssertTrue(model.updates.isBusy())
        model.startRecording()
        XCTAssertEqual(model.state, .stopping)
        let processing = try XCTUnwrap(model.processingTask)
        await fulfillment(of: [stopping], timeout: 5)
        XCTAssertEqual(model.processingPhase, .finalizingRecording)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("transcript.md").path),
                       "Transcription must wait until capture finishes")
        XCTAssertFalse(model.canCancelTranscription, "Saving capture must finish before processing can be cancelled")
        try XCTUnwrap(finishStop).resume()
        await processing.value
        XCTAssertEqual(model.state, .idle)
        XCTAssertFalse(model.isProcessing)
        XCTAssertEqual(try Data(contentsOf: recording), bytes)
        XCTAssertFalse(try XCTUnwrap(MeetingArtifacts.meeting(in: folder)).needsTranscription)
    }

    private func withMeetings(
        count: Int = 3, _ check: (AppModel) async throws -> Void
    ) async throws {
        let (defaults, suite, root) = try makeTempDefaults("BetterMeetingQueue")
        defer { removeTempDefaults(defaults, suite: suite, root: root) }
        for index in 0...count {
            let date = Date(timeIntervalSince1970: 1_788_530_400 - Double(index * 3_600))
            let folder = try MeetingArtifacts.createDirectory(in: root, title: "Meeting \(index)", recordedAt: date)
            try Data([1]).write(to: folder.appendingPathComponent("audio.m4a"))
            if index == count {
                try MeetingArtifacts.write(title: "Completed meeting", recordedAt: date, duration: 60, segments: [], to: folder)
            }
        }
        let model = AppModel(defaults: defaults)
        await model.historyRefreshTask?.value
        try await check(model)
    }

    func testQueueRunsInOrderAndExcludesCompletedMeetings() async throws {
        try await withMeetings { model in
            var announcements: [String] = []
            model.accessibilityAnnouncement = { announcements.append($0) }
            model.prepareSpeechModel { _ in }
            try await model.modelPreparationTask?.value
            let expected = model.unfinishedRecordings
            var visited: [MeetingHistoryItem] = []
            var active = 0
            model.transcribeAllRecordings { item in
                active += 1
                XCTAssertEqual(active, 1)
                XCTAssertEqual(model.transcriptionBatchIndex, visited.count + 1)
                XCTAssertEqual(model.transcriptionBatchWaiting, 2 - visited.count)
                XCTAssertEqual(model.processingTitle, item.title)
                XCTAssertEqual(model.processingFolder, item.folderURL)
                XCTAssertEqual(model.queuedFolders, expected.dropFirst(visited.count + 1).map(\.folderURL),
                               "The list marks the meetings still waiting")
                XCTAssertNil(model.modelUnloadTask, "A running queue keeps the speech model loaded")
                XCTAssertTrue(model.isProcessing)
                XCTAssertTrue(model.updates.isBusy())
                model.transcribeAllRecordings { _ in XCTFail("No overlapping batch"); return false }
                await Task.yield()
                visited.append(item)
                active -= 1
                return true
            }
            let task = try XCTUnwrap(model.processingTask)
            await task.value
            XCTAssertEqual(visited, expected)
            XCTAssertEqual(model.completionMessage, "Transcribed 3 of 3 recordings.")
            XCTAssertTrue(announcements.contains("Transcribed 3 of 3 recordings."))
            XCTAssertTrue(model.queuedFolders.isEmpty)
            XCTAssertNotNil(model.modelUnloadTask, "A finished queue schedules releasing the speech model")
            XCTAssertFalse(model.isTranscribingBatch)
            XCTAssertEqual(model.state, .idle)
            XCTAssertNil(model.processingTask)
            model.refreshHistory()
            await model.historyRefreshTask?.value
            model.meetingTitle = "Next meeting"
            XCTAssertEqual(model.completionMessage, "Transcribed 3 of 3 recordings.")
            for scheme: ColorScheme in [.light, .dark] {
                try render(model, name: "completion-\(scheme)", scheme: scheme)
            }
            model.recordingDidStart(at: Date())
            XCTAssertNil(model.completionMessage)
            model.fail(AppError.missingRecording) // Stop the synthetic recording timer; no capture was started.
        }
    }

    func testProcessingLeavesALiveRecordingAlone() async throws {
        try await withMeetings { model in
            var release: CheckedContinuation<Void, Never>?
            model.transcribeAllRecordings { _ in
                await withCheckedContinuation { release = $0 }
                return false
            }
            for _ in 0..<100 where release == nil {
                await Task.yield()
            }
            XCTAssertNotNil(release)
            XCTAssertTrue(model.isProcessing)
            XCTAssertEqual(model.state, .idle, "A recording can start while processing runs")

            model.meetingTitle = "Back-to-back meeting"
            model.recordingDidStart(at: Date())
            XCTAssertEqual(model.state, .recording)

            release?.resume()
            await model.processingTask?.value
            XCTAssertEqual(model.state, .recording, "Processing must not end a live recording")
            XCTAssertEqual(model.meetingTitle, "Back-to-back meeting", "Processing must not clear the capture fields")
            XCTAssertFalse(model.isProcessing)
            model.fail(AppError.missingRecording) // Stop the synthetic recording timer; no capture was started.
        }
    }

    func testCancellationStopsBeforeNextMeetingAndKeepsFiles() async throws {
        try await withMeetings { model in
            let folders = model.unfinishedRecordings.map(\.folderURL)
            var visited = 0
            model.transcribeAllRecordings { _ in
                visited += 1
                model.cancelTranscription()
                XCTAssertTrue(Task.isCancelled)
                return true // Only the cancellation check may stop the queue here.
            }
            await model.processingTask?.value
            XCTAssertEqual(visited, 1)
            XCTAssertEqual(model.state, .idle)
            XCTAssertFalse(model.isTranscribingBatch)
            XCTAssertFalse(model.cancellingTranscription)
            XCTAssertTrue(model.completionMessage?.contains("1 of 3 finished") == true)
            for folder in folders {
                XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("audio.m4a")), Data([1]))
            }
            model.transcribeAllRecordings { _ in XCTFail("Pre-start cancellation must not process"); return false }
            let task = try XCTUnwrap(model.processingTask)
            model.cancelTranscription()
            await task.value
            XCTAssertEqual(model.state, .idle)
        }
    }

    func testFailureStopsQueueAndLeavesSingleRetryAvailable() async throws {
        try await withMeetings { model in
            // The fixture audio is unreadable and there is no recording.mp4, so the first meeting fails for real.
            let first = try XCTUnwrap(model.unfinishedRecordings.first)
            XCTAssertEqual(model.needsAttention, model.captureAccessNeedsAttention,
                           "Recordings waiting for transcription are not a problem to flag in the menu bar")
            model.transcribeAllRecordings()
            await model.processingTask?.value
            XCTAssertEqual(model.completedFolder, first.folderURL, "The queue must stop at the first failed meeting")
            XCTAssertEqual(model.unfinishedRecordings.count, 3)
            XCTAssertEqual(model.state, .idle, "A failed transcription must leave Start recording available")
            XCTAssertFalse(model.isTranscribingBatch)
            XCTAssertEqual(model.primaryButtonTitle, "Start recording")
            XCTAssertEqual(model.failedTranscriptionMeeting?.folderURL, first.folderURL)
            XCTAssertTrue(model.needsAttention, "A failed transcription flags the menu-bar icon")
            XCTAssertNil(model.processingTask)
        }
    }

    func testRecordingQueueFailureKeepsRenamedRetryTarget() async throws {
        let (defaults, suite, root) = try makeTempDefaults("RecordingQueueFailure")
        defer { removeTempDefaults(defaults, suite: suite, root: root) }
        let date = Date()
        let settings = SpeechSettings(engine: .whisper, speakerLabels: false)
        let first = try MeetingArtifacts.createDirectory(in: root, title: "First meeting", recordedAt: date)
        let second = try MeetingArtifacts.createDirectory(in: root, title: "Old name", recordedAt: date)
        let source = root.appendingPathComponent("sample.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600))
        buffer.frameLength = buffer.frameCapacity
        try XCTUnwrap(buffer.floatChannelData)[0].update(repeating: 0, count: Int(buffer.frameLength))
        do { let file = try AVAudioFile(forWriting: source, settings: format.settings); try file.write(from: buffer) }
        for folder in [first, second] {
            let audio = folder.appendingPathComponent("audio.m4a")
            try await AudioExtractor.extract(from: source, to: audio) { _ in }
            // Cache ordinary Whisper results so the production queue needs no model download.
            _ = try await TranscriptionPasses.run(audioURL: audio, languages: ["en"], settings: settings, progressHandler: { _ in }) { _, _ in
                [ScoredSegment(start: 0, end: 0.1,
                               text: "Microsoft discussed the product launch. Microsoft will prepare the product launch. We will review the product launch next week.",
                               lang: "en", score: -0.1, nospeech: 0)]
            }
        }
        // A real filesystem error occurs only after the second job has renamed its folder.
        try FileManager.default.createDirectory(at: second.appendingPathComponent("transcript.json"), withIntermediateDirectories: false)
        let model = AppModel(defaults: defaults)
        await model.historyRefreshTask?.value
        model.enqueue(ProcessingRun(folder: first, recordedAt: date, title: "First meeting", titleWasProvided: true,
                                    replacing: nil, languages: ["en"], hints: "", settings: settings))
        model.enqueue(ProcessingRun(folder: second, recordedAt: date, title: "Renamed meeting", titleWasProvided: true,
                                    replacing: nil, languages: ["en"], hints: "", settings: settings, folderTitle: "Old name"))
        await model.processingTask?.value
        await model.historyRefreshTask?.value
        let renamed = try XCTUnwrap(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasSuffix(" — Renamed meeting") })
        XCTAssertEqual(model.completedFolder?.standardizedFileURL, renamed.standardizedFileURL)
        XCTAssertEqual(model.failedTranscriptionMeeting?.folderURL.standardizedFileURL, renamed.standardizedFileURL)
        XCTAssertEqual(model.failedTranscriptionFolders, [renamed.standardizedFileURL])
        XCTAssertFalse(try XCTUnwrap(MeetingArtifacts.meeting(in: first)).needsTranscription,
                       "A later job's failure must not mark the successful meeting failed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
        model.retryFailedTranscription()
        await model.processingTask?.value
        XCTAssertEqual(model.completedFolder?.standardizedFileURL, renamed.standardizedFileURL, "Retry must use the failed job's actual folder")

        // Once saving is unblocked, the batch must keep the folder's new automatic name too.
        try FileManager.default.removeItem(at: renamed.appendingPathComponent("transcript.json"))
        try MeetingArtifacts.writeMetadata(title: "Renamed meeting", recordedAt: date, duration: 0.1,
                                           titleWasProvided: false, speechSettings: settings, to: renamed)
        model.transcriptionLanguages = ["en"]
        model.refreshHistory()
        await model.historyRefreshTask?.value
        model.transcribeAllRecordings()
        await model.processingTask?.value
        await model.historyRefreshTask?.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: renamed.path), "The unnamed meeting must receive an automatic title")
        let finished = try XCTUnwrap(model.transcriptionHistory.first { $0.folderURL.standardizedFileURL != first.standardizedFileURL })
        XCTAssertFalse(finished.needsTranscription)
        XCTAssertEqual(model.completedFolder?.standardizedFileURL, finished.folderURL.standardizedFileURL)
    }

    /// A recording stopped during a batch waits behind it; cancelling the batch must not leave the
    /// recording's own job unable to report progress or be cancelled.
    func testRecordingStoppedDuringACancelledBatchRunsAsItsOwnCancellableJob() async throws {
        try await withMeetings { model in
            let batchFolder = try XCTUnwrap(model.unfinishedRecordings.first).folderURL
            var release: CheckedContinuation<Bool, Never>?
            model.transcribeAllRecordings { _ in await withCheckedContinuation { release = $0 } }
            for _ in 0..<100 where release == nil { await Task.yield() }
            let batch = try XCTUnwrap(model.processingTask)
            let recording = try MeetingArtifacts.createDirectory(in: model.outputRoot, title: "Stopped meanwhile", recordedAt: Date())
            model.activeFolder = recording
            model.recordingDidStart(at: Date())
            var finishStop: CheckedContinuation<Void, Never>?
            model.stopCapture = { await withCheckedContinuation { finishStop = $0 } }
            model.primaryAction()
            XCTAssertEqual(model.processingFolder, batchFolder, "Stopping a recording must not take the running meeting's marker")
            XCTAssertEqual(model.queuedFolders.last, recording, "The stopped recording waits behind the batch")

            model.cancelTranscription()
            try XCTUnwrap(release).resume(returning: true)
            await batch.value
            let queue = try XCTUnwrap(model.processingTask, "The stopped recording still runs after the batch is cancelled")
            XCTAssertFalse(model.cancellingTranscription, "The batch's cancellation must not carry over to the next job")
            XCTAssertTrue(model.canCancelTranscription)
            XCTAssertNotEqual(model.processingStatusText, "Cancelling transcription…")

            model.cancelTranscription()
            for _ in 0..<100 where finishStop == nil { await Task.yield() }
            try XCTUnwrap(finishStop).resume()
            await queue.value
            XCTAssertEqual(model.state, .idle)
            XCTAssertFalse(model.isProcessing)
            XCTAssertEqual(model.completedFolder, recording, "Only the second cancellation stops the recording's job")
            XCTAssertTrue(FileManager.default.fileExists(atPath: recording.path))
        }
    }

    /// A capture failure while another meeting transcribes belongs to the recording, not the running job.
    func testCaptureFailureDuringProcessingFlagsTheRecordingNotTheRunningMeeting() async throws {
        try await withMeetings { model in
            let batchFolder = try XCTUnwrap(model.unfinishedRecordings.first).folderURL
            var release: CheckedContinuation<Bool, Never>?
            model.transcribeAllRecordings { _ in await withCheckedContinuation { release = $0 } }
            for _ in 0..<100 where release == nil { await Task.yield() }
            let recording = try MeetingArtifacts.createDirectory(in: model.outputRoot, title: "Capture failed", recordedAt: Date())
            try Data([1]).write(to: recording.appendingPathComponent("audio.m4a"))
            model.activeFolder = recording
            model.recordingDidStart(at: Date())
            model.stopCapture = { throw URLError(.cannotWriteToFile) }
            let failed = expectation(description: "stop failure shown")
            let observation = model.$state.sink { if $0 == .failed { failed.fulfill() } }
            defer { observation.cancel() }
            model.cancelRecording(confirm: { _ in .alertSecondButtonReturn }, trash: { _ in XCTFail("A failed stop keeps the recording") })
            await fulfillment(of: [failed], timeout: 5)
            XCTAssertEqual(model.completedFolder, recording)
            XCTAssertEqual(model.failedTranscriptionFolders, [recording.standardizedFileURL],
                           "The meeting still transcribing must not be marked failed")
            XCTAssertEqual(model.processingFolder, batchFolder)

            try XCTUnwrap(release).resume(returning: false)
            await model.processingTask?.value
            XCTAssertFalse(model.isProcessing)
            XCTAssertEqual(model.failedTranscriptionFolders, [recording.standardizedFileURL])
        }
    }

    /// A retry keeps the engine its meeting was saved with, so it must not wait on a download for another engine.
    func testTranscriptionDoesNotWaitForAnotherEnginesDownload() async throws {
        let (defaults, suite, root) = try makeTempDefaults("OtherEngineDownload")
        defer { removeTempDefaults(defaults, suite: suite, root: root) }
        let date = Date()
        let whisper = SpeechSettings(engine: .whisper, speakerLabels: false)
        let folder = try MeetingArtifacts.createDirectory(in: root, title: "Whisper meeting", recordedAt: date)
        let source = root.appendingPathComponent("sample.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600))
        buffer.frameLength = buffer.frameCapacity
        try XCTUnwrap(buffer.floatChannelData)[0].update(repeating: 0, count: Int(buffer.frameLength))
        do { let file = try AVAudioFile(forWriting: source, settings: format.settings); try file.write(from: buffer) }
        let audio = folder.appendingPathComponent("audio.m4a")
        try await AudioExtractor.extract(from: source, to: audio) { _ in }
        // Cache ordinary Whisper results so the queue needs no Whisper model.
        _ = try await TranscriptionPasses.run(audioURL: audio, languages: ["en"], settings: whisper, progressHandler: { _ in }) { _, _ in
            [ScoredSegment(start: 0, end: 0.1, text: "Whisper finished.", lang: "en", score: -0.1, nospeech: 0)]
        }
        let model = AppModel(defaults: defaults)
        await model.historyRefreshTask?.value
        model.speechSettings = SpeechSettings(engine: .parakeet, speakerLabels: false)
        var finishDownload: CheckedContinuation<Void, Never>?
        model.prepareSpeechModel { _ in await withCheckedContinuation { finishDownload = $0 } }
        let preparation = try XCTUnwrap(model.modelPreparationTask)

        model.enqueue(ProcessingRun(folder: folder, recordedAt: date, title: "Whisper meeting", titleWasProvided: true,
                                    replacing: nil, languages: ["en"], hints: "", settings: whisper))
        let queue = try XCTUnwrap(model.processingTask)
        let finished = expectation(description: "Whisper transcription finished")
        Task { await queue.value; finished.fulfill() }
        await fulfillment(of: [finished], timeout: 10)
        let saved = MeetingArtifacts.meeting(in: folder)
        XCTAssertNotNil(model.modelPreparationTask, "The Parakeet download keeps going")
        for _ in 0..<100 where finishDownload == nil { await Task.yield() }
        finishDownload?.resume()
        try await preparation.value
        await queue.value
        XCTAssertEqual(saved?.needsTranscription, false)
    }

    func testEmptyQueueAndNativeQueueLayouts() async throws {
        _ = NSApplication.shared
        try await withMeetings(count: 0) { model in
            XCTAssertNil(model.completionMessage, "A new app model starts without a previous session's status")
            model.transcribeAllRecordings { _ in XCTFail("No unfinished meetings"); return false }
            XCTAssertNil(model.processingTask)
            XCTAssertFalse(model.isTranscribingBatch)
        }
        try await withMeetings(count: 31) { model in
            model.prepareSpeechModel { _ in }
            try await model.modelPreparationTask?.value
            for scheme: ColorScheme in [.light, .dark] {
                try render(model, name: "queue-idle-\(scheme)", scheme: scheme)
            }
            model.transcribeAllRecordings { _ in
                for scheme: ColorScheme in [.light, .dark] {
                    do { try self.render(model, name: "queue-processing-\(scheme)", scheme: scheme) }
                    catch { XCTFail("Queue preview failed: \(error)") }
                }
                model.cancelTranscription()
                return false
            }
            await model.processingTask?.value
        }
    }

    private func render(_ model: AppModel, name: String, scheme: ColorScheme) throws {
        let view = hostingView(MenuBarControlView(), model: model, scheme: scheme)
        XCTAssertEqual(view.fittingSize.width, 304)
        XCTAssertLessThan(view.fittingSize.height, 700)
        try writePanelPreview(view, name: name)
    }
}
