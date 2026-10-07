import AppKit
import Combine

/// The live capture: its state, recorder calls, timer, and disk-space and audio warnings, until it is
/// queued for processing. Its tasks capture the model, so a capture starting or stopping keeps it alive.
@MainActor
final class RecordingSession: ObservableObject {
    @Published var state: AppState = .idle { didSet { model.refreshCaptureAccess() } }
    @Published var statusText = "Ready to record your display and audio."
    @Published private(set) var audioWarning = false
    @Published private(set) var audioWarningTitle = "No audio detected yet"
    var audioWarningDetail: String {
        audioWarningTitle == "No audio detected yet"
            ? "Check your microphone and meeting audio."
            : "Check the source if audio is expected."
    }
    @Published private(set) var diskSpace: RecordingDiskSpace?
    private(set) var captureMode: CaptureMode = .screen
    private(set) var id: UUID?
    var activeFolder: URL?
    private var recordedAt: Date?
    var titleWasProvided = true
    private var folderTitle = ""
    private var timer: Timer?
    private var audioWarningTask: Task<Void, Never>?
    private var diskWarningTask: Task<Void, Never>?
    private var lastDiskCheck = Date.distantPast
    private var startTask: Task<Void, Never>?
    private let recorder = MeetingRecorder()
    /// Production waits for ScreenCaptureKit's completion; tests can hold that completion pending.
    lazy var stopCapture: () async throws -> Void = { [recorder] in try await recorder.stop() }
    unowned let model: AppModel

    init(model: AppModel) {
        self.model = model
        recorder.onUnexpectedStop = { [weak self] error in
            self?.captureStoppedExternally(with: error)
        }
    }

    func start(calendarEvent: CalendarEvent?, mode: CaptureMode) {
        stopTimer()
        model.elapsed = 0
        state = .preparing
        captureMode = mode
        statusText = "Checking screen and microphone access…"
        activeFolder = nil
        recordedAt = nil

        let manualTitle = model.meetingTitle
        startTask = Task { [model] in
            defer { startTask = nil }
            do {
                try Task.checkCancellation()
                let root = model.outputRoot
                let space = await Task.detached(priority: .utility) { RecordingDiskSpace.read(at: root) }.value
                checkDiskSpace(space)
                try space?.preflight()
                try await recorder.requestPermissions()
                await MeetingNotifications.requestPermission()

                // Resolve only the exact event the user clicked, never a title/time match.
                let event: CalendarEvent?
                if let calendarEvent {
                    event = try await model.calendar.eventForRecording(id: calendarEvent.id)
                } else {
                    event = nil
                }
                let title = event?.title ?? manualTitle
                model.meetingTitle = title
                titleWasProvided = !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                folderTitle = title
                let startedAt = Date()
                let folder = try MeetingArtifacts.createDirectory(
                    in: model.outputRoot,
                    title: title,
                    recordedAt: startedAt
                )
                let recordingURL = folder.appendingPathComponent(mode.filename)
                activeFolder = folder
                try event?.attach(to: folder, recordedAt: startedAt)
                try await recorder.start(
                    to: recordingURL, displayID: model.selectedDisplayID, microphoneID: model.selectedMicrophoneID,
                    resolution: model.captureResolution, quality: model.captureQuality, mode: mode
                )
                didStart(at: startedAt)
            } catch {
                discardUnstartedFolder()
                model.fail(error, folder: activeFolder)
            }
        }
    }

    /// Quitting during setup: stops it and removes a folder that never received media.
    func cancelStart() {
        startTask?.cancel()
        discardUnstartedFolder()
    }

