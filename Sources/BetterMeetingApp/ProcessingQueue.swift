import AppKit
import AVFoundation
import Combine
import os

struct ProcessingRun {
    let folder: URL
    let recordedAt: Date
    let title: String
    let titleWasProvided: Bool
    let replacing: MeetingHistoryItem?
    let languages: [String]
    let hints: String
    let settings: SpeechSettings
    var stopTask: Task<Void, Error>?
    /// The title a capture folder was created with; the name can change while recording.
    var folderTitle: String?
}

/// A stopped or retried recording, or one meeting of Transcribe all.
private enum QueuedJob {
    case recording(ProcessingRun), batch(MeetingHistoryItem, process: (MeetingHistoryItem) async -> Bool)
    var folder: URL { switch self { case .recording(let run): run.folder; case .batch(let item, _): item.folderURL } }
    var isBatch: Bool { if case .batch = self { true } else { false } }
}

extension LocalTranscriptionProgress {
    /// Setup and transcription share one progress enum; only model steps map onto a processing phase.
    var modelStep: (phase: ProcessingPhase, fraction: Double?)? {
        switch self {
        case .preparingModel: (.preparingModel, nil)
        case .downloadingModel(let fraction): (.downloadingModel, fraction)
        case .loadingModel: (.loadingModel, nil)
        case .transcribing: nil
        case .engineTranscribing: nil
        }
    }
}

/// The running transcription, batch meeting, or export and the jobs behind it: their progress, cancellation,
/// and completion. Results surface through the model; its tasks capture the model, so a running job keeps it alive.
@MainActor
final class ProcessingQueue: ObservableObject {
    @Published private(set) var phase: ProcessingPhase?
    @Published private(set) var fraction: Double?
    @Published private(set) var statusText = ""
    @Published private(set) var title = ""
    @Published private(set) var folder: URL?
    /// Meetings waiting behind the current job, in order, so the list can mark them.
    @Published private(set) var queuedFolders: [URL] = []
    @Published private(set) var cancelling = false
    @Published private(set) var batchTotal = 0
    @Published private(set) var batchIndex = 0
    private(set) var task: Task<Void, Never>?
    private var pendingJobs: [QueuedJob] = [] { didSet { queuedFolders = pendingJobs.map(\.folder) } }
    private(set) var lastOptions: (languages: [String], hints: String, settings: SpeechSettings)?
    unowned let model: AppModel

    init(model: AppModel) { self.model = model }

    var isProcessing: Bool { phase != nil }
    var canCancel: Bool { isProcessing && phase != .finalizingRecording && phase != .writingFiles && !cancelling }
    var isExportingBundle: Bool { phase == .extractingScreens || phase == .exportingBundle }

    func startBatch(_ recordings: [MeetingHistoryItem], process: @escaping (MeetingHistoryItem) async -> Bool) {
        model.cancelModelUnload()
        batchTotal = recordings.count
        batchIndex = 1
        model.prepareSavedTranscription(recordings[0])
        pendingJobs = recordings.map { .batch($0, process: process) }
        task = Task { [model] in await model.processing.runQueue() }
    }

    /// Shows a saved meeting as the job about to run.
    func show(_ item: MeetingHistoryItem) {
        folder = item.folderURL
        title = item.title
        setPhase(.preparingAudio, fraction: 0)
    }

    /// Shows a stopped capture finalizing when no job is running.
    func showFinalizing(_ folder: URL) {
        guard !isProcessing else { return }
        self.folder = folder
        setPhase(.finalizingRecording)
    }

    func cancel() {
        guard canCancel else { return }
        cancelling = true
        statusText = isExportingBundle ? "Cancelling export…" : "Cancelling transcription…"
        task?.cancel()
    }

    func export(_ meeting: MeetingHistoryItem) {
        folder = meeting.folderURL
        model.elapsed = meeting.duration
        setPhase(.extractingScreens, fraction: 0)
        task = Task { [model] in
            var succeeded = false
            do {
                let destination = try await createBundle(for: meeting)
                model.showOutcome(in: meeting.folderURL, message: "Export bundle saved in the meeting folder.")
                NSWorkspace.shared.open(destination)
                succeeded = true
            } catch {
                model.showOutcome(in: meeting.folderURL, message: Task.isCancelled
                    ? "Export cancelled. Existing meeting files and bundle are kept."
                    : "Export failed: \(error.localizedDescription)")
            }
            queueFinished(succeeded: succeeded)
        }
    }

