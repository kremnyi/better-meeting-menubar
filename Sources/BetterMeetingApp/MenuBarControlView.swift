import AppKit
import SwiftUI

struct MenuBarControlView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var updates: AppUpdater
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State var captureOptionsPresented = false
    @State private var optionsPage: CaptureOptionsView.Page = .options
    @State private var retranscribingMeeting: MeetingHistoryItem?
    @State private var copiedTranscript = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
                .padding(12)

            Divider()

            HStack(spacing: 8) {
                Button {
                    captureOptionsPresented.toggle()
                } label: {
                    Label("Options", systemImage: "slider.horizontal.3")
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .font(.callout)
                .keyboardShortcut(",")
                .help("Recording and app options (⌘,)")
                .accessibilityLabel("Options")
                // Trailing edge: below the footer a tall page runs off screen and AppKit flips the popover to the top.
                .popover(isPresented: $captureOptionsPresented, arrowEdge: .trailing) {
                    CaptureOptionsView(page: optionsPage)
                }
                .onChange(of: captureOptionsPresented) { _, presented in
                    if !presented {
                        optionsPage = .options
                    }
                }

                updateStatus

                Spacer()

                Button("Quit") {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("q")
                .help("Quit Better Meeting (⌘Q)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        // Fixed so long titles wrap instead of stretching the menu; layout tests pin this width.
        .frame(width: 304)
        .background(MenuWindowReader(model: model).frame(width: 0, height: 0).accessibilityHidden(true))
        .sheet(item: $retranscribingMeeting) { meeting in
            RetranscriptionView(
                meeting: meeting, languages: model.transcriptionLanguages, hints: model.transcriptionHints,
                settings: MeetingArtifacts.speechSettings(in: meeting.folderURL) ?? model.speechSettings,
                dismiss: { retranscribingMeeting = nil }
            ) { languages, hints, settings in
                model.retryTranscription(meeting, languages: languages, hints: hints, settings: settings)
            }
        }
        .onAppear {
            model.refreshHistory()
            model.refreshCaptureAccess()
            CaptureOptionsView.refreshLaunchAtLoginStatusInBackground()
        }
        .onChange(of: model.completionMessage) { copiedTranscript = false }
        .onDisappear {
            // The idle menu showed the message while it was open; don't repeat it next time.
            if model.state == .idle, !model.processing.isProcessing {
                model.completionMessage = nil
            }
        }
    }

    @ViewBuilder
    private var updateStatus: some View {
        switch updates.status {
        case .downloading, .preparing, .installing:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
                Text(updates.status.message)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .available, .downloaded, .ready:
            Button(updates.actionTitle, action: updates.performAction)
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(updates.canPerformAction ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .disabled(!updates.canPerformAction)
            .help(updates.installationWaiting
                ? "The update will install when this meeting finishes."
                : updates.isBusy()
                    ? "Finish recording or processing before updating."
                    : "Download and install the update, then relaunch Better Meeting")
        case .failed:
            Button {
                optionsPage = .appSettings
                captureOptionsPresented = true
            } label: {
                Label {
                    Text("Update failed")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.attention(colorScheme))
                }
            }
            .buttonStyle(.plain)
            .font(.caption)
            .help("Update failed. Open update settings for details.")
            .accessibilityLabel("Update failed. View details")
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle:
            idleContent
        case .preparing, .stopping:
            preparingContent
        case .recording:
            recordingContent
        case .failed:
            failedContent
        }
    }

    /// One stack for both idle states, so the history list keeps its scroll position and search focus.
    private var idleContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            captureSummary

            startControls

            if model.isTranscribingBatch || model.processing.isProcessing {
                processingStatus
            } else {
                idleStatus
            }

            MeetingHistorySection(retranscribingMeeting: $retranscribingMeeting)
        }
    }

    @ViewBuilder
    private var idleStatus: some View {
        Group { transcriptionFailureStatus }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: model.errorMessage)

        modelSetupStatus

        Group { completionStatus }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: model.completionMessage)

        Divider()

        UpcomingMeetingView(calendar: model.calendar) {
            optionsPage = .meetings
            captureOptionsPresented = true
        } record: { event in
            model.startRecording(calendarEvent: event)
        }
    }

    private var startControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Meeting name (optional)", text: $model.meetingTitle)
                .textFieldStyle(.roundedBorder)
                .onSubmit { startFromMenu() }
                .help("Press Return to start recording")
            StartRecordingButton(calendar: model.calendar, meetingTitle: model.meetingTitle) { startFromMenu(mode: $0) }
        }
    }

    private func startFromMenu(mode: CaptureMode = .screen) {
        let event = StartRecordingButton.imminentEvent(in: model.calendar, title: model.meetingTitle, at: Date())
        model.startRecording(calendarEvent: event, mode: mode)
    }

    @ViewBuilder
    private var transcriptionFailureStatus: some View {
        if let meeting = model.failedTranscriptionMeeting, let message = model.errorMessage {
            VStack(alignment: .leading, spacing: 8) {
                ErrorPanel(message: message, title: model.failureTitle, details: model.errorDetails)
                HStack(spacing: 8) {
                    Button("Retry transcription", action: model.retryFailedTranscription)
                        .accessibilityLabel("Retry transcription for \(meeting.title)")
                        .help("Transcribe the saved recording again with the same options")
                    Button("Dismiss", action: model.dismissTranscriptionFailure)
                        .help("Hide this message. The meeting stays marked Failed in the list.")
                }
                .buttonStyle(.bordered)
            }
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
        }
    }

    @ViewBuilder
    private var completionStatus: some View {
        if let message = model.completionMessage {
            VStack(alignment: .leading, spacing: 4) {
                Text(message)
                    .font(.callout)
                    .contentTransition(reduceMotion ? .identity : .opacity)
                    .fixedSize(horizontal: false, vertical: true)
                if message.hasPrefix("Transcribed "), !model.unfinishedRecordings.isEmpty {
                    let count = model.unfinishedRecordings.count
                    Text(count == 1 ? "1 still needs transcription." : "\(count) still need transcription.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let folder = model.completedFolder {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) { completionActions(folder) }
                        VStack(alignment: .leading, spacing: 4) { completionActions(folder) }
                    }
                    .buttonStyle(.link)
                    .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
        }
    }

    @ViewBuilder
    private func completionActions(_ folder: URL) -> some View {
        if model.hasCompletedTranscript {
            Button("Open Transcript") { AppModel.openTranscript(in: folder) }
            Button {
                if AppModel.copyTranscriptOrAlert(in: folder) {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { copiedTranscript = true }
                }
            } label: {
                Text(copiedTranscript ? "Copied" : "Copy Transcript")
                    .contentTransition(reduceMotion ? .identity : .opacity)
            }
        }
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        }
    }

    @ViewBuilder
    private var modelSetupStatus: some View {
        if !model.modelReady {
            VStack(alignment: .leading, spacing: 6) {
                if let error = model.modelSetupError {
                    Text("Speech model unavailable. You can still record.")
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Retry setup", action: model.prepareSpeechModel)
                } else {
                    Text(model.modelSetupStatus)
                    if model.modelPreparationTask != nil {
                        ProgressView(value: model.modelSetupFraction)
                            .progressViewStyle(.linear)
                            .accessibilityLabel(model.modelSetupStatus)
                        Text("You can record while setup finishes.")
                    } else {
                        Button("Download model", action: model.prepareSpeechModel)
                            .disabled(model.processing.isProcessing)
                    }
                }
            }
            .font(.callout)
        }
    }

    private var preparingContent: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(model.recording.statusText)
                .font(.callout)
                .foregroundStyle(.secondary)
            processingIndicator
                .accessibilityLabel(model.recording.statusText)
            diskSpaceWarning
        }
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
    }

    private var recordingContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            RecordingElapsed(clock: model.recordingClock)

            TextField("Meeting name (optional)", text: $model.meetingTitle)
                .textFieldStyle(.roundedBorder)
                .help("The name is used when recording stops")

            AudioMetersView(meters: model.meters)

            ZStack(alignment: .leading) {
                Text(model.recording.statusText)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .opacity(model.recording.audioWarning ? 0 : 1)
                    .accessibilityHidden(model.recording.audioWarning)
                VStack(alignment: .leading, spacing: 2) {
                    Label {
                        Text(model.recording.audioWarningTitle).fontWeight(.medium)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.attention(colorScheme))
                    }
                    Text(model.recording.audioWarningDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                .opacity(model.recording.audioWarning ? 1 : 0)
                .accessibilityHidden(!model.recording.audioWarning)
            }
            .font(.callout)
            .animation(.easeInOut(duration: 0.2), value: model.recording.audioWarning)

            diskSpaceWarning

            primaryActionButton

            Button("Cancel recording") { model.cancelRecording() }
                .buttonStyle(.link)
                .font(.callout)
                .frame(maxWidth: .infinity)
                .help("Stop and discard this recording without transcribing it")

            modelSetupStatus

            if model.processing.isProcessing {
                Text("Transcribing \(model.processing.title.isEmpty ? "the previous meeting" : model.processing.title) in the background…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var diskSpaceWarning: some View {
        if let space = model.recording.diskSpace, space.isLow {
            VStack(alignment: .leading, spacing: 2) {
                Label("Low recording disk space", systemImage: "externaldrive.badge.exclamationmark")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Color.attention(colorScheme))
                Text(space.warning)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var processingStatus: some View {
        Divider()

        HStack(spacing: 8) {
            Image(systemName: model.processing.isExportingBundle ? "shippingbox" : "waveform")
                .font(.title2)
                .foregroundStyle(.tint)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.variableColor.iterative.dimInactiveLayers, options: .repeating,
                              isActive: !reduceMotion && !model.processing.isExportingBundle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(processingHeadline)
                    .font(.callout.weight(.medium))
                Text(processingSubject)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(processingSubject)
            }
            Spacer(minLength: 0)
            Button("Cancel", action: model.cancelTranscription)
                .disabled(!model.processing.canCancel)
                .accessibilityLabel(model.isTranscribingBatch ? "Cancel transcription queue"
                    : model.processing.isExportingBundle ? "Cancel export" : "Cancel transcription")
                .help(model.isTranscribingBatch ? "Stops the queue and keeps saved transcripts and recordings"
                    : model.processing.isExportingBundle ? "Keeps the transcript and previous export bundle"
                    : "Keeps the recording and completed language passes so you can resume later")
        }

        processingIndicator
            .accessibilityLabel(model.processing.statusText)

        HStack(alignment: .top) {
            Text(model.processing.statusText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if model.isTranscribingBatch {
                Text("\(model.transcriptionBatchWaiting) waiting")
                    .fixedSize()
            } else if let phase = model.processing.phase {
                Text(phase.stepText)
                    .fixedSize()
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)

        Divider()
    }

    private var processingHeadline: String {
        if model.isTranscribingBatch {
            return "Transcribing \(model.processing.batchIndex) of \(model.processing.batchTotal)"
        }
        return model.processing.isExportingBundle ? "Exporting bundle" : "Transcribing"
    }

    private var processingSubject: String {
        model.processing.title.isEmpty ? "Untitled meeting" : model.processing.title
    }

    @ViewBuilder
    private var processingIndicator: some View {
        // Steps without a known fraction keep the same bar and percentage slot, so the layout holds between steps.
        let fraction = model.processing.fraction
        HStack(spacing: 8) {
            if let fraction {
                ProgressView(value: fraction)
            } else {
                ProgressView()
            }

            Text(fraction ?? 0, format: .percent.precision(.fractionLength(0)))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
                .opacity(fraction == nil ? 0 : 1)
        }
        .progressViewStyle(.linear)
    }

    private var failedContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.privacyPermission != nil {
                captureSummary
            }

            if let error = model.errorMessage {
                ErrorPanel(message: error, title: model.failureTitle, details: model.errorDetails)
            }

            if let permission = model.privacyPermission {
                Button {
                    if let url = permission.settingsURL { NSWorkspace.shared.open(url) }
                } label: {
                    Label("Open System Settings", systemImage: "gearshape")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else if model.showsRecordingOptionsAction {
                // Trying again with the same missing device fails the same way; choosing another comes first.
                Button {
                    captureOptionsPresented = true
                } label: {
                    Label("Open Recording Options", systemImage: "slider.horizontal.3")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                primaryActionButton
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { failureSecondaryActions }
                VStack(alignment: .leading, spacing: 8) { failureSecondaryActions }
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private var failureSecondaryActions: some View {
        // Equal widths line the row up with the full-width primary button above it.
        if model.privacyPermission != nil || model.showsRecordingOptionsAction {
            Button { model.primaryAction() } label: { Text(model.primaryButtonTitle).frame(maxWidth: .infinity) }
        } else if let folder = model.completedFolder {
            Button { NSWorkspace.shared.open(folder) } label: { Text("Show saved files").frame(maxWidth: .infinity) }
        }
        Button(action: model.dismissFailure) { Text("Back to meetings").frame(maxWidth: .infinity) }
    }

    private var primaryActionButton: some View {
        Button(action: model.primaryAction) {
            Label {
                Text(model.primaryButtonTitle)
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
            } icon: {
                Image(systemName: model.primaryButtonSymbol)
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(.signalCoral)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: model.primaryButtonTitle)
    }

    private var captureSummary: some View {
        let notice = model.captureAccessNotice
        return VStack(spacing: 6) {
            // The symbol flows inline so a wrapped notice centers every line; a Label keeps its title leading.
            Text("\(Image(systemName: model.captureAccessSymbol)) \(notice.text)")
                .font(notice.isSecondary ? .caption : .callout)
                .foregroundStyle(model.captureAccessNeedsAttention
                    ? Color.attention(colorScheme)
                    : notice.isSecondary ? .secondary : .primary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)

            if let settingsURL = model.captureAccessSettingsURL {
                Button("Open System Settings") { NSWorkspace.shared.open(settingsURL) }
                    .buttonStyle(.link)
                    .controlSize(.small)
            }
        }
    }
}

private struct StartRecordingButton: View {
    @ObservedObject var calendar: CalendarIntegration
    let meetingTitle: String
    let start: (CaptureMode) -> Void
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    // Native menus retint template SF Symbols black in light appearance; use a non-template white image.
    private static let menuChevron: NSImage = {
        let configuration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        guard let symbol = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return NSImage() }
        return NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            return true
        }
    }()

    static func imminentEvent(in calendar: CalendarIntegration, title: String, at now: Date) -> CalendarEvent? {
        guard title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              calendar.enabled, calendar.authorization == .fullAccess,
              let event = UpcomingMeetingLayout.make(events: calendar.events, now: now).primary,
              event.scheduledEnd > now,
              event.scheduledStart.timeIntervalSince(now) <= UpcomingMeetingView.prominentRecordLeadTime else { return nil }
        return event
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let event = Self.imminentEvent(in: calendar, title: meetingTitle, at: context.date)
            Button { start(.screen) } label: {
                HStack(spacing: 0) {
                    Label {
                        Text(event.map { "Record “\($0.title)”" } ?? "Start recording")
                            .lineLimit(1)
                    } icon: {
                        Image(systemName: "record.circle")
                    }
                    .frame(maxWidth: .infinity)
                    Color.white.opacity(0.25)
                        .frame(width: 1, height: 14)
                        .accessibilityHidden(true)
                    // Reserve the native menu's hit area without nesting it in this button.
                    Color.clear.frame(width: 32, height: 14)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(hovering && isEnabled ? .signalCoralHover : .signalCoral)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering && isEnabled)
            .onHover { hovering = $0 }
            .onDisappear { hovering = false }
            .help(event == nil ? "Record screen and audio. Use the arrow for audio-only."
                : "Records with this meeting’s calendar details. Use the arrow for audio-only, or type a name above to record something else.")
            .accessibilityLabel(event.map { "Record \($0.title)" } ?? "Start recording")
            .overlay(alignment: .trailing) {
                // A sibling control: opening its menu must never trigger screen capture.
                Menu {
                    Button("Record audio-only") { start(.audioOnly) }
                        .help("Record system audio and microphone without saving screen video")
                } label: {
                    Image(nsImage: Self.menuChevron)
                        .renderingMode(.original)
                        .frame(width: 32, height: 28)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 32, height: 28)
                .help("Recording options")
                .accessibilityLabel("Recording options")
            }
        }
    }
}

/// Observes the clock alone, so 1 Hz ticks redraw only this text.
private struct RecordingElapsed: View {
    @ObservedObject var clock: RecordingClock

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "circle.fill")
                .font(.body)
                .foregroundStyle(colorScheme == .dark ? Color.signalCoralBright : Color.signalCoral)
                .symbolEffect(.pulse, options: .repeating.speed(0.5), isActive: !reduceMotion)
                .accessibilityHidden(true)
            Text(Timecode.compact(clock.elapsed))
                .font(.system(.largeTitle, design: .rounded).weight(.medium).monospacedDigit())
                .contentTransition(reduceMotion ? .identity : .numericText(value: clock.elapsed))
                .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: clock.elapsed)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recording time")
        .accessibilityValue(Timecode.compact(clock.elapsed))
    }
}

private struct MenuWindowReader: NSViewRepresentable {
    let model: AppModel

    func makeNSView(context: Context) -> WindowView {
        let view = WindowView()
        view.model = model
        return view
    }

    func updateNSView(_ view: WindowView, context: Context) {}

    final class WindowView: NSView {
        weak var model: AppModel?
        private var keyObserver: Any?

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if newWindow == nil, model?.menuWindow === window { model?.menuWindow = nil }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            keyObserver.map(NotificationCenter.default.removeObserver)
            keyObserver = nil
            guard let window else { return }
            model?.menuWindow = window
            // With both the menu bar and the notch, the menu opened last routes notifications.
            keyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.model?.menuWindow = self?.window }
            }
        }
    }
}