    /// Stops capture and moves the recording to the Trash without transcribing it,
    /// for meetings nobody joined.
    func cancel(
        confirm: @MainActor (NSAlert) -> NSApplication.ModalResponse = { $0.runActive() },
        trash: @escaping (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) {
        guard state == .recording else { return }
        let alert = NSAlert()
        alert.messageText = "Cancel this recording?"
        alert.informativeText = "The recording stops and is moved to the Trash. It won’t be transcribed."
        alert.addButton(withTitle: "Keep recording")
        alert.addButton(withTitle: "Cancel Recording")
        alert.buttons[1].hasDestructiveAction = true
        // Capture may have stopped while the confirmation was open.
        guard confirm(alert) == .alertSecondButtonReturn, state == .recording else { return }
        stopTimer()
        let folder = activeFolder
        state = .stopping
        statusText = "Stopping the recording before moving it to the Trash…"
        Task { [model] in
            do {
                try await stopCapture()
                guard let folder else { throw AppError.missingRecording }
                try trash(folder)
                activeFolder = nil
                recordedAt = nil
                model.elapsed = 0
                model.meetingTitle = ""
                state = .idle
                model.accessibilityAnnouncement("Recording cancelled.")
                model.refreshHistory()
                if !model.isProcessing { model.completeTermination(true) }
            } catch {
                model.fail(error, folder: activeFolder)
            }
        }
    }

    private func discardUnstartedFolder() {
        // Capture may start while a confirmation is open; never discard a live recording.
        guard state == .preparing, let folder = activeFolder,
              MeetingArtifacts.removeFolderWithoutMedia(folder) else { return }
        activeFolder = nil
        recordedAt = nil
    }

    private func captureStoppedExternally(with error: Error?) {
        guard state == .recording else { return }

        if let error {
            model.fail(error, folder: activeFolder)
            return
        }

        finish(stoppingCapture: false)
    }

    /// Ends the capture and queues its transcription.
    func finish(stoppingCapture stopCapture: Bool) {
        if let recordedAt {
            model.elapsed = Date().timeIntervalSince(recordedAt)
        }
        stopTimer()
        guard var run = takeCaptureRun() else {
            model.fail(AppError.missingRecording, folder: activeFolder)
            return
        }
        state = stopCapture ? .stopping : .idle
        if stopCapture { statusText = "Stopping the recording…" }
        model.accessibilityAnnouncement("Recording stopped. Transcription started.")
        model.processing.showFinalizing(run.folder)
        if stopCapture {
            let folder = run.folder
            run.stopTask = Task { [model] in
                do {
                    try await self.stopCapture()
                    if state == .stopping { state = .idle }
                } catch {
                    model.fail(error, folder: folder)
                    throw error
                }
            }
        }
        model.processing.enqueue(run)
    }

    private func takeCaptureRun() -> ProcessingRun? {
        guard let folder = activeFolder, let recordedAt else { return nil }
        activeFolder = nil
        self.recordedAt = nil
        // A name typed or changed while recording wins; clearing the field keeps the folder's name.
        let meetingTitle = model.meetingTitle
        let editedTitle = meetingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return ProcessingRun(
            folder: folder,
            recordedAt: recordedAt,
            title: editedTitle.isEmpty ? folderTitle : meetingTitle,
            titleWasProvided: titleWasProvided || !editedTitle.isEmpty,
            replacing: nil,
            languages: model.transcriptionLanguages,
            hints: model.transcriptionHints,
            settings: model.speechSettings.withResolvedEngine,
            folderTitle: folderTitle
        )
    }

    func didStart(at startDate: Date) {
        stopTimer()
        recordedAt = startDate
        model.completionMessage = nil
        let recordingID = UUID()
        id = recordingID
        model.elapsed = 0
        state = .recording
        // The microphone is live from here on, so its idle event always re-arms the detector.
        if model.detectsMeetings { model.meetingDetector.ownRecordingStarted() }
        statusText = captureMode == .audioOnly
            ? "Recording system audio and microphone. No screen video is saved."
            : "Recording the selected display, system audio, and microphone."
        model.accessibilityAnnouncement("Recording started.")
        refreshDiskSpace()
        // Added to the main run loop below, so each tick already runs on the main actor.
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.state == .recording, self.id == recordingID else { return }
                let model = self.model
                let elapsed = Date().timeIntervalSince(startDate)
                // The clocks show whole seconds; publishing every tick would redraw the menu four times a second.
                if Int(elapsed) != Int(model.elapsed) { model.elapsed = elapsed }
                if model.menuWindow?.isVisible == true {
                    model.meters.update(
                        microphone: self.recorder.audioLevel(microphone: true),
                        system: self.recorder.audioLevel(microphone: false)
                    )
                }
                self.checkAudio(elapsed: elapsed, audioDetected: self.recorder.hasDetectedAudio,
                                health: self.recorder.audioHealth())
                if Date().timeIntervalSince(self.lastDiskCheck) >= 10 { self.refreshDiskSpace() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func checkAudio(elapsed: TimeInterval, audioDetected: Bool, health: RecordingAudioHealth? = nil) {
        guard state == .recording else { return }
        let title: String? = elapsed < 30 ? nil
            : (!audioDetected ? "No audio detected yet" : health?.warning)
        let warning = title != nil
        guard audioWarning != warning || (warning && audioWarningTitle != title) else { return }
        if let title { audioWarningTitle = title }
        audioWarning = warning
        let message = "\(audioWarningTitle). \(audioWarningDetail)"
        if warning { model.accessibilityAnnouncement(message) }
        let previousWarning = audioWarningTask
        clearAudioWarning()
        if warning, model.menuWindow?.isVisible != true, let id {
            audioWarningTask = Task {
                _ = await previousWarning?.value
                guard !Task.isCancelled else { return }
                await MeetingNotifications.post(MeetingNotifications.audioWarning(recordingID: id, message: message))
            }
        }
    }

    /// Reads free space off the main actor; a result that arrives after this recording ended is dropped.
    private func refreshDiskSpace() {
        guard let recordingID = id else { return }
        lastDiskCheck = Date()
        let destination = activeFolder ?? model.outputRoot
        Task { [model] in
            let space = await Task.detached(priority: .utility) { RecordingDiskSpace.read(at: destination) }.value
            guard self.id == recordingID else { return }
            model.recording.checkDiskSpace(space)
        }
    }

    func checkDiskSpace(_ space: RecordingDiskSpace?) {
        guard state == .recording || state == .preparing else { return }
        let wasLow = diskSpace?.isLow == true
        diskSpace = space
        guard let space, space.isLow else {
            clearDiskWarning()
            return
        }
        guard !wasLow else { return }
        model.accessibilityAnnouncement("Low recording disk space. \(space.warning)")
        if model.menuWindow?.isVisible != true, let id {
            diskWarningTask = Task {
                await MeetingNotifications.post(MeetingNotifications.diskWarning(recordingID: id, message: space.warning))
            }
        }
    }

    private func clearDiskWarning() {
        diskWarningTask?.cancel()
        diskWarningTask = nil
        if let id { MeetingNotifications.remove(id.uuidString + "-disk") }
    }

    private func clearAudioWarning() {
        audioWarningTask?.cancel()
        audioWarningTask = nil
        if let id { MeetingNotifications.remove(id.uuidString) }
    }

    func stopTimer() {
        timer?.invalidate()
        timer = nil
        clearAudioWarning()
        clearDiskWarning()
        audioWarning = false
        audioWarningTitle = "No audio detected yet"
        diskSpace = nil
        id = nil
        model.meters.update(microphone: 0, system: 0)
    }
}
