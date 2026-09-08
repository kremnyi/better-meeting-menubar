import Foundation
import UserNotifications

enum MeetingNotifications {
    static let audioWarningCategory = "recording-audio-warning"

    static var center: UNUserNotificationCenter? {
        // Command-line tests do not have an application identity for notifications.
        guard Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        return .current()
    }

    static func requestPermission() async {
        guard let center, await center.notificationSettings().authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert])
    }

    static func post(title: String, folder: URL, failed: Bool) async {
        guard let content = try? content(title: title, folder: folder, failed: failed) else { return }
        await post(UNNotificationRequest(identifier: folder.path, content: content, trigger: nil))
    }

    static func post(_ request: UNNotificationRequest) async {
        guard let center else { return }
        let status = await center.notificationSettings().authorizationStatus
        let isAudioWarning = request.content.categoryIdentifier == audioWarningCategory
        guard status == .authorized || status == .provisional,
              !isAudioWarning || !Task.isCancelled else { return }
        try? await center.add(request)
        if isAudioWarning && Task.isCancelled { remove(request.identifier) }
    }

    static func audioWarning(recordingID: UUID) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "Check your recording"
        content.body = "No audio detected in this recording yet. Check your microphone and meeting audio."
        content.categoryIdentifier = audioWarningCategory
        return UNNotificationRequest(identifier: recordingID.uuidString, content: content, trigger: nil)
    }

    static func remove(_ identifier: String) {
        center?.removePendingNotificationRequests(withIdentifiers: [identifier])
        center?.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    static func content(title: String, folder: URL, failed: Bool) throws -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = failed ? "Transcription needs attention" : "Transcript ready"
        content.body = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? folder.lastPathComponent : title
        // A bookmark follows the folder if the meeting is renamed before the click.
        content.userInfo = ["meetingFolder": try folder.bookmarkData(options: .minimalBookmark)]
        return content
    }

    static func folder(from content: UNNotificationContent) -> URL? {
        guard let bookmark = content.userInfo["meetingFolder"] as? Data else { return nil }
        var stale = false
        guard let folder = try? URL(
            resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
            bookmarkDataIsStale: &stale
        ), folder.isFileURL,
              (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
        return folder
    }
}
