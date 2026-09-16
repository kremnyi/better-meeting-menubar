import AppKit
import AVFoundation
import Combine
import CoreGraphics
import Foundation

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
    /// The title a capture folder was created with; the name can change while recording.
    var folderTitle: String?
}

private extension LocalTranscriptionProgress {
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

@MainActor
final class AppModel: ObservableObject {
    @Published var meetingTitle = ""
    @Published private(set) var state: AppState = .idle { didSet { refreshCaptureAccess() } }
    @Published private(set) var elapsed: TimeInterval = 0
    let meters = AudioMeters()
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
    @Published private(set) var transcriptionHistory: [MeetingHistoryItem] = [] {
        didSet { historyDays = MeetingDayGroup.groups(transcriptionHistory) }
    }
    /// The listed meetings grouped by day, computed when the list changes rather than on every redraw.
    private(set) var historyDays: [MeetingDayGroup] = []
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
    /// Display, microphone, and quality apply when a recording starts, so only a running capture locks them.
    var captureSettingsLocked: Bool { isCapturing }
    /// Transcription settings are read when a recording stops, so they lock only while a transcription runs.
    var transcriptionSettingsLocked: Bool { isProcessing }
    /// The save folder and automatic export stay in use until the last job finishes.
    var fileSettingsLocked: Bool { isCapturing || isProcessing }
    var settingsLockNotice: String? {
        switch (isCapturing, isProcessing) {
        case (true, true): "Recording, transcription, and file settings unlock when recording and processing finish."
        case (true, false): "Recording and file settings unlock when recording stops. Transcription changes apply to this meeting."
        case (false, true): "Transcription and file settings unlock when processing finishes."
        case (false, false): nil
        }
    }
    @Published private(set) var modelReady = false
    @Published private(set) var modelSetupStatus = "Preparing speech model…"
    @Published private(set) var modelSetupFraction: Double?
    @Published private(set) var modelSetupError: String?
    @Published private(set) var storedModels: [StoredModelInfo] = []
    @Published private(set) var modelDownloads: [String: Double] = [:]
    @Published private(set) var modelDownloadError: String?
    private(set) var modelPreparationTask: Task<Void, Error>?
    private var modelPreparationToken = 0
    private(set) var modelDownloadTask: Task<Void, Never>?
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
    @Published var menuBarRecordingTime: Bool {
        didSet { defaults.set(menuBarRecordingTime, forKey: "menuBarRecordingTime") }
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
        modelReady = Self.modelIsCached(speechSettings)
        prepareSpeechModel()
    }

    private static func modelIsCached(_ settings: SpeechSettings) -> Bool {
        switch settings.selectedEngine {
        case .whisper: LocalTranscriber.cachedModelFolder(model: settings.model) != nil
        case .parakeet: LocalTranscriber.cachedParakeetModels()
        }
    }

    private let defaults: UserDefaults
    private let recorder = MeetingRecorder()
    private let transcriber = LocalTranscriber()
    private let library = MeetingLibrary()
    private(set) var modelUnloadTask: Task<Void, Never>?
    /// How long a loaded speech model stays in memory after the last job. Loading it again takes a few seconds.
    var modelIdleUnloadDelay: Duration = .seconds(300)
    private var activeFolder: URL?
    private var recordedAt: Date?
    private var titleWasProvided = true
    private var recordingFolderTitle = ""
    private var timer: Timer?
    private var audioWarningTask: Task<Void, Never>?
    private var quitWhenFinished = false
    private var startTask: Task<Void, Never>?
    private(set) var processingTask: Task<Void, Never>?
    private var pendingRuns: [ProcessingRun] = [] { didSet { updateQueuedFolders() } }
    private var batchRemaining: [URL] = [] { didSet { updateQueuedFolders() } }
    @Published private(set) var processingFolder: URL?
    /// Meetings waiting behind the current job, in order, so the list can mark them.
    @Published private(set) var queuedFolders: [URL] = []
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
        menuBarRecordingTime = defaults.object(forKey: "menuBarRecordingTime") as? Bool ?? true
        speechSettings = defaults.data(forKey: "speechSettings")
            .flatMap { try? JSONDecoder().decode(SpeechSettings.self, from: $0) } ?? SpeechSettings()
        if (try? speechSettings.validate()) == nil { speechSettings = SpeechSettings() }
        // Parakeet is the default; keep Whisper when the saved languages include one Parakeet lacks.
        if speechSettings.engine == nil, !transcriptionLanguages.allSatisfy(SpeechSettings.parakeetLanguages.contains) {
            speechSettings.engine = .whisper
            defaults.set(try? JSONEncoder().encode(speechSettings), forKey: "speechSettings")
        }
        modelReady = Self.modelIsCached(speechSettings)
        // Listed without sizes so the model rows are there in the first frame; refreshStoredModels fills the sizes in.
        storedModels = LocalTranscriber.storedModels(sizes: false)
        grantedAccess = captureAccess()
        updates.allowsBetaUpdates = betaUpdates
        recorder.onUnexpectedStop = { [weak self] error in
            self?.captureStoppedExternally(with: error)
        }
        refreshHistory()
    }

