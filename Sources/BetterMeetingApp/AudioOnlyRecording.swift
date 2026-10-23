import AVFoundation
import ScreenCaptureKit

/// All writer access is serialized on the capture queue, so samples are appended inline as they arrive.
final class AudioOnlyRecording: @unchecked Sendable {
    private struct QueuedSample {
        let buffer: CMSampleBuffer
        let receivedAt: ContinuousClock.Instant
    }

    private let writer: AVAssetWriter
    private let inputs: [SCStreamOutputType: AVAssetWriterInput]
    private let queue: DispatchQueue
    private var pending: [SCStreamOutputType: [QueuedSample]] = [:]
    private var finishedInputs: Set<SCStreamOutputType> = []
    private var retryScheduled = false
    private var started = false
    private var finishing = false
    private var finished = false
    private var failure: Error?
    private var finishContinuation: CheckedContinuation<Void, Error>?
    private let onFailure: @Sendable (Error) -> Void
    private let isReady: @Sendable (AVAssetWriterInput) -> Bool
    private let stallLimit: Duration

    init(to url: URL, queue: DispatchQueue,
         isReady: @escaping @Sendable (AVAssetWriterInput) -> Bool = { $0.isReadyForMoreMediaData },
         stallLimit: Duration = .seconds(30),
         onFailure: @escaping @Sendable (Error) -> Void) throws {
        self.queue = queue
        self.onFailure = onFailure
        self.isReady = isReady
        self.stallLimit = stallLimit
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.movieFragmentInterval = CMTime(seconds: 5, preferredTimescale: 600)
        var inputs: [SCStreamOutputType: AVAssetWriterInput] = [:]
        for type: SCStreamOutputType in [.audio, .microphone] {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: type == .microphone ? 1 : 2,
                AVEncoderBitRateKey: 128_000
            ])
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw WriteError() }
            writer.add(input)
            inputs[type] = input
        }
        self.inputs = inputs
        guard writer.startWriting() else { throw writer.error ?? WriteError() }
    }

    func append(_ sample: CMSampleBuffer, type: SCStreamOutputType) {
        guard inputs[type] != nil else { return }
        dispatchPrecondition(condition: .onQueue(queue))
        guard !finishing, !finished, failure == nil else { return }
        if !started {
            writer.startSession(atSourceTime: sample.presentationTimeStamp)
            started = true
        }
        pending[type, default: []].append(QueuedSample(buffer: sample, receivedAt: .now))
        drain()
    }

    /// Encoder back-pressure is not a write failure: keep original timestamps and retry without blocking the queue or dropping samples.
    private func drain() {
        guard !finished else { return }
        guard failure == nil else { if finishing { finalize() }; return }
        guard writer.status == .writing else {
            recordFailure(writer.error ?? WriteError())
            return
        }
        for (type, input) in inputs where !finishedInputs.contains(type) {
            var appended = 0
            var error: Error?
            for item in pending[type] ?? [] {
                guard isReady(input) else {
                    if item.receivedAt.duration(to: .now) >= stallLimit { error = BackpressureError() }
                    break
                }
                guard input.append(item.buffer) else {
                    error = writer.error ?? WriteError()
                    break
                }
                appended += 1
            }
            if appended > 0 { pending[type]?.removeFirst(appended) }
            if let error {
                recordFailure(error)
                return
            }
            // An unused or exhausted track must not stall another track's tail.
            if finishing, pending[type]?.isEmpty != false {
                input.markAsFinished()
                finishedInputs.insert(type)
            }
        }
        if pending.values.allSatisfy(\.isEmpty) {
            if finishing { finalize() }
        } else if !retryScheduled {
            retryScheduled = true
            queue.asyncAfter(deadline: .now() + .milliseconds(10)) { [self] in
                retryScheduled = false
                drain()
            }
        }
    }

    func finish() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard !finishing, !finished else {
                    continuation.resume(throwing: failure ?? WriteError())
                    return
                }
                finishing = true
                finishContinuation = continuation
                drain()
            }
        }
    }

    private func finalize() {
        guard !finished else { return }
        finished = true
        guard started, writer.status == .writing else {
            // Finishing the inputs of a writer with no session fails it, so its own error would mislead here.
            let error = failure ?? (started ? writer.error ?? WriteError() : NoAudioError())
            writer.cancelWriting()
            completeFinish(.failure(error))
            return
        }
        for (type, input) in inputs where !finishedInputs.contains(type) { input.markAsFinished() }
        writer.finishWriting { [self] in
            queue.async { [self] in
                if let error = failure ?? writer.error {
                    completeFinish(.failure(error))
                } else if writer.status == .completed {
                    completeFinish(.success(()))
                } else {
                    completeFinish(.failure(WriteError()))
                }
            }
        }
    }

    private func completeFinish(_ result: Result<Void, Error>) {
        let continuation = finishContinuation
        finishContinuation = nil
        continuation?.resume(with: result)
    }

    private func recordFailure(_ error: Error) {
        guard !finished, failure == nil else { return }
        failure = error
        pending.removeAll()
        onFailure(error)
        if finishing { finalize() }
    }

    func cancel() {
        queue.async { [self] in
            guard !finished else { return }
            finished = true
            pending.removeAll()
            writer.cancelWriting()
            completeFinish(.failure(failure ?? CancellationError()))
        }
    }

    private struct BackpressureError: LocalizedError {
        var errorDescription: String? {
            "The audio encoder could not keep up with the recording. Close other busy apps or check the recording drive, then retry. Any saved audio remains in the meeting folder."
        }
    }

    private struct NoAudioError: LocalizedError {
        var errorDescription: String? {
            "No audio was captured before the recording stopped."
        }
    }

    private struct WriteError: LocalizedError {
        var errorDescription: String? {
            "Audio could not be saved. Check the recording drive and retry. Any saved audio remains in the meeting folder."
        }
    }
}
