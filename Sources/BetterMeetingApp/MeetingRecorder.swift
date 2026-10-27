import AVFoundation
import Accelerate
import CoreGraphics
import CoreMedia
import Foundation
import os
import ScreenCaptureKit

enum CaptureMode {
    case screen, audioOnly
    var filename: String { self == .screen ? "recording.mp4" : "recording.mov" }
}

struct RecordingAudioHealth {
    let microphoneMissing: Bool
    let systemMissing: Bool
    var warning: String? {
        switch (microphoneMissing, systemMissing) {
        case (true, true): "Audio sources stopped sending data"
        case (true, false): "Microphone stopped sending audio"
        case (false, true): "System audio stopped sending data"
        case (false, false): nil
        }
    }
}

@MainActor
final class MeetingRecorder: NSObject, SCRecordingOutputDelegate, SCStreamDelegate, SCStreamOutput {
    private struct MeterState: Sendable {
        var stream: ObjectIdentifier?
        var levels: [SCStreamOutputType: Level] = [:]
        var detected = false
    }

    private struct Level: Sendable {
        let value: Double
        let time: ContinuousClock.Instant
    }

    var onUnexpectedStop: ((Error?) -> Void)?
    nonisolated var hasDetectedAudio: Bool { meter.withLock { $0.detected } }

    private var stream: SCStream?
    private(set) var recordingOutput: SCRecordingOutput?
    private nonisolated let audioRecording = OSAllocatedUnfairLock<AudioOnlyRecording?>(initialState: nil)
    private var finalizingAudio = false
    private var microphone: AVCaptureDevice?
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var stopContinuation: CheckedContinuation<Task<Void, Error>, Error>?
    private var startCaptureTask: Task<Void, Never>?
    private var startTimeoutTask: Task<Void, Never>?
    // Screen recordings whose capture has stopped while ScreenCaptureKit still finishes the file.
    private var savingFiles: [ObjectIdentifier: (output: SCRecordingOutput, done: AsyncThrowingStream<Void, Error>.Continuation)] = [:]
    private var starting = false
    private var captureStopped = false
    private var recordingStarted: ContinuousClock.Instant?
    // A call with no keyboard or mouse input must not let the Mac idle-sleep mid-recording.
    private var sleepActivity: NSObjectProtocol?
    var startCapture: (SCStream) async throws -> Void = { try await $0.startCapture() }
    var stopCapture: (SCStream) async throws -> Void = { try await $0.stopCapture() }
    // ScreenCaptureKit normally reports a recording output within a second. A minute is far beyond that, so only a callback
    // that will never come ends the wait.
    var callbackTimeout: Duration = .seconds(60)
    // ScreenCaptureKit finishes the MP4 only after capture stops, and the time grows with its length: a 23-minute recording
    // took 82 seconds. The file wait adds a quarter of the recorded time to callbackTimeout.
    private var stopTimeout: Duration {
        callbackTimeout + (recordingStarted.map { $0.duration(to: .now) } ?? .zero) / 4
    }
    // Audio buffers stay on audioQueue so the main thread is not woken for each one.
    private nonisolated let meter = OSAllocatedUnfairLock(initialState: MeterState())
    nonisolated let audioQueue = DispatchQueue(label: "com.kremnyi.bettermeeting.audio-levels", qos: .userInitiated)

    nonisolated func audioLevel(microphone: Bool) -> Double {
        let type: SCStreamOutputType = microphone ? .microphone : .audio
        guard let level = meter.withLock({ $0.levels[type] }),
              level.time.duration(to: .now) < .milliseconds(500) else { return 0 }
        return level.value
    }

    func audioHealth(at time: ContinuousClock.Instant = .now) -> RecordingAudioHealth {
        let levels = meter.withLock { $0.levels }
        let missing = { (type: SCStreamOutputType) in
            levels[type].map { $0.time.duration(to: time) >= .seconds(10) } ?? true
        }
        return RecordingAudioHealth(
            microphoneMissing: missing(.microphone) || microphone?.isConnected == false,
            systemMissing: missing(.audio)
        )
    }

