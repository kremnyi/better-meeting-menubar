import AppKit
import EventKit
import SwiftUI

struct CalendarOptionsView: View {
    @ObservedObject var calendar: CalendarIntegration

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Calendars").font(.headline)
            Toggle("Show upcoming meetings", isOn: Binding(
                get: { calendar.enabled },
                set: { calendar.setEnabled($0); Task { await calendar.refresh() } }
            ))
            .toggleStyle(.checkbox)

            if calendar.enabled {
                if calendar.authorization == .fullAccess {
                    Text("Choose calendars").font(.callout.weight(.medium))
                        .padding(.top, 4)
                    if calendar.isLoading && calendar.calendars.isEmpty {
                        ProgressView().controlSize(.small).accessibilityLabel("Loading calendars")
                    } else if calendar.calendars.isEmpty {
                        Text("No calendars available. Check that your account is enabled in macOS Calendar.")
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(calendar.calendars) { choice in
                                    Toggle(isOn: Binding(
                                        get: { calendar.selectedIDs.contains(choice.id) },
                                        set: { calendar.select(choice.id, enabled: $0); Task { await calendar.refresh() } }
                                    )) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(choice.title)
                                            Text(choice.account).font(.caption).foregroundStyle(.secondary)
                                        }
                                        .fixedSize(horizontal: false, vertical: true)
                                    }
                                    .toggleStyle(.checkbox)
                                    .accessibilityLabel("\(choice.title), \(choice.account)")
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: min(220, CGFloat(calendar.calendars.count) * 46))
                    }
                    Divider()
                    CalendarReminderOptionsView(calendar: calendar, reminders: calendar.reminders)
                } else {
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
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
                if let error = calendar.errorMessage {
                    Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task { await calendar.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await calendar.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in
            Task { await calendar.refresh() }
        }
    }
}

private struct CalendarReminderOptionsView: View {
    @ObservedObject var calendar: CalendarIntegration
    @ObservedObject var reminders: CalendarReminders

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Meeting reminders").font(.callout.weight(.medium))
            Toggle("Notify me when meetings start", isOn: Binding(
                get: { calendar.notifyAtStart },
                set: { value in Task { await calendar.setNotifyAtStart(value) } }
            ))
            .toggleStyle(.checkbox)
            .disabled(reminders.requestingAccess)
            if calendar.notifyAtStart {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    let scheduled = reminders.scheduledEvents.filter { $0.scheduledStart > context.date }
                    if let next = scheduled.first {
                        HStack(spacing: 10) {
                            Image(systemName: "calendar")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(scheduled.count == 1 ? "1 meeting scheduled" : "\(scheduled.count) meetings scheduled")
                                Text("Next: \(next.title) · \(next.relativeStart(at: context.date))")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .help(next.title)
                            }
                        }
                        .padding(.top, 4)
                    } else if reminders.message == nil {
                        if reminders.isUpdating {
                            ProgressView("Scheduling reminders…").controlSize(.small)
                        } else {
                            Text("No upcoming reminders scheduled.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if calendar.notifyAtStart, let message = reminders.message {
                Text(message).font(.caption).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Notification Settings…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
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

    var body: some View {
        Group {
            if calendar.enabled {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Upcoming meeting").font(.callout.weight(.medium))
                        Spacer()
                        Button(action: configure) {
                            Image(systemName: "calendar").frame(width: 24, height: 20)
                        }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Calendar options")
                            .help("Choose calendars")
                    }
                    if calendar.authorization != .fullAccess {
                        Button("Calendar access needed…", action: configure)
                    } else if calendar.isLoading && calendar.events.isEmpty {
                        ProgressView().controlSize(.small).accessibilityLabel("Loading upcoming meetings")
                    } else if let event = calendar.events.first {
                        HStack(alignment: .top, spacing: 8) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(event.title).lineLimit(2).help(event.title)
                                TimelineView(.periodic(from: .now, by: 60)) { context in
                                    Text(event.relativeStart(at: context.date) + " · " + event.timeRange)
                                        .font(.caption).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .help(event.scheduledStart.formatted(date: .complete, time: .shortened))
                                }
                                Text(event.calendarTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Button { record(event) } label: {
                                Image(systemName: "record.circle")
                                    .font(.system(size: 16))
                                    .frame(width: 24, height: 24)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Record this meeting: \(event.title)")
                            .help("Record this meeting")
                        }
                    } else {
                        Text(calendar.calendars.contains(where: { calendar.selectedIDs.contains($0.id) })
                             ? "No meetings in the next 24 hours."
                             : "Choose calendars in Options to see meetings.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Divider()
            }
        }
        .task {
            while !Task.isCancelled {
                await calendar.refresh()
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in
            Task { await calendar.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await calendar.refresh() }
        }
    }
}

extension CalendarEvent {
    func relativeStart(at now: Date, calendar: Calendar = .current) -> String {
        if scheduledEnd <= now { return "Ended" }
        if scheduledStart <= now { return "In progress" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                           to: calendar.startOfDay(for: scheduledStart)).day
        if days == 1 { return "Tomorrow" }
        if days != 0 { return scheduledStart.formatted(date: .abbreviated, time: .omitted) }
        let minutes = Int(ceil(scheduledStart.timeIntervalSince(now) / 60))
        if minutes < 60 { return "Starts in \(minutes) min" }
        let remainder = minutes % 60
        return "Starts in \(minutes / 60) hr" + (remainder == 0 ? "" : " \(remainder) min")
    }

    var timeRange: String {
        scheduledStart.formatted(date: .omitted, time: .shortened) + "–"
            + scheduledEnd.formatted(date: Calendar.current.isDate(scheduledStart, inSameDayAs: scheduledEnd) ? .omitted : .abbreviated,
                                     time: .shortened)
    }
}
