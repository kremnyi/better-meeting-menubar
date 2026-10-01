import AppKit
import SwiftUI

/// The searchable list of recorded meetings below the menu's controls.
struct MeetingHistorySection: View {
    @EnvironmentObject private var model: AppModel
    @Binding var retranscribingMeeting: MeetingHistoryItem?
    @State private var hoveredMeetingID: MeetingHistoryItem.ID?
    @State private var searchFocusRequest = 0

    /// Every row is this tall, divider included, so the list always shows whole rows and
    /// snapping to a row never leaves a gap or a cut-off line at the bottom.
    static let rowHeight: CGFloat = 43
    static let visibleRows = 5
    /// Space between a row's hover highlight and its text, matching the Options page rows.
    static let hoverInset: CGFloat = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error = model.historyError {
                ErrorPanel(message: model.hasMeetings
                           ? "Meetings folder unavailable. Showing the last available list."
                           : "Meetings folder unavailable. Your recordings are kept.", details: error)
                HStack {
                    Button("Retry") { model.refreshHistory() }
                    Button("Choose folder…") { model.chooseOutputFolder() }
                        .disabled(model.fileSettingsLocked)
                }
                .buttonStyle(.bordered)
            }
            if !model.transcribableRecordings.isEmpty, model.state == .idle, !model.isProcessing {
                let count = model.transcribableRecordings.count
                HStack(spacing: 8) {
                    Text("\(count) not transcribed")
                        .font(.callout)
                    Spacer(minLength: 0)
                    Menu {
                        ForEach(model.transcribableRecordings) { item in
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
                if model.historyTotalBytes > 0 {
                    Text(ByteCountFormatter.string(fromByteCount: model.historyTotalBytes, countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Disk space used by recorded meetings")
                }
                Spacer()
                if model.searchingHistory {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityLabel("Searching meetings")
                }
                Button(action: model.openMeetingsFolder) {
                    Image(systemName: "folder").frame(width: 28, height: 24)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Open meetings folder")
                .help("Open meetings folder in Finder")
            }

            if model.hasMeetings {
                // The list shows a handful of rows, so the field states how many meetings it searches.
                MeetingSearchField(text: $model.historyQuery, focusRequest: searchFocusRequest,
                                   placeholder: model.allMeetingCount > 1 ? "Search \(model.allMeetingCount) meetings" : "Search meetings")
                    .help("Search meetings (⌘F)")
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
                            ForEach(model.transcriptionHistory) { item in
                                historyRow(
                                    item,
                                    isNew: item.folderURL == model.completedFolder
                                        && !model.failedTranscriptionFolders.contains(item.folderURL.standardizedFileURL),
                                    canEdit: model.state == .idle && !model.isProcessing && model.historyError == nil,
                                    status: rowStatus(item)
                                )
                                .frame(height: Self.rowHeight)
                                .overlay(alignment: .top) {
                                    if item.id != model.transcriptionHistory.first?.id {
                                        Divider().padding(.horizontal, Self.hoverInset)
                                    }
                                }
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.viewAligned)
                    .scrollIndicators(.hidden)
                    // Rows pad their hover highlight past the text; the list gives that back so titles
                    // stay aligned with the heading and search field above.
                    .padding(.horizontal, -Self.hoverInset)
                }
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: historyViewportHeight, alignment: .top)
        }
    }

    /// Sized from every meeting, not search results, so searching never resizes the menu.
    private var historyViewportHeight: CGFloat? {
        guard model.hasMeetings, model.allMeetingCount > 0 else { return nil }
        return CGFloat(min(model.allMeetingCount, Self.visibleRows)) * Self.rowHeight
    }

    /// Leads with the full title, which the row cuts to one line.
    static func rowHelp(_ item: MeetingHistoryItem) -> String {
        let action = item.needsTranscription ? "Open meeting folder" : "Open transcript"
        let size = item.totalBytes > 0 ? " · " + ByteCountFormatter.string(fromByteCount: item.totalBytes, countStyle: .file) : ""
        return item.title + "\n" + (item.recoveryError ?? action) + size
    }

    static func dayTitle(_ day: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(day, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        return calendar.isDate(day, equalTo: now, toGranularity: .year)
            ? day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
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
        if model.failedTranscriptionFolders.contains(URL(fileURLWithPath: path)) { return .failed }
        return item.needsTranscription ? .notTranscribed : nil
    }

    func historyRow(_ item: MeetingHistoryItem, isNew: Bool, canEdit: Bool, status: MeetingRowStatus? = nil) -> some View {
        let badge: MeetingRowStatus? = item.recoveryFolder != nil ? .recoveryRequired
            : status ?? (item.needsTranscription ? .notTranscribed : nil)
        return HStack(spacing: 10) {
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
                        if let badge, !(badge == .failed && canEdit) {
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
                        Text(Self.dayTitle(item.recordedAt) + ", " + item.recordedAt.formatted(date: .omitted, time: .shortened))
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
            .help(Self.rowHelp(item))
            .accessibilityLabel(item.needsTranscription
                ? "Open \(item.title), \(item.recordedAt.formatted(date: .abbreviated, time: .standard)), in Finder"
                : "Open transcript of \(item.title), \(item.recordedAt.formatted(date: .abbreviated, time: .standard))")
            .accessibilityValue([isNew ? "New" : nil, badge?.text].compactMap { $0 }.joined(separator: ", "))

            // Beside the row button, not inside its label, so it stays its own control for VoiceOver.
            if item.recoveryFolder != nil, canEdit {
                Button("Retry recovery") { model.retryTranscriptRecovery(item) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(item.recoveryError ?? "Restore the previous transcript before transcribing")
                    .accessibilityLabel("Retry transcript recovery for \(item.title)")
            } else if badge == .failed, canEdit {
                Button("Retry") { model.retryTranscription(item) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize()
                    .accessibilityLabel("Retry transcription for \(item.title)")
                    .help("Transcription failed. Transcribe this recording again.")
            }

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
        .padding(.horizontal, Self.hoverInset)
        .frame(minHeight: 42)
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
            do { try AppModel.copyTranscript(in: item.folderURL) }
            catch { NSAlert(error: error).runActive() }
        }
        .disabled(item.recoveryFolder != nil
                  || !FileManager.default.fileExists(atPath: item.folderURL.appendingPathComponent("transcript.md").path))
        Button("Rename…") { model.renameMeeting(item) }
            .disabled(!canEdit || item.recoveryFolder != nil)
        Button(item.needsTranscription ? "Transcribe…" : "Re-transcribe…") { retranscribingMeeting = item }
            .disabled(!canEdit || item.recoveryFolder != nil)
        Button("Export bundle…") { model.exportBundle(item) }
            .disabled(!canEdit || item.needsTranscription || item.recoveryFolder != nil)
        Divider()
        Button("Move to Trash") { model.moveMeetingToTrash(item) }
            .disabled(!canEdit)
    }
}

enum MeetingRowStatus: Equatable {
    case working(String)
    case queued
    case notTranscribed
    case recoveryRequired
    case failed

    var text: String {
        switch self {
        case .working(let text): text
        case .queued: "Queued"
        case .notTranscribed: "Not transcribed"
        case .recoveryRequired: "Recovery required"
        case .failed: "Failed"
        }
    }

    var isWorking: Bool {
        if case .working = self { return true }
        return false
    }
}

private struct MeetingSearchField: NSViewRepresentable {
    @Binding var text: String
    /// Incremented to move keyboard focus into the field.
    var focusRequest = 0
    var placeholder = "Search meetings"

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = placeholder
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
        if field.placeholderString != placeholder { field.placeholderString = placeholder }
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
