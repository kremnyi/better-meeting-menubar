import Foundation
import SpeakerKit
import WhisperKit

enum SpeakerLabels {
    struct Turn: Codable, Equatable, Sendable {
        let start: Double
        let end: Double
        let speaker: Int

        var isValid: Bool {
            start.isFinite && end.isFinite && start >= 0 && end > start && speaker >= 0
        }
    }

    private struct Cache: Codable {
        let backend: String
        let audioSize: Int?
        let audioModified: Date?
        let turns: [Turn]
    }

    static func run(
        audioURL: URL, segments: [TranscriptSegment], enabled: Bool,
        detect: () async throws -> [Turn]
    ) async throws -> [TranscriptSegment] {
        try Task.checkCancellation()
        guard enabled, !segments.isEmpty else { return segments }
        let backend = "SpeakerKit-1.1.0-pyannote-defaults"
        let attributes = try FileManager.default.attributesOfItem(atPath: audioURL.path)
        let size = (attributes[.size] as? NSNumber)?.intValue
        let modified = attributes[.modificationDate] as? Date
        let cacheURL = audioURL.deletingLastPathComponent().appendingPathComponent("speaker_turns.json")
        let cache = (try? Data(contentsOf: cacheURL)).flatMap { try? JSONDecoder().decode(Cache.self, from: $0) }
        let turns: [Turn]
        if let cache, cache.backend == backend, cache.audioSize == size, cache.audioModified == modified,
           cache.turns.allSatisfy(\.isValid) {
            turns = cache.turns
        } else {
            turns = try await detect()
            try Task.checkCancellation()
            guard turns.allSatisfy(\.isValid) else { throw MeetingActionError.invalidMeeting }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(Cache(backend: backend, audioSize: size, audioModified: modified, turns: turns))
                .write(to: cacheURL, options: .atomic)
        }
        try Task.checkCancellation()
        return assign(turns, to: segments)
    }

    static func detect(
        audioURL: URL, downloadBase: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [Turn] {
        try Task.checkCancellation()
        let kit = try await SpeakerKit(PyannoteConfig(downloadBase: downloadBase.path, verbose: false))
        do {
            try Task.checkCancellation()
            let audio = try AudioProcessor.loadAudioAsFloatArray(fromPath: audioURL.path)
            try Task.checkCancellation()
            let result = try await kit.diarize(audioArray: audio, progressCallback: { update in
                progress(update.fractionCompleted)
            })
            try Task.checkCancellation()
            await kit.unloadModels()
            return result.segments.compactMap { segment in
                guard let speaker = segment.speaker.speakerId else { return nil }
                return Turn(start: Double(segment.startTime), end: Double(segment.endTime), speaker: speaker)
            }
        } catch {
            await kit.unloadModels()
            throw error
        }
    }

    // ponytail: one label per transcript segment; use word timings if mid-segment speaker changes need splitting.
    static func assign(_ turns: [Turn], to segments: [TranscriptSegment]) -> [TranscriptSegment] {
        segments.map { segment in
            var labeled = segment
            var overlap: [Int: Double] = [:]
            for turn in turns where turn.isValid {
                let seconds = min(segment.end, turn.end) - max(segment.start, turn.start)
                if seconds > 0 { overlap[turn.speaker, default: 0] += seconds }
            }
            let best = overlap.values.max()
            let matches = overlap.filter { $0.value == best }.map(\.key)
            labeled.speaker = matches.count == 1 ? matches[0] : nil
            return labeled
        }
    }
}
