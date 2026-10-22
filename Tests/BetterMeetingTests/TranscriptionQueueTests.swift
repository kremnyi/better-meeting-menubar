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
        try await cacheEnglishTranscript(in: folder, settings: settings, text: "The recording finished saving.")
        let model = AppModel(defaults: defaults)
        model.speechSettings = settings
        model.transcriptionLanguages = ["en"]
        model.meetingTitle = "Still saving"
        model.recording.activeFolder = folder
        model.recording.didStart(at: date)
        let stopping = expectation(description: "capture stop requested")
        var finishStop: CheckedContinuation<Void, Never>?
        model.recording.stopCapture = {
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
        let processing = try XCTUnwrap(model.processing.task)
        await fulfillment(of: [stopping], timeout: 5)
        XCTAssertEqual(model.processing.phase, .finalizingRecording)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("transcript.md").path),
                       "Transcription must wait until capture finishes")
        XCTAssertFalse(model.processing.canCancel, "Saving capture must finish before processing can be cancelled")
        try XCTUnwrap(finishStop).resume()
        await processing.value
        XCTAssertEqual(model.state, .idle)
        XCTAssertFalse(model.processing.isProcessing)
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
                XCTAssertEqual(model.processing.batchIndex, visited.count + 1)
                XCTAssertEqual(model.transcriptionBatchWaiting, 2 - visited.count)
                XCTAssertEqual(model.processing.title, item.title)
                XCTAssertEqual(model.processing.folder, item.folderURL)
                XCTAssertEqual(model.processing.queuedFolders, expected.dropFirst(visited.count + 1).map(\.folderURL),
                               "The list marks the meetings still waiting")
                XCTAssertNil(model.modelUnloadTask, "A running queue keeps the speech model loaded")
                XCTAssertTrue(model.processing.isProcessing)
                XCTAssertTrue(model.updates.isBusy())
                model.transcribeAllRecordings { _ in XCTFail("No overlapping batch"); return false }
                await Task.yield()
                visited.append(item)
                active -= 1
                return true
            }
            let task = try XCTUnwrap(model.processing.task)
            await task.value
            XCTAssertEqual(visited, expected)
            XCTAssertEqual(model.completionMessage, "Transcribed 3 of 3 recordings.")
            XCTAssertTrue(announcements.contains("Transcribed 3 of 3 recordings."))
            XCTAssertTrue(model.processing.queuedFolders.isEmpty)
            XCTAssertNotNil(model.modelUnloadTask, "A finished queue schedules releasing the speech model")
            XCTAssertEqual(model.state, .idle)
            model.refreshHistory()
            await model.historyRefreshTask?.value
            model.meetingTitle = "Next meeting"
            XCTAssertEqual(model.completionMessage, "Transcribed 3 of 3 recordings.")
            for scheme: ColorScheme in [.light, .dark] {
                try render(model, name: "completion-\(scheme)", scheme: scheme)
            }
            model.recording.didStart(at: Date())
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
            XCTAssertTrue(model.processing.isProcessing)
            XCTAssertEqual(model.state, .idle, "A recording can start while processing runs")

            model.meetingTitle = "Back-to-back meeting"
            model.recording.didStart(at: Date())

            release?.resume()
            await model.processing.task?.value
            XCTAssertEqual(model.state, .recording, "Processing must not end a live recording")
            XCTAssertEqual(model.meetingTitle, "Back-to-back meeting", "Processing must not clear the capture fields")
            XCTAssertFalse(model.processing.isProcessing)
            model.fail(AppError.missingRecording) // Stop the synthetic recording timer; no capture was started.
        }
    }

    func testCancellationStopsBeforeNextMeetingAndKeepsFiles() async throws {
        try await withMeetings { model in
            let folders = model.unfinishedRecordings.map(\.folderURL)
            var visited = 0
            var release: CheckedContinuation<Bool, Never>?
            var jobWasCancelled = false
            model.transcribeAllRecordings { _ in
                visited += 1
                guard visited == 1 else { return true }
                let processed = await withCheckedContinuation { release = $0 }
                jobWasCancelled = Task.isCancelled
                return processed
            }
            for _ in 0..<100 where release == nil { await Task.yield() }
            model.cancelTranscription()
            try XCTUnwrap(release).resume(returning: true)
            await model.processing.task?.value
            XCTAssertTrue(jobWasCancelled)
            XCTAssertEqual(visited, 1)
            XCTAssertEqual(model.state, .idle)
            XCTAssertFalse(model.isTranscribingBatch)
            XCTAssertFalse(model.processing.cancelling)
            XCTAssertTrue(model.completionMessage?.contains("1 of 3 finished") == true)
            for folder in folders {
                XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("audio.m4a")), Data([1]))
            }
            model.transcribeAllRecordings { _ in XCTFail("Pre-start cancellation must not process"); return false }
            let task = try XCTUnwrap(model.processing.task)
            var redrew = false
            let redraw = model.objectWillChange.sink { redrew = true }
            defer { redraw.cancel() }
            model.cancelTranscription()
            XCTAssertTrue(redrew, "The menu observes the model, so the queue's Cancelling… must reach it")
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
            await model.processing.task?.value
            XCTAssertEqual(model.completedFolder, first.folderURL, "The queue must stop at the first failed meeting")
            XCTAssertEqual(model.unfinishedRecordings.count, 3)
            XCTAssertEqual(model.state, .idle, "A failed transcription must leave Start recording available")
            XCTAssertFalse(model.isTranscribingBatch)
            XCTAssertEqual(model.failedTranscriptionMeeting?.folderURL, first.folderURL)
            XCTAssertTrue(model.needsAttention, "A failed transcription flags the menu-bar icon")
            XCTAssertNil(model.processing.task)
        }
    }

    func testRecordingQueueFailureKeepsRenamedRetryTarget() async throws {
        let (defaults, suite, root) = try makeTempDefaults("RecordingQueueFailure")
        defer { removeTempDefaults(defaults, suite: suite, root: root) }
        let date = Date()
        let settings = SpeechSettings(engine: .whisper, speakerLabels: false)
        let first = try MeetingArtifacts.createDirectory(in: root, title: "First meeting", recordedAt: date)
        let second = try MeetingArtifacts.createDirectory(in: root, title: "Old name", recordedAt: date)
        for folder in [first, second] {
            try await cacheEnglishTranscript(
                in: folder, settings: settings,
                text: "Microsoft discussed the product launch. Microsoft will prepare the product launch. We will review the product launch next week."
            )
        }
        // A real filesystem error occurs only after the second job has renamed its folder.
        try FileManager.default.createDirectory(at: second.appendingPathComponent("transcript.json"), withIntermediateDirectories: false)
        let model = AppModel(defaults: defaults)
        await model.historyRefreshTask?.value
        model.processing.enqueue(ProcessingRun(folder: first, recordedAt: date, title: "First meeting", titleWasProvided: true,
                                    replacing: nil, languages: ["en"], hints: "", settings: settings))
        model.processing.enqueue(ProcessingRun(folder: second, recordedAt: date, title: "Renamed meeting", titleWasProvided: true,
                                    replacing: nil, languages: ["en"], hints: "", settings: settings, folderTitle: "Old name"))
        await model.processing.task?.value
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
        await model.processing.task?.value
        XCTAssertEqual(model.completedFolder?.standardizedFileURL, renamed.standardizedFileURL, "Retry must use the failed job's actual folder")

        try FileManager.default.removeItem(at: renamed.appendingPathComponent("transcript.json"))
        try MeetingArtifacts.writeMetadata(title: "Renamed meeting", recordedAt: date, duration: 0.1,
                                           titleWasProvided: false, speechSettings: settings, to: renamed)
        model.transcriptionLanguages = ["en"]
        model.refreshHistory()
        await model.historyRefreshTask?.value
        model.transcribeAllRecordings()
        await model.processing.task?.value
        await model.historyRefreshTask?.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: renamed.path), "The unnamed meeting must receive an automatic title")
        let finished = try XCTUnwrap(model.transcriptionHistory.first { $0.folderURL.standardizedFileURL != first.standardizedFileURL })
        XCTAssertFalse(finished.needsTranscription)
        XCTAssertEqual(model.completedFolder?.standardizedFileURL, finished.folderURL.standardizedFileURL)
    }

    func testRecordingQueuedBehindAFailedJobStillRuns() async throws {
        let (defaults, suite, root) = try makeTempDefaults("QueueAfterFailure")
        defer { removeTempDefaults(defaults, suite: suite, root: root) }
        let date = Date()
        let settings = SpeechSettings(engine: .whisper, speakerLabels: false)
        // Unreadable audio and no recording, so the first job fails for real.
        let failing = try MeetingArtifacts.createDirectory(in: root, title: "Broken audio", recordedAt: date)
        try Data([1]).write(to: failing.appendingPathComponent("audio.m4a"))
        let queued = try MeetingArtifacts.createDirectory(in: root, title: "Untitled", recordedAt: date)
        try await cacheEnglishTranscript(in: queued, settings: settings, text: "We agreed on the budget.")
        let model = AppModel(defaults: defaults)
        await model.historyRefreshTask?.value
        model.quitWhenFinished = true
        let (stopped, finishStop) = AsyncStream<Void>.makeStream()
        model.processing.enqueue(ProcessingRun(folder: failing, recordedAt: date, title: "Broken audio", titleWasProvided: true,
                                    replacing: nil, languages: ["en"], hints: "", settings: settings))
        model.processing.enqueue(ProcessingRun(folder: queued, recordedAt: date, title: "Budget review", titleWasProvided: true,
                                    replacing: nil, languages: ["en"], hints: "", settings: settings,
                                    stopTask: Task<Void, Error> { for await _ in stopped {} }, folderTitle: "Untitled"))
        await model.processing.task?.value
        for _ in 0..<100 where model.processing.folder != queued { await Task.yield() }
        XCTAssertEqual(model.processing.folder, queued, "The recording behind the failed job must still run")
        XCTAssertEqual(model.failedTranscriptionMeeting?.folderURL.standardizedFileURL, failing.standardizedFileURL)
        XCTAssertFalse(model.quitWhenFinished, "Wait and quit must not quit once a job has failed")
        model.quitWhenFinished = false // A regression must not quit the test runner.

        finishStop.finish()
        await model.processing.task?.value
        await model.historyRefreshTask?.value
        let saved = try XCTUnwrap(model.completedFolder.flatMap { MeetingArtifacts.meeting(in: $0) })
        XCTAssertEqual(saved.title, "Budget review", "The name typed while recording must reach the meeting")
        XCTAssertFalse(saved.needsTranscription)
        XCTAssertNil(model.failedTranscriptionMeeting, "The failure panel must not name or retry the saved meeting")
        XCTAssertEqual(model.failedTranscriptionFolders, [failing.standardizedFileURL], "The failed meeting stays marked on its row")
    }

    func testRecordingStoppedDuringACancelledBatchRunsAsItsOwnCancellableJob() async throws {
        try await withMeetings { model in
            let batchFolder = try XCTUnwrap(model.unfinishedRecordings.first).folderURL
            var release: CheckedContinuation<Bool, Never>?
            model.transcribeAllRecordings { _ in await withCheckedContinuation { release = $0 } }
            for _ in 0..<100 where release == nil { await Task.yield() }
            let batch = try XCTUnwrap(model.processing.task)
            let recording = try MeetingArtifacts.createDirectory(in: model.outputRoot, title: "Stopped meanwhile", recordedAt: Date())
            model.recording.activeFolder = recording
            model.recording.didStart(at: Date())
            var finishStop: CheckedContinuation<Void, Never>?
            model.recording.stopCapture = { await withCheckedContinuation { finishStop = $0 } }
            model.primaryAction()
            XCTAssertEqual(model.processing.folder, batchFolder, "Stopping a recording must not take the running meeting's marker")
            XCTAssertEqual(model.processing.queuedFolders.last, recording, "The stopped recording waits behind the batch")

            model.cancelTranscription()
            try XCTUnwrap(release).resume(returning: true)
            await batch.value
            let queue = try XCTUnwrap(model.processing.task, "The stopped recording still runs after the batch is cancelled")
            XCTAssertFalse(model.processing.cancelling, "The batch's cancellation must not carry over to the next job")
            XCTAssertTrue(model.processing.canCancel)
            XCTAssertNotEqual(model.processing.statusText, "Cancelling transcription…")

            model.cancelTranscription()
            for _ in 0..<100 where finishStop == nil { await Task.yield() }
            try XCTUnwrap(finishStop).resume()
            await queue.value
            XCTAssertEqual(model.state, .idle)
            XCTAssertFalse(model.processing.isProcessing)
            XCTAssertEqual(model.completedFolder, recording, "Only the second cancellation stops the recording's job")
            XCTAssertTrue(FileManager.default.fileExists(atPath: recording.path))
        }
    }

    func testCaptureFailureDuringProcessingFlagsTheRecordingNotTheRunningMeeting() async throws {
        try await withMeetings { model in
            let batchFolder = try XCTUnwrap(model.unfinishedRecordings.first).folderURL
            var release: CheckedContinuation<Bool, Never>?
            model.transcribeAllRecordings { item in
                let processed = await withCheckedContinuation { release = $0 }
                // As finishRecording does, a saved meeting reports through transcriptSaved.
                if processed { model.transcriptSaved(in: item.folderURL) }
                return processed
            }
            for _ in 0..<100 where release == nil { await Task.yield() }
            let recording = try MeetingArtifacts.createDirectory(in: model.outputRoot, title: "Capture failed", recordedAt: Date())
            try Data([1]).write(to: recording.appendingPathComponent("audio.m4a"))
            model.recording.activeFolder = recording
            model.recording.didStart(at: Date())
            model.recording.stopCapture = { throw URLError(.cannotWriteToFile) }
            let failed = expectation(description: "stop failure shown")
            let observation = model.recording.$state.sink { if $0 == .failed { failed.fulfill() } }
            defer { observation.cancel() }
            model.recording.cancel(confirm: { _ in .alertSecondButtonReturn }, trash: { _ in XCTFail("A failed stop keeps the recording") })
            await fulfillment(of: [failed], timeout: 5)
            XCTAssertEqual(model.completedFolder, recording)
            XCTAssertEqual(model.failedTranscriptionFolders, [recording.standardizedFileURL],
                           "The meeting still transcribing must not be marked failed")
            XCTAssertEqual(model.processing.folder, batchFolder)

            let firstMeeting = try XCTUnwrap(release)
            release = nil
            firstMeeting.resume(returning: true)
            for _ in 0..<100 where release == nil { await Task.yield() }
            XCTAssertEqual(model.processing.batchIndex, 2)
            XCTAssertEqual(model.state, .failed, "A batch step must not clear a capture failure")
            XCTAssertNotNil(model.lastError)
            XCTAssertEqual(model.completedFolder, recording, "Retry must still target the failed recording, not the saved meeting")

            try XCTUnwrap(release).resume(returning: false)
            await model.processing.task?.value
            XCTAssertFalse(model.processing.isProcessing)
            XCTAssertEqual(model.failedTranscriptionFolders, [recording.standardizedFileURL])
        }
    }

    func testTranscriptionDoesNotWaitForAnotherEnginesDownload() async throws {
        let (defaults, suite, root) = try makeTempDefaults("OtherEngineDownload")
        defer { removeTempDefaults(defaults, suite: suite, root: root) }
        let date = Date()
        let whisper = SpeechSettings(engine: .whisper, speakerLabels: false)
        let folder = try MeetingArtifacts.createDirectory(in: root, title: "Whisper meeting", recordedAt: date)
        try await cacheEnglishTranscript(in: folder, settings: whisper, text: "Whisper finished.")
        let model = AppModel(defaults: defaults)
        await model.historyRefreshTask?.value
        model.speechSettings = SpeechSettings(engine: .parakeet, speakerLabels: false)
        var finishDownload: CheckedContinuation<Void, Never>?
        model.prepareSpeechModel { _ in await withCheckedContinuation { finishDownload = $0 } }
        let preparation = try XCTUnwrap(model.modelPreparationTask)

        model.processing.enqueue(ProcessingRun(folder: folder, recordedAt: date, title: "Whisper meeting", titleWasProvided: true,
                                    replacing: nil, languages: ["en"], hints: "", settings: whisper))
        let queue = try XCTUnwrap(model.processing.task)
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

    func testTranscriptionWaitsForAnOptionsDownloadOfItsModel() async throws {
        let (defaults, suite, root) = try makeTempDefaults("SameModelDownload")
        defer { removeTempDefaults(defaults, suite: suite, root: root) }
        let date = Date()
        let whisper = SpeechSettings(engine: .whisper, speakerLabels: false)
        let folder = try MeetingArtifacts.createDirectory(in: root, title: "Whisper meeting", recordedAt: date)
        try await cacheEnglishTranscript(in: folder, settings: whisper, text: "Whisper finished.")
        let model = AppModel(defaults: defaults)
        await model.historyRefreshTask?.value
        var finishDownload: CheckedContinuation<Void, Never>?
        let item = StoredModelInfo(title: "Whisper", kind: .whisper(whisper.model), url: root,
                                   installed: false, sizeBytes: 0, downloadBytes: 0)
        model.downloadStoredModel(item) { _ in
            await withCheckedContinuation { finishDownload = $0 }
            try Task.checkCancellation()
        }
        let download = try XCTUnwrap(model.modelDownloadTask)
        let waiting = expectation(description: "transcription waits for the download")
        waiting.assertForOverFulfill = false
        let observation = model.processing.$phase.sink { if $0 == .downloadingModel { waiting.fulfill() } }
        defer { observation.cancel() }

        let run = ProcessingRun(folder: folder, recordedAt: date, title: "Whisper meeting", titleWasProvided: true,
                                replacing: nil, languages: ["en"], hints: "", settings: whisper)
        model.processing.enqueue(run)
        let waitingJob = try XCTUnwrap(model.processing.task)
        await fulfillment(of: [waiting], timeout: 10)
        XCTAssertEqual(MeetingArtifacts.meeting(in: folder)?.needsTranscription, true, "The transcript must wait for the download")

        let cancelled = expectation(description: "the cancelled job ends before the download")
        Task { await waitingJob.value; cancelled.fulfill() }
        model.cancelTranscription()
        await fulfillment(of: [cancelled], timeout: 5)
        XCTAssertNotNil(model.modelDownloadTask)

        model.processing.enqueue(run)
        let queue = try XCTUnwrap(model.processing.task)
        for _ in 0..<100 where finishDownload == nil { await Task.yield() }
        try XCTUnwrap(finishDownload).resume()
        await download.value
        await queue.value
        XCTAssertNil(model.modelDownloadError, "Cancelling the transcription must not cancel the download")
        XCTAssertEqual(MeetingArtifacts.meeting(in: folder)?.needsTranscription, false)
    }

    func testRetrySetupDoesNotStartASecondDownloadWhileOptionsDownloads() async throws {
        let (defaults, suite, root) = try makeTempDefaults("RetryDuringDownload")
        defer { removeTempDefaults(defaults, suite: suite, root: root) }
        let model = AppModel(defaults: defaults)
        await model.historyRefreshTask?.value
        // A failed setup leaves the model unready, as on a Mac that has not downloaded it.
        model.prepareSpeechModel { _ in throw URLError(.notConnectedToInternet) }
        _ = try? await model.modelPreparationTask?.value
        XCTAssertFalse(model.modelReady)
        XCTAssertNil(model.modelPreparationTask)
        var finishDownload: CheckedContinuation<Void, Never>?
        let item = StoredModelInfo(title: "Whisper", kind: .whisper(model.speechSettings.model), url: root,
                                   installed: false, sizeBytes: 0, downloadBytes: 0)
        model.downloadStoredModel(item) { _ in await withCheckedContinuation { finishDownload = $0 } }
        let download = try XCTUnwrap(model.modelDownloadTask)
        defer { model.modelPreparationTask?.cancel() }

        model.prepareSpeechModel()
        XCTAssertNil(model.modelPreparationTask, "A running download already fetches the model")

        for _ in 0..<100 where finishDownload == nil { await Task.yield() }
        try XCTUnwrap(finishDownload).resume()
        await download.value
    }

    func testCancellingAnExportDoesNotCancelTheNextQueuedRecording() async throws {
        let (defaults, suite, root) = try makeTempDefaults("CancelExportQueue")
        defer { removeTempDefaults(defaults, suite: suite, root: root) }
        let date = Date()
        let settings = SpeechSettings(engine: .whisper, speakerLabels: false)
        var runs: [ProcessingRun] = []
        for name in ["First meeting", "Second meeting"] {
            let folder = try MeetingArtifacts.createDirectory(in: root, title: name, recordedAt: date)
            try await cacheEnglishTranscript(in: folder, settings: settings, text: "\(name) finished.")
            runs.append(ProcessingRun(folder: folder, recordedAt: date, title: name, titleWasProvided: true,
                                      replacing: nil, languages: ["en"], hints: "", settings: settings))
        }
        let model = AppModel(defaults: defaults)
        await model.historyRefreshTask?.value
        model.exportAfterRecording = true
        model.quitWhenFinished = true
        // Cancel once, from a new task, so the cancel lands after the first export has started.
        var cancelled = false
        var quitPendingForNextJob: Bool?
        let observation = model.processing.$phase.sink { phase in
            if cancelled, phase != nil, quitPendingForNextJob == nil, model.processing.title == "Second meeting" {
                quitPendingForNextJob = model.quitWhenFinished
                model.quitWhenFinished = false // Keep the test runner open.
            }
            guard phase == .extractingScreens, !cancelled else { return }
            cancelled = true
            Task { @MainActor in model.cancelTranscription() }
        }
        defer { observation.cancel() }

        model.processing.enqueue(runs[0])
        model.processing.enqueue(runs[1])
        while let task = model.processing.task { await task.value }

        XCTAssertTrue(cancelled)
        XCTAssertEqual(quitPendingForNextJob, true, "A cancelled export must not drop a pending Wait and quit")
        for run in runs {
            XCTAssertEqual(MeetingArtifacts.meeting(in: run.folder)?.needsTranscription, false,
                           "\(run.title) must be transcribed; cancelling an export keeps the transcript")
        }
        XCTAssertTrue(model.failedTranscriptionFolders.isEmpty)
    }

    func testEmptyQueueAndNativeQueueLayouts() async throws {
        _ = NSApplication.shared
        try await withMeetings(count: 0) { model in
            model.transcribeAllRecordings { _ in XCTFail("No unfinished meetings"); return false }
            XCTAssertNil(model.processing.task)
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
            await model.processing.task?.value
        }
    }

    private func render(_ model: AppModel, name: String, scheme: ColorScheme) throws {
        let view = hostingView(MenuBarControlView(), model: model, scheme: scheme)
        XCTAssertEqual(view.fittingSize.width, 304)
        XCTAssertLessThan(view.fittingSize.height, 700)
        try writePanelPreview(view, name: name)
    }
}
