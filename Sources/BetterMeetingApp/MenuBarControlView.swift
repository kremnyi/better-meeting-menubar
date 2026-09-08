import AppKit
import SwiftUI

struct MenuBarControlView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var updates: AppUpdater
    @State var captureOptionsPresented = false
    @State private var retranscribingMeeting: MeetingHistoryItem?

    private var updateReady: Bool {
        if case .ready = updates.status { true } else { false }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
                .padding(12)

            Divider()

            HStack(spacing: 8) {
                Button {
                    captureOptionsPresented.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Label("Options", systemImage: "slider.horizontal.3")
                        Circle()
                            .fill(.blue)
                            .frame(width: 6, height: 6)
                            .opacity(updateReady ? 1 : 0)
                            .accessibilityHidden(true)
                    }
                }
                .buttonStyle(.plain)
                .font(.callout)
                .help(updateReady ? "Update ready to install" : "Recording and app options")
                .accessibilityLabel(updateReady ? "Options, update ready to install" : "Options")
                .popover(isPresented: $captureOptionsPresented, arrowEdge: .top) {
                    CaptureOptionsView()
                }

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
    private var content: some View {
        switch model.state {
        case .idle:
            idleContent
        case .preparing:
            preparingContent
        case .recording:
            recordingContent
        case .processing:
            processingContent
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

            if let message = model.completionMessage {
                HStack(alignment: .top) {
                    Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
                    Button { model.completionMessage = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dismiss status")
                }
            }

            Divider()

            historySection
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
            if !model.unfinishedRecordings.isEmpty {
                Menu("Finish saved recording (\(model.unfinishedRecordings.count))") {
                    ForEach(model.unfinishedRecordings) { item in
                        Button("\(item.title) · \(item.recordedAt.formatted(date: .abbreviated, time: .shortened))") {
                            model.retryTranscription(item)
                        }
                    }
                }
                .disabled(model.state != .idle)
                .help("Retry transcription from a saved recording")
            }

            Text("Recent meetings")
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
                                historyRow(item, isSaved: item.folderURL == model.completedFolder, canEdit: model.state == .idle)

                                if item.id != model.transcriptionHistory.last?.id {
                                    Divider()
                                }
                            }
                        }
                        .padding(.trailing, 16)
                    }
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

            Spacer(minLength: 8)

            Button {
                NSWorkspace.shared.open(item.folderURL)
            } label: {
                Image(systemName: "folder")
                    .font(.body)
                    .foregroundStyle(.primary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .help("Show in Finder")
            .accessibilityLabel("Show \(item.title), \(item.recordedAt.formatted(date: .abbreviated, time: .standard)), in Finder")
        }
        .frame(minHeight: 47)
        .contentShape(Rectangle())
        .contextMenu {
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

            Text(model.statusText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            primaryActionButton

            captureSummary

            modelSetupStatus
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
                Text(model.statusText)
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
                .accessibilityLabel(model.statusText)

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
        return Label(notice.text, systemImage: model.captureAccessSymbol)
            .font(notice.isSecondary ? .caption : .callout)
            .foregroundStyle(model.privacyPermission != nil ? Color.orange : notice.isSecondary ? .secondary : .primary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
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

private struct MeetingSearchField: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Search meetings"
        field.toolTip = "Search all titles and transcripts"
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

    final class Coordinator: NSObject {
        var text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        @objc func search(_ field: NSSearchField) {
            text.wrappedValue = field.stringValue
        }
    }
}
