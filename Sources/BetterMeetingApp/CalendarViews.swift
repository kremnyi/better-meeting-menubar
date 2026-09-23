import AppKit
import EventKit
import SwiftUI

/// Options → Meetings: where meetings come from, and when the app offers to record one.
struct MeetingOptionsView: View {
    @ObservedObject var calendar: CalendarIntegration
    @Binding var detectsMeetings: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Calendar").font(.callout.weight(.medium))
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Use calendar", isOn: Binding(
                    get: { calendar.enabled },
                    set: { calendar.setEnabled($0); Task { await calendar.refresh() } }
                ))
                Text("Lists upcoming meetings in the menu.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.leading, 18)
            }

            Group {
                if calendar.authorization == .fullAccess {
                    Toggle("Show next meeting in the menu bar", isOn: Binding(
                        get: { calendar.menuBarPreview },
                        set: { calendar.setMenuBarPreview($0) }
                    ))
                    calendarChoices
                } else {
                    accessRequest
                }
                if let error = calendar.errorMessage {
                    ErrorPanel(message: error)
                }
                if calendar.enabled, calendar.hasLoaded || calendar.isStale || calendar.errorMessage != nil {
                    Text(calendar.diagnosticSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .disabled(!calendar.enabled)
            .opacity(calendar.enabled ? 1 : 0.5)

            Divider()
            Text("Suggest recording").font(.callout.weight(.medium))
            CalendarReminderOptionsView(calendar: calendar, reminders: calendar.reminders)
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Detect meetings automatically", isOn: $detectsMeetings)
                    .help("Notifies you when another app has used the microphone for half a minute. Nothing is recorded on its own.")
                Text("For calls that aren’t on your calendar.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.leading, 18)
            }
        }
        .toggleStyle(.checkbox)
        .task { await calendar.refresh() }
    }

    @ViewBuilder
    private var calendarChoices: some View {
        Text("Calendars to show").font(.caption).foregroundStyle(.secondary)
        if calendar.isLoading && calendar.calendars.isEmpty && !calendar.hasLoaded {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(0..<3, id: \.self) { _ in
                    Toggle(isOn: .constant(false)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Calendar")
                            Text("Account").font(.caption).foregroundStyle(.secondary)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .redacted(reason: .placeholder)
            .disabled(true)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Loading calendars")
        } else if calendar.calendars.isEmpty {
            Text("No calendars available. Check that your account is enabled in macOS Calendar.")
                .fixedSize(horizontal: false, vertical: true)
        } else {
            let rows = VStack(alignment: .leading, spacing: 10) {
                ForEach(calendar.calendars) { choice in
                    Toggle(isOn: Binding(
                        get: { calendar.selectedIDs.contains(choice.id) },
                        set: { calendar.select(choice.id, enabled: $0); Task { await calendar.refresh() } }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(choice.title)
                                .lineLimit(1)
                                .help(choice.title)
                            Text(choice.account).font(.caption).foregroundStyle(.secondary)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityLabel("\(choice.title), \(choice.account)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // A short list takes the height of its rows; a long one scrolls, and the cut-off row shows there is more.
            if calendar.calendars.count <= 5 {
                rows
            } else {
                ScrollView { rows }.frame(height: 220)
            }
        }
    }

    @ViewBuilder
    private var accessRequest: some View {
        Text(calendar.authorization == .restricted
             ? "Calendar access is restricted by your Mac’s settings or administrator."
             : "macOS requires full calendar access to read events. Better Meeting never edits them.")
            .fixedSize(horizontal: false, vertical: true)
        if calendar.authorization == .notDetermined || calendar.authorization == .writeOnly {
            Button(calendar.requestingAccess ? "Requesting access…" : "Allow calendar access") {
                Task { await calendar.requestAccess() }
            }
            .disabled(calendar.requestingAccess)
        } else {
            Button("Open Calendar Privacy Settings…") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
            }
        }
    }
}

private struct CalendarReminderOptionsView: View {
    @ObservedObject var calendar: CalendarIntegration
    @ObservedObject var reminders: CalendarReminders

    /// Why the reminder can't fire right now; it stays visible so both ways to suggest a recording read together.
    private var unavailableReason: String? {
        if !calendar.enabled { return "Turn on Use calendar first." }
        if calendar.authorization != .fullAccess { return "Allow calendar access first." }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Toggle("When a calendar meeting starts", isOn: Binding(
                    get: { calendar.notifyAtStart },
                    set: { value in Task { await calendar.setNotifyAtStart(value) } }
                ))
                .disabled(reminders.requestingAccess || unavailableReason != nil)
                .help("Sends a notification with Start recording when a meeting from your selected calendars begins.")
                if let unavailableReason {
                    Text(unavailableReason)
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.leading, 18)
                }
                // Schedule status belongs under its own toggle, not between the two checkboxes.
                if calendar.notifyAtStart, unavailableReason == nil {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        let scheduled = reminders.scheduledEvents.filter { $0.scheduledStart > context.date }
                        if let next = scheduled.first {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(scheduled.count == 1 ? "1 meeting scheduled" : "\(scheduled.count) meetings scheduled")
                                Text("Next: \(next.title) · \(next.relativeStart(at: context.date))")
                                    .lineLimit(2)
                                    .help(next.title)
                            }
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.leading, 18)
                        } else if reminders.message == nil {
                            Text("No upcoming reminders scheduled.")
                                .font(.caption).foregroundStyle(.secondary)
                                .padding(.leading, 18)
                        }
                    }
                }
            }
            if calendar.notifyAtStart, unavailableReason == nil, let message = reminders.message {
                Text(message)
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 18)
                HStack {
                    Button("Notification Settings…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                    }
                    Button("Retry") { Task { await calendar.setNotifyAtStart(true) } }
                        .disabled(reminders.requestingAccess)
                }
            }
        }
    }
}

