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
    @State private var searchFocusRequest = 0
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
                }
                .buttonStyle(.plain)
                .font(.callout)
                .keyboardShortcut(",")
                .help("Recording and app options (⌘,)")
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
            model.refreshInputs()
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

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !model.unfinishedRecordings.isEmpty, model.state == .idle, !model.isProcessing {
                let count = model.unfinishedRecordings.count
                HStack(spacing: 8) {
                    Text("\(count) not transcribed")
                        .font(.callout)
                    Spacer(minLength: 0)
                    Menu {
                        ForEach(model.unfinishedRecordings) { item in
                            Button("\(item.title) · \(item.recordedAt.formatted(date: .abbreviated, time: .shortened))") {
                                model.retryTranscription(item)
                            }
                        }
                    } label: {
                        Text(count == 1 ? "Transcribe" : "Transcribe all")
                    } primaryAction: {
                        model.transcribeAllRecordings()
                    }
                    .menuStyle(.button)
                    .buttonStyle(.bordered)
                    .fixedSize()
                    .help(count == 1 ? "Transcribe this recording" : "Transcribe all \(count) recordings, or choose one from the arrow")
                }
            }

            HStack(spacing: 6) {
                Text("Recorded meetings")
                    .font(.callout.weight(.medium))
                Spacer()
                if model.searchingHistory {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityLabel("Searching meetings")
                }
                Button(action: model.openMeetingsFolder) {
                    Image(systemName: "folder").frame(width: 24, height: 20)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Open meetings folder")
                .help("Open meetings folder in Finder")
            }

            if model.hasMeetings {
                MeetingSearchField(text: $model.historyQuery, focusRequest: searchFocusRequest)
                    .frame(height: 24)
                    .background {
                        // Invisible target for ⌘F; the search field itself is AppKit.
                        Button("Search meetings") { searchFocusRequest += 1 }
                            .keyboardShortcut("f")
                            .opacity(0)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
            }

            Group {
                if model.transcriptionHistory.isEmpty {
                    Text(model.searchingHistory ? "Searching meetings…"
                         : model.historyQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                         ? "Finished meetings will appear here. Click one to open its transcript."
                         : "No matching meetings.")
                } else {
                    // Earlier results stay while a search runs; the header shows its progress.
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            let groups = Self.dayGroups(model.transcriptionHistory)
                            ForEach(groups) { group in
                                Text(Self.dayTitle(group.day))
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.top, group.id == groups.first?.id ? 0 : 10)
                                    .padding(.bottom, 2)
                                    .accessibilityAddTraits(.isHeader)
                                ForEach(group.items) { item in
                                    historyRow(
                                        item, isNew: item.folderURL == model.completedFolder,
                                        canEdit: model.state == .idle && !model.isProcessing,
                                        status: rowStatus(item)
                                    )
                                    if item.id != group.items.last?.id {
                                        Divider()
                                    }
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
        }
    }

    struct DayGroup: Identifiable {
        let day: Date
        var items: [MeetingHistoryItem]
        var id: Date { day }
    }

    /// Runs of meetings from the same day, keeping the list's order.
    static func dayGroups(_ items: [MeetingHistoryItem], calendar: Calendar = .current) -> [DayGroup] {
        var groups: [DayGroup] = []
        for item in items {
            let day = calendar.startOfDay(for: item.recordedAt)
            if groups.last?.day == day {
                groups[groups.count - 1].items.append(item)
            } else {
                groups.append(DayGroup(day: day, items: [item]))
            }
        }
        return groups
    }

    static func dayTitle(_ day: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(day, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        return calendar.isDate(day, equalTo: now, toGranularity: .year)
            ? day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
            : day.formatted(.dateTime.month(.abbreviated).day().year())
    }

    private func rowStatus(_ item: MeetingHistoryItem) -> MeetingRowStatus? {
        let path = item.folderURL.standardizedFileURL.path
        if model.isProcessing, model.processingFolder?.standardizedFileURL.path == path {
            let verb = model.processingPhase == .finalizingRecording ? "Saving"
                : model.isExportingBundle ? "Exporting" : "Transcribing"
            guard let fraction = model.processingFraction else { return .working(verb) }
            return .working("\(verb) · \(fraction.formatted(.percent.precision(.fractionLength(0))))")
        }
        if model.queuedFolders.contains(where: { $0.standardizedFileURL.path == path }) { return .queued }
        return item.needsTranscription ? .notTranscribed : nil
    }

    func historyRow(_ item: MeetingHistoryItem, isNew: Bool, canEdit: Bool, status: MeetingRowStatus? = nil) -> some View {
        HStack(spacing: 10) {
            Button {
                open(item)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.title)
                            .lineLimit(1)
                        if isNew {
                            Text("New")
                                .font(.caption)
                                .foregroundStyle(.tint)
                                .lineLimit(1)
                                .fixedSize()
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.15), in: Capsule())
                                .help("Just saved")
                        }
                        if let badge = status ?? (item.needsTranscription ? .notTranscribed : nil) {
                            Text(badge.text)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(badge.isWorking ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                                .lineLimit(1)
                                .fixedSize()
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background((badge.isWorking ? Color.accentColor : Color.secondary).opacity(0.15), in: Capsule())
                        }
                    }
                    .font(.callout)

                    HStack(spacing: 4) {
                        Text(item.recordedAt, format: .dateTime.hour().minute())
                        Text("·")
                        Text(Timecode.readable(item.duration))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(item.needsTranscription ? "Open meeting folder" : "Open transcript")
            .accessibilityLabel(item.needsTranscription
                ? "Open \(item.title), \(item.recordedAt.formatted(date: .abbreviated, time: .standard)), in Finder"
                : "Open transcript of \(item.title), \(item.recordedAt.formatted(date: .abbreviated, time: .standard))")
            .accessibilityValue((status ?? (item.needsTranscription ? .notTranscribed : nil))?.text ?? "")

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
            .help("Open, copy, rename, re-transcribe, export, or move to Trash")
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

    private func open(_ item: MeetingHistoryItem) {
        if item.needsTranscription {
            NSWorkspace.shared.open(item.folderURL)
        } else {
            AppModel.openTranscript(in: item.folderURL)
        }
    }

    @ViewBuilder
    private func meetingActions(_ item: MeetingHistoryItem, canEdit: Bool) -> some View {
        Button("Open Transcript") { open(item) }
            .disabled(item.needsTranscription)
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([item.folderURL])
        }
        Divider()
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
        Divider()
        Button("Move to Trash") { model.moveMeetingToTrash(item) }
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
                .font(.system(size: 32, weight: .medium).monospacedDigit())
                .contentTransition(.numericText())

            TextField("Meeting name (optional)", text: $model.meetingTitle)
                .textFieldStyle(.roundedBorder)
                .help("The name is used when recording stops")

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
            historySection
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

    private func audioMeter(_ label: String, level: Double) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.caption).frame(width: 78, alignment: .leading)
            // Empty when silent; a progress bar's rounded start looked like a slider knob.
            Capsule()
                .fill(Color.primary.opacity(0.1))
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule()
                            .fill(Color.green)
                            .frame(width: proxy.size.width * min(max(level, 0), 1))
                    }
                }
                .frame(height: 5)
                .accessibilityElement()
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

enum MeetingRowStatus: Equatable {
    case working(String)
    case queued
    case notTranscribed

    var text: String {
        switch self {
        case .working(let text): text
        case .queued: "Queued"
        case .notTranscribed: "Not transcribed"
        }
    }

    var isWorking: Bool {
        if case .working = self { return true }
        return false
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
    /// Incremented to move keyboard focus into the field.
    var focusRequest = 0

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Search meetings"
        field.delegate = context.coordinator
        field.toolTip = "Search titles, transcripts, and calendar attendees (⌘F)"
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
        if context.coordinator.focusRequest != focusRequest {
            context.coordinator.focusRequest = focusRequest
            field.window?.makeFirstResponder(field)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, focusRequest: focusRequest) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        var focusRequest: Int

        init(text: Binding<String>, focusRequest: Int) {
            self.text = text
            self.focusRequest = focusRequest
        }

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
