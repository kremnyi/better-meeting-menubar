import AppKit
import AVFoundation
import Combine
import CoreGraphics
import Foundation
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

private let failedTranscriptionFoldersKey = "failedTranscriptionFolders"

/// A stopped or retried recording, or one meeting of Transcribe all.
private enum QueuedJob {
    case recording(ProcessingRun), batch(MeetingHistoryItem, process: (MeetingHistoryItem) async -> Bool)
    var folder: URL { switch self { case .recording(let run): run.folder; case .batch(let item, _): item.folderURL } }
    var isBatch: Bool { if case .batch = self { true } else { false } }
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

/// Recording elapsed time, isolated so 1 Hz ticks redraw only the views that show it
/// (the same pattern as AudioMeters and MenuBarSpinner).
@MainActor
final class RecordingClock: ObservableObject {
    @Published var elapsed: TimeInterval = 0
}

@MainActor
final class AppModel: ObservableObject {
    @Published var meetingTitle = ""
    @Published private(set) var state: AppState = .idle { didSet { refreshCaptureAccess() } }
    let recordingClock = RecordingClock()
    var elapsed: TimeInterval {
        get { recordingClock.elapsed }
        set { recordingClock.elapsed = newValue }
    }
    let meters = AudioMeters()
    @Published private(set) var audioWarning = false
    @Published private(set) var audioWarningTitle = "No audio detected yet"
    var audioWarningDetail: String {
        audioWarningTitle == "No audio detected yet"
            ? "Check your microphone and meeting audio."
            : "Check the source if audio is expected."
    }
    @Published private(set) var recordingDiskSpace: RecordingDiskSpace?
    private(set) var captureMode: CaptureMode = .screen
    private(set) var recordingID: UUID?
    weak var menuWindow: NSWindow?
    @Published private(set) var statusText = "Ready to record your display and audio."
    @Published private(set) var lastError: Error?
    /// A transcription that failed while nothing was recording. It shows inline in the idle menu,
    /// so a failed transcript never takes the place of Start recording.
    @Published private(set) var transcriptionError: Error?
    /// The failure text shown in the menu: the error's own description when it has a friendly one.
    var errorMessage: String? {
        (lastError ?? transcriptionError).map { ($0 as? LocalizedError)?.errorDescription ?? $0.localizedDescription }
    }
    /// The failed error's domain and code, shown behind Details in the failure panel.
    var errorDetails: String? {
        (lastError ?? transcriptionError).map { error in let ns = error as NSError; return "\(ns.domain) \(ns.code)" }
    }
    /// The meeting whose transcription failed while idle, for the inline failure and its Retry.
    var failedTranscriptionMeeting: MeetingHistoryItem? {
        transcriptionError == nil ? nil : retryableMeeting
    }
    /// Access to grant in System Settings, or a failed transcription: what the menu-bar icon flags.
    /// Recordings merely waiting to be transcribed are not a problem, so they never raise it.
    var needsAttention: Bool {
        captureAccessNeedsAttention || failedTranscriptionMeeting != nil
    }
    @Published private(set) var completedFolder: URL? {
        didSet {
            // Checked once when the folder is set; the menu reads the flag on every redraw.
            hasCompletedTranscript = completedFolder.map {
                FileManager.default.fileExists(atPath: $0.appendingPathComponent("transcript.md").path)
            } ?? false
            updateRetryableMeeting()
        }
    }
    private(set) var hasCompletedTranscript = false
    @Published private(set) var outputRoot: URL
    @Published private(set) var privacyPermission: PrivacyPermission?
    @Published private(set) var processingFraction: Double?
    var showsRecordingOptionsAction: Bool {
        guard let error = lastError as? RecorderError else { return false }
        return switch error {
        case .noDisplay, .noMicrophone: true
        default: false
        }
    }
    @Published private(set) var processingPhase: ProcessingPhase?
    @Published private(set) var processingStatusText = ""
    @Published private(set) var processingTitle = ""
    @Published private(set) var transcriptionHistory: [MeetingHistoryItem] = []
    @Published private(set) var historyError: String?
    /// Every meeting, whatever the search shows.
    private(set) var allMeetingCount = 0
    @Published private(set) var failedTranscriptionFolders: Set<URL> = []
    @Published var historyQuery = "" {
        didSet { searchHistory() }
    }
    @Published private(set) var searchingHistory = false
    @Published private(set) var unfinishedRecordings: [MeetingHistoryItem] = [] {
        didSet { updateRetryableMeeting() }
    }
    @Published private(set) var historyTotalBytes: Int64 = 0
    @Published private(set) var transcriptionBatchTotal = 0
    @Published private(set) var transcriptionBatchIndex = 0
    var isTranscribingBatch: Bool { transcriptionBatchTotal > 0 }
    var transcriptionBatchWaiting: Int { max(0, transcriptionBatchTotal - transcriptionBatchIndex) }
    var isProcessing: Bool { processingPhase != nil }
    var isCapturing: Bool { state == .preparing || state == .recording || state == .stopping }
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
    @Published private(set) var modelDownload: (id: String, fraction: Double)?
    @Published private(set) var modelDownloadError: String?
    private(set) var modelPreparationTask: Task<Void, Error>?
    private var modelPreparationToken = 0
    private(set) var modelDownloadTask: Task<Void, Never>?
    @Published private(set) var cancellingTranscription = false
    @Published private(set) var displays: [(id: CGDirectDisplayID, name: String)] = []
    @Published private(set) var microphones: [(id: String, name: String)] = []
    private var inputWatches: [AnyCancellable] = []
    private var microphoneDiscovery: Task<Void, Never>?
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
        return isCapturing || isProcessing
    }
    @Published var automaticUpdateChecks: Bool {
        didSet { defaults.set(automaticUpdateChecks, forKey: "checkUpdatesOnLaunch") }
    }
    @Published var menuBarRecordingTime: Bool {
        didSet { defaults.set(menuBarRecordingTime, forKey: "menuBarRecordingTime") }
    }
    @Published var detectsMeetings: Bool {
        didSet {
            defaults.set(detectsMeetings, forKey: "detectMeetings")
            meetingDetector.setEnabled(detectsMeetings)
        }
    }
    /// Built on first use, so a model without meeting detection never touches Core Audio.
    lazy var meetingDetector = MeetingDetector(isBusy: { [weak self] in
        guard let self else { return true }
        return state != .idle || isProcessing
    })
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
    /// Production waits for ScreenCaptureKit's completion; tests can hold that completion pending.
    lazy var stopCapture: () async throws -> Void = { [recorder] in try await recorder.stop() }
    private let transcriber = LocalTranscriber()
    private let library = MeetingLibrary()
    private(set) var modelUnloadTask: Task<Void, Never>?
    var activeFolder: URL?
    private var recordedAt: Date?
    private var titleWasProvided = true
    private var recordingFolderTitle = ""
    private var timer: Timer?
    private var audioWarningTask: Task<Void, Never>?
    private var diskWarningTask: Task<Void, Never>?
    private var lastDiskCheck = Date.distantPast
    private var quitWhenFinished = false
    private var startTask: Task<Void, Never>?
    private(set) var processingTask: Task<Void, Never>?
    private var pendingJobs: [QueuedJob] = [] { didSet { queuedFolders = pendingJobs.map(\.folder) } }
    @Published private(set) var processingFolder: URL?
    /// Meetings waiting behind the current job, in order, so the list can mark them.
    @Published private(set) var queuedFolders: [URL] = []
    private(set) var historySearchTask: Task<Void, Never>?
    private(set) var historyRefreshTask: Task<Void, Never>?
    private var historyRefreshStart = ContinuousClock.now - .seconds(1)
    private var completedMeetings: [MeetingHistoryItem] = [] {
        didSet { updateRetryableMeeting() }
    }
    /// Every meeting, newest first, sorted once per refresh for the list and each search.
    private var meetingsByRecency: [MeetingHistoryItem] = []
    private var lastTranscriptionOptions: (languages: [String], hints: String, settings: SpeechSettings)?
    /// The speech settings the running model preparation downloads for.
    private var modelPreparationSettings: SpeechSettings?