struct UpcomingMeetingView: View {
    @ObservedObject var calendar: CalendarIntegration
    let configure: () -> Void
    let record: (CalendarEvent) -> Void

    /// Once a meeting is under way or this close to starting, recording it is the likely next step.
    static let prominentRecordLeadTime: TimeInterval = 5 * 60

    var body: some View {
        Group {
            if calendar.enabled {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Upcoming meetings").font(.callout.weight(.medium))
                        Spacer()
                        Button(action: configure) {
                            Image(systemName: "calendar").frame(width: 28, height: 24)
                        }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Meeting options")
                            .help("Calendars and meeting suggestions")
                    }
                    if calendar.authorization != .fullAccess {
                        Button("Calendar access needed…", action: configure)
                    } else if calendar.isLoading && calendar.events.isEmpty && !calendar.hasLoaded {
                        HStack(alignment: .top, spacing: 8) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Event title").lineLimit(2)
                                Text("In 5 minutes · 10:00 – 11:00")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "record.circle")
                                .font(.system(size: 16))
                                .frame(width: 24, height: 24)
                        }
                        .redacted(reason: .placeholder)
                        .disabled(true)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Loading upcoming meetings")
                    } else {
                        let layout = UpcomingMeetingLayout.make(events: calendar.events, now: Date())
                        if let event = layout.primary {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .top, spacing: 8) {
                                    Button(action: openCalendar) {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(event.title).lineLimit(2).help(event.title)
                                            TimelineView(.periodic(from: .now, by: 60)) { context in
                                                Text(event.relativeStart(at: context.date) + " · " + event.timeRange)
                                                    .font(.caption).foregroundStyle(.secondary)
                                                    .fixedSize(horizontal: false, vertical: true)
                                                    .help(event.scheduledStart.formatted(date: .complete, time: .shortened))
                                            }
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .help("Open Calendar")
                                    .accessibilityLabel("Open Calendar for \(event.title)")
                                    TimelineView(.periodic(from: .now, by: 30)) { context in
                                        if event.scheduledStart.timeIntervalSince(context.date) <= Self.prominentRecordLeadTime {
                                            Button { record(event) } label: {
                                                Label("Record", systemImage: "record.circle")
                                            }
                                            .buttonStyle(.borderedProminent)
                                            .controlSize(.small)
                                            .tint(.signalCoral)
                                            .fixedSize()
                                            .accessibilityLabel("Record this meeting: \(event.title)")
                                            .help("Record this meeting")
                                        } else {
                                            Button { record(event) } label: {
                                                Image(systemName: "record.circle")
                                                    .font(.system(size: 16))
                                                    .frame(width: 28, height: 28)
                                                    .contentShape(Rectangle())
                                            }
                                            .buttonStyle(.borderless)
                                            .accessibilityLabel("Record this meeting: \(event.title)")
                                            .help("Record this meeting")
                                        }
                                    }
                                }
                                if !layout.compact.isEmpty {
                                    Divider().padding(.vertical, 2)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Later today")
                                            .font(.caption).foregroundStyle(.secondary)
                                        VStack(alignment: .leading, spacing: 4) {
                                            ForEach(layout.compact) { meeting in
                                                Button(action: openCalendar) {
                                                    HStack(spacing: 8) {
                                                        Text(meeting.timeRange)
                                                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                                        Text(meeting.title).font(.caption).lineLimit(1)
                                                        Spacer(minLength: 0)
                                                    }
                                                    .contentShape(Rectangle())
                                                }
                                                .buttonStyle(.plain)
                                                .help("Open Calendar · " + meeting.title)
                                                .accessibilityLabel("Open Calendar for \(meeting.title)")
                                            }
                                        }
                                    }
                                }
                                if layout.extraTodayCount > 0 {
                                    Button(action: openCalendar) {
                                        Text(layout.extraTodayCount == 1 ? "1 more today" : "\(layout.extraTodayCount) more today")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Show the rest in Calendar")
                                    .accessibilityLabel("Show \(layout.extraTodayCount) more meetings in Calendar")
                                }
                            }
                        } else if !calendar.calendars.contains(where: { calendar.selectedIDs.contains($0.id) }) {
                            Text("Choose calendars in Options → Meetings to see them here.")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("No more meetings today.")
                                if let tomorrow = layout.tomorrowFirst {
                                    Text("Tomorrow " + tomorrow.scheduledStart.formatted(date: .omitted, time: .shortened) + " · " + tomorrow.title)
                                        .lineLimit(1)
                                        .help(tomorrow.title)
                                }
                            }
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Divider()
            }
        }
        .task { await calendar.refresh() }
    }

    private func openCalendar() {
        NSWorkspace.shared.open(URL(string: "ical://")!)
    }
}

