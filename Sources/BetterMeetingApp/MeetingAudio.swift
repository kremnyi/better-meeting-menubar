import AVFoundation
import Foundation
import os
import WhisperKit

/// The extracted m4a's size and modification date, which the pass and speaker caches key on.
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

/// A meeting's audio as 16 kHz mono samples, decoded on first use and shared by every
/// Whisper language pass and speaker labeling instead of decoding the file for each.
final class MeetingAudio: Sendable {
    static let sampleRate = Double(WhisperKit.sampleRate)

    /// The extracted m4a, or the recording itself for `init(recording:)`.
    let url: URL
    private let fromRecording: Bool
    // One shared decode; a second caller awaits it instead of repeating it.
    private let decode = OSAllocatedUnfairLock<Task<[Float], Error>?>(initialState: nil)

    init(url: URL) {
        self.url = url
        fromRecording = false
    }

    /// Decodes the recording with AudioExtractor's track mix, so transcription need not wait for the
    /// m4a export. The samples differ from the m4a's only by the export's AAC encoding.
    init(recording: URL) {
        url = recording
        fromRecording = true
    }

    /// The decoded samples. The decode runs on a dispatch queue rather than the cooperative pool.
    func load() async throws -> [Float] {
        try Task.checkCancellation()
        let url = url
        let fromRecording = fromRecording
        let task = decode.withLock { task in
            if let task { return task }
            let started = Task<[Float], Error> {
                if fromRecording { return try await Self.decodeRecording(url) }
                return try await withCheckedThrowingContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        continuation.resume(with: Result { try AudioProcessor.loadAudioAsFloatArray(fromPath: url.path) })
                    }
                }
            }
            task = started
            return started
        }
        let samples = try await task.value
        try Task.checkCancellation()
        return samples
    }

    /// Frees the samples once transcription and speaker labels are done, stopping a decode still running.
    func discard() {
        decode.withLock { task in
            task?.cancel()
            task = nil
        }
    }

    private static func decodeRecording(_ url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let allTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !allTracks.isEmpty else { throw AudioExtractionError.cannotCreateExporter }
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
        let duration = try await asset.load(.duration).seconds
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result {
                        try read(asset, tracks: tracks, mix: AudioExtractor.mix(for: url, tracks: allTracks),
                                 rate: rate > 0 ? rate : 48_000, channels: min(channels, 2),
                                 duration: duration, cancelled: cancelled)
                    })
                }
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
    }

    private static func read(
        _ asset: AVURLAsset, tracks: [AVAssetTrack], mix: AVAudioMix?, rate: Double, channels: Int,
        duration: Double, cancelled: OSAllocatedUnfairLock<Bool>
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
        if duration.isFinite, duration > 0 { samples.reserveCapacity(Int(duration * sampleRate) + Int(sampleRate)) }
        // WhisperKit decodes the m4a in 10-minute windows read 1,323,000 frames at a time, mixing each
        // read to mono and resampling it alone; flush at the same frames so the samples match it.
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
            if cancelled.withLock({ $0 }) { throw CancellationError() }
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
        if cancelled.withLock({ $0 }) { throw CancellationError() }
        if reader.status == .failed { throw reader.error ?? AudioExtractionError.cannotCreateExporter }
        try flush()
        return samples
    }
}