    /// The completed or failed meeting, resolved when the folder or history changes:
    /// the menu-bar label reads it on every redraw.
    private var retryableMeeting: MeetingHistoryItem?

    private func updateRetryableMeeting() {
        retryableMeeting = completedFolder.flatMap { folder in
            unfinishedRecordings.first { $0.folderURL == folder }
                ?? completedMeetings.first { $0.folderURL == folder }
                ?? MeetingArtifacts.meeting(in: folder)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        failedTranscriptionFolders = Set((defaults.stringArray(forKey: failedTranscriptionFoldersKey) ?? []).map {
            URL(fileURLWithPath: $0).standardizedFileURL
        })
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        outputRoot = defaults.url(forKey: "outputFolder")
            ?? documents.appendingPathComponent("Better Meetings", isDirectory: true)
        if defaults.url(forKey: "outputFolder") == nil {
            try? FileManager.default.createDirectory(at: documents.appendingPathComponent("Better Meetings", isDirectory: true),
                                                     withIntermediateDirectories: true)
        }
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
        detectsMeetings = defaults.bool(forKey: "detectMeetings")
        speechSettings = defaults.data(forKey: "speechSettings")
            .flatMap { try? JSONDecoder().decode(SpeechSettings.self, from: $0) } ?? SpeechSettings()
        if (try? speechSettings.validate()) == nil { speechSettings = SpeechSettings() }
        // Speaker labels are on unless turned off. Only preferences change: a meeting saved
        // without the field was transcribed without labels and keeps that when retried.
        if speechSettings.speakerLabels == nil {
            speechSettings.speakerLabels = true
            defaults.set(try? JSONEncoder().encode(speechSettings), forKey: "speechSettings")
        }
        // Parakeet is the default; keep Whisper when the saved languages include one Parakeet lacks.
        if speechSettings.engine == nil, !transcriptionLanguages.allSatisfy(SpeechSettings.parakeetLanguages.contains) {
            speechSettings.engine = .whisper
            defaults.set(try? JSONEncoder().encode(speechSettings), forKey: "speechSettings")
        }
        // Listed without sizes so the model rows are there in the first frame; refreshStoredModels fills the sizes in.
        storedModels = LocalTranscriber.storedModels(sizes: false)
        modelReady = Self.modelIsCached(speechSettings)
        grantedAccess = captureAccess()
        updates.allowsBetaUpdates = betaUpdates
        recorder.onUnexpectedStop = { [weak self] error in
            self?.captureStoppedExternally(with: error)
        }
        refreshHistory()
    }

    /// Screen Recording and microphone access. Previews replace it to show the granted state.
    var captureAccess: () -> (screen: Bool, microphone: AVAuthorizationStatus) = {
        (CGPreflightScreenCaptureAccess(), AVCaptureDevice.authorizationStatus(for: .audio))
    } {
        didSet { refreshCaptureAccess() }
    }

    var accessibilityAnnouncement: (String) -> Void = { message in
        NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested, userInfo: [
            .announcement: message,
            .priority: NSAccessibilityPriorityLevel.high.rawValue
        ])
    }

