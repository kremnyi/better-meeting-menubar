import AppKit
import AVFoundation
import Combine
import CoreGraphics
import Foundation

private let failedTranscriptionFoldersKey = "failedTranscriptionFolders"

/// Recording elapsed time, isolated so 1 Hz ticks redraw only the views that show it
/// (the same pattern as AudioMeters and MenuBarSpinner).
@MainActor
final class RecordingClock: ObservableObject {
    @Published var elapsed: TimeInterval = 0
}

@MainActor
final class AppModel: ObservableObject {
    @Published var meetingTitle = ""
    private(set) lazy var recording = RecordingSession(model: self)
    private(set) lazy var processing = ProcessingQueue(model: self)
    /// The sub-objects publish their own state; the menu observes this model.
    private var forwardedChanges: [AnyCancellable] = []
    var state: AppState { recording.state }
    let recordingClock = RecordingClock()
    var elapsed: TimeInterval {
        get { recordingClock.elapsed }
        set { recordingClock.elapsed = newValue }
    }
    let meters = AudioMeters()
    var audioWarning: Bool { recording.audioWarning }
    var audioWarningTitle: String { recording.audioWarningTitle }
    var audioWarningDetail: String { recording.audioWarningDetail }
    var recordingDiskSpace: RecordingDiskSpace? { recording.diskSpace }
    var recordingID: UUID? { recording.id }
    weak var menuWindow: NSWindow?
    var statusText: String { recording.statusText }
    @Published private(set) var lastError: Error?
    /// A transcription that failed while nothing was recording. It shows inline in the idle menu,
    /// so a failed transcript never takes the place of Start recording.
    @Published private(set) var transcriptionError: Error?
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
    var processingFraction: Double? { processing.fraction }
    var processingPhase: ProcessingPhase? { processing.phase }
    var processingStatusText: String { processing.statusText }
    var processingTitle: String { processing.title }
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
    var transcriptionBatchTotal: Int { processing.batchTotal }
    var transcriptionBatchIndex: Int { processing.batchIndex }
    var isTranscribingBatch: Bool { transcriptionBatchTotal > 0 }
    var transcriptionBatchWaiting: Int { max(0, transcriptionBatchTotal - transcriptionBatchIndex) }
    var isProcessing: Bool { processing.isProcessing }
    var isCapturing: Bool { state == .preparing || state == .recording || state == .stopping }
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
    let transcriber = LocalTranscriber()
    private let library = MeetingLibrary()
    private(set) var modelUnloadTask: Task<Void, Never>?
    var quitWhenFinished = false
    var processingFolder: URL? { processing.folder }
    var queuedFolders: [URL] { processing.queuedFolders }
    private(set) var historySearchTask: Task<Void, Never>?
    private(set) var historyRefreshTask: Task<Void, Never>?
    private var historyRefreshStart = ContinuousClock.now - .seconds(1)
    private var completedMeetings: [MeetingHistoryItem] = [] {
        didSet { updateRetryableMeeting() }
    }
    /// Every meeting, newest first, sorted once per refresh for the list and each search.
    private var meetingsByRecency: [MeetingHistoryItem] = []
    /// The speech settings the running model preparation downloads for.
    private(set) var modelPreparationSettings: SpeechSettings?

