import AVFoundation
import os
import ScreenCaptureKit

/// The two capture sources share the host clock. Keep separate audio tracks in a
/// fragmented movie, then mix them into audio.m4a through the usual processing path.
/// No video input is created. All writer access is serialized on the capture queue,
/// so samples are appended inline as they arrive.
final class AudioOnlyRecording: @unchecked Sendable {
    private struct QueuedSample {
        let buffer: CMSampleBuffer
        let bytes: Int
        let receivedAt: ContinuousClock.Instant
    }

    private struct Budget {
        var bytes = 0
        var buffers = 0
    }

    private let writer: AVAssetWriter
    private let inputs: [SCStreamOutputType: AVAssetWriterInput]
    private let queue: DispatchQueue
    private let budget = OSAllocatedUnfairLock(initialState: Budget())
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

    init(to url: URL, queue: DispatchQueue,
         isReady: @escaping @Sendable (AVAssetWriterInput) -> Bool = { $0.isReadyForMoreMediaData },
         onFailure: @escaping @Sendable (Error) -> Void) throws {
        self.queue = queue
        self.onFailure = onFailure
        self.isReady = isReady
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
            guard writer.canAdd(input) else { throw AudioExtractionError.cannotCreateExporter }
            writer.add(input)
            inputs[type] = input
        }
        self.inputs = inputs
        guard writer.startWriting() else { throw writer.error ?? AudioExtractionError.cannotCreateExporter }
    }

    func append(_ sample: CMSampleBuffer, type: SCStreamOutputType) {
        guard inputs[type] != nil else { return }
        let item = QueuedSample(buffer: sample,
            bytes: max(CMSampleBufferGetTotalSampleSize(sample), sample.numSamples * 8), receivedAt: .now)
        let reserved = budget.withLock { budget in
            guard budget.buffers < 512, item.bytes <= 8_388_608 - budget.bytes else { return false }
            budget.buffers += 1
            budget.bytes += item.bytes
            return true
        }
        dispatchPrecondition(condition: .onQueue(queue))
        enqueue(reserved ? item : nil, type: type)
    }

    /// A nil item is a sample that did not fit the budget.
    private func enqueue(_ item: QueuedSample?, type: SCStreamOutputType) {
        guard let item else { return recordFailure(BackpressureError()) }
        guard !finishing, !finished, failure == nil else { release(item); return }
        if !started {
            writer.startSession(atSourceTime: item.buffer.presentationTimeStamp)
            started = true
        }
        pending[type, default: []].append(item)
        drain()
    }

    /// Temporary encoder pressure is not a write failure. Keep original timestamps
    /// and retry without blocking the capture queue or silently dropping samples.
    private func drain() {
        guard !finished else { return }
        guard failure == nil else { if finishing { finalize() }; return }
        guard writer.status == .writing else {
            recordFailure(writer.error ?? WriteError())
            return
        }
        for (type, input) in inputs where !finishedInputs.contains(type) {
            // Drop the appended prefix once; removing each sample would shift the queue every time.
            let queued = pending[type]?.count ?? 0
            var appended = 0
            var error: Error?
            while appended < queued {
                let item = pending[type, default: []][appended]
                guard isReady(input) else {
                    if item.receivedAt.duration(to: .now) >= .seconds(2) { error = BackpressureError() }
                    break
                }
                guard input.append(item.buffer) else {
                    error = writer.error ?? WriteError()
                    break
                }
                appended += 1
                release(item)
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
            // Stopping before the first buffer is not a drive problem; finishing the inputs
            // of a writer with no session fails it, so its own error would mislead here.
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

    private func release(_ item: QueuedSample) {
        budget.withLock { budget in
            budget.bytes -= item.bytes
            budget.buffers -= 1
        }
    }

    private func discardPending() {
        for item in pending.values.flatMap({ $0 }) { release(item) }
        pending.removeAll()
    }

    private func recordFailure(_ error: Error) {
        guard !finished, failure == nil else { return }
        failure = error
        discardPending()
        onFailure(error)
        if finishing { finalize() }
    }

    func cancel() {
        queue.async { [self] in
            guard !finished else { return }
            finished = true
            discardPending()
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