    /// The last read of `captureAccess`, so a menu redraw never asks the system again. Granting access
    /// happens in System Settings or during a recording, and both reopen the menu or change `state`.
    @Published private(set) var grantedAccess: (screen: Bool, microphone: AVAuthorizationStatus) = (false, .notDetermined)

    func refreshCaptureAccess() {
        let access = captureAccess()
        // `state` changes call this; publish only a real change so the menu doesn't redraw for nothing.
        if access != grantedAccess { grantedAccess = access }
    }

    var primaryButtonTitle: String {
        switch state {
        case .recording: "Stop recording"
        case .preparing: "Preparing…"
        case .stopping: "Stopping…"
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
        switch state {
        case .recording: "stop.fill"
        case .failed: "arrow.clockwise"
        case .idle, .preparing, .stopping: "record.circle"
        }
    }

    var captureAccessNotice: (text: String, isSecondary: Bool) {
        if let privacyPermission {
            return (privacyPermission.accessNeededText, false)
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
        if state == .idle, let meeting = failedTranscriptionMeeting { return "Couldn’t transcribe “\(meeting.title)”" }
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
        captureAccessNeedsAttention ? "exclamationmark.shield" : "shield"
    }

    func primaryAction() {
        if state == .recording {
            beginProcessing(stopCapture: true)
        } else if state == .failed, privacyPermission == .screenRecording {
            restartApplication()
        } else if state == .failed, retryableMeeting != nil {
            retryFailedTranscription()
        } else if state == .idle || state == .failed {
            startRecording(mode: state == .failed ? captureMode : .screen)
        }
    }

    /// Lists displays and microphones once, then again only when one connects or disconnects,
    /// so opening Options never waits for device discovery.
    func watchInputs() {
        guard inputWatches.isEmpty else { return }
        let center = NotificationCenter.default
        inputWatches = [
            Publishers.Merge(
                center.publisher(for: AVCaptureDevice.wasConnectedNotification),
                center.publisher(for: AVCaptureDevice.wasDisconnectedNotification)
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshMicrophones() },
            center.publisher(for: NSApplication.didChangeScreenParametersNotification)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.refreshDisplays() },
        ]
        refreshDisplays()
        refreshMicrophones()
    }

    private func refreshDisplays() {
        displays = NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            return (number.uint32Value, screen.localizedName)
        }
    }