    func requestPermissions() async throws {
        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            throw RecorderError.screenPermissionDenied
        }

        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            throw RecorderError.microphonePermissionDenied
        }
    }

    func start(
        to outputURL: URL, displayID: CGDirectDisplayID, microphoneID: String,
        resolution: CaptureResolution, quality: CaptureQuality, mode: CaptureMode = .screen
    ) async throws {
        // Overlapping starts would both pass a check on `stream` alone, which is set only after the awaits below.
        guard stream == nil, !starting, startContinuation == nil, startCaptureTask == nil else {
            throw RecorderError.alreadyRecording
        }
        starting = true
        defer { starting = false }
        meter.withLock { $0 = MeterState() }
        guard CGPreflightScreenCaptureAccess() else { throw RecorderError.screenPermissionDenied }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw RecorderError.microphonePermissionDenied
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let captureDisplayID = mode == .audioOnly || displayID == 0 ? CGMainDisplayID() : displayID
        guard let display = content.displays.first(where: { $0.displayID == captureDisplayID }) else {
            throw RecorderError.noDisplay
        }
        let microphone = microphoneID.isEmpty
            ? AVCaptureDevice.default(for: .audio)
            : AVCaptureDevice(uniqueID: microphoneID)
        guard let microphone, microphone.hasMediaType(.audio), microphone.isConnected else {
            throw RecorderError.noMicrophone
        }

        let ownBundleID = Bundle.main.bundleIdentifier
        let filter = SCContentFilter(
            display: display,
            excludingApplications: content.applications.filter { $0.bundleIdentifier == ownBundleID },
            exceptingWindows: []
        )

        let configuration = Self.videoConfiguration(
            sourceSize: CGSize(
                width: filter.contentRect.width * CGFloat(filter.pointPixelScale),
                height: filter.contentRect.height * CGFloat(filter.pointPixelScale)
            ),
            resolution: resolution, quality: quality
        )
        configuration.queueDepth = 3
        configuration.showsCursor = false
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.captureMicrophone = true
        configuration.microphoneCaptureDeviceID = microphone.uniqueID

        if mode == .audioOnly {
            configuration.width = 2
            configuration.height = 2
            configuration.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 1)
        }
        try await begin(SCStream(filter: filter, configuration: configuration, delegate: self),
                        to: outputURL, microphone: microphone, mode: mode)
    }

    func begin(_ stream: SCStream, to outputURL: URL, microphone: AVCaptureDevice?, mode: CaptureMode) async throws {
        let streamID = ObjectIdentifier(stream)
        meter.withLock { $0.stream = streamID }
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: audioQueue)
        if mode == .screen {
            let outputConfiguration = SCRecordingOutputConfiguration()
            outputConfiguration.outputURL = outputURL
            outputConfiguration.outputFileType = .mp4
            outputConfiguration.videoCodecType = outputConfiguration.availableVideoCodecTypes.contains(.hevc)
                ? .hevc : .h264
            let output = SCRecordingOutput(configuration: outputConfiguration, delegate: self)
            try stream.addRecordingOutput(output)
            recordingOutput = output
        } else {
            let recording = try AudioOnlyRecording(to: outputURL, queue: audioQueue) { [weak self] error in
                Task { @MainActor [weak self] in
                    guard self?.stream.map(ObjectIdentifier.init) == streamID else { return }
                    self?.finish(failing: error)
                }
            }
            audioRecording.withLock { $0 = recording }
        }

        self.stream = stream
        self.microphone = microphone
        if sleepActivity == nil {
            sleepActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled], reason: "Recording a meeting")
        }
        finalizingAudio = false
        captureStopped = false

        try await withCheckedThrowingContinuation { continuation in
            startContinuation = continuation
            // A screen recording starts only when its output reports in; without that report the start would wait forever.
            startTimeoutTask = Task {
                try? await Task.sleep(for: callbackTimeout)
                guard !Task.isCancelled else { return }
                finishStart(with: .failure(RecorderError.startTimedOut))
            }
            startCaptureTask = Task {
                do {
                    try await startCapture(stream)
                    // A start that timed out can finish late; its result must not settle a later session.
                    if mode == .audioOnly, self.stream === stream { finishStart(with: .success(())) }
                } catch {
                    if self.stream === stream { finishStart(with: .failure(error)) }
                }
            }
        }
    }

    static func videoConfiguration(
        sourceSize: CGSize, resolution: CaptureResolution, quality: CaptureQuality
    ) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        let scale = min(1, CGFloat(resolution.rawValue) / max(sourceSize.width, sourceSize.height))
        // HEVC and H.264 need even dimensions.
        configuration.width = max(2, Int(sourceSize.width * scale) / 2 * 2)
        configuration.height = max(2, Int(sourceSize.height * scale) / 2 * 2)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: Int32(quality.rawValue))
        configuration.captureResolution = .best
        return configuration
    }

    /// Returns once capture stops and the next recording can start. The returned task ends when the file is complete.
    func stop() async throws -> Task<Void, Error> {
        // A second stop while one is pending would overwrite, and leak, the first continuation.
        guard let stream, stopContinuation == nil else { throw RecorderError.notRecording }

        return try await withCheckedThrowingContinuation { continuation in
            stopContinuation = continuation
            Task {
                do {
                    captureStopped = true
                    try await stopCapture(stream)
                    if audioRecording.withLock({ $0 != nil }) {
                        finalizeAudio(error: nil)
                    } else if stopContinuation != nil, stream === self.stream, let output = recordingOutput {
                        // The stream is already stopped, so the next recording can start while ScreenCaptureKit finishes
                        // this file. A missing finish callback fails only the file wait; the recording stays in its folder.
                        finishStop(with: .success(()), file: savingFile(of: output))
                    }
                } catch {
                    // Clean-up may still need to stop a capture that failed to stop here.
                    if stream === self.stream { captureStopped = false }
                    // Cancelling the audio writer would delete the file; finishing it keeps what was recorded.
                    if audioRecording.withLock({ $0 != nil }) {
                        finalizeAudio(error: error)
                    } else {
                        finishStop(with: .failure(error))
                    }
                }
            }
        }
    }

    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in
            guard recordingOutput === self.recordingOutput else { return }
            finishStart(with: .success(()))
        }
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio || type == .microphone else { return }
        let streamID = ObjectIdentifier(stream)
        let now = ContinuousClock.now
        guard meter.withLock({ $0.stream == streamID }),
              sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer),
              sampleBuffer.formatDescription != nil else { return }
        audioRecording.withLock { $0 }?.append(sampleBuffer, type: type)
        guard meter.withLock({ state in
            state.levels[type].map { $0.time.duration(to: now) >= .milliseconds(100) } ?? true
        }) else { return }
        guard let level = Self.meterLevel(sampleBuffer) else { return }
        recordLevel(level, type: type, at: now)
    }

    nonisolated func recordLevel(_ level: Double, type: SCStreamOutputType, at time: ContinuousClock.Instant) {
        meter.withLock { state in
            state.levels[type] = Level(value: level, time: time)
            state.detected = state.detected || level > 0
        }
    }

    nonisolated static func meterLevel(_ sampleBuffer: CMSampleBuffer) -> Double? {
        let frames = sampleBuffer.numSamples
        guard frames > 0, let description = sampleBuffer.formatDescription,
              let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else { return nil }
        return try? sampleBuffer.withAudioBufferList(body: { buffers, _ in
            meterLevel(buffers, format: format, frames: frames)
        })
    }

    /// Interleaved channels share one buffer with a channel-count stride; non-interleaved channels each have their own.
    nonisolated static func meterLevel(
        _ buffers: UnsafeMutableAudioBufferListPointer, format: AudioStreamBasicDescription, frames: Int
    ) -> Double {
        let channels = Int(format.mChannelsPerFrame)
        let bytes = Int(format.mBitsPerChannel) / 8
        let flags = format.mFormatFlags
        let isFloat = flags & kAudioFormatFlagIsFloat != 0
        let isInteger = flags & kAudioFormatFlagIsSignedInteger != 0
        guard channels > 0, format.mFormatID == kAudioFormatLinearPCM,
              isFloat ? bytes == 4 : isInteger && (bytes == 2 || bytes == 4) else { return 0 }
        let nonInterleaved = flags & kAudioFormatFlagIsNonInterleaved != 0
        let stride = nonInterleaved ? 1 : channels
        var peakRMS: Float = 0
        var samples: [Float] = []
        for channel in 0..<channels {
            let index = nonInterleaved ? channel : 0
            guard index < buffers.count, let data = buffers[index].mData else { return 0 }
            let count = min(frames, Int(buffers[index].mDataByteSize) / (bytes * stride))
            guard count > 0 else { continue }
            let offset = nonInterleaved ? 0 : channel
            let length = vDSP_Length(count)
            var rms: Float = 0
            if isFloat {
                vDSP_rmsqv(data.assumingMemoryBound(to: Float.self) + offset, vDSP_Stride(stride), &rms, length)
            } else {
                if samples.count < count { samples = [Float](repeating: 0, count: count) }
                let scale: Float
                if bytes == 2 {
                    vDSP_vflt16(data.assumingMemoryBound(to: Int16.self) + offset, vDSP_Stride(stride), &samples, 1, length)
                    scale = 32768
                } else {
                    vDSP_vflt32(data.assumingMemoryBound(to: Int32.self) + offset, vDSP_Stride(stride), &samples, 1, length)
                    scale = 2147483648
                }
                vDSP_rmsqv(samples, 1, &rms, length)
                rms /= scale
            }
            peakRMS = max(peakRMS, rms)
        }
        guard peakRMS.isFinite, peakRMS > 0 else { return 0 }
        return min(1, max(0, (20 * log10(Double(peakRMS)) + 60) / 60))
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in
            if recordingOutput === self.recordingOutput {
                settleStop(with: nil)
            } else {
                settleFile(of: recordingOutput, with: nil)
            }
        }
    }

    nonisolated func recordingOutput(
        _ recordingOutput: SCRecordingOutput,
        didFailWithError error: any Error
    ) {
        Task { @MainActor in
            if recordingOutput === self.recordingOutput {
                finish(failing: error)
            } else {
                settleFile(of: recordingOutput, with: error)
            }
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        Task { @MainActor in
            guard stream === self.stream else { return }
            captureStopped = true
            let nsError = error as NSError
            let code = SCStreamError.Code(rawValue: nsError.code)
            let wasStoppedIntentionally = nsError.domain == SCStreamErrorDomain
                && (code == .userStopped || code == .systemStoppedStream)
            // A stop from the macOS screen-sharing menu may never deliver the recording-output callback, so hand the recording off now.
            if wasStoppedIntentionally, startContinuation == nil {
                if stopContinuation == nil {
                    if audioRecording.withLock({ $0 != nil }) {
                        finalizeAudio(error: nil)
                    } else {
                        finishUnexpectedStop(with: nil)
                    }
                }
                return
            }
            finish(failing: error)
        }
    }

    private func finish(failing error: Error) {
        if startContinuation != nil {
            finishStart(with: .failure(error))
        } else if audioRecording.withLock({ $0 != nil }) {
            finalizeAudio(error: error)
        } else {
            settleStop(with: error)
        }
    }

    private func settleStop(with error: Error?) {
        if stopContinuation != nil {
            finishStop(with: error.map { .failure($0) } ?? .success(()))
        } else {
            finishUnexpectedStop(with: error)
        }
    }

    private func finalizeAudio(error: Error?) {
        guard !finalizingAudio, let recording = audioRecording.withLock({ $0 }) else { return }
        finalizingAudio = true
        Task {
            if error != nil, !captureStopped, let stream {
                captureStopped = true
                try? await stopCapture(stream)
            }
            // The capture queue can still hold its last buffers when capture ends. A writer or queue that never
            // answers must not hold the stop forever.
            let outcome = OSAllocatedUnfairLock<Result<Void, Error>?>(initialState: nil)
            let finishTask = Task { [audioQueue] in
                await withCheckedContinuation { continuation in
                    audioQueue.async { continuation.resume() }
                }
                let result: Result<Void, Error>
                do { try await recording.finish(); result = .success(()) } catch { result = .failure(error) }
                outcome.withLock { $0 = result }
            }
            await Self.wait(for: finishTask, atMost: stopTimeout)
            var failure = error
            switch outcome.withLock({ $0 }) {
            case .success: break
            case .failure(let writeError): failure = failure ?? writeError
            case nil:
                failure = failure ?? RecorderError.stopTimedOut
                // cleanUp would cancel the writer and delete the file; the late finish keeps what was recorded.
                audioRecording.withLock { $0 = nil }
            }
            settleStop(with: failure)
        }
    }

    private func finishStart(with result: Result<Void, Error>) {
        guard let continuation = startContinuation else { return }
        startContinuation = nil
        startTimeoutTask?.cancel()
        startTimeoutTask = nil
        switch result {
        case .success: recordingStarted = .now
        case .failure: cleanUp()
        }
        continuation.resume(with: result)
    }

    private func finishStop(with result: Result<Void, Error>, file: Task<Void, Error> = Task {}) {
        guard let continuation = stopContinuation else { return }
        stopContinuation = nil
        cleanUp()
        continuation.resume(with: result.map { file })
    }

    private func savingFile(of output: SCRecordingOutput) -> Task<Void, Error> {
        let (finished, done) = AsyncThrowingStream<Void, Error>.makeStream()
        savingFiles[ObjectIdentifier(output)] = (output, done)
        let limit = stopTimeout
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: limit)
            guard !Task.isCancelled else { return }
            self?.settleFile(of: output, with: RecorderError.stopTimedOut)
        }
        return Task {
            defer { timeout.cancel() }
            for try await _ in finished {}
        }
    }

    private func settleFile(of output: SCRecordingOutput, with error: Error?) {
        savingFiles.removeValue(forKey: ObjectIdentifier(output))?.done.finish(throwing: error)
    }

    private func finishUnexpectedStop(with error: Error?) {
        guard stream != nil else { return }
        cleanUp()
        onUnexpectedStop?(error)
    }

    private func cleanUp() {
        let previousStream = captureStopped ? nil : stream
        captureStopped = false
        recordingStarted = nil
        startTimeoutTask?.cancel()
        startTimeoutTask = nil
        stream = nil
        recordingOutput = nil
        microphone = nil
        if let sleepActivity {
            ProcessInfo.processInfo.endActivity(sleepActivity)
            self.sleepActivity = nil
        }
        audioRecording.withLock { $0.take() }?.cancel()
        meter.withLock { state in
            state.stream = nil
            state.levels.removeAll()
        }
        // Settle the start task first so stopCapture never overlaps a
        // still-in-flight startCapture when an early delegate failure triggers cleanUp.
        // A startCapture that never returns must not keep the stream running, so the wait is bounded.
        let startTask = startCaptureTask
        startCaptureTask = nil
        let stopCapture = stopCapture
        let limit = callbackTimeout
        Task {
            if let startTask { await Self.wait(for: startTask, atMost: limit) }
            if let previousStream { try? await stopCapture(previousStream) }
        }
    }

    private static func wait(for task: Task<Void, Never>, atMost limit: Duration) async {
        let resumed = OSAllocatedUnfairLock(initialState: false)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resume = {
                if resumed.withLock({ wasResumed in defer { wasResumed = true }; return !wasResumed }) { continuation.resume() }
            }
            let timer = Task { try? await Task.sleep(for: limit); resume() }
            Task { await task.value; timer.cancel(); resume() }
        }
    }
}

