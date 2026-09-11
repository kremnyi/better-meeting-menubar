import SwiftUI
import UserNotifications

@main
struct BetterMeetingApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var processingFrame = 0
    @State private var iconTimer: Timer?
    @StateObject private var model: AppModel

    init() {
        let model = AppModel()
        _model = StateObject(wrappedValue: model)
        appDelegate.model = model
        model.calendar.startMonitoring()
        model.prepareSpeechModel()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarControlView()
                .environmentObject(model)
                .environmentObject(model.updates)
        } label: {
            MenuBarStatusLabel(model: model, calendar: model.calendar, state: model.state, processingFrame: processingFrame)
        }
        .menuBarExtraStyle(.window)
        .onChange(of: model.automaticUpdateChecks, initial: true) { _, enabled in
            model.updates.start(automaticChecks: enabled)
        }
        .onChange(of: model.state) {
            model.updates.resumePendingInstallation()
        }
        .onChange(of: model.state == .processing && !reduceMotion, initial: true) { _, animate in
            iconTimer?.invalidate()
            iconTimer = nil
            processingFrame = 0
            if animate {
                let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
                    processingFrame = (processingFrame + 1) % BrandAssets.processingMenuBarFrames.count
                }
                RunLoop.main.add(timer, forMode: .common)
                iconTimer = timer
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    weak var model: AppModel?

    func applicationWillFinishLaunching(_ notification: Notification) {
        MeetingNotifications.center?.delegate = self
        MeetingNotifications.center?.setNotificationCategories([CalendarReminder.category])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        if notification.request.content.categoryIdentifier == CalendarReminder.categoryID {
            return await shouldPresentCalendarReminder(notification.request) ? [.banner, .list, .sound] : []
        }
        if notification.request.content.categoryIdentifier == MeetingNotifications.audioWarningCategory {
            return await shouldPresentAudioWarning(notification.request) ? [.banner, .list] : []
        }
        return [.banner, .list]
    }

    func shouldPresentAudioWarning(_ request: UNNotificationRequest) -> Bool {
        model?.audioWarning == true && model?.recordingID?.uuidString == request.identifier
            && model?.menuWindow?.isVisible != true
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        if response.notification.request.content.categoryIdentifier == CalendarReminder.categoryID {
            await handleCalendarReminder(response.notification.request, action: response.actionIdentifier)
            return
        }
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        openNotification(response.notification.request)
    }

    func shouldPresentCalendarReminder(_ request: UNNotificationRequest) async -> Bool {
        guard let model, model.calendar.enabled, model.calendar.notifyAtStart else { return false }
        await model.calendar.refresh()
        return model.calendar.events.contains {
            CalendarReminder.matches(request, event: $0) && $0.scheduledEnd > Date()
                && model.calendar.selectedIDs.contains($0.providerCalendarId)
        }
    }

    func handleCalendarReminder(_ request: UNNotificationRequest, action: String,
                                start: ((CalendarEvent) -> Void)? = nil) async {
        guard action == UNNotificationDefaultActionIdentifier || action == CalendarReminder.startActionID else { return }
        guard let model else { return }
        if action == CalendarReminder.startActionID, model.state == .idle {
            do {
                guard model.calendar.notifyAtStart,
                      let id = request.content.userInfo["occurrenceId"] as? String else { throw CalendarRecordingError.eventUnavailable }
                let event = try await model.calendar.eventForRecording(id: id)
                guard CalendarReminder.matches(request, event: event) else { throw CalendarRecordingError.eventUnavailable }
                guard model.state == .idle else { return }
                if let start { start(event) } else { model.startCalendarRecording(event) }
            } catch {
                if model.state == .idle {
                    model.completionMessage = "This meeting changed or is no longer available. Check the upcoming meeting, or start a manual recording."
                }
            }
        }
        showMenu()
    }

    private func showMenu() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = model?.menuWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return
        }
        clickStatusItem()
    }

    // This app owns one status item. Use its native button without private SwiftUI APIs.
    private func clickStatusItem() {
        var views = NSApp.windows.compactMap(\.contentView)
        while let view = views.popLast() {
            if let button = view as? NSStatusBarButton { button.performClick(nil); return }
            views.append(contentsOf: view.subviews)
        }
    }

    func openNotification(_ request: UNNotificationRequest) {
        if request.content.categoryIdentifier == MeetingNotifications.audioWarningCategory {
            guard model?.state == .recording, model?.recordingID?.uuidString == request.identifier else { return }
            if let window = model?.menuWindow, window.isVisible {
                window.makeKeyAndOrderFront(nil)
                return
            }
            clickStatusItem()
            return
        }
        guard let folder = MeetingNotifications.folder(from: request.content) else { return }
        NSWorkspace.shared.open(folder)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model?.terminationReply() ?? .terminateNow
    }
}