/// Splits the 24-hour event window for the menu's upcoming section. The window
/// itself stays 24 hours because reminders and the menu-bar preview depend on
/// it; the menu shows only today — the first meeting in full, then at most two
/// one-line rows and a count of the rest — and falls back to the first meeting
/// of tomorrow once today is done.
struct UpcomingMeetingLayout {
    let primary: CalendarEvent?
    let compact: [CalendarEvent]
    let extraTodayCount: Int
    let tomorrowFirst: CalendarEvent?

    static let compactLimit = 2

    static func make(events: [CalendarEvent], now: Date, calendar: Calendar = .current) -> UpcomingMeetingLayout {
        let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        let today = events.filter { $0.scheduledStart < tomorrowStart }
        let compact = Array(today.dropFirst().prefix(compactLimit))
        let tomorrow = events.first { $0.scheduledStart >= tomorrowStart }
        return UpcomingMeetingLayout(
            primary: today.first,
            compact: compact,
            extraTodayCount: max(0, today.count - 1 - compact.count),
            tomorrowFirst: today.isEmpty ? tomorrow : nil
        )
    }
}

extension CalendarEvent {
    /// `compact` abbreviates the countdown for the menu bar: "in 26m" or "in 1h20m".
    func relativeStart(at now: Date, calendar: Calendar = .current, compact: Bool = false) -> String {
        if scheduledEnd <= now { return "Ended" }
        if scheduledStart <= now { return "until " + scheduledEnd.formatted(date: .omitted, time: .shortened) }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                           to: calendar.startOfDay(for: scheduledStart)).day
        if days == 1 { return "Tomorrow " + scheduledStart.formatted(date: .omitted, time: .shortened) }
        if days != 0 { return scheduledStart.formatted(date: .abbreviated, time: .omitted) }
        let minutes = Int(ceil(scheduledStart.timeIntervalSince(now) / 60))
        if compact {
            if minutes < 60 { return "in \(minutes)m" }
            let remainder = minutes % 60
            return "in \(minutes / 60)h" + (remainder == 0 ? "" : "\(remainder)m")
        }
        let verb = "Starts "
        if minutes < 60 { return verb + "in \(minutes) min" }
        let remainder = minutes % 60
        return verb + "in \(minutes / 60) hr" + (remainder == 0 ? "" : " \(remainder) min")
    }

    var timeRange: String {
        scheduledStart.formatted(date: .omitted, time: .shortened) + "–"
            + scheduledEnd.formatted(date: Calendar.current.isDate(scheduledStart, inSameDayAs: scheduledEnd) ? .omitted : .abbreviated,
                                     time: .shortened)
    }
}
