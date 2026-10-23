@preconcurrency import AVFoundation
import Foundation
import os
import WhisperKit

/// Read from the file system because URL resource values can be stale when the file is replaced.
struct AudioStamp: Sendable {
    let size: Int?
    let modified: Date?

    init(of url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        size = (attributes[.size] as? NSNumber)?.intValue
        modified = attributes[.modificationDate] as? Date
    }
}

private struct Waiting<T> {
    var cancelled = false
    var continuation: CheckedContinuation<T, Error>?
}

final class MeetingAudio: Sendable {
    let url: URL
    private let decoder: @Sendable (URL) async throws -> [Float]
    private let decode = OSAllocatedUnfairLock<Task<[Float], Error>?>(initialState: nil)

    /// Decodes with AudioExtractor's track mix, so transcription need not wait for the m4a export.
    convenience init(url: URL) {
        self.init(url: url, decoder: Self.decode)
    }

    init(url: URL, decoder: @escaping @Sendable (URL) async throws -> [Float]) {
        self.url = url
        self.decoder = decoder
    }

    /// Cancelling any caller cancels the shared decode for every caller of the job.
    func load() async throws -> [Float] {
        try Task.checkCancellation()
        let url = url
        let decoder = decoder
        let task = decode.withLock { task in
            if let task { return task }
            let started = Task<[Float], Error> { try await decoder(url) }
            task = started
            return started
        }
        let samples = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        try Task.checkCancellation()
        return samples
    }

    func discard() {
        decode.withLock { task in
            task?.cancel()
            task = nil
        }
    }

    /// Cancelling resumes the caller at once; the work runs on unobserved unless it polls `isCancelled`.
    static func blocking<T: Sendable>(_ work: @escaping @Sendable (_ isCancelled: @Sendable () -> Bool) throws -> T) async throws -> T {
        let state = OSAllocatedUnfairLock(initialState: Waiting<T>())
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let cancelled = state.withLock { waiting in
                    if !waiting.cancelled { waiting.continuation = continuation }
                    return waiting.cancelled
                }
                if cancelled { return continuation.resume(throwing: CancellationError()) }
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = Result { try work { state.withLock { $0.cancelled } } }
                    state.withLock { $0.continuation.take() }?.resume(with: result)
                }
            }
        } onCancel: {
            state.withLock { waiting in
                waiting.cancelled = true
                return waiting.continuation.take()
            }?.resume(throwing: CancellationError())
        }
    }

    @Sendable private static func decode(_ url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let allTracks = try await asset.loadTracks(withMediaType: .audio)
        // The m4a export leaves out disabled tracks, keeps the source rate, and has at most two channels.
        var tracks: [AVAssetTrack] = []
        for track in allTracks where try await track.load(.isEnabled) { tracks.append(track) }
        guard !tracks.isEmpty else { throw AudioExtractionError.cannotCreateExporter }
        var rate = 0.0
        var channels = 1
        for track in tracks {
            for description in try await track.load(.formatDescriptions) {
                guard let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else { continue }
                rate = max(rate, format.mSampleRate)
                channels = max(channels, Int(format.mChannelsPerFrame))
            }
        }
        let seconds = try await asset.load(.duration).seconds
        let mix = AudioExtractor.mix(for: url, tracks: allTracks)
        let (readTracks, readRate, readChannels) = (tracks, rate > 0 ? rate : 48_000, min(channels, 2))
        return try await blocking { isCancelled in
            try read(asset, tracks: readTracks, mix: mix, rate: readRate, channels: readChannels,
                     seconds: seconds.isFinite ? seconds : 0, isCancelled: isCancelled)
        }
    }

    private static func read(
        _ asset: AVURLAsset, tracks: [AVAssetTrack], mix: AVAudioMix?, rate: Double, channels: Int,
        seconds: Double, isCancelled: @Sendable () -> Bool
    ) throws -> [Float] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: true,
            AVLinearPCMIsBigEndianKey: false,
        ])
        output.audioMix = mix
        guard reader.canAdd(output) else { throw AudioExtractionError.cannotCreateExporter }
        reader.add(output)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: rate,
            channels: AVAudioChannelCount(channels), interleaved: false
        ), let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: Constants.defaultAudioReadFrameSize),
           let chunkData = chunk.floatChannelData
        else { throw AudioExtractionError.cannotCreateExporter }
        guard reader.startReading() else { throw reader.error ?? AudioExtractionError.cannotCreateExporter }
        defer { reader.cancelReading() }

        let sampleRate = Double(WhisperKit.sampleRate)
        var samples: [Float] = []
        // Grown by appends, the array would briefly hold two copies of a long meeting while reallocating.
        samples.reserveCapacity(Int(seconds * sampleRate) + WhisperKit.sampleRate)
        // WhisperKit resamples each 10-minute window of its m4a decode alone; flush at the same frames so the samples match.
        let window = AVAudioFramePosition(600 * rate)
        var position: AVAudioFramePosition = 0
        func flush() throws {
            guard chunk.frameLength > 0 else { return }
            defer { chunk.frameLength = 0 }
            if rate == sampleRate, channels == 1 {
                samples.append(contentsOf: UnsafeBufferPointer(start: chunkData[0], count: Int(chunk.frameLength)))
                return
            }
            guard let mono = AudioProcessor.convertToMono(chunk, mode: .sumChannels(nil)),
                  let resampled = AudioProcessor.resampleAudio(fromBuffer: mono, toSampleRate: sampleRate, channelCount: 1),
                  let data = resampled.floatChannelData
            else { throw AudioExtractionError.cannotCreateExporter }
            samples.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(resampled.frameLength)))
        }
        while let buffer = output.copyNextSampleBuffer() {
            if isCancelled() { throw CancellationError() }
            let frames = CMSampleBufferGetNumSamples(buffer)
            guard frames > 0 else { continue }
            try buffer.withAudioBufferList { list, _ in
                guard list.count == channels else { throw AudioExtractionError.cannotCreateExporter }
                var offset = 0
                while offset < frames {
                    let toWindowEnd = Int(window - position % window)
                    let room = Int(chunk.frameCapacity - chunk.frameLength)
                    let count = min(frames - offset, room, toWindowEnd)
                    for channel in 0..<channels {
                        guard let source = list[channel].mData?.assumingMemoryBound(to: Float.self) else {
                            throw AudioExtractionError.cannotCreateExporter
                        }
                        (chunkData[channel] + Int(chunk.frameLength)).update(from: source + offset, count: count)
                    }
                    chunk.frameLength += AVAudioFrameCount(count)
                    offset += count
                    position += AVAudioFramePosition(count)
                    if chunk.frameLength == chunk.frameCapacity || position % window == 0 { try flush() }
                }
            }
        }
        if reader.status == .failed { throw reader.error ?? AudioExtractionError.cannotCreateExporter }
        try flush()
        return samples
    }
}
