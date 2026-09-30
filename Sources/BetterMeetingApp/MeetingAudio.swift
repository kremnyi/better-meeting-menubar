import Foundation
import os
import WhisperKit

/// A meeting's audio as 16 kHz mono samples, decoded on first use and shared by every
/// Whisper language pass and speaker labeling instead of decoding the file for each.
final class MeetingAudio: Sendable {
    let url: URL
    // Guards `samples`; a second caller waits for the first decode instead of repeating it.
    private let samples = OSAllocatedUnfairLock<[Float]?>(initialState: nil)

    init(url: URL) {
        self.url = url
    }

    func load() throws -> [Float] {
        try samples.withLock { cached in
            if let cached { return cached }
            let loaded = try AudioProcessor.loadAudioAsFloatArray(fromPath: url.path)
            cached = loaded
            return loaded
        }
    }

    /// Frees the samples once transcription and speaker labels are done.
    func discard() {
        samples.withLock { $0 = nil }
    }
}
