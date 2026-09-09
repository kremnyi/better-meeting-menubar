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

            Text("Uses calendars synced with macOS. Add your Google account in System Settings → Internet Accounts, with Calendars enabled.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if calendar.enabled {
                if calendar.authorization == .fullAccess {
                    Text("Choose calendars").font(.callout.weight(.medium))
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
                    Text("Reads selected calendars without editing events. Turning this off keeps details already saved with recordings.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
                        Button(action: configure) { Image(systemName: "calendar") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Calendar options")
                            .help("Choose calendars")
                    }
                    if calendar.authorization != .fullAccess {
                        Button("Calendar access needed…", action: configure)
                    } else if calendar.isLoading && calendar.events.isEmpty {
                        ProgressView().controlSize(.small).accessibilityLabel("Loading upcoming meetings")
                    } else if let event = calendar.events.first {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(event.title).lineLimit(2).help(event.title)
                            Text(event.scheduledStart.formatted(date: .abbreviated, time: .shortened)
                                 + " – " + event.scheduledEnd.formatted(date: .omitted, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                            Text(event.calendarTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        HStack {
                            Button("Start recording") { record(event) }
                                .accessibilityLabel("Start recording \(event.title)")
                            if calendar.events.count > 1 {
                                Menu("Record another…") {
                                    ForEach(calendar.events.dropFirst()) { other in
                                        Button("Start recording — \(other.title) · \(other.scheduledStart.formatted(date: .abbreviated, time: .shortened))") {
                                            record(other)
                                        }
                                    }
                                }
                                .fixedSize()
                                .help("Start recording another event in the next 24 hours")
                            }
                        }
                        .controlSize(.small)
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
