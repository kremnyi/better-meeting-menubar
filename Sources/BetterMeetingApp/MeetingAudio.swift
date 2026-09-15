import Foundation
import WhisperKit

/// A meeting's audio as 16 kHz mono samples, decoded on first use and shared by every
/// Whisper language pass and speaker labeling instead of decoding the file for each.
final class MeetingAudio: @unchecked Sendable {
    let url: URL
    // Guards `samples`; a second caller waits for the first decode instead of repeating it.
    private let lock = NSLock()
    private var samples: [Float]?

    init(url: URL) {
        self.url = url
    }

    func load() throws -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        if let samples { return samples }
        let loaded = try AudioProcessor.loadAudioAsFloatArray(fromPath: url.path)
        samples = loaded
        return loaded
    }

    /// Frees the samples once transcription and speaker labels are done.
    func discard() {
        lock.lock()
        defer { lock.unlock() }
        samples = nil
    }
}
