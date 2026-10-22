import AppKit
import AVFoundation
import Combine
import WhisperKit

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
    var folderTitle: String?
}

private enum QueuedJob {
    case recording(ProcessingRun), batch(MeetingHistoryItem, process: (MeetingHistoryItem) async -> Bool)
    var folder: URL { switch self { case .recording(let run): run.folder; case .batch(let item, _): item.folderURL } }
    var isBatch: Bool { if case .batch = self { true } else { false } }
}

extension LocalTranscriptionProgress {
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

@MainActor
final class ProcessingQueue: ObservableObject {
    @Published var phase: ProcessingPhase?
    @Published var fraction: Double?
    @Published private(set) var statusText = ""
    @Published private(set) var title = ""
    @Published private(set) var folder: URL?
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

    func show(_ item: MeetingHistoryItem) {
        folder = item.folderURL
        title = item.title
        setPhase(.preparingAudio, fraction: 0)
    }

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
                model.showJobResult(in: meeting.folderURL)
                model.completionMessage = "Export bundle saved in the meeting folder."
                NSWorkspace.shared.open(destination)
                succeeded = true
            } catch {
                model.showJobResult(in: meeting.folderURL)
                model.completionMessage = Task.isCancelled
                    ? "Export cancelled. Existing meeting files and bundle are kept."
                    : "Export failed: \(error.localizedDescription)"
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
        jobs: while succeeded, !pendingJobs.isEmpty {
            switch pendingJobs.removeFirst() {
            case .batch(let item, let process):
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
                    // Break so the next job runs in a new task this cancellation does not reach.
                    if Task.isCancelled { break jobs }
                }
            }
        }
        queueFinished(succeeded: succeeded)
    }

    private func queueFinished(succeeded: Bool) {
        // Reset before a queued job starts, so that job can report and cancel.
        if cancelling {
            cancelling = false
            if let phase { statusText = phase.statusText }
        }
        guard pendingJobs.isEmpty else {
            // A failure cancels Wait and quit, even when a later job succeeds.
            if !succeeded { model.completeTermination(false) }
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

    private static func audioDuration(_ audioURL: URL) throws -> Double {
        let audio = try AVAudioFile(forReading: audioURL)
        return Double(audio.length) / audio.fileFormat.sampleRate
    }

    @discardableResult
    func finishRecording(_ run: ProcessingRun, inBatch: Bool = false) async -> Bool {
        lastOptions = (run.languages, run.hints, run.settings)
        var folder = run.folder
        var replacing = run.replacing
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
            let audioURL = folder.appendingPathComponent("audio.m4a")
            let (meetingAudio, duration, audioReady) = try await prepareAudio(for: run, to: audioURL, export: &export)
            defer { meetingAudio.discard() }
            if !model.isCapturing { model.elapsed = duration }
            if replacing == nil {
                try MeetingArtifacts.writeMetadata(
                    title: title, recordedAt: recordedAt, duration: duration,
                    titleWasProvided: run.titleWasProvided, speechSettings: run.settings, to: folder
                )
            }

            try await waitForModel(run.settings)
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
                model.transcriptionCancelled(in: failedFolder)
                model.completionMessage = replacing == nil
                    ? "Transcription cancelled. Recording kept; transcribe it from the menu to resume."
                    : "Re-transcription cancelled. Your existing transcript is unchanged."
                return false
            }
            model.transcriptionFailed(in: failedFolder, error: error)
            model.accessibilityAnnouncement("Transcription failed for \(run.title). Open Better Meeting to retry.")
            await MeetingNotifications.post(title: run.title, folder: failedFolder, failed: true)
            return false
        }
    }

    /// Starts the m4a export when it is missing; the returned audio can be transcribed before the export ends.
    private func prepareAudio(
        for run: ProcessingRun, to audioURL: URL, export: inout Task<Void, Error>?
    ) async throws -> (audio: MeetingAudio, duration: Double, ready: (@Sendable () async throws -> Void)?) {
        let recordingURL = MeetingArtifacts.recordingURL(in: run.folder)
        let needsAudio = ((try? AVAudioFile(forReading: audioURL).length) ?? 0) == 0
        // Only a capture that just ended (folderTitle set) can still be finishing its MP4.
        if needsAudio, run.folderTitle != nil {
            setPhase(.finalizingRecording)
            try await AudioExtractor.waitUntilReadable(recordingURL)
        }
        setPhase(.preparingAudio, fraction: 0)
        guard needsAudio else { return (MeetingAudio(url: audioURL), try Self.audioDuration(audioURL), nil) }
        let exporting = Task {
            try await AudioExtractor.extract(from: recordingURL, to: audioURL) { [weak self] fraction in
                Task { @MainActor [weak self] in
                    guard self?.phase == .preparingAudio else { return }
                    self?.setFraction(fraction)
                }
            }
        }
        export = exporting
        let exported: @Sendable () async throws -> Void = {
            try await withTaskCancellationHandler {
                try await exporting.value
            } onCancel: {
                exporting.cancel()
            }
        }
        let decoded = MeetingAudio(url: recordingURL)
        do {
            let duration = Double(try await decoded.load().count) / Double(WhisperKit.sampleRate)
            // Awaited while the m4a is still exporting; caches are keyed on the finished file.
            return (decoded, duration, { [weak self] in
                await MainActor.run { [weak self] in
                    if let self, !self.cancelling { self.statusText = "Saving audio.m4a…" }
                }
                try await exported()
            })
        } catch {
            try Task.checkCancellation()
            // The export reports a recording it cannot read; otherwise transcribe its m4a.
            try await exported()
            return (MeetingAudio(url: audioURL), try Self.audioDuration(audioURL), nil)
        }
    }

    /// Waits for a model preparation or Options download this job needs.
    private func waitForModel(_ settings: SpeechSettings) async throws {
        if let preparation = model.modelPreparationTask,
           model.modelPreparationSettings.map({ $0.selectedEngine == settings.selectedEngine
               && ($0.selectedEngine != .whisper || $0.model == settings.model) }) ?? true {
            setPhase(.preparingModel, fraction: model.modelSetupFraction)
            statusText = model.modelSetupStatus
            try await withTaskCancellationHandler {
                try await preparation.value
            } onCancel: {
                preparation.cancel()
            }
            try Task.checkCancellation()
        }
        // Poll, not await: an Options download would race this job into the same folder, and cancel must end only the wait.
        if model.modelDownloadKind?.isUsed(by: settings) == true {
            setPhase(.downloadingModel)
            while model.modelDownloadKind?.isUsed(by: settings) == true {
                setFraction(model.modelDownload?.fraction)
                try await Task.sleep(for: .milliseconds(250))
            }
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
