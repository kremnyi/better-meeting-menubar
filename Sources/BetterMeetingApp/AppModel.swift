import AppKit
import AVFoundation
import Combine
import CoreGraphics
import Foundation

enum AppState: Equatable {
    case idle
    case preparing
    case recording
    case failed
}

private struct ProcessingRun {
    let folder: URL
    let recordedAt: Date
    let title: String
    let titleWasProvided: Bool
    let replacing: MeetingHistoryItem?
    let languages: [String]
    let hints: String
    let settings: SpeechSettings
    var stopTask: Task<Void, Error>?
}

enum ProcessingPhase: Equatable {
    case finalizingRecording
    case preparingAudio
    case preparingModel
    case downloadingModel
    case loadingModel
    case transcribing
    case labelingSpeakers
    case writingFiles
    case extractingScreens
    case exportingBundle

    var stepText: String {
        switch self {
        case .finalizingRecording: "Step 1 of 5"
        case .preparingAudio: "Step 2 of 5"
        case .preparingModel, .downloadingModel, .loadingModel: "Step 3 of 5"
        case .transcribing: "Step 4 of 5"
        case .writingFiles: "Step 5 of 5"
        case .labelingSpeakers: "Speaker labels"
        case .extractingScreens: "Step 1 of 2"
        case .exportingBundle: "Step 2 of 2"
        }
    }

    var statusText: String {
        switch self {
        case .finalizingRecording: "Finalizing the recording…"
        case .preparingAudio: "Preparing audio for transcription…"
        case .preparingModel: "Checking the speech model…"
        case .downloadingModel: "Downloading the speech model…"
        case .loadingModel: "Loading the speech model…"
        case .transcribing: "Transcribing…"
        case .labelingSpeakers: "Preparing speaker labels…"
        case .writingFiles: "Writing transcript.md…"
        case .extractingScreens: "Extracting screenshots and screen text…"
        case .exportingBundle: "Writing the export bundle…"
        }
    }
}

