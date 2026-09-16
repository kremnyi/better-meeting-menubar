import AppKit
import UserNotifications
import XCTest
@testable import BetterMeetingApp

@MainActor
final class MeetingDetectorTests: XCTestCase {
    /// Stands in for Core Audio so the microphone can go in and out of use on demand.
    private final class MicrophoneFixture: MicrophoneUse {
        private(set) var started = 0
        private(set) var stopped = 0
        private var report: ((Bool) -> Void)?

        func start(_ onChange: @escaping (Bool) -> Void) {
            started += 1
            report = onChange
        }

        func stop() {
            stopped += 1
            report = nil
        }

        func send(_ inUse: Bool) { report?(inUse) }
    }

    private final class NotificationFixture {
        var posted: [UNNotificationRequest] = []
        var removed: [String] = []
        var onPost: (() -> Void)?
    }

    private func makeDetector(busy: @escaping () -> Bool = { false })
        -> (detector: MeetingDetector, microphone: MicrophoneFixture, notifications: NotificationFixture) {
        let microphone = MicrophoneFixture()
        let notifications = NotificationFixture()
        let detector = MeetingDetector(
            source: microphone, isBusy: busy,
            post: { request in
                notifications.posted.append(request)
                notifications.onPost?()
            },
            remove: { notifications.removed.append($0) }
        )
        detector.delay = 0.01
        return (detector, microphone, notifications)
    }

    func testOneSuggestionPerCallOnTheMicrophone() async throws {
        let (detector, microphone, notifications) = makeDetector()
        let suggested = expectation(description: "suggested")
        notifications.onPost = { suggested.fulfill() }
        detector.setEnabled(true)
        XCTAssertEqual(microphone.started, 1)

        microphone.send(true)
        microphone.send(true) // A second report of the same call must not queue another suggestion.
        await fulfillment(of: [suggested], timeout: 2)
        XCTAssertEqual(notifications.posted.count, 1)
        let request = try XCTUnwrap(notifications.posted.first)
        XCTAssertEqual(request.identifier, MicrophoneMeeting.requestID)
        XCTAssertEqual(request.content.categoryIdentifier, MicrophoneMeeting.categoryID)
        XCTAssertFalse(request.content.title.isEmpty)

        microphone.send(true)
        XCTAssertEqual(notifications.posted.count, 1, "The suggestion stands until the call ends")
    }

    func testEndingTheCallWithdrawsTheSuggestionAndArmsTheNext() async throws {
        let (detector, microphone, notifications) = makeDetector()
        var suggested = expectation(description: "first call")
        notifications.onPost = { suggested.fulfill() }
        detector.setEnabled(true)
        microphone.send(true)
        await fulfillment(of: [suggested], timeout: 2)

        microphone.send(false)
        XCTAssertEqual(notifications.removed, [MicrophoneMeeting.requestID])

        suggested = expectation(description: "second call")
        microphone.send(true)
        await fulfillment(of: [suggested], timeout: 2)
        XCTAssertEqual(notifications.posted.count, 2)
    }

    func testNothingIsSuggestedWhileTheAppItselfRecords() async throws {
        var recording = true
        let (detector, microphone, notifications) = makeDetector(busy: { recording })
        let quiet = expectation(description: "no suggestion")
        quiet.isInverted = true
        notifications.onPost = { quiet.fulfill() }
        detector.setEnabled(true)

        microphone.send(true) // Our own recorder holds the microphone for the whole recording.
        await fulfillment(of: [quiet], timeout: 0.3)
        XCTAssertTrue(notifications.posted.isEmpty)

        recording = false
        let suggested = expectation(description: "suggested")
        notifications.onPost = { suggested.fulfill() }
        microphone.send(false)
        microphone.send(true)
        await fulfillment(of: [suggested], timeout: 2)
    }

    func testTurningDetectionOffStopsWatchingAndWithdraws() async throws {
        let (detector, microphone, notifications) = makeDetector()
        let suggested = expectation(description: "suggested")
        notifications.onPost = { suggested.fulfill() }
        detector.setEnabled(true)
        microphone.send(true)
        await fulfillment(of: [suggested], timeout: 2)

        detector.setEnabled(false)
        XCTAssertEqual(microphone.stopped, 1)
        XCTAssertEqual(notifications.removed, [MicrophoneMeeting.requestID])
        microphone.send(true)
        XCTAssertEqual(notifications.posted.count, 1, "A stopped detector ignores the microphone")
    }

    func testOnlyTheStartActionRecordsAndTheBannerNeedsTheSetting() async throws {
        _ = NSApplication.shared
        let (defaults, suite, root) = try makeTempDefaults("MeetingDetection")
        defer { removeTempDefaults(defaults, suite: suite, root: root) }
        let model = AppModel(defaults: defaults)
        let delegate = AppDelegate()
        delegate.model = model // No menu appearance is required for notification handling.

        XCTAssertFalse(model.detectsMeetings, "Detection is off until it is switched on")
        XCTAssertFalse(delegate.shouldPresentMicrophoneMeeting())

        var starts = 0
        delegate.startMicrophoneRecording(action: UNNotificationDefaultActionIdentifier) { starts += 1 }
        delegate.startMicrophoneRecording(action: UNNotificationDismissActionIdentifier) { starts += 1 }
        XCTAssertEqual(starts, 0, "Opening or dismissing the notification must not record")
        delegate.startMicrophoneRecording(action: MicrophoneMeeting.startActionID) { starts += 1 }
        XCTAssertEqual(starts, 1)

        XCTAssertEqual(MicrophoneMeeting.category.actions.first?.identifier, MicrophoneMeeting.startActionID)
        XCTAssertTrue(MicrophoneMeeting.category.actions[0].options.contains(.foreground))
        XCTAssertTrue(MicrophoneMeeting.category.actions[0].options.contains(.authenticationRequired))

        model.detectsMeetings = true
        XCTAssertTrue(delegate.shouldPresentMicrophoneMeeting())
        XCTAssertTrue(AppModel(defaults: defaults).detectsMeetings, "The setting is remembered")
        model.recordingDidStart(at: Date())
        XCTAssertFalse(delegate.shouldPresentMicrophoneMeeting(), "A recording is already under way")
        model.detectsMeetings = false
    }
}