enum CaptureResolution: Int, CaseIterable {
    case pixels1280 = 1280
    case pixels1440 = 1440
    case pixels1920 = 1920
    case pixels2560 = 2560

    var label: String { "\(rawValue) px" }
}

enum CaptureQuality: Int, CaseIterable {
    case compact = 5
    case standard = 10
    case smooth = 30

    // shortcut: use frame rate presets; custom bitrate needs a different recording pipeline.
    var label: String {
        switch self {
        case .compact: "Compact · 5 fps"
        case .standard: "Standard · 10 fps"
        case .smooth: "Smooth · 30 fps"
        }
    }
}

enum RecorderError: LocalizedError {
    case alreadyRecording
    case notRecording
    case screenPermissionDenied
    case microphonePermissionDenied
    case noDisplay
    case noMicrophone
    case startTimedOut
    case stopTimedOut

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            "A meeting is already being recorded."
        case .notRecording:
            "There is no active recording to stop."
        case .screenPermissionDenied:
            "Enable screen access for Better Meeting in System Settings, then restart the app."
        case .microphonePermissionDenied:
            "Enable Better Meeting in System Settings → Privacy & Security → Microphone, then try again."
        case .noDisplay:
            "The selected display is unavailable. Choose a connected display in Options."
        case .noMicrophone:
            "The selected microphone is unavailable. Choose a connected microphone in Options."
        case .startTimedOut:
            "The recording did not start. Try again."
        case .stopTimedOut:
            "The recording did not finish saving in time. Check the meeting folder for the file."
        }
    }
}