private extension LocalTranscriptionProgress {
    /// Setup and transcription share one progress enum; only model steps map onto a processing phase.
    var modelStep: (phase: ProcessingPhase, fraction: Double?)? {
        switch self {
        case .preparingModel: (.preparingModel, nil)
        case .downloadingModel(let fraction): (.downloadingModel, fraction)
        case .loadingModel: (.loadingModel, nil)
        case .transcribing: nil
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var meetingTitle = ""
    @Published private(set) var state: AppState = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var microphoneLevel = 0.0
    @Published private(set) var systemAudioLevel = 0.0
    @Published private(set) var audioWarning = false
    private(set) var recordingID: UUID?
    weak var menuWindow: NSWindow?
    @Published private(set) var statusText = "Ready to record your display and audio."
    @Published private(set) var errorMessage: String?
    @Published private(set) var completedFolder: URL?
    @Published private(set) var outputRoot: URL
    @Published private(set) var privacyPermission: PrivacyPermission?
    @Published private(set) var processingFraction: Double?
    @Published private(set) var processingPhase: ProcessingPhase?
    @Published private(set) var processingStatusText = ""
    @Published private(set) var processingTitle = ""
    @Published private(set) var transcriptionHistory: [MeetingHistoryItem] = []
    @Published var historyQuery = "" {
        didSet { searchHistory() }
    }
    @Published private(set) var searchingHistory = false
    @Published private(set) var unfinishedRecordings: [MeetingHistoryItem] = []
    @Published private(set) var transcriptionBatchTotal = 0
    @Published private(set) var transcriptionBatchIndex = 0
    var isTranscribingBatch: Bool { transcriptionBatchTotal > 0 }
    var transcriptionBatchWaiting: Int { max(0, transcriptionBatchTotal - transcriptionBatchIndex) }
    var isProcessing: Bool { processingPhase != nil }
    var isCapturing: Bool { state == .preparing || state == .recording }
    @Published private(set) var modelReady = false
    @Published private(set) var modelSetupStatus = "Preparing speech model…"
    @Published private(set) var modelSetupFraction: Double?
    @Published private(set) var modelSetupError: String?
    private(set) var modelPreparationTask: Task<Void, Error>?
    @Published private(set) var cancellingTranscription = false
    @Published private(set) var displays: [(id: CGDirectDisplayID, name: String)] = []
    @Published private(set) var microphones: [AVCaptureDevice] = []
    @Published var selectedDisplayID: CGDirectDisplayID {
        didSet { defaults.set(Int(selectedDisplayID), forKey: "displayID") }
    }
    @Published var selectedMicrophoneID: String {
        didSet { defaults.set(selectedMicrophoneID, forKey: "microphoneID") }
    }
    @Published var captureResolution: CaptureResolution {
        didSet { defaults.set(captureResolution.rawValue, forKey: "captureResolution") }
    }
    @Published var captureQuality: CaptureQuality {
        didSet { defaults.set(captureQuality.rawValue, forKey: "captureQuality") }
    }
    @Published var transcriptionLanguages: [String] {
        didSet { defaults.set(transcriptionLanguages, forKey: "transcriptionLanguages") }
    }
    @Published var transcriptionHints: String {
        didSet { defaults.set(transcriptionHints, forKey: "transcriptionHints") }
    }

    @Published var completionMessage: String?
    lazy var calendar = CalendarIntegration(defaults: defaults)
    lazy var updates = AppUpdater { [weak self] in
        guard let self else { return true }
        return state == .preparing || state == .recording || isProcessing
    }
    @Published var automaticUpdateChecks: Bool {
        didSet { defaults.set(automaticUpdateChecks, forKey: "checkUpdatesOnLaunch") }
    }
    @Published var betaUpdates: Bool {
        didSet {
            defaults.set(betaUpdates, forKey: "betaUpdates")
            updates.allowsBetaUpdates = betaUpdates
        }
    }
    @Published var exportAfterRecording: Bool {
        didSet { defaults.set(exportAfterRecording, forKey: "exportAfterRecording") }
    }
    @Published var speechSettings: SpeechSettings {
        didSet { defaults.set(try? JSONEncoder().encode(speechSettings), forKey: "speechSettings") }
    }

    func speechModelChanged() {
        modelReady = false
        prepareSpeechModel()
    }

    private let defaults: UserDefaults
    private let recorder = MeetingRecorder()
    private let transcriber = LocalTranscriber()
    private var activeFolder: URL?
    private var recordedAt: Date?
    private var titleWasProvided = true
    private var timer: Timer?
    private var audioWarningTask: Task<Void, Never>?
    private var quitWhenFinished = false
    private var startTask: Task<Void, Never>?
    private(set) var processingTask: Task<Void, Never>?
    private var pendingRuns: [ProcessingRun] = []
    private var processingFolder: URL?
    private(set) var historySearchTask: Task<Void, Never>?
    private(set) var historyRefreshTask: Task<Void, Never>?
    private var completedMeetings: [MeetingHistoryItem] = []
    private var lastTranscriptionOptions: (languages: [String], hints: String, settings: SpeechSettings)?

    private var retryableMeeting: MeetingHistoryItem? {
        (unfinishedRecordings + completedMeetings).first { $0.folderURL == completedFolder }
            ?? completedFolder.flatMap { MeetingArtifacts.meeting(in: $0) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        outputRoot = defaults.url(forKey: "outputFolder")
            ?? documents.appendingPathComponent("Better Meetings", isDirectory: true)
        selectedDisplayID = CGDirectDisplayID(clamping: defaults.integer(forKey: "displayID"))
        selectedMicrophoneID = defaults.string(forKey: "microphoneID") ?? ""
        captureResolution = CaptureResolution(rawValue: defaults.integer(forKey: "captureResolution")) ?? .pixels1440
        captureQuality = CaptureQuality(rawValue: defaults.integer(forKey: "captureQuality")) ?? .standard
        let previousLanguage = TranscriptionLanguage(rawValue: defaults.string(forKey: "transcriptionLanguage") ?? "")
        transcriptionLanguages = TranscriptionLanguage.candidates(from:
            defaults.stringArray(forKey: "transcriptionLanguages")
                ?? previousLanguage.map { [$0.rawValue] }
                ?? defaults.stringArray(forKey: "candidateLanguages") ?? []
        )
        transcriptionHints = defaults.string(forKey: "transcriptionHints") ?? ""
        exportAfterRecording = defaults.bool(forKey: "exportAfterRecording")
        automaticUpdateChecks = defaults.bool(forKey: "checkUpdatesOnLaunch")
        betaUpdates = defaults.bool(forKey: "betaUpdates")
        speechSettings = defaults.data(forKey: "speechSettings")
            .flatMap { try? JSONDecoder().decode(SpeechSettings.self, from: $0) } ?? SpeechSettings()
        if (try? speechSettings.validate()) == nil { speechSettings = SpeechSettings() }
        modelReady = LocalTranscriber.cachedModelFolder(model: speechSettings.model) != nil
        updates.allowsBetaUpdates = betaUpdates
        recorder.onUnexpectedStop = { [weak self] error in
            self?.captureStoppedExternally(with: error)
        }
        refreshHistory()
    }

    var elapsedText: String {
        Timecode.string(elapsed)
    }

    var primaryButtonTitle: String {
        switch state {
        case .recording: "Stop recording"
        case .preparing: "Preparing…"
        case .idle: "Start recording"
        case .failed:
            if privacyPermission == .screenRecording {
                "Restart Better Meeting"
            } else if retryableMeeting != nil {
                "Retry transcription"
            } else {
                "Try again"
            }
        }
    }

    var primaryButtonSymbol: String {
        if state == .recording {
            return "stop.fill"
        }
        if state == .failed, privacyPermission == .screenRecording || retryableMeeting != nil {
            return "arrow.clockwise"
        }
        return "record.circle"
    }

    var captureAccessNotice: (text: String, isSecondary: Bool) {
        if let privacyPermission {
            return (privacyPermission.accessNeededText, false)
        }

        if state == .recording {
            return ("Stop here or from the macOS recording menu", true)
        }

        let screenReady = CGPreflightScreenCaptureAccess()
        let microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        if screenReady && microphone == .authorized {
            return ("Screen, system audio, and mic ready", true)
        }

        if !screenReady {
            return (microphone == .authorized
                ? "Screen Recording access needed"
                : "Screen Recording and microphone access needed", false)
        }

        return microphone == .notDetermined
            ? ("Start recording to grant microphone access", false)
            : ("Microphone access needed", false)
    }

    var captureAccessSettingsURL: URL? {
        guard state == .idle, !isProcessing else { return nil }
        if !CGPreflightScreenCaptureAccess() {
            return PrivacyPermission.screenRecording.settingsURL
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted: return PrivacyPermission.microphone.settingsURL
        default: return nil
        }
    }

    var captureAccessSymbol: String {
        if state == .recording {
            return "stop.circle"
        }
        return privacyPermission == nil ? "shield" : "exclamationmark.shield"
    }

    func primaryAction() {
        if state == .recording {
            beginProcessing(stopCapture: true)
        } else if state == .failed, privacyPermission == .screenRecording {
            restartApplication()
        } else if state == .failed, let item = retryableMeeting {
            retryTranscription(item, languages: lastTranscriptionOptions?.languages, hints: lastTranscriptionOptions?.hints, settings: lastTranscriptionOptions?.settings)
        } else if state == .idle || state == .failed {
            startRecording()
        }
    }

    func refreshInputs() {
        displays = NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            return (number.uint32Value, screen.localizedName)
        }
        microphones = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified
        ).devices
    }

    func prepareSpeechModel() {
        guard !modelReady, !isProcessing, state == .idle || state == .recording else { return }
        let selectedModel = speechSettings.model
        prepareSpeechModel { [transcriber] progress in
            _ = try await transcriber.prepare(model: selectedModel, progressHandler: progress)
        }
    }

    func prepareSpeechModel(
        _ prepare: @escaping (@escaping @Sendable (LocalTranscriptionProgress) -> Void) async throws -> Void
    ) {
        guard modelPreparationTask == nil else { return }
        modelReady = false
        modelSetupError = nil
        modelSetupFraction = nil
        modelSetupStatus = "Preparing speech model…"
        modelPreparationTask = Task {
            defer { modelPreparationTask = nil }
            do {
                try await prepare { [weak self] progress in
                    Task { @MainActor [weak self] in self?.updateModelSetupProgress(progress) }
                }
                modelReady = true
                modelSetupStatus = "Speech model ready"
            } catch {
                modelReady = false
                if error is CancellationError {
                    modelSetupStatus = "Speech model download cancelled"
                } else {
                    modelSetupError = error.localizedDescription
                    modelSetupStatus = "Speech model unavailable"
                }
                throw error
            }
        }
    }

    private func updateModelSetupProgress(_ progress: LocalTranscriptionProgress) {
        guard modelPreparationTask != nil, let step = progress.modelStep else { return }
        modelSetupStatus = step.phase.statusText
        modelSetupFraction = step.fraction
        if isProcessing,
           [.preparingModel, .downloadingModel, .loadingModel].contains(processingPhase) {
            updateTranscriptionProgress(progress)
        }
    }

    func retryTranscription(_ item: MeetingHistoryItem, languages: [String]? = nil, hints: String? = nil, settings: SpeechSettings? = nil) {
        guard !isProcessing, !isTranscribingBatch, state == .idle || state == .failed else { return }
        prepareSavedTranscription(item)
        enqueue(run(
            for: item, replacing: item.needsTranscription ? nil : item,
            languages: languages, hints: hints,
            settings: settings ?? MeetingArtifacts.speechSettings(in: item.folderURL)
        ))
    }

    func transcribeAllRecordings() {
        transcribeAllRecordings { [self] item in
            await finishRecording(run(for: item, replacing: nil), inBatch: true)
        }
    }

    func transcribeAllRecordings(_ process: @escaping (MeetingHistoryItem) async -> Bool) {
        guard state == .idle, !isProcessing, !isTranscribingBatch, !unfinishedRecordings.isEmpty else { return }
        let recordings = unfinishedRecordings
        transcriptionBatchTotal = recordings.count
        transcriptionBatchIndex = 1
        prepareSavedTranscription(recordings[0])
        processingTask = Task {
            var completed = 0
            for (index, item) in recordings.enumerated() {
                guard !Task.isCancelled else { break }
                transcriptionBatchIndex = index + 1
                if index > 0 { prepareSavedTranscription(item) }
                guard await process(item) else { break }
                completed += 1
                completedFolder = item.folderURL
            }
            let cancelled = Task.isCancelled
            if errorMessage == nil {
                completionMessage = cancelled
                    ? "Transcription cancelled. \(completed) of \(recordings.count) finished; remaining recordings are kept."
                    : "Transcribed \(completed) of \(recordings.count) recordings."
            }
            transcriptionBatchTotal = 0
            transcriptionBatchIndex = 0
            refreshHistory()
            processingQueueFinished(succeeded: !cancelled && completed == recordings.count)
        }
    }

    private func run(
        for item: MeetingHistoryItem, replacing: MeetingHistoryItem?,
        languages: [String]? = nil, hints: String? = nil, settings: SpeechSettings? = nil
    ) -> ProcessingRun {
        ProcessingRun(
            folder: item.folderURL,
            recordedAt: item.recordedAt,
            title: item.title,
            titleWasProvided: item.titleWasProvided,
            replacing: replacing,
            languages: languages ?? transcriptionLanguages,
            hints: hints ?? transcriptionHints,
            settings: settings ?? MeetingArtifacts.speechSettings(in: item.folderURL) ?? speechSettings
        )
    }

    private func prepareSavedTranscription(_ item: MeetingHistoryItem) {
        completionMessage = nil
        completedFolder = nil
        if state == .failed { state = .idle }
        processingFolder = item.folderURL
        processingTitle = item.title
        if !isCapturing { elapsed = item.duration }
        errorMessage = nil
        privacyPermission = nil
        setProcessingPhase(.preparingAudio, fraction: 0)
    }

    var canCancelTranscription: Bool {
        isProcessing && processingPhase != .finalizingRecording
            && processingPhase != .writingFiles && !cancellingTranscription
    }

    func cancelTranscription() {
        guard canCancelTranscription else { return }
        cancellingTranscription = true
        processingStatusText = isExportingBundle ? "Cancelling export…" : "Cancelling transcription…"
        processingTask?.cancel()
    }

    var isExportingBundle: Bool {
        processingPhase == .extractingScreens || processingPhase == .exportingBundle
    }

    func exportBundle(_ meeting: MeetingHistoryItem) {
        guard state == .idle, !isProcessing else { return }
        elapsed = meeting.duration
        completionMessage = nil
        errorMessage = nil
        setProcessingPhase(.extractingScreens, fraction: 0)
        processingTask = Task {
            var succeeded = false
            do {
                let destination = try await createBundle(for: meeting)
                completedFolder = meeting.folderURL
                completionMessage = "Export bundle saved in the meeting folder."
                NSWorkspace.shared.open(destination)
                succeeded = true
            } catch {
                completedFolder = meeting.folderURL
                completionMessage = Task.isCancelled
                    ? "Export cancelled. Existing meeting files and bundle are kept."
                    : "Export failed: \(error.localizedDescription)"
            }
            processingQueueFinished(succeeded: succeeded)
        }
    }

    private func createBundle(for meeting: MeetingHistoryItem) async throws -> URL {
        setProcessingPhase(.extractingScreens, fraction: 0)
        let report: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor [weak self] in
                guard let self, self.isExportingBundle, !self.cancellingTranscription,
                      fraction >= (self.processingFraction ?? 0) else { return }
                self.setProcessingPhase(fraction < 1 ? .extractingScreens : .exportingBundle, fraction: fraction)
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

    func dismissFailure() {
        guard state == .failed else { return }
        state = .idle
        errorMessage = nil
        privacyPermission = nil
        meetingTitle = ""
        refreshHistory()
    }

    func terminationReply(
        confirm: @MainActor (NSAlert) -> NSApplication.ModalResponse = { $0.runModal() }
    ) -> NSApplication.TerminateReply {
        guard state == .recording || isProcessing || state == .preparing else {
            return .terminateNow
        }
        quitWhenFinished = false
        let alert = NSAlert()
        if state == .preparing {
            alert.messageText = "Setup is still running"
            alert.informativeText = "Quit now to stop setup. A recording that already started is saved when possible."
            alert.addButton(withTitle: "Keep open")
            alert.addButton(withTitle: "Quit Anyway")
            guard confirm(alert) == .alertSecondButtonReturn else { return .terminateCancel }
            startTask?.cancel()
            discardUnstartedFolder()
            return .terminateNow
        }
        alert.messageText = state == .recording ? "Finish this recording and quit?" : "Quit when transcription finishes?"
        if state == .recording && isProcessing { alert.messageText = "Finish this recording, then quit when transcription finishes?" }
        if isTranscribingBatch { alert.messageText = "Quit when all queued transcriptions finish?" }
        if isExportingBundle { alert.messageText = "Quit when export finishes?" }
        alert.informativeText = isExportingBundle
            ? "Better Meeting will stay open until the export bundle is saved."
            : "Better Meeting will stay open until the recording and transcript are saved."
        if isTranscribingBatch { alert.informativeText = "Better Meeting will stay open until the queue finishes. An error or cancellation will keep the app open." }
        alert.addButton(withTitle: state == .recording ? "Finish and quit" : "Wait and quit")
        alert.addButton(withTitle: "Keep open")
        guard confirm(alert) == .alertFirstButtonReturn else { return .terminateCancel }
        // Processing may finish while the native confirmation is open.
        guard state == .recording || isProcessing else {
            return state == .idle ? .terminateNow : .terminateCancel
        }
        quitWhenFinished = true
        if state == .recording { beginProcessing(stopCapture: true) }
        // terminateLater keeps AppKit in a modal loop and stalls menu-bar updates.
        return .terminateCancel
    }

    func setOutputFolder(_ url: URL) {
        outputRoot = url
        defaults.set(url, forKey: "outputFolder")
        completedMeetings = []
        unfinishedRecordings = []
        transcriptionHistory = []
        searchHistory()
        refreshHistory()
    }

    func completeTermination(_ success: Bool, terminate: @MainActor () -> Void = { NSApp.terminate(nil) }) {
        if quitWhenFinished {
            quitWhenFinished = false
            if success { terminate() }
        }
    }

    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose where meetings are saved"
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = outputRoot

        if panel.runModal() == .OK, let url = panel.url {
            setOutputFolder(url)
        }
    }

    func refreshHistory(
        scan: @escaping @Sendable (URL) -> [MeetingHistoryItem] = { MeetingArtifacts.meetings(in: $0) }
    ) {
        historyRefreshTask?.cancel()
        let root = outputRoot
        historyRefreshTask = Task.detached(priority: .userInitiated) { [weak self] in
            let meetings = scan(root)
            await self?.showHistory(meetings)
        }
    }

    private func showHistory(_ meetings: [MeetingHistoryItem]) {
        guard !Task.isCancelled else { return }
        completedMeetings = meetings.filter { !$0.needsTranscription }
        unfinishedRecordings = meetings.filter(\.needsTranscription)
        searchHistory()
    }

    var historyListHeight: CGFloat {
        6 * 48
    }

    private var meetingsByRecency: [MeetingHistoryItem] {
        (completedMeetings + unfinishedRecordings).sorted { $0.recordedAt > $1.recordedAt }
    }

    private func searchHistory() {
        historySearchTask?.cancel()
        let query = historyQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchingHistory = false
            transcriptionHistory = meetingsByRecency
            return
        }
        let meetings = meetingsByRecency
        searchingHistory = true
        historySearchTask = Task.detached(priority: .userInitiated) { [weak self] in
            let matches = MeetingArtifacts.search(meetings, query: query)
            await self?.showSearchResults(matches)
        }
    }

