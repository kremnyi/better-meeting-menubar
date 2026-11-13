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
    private var ends: [SCStreamOutputType: CMTime] = [:]
    private var progressed: [SCStreamOutputType: ContinuousClock.Instant] = [:]
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
        // AAC packs a track's buffers back to back, so a source that drops out needs silence to keep its later audio in place.
        let start = sample.presentationTimeStamp
        if let end = ends[type], end.isNumeric, start - end > CMTime(value: 1, timescale: 20) {
            for silence in Self.silence(from: end, to: start, like: sample) {
                pending[type, default: []].append(QueuedSample(buffer: silence, receivedAt: .now))
            }
        }
        ends[type] = start + sample.duration
        pending[type, default: []].append(QueuedSample(buffer: sample, receivedAt: .now))
        drain()
    }

    /// Pieces of at most one second share one zeroed block, so a long gap does not allocate its full length.
    private static func silence(from start: CMTime, to end: CMTime, like sample: CMSampleBuffer) -> [CMSampleBuffer] {
        guard let format = sample.formatDescription, let description = format.audioStreamBasicDescription,
              description.mFormatID == kAudioFormatLinearPCM else { return [] }
        let rate = Int(description.mSampleRate)
        let buffers = description.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 ? Int(description.mChannelsPerFrame) : 1
        let frameBytes = Int(description.mBytesPerFrame) * buffers
        func zeros(_ frames: Int) -> CMBlockBuffer? {
            guard let block = try? CMBlockBuffer(length: frames * frameBytes, flags: .assureMemoryNow),
                  (try? block.fillDataBytes(with: 0)) != nil else { return nil }
            return block
        }
        guard rate > 0, frameBytes > 0, let second = zeros(rate) else { return [] }
        let total = Int(((end - start).seconds * Double(rate)).rounded())
        var pieces: [CMSampleBuffer] = []
        var done = 0
        while done < total {
            let frames = min(rate, total - done)
            guard let data = frames == rate ? second : zeros(frames),
                  let piece = try? CMSampleBuffer(
                      dataBuffer: data, formatDescription: format, numSamples: frames,
                      presentationTimeStamp: start + CMTime(value: CMTimeValue(done), timescale: CMTimeScale(rate)),
                      packetDescriptions: []) else { break }
            pieces.append(piece)
            done += frames
        }
        return pieces
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
                    // Silence for a long gap queues at once, so the limit counts from the track's last append, not the item's age.
                    if max(item.receivedAt, progressed[type] ?? item.receivedAt).duration(to: .now) >= stallLimit { error = BackpressureError() }
                    break
                }
                guard input.append(item.buffer) else {
                    error = writer.error ?? WriteError()
                    break
                }
                appended += 1
            }
            if appended > 0 {
                pending[type]?.removeFirst(appended)
                progressed[type] = .now
            }
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
