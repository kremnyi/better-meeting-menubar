import Foundation
import WhisperKit

struct ScoredSegment: Codable, Equatable, Sendable {
    let start: Double
    let end: Double
    let text: String
    let lang: String
    let score: Float
    let nospeech: Float

    var transcript: TranscriptSegment {
        TranscriptSegment(start: start, end: end, text: text, language: lang)
    }
}

struct TranscriptionLanguage: RawRepresentable, Hashable {
    let rawValue: String

    init?(rawValue: String) {
        guard Constants.languageCodes.contains(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    static let defaultCandidates = ["uk", "ru", "en"]
    static let allCases = Constants.languageCodes.compactMap(Self.init(rawValue:))
        .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }

    var label: String {
        (Locale.current.localizedString(forLanguageCode: rawValue) ?? rawValue).capitalized
    }

    static func candidates(from saved: [String]) -> [String] {
        var seen: Set<String> = []
        let unique = saved.filter { Constants.languageCodes.contains($0) && seen.insert($0).inserted }
        return unique.isEmpty ? defaultCandidates : unique
    }
}

enum TranscriptionPasses {
    // Bumped when decoding decoded samples split at silences, which segments speech differently than streaming did.
    private static let backend = "WhisperKit-1.1.0-nospeech-2-vad-samples"

    private struct Cache: Codable {
        let model: String
        let backend: String
        let options: Data
        var hints: String? = nil
        let audioSize: Int?
        let audioModified: Date?
        let segments: [ScoredSegment]
    }

    /// A candidate language gets its own pass only when some sampled window detects it at least this likely.
    static let detectionThreshold: Float = 0.3

    /// `detectLanguages` returns each sampled window's language probabilities; without it every candidate runs.
    static func run(
        audioURL: URL, languages: [String], hints: String = "",
        settings: SpeechSettings = SpeechSettings(),
        audioReady: (@Sendable () async throws -> Void)? = nil,
        detectLanguages: (() async throws -> [[String: Float]])? = nil,
        progressHandler: @escaping @Sendable (LocalTranscriptionProgress) -> Void,
        transcribe: (DecodingOptions, _ report: @escaping @Sendable (Double) -> Void) async throws -> [ScoredSegment]
    ) async throws -> [TranscriptSegment] {
        try settings.validate()
        guard !languages.isEmpty, languages.allSatisfy(Constants.languageCodes.contains),
              Set(languages).count == languages.count else { throw TranscriptionError.invalidLanguages }
        // A pending export has no cache yet; its passes are keyed on the m4a once it is written.
        var stamp = try audioReady == nil ? AudioStamp(of: audioURL) : nil
        let hints = hints.trimmingCharacters(in: .whitespacesAndNewlines)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        func cacheURL(_ language: String) -> URL {
            audioURL.deletingLastPathComponent().appendingPathComponent("pass_\(language).json")
        }
        func cachedPass(_ language: String) throws -> [ScoredSegment]? {
            let options = try encoder.encode(settings.decodingOptions(language: language))
            guard let stamp, let data = try? Data(contentsOf: cacheURL(language)),
                  let cache = try? JSONDecoder().decode(Cache.self, from: data),
                  cache.model == settings.model.rawValue, cache.backend == backend, cache.options == options,
                  (cache.hints ?? "") == hints,
                  cache.audioSize == stamp.size, cache.audioModified == stamp.modified else { return nil }
            return cache.segments
        }
        // Detection needs the model, so it runs only when a candidate's pass is still missing.
        var passes = languages
        if languages.count > 1, let detectLanguages, try languages.contains(where: { try cachedPass($0) == nil }) {
            let windows = try await detectLanguages()
            try Task.checkCancellation()
            let detected = languages.filter { language in windows.contains { $0[language] ?? 0 >= detectionThreshold } }
            passes = detected.isEmpty ? [languages[0]] : detected
        }
        let total = passes.count
        var segments: [ScoredSegment] = []
        for (index, language) in passes.enumerated() {
            try Task.checkCancellation()
            let report: @Sendable (Double) -> Void = { fraction in
                progressHandler(.transcribing(
                    (Double(index) + fraction) / Double(total), language: language, pass: index + 1, total: total
                ))
            }
            let pass: [ScoredSegment]
            if let cached = try cachedPass(language) {
                pass = cached
            } else {
                let options = settings.decodingOptions(language: language)
                pass = try await transcribe(options, report)
                try Task.checkCancellation()
                if stamp == nil, let audioReady {
                    try await audioReady()
                    stamp = try AudioStamp(of: audioURL)
                }
                let cache = Cache(
                    model: settings.model.rawValue, backend: backend,
                    options: try encoder.encode(options), hints: hints.isEmpty ? nil : hints, audioSize: stamp?.size,
                    audioModified: stamp?.modified, segments: pass
                )
                try encoder.encode(cache).write(to: cacheURL(language), options: .atomic)
            }
            segments.append(contentsOf: pass)
            report(1)
        }
        return (total > 1 ? merge(segments, noSpeechThreshold: settings.noSpeechThreshold, logProbThreshold: settings.logProbThreshold) : segments.sorted { $0.start < $1.start }).map(\.transcript)
    }

    // Port of GivenFLY/better-meeting's asr.py _merge at e9b524d, except that a candidate must add at
    // least half its length past the cursor. Upstream also took a segment another pass had already
    // covered, which repeated sentences and placed lines out of order.
    // Upstream rescans every segment for each pick; this sweep gives the same picks in near-linear time.
    static func merge(_ passes: [ScoredSegment], noSpeechThreshold: Float = 0.6, logProbThreshold: Float = -1) -> [ScoredSegment] {
        let segments = passes.filter { !($0.nospeech > noSpeechThreshold && $0.score < logProbThreshold) }
            .sorted { $0.start < $1.start }
        guard var cursor = segments.first?.start else { return [] }
        var merged: [ScoredSegment] = []
        // The cursor only moves forward, so segments that start within reach form a growing prefix,
        // and a segment that ends before the reach stays out of it for good.
        var reached = 0
        var open: [Int] = []
        var following = 0
        while true {
            while reached < segments.count, segments[reached].start <= cursor + 2 {
                open.append(reached)
                reached += 1
            }
            open.removeAll { !(segments[$0].end > cursor + 0.2) }
            // Keep the first candidate on ties, matching Python's max().
            var best: ScoredSegment?
            for index in open {
                let segment = segments[index]
                guard segment.end - max(segment.start, cursor) >= (segment.end - segment.start) / 2 else { continue }
                if let current = best, !(current.score < segment.score) { continue }
                best = segment
            }
            while following < segments.count, segments[following].start <= cursor { following += 1 }
            if let best {
                merged.append(best)
                cursor = best.end
            } else if following < segments.count {
                cursor = segments[following].start
            } else {
                break
            }
        }
        return merged
    }
}

enum TranscriptionError: LocalizedError {
    case invalidLanguages

    var errorDescription: String? { "Choose at least one supported language, without duplicates." }
}