    private func showSearchResults(_ matches: [MeetingHistoryItem]) {
        guard !Task.isCancelled else { return }
        transcriptionHistory = matches
        searchingHistory = false
    }

    func copyTranscript(_ meeting: MeetingHistoryItem, to pasteboard: NSPasteboard = .general) throws {
        let text = try String(contentsOf: meeting.folderURL.appendingPathComponent("transcript.md"), encoding: .utf8)
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { throw MeetingActionError.clipboardUnavailable }
    }

    func renameMeeting(_ meeting: MeetingHistoryItem) {
        guard state == .idle, !isProcessing else { return }
        let alert = NSAlert()
        alert.messageText = "Rename meeting"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        nameField.stringValue = meeting.title
        nameField.setAccessibilityLabel("Meeting name")
        alert.accessoryView = nameField
        alert.window.initialFirstResponder = nameField
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let folder = try MeetingArtifacts.renameMeeting(meeting, to: nameField.stringValue)
            if completedFolder == meeting.folderURL { completedFolder = folder }
        } catch {
            NSAlert(error: error).runModal()
        }
        refreshHistory()
    }

    func openMeetingsFolder() {
        try? FileManager.default.createDirectory(
            at: outputRoot,
            withIntermediateDirectories: true
        )
        NSWorkspace.shared.open(outputRoot)
    }

    private func restartApplication() {
        statusText = "Restarting Better Meeting…"

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL,
            configuration: configuration
        ) { [weak self] _, error in
            Task { @MainActor [weak self] in
                if let error {
                    self?.fail(error)
                } else {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    func startCalendarRecording(_ event: CalendarEvent) {
        guard state == .idle else { return }
        startRecording(calendarEvent: event)
    }

    private func startRecording(calendarEvent: CalendarEvent? = nil) {
        guard state == .idle || state == .failed else { return }
        stopTimer()
        elapsed = 0
        state = .preparing
        statusText = "Checking screen and microphone access…"
        errorMessage = nil
        completedFolder = nil
        privacyPermission = nil
        activeFolder = nil
        recordedAt = nil

        let manualTitle = meetingTitle
        startTask = Task {
            defer { startTask = nil }
            do {
                try Task.checkCancellation()
                try await recorder.requestPermissions()
                await MeetingNotifications.requestPermission()

                // Resolve only the exact event the user clicked, never a title/time match.
                let event: CalendarEvent?
                if let calendarEvent {
                    event = try await calendar.eventForRecording(id: calendarEvent.id)
                } else {
                    event = nil
                }
                let title = event?.title ?? manualTitle
                meetingTitle = title
                titleWasProvided = !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let startedAt = Date()
                let folder = try MeetingArtifacts.createDirectory(
                    in: outputRoot,
                    title: title,
                    recordedAt: startedAt
                )
                let recordingURL = folder.appendingPathComponent("recording.mp4")
                try event?.attach(to: folder, recordedAt: startedAt)

                activeFolder = folder
                recordedAt = startedAt
                try await recorder.start(
                    to: recordingURL, displayID: selectedDisplayID, microphoneID: selectedMicrophoneID,
                    resolution: captureResolution, quality: captureQuality
                )
                recordingDidStart(at: startedAt)
            } catch {
                discardUnstartedFolder()
                fail(error)
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
            fail(error)
            return
        }

        beginProcessing(stopCapture: false)
    }

    private func beginProcessing(stopCapture: Bool) {
        if let recordedAt {
            elapsed = Date().timeIntervalSince(recordedAt)
        }
        stopTimer()
        guard var run = takeCaptureRun() else {
            fail(AppError.missingRecording)
            return
        }
        state = .idle
        processingFolder = run.folder
        if !isProcessing { setProcessingPhase(.finalizingRecording) }
        if stopCapture {
            run.stopTask = Task { try await recorder.stop() }
        }
        enqueue(run)
    }

    private func takeCaptureRun() -> ProcessingRun? {
        guard let folder = activeFolder, let recordedAt else { return nil }
        activeFolder = nil
        self.recordedAt = nil
        return ProcessingRun(
            folder: folder,
            recordedAt: recordedAt,
            title: meetingTitle,
            titleWasProvided: titleWasProvided,
            replacing: nil,
            languages: transcriptionLanguages,
            hints: transcriptionHints,
            settings: speechSettings
        )
    }

    private func enqueue(_ run: ProcessingRun) {
        pendingRuns.append(run)
        guard processingTask == nil else { return }
        processingTask = Task { await runProcessingQueue() }
    }

    private func runProcessingQueue() async {
        var succeeded = true
        while !pendingRuns.isEmpty {
            let run = pendingRuns.removeFirst()
            if let stopTask = run.stopTask {
                do {
                    try await stopTask.value
                } catch {
                    fail(error)
                    succeeded = false
                    pendingRuns.removeAll()
                    break
                }
            }
            processingFolder = run.folder
            processingTitle = run.title
            if !(await finishRecording(run)) {
                succeeded = false
                pendingRuns.removeAll()
                break
            }
        }
        processingQueueFinished(succeeded: succeeded)
    }

    private func processingQueueFinished(succeeded: Bool) {
        guard pendingRuns.isEmpty else {
            processingTask = Task { await runProcessingQueue() }
            return
        }
        finishProcessingUI()
        processingTask = nil
        cancellingTranscription = false
        if !isCapturing { completeTermination(succeeded) }
    }

    private func finishProcessingUI() {
        processingPhase = nil
        processingFraction = nil
        processingTitle = ""
        processingFolder = nil
        processingStatusText = ""
        guard !isCapturing else { return }
        elapsed = 0
        meetingTitle = ""
        titleWasProvided = true
        if state == .idle {
            errorMessage = nil
            privacyPermission = nil
        }
    }

    @discardableResult
    private func finishRecording(_ run: ProcessingRun, inBatch: Bool = false) async -> Bool {
        lastTranscriptionOptions = (run.languages, run.hints, run.settings)
        do {
            try Task.checkCancellation()
            await MeetingNotifications.requestPermission()
            var folder = run.folder
            var title = run.title
            let recordedAt = run.recordedAt

            let recordingURL = folder.appendingPathComponent("recording.mp4")
            let audioURL = folder.appendingPathComponent("audio.m4a")
            setProcessingPhase(.preparingAudio, fraction: 0)
            if ((try? AVAudioFile(forReading: audioURL).length) ?? 0) == 0 {
                try await AudioExtractor.extract(from: recordingURL, to: audioURL) { [weak self] fraction in
                    Task { @MainActor [weak self] in
                        guard self?.processingPhase == .preparingAudio else { return }
                        self?.processingFraction = fraction
                    }
                }
            }
            let audio = try AVAudioFile(forReading: audioURL)
            try Task.checkCancellation()
            let duration = Double(audio.length) / audio.fileFormat.sampleRate
            if !isCapturing { elapsed = duration }
            if run.replacing == nil {
                try MeetingArtifacts.writeMetadata(
                    title: title, recordedAt: recordedAt, duration: duration,
                    titleWasProvided: run.titleWasProvided, speechSettings: run.settings, to: folder
                )
            }

            if let preparation = modelPreparationTask {
                setProcessingPhase(.preparingModel, fraction: modelSetupFraction)
                processingStatusText = modelSetupStatus
                try await withTaskCancellationHandler {
                    try await preparation.value
                } onCancel: {
                    preparation.cancel()
                }
                try Task.checkCancellation()
            }
            var segments = try await transcriber.transcribe(
                audioURL: audioURL, languages: run.languages, hints: run.hints, settings: run.settings
            ) { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.updateTranscriptionProgress(progress)
                }
            }

            var speakerWarning: String?
            do {
                segments = try await SpeakerLabels.run(
                    audioURL: audioURL, segments: segments, enabled: run.settings.speakerLabels == true
                ) {
                    self.setProcessingPhase(.labelingSpeakers)
                    return try await SpeakerLabels.detect(
                        audioURL: audioURL, downloadBase: LocalTranscriber.defaultDownloadBase
                    ) { [weak self] fraction in
                        Task { @MainActor [weak self] in
                            guard let self, self.processingPhase == .labelingSpeakers,
                                  !self.cancellingTranscription, fraction.isFinite else { return }
                            self.processingFraction = min(max(fraction, 0), 1)
                            self.processingStatusText = "Identifying speakers on this Mac…"
                        }
                    }
                }
            } catch {
                try Task.checkCancellation()
                speakerWarning = "Transcript saved without speaker labels: \(error.localizedDescription)"
            }

            try Task.checkCancellation()
            setProcessingPhase(.writingFiles)
            if !run.titleWasProvided && run.replacing == nil {
                let generatedTitle = await Task.detached(priority: .utility) {
                    MeetingTitle.suggest(from: segments.map(\.text).joined(separator: "\n"))
                }.value
                if let generatedTitle {
                    folder = try MeetingArtifacts.renameDirectory(folder, title: generatedTitle, recordedAt: recordedAt)
                    title = generatedTitle
                    processingTitle = generatedTitle
                }
            }
            if let replacing = run.replacing {
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

            completedFolder = folder
            modelReady = LocalTranscriber.cachedModelFolder(model: run.settings.model) != nil
            modelSetupError = nil
            refreshHistory()
            let meeting = MeetingArtifacts.meeting(in: folder)
            if !inBatch {
                completionMessage = "Transcript saved."
            }
            if exportAfterRecording, let meeting {
                do {
                    _ = try await createBundle(for: meeting)
                    completionMessage = "Export bundle saved in the meeting folder."
                } catch {
                    completionMessage = Task.isCancelled
                        ? "Transcript saved. Export cancelled; any previous bundle is kept."
                        : "Transcript saved. Export failed: \(error.localizedDescription)"
                }
            }
            if let speakerWarning {
                completionMessage = [speakerWarning, completionMessage].compactMap { $0 }.joined(separator: "\n")
            }
            await MeetingNotifications.post(
                title: meeting?.title ?? folder.lastPathComponent,
                folder: folder, failed: false
            )
            return true
        } catch {
            completedFolder = run.folder
            if Task.isCancelled {
                completionMessage = run.replacing == nil
                    ? "Transcription cancelled. Recording kept; choose it from the Transcribe all menu to resume."
                    : "Re-transcription cancelled. Your existing transcript is unchanged."
                refreshHistory()
                return false
            }
            failProcessing(error, folder: run.folder)
            await MeetingNotifications.post(title: run.title, folder: run.folder, failed: true)
            return false
        }
    }

    // ponytail: background failure while recording is not shown as its own screen.
    private func failProcessing(_ error: Error, folder: URL) {
        completedFolder = folder
        guard state == .idle else { return }
        fail(error)
    }

    func recordingDidStart(at startDate: Date) {
        stopTimer()
        completionMessage = nil
        let recordingID = UUID()
        self.recordingID = recordingID
        elapsed = 0
        state = .recording
        statusText = "Recording the selected display, system audio, and microphone."
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.state == .recording, self.recordingID == recordingID else { return }
                self.elapsed = Date().timeIntervalSince(startDate)
                self.microphoneLevel = self.recorder.audioLevel(microphone: true)
                self.systemAudioLevel = self.recorder.audioLevel(microphone: false)
                self.checkRecordingAudio(elapsed: self.elapsed, audioDetected: self.recorder.hasDetectedAudio)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func checkRecordingAudio(elapsed: TimeInterval, audioDetected: Bool) {
        guard state == .recording else { return }
        let warning = elapsed >= 30 && !audioDetected
        guard audioWarning != warning else { return }
        audioWarning = warning
        if warning, menuWindow?.isVisible != true, let recordingID {
            audioWarningTask = Task {
                await MeetingNotifications.post(MeetingNotifications.audioWarning(recordingID: recordingID))
            }
        } else if !warning {
            clearAudioWarning()
        }
    }

    private func clearAudioWarning() {
        audioWarningTask?.cancel()
        audioWarningTask = nil
        if let recordingID { MeetingNotifications.remove(recordingID.uuidString) }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        clearAudioWarning()
        audioWarning = false
        recordingID = nil
        microphoneLevel = 0
        systemAudioLevel = 0
    }

    private func updateTranscriptionProgress(_ progress: LocalTranscriptionProgress) {
        guard !cancellingTranscription else { return }
        guard isProcessing, !isExportingBundle, processingPhase != .labelingSpeakers else { return }

        if let step = progress.modelStep {
            setProcessingPhase(step.phase, fraction: step.fraction)
        } else if case .transcribing(let fraction, let language, let pass, let total) = progress {
            setProcessingPhase(.transcribing, fraction: fraction)
            let name = TranscriptionLanguage(rawValue: language)?.label ?? language
            processingStatusText = "Transcribing \(name) · pass \(pass) of \(total)…"
        }
    }

    private func setProcessingPhase(_ phase: ProcessingPhase, fraction: Double? = nil) {
        processingPhase = phase
        processingStatusText = phase.statusText
        processingFraction = fraction
    }

    func fail(_ error: Error) {
        stopTimer()
        state = .failed
        statusText = "Couldn’t finish this recording."
        if processingTask == nil {
            processingFraction = nil
            processingPhase = nil
        }
        errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        if let folder = processingFolder ?? activeFolder {
            completedFolder = folder
        }
        refreshHistory()
        completeTermination(false)

        switch error as? RecorderError {
        case .screenPermissionDenied:
            privacyPermission = .screenRecording
        case .microphonePermissionDenied:
            privacyPermission = .microphone
        default:
            privacyPermission = nil
        }
    }
}

enum PrivacyPermission: Equatable {
    case screenRecording
    case microphone

    var accessNeededText: String {
        switch self {
        case .screenRecording: "Screen access needed"
        case .microphone: "Microphone access needed"
        }
    }

    var settingsURL: URL? {
        let anchor = switch self {
        case .screenRecording: "Privacy_ScreenCapture"
        case .microphone: "Privacy_Microphone"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    }
}

enum AppError: LocalizedError {
    case missingRecording

    var errorDescription: String? {
        switch self {
        case .missingRecording:
            "The active recording folder is missing. Start a new recording."
        }
    }
}
