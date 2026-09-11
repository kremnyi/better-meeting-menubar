import AppKit
import SwiftUI
import XCTest
@testable import BetterMeetingApp

@MainActor
final class TranscriptionQueueTests: XCTestCase {
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
            let expected = model.unfinishedRecordings
            var visited: [MeetingHistoryItem] = []
            var active = 0
            model.transcribeAllRecordings { item in
                active += 1
                XCTAssertEqual(active, 1)
                XCTAssertEqual(model.transcriptionBatchIndex, visited.count + 1)
                XCTAssertEqual(model.transcriptionBatchWaiting, 2 - visited.count)
                XCTAssertEqual(model.processingTitle, item.title)
                XCTAssertTrue(model.isProcessing)
                XCTAssertTrue(model.updates.meetingInProgress)
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
                return false
            }
            await model.processingTask?.value
            XCTAssertEqual(visited, 1)
            XCTAssertEqual(model.state, .idle)
            XCTAssertFalse(model.isTranscribingBatch)
            XCTAssertFalse(model.cancellingTranscription)
            XCTAssertTrue(model.completionMessage?.contains("0 of 3 finished") == true)
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
            var visited = 0
            model.transcribeAllRecordings { _ in
                visited += 1
                model.fail(AppError.missingRecording)
                return false
            }
            await model.processingTask?.value
            XCTAssertEqual(visited, 1)
            XCTAssertEqual(model.state, .failed)
            XCTAssertFalse(model.isTranscribingBatch)
            XCTAssertEqual(model.primaryButtonTitle, "Retry transcription")
            XCTAssertNil(model.processingTask)
        }
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
        let view = NSHostingView(rootView: MenuBarControlView()
            .environmentObject(model).environmentObject(model.updates)
            .environment(\.colorScheme, scheme)
            .background(Color(nsColor: .windowBackgroundColor)))
        view.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.fittingSize.width, 304)
        XCTAssertLessThan(view.fittingSize.height, 700)
        guard let path = ProcessInfo.processInfo.environment["BETTER_MEETING_PANELS_PREVIEW_PATH"] else { return }
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let output = URL(fileURLWithPath: path).appendingPathComponent("\(name).png")
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output)
    }
}
