import AppKit
import SwiftUI

/// The searchable list of recorded meetings below the menu's controls.
struct MeetingHistorySection: View {
    @EnvironmentObject private var model: AppModel
    @Binding var retranscribingMeeting: MeetingHistoryItem?
    @State private var hoveredMeetingID: MeetingHistoryItem.ID?
    @State private var searchFocusRequest = 0
    @State private var scrollOffset: CGFloat = 0

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
                MeetingSearchField(text: $model.historyQuery, focusRequest: searchFocusRequest)
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
                            ForEach(model.historyDays) { group in
                                Text(Self.dayTitle(group.day))
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.top, group.id == model.historyDays.first?.id ? 0 : 5)
                                    .padding(.bottom, 1)
                                    .accessibilityAddTraits(.isHeader)
                                ForEach(group.items) { item in
                                    historyRow(
                                        item,
                                        isNew: item.folderURL == model.completedFolder
                                            && !model.failedTranscriptionFolders.contains(item.folderURL.standardizedFileURL),
                                        canEdit: model.state == .idle && !model.isProcessing,
                                        status: rowStatus(item)
                                    )
                                    if item.id != group.items.last?.id {
                                        Divider()
                                    }
                                }
                            }
                        }
                        .scrollTargetLayout()
                    }
                    // Snaps to a row or day header so the top never shows a half-cut line,
                    // and hides a row that only partly fits at the bottom.
                    .scrollTargetBehavior(.viewAligned)
                    .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, offset in
                        scrollOffset = offset
                    }
                    .mask(alignment: .top) {
                        if let height = historyViewportHeight {
                            Color.black.frame(height: visibleHeight(in: height))
                        } else {
                            Color.black
                        }
                    }
                    .scrollIndicators(.hidden)
                }
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: historyViewportHeight, alignment: .top)
        }
    }

    private var historyViewportHeight: CGFloat? {
        guard model.hasMeetings, !model.allHistoryDays.isEmpty else { return nil }
        return Self.lineBottoms(model.allHistoryDays).last { $0 <= 232 } ?? 232
    }

    /// The height down to the last row or header that fits whole below the current scroll position.
    private func visibleHeight(in viewport: CGFloat) -> CGFloat {
        guard let bottom = Self.lineBottoms(model.historyDays).last(where: { $0 - scrollOffset <= viewport + 0.5 }),
              bottom > scrollOffset else { return viewport }
        return min(viewport, bottom - scrollOffset)
    }

    /// The bottom edge of each day header and row, matching the list's layout.
    private static func lineBottoms(_ days: [MeetingDayGroup]) -> [CGFloat] {
        var bottoms: [CGFloat] = []
        var height: CGFloat = 0
        for (groupIndex, group) in days.enumerated() {
            height += groupIndex == 0 ? 17 : 22
            bottoms.append(height)
            for itemIndex in group.items.indices {
                height += itemIndex == group.items.count - 1 ? 42 : 43
                bottoms.append(height)
            }
        }
        return bottoms
    }

    static func rowHelp(_ item: MeetingHistoryItem) -> String {
        let action = item.needsTranscription ? "Open meeting folder" : "Open transcript"
        guard item.totalBytes > 0 else { return action }
        return action + " · " + ByteCountFormatter.string(fromByteCount: item.totalBytes, countStyle: .file)
    }

    static func dayTitle(_ day: Date, now: Date = Date(), calendar: Calendar = .current) -> String {        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
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
        if model.failedTranscriptionFolders.contains(URL(fileURLWithPath: path)) { return .failed }
        return item.needsTranscription ? .notTranscribed : nil
    }

    func historyRow(_ item: MeetingHistoryItem, isNew: Bool, canEdit: Bool, status: MeetingRowStatus? = nil) -> some View {
        let badge: MeetingRowStatus? = status ?? (item.needsTranscription ? .notTranscribed : nil)
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
                        if let badge {
                            if badge == .failed, canEdit {
                                Button("Retry") { model.retryTranscription(item) }
                                    .buttonStyle(.bordered)
                                    .controlSize(.mini)
                                    .accessibilityLabel("Retry transcription for \(item.title)")
                            } else {
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
            .help(Self.rowHelp(item))
            .accessibilityLabel(item.needsTranscription
                ? "Open \(item.title), \(item.recordedAt.formatted(date: .abbreviated, time: .standard)), in Finder"
                : "Open transcript of \(item.title), \(item.recordedAt.formatted(date: .abbreviated, time: .standard))")
            .accessibilityValue(badge?.text ?? "")

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
            catch { NSAlert(error: error).runActive() }
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
    case failed

    var text: String {
        switch self {
        case .working(let text): text
        case .queued: "Queued"
        case .notTranscribed: "Not transcribed"
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
