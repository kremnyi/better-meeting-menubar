import AppKit
import SwiftUI

/// The searchable list of recorded meetings below the menu's controls.
struct MeetingHistorySection: View {
    @EnvironmentObject private var model: AppModel
    @Binding var retranscribingMeeting: MeetingHistoryItem?
    @State private var hoveredMeetingID: MeetingHistoryItem.ID?
    @State private var searchFocusRequest = 0

    var body: some View {
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
                            ForEach(model.historyDays) { group in
                                Text(Self.dayTitle(group.day))
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.top, group.id == model.historyDays.first?.id ? 0 : 5)
                                    .padding(.bottom, 1)
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
