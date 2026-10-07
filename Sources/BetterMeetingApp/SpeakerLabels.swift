import Foundation
import SpeakerKit

enum SpeakerLabels {
    struct Turn: Codable, Sendable {
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
        audioReady: (@Sendable () async throws -> Void)? = nil,
        detect: () async throws -> [Turn]
    ) async throws -> [TranscriptSegment] {
        try Task.checkCancellation()
        guard enabled, !segments.isEmpty else { return segments }
        let backend = "SpeakerKit-1.1.0-pyannote-defaults"
        // A pending export has no cache yet; its turns are keyed on the m4a once it is written.
        let stamp = try audioReady == nil ? AudioStamp(of: audioURL) : nil
        let cacheURL = audioURL.deletingLastPathComponent().appendingPathComponent("speaker_turns.json")
        let cache = (try? Data(contentsOf: cacheURL)).flatMap { try? JSONDecoder().decode(Cache.self, from: $0) }
        let turns: [Turn]
        if let cache, let stamp, cache.backend == backend, cache.audioSize == stamp.size,
           cache.audioModified == stamp.modified, cache.turns.allSatisfy(\.isValid) {
            turns = cache.turns
        } else {
            turns = try await detect()
            try Task.checkCancellation()
            guard turns.allSatisfy(\.isValid) else { throw MeetingActionError.invalidMeeting }
            try await audioReady?()
            let written = try stamp ?? AudioStamp(of: audioURL)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(Cache(backend: backend, audioSize: written.size, audioModified: written.modified, turns: turns))
                .write(to: cacheURL, options: .atomic)
        }
        try Task.checkCancellation()
        return assign(turns, to: segments)
    }

    static func detect(
        audio: MeetingAudio, kit: SpeakerKit,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [Turn] {
        try Task.checkCancellation()
        let samples = try await audio.load()
        try Task.checkCancellation()
        let result = try await kit.diarize(audioArray: samples, progressCallback: { update in
            progress(update.fractionCompleted)
        })
        try Task.checkCancellation()
        return result.segments.compactMap { segment in
            guard let speaker = segment.speaker.speakerId else { return nil }
            return Turn(start: Double(segment.startTime), end: Double(segment.endTime), speaker: speaker)
        }
    }

    // ponytail: one label per transcript segment; use word timings if mid-segment speaker changes need splitting.
    static func assign(_ turns: [Turn], to segments: [TranscriptSegment]) -> [TranscriptSegment] {
        // Validate once and order by start; the sort is stable, so equal starts keep their input order.
        let sorted = turns.filter(\.isValid).sorted { $0.start < $1.start }
        // furthestEnd[i] is the latest end among sorted[0...i]; turns before the first index whose
        // value passes a segment's start cannot overlap it.
        var furthestEnd: [Double] = []
        furthestEnd.reserveCapacity(sorted.count)
        for turn in sorted { furthestEnd.append(max(furthestEnd.last ?? -.infinity, turn.end)) }
        return segments.map { segment in
            var labeled = segment
            var overlap: [Int: Double] = [:]
            var index = Self.firstIndex(in: furthestEnd) { $0 > segment.start }
            while index < sorted.count, sorted[index].start < segment.end {
                let turn = sorted[index]
                let seconds = min(segment.end, turn.end) - max(segment.start, turn.start)
                if seconds > 0 { overlap[turn.speaker, default: 0] += seconds }
                index += 1
            }
            let best = overlap.values.max()
            let matches = overlap.filter { $0.value == best }.map(\.key)
            labeled.speaker = matches.count == 1 ? matches[0] : nil
            return labeled
        }
    }

    /// The first index whose value satisfies `predicate`, for values on which it flips from false to true once.
    private static func firstIndex(in values: [Double], where predicate: (Double) -> Bool) -> Int {
        var low = 0
        var high = values.count
        while low < high {
            let middle = (low + high) / 2
            if predicate(values[middle]) { high = middle } else { low = middle + 1 }
        }
        return low
    }
}
