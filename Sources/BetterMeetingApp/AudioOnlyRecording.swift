import AVFoundation
import ScreenCaptureKit

/// The two capture sources share the host clock. Keep separate audio tracks in a
/// fragmented movie, then mix them into audio.m4a through the usual processing path.
/// No video input is created. All writer access is serialized on this queue.
final class AudioOnlyRecording: @unchecked Sendable {
    private let writer: AVAssetWriter
    private let inputs: [SCStreamOutputType: AVAssetWriterInput]
    private let queue = DispatchQueue(label: "com.kremnyi.bettermeeting.audio-recording", qos: .userInitiated)
    private var started = false
    private var finished = false
    private var failure: Error?
    private let onFailure: @Sendable (Error) -> Void

    init(to url: URL, onFailure: @escaping @Sendable (Error) -> Void) throws {
        self.onFailure = onFailure
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
        queue.async { [self] in
            guard !finished, failure == nil, let input = inputs[type] else { return }
            if !started {
                writer.startSession(atSourceTime: sample.presentationTimeStamp)
                started = true
            }
            guard input.isReadyForMoreMediaData, input.append(sample) else {
                let error = writer.error ?? WriteError()
                failure = error
                onFailure(error)
                return
            }
        }
    }

    func finish() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard !finished else {
                    continuation.resume(throwing: failure ?? WriteError())
                    return
                }
                finished = true
                guard started, writer.status == .writing else {
                    writer.cancelWriting()
                    continuation.resume(throwing: failure ?? writer.error ?? WriteError())
                    return
                }
                inputs.values.forEach { $0.markAsFinished() }
                writer.finishWriting { [self] in
                    if let error = failure ?? writer.error {
                        continuation.resume(throwing: error)
                    } else if writer.status == .completed {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: WriteError())
                    }
                }
            }
        }
    }

    func cancel() {
        queue.async { [self] in
            if !finished { finished = true; writer.cancelWriting() }
        }
    }

    private struct WriteError: LocalizedError {
        var errorDescription: String? {
            "Audio could not be saved. Check the recording drive and retry. Any saved audio remains in the meeting folder."
        }
    }
}
