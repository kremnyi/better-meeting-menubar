import AppKit
import SwiftUI

struct MenuBarControlView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var updates: AppUpdater
    @Environment(\.colorScheme) private var colorScheme
    @State var captureOptionsPresented = false
    @State private var meetingOptionsPresented = false
    @State private var appSettingsPresented = false
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
                // Attached to the menu's side: below the footer a tall page runs out of
                // screen, and AppKit flips the popover to the top like a second window.
                .popover(isPresented: $captureOptionsPresented, arrowEdge: .trailing) {
                    CaptureOptionsView(
                        meetingsPresented: meetingOptionsPresented,
                        appSettingsPresented: appSettingsPresented
                    )
                }
                .onChange(of: captureOptionsPresented) { _, presented in
                    if !presented {
                        meetingOptionsPresented = false
                        appSettingsPresented = false
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
            if model.state == .idle, !model.isProcessing {
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
        case .ready:
            Button(updates.actionTitle) {
                updates.performAction()
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(updates.canPerformAction ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .disabled(!updates.canPerformAction)
            .help(updates.installationWaiting
                ? "The update will install when this meeting finishes."
                : updates.isBusy()
                    ? "Finish recording or processing before updating."
                    : "Install the update and relaunch Better Meeting")
        case .failed:
            Button("Update failed — View details") {
                appSettingsPresented = true
                captureOptionsPresented = true
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
            .help("Open update settings")
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle:
            if model.isTranscribingBatch || model.isProcessing {
                processingContent
            } else {
                idleContent
            }
        case .preparing:
            preparingContent
        case .recording:
            recordingContent
        case .failed:
            failedContent
        }
    }

    private var idleContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            captureSummary

            TextField("Meeting name (optional)", text: $model.meetingTitle)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.primaryAction() }
                .help("Press Return to start recording")

            primaryActionButton

            modelSetupStatus

            completionStatus

            Divider()

            UpcomingMeetingView(calendar: model.calendar) {
                meetingOptionsPresented = true
                captureOptionsPresented = true
            } record: { event in
                model.startCalendarRecording(event)
            }

            MeetingHistorySection(retranscribingMeeting: $retranscribingMeeting)
        }
    }

    @ViewBuilder
    private var completionStatus: some View {
        if let message = model.completionMessage {
            VStack(alignment: .leading, spacing: 4) {
                Text(message)
                    .font(.callout)
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
        }
    }

    @ViewBuilder
    private func completionActions(_ folder: URL) -> some View {
        if model.hasCompletedTranscript {
            Button("Open Transcript") { AppModel.openTranscript(in: folder) }
            Button(copiedTranscript ? "Copied" : "Copy Transcript") {
                do {
                    try AppModel.copyTranscript(in: folder)
                    copiedTranscript = true
                } catch {
                    NSAlert(error: error).runActive()
                }
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
                    Button("Retry setup", action: model.prepareSpeechModel)
                        .help(error)
                } else {
                    Text(model.modelSetupStatus)
                    if model.modelPreparationTask != nil {
                        ProgressView(value: model.modelSetupFraction)
                            .progressViewStyle(.linear)
                            .accessibilityLabel(model.modelSetupStatus)
                        Text("You can record while setup finishes.")
                    } else {
                        Button("Download model", action: model.prepareSpeechModel)
                            .disabled(model.isProcessing)
                    }
                }
            }
            .font(.callout)
        }
    }

    private var preparingContent: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(model.statusText)
                .font(.callout)
                .foregroundStyle(.secondary)
            processingIndicator
                .accessibilityLabel(model.statusText)
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
                Text(model.statusText)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .opacity(model.audioWarning ? 0 : 1)
                    .accessibilityHidden(model.audioWarning)
                VStack(alignment: .leading, spacing: 2) {
                    Label {
                        Text("No audio detected yet").fontWeight(.medium)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(colorScheme == .dark ? Color.orange : Color.attentionOrange)
                    }
                    Text("Check your microphone and meeting audio.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                .opacity(model.audioWarning ? 1 : 0)
                .accessibilityHidden(!model.audioWarning)
            }
            .font(.callout)

            primaryActionButton

            Button("Cancel recording") { model.cancelRecording() }
                .buttonStyle(.link)
                .font(.callout)
                .frame(maxWidth: .infinity)
                .help("Stop and discard this recording without transcribing it")

            modelSetupStatus

            if model.isProcessing {
                Text("Transcribing \(model.processingTitle.isEmpty ? "the previous meeting" : model.processingTitle) in the background…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var processingContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            captureSummary

            primaryActionButton

            Divider()

            HStack(spacing: 8) {
                Image(systemName: model.isExportingBundle ? "shippingbox" : "waveform")
                    .font(.title2)
                    .foregroundStyle(.tint)
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
                    .disabled(!model.canCancelTranscription)
                    .accessibilityLabel(model.isTranscribingBatch ? "Cancel transcription queue"
                        : model.isExportingBundle ? "Cancel export" : "Cancel transcription")
                    .help(model.isTranscribingBatch ? "Stops the queue and keeps saved transcripts and recordings"
                        : model.isExportingBundle ? "Keeps the transcript and previous export bundle"
                        : "Keeps the recording and completed language passes so you can resume later")
            }

            processingIndicator
                .accessibilityLabel(model.processingStatusText)

            HStack(alignment: .top) {
                Text(model.processingStatusText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if model.isTranscribingBatch {
                    Text("\(model.transcriptionBatchWaiting) waiting")
                        .fixedSize()
                } else if let phase = model.processingPhase {
                    Text(phase.stepText)
                        .fixedSize()
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Divider()
            MeetingHistorySection(retranscribingMeeting: $retranscribingMeeting)
        }
    }

    private var processingHeadline: String {
        if model.isTranscribingBatch {
            return "Transcribing \(model.transcriptionBatchIndex) of \(model.transcriptionBatchTotal)"
        }
        return model.isExportingBundle ? "Exporting bundle" : "Transcribing"
    }

    private var processingSubject: String {
        model.processingTitle.isEmpty ? "Untitled meeting" : model.processingTitle
    }

    @ViewBuilder
    private var processingIndicator: some View {
        if let fraction = model.processingFraction {
            HStack(spacing: 8) {
                ProgressView(value: fraction)

                Text(fraction, format: .percent.precision(.fractionLength(0)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
            }
            .progressViewStyle(.linear)
        } else {
            ProgressView()
                .controlSize(.small)
        }
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
            } else {
                primaryActionButton
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { failureSecondaryActions }
                VStack(alignment: .leading, spacing: 8) { failureSecondaryActions }
            }
        }
    }

    @ViewBuilder
    private var failureSecondaryActions: some View {
        if model.showsRecordingOptionsAction {
            Button("Open Recording Options") { captureOptionsPresented = true }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("open-recording-options")
        }
        if model.privacyPermission != nil {
            Button(model.primaryButtonTitle, action: model.primaryAction)
                .buttonStyle(.bordered)
        } else if let folder = model.completedFolder {
            Button("Show saved files") { NSWorkspace.shared.open(folder) }
                .buttonStyle(.bordered)
        }
        Button("Back to meetings", action: model.dismissFailure)
            .buttonStyle(.bordered)
    }

    private var primaryActionButton: some View {
        Button {
            model.primaryAction()
        } label: {
            Label(model.primaryButtonTitle, systemImage: model.primaryButtonSymbol)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(.signalCoral)
    }

    private var captureSummary: some View {
        let notice = model.captureAccessNotice
        return VStack(spacing: 6) {
            Label(notice.text, systemImage: model.captureAccessSymbol)
                .font(notice.isSecondary ? .caption : .callout)
                .foregroundStyle(model.captureAccessNeedsAttention
                    ? (colorScheme == .dark ? Color.orange : Color.attentionOrange)
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

/// Observes the clock alone, so 1 Hz ticks redraw only this text.
private struct RecordingElapsed: View {
    @ObservedObject var clock: RecordingClock

    var body: some View {
        Text(Timecode.compact(clock.elapsed))
            .font(.system(.largeTitle, design: .rounded).weight(.medium).monospacedDigit())
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

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            model?.menuWindow = window
        }
    }
}
