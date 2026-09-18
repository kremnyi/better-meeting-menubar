import AppKit
import SwiftUI

struct MenuBarControlView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var updates: AppUpdater
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
                .popover(isPresented: $captureOptionsPresented, arrowEdge: .top) {
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
        .frame(width: 304)
        .background(MenuWindowReader(model: model).frame(width: 0, height: 0).accessibilityHidden(true))
        .sheet(item: $retranscribingMeeting) { meeting in
            RetranscriptionView(
                meeting: meeting, languages: model.transcriptionLanguages, hints: model.transcriptionHints,
                settings: MeetingArtifacts.speechSettings(in: meeting.folderURL) ?? model.speechSettings
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
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent("transcript.md").path) {
            Button("Open Transcript") { AppModel.openTranscript(in: folder) }
            Button(copiedTranscript ? "Copied" : "Copy Transcript") {
                do {
                    try AppModel.copyTranscript(in: folder)
                    copiedTranscript = true
                } catch {
                    NSAlert(error: error).runModal()
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
            Text(model.elapsedText)
                .font(.system(size: 32, weight: .medium).monospacedDigit())
                .contentTransition(.numericText())

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
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
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
                errorView(error)
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
                .foregroundStyle(model.captureAccessNeedsAttention ? Color.orange : notice.isSecondary ? .secondary : .primary)
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

    private func errorView(_ message: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                if let title = model.failureTitle {
                    Text(title)
                        .fontWeight(.medium)
                }
                Text(message)
                    .foregroundStyle(model.failureTitle == nil ? .primary : .secondary)
                    .textSelection(.enabled)
            }
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
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
