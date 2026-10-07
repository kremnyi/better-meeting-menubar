import AppKit

/// What the menu shows for the current state, and the app-level actions behind its buttons:
/// the primary button, quitting while busy, and opening meeting files.
extension AppModel {
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

    var showsRecordingOptionsAction: Bool {
        guard let error = lastError as? RecorderError else { return false }
        return switch error {
        case .noDisplay, .noMicrophone: true
        default: false
        }
    }

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
            recording.finish(stoppingCapture: true)
        } else if state == .failed, privacyPermission == .screenRecording {
            restartApplication()
        } else if state == .failed, retryableMeeting != nil {
            retryFailedTranscription()
        } else if state == .idle || state == .failed {
            startRecording(mode: state == .failed ? recording.captureMode : .screen)
        }
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
            recording.cancelStart()
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
        if state == .recording { recording.finish(stoppingCapture: true) }
        // terminateLater keeps AppKit in a modal loop and stalls menu-bar updates.
        return .terminateCancel
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

    func openMeetingsFolder() {
        try? FileManager.default.createDirectory(
            at: outputRoot,
            withIntermediateDirectories: true
        )
        NSWorkspace.shared.open(outputRoot)
    }

    private func restartApplication() {
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
}
