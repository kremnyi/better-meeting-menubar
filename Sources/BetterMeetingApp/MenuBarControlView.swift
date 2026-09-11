import AppKit
import SwiftUI

struct MenuBarControlView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var updates: AppUpdater
    @State var captureOptionsPresented = false
    @State private var calendarOptionsPresented = false
    @State private var appSettingsPresented = false
    @State private var retranscribingMeeting: MeetingHistoryItem?
    @State private var hoveredMeetingID: MeetingHistoryItem.ID?

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
                }
                .buttonStyle(.plain)
                .font(.callout)
                .help("Recording and app options")
                .accessibilityLabel("Options")
                .popover(isPresented: $captureOptionsPresented, arrowEdge: .top) {
                    CaptureOptionsView(
                        calendarsPresented: calendarOptionsPresented,
                        appSettingsPresented: appSettingsPresented
                    )
                }
                .onChange(of: captureOptionsPresented) { _, presented in
                    if !presented {
                        calendarOptionsPresented = false
                        appSettingsPresented = false
                    }
                }

                updateStatus

                Spacer()

                Button("Quit") {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.plain)
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
            model.refreshInputs()
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
        case .ready, .failed:
            Button(updates.status == .failed ? "Update failed — View details" : updates.status.message) {
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
            if model.isTranscribingBatch {
                batchProcessingContent
            } else if model.isProcessing {
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

            primaryActionButton

            modelSetupStatus

            completionStatus

            Divider()

            UpcomingMeetingView(calendar: model.calendar) {
                calendarOptionsPresented = true
                captureOptionsPresented = true
            } record: { event in
                model.startCalendarRecording(event)
            }

            historySection
        }
    }

    @ViewBuilder
    private var completionStatus: some View {
        if let message = model.completionMessage {
            VStack(alignment: .leading, spacing: 4) {
                Text(message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if let folder = model.completionFolder {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([folder])
                    }
                    .buttonStyle(.link)
                    .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
                    ProgressView(value: model.modelSetupFraction)
                        .progressViewStyle(.linear)
                        .accessibilityLabel(model.modelSetupStatus)
                    Text("You can record while setup finishes.")
                }
            }
            .font(.callout)
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !model.unfinishedRecordings.isEmpty, model.state == .idle, !model.isProcessing {
                HStack(spacing: 8) {
                    Text("\(model.unfinishedRecordings.count) unfinished")
                        .font(.callout)
                    Spacer(minLength: 0)
                    HStack(spacing: 0) {
                        Button {
                            model.transcribeAllRecordings()
                        } label: {
                            Text("Transcribe all")
                                .padding(.horizontal, 10)
                                .frame(height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Transcribe all unfinished recordings")

                        Rectangle().fill(.white.opacity(0.3)).frame(width: 1, height: 16)

                        Menu {
                            ForEach(model.unfinishedRecordings) { item in
                                Button("\(item.title) · \(item.recordedAt.formatted(date: .abbreviated, time: .shortened))") {
                                    model.retryTranscription(item)
                                }
                            }
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.caption.weight(.semibold))
                                .frame(width: 26, height: 28)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .accessibilityLabel("Choose a recording to transcribe")
                        .help("Choose one unfinished recording")
                    }
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.white)
                    .background(.blue, in: RoundedRectangle(cornerRadius: 6))
                    .fixedSize()
                }
            }

            Text("Recorded meetings")
                .font(.callout.weight(.medium))

            MeetingSearchField(text: $model.historyQuery)
                .frame(height: 24)

            Group {
                if model.searchingHistory {
                    Text("Searching meetings…")
                } else if model.transcriptionHistory.isEmpty {
                    Text(model.historyQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                         ? "Finished meetings will appear here. Open their folders in Finder."
                         : "No matching meetings.")
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(model.transcriptionHistory) { item in
                                historyRow(item, isSaved: item.folderURL == model.completedFolder, canEdit: model.state == .idle && !model.isProcessing)

                                if item.id != model.transcriptionHistory.last?.id {
                                    Divider()
                                }
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                }
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: model.historyListHeight, alignment: .top)

            Button {
                model.openMeetingsFolder()
            } label: {
                Label("Open meetings folder", systemImage: "folder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    func historyRow(_ item: MeetingHistoryItem, isSaved: Bool, canEdit: Bool) -> some View {
        HStack(spacing: 10) {
            Button {
                NSWorkspace.shared.open(item.folderURL)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.title)
                            .lineLimit(1)
                        if isSaved {
                            Label("Saved", systemImage: "checkmark.circle.fill")
                                .labelStyle(.iconOnly)
                                .foregroundStyle(.green)
                                .help("Saved")
                        }
                        if item.needsTranscription {
                            Text("Not transcribed")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .fixedSize()
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.15), in: Capsule())
                        }
                    }
                    .font(.callout)

                    HStack(spacing: 4) {
                        Text(item.recordedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                        Text("·")
                        Text(Timecode.string(item.duration))
                            .monospacedDigit()
                    }
                    .font(.callout)
                    .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open meeting folder")
            .accessibilityLabel("Open \(item.title), \(item.recordedAt.formatted(date: .abbreviated, time: .standard)), in Finder")

            Menu {
                meetingActions(item, canEdit: canEdit)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More actions for \(item.title)")
            .help("Copy, rename, re-transcribe, or export")
        }
        .frame(minHeight: 47)
        .contentShape(Rectangle())
        .background(
            hoveredMeetingID == item.id ? Color.primary.opacity(0.06) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .onHover { hovering in
            hoveredMeetingID = hovering ? item.id : nil
        }
        .contextMenu {
            meetingActions(item, canEdit: canEdit)
        }
    }

    @ViewBuilder
    private func meetingActions(_ item: MeetingHistoryItem, canEdit: Bool) -> some View {
        Button("Copy Transcript") {
            do { try model.copyTranscript(item) }
            catch { NSAlert(error: error).runModal() }
        }
        Button("Rename…") { model.renameMeeting(item) }
            .disabled(!canEdit)
        Button("Re-transcribe…") { retranscribingMeeting = item }
            .disabled(!canEdit)
        Button("Export bundle…") { model.exportBundle(item) }
            .disabled(!canEdit)
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
                .font(.system(size: 32, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .contentTransition(.numericText())

            VStack(spacing: 6) {
                audioMeter("Microphone", level: model.microphoneLevel)
                audioMeter("System audio", level: model.systemAudioLevel)
            }

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

            captureSummary

            modelSetupStatus

            if model.isProcessing {
                Text("Transcribing \(model.processingTitle.isEmpty ? "the previous meeting" : model.processingTitle) in the background…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var batchProcessingContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            captureSummary

            Text("You can start a new recording while this finishes in the background.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            primaryActionButton

            Divider()

            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .font(.title2)
                    .foregroundStyle(.blue)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Transcribing \(model.transcriptionBatchIndex) of \(model.transcriptionBatchTotal)")
                        .font(.callout.weight(.medium))
                    Text(model.processingTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(model.processingTitle)
                }
                Spacer(minLength: 0)
                Button("Cancel", action: model.cancelTranscription)
                    .disabled(!model.canCancelTranscription)
                    .accessibilityLabel("Cancel transcription queue")
                    .help("Stops the queue and keeps saved transcripts and recordings")
            }

            processingIndicator
                .tint(.blue)
                .accessibilityLabel(model.processingStatusText)

            HStack(alignment: .top) {
                Text(model.processingStatusText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text("\(model.transcriptionBatchWaiting) waiting")
                    .fixedSize()
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Divider()
            historySection
        }
    }

    private var processingContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(model.elapsedText)
                    .font(.title3.monospacedDigit())

                Text("recorded")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(model.processingStatusText)
                    .font(.callout)

                Spacer()

                if let phase = model.processingPhase {
                    Text(phase.stepText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            processingIndicator
                .tint(.signalCoral)
                .accessibilityLabel(model.processingStatusText)

            primaryActionButton

            Button(model.isExportingBundle ? "Cancel export" : "Cancel transcription", action: model.cancelTranscription)
                .disabled(!model.canCancelTranscription)
                .help(model.isExportingBundle ? "Keeps the transcript and previous export bundle" : "Keeps the recording and completed language passes so you can resume later")

            Divider()

            historySection
        }
    }

    private func audioMeter(_ label: String, level: Double) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.caption).frame(width: 78, alignment: .leading)
            ProgressView(value: level)
                .tint(.green)
                .accessibilityLabel(label)
                .accessibilityValue(level > 0 ? "Audio detected" : "No audio detected")
        }
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
                .tint(.signalCoral)

                Button(model.primaryButtonTitle, action: model.primaryAction)
                    .buttonStyle(.bordered)
            } else {
                primaryActionButton
            }

            Button("Back to meetings", action: model.dismissFailure)
                .buttonStyle(.bordered)
        }
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
                .foregroundStyle(model.privacyPermission != nil ? Color.orange : notice.isSecondary ? .secondary : .primary)
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
        VStack(alignment: .leading, spacing: 10) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)

            if let folder = model.completedFolder {
                Button("Show saved files") { NSWorkspace.shared.open(folder) }
            }
        }
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

private struct MeetingSearchField: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Search meetings"
        field.delegate = context.coordinator
        field.toolTip = "Search titles, transcripts, and calendar attendees"
        field.setAccessibilityLabel("Search all meetings")
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.sendsSearchStringImmediately = false
        field.sendsWholeSearchString = false
        field.target = context.coordinator
        field.action = #selector(Coordinator.search(_:))
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            control.stringValue = ""
            text.wrappedValue = ""
            return true
        }

        @objc func search(_ field: NSSearchField) {
            text.wrappedValue = field.stringValue
        }
    }
}
