import AppKit
import AVFoundation
import Combine
import CoreMedia
import Foundation
import ScreenCaptureKit
import SwiftUI
import XCTest
@testable import BetterMeetingApp

final class RecoveryTests: XCTestCase {
    func testUnfinishedAndLegacyRecordingsSurviveReload() throws {
        let root = makeTempRoot()
        defer { removeTempRoot(root) }
        let date = Date(timeIntervalSince1970: 1_788_530_400)
        let folder = try MeetingArtifacts.createDirectory(in: root, title: "Product / sync", recordedAt: date)
        XCTAssertTrue(MeetingArtifacts.meetings(in: root).isEmpty, "A failed start with no recording is not recoverable")
        try Data([1]).write(to: folder.appendingPathComponent("recording.mp4"))
        let pending = try XCTUnwrap(MeetingArtifacts.meetings(in: root).first)
        XCTAssertTrue(pending.needsTranscription)
        XCTAssertEqual(pending.title, "Product sync")
        XCTAssertEqual(pending.recordedAt, date)

        // A crash between transcript writes must not turn a pending meeting into a completed one.
        try "partial".write(to: folder.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        try "[]".write(to: folder.appendingPathComponent("transcript.json"), atomically: true, encoding: .utf8)
        XCTAssertTrue(try XCTUnwrap(MeetingArtifacts.meetings(in: root).first).needsTranscription)

        try MeetingArtifacts.write(title: pending.title, recordedAt: date, duration: 12, segments: [], to: folder)
        XCTAssertFalse(try XCTUnwrap(MeetingArtifacts.meetings(in: root).first).needsTranscription)

        // Completed metadata from earlier app versions has no completion flag.
        let metadataURL = folder.appendingPathComponent("metadata.json")
        var metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any])
        metadata.removeValue(forKey: "transcriptionComplete")
        metadata.removeValue(forKey: "titleWasProvided")
        try JSONSerialization.data(withJSONObject: metadata).write(to: metadataURL)
        XCTAssertFalse(try XCTUnwrap(MeetingArtifacts.meetings(in: root).first).needsTranscription)
        XCTAssertTrue(try XCTUnwrap(MeetingArtifacts.meetings(in: root).first).titleWasProvided)