    /// The completed or failed meeting, resolved when the folder or history changes:
    /// the menu-bar label reads it on every redraw.
    private(set) var retryableMeeting: MeetingHistoryItem?

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
        forwardedChanges = [recording.objectWillChange, processing.objectWillChange].map { $0.sink { [weak self] in self?.objectWillChange.send() } }
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
            processing.updateTranscriptionProgress(progress)
        }
    }

    func updateFailedTranscriptionFolders(_ update: (inout Set<URL>) -> Void) {
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
        processing.enqueue(run(
            for: item, replacing: item.needsTranscription ? nil : item,
            languages: languages, hints: hints,
            settings: settings ?? MeetingArtifacts.speechSettings(in: item.folderURL)
        ))
    }

    /// Retries the failed meeting with the options its last attempt used.
    func retryFailedTranscription() {
        guard let item = retryableMeeting else { return }
        let options = processing.lastOptions
        retryTranscription(item, languages: options?.languages, hints: options?.hints, settings: options?.settings)
    }

    func dismissTranscriptionFailure() {
        guard transcriptionError != nil else { return }
        transcriptionError = nil
        completedFolder = nil
    }

    func transcribeAllRecordings() {
        transcribeAllRecordings { [self] item in
            await processing.finishRecording(run(for: item, replacing: nil), inBatch: true)
        }
    }

    func transcribeAllRecordings(_ process: @escaping (MeetingHistoryItem) async -> Bool) {
        let recordings = transcribableRecordings
        guard state == .idle, !isProcessing, !isTranscribingBatch, !recordings.isEmpty else { return }
        processing.startBatch(recordings, process: process)
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

    func prepareSavedTranscription(_ item: MeetingHistoryItem) {
        completionMessage = nil
        completedFolder = nil
        recording.clearFailure()
        transcriptionError = nil
        if !isCapturing { elapsed = item.duration }
        lastError = nil
        privacyPermission = nil
        processing.show(item)
    }

    var canCancelTranscription: Bool { processing.canCancel }
    func cancelTranscription() { processing.cancel() }
    var isExportingBundle: Bool { processing.isExportingBundle }

    func exportBundle(_ meeting: MeetingHistoryItem) {
        guard state == .idle, !isProcessing else { return }
        completionMessage = nil
        lastError = nil
        transcriptionError = nil
        processing.export(meeting)
    }

    func dismissFailure() {
        guard state == .failed else { return }
        recording.clearFailure()
        lastError = nil
        privacyPermission = nil
        meetingTitle = ""
        refreshHistory()
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

    func startCalendarRecording(_ event: CalendarEvent, mode: CaptureMode = .screen) {
        guard state == .idle || state == .failed else { return }
        startRecording(calendarEvent: event, mode: mode)
    }

    func startRecording(calendarEvent: CalendarEvent? = nil, mode: CaptureMode = .screen) {
        guard state == .idle || state == .failed else { return }
        lastError = nil
        transcriptionError = nil
        completedFolder = nil
        privacyPermission = nil
        recording.start(calendarEvent: calendarEvent, mode: mode)
    }

    func cancelRecording() { recording.cancel() }

    /// Clears the queue's display after its last job; a capture in progress keeps its own title and clock.
    func processingDidFinish() {
        guard !isCapturing else { return }
        elapsed = 0
        meetingTitle = ""
        recording.titleWasProvided = true
        if state == .idle {
            lastError = nil
            privacyPermission = nil
        }
    }

    /// The meeting a finished export or a cancelled job reports on.
    func showOutcome(in folder: URL, message: String) {
        completedFolder = folder
        completionMessage = message
    }

    func transcriptSaved(in folder: URL) {
        completedFolder = folder
        updateFailedTranscriptionFolders { $0.remove(folder) }
        modelReady = Self.modelIsCached(speechSettings)
        modelSetupError = nil
        refreshHistory()
    }

    func transcriptionFailed(in folder: URL, error: Error) {
        completedFolder = folder
        updateFailedTranscriptionFolders { $0.insert(folder) }
        if state == .idle {
            // Shown inline: the next recording must still start with one click.
            transcriptionError = error
            refreshHistory()
        }
    }

    func cancelModelUnload() {
        modelUnloadTask?.cancel()
        modelUnloadTask = nil
    }

    /// Frees the speech model after a quiet period. A recording in progress keeps it for its own transcription.
    func scheduleModelUnload() {
        modelUnloadTask?.cancel()
        modelUnloadTask = Task { [weak self, transcriber] in
            // A loaded speech model stays in memory for five quiet minutes; loading it again takes a few seconds.
            try? await Task.sleep(for: .seconds(300))
            guard !Task.isCancelled, let self, !self.isProcessing, !self.isCapturing else { return }
            await transcriber.unloadIfIdle()
        }
    }

    /// Progress sources fire far more often than the integer-percent UI shows.
    static func shownPercent(_ fraction: Double?) -> Int? {
        fraction.map { Int(($0 * 100).rounded()) }
    }

    /// `folder` is the meeting the failure belongs to; a job transcribing meanwhile keeps its own state.
    func fail(_ error: Error, folder: URL? = nil) {
        recording.didFail()
        transcriptionError = nil
        processing.clearProgressUnlessRunning()
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
