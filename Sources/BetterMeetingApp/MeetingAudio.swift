import Foundation
import os
import WhisperKit

/// A meeting's audio as 16 kHz mono samples, decoded on first use and shared by every
/// Whisper language pass and speaker labeling instead of decoding the file for each.
final class MeetingAudio: Sendable {
    let url: URL
    // One shared decode; a second caller awaits it instead of repeating it.
    private let decode = OSAllocatedUnfairLock<Task<[Float], Error>?>(initialState: nil)

    init(url: URL) {
        self.url = url
    }

    /// The decoded samples. The decode runs on a dispatch queue rather than the cooperative pool.
    func load() async throws -> [Float] {
        try Task.checkCancellation()
        let url = url
        let task = decode.withLock { task in
            if let task { return task }
            let started = Task<[Float], Error> {
                try await withCheckedThrowingContinuation { continuation in
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

    /// Frees the samples once transcription and speaker labels are done.
    func discard() {
        decode.withLock { $0 = nil }
    }
}