    var elapsedText: String {
        Timecode.compact(elapsed)
    }

    /// Screen Recording and microphone access. Previews replace it to show the granted state.
    var captureAccess: () -> (screen: Bool, microphone: AVAuthorizationStatus) = {
        (CGPreflightScreenCaptureAccess(), AVCaptureDevice.authorizationStatus(for: .audio))
    } {
        didSet { refreshCaptureAccess() }
    }

    /// The last read of `captureAccess`, so a menu redraw never asks the system again. Granting access
    /// happens in System Settings or during a recording, and both reopen the menu or change `state`.
    @Published private(set) var grantedAccess: (screen: Bool, microphone: AVAuthorizationStatus) = (false, .notDetermined)

    func refreshCaptureAccess() {
        grantedAccess = captureAccess()
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

        let (screenReady, microphone) = grantedAccess
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
        let access = grantedAccess
        if !access.screen {
            return PrivacyPermission.screenRecording.settingsURL
        }
        switch access.microphone {
        case .denied, .restricted: return PrivacyPermission.microphone.settingsURL
        default: return nil
        }
    }

    /// Names what failed, so the system's error text has context. Permission failures explain themselves.
    var failureTitle: String? {
        guard state == .failed, privacyPermission == nil else { return nil }
        if let meeting = retryableMeeting { return "Couldn’t transcribe “\(meeting.title)”" }
        return completedFolder == nil ? "Couldn’t start recording" : "Couldn’t finish this recording"
    }

    /// Access the user must grant in System Settings, as opposed to a prompt the next recording will show.
    var captureAccessNeedsAttention: Bool {
        if privacyPermission != nil { return true }
        guard state != .recording else { return false }
        let access = grantedAccess
        return !access.screen || [.denied, .restricted].contains(access.microphone)
    }

