import AppKit
import AVFoundation
import Combine
import CoreGraphics
import Foundation

private let failedTranscriptionFoldersKey = "failedTranscriptionFolders"

/// A separate object so the 1 Hz tick redraws only the views that show the time.
@MainActor
final class RecordingClock: ObservableObject {
    @Published var elapsed: TimeInterval = 0
}

@MainActor
final class AppModel: ObservableObject {
    @Published var meetingTitle = ""
    private(set) lazy var recording = RecordingSession(model: self)
    private(set) lazy var processing = ProcessingQueue(model: self)
    private var forwardedChanges: [AnyCancellable] = []
    var state: AppState { recording.state }
    let recordingClock = RecordingClock()
    var elapsed: TimeInterval {
        get { recordingClock.elapsed }
        set { recordingClock.elapsed = newValue }
    }
    let meters = AudioMeters()
    weak var menuWindow: NSWindow?
    @Published private(set) var lastError: Error?
    @Published private(set) var transcriptionError: Error?
    @Published var completedFolder: URL? {
        didSet {
            hasCompletedTranscript = completedFolder.map {
                FileManager.default.fileExists(atPath: $0.appendingPathComponent("transcript.md").path)
            } ?? false
            updateRetryableMeeting()
        }
    }
    private(set) var hasCompletedTranscript = false
    @Published private(set) var outputRoot: URL
    @Published private(set) var privacyPermission: PrivacyPermission?
    @Published private(set) var transcriptionHistory: [MeetingHistoryItem] = []
    @Published private(set) var historyError: String?
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
    var isTranscribingBatch: Bool { processing.batchTotal > 0 }
    var transcriptionBatchWaiting: Int { max(0, processing.batchTotal - processing.batchIndex) }
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
    var modelTransferInProgress: Bool { modelPreparationTask != nil || modelDownloadTask != nil }
    var modelWorkInProgress: Bool { processing.isProcessing || isCapturing || modelTransferInProgress }
    private(set) var modelDownloadKind: StoredModelInfo.Kind?
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
        return isCapturing || processing.isProcessing
    }
    @Published var automaticUpdateChecks: Bool {
        didSet { defaults.set(automaticUpdateChecks, forKey: "checkUpdatesOnLaunch") }
    }
    @Published var menuBarRecordingTime: Bool {
        didSet { defaults.set(menuBarRecordingTime, forKey: "menuBarRecordingTime") }
    }
    @Published var statusPlacement: StatusPlacement {
        didSet { defaults.set(statusPlacement.rawValue, forKey: "statusPlacement") }
    }
    @Published var detectsMeetings: Bool {
        didSet {
            defaults.set(detectsMeetings, forKey: "detectMeetings")
            meetingDetector.setEnabled(detectsMeetings)
        }
    }
    lazy var meetingDetector = MeetingDetector(isBusy: { [weak self] in
        guard let self else { return true }
        return (state != .idle && state != .failed) || processing.isProcessing
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
        if modelReady, modelPreparationTask != nil {
            // The cached model is ready; a still-running download of the old one must not report on it.
            modelPreparationTask?.cancel()
            modelPreparationTask = nil
            modelPreparationSettings = nil
            modelPreparationToken += 1
            return
        }
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
    var modelUnloadDelay: Duration = .seconds(300)
    lazy var unloadSpeechModels: () async -> Void = { [transcriber] in await transcriber.unloadIfIdle() }
    var quitWhenFinished = false
    private(set) var historySearchTask: Task<Void, Never>?
    private(set) var historyRefreshTask: Task<Void, Never>?
    private var historyRefreshStart = ContinuousClock.now - .seconds(1)
    private var completedMeetings: [MeetingHistoryItem] = [] {
        didSet { updateRetryableMeeting() }
    }
    private var meetingsByRecency: [MeetingHistoryItem] = []
    private(set) var modelPreparationSettings: SpeechSettings?

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
        let savedRoot = defaults.url(forKey: "outputFolder")
        let defaultRoot = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Better Meetings", isDirectory: true)
        if savedRoot == nil { try? FileManager.default.createDirectory(at: defaultRoot, withIntermediateDirectories: true) }
        outputRoot = savedRoot ?? defaultRoot
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
        statusPlacement = StatusPlacement(rawValue: defaults.string(forKey: "statusPlacement") ?? "") ?? .menuBar
        detectsMeetings = defaults.bool(forKey: "detectMeetings")
        speechSettings = defaults.data(forKey: "speechSettings")
            .flatMap { try? JSONDecoder().decode(SpeechSettings.self, from: $0) } ?? SpeechSettings()
        if (try? speechSettings.validate()) == nil { speechSettings = SpeechSettings() }
        let loadedSettings = speechSettings
        // Default on for preferences only; a saved meeting without the field keeps no labels on retry.
        if speechSettings.speakerLabels == nil { speechSettings.speakerLabels = true }
        if speechSettings.engine == nil, !transcriptionLanguages.allSatisfy(SpeechSettings.parakeetLanguages.contains) {
            speechSettings.engine = .whisper
        }
        if speechSettings != loadedSettings { defaults.set(try? JSONEncoder().encode(speechSettings), forKey: "speechSettings") }
        storedModels = LocalTranscriber.storedModels(sizes: false)
        modelReady = Self.modelIsCached(speechSettings)
        grantedAccess = captureAccess()
        updates.allowsBetaUpdates = betaUpdates
        forwardedChanges = [recording.objectWillChange, processing.objectWillChange].map { $0.sink { [weak self] in self?.objectWillChange.send() } }
        refreshHistory()
    }

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

    @Published private(set) var grantedAccess: (screen: Bool, microphone: AVAuthorizationStatus) = (false, .notDetermined)

    func refreshCaptureAccess() {
        let access = captureAccess()
        if access != grantedAccess { grantedAccess = access }
    }

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

    /// Off the main thread: discovery can take seconds while it looks for Continuity or virtual microphones.
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

    // Download-only; each engine loads on first transcription so picking one never compiles in the background.
    func prepareSpeechModel() {
        guard !modelReady, !processing.isProcessing, modelDownloadTask == nil, state == .idle || state == .recording else { return }
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
                await refreshStoredModels()
            } catch {
                guard modelPreparationToken == token else { return }
                modelReady = false
                if error is CancellationError {
                    modelSetupStatus = "Speech model download cancelled"
                } else {
                    modelSetupError = error.localizedDescription
                    modelSetupStatus = "Speech model unavailable"
                }
                await refreshStoredModels()
                throw error
            }
        }
    }

    func refreshStoredModels() async {
        storedModels = await Task.detached(priority: .utility) { LocalTranscriber.storedModels() }.value
    }

    func deleteStoredModel(_ item: StoredModelInfo) async {
        guard !modelWorkInProgress else { return }
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
        downloadStoredModel(item) { [transcriber] report in
            switch item.kind {
            case .whisper(let model):
                try await transcriber.download(model: model, progress: report)
            case .parakeet:
                try await transcriber.downloadParakeet(progress: report)
            case .speakerLabels:
                try await transcriber.downloadSpeakerModels()
            }
        }
    }

    func downloadStoredModel(
        _ item: StoredModelInfo, _ download: @escaping (@escaping @Sendable (Double) -> Void) async throws -> Void
    ) {
        guard !modelWorkInProgress else { return }
        modelDownloadError = nil
        modelDownload = (item.id, 0)
        modelDownloadKind = item.kind
        modelDownloadTask = Task {
            defer {
                modelDownload = nil
                modelDownloadKind = nil
                modelDownloadTask = nil
            }
            let report: @Sendable (Double) -> Void = { [weak self] fraction in
                Task { @MainActor [weak self] in
                    guard let self, let shown = modelDownload, shown.id == item.id,
                          Self.shownPercent(fraction) != Self.shownPercent(shown.fraction) else { return }
                    modelDownload = (item.id, fraction)
                }
            }
            do {
                try await download(report)
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
        if processing.isProcessing,
           [.preparingModel, .downloadingModel, .loadingModel].contains(processing.phase) {
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
        guard !processing.isProcessing, !isTranscribingBatch, state == .idle || state == .failed else { return }
        if let backup = item.recoveryFolder {
            lastError = MeetingActionError.transcriptRecovery(backup)
            return
        }
        if recording.state == .failed { recording.state = .idle }
        prepareSavedTranscription(item)
        processing.enqueue(run(
            for: item, replacing: item.needsTranscription ? nil : item,
            languages: languages, hints: hints,
            settings: settings
        ))
    }

    /// Uses the last job's options only for an inline transcription failure; a capture failure never ran a job.
    func retryFailedTranscription() {
        guard let item = retryableMeeting else { return }
        let options = transcriptionError != nil ? processing.lastOptions : nil
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
        guard state == .idle, !processing.isProcessing, !isTranscribingBatch, !recordings.isEmpty else { return }
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
        } catch { NSAlert(error: error).runActive() }
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
        transcriptionError = nil
        if !isCapturing { elapsed = item.duration }
        if state != .failed {
            completedFolder = nil
            lastError = nil
            privacyPermission = nil
        }
        processing.show(item)
    }

    func cancelTranscription() { processing.cancel() }

    func exportBundle(_ meeting: MeetingHistoryItem) {
        guard state == .idle, !processing.isProcessing else { return }
        completionMessage = nil
        lastError = nil
        transcriptionError = nil
        processing.export(meeting)
    }

    func dismissFailure() {
        guard state == .failed else { return }
        recording.state = .idle
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
        // Cancel now: a pending search over the old folder must not publish before the new scan.
        historySearchTask?.cancel()
        refreshHistory()
    }

    func refreshHistory(scan: (@Sendable (URL) throws -> [MeetingHistoryItem])? = nil) {
        historyRefreshTask?.cancel()
        let root = outputRoot
        let scan = scan ?? { [library] in try library.meetings(in: $0) }
        // The first refresh scans at once; later ones within 300 ms join one trailing scan.
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

    func moveMeetingToTrash(
        _ meeting: MeetingHistoryItem,
        trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) {
        guard state == .idle, !processing.isProcessing else { return }
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
        guard state == .idle, !processing.isProcessing else { return }
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

    func startRecording(calendarEvent: CalendarEvent? = nil, mode: CaptureMode = .screen) {
        guard state == .idle || state == .failed else { return }
        lastError = nil
        transcriptionError = nil
        completedFolder = nil
        privacyPermission = nil
        recording.start(calendarEvent: calendarEvent, mode: mode)
    }

    func cancelRecording() { recording.cancel() }

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

    func showJobResult(in folder: URL) {
        if state != .failed { completedFolder = folder }
    }

    func transcriptSaved(in folder: URL) {
        transcriptionError = nil
        showJobResult(in: folder)
        updateFailedTranscriptionFolders { $0.remove(folder) }
        modelReady = Self.modelIsCached(speechSettings)
        modelSetupError = nil
        refreshHistory()
    }

    func transcriptionCancelled(in folder: URL) {
        transcriptionError = nil
        showJobResult(in: folder)
        refreshHistory()
    }

    func transcriptionFailed(in folder: URL, error: Error) {
        showJobResult(in: folder)
        updateFailedTranscriptionFolders { $0.insert(folder) }
        if state == .idle {
            transcriptionError = error
            refreshHistory()
        }
    }

    func cancelModelUnload() {
        modelUnloadTask?.cancel()
        modelUnloadTask = nil
    }

    func scheduleModelUnload() {
        modelUnloadTask?.cancel()
        modelUnloadTask = Task { [weak self] in
            // A busy app tries again later, so a recording that is discarded still releases the model.
            while true {
                try? await Task.sleep(for: self?.modelUnloadDelay ?? .seconds(300))
                guard !Task.isCancelled, let self else { return }
                if !processing.isProcessing, !isCapturing { break }
            }
            await self?.unloadSpeechModels()
        }
    }

    static func shownPercent(_ fraction: Double?) -> Int? {
        fraction.map { Int(($0 * 100).rounded()) }
    }

    func fail(_ error: Error, folder: URL? = nil) {
        recording.stopTimer()
        recording.state = .failed
        recording.statusText = "Couldn’t finish this recording."
        transcriptionError = nil
        if processing.task == nil {
            processing.fraction = nil
            processing.phase = nil
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
    /// A menu-bar app must activate first, or the alert never becomes key and its text field ignores mouse selection.
    @MainActor
    @discardableResult
    func runActive() -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        return runModal()
    }
}
