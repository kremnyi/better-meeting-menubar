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

    /// Times are monotonic, so a wall-clock change cannot make a live source look stale.
    private struct Level: Sendable {
        let value: Double
        let time: ContinuousClock.Instant
    }

    var onUnexpectedStop: ((Error?) -> Void)?
    nonisolated var hasDetectedAudio: Bool { meter.withLock { $0.detected } }

    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private nonisolated let audioRecording = OSAllocatedUnfairLock<AudioOnlyRecording?>(initialState: nil)
    private var finalizingAudio = false
    private var microphone: AVCaptureDevice?
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var stopContinuation: CheckedContinuation<Void, Error>?
    private var startCaptureTask: Task<Void, Never>?
    /// Set while `start` awaits shareable content, before `stream` is assigned.
    private var starting = false
    /// Whether this stream's capture was already stopped, so clean-up does not stop it again.
    private var captureStopped = false
    // Audio buffers arrive on their own queue so the main thread isn't woken for each one;
    // the recording timer reads the latest levels from here.
    private nonisolated let meter = OSAllocatedUnfairLock(initialState: MeterState())
    private nonisolated let audioQueue = DispatchQueue(label: "com.kremnyi.bettermeeting.audio-levels", qos: .userInitiated)

    nonisolated func audioLevel(microphone: Bool) -> Double {
        let type: SCStreamOutputType = microphone ? .microphone : .audio
        guard let level = meter.withLock({ $0.levels[type] }),
              level.time.duration(to: .now) < .milliseconds(500) else { return 0 }
        return level.value
    }

    func audioHealth(at time: ContinuousClock.Instant = .now) -> RecordingAudioHealth {
        let health = meter.withLock { state in
            RecordingAudioHealth(
                microphoneMissing: state.levels[.microphone].map { $0.time.duration(to: time) >= .seconds(10) } ?? true,
                systemMissing: state.levels[.audio].map { $0.time.duration(to: time) >= .seconds(10) } ?? true
            )
        }
        return RecordingAudioHealth(
            microphoneMissing: health.microphoneMissing || microphone?.isConnected == false,
            systemMissing: health.systemMissing
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

        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )
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
        let excludedApps = content.applications.filter { $0.bundleIdentifier == ownBundleID }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: excludedApps,
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
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        let streamID = ObjectIdentifier(stream)
        meter.withLock { $0.stream = streamID }
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: audioQueue)
        if mode == .screen {
            let outputConfiguration = SCRecordingOutputConfiguration()
            outputConfiguration.outputURL = outputURL
            outputConfiguration.outputFileType = .mp4
            // HEVC is about half the size of H.264 at the same quality; H.264 stays the fallback.
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
        finalizingAudio = false
        captureStopped = false

        try await withCheckedThrowingContinuation { continuation in
            startContinuation = continuation
            startCaptureTask = Task {
                do {
                    try await stream.startCapture()
                    if mode == .audioOnly { finishStart(with: .success(())) }
                } catch {
                    finishStart(with: .failure(error))
                }
            }
        }
    }

    static func videoConfiguration(
        sourceSize: CGSize, resolution: CaptureResolution, quality: CaptureQuality
    ) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        let scale = min(1, CGFloat(resolution.rawValue) / max(sourceSize.width, sourceSize.height))
        // HEVC and H.264 need even dimensions; keep the aspect ratio without upscaling.
        configuration.width = max(2, Int(sourceSize.width * scale) / 2 * 2)
        configuration.height = max(2, Int(sourceSize.height * scale) / 2 * 2)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: Int32(quality.rawValue))
        configuration.captureResolution = .best
        return configuration
    }

    func stop() async throws {
        // A second stop while one is pending would overwrite, and leak, the first continuation.
        guard let stream, stopContinuation == nil else { throw RecorderError.notRecording }

        try await withCheckedThrowingContinuation { continuation in
            stopContinuation = continuation
            Task {
                do {
                    captureStopped = true
                    try await stream.stopCapture()
                    if audioRecording.withLock({ $0 != nil }) { finalizeAudio(error: nil) }
                } catch {
                    // Clean-up may still need to stop a capture that failed to stop here.
                    if stream === self.stream { captureStopped = false }
                    finishStop(with: .failure(error))
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
        // Both audio outputs are delivered on audioQueue; each level is measured at most every 0.1 s.
        guard type == .audio || type == .microphone else { return }
        let streamID = ObjectIdentifier(stream)
        let now = ContinuousClock.now
        guard meter.withLock({ $0.stream == streamID }),
              sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer),
              let description = sampleBuffer.formatDescription else { return }
        audioRecording.withLock { $0 }?.append(sampleBuffer, type: type)
        guard meter.withLock({ state in
            state.levels[type].map { $0.time.duration(to: now) >= .milliseconds(100) } ?? true
        }) else { return }
        let frames = sampleBuffer.numSamples
        guard frames > 0, let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              // Measures the samples in place; nothing is copied just for the meter.
              let level = try? sampleBuffer.withAudioBufferList(body: { buffers, _ in
                  Self.meterLevel(buffers, format: format, frames: frames)
              }) else { return }
        recordLevel(level, type: type, at: now)
    }

    nonisolated func updateAudioLevel(_ buffer: AVAudioPCMBuffer, type: SCStreamOutputType, at time: ContinuousClock.Instant) {
        recordLevel(Self.meterLevel(buffer), type: type, at: time)
    }

    private nonisolated func recordLevel(_ level: Double, type: SCStreamOutputType, at time: ContinuousClock.Instant) {
        meter.withLock { state in
            state.levels[type] = Level(value: level, time: time)
            state.detected = state.detected || level > 0
        }
    }

    nonisolated static func meterLevel(_ buffer: AVAudioPCMBuffer) -> Double {
        meterLevel(UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList),
                   format: buffer.format.streamDescription.pointee, frames: Int(buffer.frameLength))
    }

    /// The loudest channel's RMS on a -60…0 dB scale. Interleaved channels share one buffer
    /// with a stride of the channel count; non-interleaved channels each have their own.
    nonisolated static func meterLevel(
        _ buffers: UnsafeMutableAudioBufferListPointer, format: AudioStreamBasicDescription, frames: Int
    ) -> Double {
        let channels = Int(format.mChannelsPerFrame)
        let bytes = Int(format.mBitsPerChannel) / 8
        let flags = format.mFormatFlags
        let isFloat = flags & kAudioFormatFlagIsFloat != 0
        let isInteger = flags & kAudioFormatFlagIsSignedInteger != 0
        guard frames > 0, channels > 0, format.mFormatID == kAudioFormatLinearPCM,
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
            guard recordingOutput === self.recordingOutput else { return }
            if stopContinuation != nil {
                finishStop(with: .success(()))
            } else {
                finishUnexpectedStop(with: nil)
            }
        }
    }

    nonisolated func recordingOutput(
        _ recordingOutput: SCRecordingOutput,
        didFailWithError error: any Error
    ) {
        Task { @MainActor in
            guard recordingOutput === self.recordingOutput else { return }
            finish(failing: error)
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
            // Our own stop waits for the recording-output callback. A stop from the macOS
            // screen-sharing menu may never deliver it, so hand the recording off now;
            // processing waits until the MP4 is readable.
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

    /// Fails whichever of start or stop is waiting, or reports the capture ending on its own.
    private func finish(failing error: Error) {
        if startContinuation != nil {
            finishStart(with: .failure(error))
        } else if audioRecording.withLock({ $0 != nil }) {
            finalizeAudio(error: error)
        } else if stopContinuation != nil {
            finishStop(with: .failure(error))
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
                try? await stream.stopCapture()
            }
            // The capture queue can still hold its last buffers when capture ends.
            await withCheckedContinuation { continuation in
                audioQueue.async { continuation.resume() }
            }
            var failure = error
            do { try await recording.finish() } catch { failure = failure ?? error }
            if stopContinuation != nil {
                finishStop(with: failure.map { .failure($0) } ?? .success(()))
            } else {
                finishUnexpectedStop(with: failure)
            }
        }
    }

    private func finishStart(with result: Result<Void, Error>) {
        guard let continuation = startContinuation else { return }
        startContinuation = nil
        if case .failure = result {
            cleanUp()
        }
        continuation.resume(with: result)
    }

    private func finishStop(with result: Result<Void, Error>) {
        guard let continuation = stopContinuation else { return }
        stopContinuation = nil
        cleanUp()
        continuation.resume(with: result)
    }

    private func finishUnexpectedStop(with error: Error?) {
        guard stream != nil else { return }
        cleanUp()
        onUnexpectedStop?(error)
    }

    private func cleanUp() {
        // Our own stop, or the stream reporting its end, already stopped this capture.
        let previousStream = captureStopped ? nil : stream
        captureStopped = false
        stream = nil
        recordingOutput = nil
        microphone = nil
        let recording = audioRecording.withLock { recording -> AudioOnlyRecording? in
            defer { recording = nil }
            return recording
        }
        recording?.cancel()
        meter.withLock { state in
            state.stream = nil
            state.levels.removeAll()
        }
        // ponytail: settle the start task first so stopCapture never overlaps a
        // still-in-flight startCapture when an early delegate failure triggers cleanUp.
        let startTask = startCaptureTask
        startCaptureTask = nil
        Task {
            _ = await startTask?.value
            try? await previousStream?.stopCapture()
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

    // ponytail: use frame rate presets; custom bitrate needs a different recording pipeline.
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
        }
    }
}