    private func createBundle(for meeting: MeetingHistoryItem) async throws -> URL {
        setPhase(.extractingScreens, fraction: 0)
        let report: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor [weak self] in
                guard let self, self.isExportingBundle, !self.cancelling,
                      fraction >= (self.fraction ?? 0) else { return }
                self.setPhase(fraction < 1 ? .extractingScreens : .exportingBundle, fraction: fraction)
            }
        }
        let work = Task.detached(priority: .utility) {
            try await MeetingBundle.build(for: meeting, progress: report)
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    func enqueue(_ run: ProcessingRun) {
        model.cancelModelUnload()
        pendingJobs.append(.recording(run))
        guard task == nil else { return }
        task = Task { [model] in await model.processing.runQueue() }
    }

    private func runQueue() async {
        var succeeded = true
        while succeeded, !pendingJobs.isEmpty {
            switch pendingJobs.removeFirst() {
            case .batch(let item, let process):
                // A batch ends after its last meeting or at the first that fails or is cancelled.
                let remaining = pendingJobs.filter(\.isBatch).count
                batchIndex = batchTotal - remaining
                if batchIndex > 1, !Task.isCancelled { model.prepareSavedTranscription(item) }
                let processed = Task.isCancelled ? false : await process(item)
                if processed, remaining > 0 { continue }
                let (completed, total, cancelled) = (batchIndex - (processed ? 0 : 1), batchTotal, Task.isCancelled)
                if model.errorMessage == nil {
                    let message = cancelled
                        ? "Transcription cancelled. \(completed) of \(total) finished; remaining recordings are kept."
                        : "Transcribed \(completed) of \(total) recordings."
                    model.completionMessage = message
                    model.accessibilityAnnouncement(message)
                }
                pendingJobs.removeAll(where: \.isBatch) // Recordings stopped meanwhile stay queued.
                (batchTotal, batchIndex) = (0, 0)
                model.refreshHistory()
                succeeded = !cancelled && completed == total
            case .recording(let run):
                folder = run.folder
                do { try await run.stopTask?.value } catch { succeeded = false }
                if succeeded {
                    title = run.title
                    succeeded = await finishRecording(run)
                }
                if !succeeded { pendingJobs.removeAll() }
            }
        }
        queueFinished(succeeded: succeeded)
    }

    private func queueFinished(succeeded: Bool) {
        // A cancelled job ends here; a recording queued behind it is a new job that can report and cancel.
        if cancelling {
            cancelling = false
            if let phase { statusText = phase.statusText }
        }
        guard pendingJobs.isEmpty else {
            task = Task { [model] in await model.processing.runQueue() }
            return
        }
        phase = nil
        fraction = nil
        title = ""
        folder = nil
        statusText = ""
        model.processingDidFinish()
        task = nil
        model.scheduleModelUnload()
        if !succeeded || !model.isCapturing { model.completeTermination(succeeded) }
    }

    /// A capture failure clears the progress only when no job is running to keep its own.
    func clearProgressUnlessRunning() {
        guard task == nil else { return }
        fraction = nil
        phase = nil
    }

    private static func audioDuration(_ audioURL: URL) throws -> Double {
        let audio = try AVAudioFile(forReading: audioURL)
        try Task.checkCancellation()
        return Double(audio.length) / audio.fileFormat.sampleRate
    }

    @discardableResult
    func finishRecording(_ run: ProcessingRun, inBatch: Bool = false) async -> Bool {
        lastOptions = (run.languages, run.hints, run.settings)
        // This job owns its error/retry target, including after an automatic rename.
        var folder = run.folder
        var replacing = run.replacing
        // A fresh recording's m4a, exported while transcription reads the recording directly.
        var export: Task<Void, Error>?
        do {
            try Task.checkCancellation()
            try MeetingArtifacts.recoverTranscript(in: folder)
            if let saved = MeetingArtifacts.meeting(in: folder), !saved.needsTranscription {
                replacing = saved
            }
            await MeetingNotifications.requestPermission()
            var title = run.title
            let recordedAt = run.recordedAt

            let recordingURL = MeetingArtifacts.recordingURL(in: folder)
            let audioURL = folder.appendingPathComponent("audio.m4a")
            let needsAudio = ((try? AVAudioFile(forReading: audioURL).length) ?? 0) == 0
            // Only a capture that just ended can still be finishing its MP4.
            if needsAudio, run.folderTitle != nil {
                setPhase(.finalizingRecording)
                try await AudioExtractor.waitUntilReadable(recordingURL)
            }
            setPhase(.preparingAudio, fraction: 0)
            // Decoded once, for every language pass and speaker labels.
            var meetingAudio = MeetingAudio(url: audioURL)
            defer { meetingAudio.discard() }
            // Set while the m4a is still exporting; caches are keyed on the finished file.
            var audioReady: (@Sendable () async throws -> Void)?
            let duration: Double
            if needsAudio {
                let exportDone = OSAllocatedUnfairLock(initialState: false)
                let exporting = Task {
                    try await AudioExtractor.extract(from: recordingURL, to: audioURL) { [weak self] fraction in
                        Task { @MainActor [weak self] in
                            // Transcription overlaps the export; its progress only shows before transcription starts.
                            guard self?.phase == .preparingAudio else { return }
                            self?.setFraction(fraction)
                        }
                    }
                    exportDone.withLock { $0 = true }
                }
                export = exporting
                let exported: @Sendable () async throws -> Void = {
                    try await withTaskCancellationHandler {
                        try await exporting.value
                    } onCancel: {
                        exporting.cancel()
                    }
                }
                let decoded = MeetingAudio(recording: recordingURL)
                do {
                    duration = Double(try await decoded.load().count) / MeetingAudio.sampleRate
                    meetingAudio = decoded
                    audioReady = { [weak self] in
                        if !exportDone.withLock({ $0 }) {
                            await self?.showSavingAudio()
                        }
                        try await exported()
                    }
                } catch {
                    try Task.checkCancellation()
                    // The export reports a recording it cannot read; otherwise transcribe its m4a as before.
                    try await exported()
                    duration = try Self.audioDuration(audioURL)
                }
            } else {
                duration = try Self.audioDuration(audioURL)
            }
            if !model.isCapturing { model.elapsed = duration }
            if replacing == nil {
                try MeetingArtifacts.writeMetadata(
                    title: title, recordedAt: recordedAt, duration: duration,
                    titleWasProvided: run.titleWasProvided, speechSettings: run.settings, to: folder
                )
            }

            // Only wait for a download of the model this job uses; a retry keeps its meeting's engine.
            if let preparation = model.modelPreparationTask,
               model.modelPreparationSettings.map({ $0.selectedEngine == run.settings.selectedEngine
                   && ($0.selectedEngine != .whisper || $0.model == run.settings.model) }) ?? true {
                setPhase(.preparingModel, fraction: model.modelSetupFraction)
                statusText = model.modelSetupStatus
                try await withTaskCancellationHandler {
                    try await preparation.value
                } onCancel: {
                    preparation.cancel()
                }
                try Task.checkCancellation()
            }
            var segments = try await model.transcriber.transcribe(
                audioURL: audioURL, audio: meetingAudio,
                languages: run.languages, hints: run.hints, settings: run.settings, audioReady: audioReady
            ) { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.updateTranscriptionProgress(progress)
                }
            }

            var speakerWarning: String?
            do {
                segments = try await SpeakerLabels.run(
                    audioURL: audioURL, segments: segments, enabled: run.settings.speakerLabels == true,
                    audioReady: audioReady
                ) {
                    self.setPhase(.labelingSpeakers)
                    return try await self.model.transcriber.detectSpeakers(audio: meetingAudio) { [weak self] fraction in
                        Task { @MainActor [weak self] in
                            guard let self, self.phase == .labelingSpeakers,
                                  !self.cancelling, let fraction = fraction.unitClamped else { return }
                            self.setFraction(fraction)
                            let statusText = "Identifying speakers on this Mac…"
                            if self.statusText != statusText { self.statusText = statusText }
                        }
                    }
                }
            } catch {
                try Task.checkCancellation()
                speakerWarning = "Transcript saved without speaker labels: \(error.localizedDescription)"
            }
            meetingAudio.discard()
            // The folder can be renamed below, so the export must be done first.
            try await audioReady?()

            try Task.checkCancellation()
            setPhase(.writingFiles)
            if !run.titleWasProvided && replacing == nil {
                let generatedTitle = await MeetingTitle.suggestInBackground(
                    from: segments.map(\.text).joined(separator: "\n"))
                try Task.checkCancellation()
                if let generatedTitle {
                    folder = try MeetingArtifacts.renameDirectory(folder, title: generatedTitle, recordedAt: recordedAt)
                    title = generatedTitle
                    self.title = generatedTitle
                }
            } else if replacing == nil, let folderTitle = run.folderTitle, title != folderTitle {
                // The name changed while recording; the folder still carries the one it started with.
                folder = try MeetingArtifacts.renameDirectory(folder, title: title, recordedAt: recordedAt)
            }
            if let replacing {
                try MeetingArtifacts.replaceTranscript(for: replacing, duration: duration, segments: segments, speechSettings: run.settings)
            } else {
                try MeetingArtifacts.write(
                    title: title,
                    recordedAt: recordedAt,
                    duration: duration,
                    segments: segments,
                    titleWasProvided: run.titleWasProvided,
                    speechSettings: run.settings,
                    to: folder
                )
            }

            model.transcriptSaved(in: folder)
            let meeting = MeetingArtifacts.meeting(in: folder)
            if !inBatch {
                model.completionMessage = "Transcript saved."
            }
            if model.exportAfterRecording, let meeting {
                do {
                    _ = try await createBundle(for: meeting)
                    model.completionMessage = "Export bundle saved in the meeting folder."
                } catch {
                    model.completionMessage = Task.isCancelled
                        ? "Transcript saved. Export cancelled; any previous bundle is kept."
                        : "Transcript saved. Export failed: \(error.localizedDescription)"
                }
            }
            if let speakerWarning {
                model.completionMessage = [speakerWarning, model.completionMessage].compactMap { $0 }.joined(separator: "\n")
            }
            if !inBatch { model.accessibilityAnnouncement("Transcript ready for \(title).") }
            await MeetingNotifications.post(
                title: meeting?.title ?? folder.lastPathComponent,
                folder: folder, failed: false
            )
            return true
        } catch {
            // A cancelled export removes its partial file; wait for that before the next job can start.
            if let export {
                export.cancel()
                _ = await export.result
            }
            let failedFolder = folder
            if Task.isCancelled {
                model.showOutcome(in: failedFolder, message: replacing == nil
                    ? "Transcription cancelled. Recording kept; transcribe it from the menu to resume."
                    : "Re-transcription cancelled. Your existing transcript is unchanged.")
                model.refreshHistory()
                return false
            }
            model.transcriptionFailed(in: failedFolder, error: error)
            model.accessibilityAnnouncement("Transcription failed for \(run.title). Open Better Meeting to retry.")
            await MeetingNotifications.post(title: run.title, folder: failedFolder, failed: true)
            return false
        }
    }

    func updateTranscriptionProgress(_ progress: LocalTranscriptionProgress) {
        guard !cancelling else { return }
        guard isProcessing, !isExportingBundle, phase != .labelingSpeakers else { return }

        if let step = progress.modelStep {
            setPhase(step.phase, fraction: step.fraction)
        } else if case .transcribing(let fraction, let language, let pass, let total) = progress {
            setPhase(.transcribing, fraction: fraction)
            let name = TranscriptionLanguage(rawValue: language)?.label ?? language
            statusText = "Transcribing \(name) · pass \(pass) of \(total)…"
        } else if case .engineTranscribing(let fraction) = progress {
            setPhase(.transcribing, fraction: fraction)
            statusText = "Transcribing with Parakeet…"
        }
    }

    /// Transcription can finish before the m4a export it overlaps.
    private func showSavingAudio() {
        guard !cancelling else { return }
        statusText = "Saving audio.m4a…"
    }

    private func setPhase(_ phase: ProcessingPhase, fraction: Double? = nil) {
        self.phase = phase
        statusText = phase.statusText
        setFraction(fraction)
    }

    private func setFraction(_ fraction: Double?) {
        guard AppModel.shownPercent(fraction) != AppModel.shownPercent(self.fraction) else { return }
        self.fraction = fraction
    }
}