    /// Discovery can take seconds when it looks for Continuity or virtual microphones, so it runs off the main thread.
    private func refreshMicrophones() {
        microphoneDiscovery?.cancel()
        microphoneDiscovery = Task {
            let found = await Task.detached(priority: .utility) {
                AVCaptureDevice.DiscoverySession(
                    deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified
                ).devices.map { (id: $0.uniqueID, name: $0.localizedName) }
            }.value
            guard !Task.isCancelled else { return }
            microphones = found
        }
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
        modelPreparationSettings = speechSettings
        modelReady = false
        modelSetupError = nil
        modelSetupFraction = nil
        modelSetupStatus = "Preparing speech model…"
        modelPreparationTask = Task {
            defer {
                if modelPreparationToken == token {
                    modelPreparationTask = nil
                    modelPreparationSettings = nil
                }
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
        guard !isCapturing, !isProcessing, modelPreparationTask == nil, modelDownloadTask == nil else { return }
        modelDownloadError = nil
        do {
            try await transcriber.deleteStoredModel(at: item.url)
        } catch {
            modelDownloadError = "Couldn’t delete \(item.title): \(error.localizedDescription)"
        }
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
        modelDownload = (item.id, 0)
        modelDownloadTask = Task {
            defer {
                modelDownload = nil
                modelDownloadTask = nil
            }
            let report: @Sendable (Double) -> Void = { [weak self] fraction in
                Task { @MainActor [weak self] in
                    guard let self, let shown = self.modelDownload, shown.id == item.id,
                          Self.shownPercent(fraction) != Self.shownPercent(shown.fraction) else { return }
                    self.modelDownload = (item.id, fraction)
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
                modelDownload = nil
                modelReady = Self.modelIsCached(speechSettings)
                await refreshStoredModels()
            } catch {
                modelDownloadError = "Couldn’t download \(item.title): \(error.localizedDescription)"
            }
        }
    }

    private func updateModelSetupProgress(_ progress: LocalTranscriptionProgress) {
        guard modelPreparationTask != nil, let step = progress.modelStep else { return }
        if modelSetupStatus != step.phase.statusText { modelSetupStatus = step.phase.statusText }
        if Self.shownPercent(step.fraction) != Self.shownPercent(modelSetupFraction) { modelSetupFraction = step.fraction }
        if isProcessing,
           [.preparingModel, .downloadingModel, .loadingModel].contains(processingPhase) {
            updateTranscriptionProgress(progress)
        }
    }

    private func updateFailedTranscriptionFolders(_ update: (inout Set<URL>) -> Void) {
        var folders = failedTranscriptionFolders
        update(&folders)
        let normalized = Set(folders.map { $0.standardizedFileURL })
        failedTranscriptionFolders = normalized
        defaults.set(normalized.map(\.path), forKey: failedTranscriptionFoldersKey)
    }

    func retryTranscription(_ item: MeetingHistoryItem, languages: [String]? = nil, hints: String? = nil, settings: SpeechSettings? = nil) {
        guard !isProcessing, !isTranscribingBatch, state == .idle || state == .failed else { return }
        if let backup = item.recoveryFolder {
            lastError = MeetingActionError.transcriptRecovery(backup)
            return
        }
        prepareSavedTranscription(item)
        enqueue(run(
            for: item, replacing: item.needsTranscription ? nil : item,
            languages: languages, hints: hints,
            settings: settings ?? MeetingArtifacts.speechSettings(in: item.folderURL)
        ))
    }

    /// Retries the failed meeting with the options its last attempt used.
    func retryFailedTranscription() {
        guard let item = retryableMeeting else { return }
        retryTranscription(item, languages: lastTranscriptionOptions?.languages, hints: lastTranscriptionOptions?.hints, settings: lastTranscriptionOptions?.settings)
    }

    func dismissTranscriptionFailure() {
        guard transcriptionError != nil else { return }
        transcriptionError = nil
        completedFolder = nil
    }

    func transcribeAllRecordings() {
        transcribeAllRecordings { [self] item in
            await finishRecording(run(for: item, replacing: nil), inBatch: true)
        }
    }

    func transcribeAllRecordings(_ process: @escaping (MeetingHistoryItem) async -> Bool) {
        let recordings = transcribableRecordings
        guard state == .idle, !isProcessing, !isTranscribingBatch, !recordings.isEmpty else { return }
        cancelModelUnload()
        transcriptionBatchTotal = recordings.count
        transcriptionBatchIndex = 1
        prepareSavedTranscription(recordings[0])
        pendingJobs = recordings.map { .batch($0, process: process) }
        processingTask = Task { await runProcessingQueue() }
    }

    var transcribableRecordings: [MeetingHistoryItem] {
        historyError == nil ? unfinishedRecordings.filter { $0.recoveryFolder == nil } : []
    }

    func retryTranscriptRecovery(_ item: MeetingHistoryItem) {
        do {
            try MeetingArtifacts.recoverTranscript(in: item.folderURL)
            lastError = nil
            if completedFolder?.standardizedFileURL.path == item.folderURL.standardizedFileURL.path {
                transcriptionError = nil
            }
            updateFailedTranscriptionFolders { $0.remove(item.folderURL.standardizedFileURL) }
        } catch { lastError = error }
        refreshHistory()
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
        transcriptionError = nil
        processingFolder = item.folderURL
        processingTitle = item.title
        if !isCapturing { elapsed = item.duration }
        lastError = nil
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
        lastError = nil
        transcriptionError = nil
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
        lastError = nil
        privacyPermission = nil
        meetingTitle = ""
        refreshHistory()
    }

    func terminationReply(
        confirm: @MainActor (NSAlert) -> NSApplication.ModalResponse = { $0.runActive() }
    ) -> NSApplication.TerminateReply {
        guard isCapturing || isProcessing else {
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
        if state == .stopping { alert.messageText = "Quit when the recording finishes stopping?" }
        alert.informativeText = isExportingBundle
            ? "Better Meeting will stay open until the export bundle is saved."
            : "Better Meeting will stay open until the recording and transcript are saved."
        if isTranscribingBatch { alert.informativeText = "Better Meeting will stay open until the queue finishes. An error or cancellation will keep the app open." }
        if state == .stopping { alert.informativeText = "Better Meeting will stay open until capture stops and the recording is saved or moved to the Trash." }
        alert.addButton(withTitle: state == .recording ? "Finish and quit" : "Wait and quit")
        alert.addButton(withTitle: "Keep open")
        guard confirm(alert) == .alertFirstButtonReturn else { return .terminateCancel }
        // Processing may finish while the native confirmation is open.
        guard state == .recording || state == .stopping || isProcessing else {
            return state == .idle ? .terminateNow : .terminateCancel
        }
        quitWhenFinished = true
        if state == .recording { beginProcessing(stopCapture: true) }
        // terminateLater keeps AppKit in a modal loop and stalls menu-bar updates.
        return .terminateCancel
    }

    func setOutputFolder(_ url: URL) {
        outputRoot = url
        historyError = nil
        defaults.set(url, forKey: "outputFolder")
        updateFailedTranscriptionFolders { $0.removeAll() }
        completedMeetings = []
        unfinishedRecordings = []
        meetingsByRecency = []
        allMeetingCount = 0
        transcriptionHistory = []
        // A pending search over the old folder must not publish; the refresh searches the new one.
        historySearchTask?.cancel()
        refreshHistory()
    }

    func completeTermination(_ success: Bool, terminate: @MainActor () -> Void = { NSApp.terminate(nil) }) {
        guard quitWhenFinished else { return }
        quitWhenFinished = false
        if success { terminate() }
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

        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            setOutputFolder(url)
        }
    }

    func refreshHistory(scan: (@Sendable (URL) throws -> [MeetingHistoryItem])? = nil) {
        historyRefreshTask?.cancel()
        let root = outputRoot
        let scan = scan ?? { [library] in try library.meetings(in: $0) }
        // The first refresh scans at once; later ones within the window join a single trailing scan,
        // so a batch, its completion, and a menu open don't each list every meeting folder.
        let now = ContinuousClock.now
        let start = historyRefreshStart > now ? historyRefreshStart : max(now, historyRefreshStart + .milliseconds(300))
        historyRefreshStart = start
        historyRefreshTask = Task.detached(priority: .userInitiated) { [weak self] in
            if start > now {
                try? await Task.sleep(until: start, clock: .continuous)
                guard !Task.isCancelled else { return }
            }
            do {
                let meetings = try scan(root)
                await self?.showHistory(meetings)
            } catch {
                await self?.showHistoryError(error, root: root)
            }
        }
    }

    private func showHistoryError(_ error: Error, root: URL) {
        guard !Task.isCancelled, outputRoot == root else { return }
        historyError = error.localizedDescription
    }

    private func showHistory(_ meetings: [MeetingHistoryItem]) {
        guard !Task.isCancelled else { return }
        if historyError != nil { historyError = nil }
        let completed = meetings.filter { !$0.needsTranscription }
        let unfinished = meetings.filter(\.needsTranscription)
        // A refresh usually finds nothing new; reassigning would still redraw the menu.
        if completed != completedMeetings { completedMeetings = completed }
        if unfinished != unfinishedRecordings { unfinishedRecordings = unfinished }
        meetingsByRecency = (completed + unfinished).sorted { $0.recordedAt > $1.recordedAt }
        let currentFolders = Set(meetings.map { $0.folderURL.standardizedFileURL })
        let validFailedFolders = failedTranscriptionFolders.intersection(currentFolders)
        if validFailedFolders != failedTranscriptionFolders {
            updateFailedTranscriptionFolders { $0 = validFailedFolders }
        }
        allMeetingCount = meetings.count
        let totalBytes = meetings.reduce(0) { $0 + $1.totalBytes }
        if totalBytes != historyTotalBytes { historyTotalBytes = totalBytes }
        searchHistory()
    }

    var hasMeetings: Bool { !completedMeetings.isEmpty || !unfinishedRecordings.isEmpty }

    private func searchHistory() {
        historySearchTask?.cancel()
        let query = historyQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            if searchingHistory { searchingHistory = false }
            if transcriptionHistory != meetingsByRecency { transcriptionHistory = meetingsByRecency }
            return
        }
        let meetings = meetingsByRecency
        searchingHistory = true
        historySearchTask = Task.detached(priority: .userInitiated) { [weak self, library] in
            // Coalesce keystrokes and refreshes; the task is cancelled and re-armed on each call.
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            let matches = library.search(meetings, query: query)
            await self?.showSearchResults(matches)
        }
    }

    private func showSearchResults(_ matches: [MeetingHistoryItem]) {
        guard !Task.isCancelled else { return }
        if transcriptionHistory != matches { transcriptionHistory = matches }
        searchingHistory = false
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
            updateFailedTranscriptionFolders { $0.remove(meeting.folderURL) }
            completedFolder = nil
            completionMessage = "Moved “\(meeting.title)” to the Trash."
        } catch {
            NSAlert(error: error).runActive()
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
        guard alert.runActive() == .alertFirstButtonReturn else { return }
        do {
            let folder = try MeetingArtifacts.renameMeeting(meeting, to: nameField.stringValue)
            if completedFolder == meeting.folderURL { completedFolder = folder }
            updateFailedTranscriptionFolders {
                guard $0.remove(meeting.folderURL) != nil else { return }
                $0.insert(folder)
            }
        } catch {
            NSAlert(error: error).runActive()
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

    func startCalendarRecording(_ event: CalendarEvent, mode: CaptureMode = .screen) {
        guard state == .idle || state == .failed else { return }
        startRecording(calendarEvent: event, mode: mode)
    }

    func startRecording(calendarEvent: CalendarEvent? = nil, mode: CaptureMode = .screen) {
        guard state == .idle || state == .failed else { return }
        stopTimer()
        elapsed = 0
        state = .preparing
        captureMode = mode
        statusText = "Checking screen and microphone access…"
        lastError = nil
        transcriptionError = nil
        completedFolder = nil
        privacyPermission = nil
        activeFolder = nil
        recordedAt = nil

        let manualTitle = meetingTitle
        startTask = Task {
            defer { startTask = nil }
            do {
                try Task.checkCancellation()
                let root = outputRoot
                let space = await Task.detached(priority: .utility) { RecordingDiskSpace.read(at: root) }.value
                checkRecordingDiskSpace(space)
                try space?.preflight()
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
                let recordingURL = folder.appendingPathComponent(mode.filename)
                activeFolder = folder
                try event?.attach(to: folder, recordedAt: startedAt)
                try await recorder.start(
                    to: recordingURL, displayID: selectedDisplayID, microphoneID: selectedMicrophoneID,
                    resolution: captureResolution, quality: captureQuality, mode: mode
                )
                recordingDidStart(at: startedAt)
            } catch {
                discardUnstartedFolder()
                fail(error, folder: activeFolder)
            }
        }
    }

    /// Stops capture and moves the recording to the Trash without transcribing it,
    /// for meetings nobody joined.
    func cancelRecording(
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
        Task {
            do {
                try await stopCapture()
                guard let folder else { throw AppError.missingRecording }
                try trash(folder)
                activeFolder = nil
                recordedAt = nil
                elapsed = 0
                meetingTitle = ""
                state = .idle
                accessibilityAnnouncement("Recording cancelled.")
                refreshHistory()
                if !isProcessing { completeTermination(true) }
            } catch {
                fail(error, folder: activeFolder)
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
            fail(error, folder: activeFolder)
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
            fail(AppError.missingRecording, folder: activeFolder)
            return
        }
        state = stopCapture ? .stopping : .idle
        if stopCapture { statusText = "Stopping the recording…" }
        accessibilityAnnouncement("Recording stopped. Transcription started.")
        if !isProcessing {
            processingFolder = run.folder
            setProcessingPhase(.finalizingRecording)
        }
        if stopCapture {
            let folder = run.folder
            run.stopTask = Task {
                do {
                    try await self.stopCapture()
                    if state == .stopping { state = .idle }
                } catch {
                    fail(error, folder: folder)
                    throw error
                }
            }
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

    func enqueue(_ run: ProcessingRun) {
        cancelModelUnload()
        pendingJobs.append(.recording(run))
        guard processingTask == nil else { return }
        processingTask = Task { await runProcessingQueue() }
    }

    private func runProcessingQueue() async {
        var succeeded = true
        while succeeded, !pendingJobs.isEmpty {
            switch pendingJobs.removeFirst() {
            case .batch(let item, let process):
                // A batch ends after its last meeting or at the first that fails or is cancelled.
                let remaining = pendingJobs.filter(\.isBatch).count
                transcriptionBatchIndex = transcriptionBatchTotal - remaining
                if transcriptionBatchIndex > 1, !Task.isCancelled { prepareSavedTranscription(item) }
                let processed = Task.isCancelled ? false : await process(item)
                if processed, remaining > 0 { continue }
                let (completed, total, cancelled) = (transcriptionBatchIndex - (processed ? 0 : 1), transcriptionBatchTotal, Task.isCancelled)
                if errorMessage == nil {
                    let message = cancelled
                        ? "Transcription cancelled. \(completed) of \(total) finished; remaining recordings are kept."
                        : "Transcribed \(completed) of \(total) recordings."
                    completionMessage = message
                    accessibilityAnnouncement(message)
                }
                pendingJobs.removeAll(where: \.isBatch) // Recordings stopped meanwhile stay queued.
                (transcriptionBatchTotal, transcriptionBatchIndex) = (0, 0)
                refreshHistory()
                succeeded = !cancelled && completed == total
            case .recording(let run):
                processingFolder = run.folder
                do { try await run.stopTask?.value } catch { succeeded = false }
                if succeeded {
                    processingTitle = run.title
                    succeeded = await finishRecording(run)
                }
                if !succeeded { pendingJobs.removeAll() }
            }
        }
        processingQueueFinished(succeeded: succeeded)
    }

    private func processingQueueFinished(succeeded: Bool) {
        // A cancelled job ends here; a recording queued behind it is a new job that can report and cancel.
        if cancellingTranscription {
            cancellingTranscription = false
            if let processingPhase { processingStatusText = processingPhase.statusText }
        }
        guard pendingJobs.isEmpty else {
            processingTask = Task { await runProcessingQueue() }
            return
        }
        finishProcessingUI()
        processingTask = nil
        scheduleModelUnload()
        if !succeeded || !isCapturing { completeTermination(succeeded) }
    }

    private func cancelModelUnload() {
        modelUnloadTask?.cancel()
        modelUnloadTask = nil
    }

    /// Frees the speech model after a quiet period. A recording in progress keeps it for its own transcription.
    private func scheduleModelUnload() {
        modelUnloadTask?.cancel()
        modelUnloadTask = Task { [weak self, transcriber] in
            // A loaded speech model stays in memory for five quiet minutes; loading it again takes a few seconds.
            try? await Task.sleep(for: .seconds(300))
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
            lastError = nil
            privacyPermission = nil
        }
    }

    private static func audioDuration(_ audioURL: URL) throws -> Double {
        let audio = try AVAudioFile(forReading: audioURL)
        try Task.checkCancellation()
        return Double(audio.length) / audio.fileFormat.sampleRate
    }

    @discardableResult
    private func finishRecording(_ run: ProcessingRun, inBatch: Bool = false) async -> Bool {
        lastTranscriptionOptions = (run.languages, run.hints, run.settings)
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
                setProcessingPhase(.finalizingRecording)
                try await AudioExtractor.waitUntilReadable(recordingURL)
            }
            setProcessingPhase(.preparingAudio, fraction: 0)
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
                            guard self?.processingPhase == .preparingAudio else { return }
                            self?.setProcessingFraction(fraction)
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
            if !isCapturing { elapsed = duration }
            if replacing == nil {
                try MeetingArtifacts.writeMetadata(
                    title: title, recordedAt: recordedAt, duration: duration,
                    titleWasProvided: run.titleWasProvided, speechSettings: run.settings, to: folder
                )
            }

            // Only wait for a download of the model this job uses; a retry keeps its meeting's engine.
            if let preparation = modelPreparationTask,
               modelPreparationSettings.map({ $0.selectedEngine == run.settings.selectedEngine
                   && ($0.selectedEngine != .whisper || $0.model == run.settings.model) }) ?? true {
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
                    self.setProcessingPhase(.labelingSpeakers)
                    return try await self.transcriber.detectSpeakers(audio: meetingAudio) { [weak self] fraction in
                        Task { @MainActor [weak self] in
                            guard let self, self.processingPhase == .labelingSpeakers,
                                  !self.cancellingTranscription, let fraction = fraction.unitClamped else { return }
                            self.setProcessingFraction(fraction)
                            let statusText = "Identifying speakers on this Mac…"
                            if self.processingStatusText != statusText { self.processingStatusText = statusText }
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
            setProcessingPhase(.writingFiles)
            if !run.titleWasProvided && replacing == nil {
                let generatedTitle = await MeetingTitle.suggestInBackground(
                    from: segments.map(\.text).joined(separator: "\n"))
                try Task.checkCancellation()
                if let generatedTitle {
                    folder = try MeetingArtifacts.renameDirectory(folder, title: generatedTitle, recordedAt: recordedAt)
                    title = generatedTitle
                    processingTitle = generatedTitle
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

            completedFolder = folder
            updateFailedTranscriptionFolders { $0.remove(folder) }
            modelReady = Self.modelIsCached(speechSettings)
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
            if !inBatch { accessibilityAnnouncement("Transcript ready for \(title).") }
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
            completedFolder = failedFolder
            if Task.isCancelled {
                completionMessage = replacing == nil
                    ? "Transcription cancelled. Recording kept; transcribe it from the menu to resume."
                    : "Re-transcription cancelled. Your existing transcript is unchanged."
                refreshHistory()
                return false
            }
            updateFailedTranscriptionFolders { $0.insert(failedFolder) }
            if state == .idle {
                // Shown inline: the next recording must still start with one click.
                transcriptionError = error
                refreshHistory()
            }
            accessibilityAnnouncement("Transcription failed for \(run.title). Open Better Meeting to retry.")
            await MeetingNotifications.post(title: run.title, folder: failedFolder, failed: true)
            return false
        }
    }

    func recordingDidStart(at startDate: Date) {
        stopTimer()
        recordedAt = startDate
        completionMessage = nil
        let recordingID = UUID()
        self.recordingID = recordingID
        elapsed = 0
        state = .recording
        // The microphone is live from here on, so its idle event always re-arms the detector.
        if detectsMeetings { meetingDetector.ownRecordingStarted() }
        statusText = captureMode == .audioOnly
            ? "Recording system audio and microphone. No screen video is saved."
            : "Recording the selected display, system audio, and microphone."
        accessibilityAnnouncement("Recording started.")
        refreshRecordingDiskSpace()
        // Added to the main run loop below, so each tick already runs on the main actor.
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.state == .recording, self.recordingID == recordingID else { return }
                let elapsed = Date().timeIntervalSince(startDate)
                // The clocks show whole seconds; publishing every tick would redraw the menu four times a second.
                if Int(elapsed) != Int(self.elapsed) { self.elapsed = elapsed }
                // Only the open menu shows the meters.
                if self.menuWindow?.isVisible == true {
                    self.meters.update(
                        microphone: self.recorder.audioLevel(microphone: true),
                        system: self.recorder.audioLevel(microphone: false)
                    )
                }
                self.checkRecordingAudio(elapsed: elapsed, audioDetected: self.recorder.hasDetectedAudio,
                                         health: self.recorder.audioHealth())
                if Date().timeIntervalSince(self.lastDiskCheck) >= 10 { self.refreshRecordingDiskSpace() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func checkRecordingAudio(elapsed: TimeInterval, audioDetected: Bool, health: RecordingAudioHealth? = nil) {
        guard state == .recording else { return }
        let title: String? = elapsed < 30 ? nil
            : (!audioDetected ? "No audio detected yet" : health?.warning)
        let warning = title != nil
        guard audioWarning != warning || (warning && audioWarningTitle != title) else { return }
        if let title { audioWarningTitle = title }
        audioWarning = warning
        let message = "\(audioWarningTitle). \(audioWarningDetail)"
        if warning { accessibilityAnnouncement(message) }
        let previousWarning = audioWarningTask
        clearAudioWarning()
        if warning, menuWindow?.isVisible != true, let recordingID {
            audioWarningTask = Task {
                _ = await previousWarning?.value
                guard !Task.isCancelled else { return }
                await MeetingNotifications.post(MeetingNotifications.audioWarning(recordingID: recordingID, message: message))
            }
        }
    }

    /// Reads free space off the main actor; a result that arrives after this recording ended is dropped.
    private func refreshRecordingDiskSpace() {
        guard let recordingID else { return }
        lastDiskCheck = Date()
        let destination = activeFolder ?? outputRoot
        Task {
            let space = await Task.detached(priority: .utility) { RecordingDiskSpace.read(at: destination) }.value
            guard self.recordingID == recordingID else { return }
            checkRecordingDiskSpace(space)
        }
    }

    func checkRecordingDiskSpace(_ space: RecordingDiskSpace?) {
        guard state == .recording || state == .preparing else { return }
        let wasLow = recordingDiskSpace?.isLow == true
        recordingDiskSpace = space
        guard let space, space.isLow else {
            clearDiskWarning()
            return
        }
        guard !wasLow else { return }
        accessibilityAnnouncement("Low recording disk space. \(space.warning)")
        if menuWindow?.isVisible != true, let recordingID {
            diskWarningTask = Task {
                await MeetingNotifications.post(MeetingNotifications.diskWarning(recordingID: recordingID, message: space.warning))
            }
        }
    }

    private func clearDiskWarning() {
        diskWarningTask?.cancel()
        diskWarningTask = nil
        if let recordingID { MeetingNotifications.remove(recordingID.uuidString + "-disk") }
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
        clearDiskWarning()
        audioWarning = false
        audioWarningTitle = "No audio detected yet"
        recordingDiskSpace = nil
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

    /// Transcription can finish before the m4a export it overlaps.
    private func showSavingAudio() {
        guard !cancellingTranscription else { return }
        processingStatusText = "Saving audio.m4a…"
    }

    private func setProcessingPhase(_ phase: ProcessingPhase, fraction: Double? = nil) {
        processingPhase = phase
        processingStatusText = phase.statusText
        setProcessingFraction(fraction)
    }

    /// Progress sources fire far more often than the integer-percent UI shows.
    private static func shownPercent(_ fraction: Double?) -> Int? {
        fraction.map { Int(($0 * 100).rounded()) }
    }

    private func setProcessingFraction(_ fraction: Double?) {
        guard Self.shownPercent(fraction) != Self.shownPercent(processingFraction) else { return }
        processingFraction = fraction
    }

    /// `folder` is the meeting the failure belongs to; a job transcribing meanwhile keeps its own state.
    func fail(_ error: Error, folder: URL? = nil) {
        stopTimer()
        state = .failed
        transcriptionError = nil
        statusText = "Couldn’t finish this recording."
        if processingTask == nil {
            processingFraction = nil
            processingPhase = nil
        }
        lastError = error
        if let folder {
            updateFailedTranscriptionFolders { $0.insert(folder) }
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

extension NSAlert {
    /// A menu-bar app is not active when its menu opens a dialog; without activation the
    /// alert never becomes key, so its text field ignores mouse selection.
    @MainActor
    @discardableResult
    func runActive() -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        return runModal()
    }
}
