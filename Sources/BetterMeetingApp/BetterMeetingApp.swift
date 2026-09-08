import SwiftUI
import UserNotifications

@main
struct BetterMeetingApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var processingFrame = 0
    @State private var iconTimer: Timer?
    @StateObject private var model: AppModel = {
        let model = AppModel()
        model.prepareSpeechModel()
        return model
    }()

    var body: some Scene {
        MenuBarExtra {
            MenuBarControlView()
                .environmentObject(model)
                .environmentObject(model.updates)
                .onAppear { appDelegate.model = model }
        } label: {
            MenuBarStatusIcon(state: model.state, processingFrame: processingFrame)
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
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
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
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        openNotification(response.notification.request)
    }

    func openNotification(_ request: UNNotificationRequest) {
        if request.content.categoryIdentifier == MeetingNotifications.audioWarningCategory {
            guard model?.state == .recording, model?.recordingID?.uuidString == request.identifier else { return }
            if let window = model?.menuWindow, window.isVisible {
                window.makeKeyAndOrderFront(nil)
                return
            }
            // This app owns one status item. Use its native button without private SwiftUI APIs.
            var views = NSApp.windows.compactMap(\.contentView)
            while let view = views.popLast() {
                if let button = view as? NSStatusBarButton {
                    button.performClick(nil)
                    return
                }
                views.append(contentsOf: view.subviews)
            }
            return
        }
        guard let folder = MeetingNotifications.folder(from: request.content) else { return }
        NSWorkspace.shared.open(folder)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model?.terminationReply() ?? .terminateNow
    }
}