    var captureAccessSymbol: String {
        if state == .recording {
            return "stop.circle"
        }
        return captureAccessNeedsAttention ? "exclamationmark.shield" : "shield"
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

    // ponytail: download-only; each engine loads on first transcription so picking one never compiles in the background.
    func prepareSpeechModel() {
        guard !modelReady, !isProcessing, state == .idle || state == .recording else { return }
        let settings = speechSettings
        prepareSpeechModel { [transcriber] progress in
            let report: @Sendable (Double) -> Void = { progress(.downloadingModel($0)) }
            switch settings.selectedEngine {
            case .whisper: try await transcriber.download(model: settings.model, progress: report)
            case .parakeet: try await transcriber.downloadParakeet(progress: report)
            }
        }
    }

    func prepareSpeechModel(
        _ prepare: @escaping (@escaping @Sendable (LocalTranscriptionProgress) -> Void) async throws -> Void
    ) {
        modelPreparationTask?.cancel()
        modelPreparationToken += 1
        let token = modelPreparationToken
        modelReady = false
        modelSetupError = nil
        modelSetupFraction = nil
        modelSetupStatus = "Preparing speech model…"
        modelPreparationTask = Task {
            defer {
                if modelPreparationToken == token { modelPreparationTask = nil }
            }
            do {
                try await prepare { [weak self] progress in
                    Task { @MainActor [weak self] in self?.updateModelSetupProgress(progress) }
                }
                guard modelPreparationToken == token else { return }
                modelReady = true
                modelSetupStatus = "Speech model ready"
            } catch {
                guard modelPreparationToken == token else { return }
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

    func refreshStoredModels() async {
        let models = await Task.detached(priority: .utility) { LocalTranscriber.storedModels() }.value
        storedModels = models
    }

    func deleteStoredModel(_ item: StoredModelInfo) async {
        await transcriber.deleteStoredModel(at: item.url)
        modelReady = Self.modelIsCached(speechSettings)
        if !modelReady {
            modelSetupError = nil
            modelSetupStatus = "Speech model not downloaded"
            modelSetupFraction = nil
        }
        await refreshStoredModels()
    }

    func downloadStoredModel(_ item: StoredModelInfo) {
        guard modelDownloadTask == nil, modelPreparationTask == nil, !isProcessing else { return }
        modelDownloadError = nil
        modelDownloads[item.id] = 0
        modelDownloadTask = Task {
            defer { modelDownloadTask = nil }
            let report: @Sendable (Double) -> Void = { [weak self] fraction in
                Task { @MainActor [weak self] in
                    guard self?.modelDownloads[item.id] != nil else { return }
                    self?.modelDownloads[item.id] = fraction
                }
            }
            do {
                switch item.kind {
                case .whisper(let model):
                    try await transcriber.download(model: model, progress: report)
                case .parakeet:
                    try await transcriber.downloadParakeet(progress: report)
                case .speakerLabels:
                    try await transcriber.downloadSpeakerModels()
                }
                modelDownloads[item.id] = nil
                modelReady = Self.modelIsCached(speechSettings)
                await refreshStoredModels()
            } catch {
                modelDownloads[item.id] = nil
                modelDownloadError = "Couldn’t download \(item.title): \(error.localizedDescription)"
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
        cancelModelUnload()
        let recordings = unfinishedRecordings
        transcriptionBatchTotal = recordings.count
        transcriptionBatchIndex = 1
        prepareSavedTranscription(recordings[0])
        processingTask = Task {
            var completed = 0
            for (index, item) in recordings.enumerated() {
                guard !Task.isCancelled else { break }
                transcriptionBatchIndex = index + 1
                batchRemaining = recordings.dropFirst(index + 1).map(\.folderURL)
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
            batchRemaining = []
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
            settings: (settings ?? MeetingArtifacts.speechSettings(in: item.folderURL) ?? speechSettings).withResolvedEngine
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
        processingFolder = meeting.folderURL
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

    func refreshHistory(scan: (@Sendable (URL) -> [MeetingHistoryItem])? = nil) {
        historyRefreshTask?.cancel()
        let root = outputRoot
        let scan = scan ?? { [library] in library.meetings(in: $0) }
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

    var hasMeetings: Bool { !completedMeetings.isEmpty || !unfinishedRecordings.isEmpty }

    /// Six rows once any meeting exists, so searching never resizes the menu. Before the
    /// first meeting the empty message keeps its natural height.
    var historyListHeight: CGFloat? {
        hasMeetings ? 6 * 43 : nil
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
        historySearchTask = Task.detached(priority: .userInitiated) { [weak self, library] in
            let matches = library.search(meetings, query: query)
            await self?.showSearchResults(matches)
        }
    }

    private func showSearchResults(_ matches: [MeetingHistoryItem]) {
        guard !Task.isCancelled else { return }
        transcriptionHistory = matches
        searchingHistory = false
    }

    func copyTranscript(_ meeting: MeetingHistoryItem, to pasteboard: NSPasteboard = .general) throws {
        try Self.copyTranscript(in: meeting.folderURL, to: pasteboard)
    }

    static func copyTranscript(in folder: URL, to pasteboard: NSPasteboard = .general) throws {
        let text = try String(contentsOf: folder.appendingPathComponent("transcript.md"), encoding: .utf8)
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { throw MeetingActionError.clipboardUnavailable }
    }

    /// Opens the transcript, or the folder when there is none or no app opens Markdown.
    static func openTranscript(in folder: URL) {
        let transcript = folder.appendingPathComponent("transcript.md")
        if !FileManager.default.fileExists(atPath: transcript.path) || !NSWorkspace.shared.open(transcript) {
            NSWorkspace.shared.open(folder)
        }
    }

    /// Moves a meeting folder to the Trash, where Finder can put it back.
    func moveMeetingToTrash(
        _ meeting: MeetingHistoryItem,
        trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) {
        guard state == .idle, !isProcessing else { return }
        do {
            try trash(meeting.folderURL)
            completedFolder = nil
            completionMessage = "Moved “\(meeting.title)” to the Trash."
        } catch {
            NSAlert(error: error).runModal()
        }
        refreshHistory()
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
                recordingFolderTitle = title
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
        // A name typed or changed while recording wins; clearing the field keeps the folder's name.
        let editedTitle = meetingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return ProcessingRun(
            folder: folder,
            recordedAt: recordedAt,
            title: editedTitle.isEmpty ? recordingFolderTitle : meetingTitle,
            titleWasProvided: titleWasProvided || !editedTitle.isEmpty,
            replacing: nil,
            languages: transcriptionLanguages,
            hints: transcriptionHints,
            settings: speechSettings.withResolvedEngine,
            folderTitle: recordingFolderTitle
        )
    }

    private func updateQueuedFolders() {
        queuedFolders = batchRemaining + pendingRuns.map(\.folder)
    }

    private func enqueue(_ run: ProcessingRun) {
        cancelModelUnload()
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
        scheduleModelUnload()
        if !isCapturing { completeTermination(succeeded) }
    }

    private func cancelModelUnload() {
        modelUnloadTask?.cancel()
        modelUnloadTask = nil
    }

    /// Frees the speech model after a quiet period. A recording in progress keeps it for its own transcription.
    private func scheduleModelUnload() {
        modelUnloadTask?.cancel()
        let delay = modelIdleUnloadDelay
        modelUnloadTask = Task { [weak self, transcriber] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, !self.isProcessing, !self.isCapturing else { return }
            await transcriber.unloadIfIdle()
        }
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
            // Decoded once, for every language pass and speaker labels.
            let meetingAudio = MeetingAudio(url: audioURL)
            defer { meetingAudio.discard() }
            var segments = try await transcriber.transcribe(
                audioURL: audioURL, audio: meetingAudio,
                languages: run.languages, hints: run.hints, settings: run.settings
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
                        audio: meetingAudio, downloadBase: LocalTranscriber.defaultDownloadBase
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
            meetingAudio.discard()

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
            } else if run.replacing == nil, let folderTitle = run.folderTitle, title != folderTitle {
                // The name changed while recording; the folder still carries the one it started with.
                folder = try MeetingArtifacts.renameDirectory(folder, title: title, recordedAt: recordedAt)
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
            modelReady = Self.modelIsCached(run.settings)
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
                    ? "Transcription cancelled. Recording kept; transcribe it from the menu to resume."
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
                let elapsed = Date().timeIntervalSince(startDate)
                // The clocks show whole seconds; publishing every tick would redraw the menu four times a second.
                if Int(elapsed) != Int(self.elapsed) { self.elapsed = elapsed }
                self.meters.update(
                    microphone: self.recorder.audioLevel(microphone: true),
                    system: self.recorder.audioLevel(microphone: false)
                )
                self.checkRecordingAudio(elapsed: elapsed, audioDetected: self.recorder.hasDetectedAudio)
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
        meters.update(microphone: 0, system: 0)
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
        } else if case .engineTranscribing(let fraction) = progress {
            setProcessingPhase(.transcribing, fraction: fraction)
            processingStatusText = "Transcribing with Parakeet…"
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