        // Earlier failures wrote no metadata at all. Their raw recording is still discoverable.
        try FileManager.default.removeItem(at: metadataURL)
        let legacy = try XCTUnwrap(MeetingArtifacts.meetings(in: root).first)
        XCTAssertTrue(legacy.needsTranscription)
        XCTAssertEqual(legacy.title, "Product sync")
        XCTAssertEqual(legacy.recordedAt, date)
    }

    func testFailedExportKeepsExistingAudio() async throws {
        let root = makeTempRoot()
        defer { removeTempRoot(root) }
        let audioURL = root.appendingPathComponent("audio.m4a")
        let original = Data("saved meeting audio".utf8)
        try original.write(to: audioURL)
        let corruptURL = root.appendingPathComponent("corrupt.mp4")
        try Data("incomplete recording".utf8).write(to: corruptURL)
        for recordingURL in [root.appendingPathComponent("missing.mp4"), corruptURL] {
            do {
                try await AudioExtractor.extract(from: recordingURL, to: audioURL) { _ in
                    XCTFail("Invalid recordings must be rejected before export starts")
                }
                XCTFail("Exporting an invalid recording must fail")
            } catch {
                XCTAssertEqual(try Data(contentsOf: audioURL), original)
            }
        }
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path)
            .contains { $0.hasPrefix(".audio-") })
    }

    func testSuccessfulExportReplacesExistingAudio() async throws {
        let root = makeTempRoot()
        defer { removeTempRoot(root) }
        let sourceURL = root.appendingPathComponent("source.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800))
        buffer.frameLength = buffer.frameCapacity
        try XCTUnwrap(buffer.floatChannelData)[0].update(repeating: 0, count: Int(buffer.frameLength))
        do {
            let source = try AVAudioFile(forWriting: sourceURL, settings: format.settings)
            try source.write(from: buffer)
        }
        let audioURL = root.appendingPathComponent("audio.m4a")
        try Data("previous audio".utf8).write(to: audioURL)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await AudioExtractor.extract(from: sourceURL, to: audioURL) { _ in }
        }
        if case .success = await cancelled.result { XCTFail("Cancelled export must not replace saved audio") }
        XCTAssertEqual(try Data(contentsOf: audioURL), Data("previous audio".utf8))
        try await AudioExtractor.extract(from: sourceURL, to: audioURL) { _ in }
        XCTAssertGreaterThan(try AVAudioFile(forReading: audioURL).length, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path)
            .contains { $0.hasPrefix(".audio-") })
    }

    func testEmptyModelDirectoriesAreNotAReadyCache() throws {
        let root = makeTempRoot()
        defer { removeTempRoot(root) }
        for name in ["MelSpectrogram", "AudioEncoder", "TextDecoder"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("\(name).mlmodelc"), withIntermediateDirectories: true)
        }
        XCTAssertFalse(LocalTranscriber.hasModelFiles(in: root))
    }

    func testFailedCoreMLLoadClearsOnlyThatModelForRetry() async throws {
        let fm = FileManager.default
        let root = makeTempRoot()
        defer { removeTempRoot(root) }
        let folder = root.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(SpeechModel.turbo.rawValue)")
        for name in ["MelSpectrogram", "AudioEncoder", "TextDecoder"] {
            let component = folder.appendingPathComponent("\(name).mlmodelc")
            try fm.createDirectory(at: component, withIntermediateDirectories: true)
            try Data([1]).write(to: component.appendingPathComponent("coremldata.bin"))
        }
        let otherModel = folder.deletingLastPathComponent().appendingPathComponent(SpeechModel.small.rawValue)
        try fm.createDirectory(at: otherModel, withIntermediateDirectories: false)
        let tokenizer = root.appendingPathComponent("tokenizer.json")
        try Data("keep tokenizer".utf8).write(to: tokenizer)
        let transcriber = LocalTranscriber(downloadBase: root)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await transcriber.prepare { _ in }
        }
        if case .success = await cancelled.result { XCTFail("Cancelled setup must stop") }
        XCTAssertNotNil(LocalTranscriber.cachedModelFolder(in: root), "Cancellation must keep the cache")
        do {
            try await transcriber.prepare { progress in
                if case .downloadingModel = progress { XCTFail("Repair downloads happen on retry") }
            }
            XCTFail("Damaged models must not load")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Retry to download"))
        }
        XCTAssertNil(LocalTranscriber.cachedModelFolder(in: root), "Retry must enter the download path")
        XCTAssertFalse(fm.fileExists(atPath: folder.path))
        XCTAssertTrue(fm.fileExists(atPath: otherModel.path))
        XCTAssertEqual(try Data(contentsOf: tokenizer), Data("keep tokenizer".utf8))
    }

    @MainActor
    func testBackgroundModelSetupCanRetryWithoutTakingOverRecording() async throws {
        let (defaults, suite, root) = try makeTempDefaults("BetterMeetingSetup")
        defer { removeTempDefaults(defaults, suite: suite, root: root) }
        let model = AppModel(defaults: defaults)
        model.meetingTitle = "Next meeting"
        var attempts = 0
        model.prepareSpeechModel { _ in
            attempts += 1
            throw URLError(.notConnectedToInternet)
        }
        let first = try XCTUnwrap(model.modelPreparationTask)
        model.prepareSpeechModel { _ in XCTFail("Setup must reuse the running task") }
        _ = await first.result
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(model.state, .idle)
        XCTAssertEqual(model.primaryButtonTitle, "Start recording")
        XCTAssertEqual(model.meetingTitle, "Next meeting")
        XCTAssertNil(model.errorMessage)
        XCTAssertNotNil(model.modelSetupError)
        XCTAssertFalse(model.modelReady)
        XCTAssertNil(model.modelPreparationTask)

        model.prepareSpeechModel { _ in attempts += 1 }
        try await model.modelPreparationTask?.value
        XCTAssertEqual(attempts, 2)
        XCTAssertTrue(model.modelReady)
        XCTAssertNil(model.modelSetupError)
        XCTAssertEqual(model.state, .idle)
        model.prepareSpeechModel()
        XCTAssertNil(model.modelPreparationTask, "A ready model needs no further setup")

        model.prepareSpeechModel { _ in try Task.checkCancellation() }
        let cancelled = try XCTUnwrap(model.modelPreparationTask)
        cancelled.cancel()
        _ = await cancelled.result
        XCTAssertFalse(model.modelReady)
        XCTAssertNil(model.modelPreparationTask)
        XCTAssertEqual(model.state, .idle)
    }

    @MainActor
    func testQuitAfterProcessingKeepsTheNormalEventLoop() async throws {
        _ = NSApplication.shared
        let (defaults, suite, root) = try makeTempDefaults("BetterMeetingQuit")
        defer { removeTempDefaults(defaults, suite: suite, root: root) }
        let folder = try MeetingArtifacts.createDirectory(in: root, title: "Quit check", recordedAt: Date())
        try Data([1]).write(to: folder.appendingPathComponent("audio.m4a"))
        let model = AppModel(defaults: defaults)
        await model.historyRefreshTask?.value
        model.retryTranscription(try XCTUnwrap(model.unfinishedRecordings.first))
        let processing = try XCTUnwrap(model.processingTask)
        XCTAssertEqual(model.state, .processing)

        var exits = 0
        let finish: (NSAlert) -> NSApplication.ModalResponse = { _ in .alertFirstButtonReturn }
        XCTAssertEqual(model.terminationReply(confirm: finish), .terminateCancel,
                       "Finishing work must keep the normal event loop instead of entering AppKit's modal shutdown loop")
        model.completeTermination(true) { exits += 1 }
        model.completeTermination(true) { exits += 1 }
        XCTAssertEqual(exits, 1, "Successful completion requests quit only once")

        XCTAssertEqual(model.terminationReply(confirm: finish), .terminateCancel)
        model.completeTermination(false) { XCTFail("Failure must keep the app open") }
        model.completeTermination(true) { XCTFail("Failure must clear the pending quit") }

        XCTAssertEqual(model.terminationReply(confirm: finish), .terminateCancel)
        XCTAssertEqual(model.terminationReply(confirm: { _ in
            model.completeTermination(true) { XCTFail("Completion must not quit while reconsidering the request") }
            return .alertSecondButtonReturn
        }), .terminateCancel)
        model.completeTermination(true) { XCTFail("Keep open must cancel the earlier quit request") }

        XCTAssertEqual(model.terminationReply(confirm: finish), .terminateCancel)
        model.cancelTranscription()
        await processing.value
        XCTAssertEqual(model.state, .idle)
        model.completeTermination(true) { XCTFail("Cancelling processing must clear the pending quit") }
    }

    @MainActor
    func testProcessingIconFramesAreDistinctTemplateImages() throws {
        let frames = BrandAssets.processingMenuBarFrames
        XCTAssertGreaterThan(frames.count, 1)
        let rendered = try frames.map { image in
            XCTAssertTrue(image.isTemplate, "The menu bar must adapt to light and dark appearances")
            XCTAssertEqual(image.size, NSSize(width: 18, height: 18))
            return try XCTUnwrap(image.tiffRepresentation)
        }
        XCTAssertEqual(Set(rendered).count, frames.count, "Every animation tick must change the image")
    }

    @MainActor
    func testRecordingColorsOnlyTheExistingDot() throws {
        let asset = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Assets/MenuBarIconTemplate.png")
        let source = try XCTUnwrap(NSImage(contentsOf: asset))
        source.setName("MenuBarIconTemplate")
        defer { source.setName(nil) }
        let baseline = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            source.draw(in: rect)
            return true
        }
        let original = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(baseline.tiffRepresentation)))
        for scheme: ColorScheme in [.light, .dark] {
            let image = BrandAssets.recordingMenuBarIcon(for: scheme)
            XCTAssertFalse(image.isTemplate)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
            XCTAssertEqual(bitmap.pixelsWide, original.pixelsWide)
            XCTAssertEqual(bitmap.pixelsHigh, original.pixelsHigh)
            var redPixels = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                    let alpha = try XCTUnwrap(original.colorAt(x: x, y: y)).alphaComponent
                    XCTAssertEqual(color.alphaComponent, alpha, accuracy: 0.01, "Recording must preserve the artwork's shape")
                    guard color.alphaComponent > 0.1 else { continue }
                    if color.redComponent > color.greenComponent + 0.2 {
                        redPixels += 1
                        XCTAssertGreaterThan(Double(x) / Double(bitmap.pixelsWide), 0.7)
                        XCTAssertGreaterThan(Double(y) / Double(bitmap.pixelsHigh), 0.7)
                    } else {
                        XCTAssertEqual(color.redComponent, scheme == .dark ? 1 : 0, accuracy: 0.01)
                    }
                }
            }
            XCTAssertGreaterThan(redPixels, 0, "The existing lower-right dot must turn red")
            if let path = ProcessInfo.processInfo.environment["BETTER_MEETING_PANELS_PREVIEW_PATH"] {
                let output = URL(fileURLWithPath: path).appendingPathComponent("recording-icon-\(scheme).png")
                try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output)
            }
        }
    }

    @MainActor
    func testHistoryRemainsSearchableDuringProcessingAndCancellationShowsRecovery() async throws {
        let (defaults, suite, root) = try makeTempDefaults("BetterMeetingProcessing")
        defer { removeTempDefaults(defaults, suite: suite, root: root) }
        let date = Date(timeIntervalSince1970: 1_788_530_400)
        let saved = try MeetingArtifacts.createDirectory(in: root, title: "Product sync", recordedAt: date)
        try MeetingArtifacts.write(title: "Product sync", recordedAt: date, duration: 720, segments: [], to: saved)
        let pending = try MeetingArtifacts.createDirectory(in: root, title: "Release planning", recordedAt: date)
        try Data([1]).write(to: pending.appendingPathComponent("recording.mp4"))
        _ = NSApplication.shared
        let model = AppModel(defaults: defaults)
        await model.historyRefreshTask?.value
        let item = try XCTUnwrap(model.unfinishedRecordings.first)
        model.retryTranscription(item)
        let processing = try XCTUnwrap(model.processingTask)
        XCTAssertEqual(model.state, .processing)
        let view = NSHostingView(rootView: MenuBarControlView().environmentObject(model).environmentObject(model.updates)
            .environment(\.colorScheme, .light).background(Color(nsColor: .windowBackgroundColor)))
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        view.layoutSubtreeIfNeeded()
        func searchField(in view: NSView) -> NSSearchField? {
            (view as? NSSearchField) ?? view.subviews.lazy.compactMap { searchField(in: $0) }.first
        }
        let field = try XCTUnwrap(searchField(in: view), "Processing must keep the history search visible")
        XCTAssertTrue(field.isEnabled)
        XCTAssertTrue(model.updates.meetingInProgress)
        if let path = ProcessInfo.processInfo.environment["BETTER_MEETING_PANELS_PREVIEW_PATH"] {
            try writePreview(view, to: URL(fileURLWithPath: path).appendingPathComponent("processing.png"))
            let options = NSHostingView(rootView: CaptureOptionsView().environmentObject(model)
                .environment(\.colorScheme, .light).background(Color(nsColor: .windowBackgroundColor)))
            try writePreview(options, to: URL(fileURLWithPath: path).appendingPathComponent("options-processing.png"))
        }
        field.stringValue = "Product"
        field.sendAction(field.action, to: field.target)
        XCTAssertEqual(model.historyQuery, "Product")
        model.cancelTranscription()
        await processing.value
        await model.historySearchTask?.value
        XCTAssertEqual(model.state, .idle)
        XCTAssertEqual(model.transcriptionHistory.map(\.title), ["Product sync"])
        XCTAssertEqual(model.completionMessage, "Transcription cancelled. Recording kept; choose it from the Transcribe all menu to resume.")
        XCTAssertEqual(model.unfinishedRecordings.first?.folderURL.resolvingSymlinksInPath(), pending.resolvingSymlinksInPath())
        if let path = ProcessInfo.processInfo.environment["BETTER_MEETING_PANELS_PREVIEW_PATH"] {
            try writePreview(view, to: URL(fileURLWithPath: path).appendingPathComponent("cancelled.png"))
        }
        model.retryTranscription(item)
        await model.processingTask?.value
        XCTAssertEqual(model.state, .failed)
        XCTAssertFalse(model.updates.meetingInProgress, "A failure must unlock settings so the user can recover")
        if let path = ProcessInfo.processInfo.environment["BETTER_MEETING_PANELS_PREVIEW_PATH"] {
            let options = NSHostingView(rootView: CaptureOptionsView().environmentObject(model)
                .environment(\.colorScheme, .light).background(Color(nsColor: .windowBackgroundColor)))
            try writePreview(view, to: URL(fileURLWithPath: path).appendingPathComponent("failed.png"))
            try writePreview(options, to: URL(fileURLWithPath: path).appendingPathComponent("options-failed.png"))
        }
    }

    @MainActor
    func testPermissionFailuresKeepRecoveryVisible() throws {
        let (defaults, suite, root) = try makeTempDefaults("BetterMeetingPermissions")
        defer { removeTempDefaults(defaults, suite: suite, root: root) }
        _ = NSApplication.shared
        let model = AppModel(defaults: defaults)
        for (error, permission, title): (RecorderError, PrivacyPermission, String) in [
            (.screenPermissionDenied, .screenRecording, "Restart Better Meeting"),
            (.microphonePermissionDenied, .microphone, "Try again")
        ] {
            model.fail(error)
            XCTAssertEqual(model.state, .failed)
            XCTAssertEqual(model.privacyPermission, permission)
            XCTAssertFalse(model.captureAccessNotice.isSecondary, "Blocked access must not look like quiet ready status")
            XCTAssertEqual(model.primaryButtonTitle, title, "Keep the existing restart or retry as the secondary action")
            XCTAssertNotNil(permission.settingsURL)
            let view = NSHostingView(rootView: MenuBarControlView()
                .environmentObject(model).environmentObject(model.updates)
                .environment(\.colorScheme, .light)
                .background(Color(nsColor: .windowBackgroundColor)))
            XCTAssertEqual(view.fittingSize.width, 304)
            XCTAssertGreaterThan(view.fittingSize.height, 0)
            if let path = ProcessInfo.processInfo.environment["BETTER_MEETING_PANELS_PREVIEW_PATH"] {
                try writePreview(view, to: URL(fileURLWithPath: path).appendingPathComponent("permission-\(permission).png"))
            }
            model.dismissFailure()
            XCTAssertEqual(model.state, .idle)
            XCTAssertNil(model.privacyPermission)
        }
    }

    @MainActor
    func testPopoversDoNotResizeMenu() async throws {
        let (defaults, suite, root) = try makeTempDefaults("BetterMeetingLayout")
        defer { removeTempDefaults(defaults, suite: suite, root: root) }
        _ = NSApplication.shared
        let model = AppModel(defaults: defaults)
        await model.historyRefreshTask?.value
        let closed = NSHostingView(rootView: MenuBarControlView().environmentObject(model).environmentObject(model.updates))
        let presented = NSHostingView(rootView: MenuBarControlView(captureOptionsPresented: true).environmentObject(model).environmentObject(model.updates))
        let initialSize = closed.fittingSize
        XCTAssertGreaterThan(initialSize.height, 0)
        XCTAssertEqual(presented.fittingSize, initialSize)
        let statuses: [AppUpdater.Status] = [
            .checking, .current, .available("0.3.26"), .downloading, .downloaded("0.3.26"),
            .preparing, .ready("0.3.26"), .installing, .failed, .unchecked
        ]
        for status in statuses {
            model.updates.status = status
            await Task.yield()
            XCTAssertEqual(closed.fittingSize, initialSize, "\(status) must not resize the menu")
            XCTAssertEqual(presented.fittingSize, initialSize, "\(status) must not move the open Options popover")
        }
    }

    @MainActor
    func testOptionsAndUpdateLayouts() throws {
        let suite = "BetterMeetingPanelLayout.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = makeTempRoot(suite)
        defaults.set(root.appendingPathComponent("Better Meetings"), forKey: "outputFolder")
        defer { removeTempDefaults(defaults, suite: suite, root: root) }
        _ = NSApplication.shared
        let model = AppModel(defaults: defaults)
        let meeting = MeetingHistoryItem(
            title: "Design review", recordedAt: Date(), duration: 60,
            folderURL: root,
            needsTranscription: false, titleWasProvided: true
        )
        var panels: [(String, AnyView, CGFloat, AppUpdater.Status)] = [
            ("options", AnyView(CaptureOptionsView(version: "0.3.23")), 360, .unchecked),
            ("options-current", AnyView(CaptureOptionsView(version: "0.3.23")), 360, .current),
            ("options-checking", AnyView(CaptureOptionsView(version: "0.3.23")), 360, .checking),
            ("options-ready", AnyView(CaptureOptionsView(version: "0.3.23")), 360, .ready("0.3.24")),
            ("options-login-enabled", AnyView(CaptureOptionsView(launchAtLoginStatus: .enabled, version: "0.3.23")), 360, .unchecked),
            ("options-login-approval", AnyView(CaptureOptionsView(launchAtLoginStatus: .requiresApproval, version: "0.3.23")), 360, .unchecked),
            ("options-login-error", AnyView(CaptureOptionsView(launchAtLoginStatus: .notRegistered, launchAtLoginError: "The operation was denied.", version: "0.3.23")), 360, .unchecked),
            ("options-login-missing", AnyView(CaptureOptionsView(launchAtLoginStatus: .notFound, launchAtLoginError: "Service not found.", version: "0.3.23")), 360, .unchecked),
            ("options-enabled", AnyView(CaptureOptionsView(version: "0.3.23")), 360, .unchecked),
            ("options-single-language", AnyView(CaptureOptionsView(version: "0.3.23")), 360, .unchecked),
            ("options-many-languages", AnyView(CaptureOptionsView(version: "0.3.23")), 360, .unchecked),
            ("advanced", AnyView(CaptureOptionsView(advancedPresented: true, version: "0.3.23")), 360, .unchecked),
            ("retranscribe", AnyView(RetranscriptionView(
                meeting: meeting, languages: ["uk", "ru", "en"],
                hints: "", settings: SpeechSettings(), start: { _, _, _ in }
            )), 360, .unchecked),
            ("retranscribe-advanced", AnyView(RetranscriptionView(
                meeting: meeting, languages: ["uk", "ru", "en"],
                hints: "Anna, Approck", settings: SpeechSettings(), advancedPresented: true, start: { _, _, _ in }
            )), 360, .unchecked)
        ]
        for (name, status): (String, AppUpdater.Status) in [
            ("unchecked", .unchecked), ("checking", .checking), ("current", .current),
            ("available", .available("0.3.24")), ("downloaded", .downloaded("0.3.24")),
            ("downloading", .downloading), ("preparing", .preparing),
            ("ready", .ready("0.3.24")), ("installing", .installing), ("failed", .failed)
        ] {
            panels.append(("updates-\(name)", AnyView(UpdateOptionsView(updates: model.updates, version: "0.3.23").frame(width: 328)), 328, status))
        }
        panels.append(("updates-development", AnyView(UpdateOptionsView(
            updates: model.updates, version: nil
        ).frame(width: 328)), 328, .unchecked))
        panels.append(("options-update-error", AnyView(CaptureOptionsView(version: "0.3.23")), 360, .failed))
        var optionsHeight: CGFloat?
        var updatesHeight: CGFloat?
        for (name, content, width, status) in panels {
            model.updates.canCheckForUpdates = status != .checking
            if case .ready = status { model.updates.showReady(toInstallAndRelaunch: { _ in }) }
            else { model.updates.dismissUpdateInstallation() }
            model.updates.status = status
            if name == "options-update-error" {
                model.updates.showUpdaterError(NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet,
                    userInfo: [NSLocalizedDescriptionKey: "The update could not be downloaded because the internet connection was lost. Check your connection and try again. Your installed version is unchanged."])) {}
            }
            model.speechSettings.speakerLabels = name == "options-enabled"
            model.exportAfterRecording = name == "options-enabled"
            model.transcriptionLanguages = name == "options-single-language" ? ["uk"]
                : name == "options-many-languages" ? ["uk", "ru", "en", "fr", "de", "es", "pt", "ja"]
                : ["uk", "ru", "en"]
            let view = NSHostingView(rootView: content.environmentObject(model).environmentObject(model.updates)
                .environment(\.colorScheme, .light)
                .background(Color(nsColor: .windowBackgroundColor)))
            XCTAssertEqual(view.fittingSize.width, width, "\(name) must keep its panel width")
            XCTAssertGreaterThan(view.fittingSize.height, 0)
            if ["options", "options-current", "options-checking", "options-ready"].contains(name) {
                XCTAssertLessThanOrEqual(view.fittingSize.height, 480, "Options, including update controls, must stay compact")
                if let optionsHeight { XCTAssertEqual(view.fittingSize.height, optionsHeight, "Update states must not resize Options") }
                else { optionsHeight = view.fittingSize.height }
            }
            if name == "options-update-error", let optionsHeight {
                XCTAssertGreaterThan(view.fittingSize.height, optionsHeight, "Error details must remain visible inline")
            }
            if ["updates-unchecked", "updates-checking", "updates-current", "updates-failed"].contains(name) {
                XCTAssertLessThanOrEqual(view.fittingSize.height, 60, "Update controls must stay compact")
                if let updatesHeight { XCTAssertEqual(view.fittingSize.height, updatesHeight, "Checking must not resize update controls") }
                else { updatesHeight = view.fittingSize.height }
            }
            if let path = ProcessInfo.processInfo.environment["BETTER_MEETING_PANELS_PREVIEW_PATH"] {
                let output = URL(fileURLWithPath: path).appendingPathComponent("\(name).png")
                try writePreview(view, to: output)
            }
        }
    }

    @MainActor
    func testSearchDoesNotResizeMenu() async throws {
        let (defaults, suite, root) = try makeTempDefaults("BetterMeetingSearchLayout")
        defer { removeTempDefaults(defaults, suite: suite, root: root) }
        for index in 0..<7 {
            let date = Date(timeIntervalSince1970: Double(index * 60))
            let folder = try MeetingArtifacts.createDirectory(in: root, title: "Meeting \(index)", recordedAt: date)
            try MeetingArtifacts.write(title: "Meeting \(index)", recordedAt: date, duration: 60, segments: [], to: folder)
        }
        _ = NSApplication.shared
        let model = AppModel(defaults: defaults)
        await model.historyRefreshTask?.value
        func size() -> NSSize {
            NSHostingView(rootView: MenuBarControlView().environmentObject(model).environmentObject(model.updates)).fittingSize
        }
        let initial = size()
        let menu = NSHostingView(rootView: MenuBarControlView().environmentObject(model).environmentObject(model.updates))
        menu.frame = NSRect(origin: .zero, size: initial)
        menu.layoutSubtreeIfNeeded()
        func searchField(in view: NSView) -> NSSearchField? {
            (view as? NSSearchField) ?? view.subviews.lazy.compactMap { searchField(in: $0) }.first
        }
        let field = try XCTUnwrap(searchField(in: menu))
        XCTAssertEqual(field.bounds.width, initial.width - 24, accuracy: 1, "Search must fill the padded content width")
        let window = NSWindow(contentRect: menu.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = menu
        window.makeFirstResponder(field)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.insertText("Meeting 1", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(model.historyQuery, "", "Typing must wait for the native search delay")
        model.meetingTitle = "Unrelated update"
        menu.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(field.stringValue, "Meeting 1", "View updates must preserve pending search text")
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(model.historyQuery, "Meeting 1")
        XCTAssertEqual(size(), initial)
        await model.historySearchTask?.value
        XCTAssertEqual(model.transcriptionHistory.count, 1)
        XCTAssertEqual(size(), initial)
        model.historyQuery = "no such meeting"
        await model.historySearchTask?.value
        XCTAssertTrue(model.transcriptionHistory.isEmpty)
        XCTAssertEqual(size(), initial)
        let cell = try XCTUnwrap(field.cell as? NSSearchFieldCell)
        let clear = try XCTUnwrap(cell.cancelButtonCell)
        clear.performClick(field)
        XCTAssertEqual(model.historyQuery, "")
        XCTAssertEqual(model.transcriptionHistory.count, 7)
        XCTAssertEqual(size(), initial)
    }

    @MainActor
    func testSavedMeetingKeepsTheSameRowHeight() {
        _ = NSApplication.shared
        for (saved, unfinished) in [(false, false), (true, false), (false, true)] {
            let item = MeetingHistoryItem(
                title: "2026-09-05 14.39.08", recordedAt: Date(timeIntervalSince1970: 1_788_611_948),
                duration: 34, folderURL: URL(fileURLWithPath: "/tmp/layout-preview"),
                needsTranscription: unfinished, titleWasProvided: false
            )
            let row = NSHostingView(rootView: MenuBarControlView().historyRow(item, isSaved: saved, canEdit: true)
                .environment(\.locale, Locale(identifier: "en_US"))
                .frame(width: 264))
            XCTAssertEqual(row.fittingSize.height, 47, "The status indicators must not wrap meeting details")
        }
    }

    @MainActor
    func testRenderMenuBarPreview() async throws {
        guard let path = ProcessInfo.processInfo.environment["BETTER_MEETING_PREVIEW_PATH"] else {
            throw XCTSkip("Set BETTER_MEETING_PREVIEW_PATH to render the menu with fictional meetings")
        }
        let suite = "BetterMeetingPreview.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = makeTempRoot(suite)
        defer { removeTempDefaults(defaults, suite: suite, root: root) }
        defaults.set(root.appendingPathComponent("Better Meetings"), forKey: "outputFolder")
        for (index, title) in ["Product sync", "Release planning", "Design review"].enumerated() {
            let date = Date(timeIntervalSince1970: 1_788_530_400 - Double(index * 3_600))
            let folder = try MeetingArtifacts.createDirectory(in: root, title: title, recordedAt: date)
            try MeetingArtifacts.write(title: title, recordedAt: date, duration: Double(720 + index * 180), segments: [], to: folder)
        }
        _ = NSApplication.shared
        let model = AppModel(defaults: defaults)
        await model.historyRefreshTask?.value
        let view = NSHostingView(rootView: MenuBarControlView()
            .environmentObject(model).environmentObject(model.updates)
            .environment(\.colorScheme, .light)
            .background(Color(nsColor: .windowBackgroundColor)))
        try writePreview(view, to: URL(fileURLWithPath: path))
        if let panels = ProcessInfo.processInfo.environment["BETTER_MEETING_PANELS_PREVIEW_PATH"] {
            let initialSize = view.fittingSize
            for (name, status): (String, AppUpdater.Status) in [
                ("ready", .ready("0.3.26")), ("ready-dark", .ready("0.3.26")),
                ("ready-busy", .ready("0.3.26")), ("downloading", .downloading),
                ("preparing", .preparing), ("failed", .failed)
            ] {
                let updates = AppUpdater(isBusy: { name == "ready-busy" })
                updates.canCheckForUpdates = true
                if case .ready = status { updates.showReady(toInstallAndRelaunch: { _ in }) }
                updates.status = status
                let updated = NSHostingView(rootView: MenuBarControlView()
                    .environmentObject(model).environmentObject(updates)
                    .environment(\.colorScheme, name == "ready-dark" ? .dark : .light)
                    .background(Color(nsColor: .windowBackgroundColor)))
                updated.appearance = NSAppearance(named: name == "ready-dark" ? .darkAqua : .aqua)
                XCTAssertEqual(updated.fittingSize.width, initialSize.width)
                XCTAssertEqual(updated.fittingSize.height, initialSize.height, "Update feedback must not resize the menu")
                try writePreview(updated, to: URL(fileURLWithPath: panels).appendingPathComponent("menu-update-\(name).png"))
            }
        }
    }

    @MainActor
    private func writePreview(_ view: NSView, to output: URL) throws {
        if view.appearance == nil { view.appearance = NSAppearance(named: .aqua) }
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: output)
    }

    @MainActor
    func testPreferencesPersistAndHistoryKeepsOlderUnfinishedMeetings() async throws {
        let suite = "BetterMeetingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = makeTempRoot()
        defer { removeTempDefaults(defaults, suite: suite, root: root) }
        for index in 0..<12 {
            let date = Date(timeIntervalSince1970: Double(index * 60))
            let folder = try MeetingArtifacts.createDirectory(in: root, title: "Meeting \(index)", recordedAt: date)
            if index == 0 {
                try Data([1]).write(to: folder.appendingPathComponent("audio.m4a"))
            } else {
                try MeetingArtifacts.write(title: "Meeting \(index)", recordedAt: date, duration: 60, segments: [], to: folder)
            }
        }
        let model = AppModel(defaults: defaults)
        await model.historyRefreshTask?.value
        XCTAssertEqual(model.captureResolution, .pixels1440)
        XCTAssertEqual(model.captureQuality, .standard)
        model.setOutputFolder(root)
        model.selectedDisplayID = 42
        model.selectedMicrophoneID = "test-mic"
        model.captureResolution = .pixels1920
        model.captureQuality = .smooth
        let reopened = AppModel(defaults: defaults)
        await reopened.historyRefreshTask?.value
        XCTAssertEqual(reopened.outputRoot.path, root.path)
        XCTAssertEqual(reopened.selectedDisplayID, 42)
        XCTAssertEqual(reopened.selectedMicrophoneID, "test-mic")
        XCTAssertEqual(reopened.captureResolution, .pixels1920)
        XCTAssertEqual(reopened.captureQuality, .smooth)
        XCTAssertEqual(reopened.transcriptionHistory.count, 12)
        XCTAssertEqual(reopened.transcriptionHistory.first?.title, "Meeting 11")
        XCTAssertEqual(reopened.transcriptionHistory.last?.title, "Meeting 0", "Unfinished recordings stay in the list")
        XCTAssertEqual(reopened.unfinishedRecordings.map(\.title), ["Meeting 0"])
        XCTAssertEqual(reopened.terminationReply(), .terminateNow)
        defaults.set(999, forKey: "captureResolution")
        defaults.set(999, forKey: "captureQuality")
        let invalidPreferences = AppModel(defaults: defaults)
        XCTAssertEqual(invalidPreferences.captureResolution, .pixels1440)
        XCTAssertEqual(invalidPreferences.captureQuality, .standard)
    }

    @MainActor
    func testVideoPresetsRespectSourceSizeAndFrameRate() {
        for resolution in CaptureResolution.allCases {
            for quality in CaptureQuality.allCases {
                for source in [CGSize(width: 3840, height: 2160), CGSize(width: 2160, height: 3840),
                               CGSize(width: 1025, height: 769), CGSize(width: 5120, height: 1440)] {
                    let configuration = MeetingRecorder.videoConfiguration(
                        sourceSize: source, resolution: resolution, quality: quality
                    )
                    let scale = min(1, CGFloat(resolution.rawValue) / max(source.width, source.height))
                    XCTAssertLessThanOrEqual(max(configuration.width, configuration.height), resolution.rawValue)
                    XCTAssertLessThanOrEqual(CGFloat(configuration.width), source.width)
                    XCTAssertLessThanOrEqual(CGFloat(configuration.height), source.height)
                    XCTAssertEqual(configuration.width % 2, 0)
                    XCTAssertEqual(configuration.height % 2, 0)
                    XCTAssertEqual(CGFloat(configuration.width), source.width * scale, accuracy: 2)
                    XCTAssertEqual(CGFloat(configuration.height), source.height * scale, accuracy: 2)
                    XCTAssertEqual(CMTimeGetSeconds(configuration.minimumFrameInterval), 1 / Double(quality.rawValue), accuracy: 0.0001)
                }
            }
        }
    }

    @MainActor
    func testRecordingAudioWarningClearsWithoutResizingOrRepeating() throws {
        _ = NSApplication.shared
        let (defaults, suite, root) = try makeTempDefaults("BetterMeetingAudioWarning")
        let model = AppModel(defaults: defaults)
        defer {
            model.fail(AppError.missingRecording)
            removeTempDefaults(defaults, suite: suite, root: root)
        }
        model.recordingDidStart(at: Date())
        var warnings = 0
        let observation = model.$audioWarning.sink { if $0 { warnings += 1 } }
        defer { observation.cancel() }
        let view = NSHostingView(rootView: MenuBarControlView()
            .environmentObject(model).environmentObject(model.updates)
            .environment(\.colorScheme, .light)
            .background(Color(nsColor: .windowBackgroundColor)))
        let initialSize = view.fittingSize
        model.checkRecordingAudio(elapsed: 29.99, audioDetected: false)
        XCTAssertFalse(model.audioWarning)
        let panels = ProcessInfo.processInfo.environment["BETTER_MEETING_PANELS_PREVIEW_PATH"].map { URL(fileURLWithPath: $0) }
        if let panels { try writePreview(view, to: panels.appendingPathComponent("recording-normal.png")) }
        model.checkRecordingAudio(elapsed: 30, audioDetected: false)
        XCTAssertTrue(model.audioWarning)
        model.checkRecordingAudio(elapsed: 120, audioDetected: false)
        XCTAssertEqual(warnings, 1)
        XCTAssertEqual(model.state, .recording, "A warning must not stop recording")
        let warningView = NSHostingView(rootView: view.rootView)
        XCTAssertEqual(warningView.fittingSize, initialSize, "The warning must not move the recording controls")
        if let panels {
            try writePreview(warningView, to: panels.appendingPathComponent("recording-audio-warning.png"))
            let dark = NSHostingView(rootView: MenuBarControlView()
                .environmentObject(model).environmentObject(model.updates)
                .environment(\.colorScheme, .dark)
                .background(Color(nsColor: .windowBackgroundColor)))
            dark.appearance = NSAppearance(named: .darkAqua)
            XCTAssertEqual(dark.fittingSize, initialSize)
            try writePreview(dark, to: panels.appendingPathComponent("recording-audio-warning-dark.png"))
        }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 100))
        buffer.frameLength = 100
        let samples = try XCTUnwrap(buffer.floatChannelData)[0]
        for source: SCStreamOutputType in [.microphone, .audio] {
            let recorder = MeetingRecorder()
            samples.update(repeating: 0, count: 100)
            recorder.updateAudioLevel(buffer, type: source, at: Date())
            XCTAssertFalse(recorder.hasDetectedAudio)
            samples.update(repeating: 0.1, count: 100)
            recorder.updateAudioLevel(buffer, type: source, at: Date())
            XCTAssertTrue(recorder.hasDetectedAudio, "Either source must count as detected audio")
            model.checkRecordingAudio(elapsed: 120, audioDetected: recorder.hasDetectedAudio)
            XCTAssertFalse(model.audioWarning)
            samples.update(repeating: 0, count: 100)
            recorder.updateAudioLevel(buffer, type: source, at: Date())
            XCTAssertTrue(recorder.hasDetectedAudio, "Later silence must not erase the earlier signal")
            model.checkRecordingAudio(elapsed: 600, audioDetected: recorder.hasDetectedAudio)
            XCTAssertFalse(model.audioWarning)
        }
        XCTAssertEqual(warnings, 1)
        XCTAssertEqual(NSHostingView(rootView: view.rootView).fittingSize, initialSize)
        model.recordingDidStart(at: Date())
        model.checkRecordingAudio(elapsed: 30, audioDetected: false)
        XCTAssertEqual(warnings, 2, "A new recording must get its own warning")
        model.fail(AppError.missingRecording)
        XCTAssertFalse(model.audioWarning)
        XCTAssertNil(model.recordingID)
        model.checkRecordingAudio(elapsed: 60, audioDetected: false)
        XCTAssertFalse(model.audioWarning, "A late timer callback must not warn after recording stops")
    }

    @MainActor
    func testAudioMeterHandlesSilenceStereoAndClipping() throws {
        for interleaved in [false, true] {
            let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: interleaved))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 100))
            buffer.frameLength = 100
            let channels = try XCTUnwrap(buffer.floatChannelData)
            for frame in 0..<100 {
                channels[0][frame * buffer.stride] = 0
                channels[1][frame * buffer.stride] = 0
            }
            XCTAssertEqual(MeetingRecorder.meterLevel(buffer), 0)
            for frame in 0..<100 { channels[1][frame * buffer.stride] = 0.1 }
            XCTAssertEqual(MeetingRecorder.meterLevel(buffer), 2.0 / 3, accuracy: 0.001)
            for frame in 0..<100 { channels[1][frame * buffer.stride] = 2 }
            XCTAssertEqual(MeetingRecorder.meterLevel(buffer), 1)
        }
        for commonFormat: AVAudioCommonFormat in [.pcmFormatInt16, .pcmFormatInt32] {
            let format = try XCTUnwrap(AVAudioFormat(commonFormat: commonFormat, sampleRate: 48_000, channels: 1, interleaved: false))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 100))
            buffer.frameLength = 100
            buffer.int16ChannelData?[0].update(repeating: 16384, count: 100)
            buffer.int32ChannelData?[0].update(repeating: 1073741824, count: 100)
            XCTAssertEqual(MeetingRecorder.meterLevel(buffer), (20 * log10(0.5) + 60) / 60, accuracy: 0.001)
        }
    }

    @MainActor
    func testSearchFindsOlderTitlesAndEditedTranscripts() async throws {
        let (defaults, suite, root) = try makeTempDefaults("BetterMeetingSearch")
        defer { removeTempDefaults(defaults, suite: suite, root: root) }
        var oldest: URL?
        for index in 0..<12 {
            let date = Date(timeIntervalSince1970: Double(index * 60))
            let title = index == 0 ? "Café planning" : "Meeting \(index)"
            let folder = try MeetingArtifacts.createDirectory(in: root, title: title, recordedAt: date)
            try MeetingArtifacts.write(title: title, recordedAt: date, duration: 0, segments: [], to: folder)
            if index == 0 { oldest = folder }
        }
        let model = AppModel(defaults: defaults)
        await model.historyRefreshTask?.value
        XCTAssertEqual(model.transcriptionHistory.count, 12)
        model.historyQuery = "cafe"
        await model.historySearchTask?.value
        XCTAssertEqual(model.transcriptionHistory.map(\.title), ["Café planning"])
        try "Edited notes about pricing".write(to: try XCTUnwrap(oldest).appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        model.historyQuery = "PRICING"
        await model.historySearchTask?.value
        XCTAssertEqual(model.transcriptionHistory.map(\.title), ["Café planning"])
        model.historyQuery = "missing"
        model.historyQuery = "  "
        await model.historySearchTask?.value
        XCTAssertEqual(model.transcriptionHistory.count, 12, "Cancelled search must not replace newer results")
        XCTAssertFalse(model.searchingHistory)
    }

    @MainActor
    func testHistoryRefreshKeepsResultsAndIgnoresAnOldFolderScan() async throws {
        let suite = "BetterMeetingHistory.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = makeTempRoot(suite)
        defer { removeTempDefaults(defaults, suite: suite, root: root) }
        let oldRoot = root.appendingPathComponent("old")
        let newRoot = root.appendingPathComponent("new")
        for (destination, title) in [(oldRoot, "Old meeting"), (newRoot, "New meeting")] {
            let folder = try MeetingArtifacts.createDirectory(in: destination, title: title, recordedAt: Date())
            try MeetingArtifacts.write(title: title, recordedAt: Date(), duration: 60, segments: [], to: folder)
        }
        defaults.set(oldRoot, forKey: "outputFolder")
        let model = AppModel(defaults: defaults)
        await model.historyRefreshTask?.value
        let started = expectation(description: "Scanning away from the main thread")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let oldResults = model.transcriptionHistory
        model.refreshHistory { _ in
            XCTAssertFalse(Thread.isMainThread)
            started.fulfill()
            release.wait()
            return oldResults
        }
        let oldScan = try XCTUnwrap(model.historyRefreshTask)
        await fulfillment(of: [started], timeout: 5)
        XCTAssertEqual(model.transcriptionHistory, oldResults, "Keep results visible during a refresh")
        model.setOutputFolder(newRoot)
        XCTAssertTrue(model.transcriptionHistory.isEmpty, "A different folder must not show stale actions")
        model.historyQuery = "New"
        await model.historyRefreshTask?.value
        await model.historySearchTask?.value
        XCTAssertEqual(model.transcriptionHistory.map(\.title), ["New meeting"])
        release.signal()
        await oldScan.value
        XCTAssertEqual(model.transcriptionHistory.map(\.title), ["New meeting"], "An old scan must not replace the new folder")
    }

    func testModelPreparationAcrossColdLaunches() async throws {
        guard let mode = ProcessInfo.processInfo.environment["BETTER_MEETING_MODEL_CHECK"] else {
            throw XCTSkip("Set BETTER_MEETING_MODEL_CHECK=prepare, then offline in a separate process to check the real model cache")
        }
        let cache = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/model-check")
        if mode == "offline" {
            XCTAssertNotNil(LocalTranscriber.cachedModelFolder(in: cache))
            URLProtocol.registerClass(OfflineRequests.self)
        }
        defer { URLProtocol.unregisterClass(OfflineRequests.self) }
        try await LocalTranscriber(downloadBase: cache).prepare { _ in }
        XCTAssertNotNil(LocalTranscriber.cachedModelFolder(in: cache))
    }
}

private final class OfflineRequests: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTFail("Cached model setup attempted a network request")
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}
