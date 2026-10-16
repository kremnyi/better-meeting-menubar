import CoreAudio
import Foundation
import UserNotifications

enum MicrophoneMeeting {
    static let categoryID = "microphone-meeting"
    static let startActionID = "start-microphone-recording"
    static let requestID = "microphone-meeting"

    static var category: UNNotificationCategory {
        UNNotificationCategory(identifier: categoryID, actions: [
            UNNotificationAction(identifier: startActionID, title: "Start recording", options: [.foreground, .authenticationRequired])
        ], intentIdentifiers: [])
    }

    static var request: UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "A call seems to be running"
        content.body = "Another app has been using the microphone. Record it?"
        content.categoryIdentifier = categoryID
        content.sound = .default
        return UNNotificationRequest(identifier: requestID, content: content, trigger: nil)
    }
}

@MainActor
protocol MicrophoneUse: AnyObject {
    func start(_ onChange: @escaping (Bool) -> Void)
    func stop()
}

/// Core Audio says only whether a device is recording somewhere, so this needs no microphone access.
@MainActor
final class SystemMicrophoneUse: MicrophoneUse {
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var defaultDeviceListener: AudioObjectPropertyListenerBlock?
    private var report: ((Bool) -> Void)?

    func start(_ onChange: @escaping (Bool) -> Void) {
        guard report == nil else { return }
        report = onChange
        // Registered on the main queue, so the block already runs on the main actor.
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.followDefaultDevice() }
        }
        defaultDeviceListener = listener
        var address = Self.address(kAudioHardwarePropertyDefaultInputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        followDefaultDevice()
    }

    func stop() {
        leaveDevice()
        if let defaultDeviceListener {
            var address = Self.address(kAudioHardwarePropertyDefaultInputDevice)
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, .main, defaultDeviceListener
            )
        }
        defaultDeviceListener = nil
        report = nil
    }

    private func followDefaultDevice() {
        guard report != nil else { return }
        leaveDevice()
        device = Self.defaultInputDevice()
        guard device != AudioObjectID(kAudioObjectUnknown) else { return report?(false) ?? () }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.publish() }
        }
        deviceListener = listener
        var address = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        AudioObjectAddPropertyListenerBlock(device, &address, .main, listener)
        publish()
    }

    private func leaveDevice() {
        guard let deviceListener, device != AudioObjectID(kAudioObjectUnknown) else { return }
        var address = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        AudioObjectRemovePropertyListenerBlock(device, &address, .main, deviceListener)
        self.deviceListener = nil
        device = AudioObjectID(kAudioObjectUnknown)
    }

    private func publish() {
        report?(Self.isRecording(device))
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
    }

    static func defaultInputDevice() -> AudioObjectID {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = address(kAudioHardwarePropertyDefaultInputDevice)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        )
        return status == noErr ? device : AudioObjectID(kAudioObjectUnknown)
    }

    static func isRecording(_ device: AudioObjectID) -> Bool {
        var running = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running)
        return status == noErr && running != 0
    }
}

@MainActor
final class MeetingDetector {
    var delay: TimeInterval = 30
    /// Core Audio reports only changes, so a call that starts while the app is busy is re-checked at this interval.
    var busyRecheckInterval: TimeInterval = 5
    private(set) var enabled = false
    private let source: MicrophoneUse
    private let isBusy: () -> Bool
    private let post: (UNNotificationRequest) async -> Void
    private let remove: (String) -> Void
    private var waiting: Task<Void, Never>?
    private var suggested = false

    init(
        source: MicrophoneUse? = nil,
        isBusy: @escaping () -> Bool,
        post: @escaping (UNNotificationRequest) async -> Void = { await MeetingNotifications.post($0) },
        remove: @escaping (String) -> Void = MeetingNotifications.remove
    ) {
        self.source = source ?? SystemMicrophoneUse()
        self.isBusy = isBusy
        self.post = post
        self.remove = remove
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != self.enabled else { return }
        self.enabled = enabled
        guard enabled else { return withdraw(stopping: true) }
        Task { await MeetingNotifications.requestPermission() }
        source.start { [weak self] inUse in self?.microphoneUse(inUse) }
    }

    func microphoneUse(_ inUse: Bool) {
        guard enabled else { return }
        guard inUse else { return withdraw(stopping: false) }
        guard waiting == nil, !suggested else { return }
        waiting = Task { [delay, busyRecheckInterval] in
            try? await Task.sleep(for: .seconds(delay))
            // Our own recording and a pending transcription also hold the microphone; wait them out.
            while !Task.isCancelled, isBusy() {
                try? await Task.sleep(for: .seconds(busyRecheckInterval))
            }
            guard !Task.isCancelled else { return }
            waiting = nil
            await suggest()
        }
    }

    /// Marked as suggested so the call is not offered again when the user's own recording ends mid-call.
    func ownRecordingStarted() {
        guard enabled else { return }
        waiting?.cancel()
        waiting = nil
        if suggested { remove(MicrophoneMeeting.requestID) }
        suggested = true
    }

    private func suggest() async {
        guard enabled, !isBusy() else { return }
        suggested = true
        await post(MicrophoneMeeting.request)
    }

    private func withdraw(stopping: Bool) {
        waiting?.cancel()
        waiting = nil
        if suggested { remove(MicrophoneMeeting.requestID) }
        suggested = false
        if stopping { source.stop() }
    }
}
