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
        var unique: [String] = []
        for code in saved where Constants.languageCodes.contains(code) && !unique.contains(code) {
            unique.append(code)
        }
        return unique.isEmpty ? defaultCandidates : unique
    }
}

enum TranscriptionPasses {
    private static let backend = "WhisperKit-1.1.0-nospeech-2"

    private struct Cache: Codable {
        let model: String
        let backend: String
        let options: Data
        var hints: String? = nil
        let audioSize: Int?
        let audioModified: Date?
        let segments: [ScoredSegment]
    }

    static func run(
        audioURL: URL, languages: [String], hints: String = "",
        settings: SpeechSettings = SpeechSettings(),
        progressHandler: @Sendable (LocalTranscriptionProgress) -> Void,
        transcribe: (DecodingOptions, Int) async throws -> [ScoredSegment]
    ) async throws -> [TranscriptSegment] {
        try settings.validate()
        guard !languages.isEmpty, languages.allSatisfy(Constants.languageCodes.contains),
              Set(languages).count == languages.count else { throw TranscriptionError.invalidLanguages }
        // URL resource values can be stale when an existing audio file is replaced.
        let attributes = try FileManager.default.attributesOfItem(atPath: audioURL.path)
        let hints = hints.trimmingCharacters(in: .whitespacesAndNewlines)
        let audioSize = (attributes[.size] as? NSNumber)?.intValue
        let audioModified = attributes[.modificationDate] as? Date
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var segments: [ScoredSegment] = []
        for (index, language) in languages.enumerated() {
            try Task.checkCancellation()
            let options = settings.decodingOptions(language: language)
            let encodedOptions = try encoder.encode(options)
            let cacheURL = audioURL.deletingLastPathComponent().appendingPathComponent("pass_\(language).json")
            let cache = (try? Data(contentsOf: cacheURL)).flatMap { try? JSONDecoder().decode(Cache.self, from: $0) }
            let pass: [ScoredSegment]
            if let cache, cache.model == settings.model.rawValue,
               cache.backend == backend, cache.options == encodedOptions,
               (cache.hints ?? "") == hints,
               cache.audioSize == audioSize, cache.audioModified == audioModified {
                pass = cache.segments
            } else {
                pass = try await transcribe(options, index)
                try Task.checkCancellation()
                let cache = Cache(
                    model: settings.model.rawValue, backend: backend,
                    options: encodedOptions, hints: hints.isEmpty ? nil : hints, audioSize: audioSize,
                    audioModified: audioModified, segments: pass
                )
                try encoder.encode(cache).write(to: cacheURL, options: .atomic)
            }
            segments.append(contentsOf: pass)
            progressHandler(.transcribing(
                Double(index + 1) / Double(languages.count),
                language: language, pass: index + 1, total: languages.count
            ))
        }
        return (languages.count > 1 ? merge(segments, noSpeechThreshold: settings.noSpeechThreshold, logProbThreshold: settings.logProbThreshold) : segments.sorted { $0.start < $1.start }).map(\.transcript)
    }

    // Port of GivenFLY/better-meeting's asr.py _merge at e9b524d.
    // ponytail: upstream's quadratic scan; sweep the intervals if long meetings make merging slow.
    static func merge(_ passes: [ScoredSegment], noSpeechThreshold: Float = 0.6, logProbThreshold: Float = -1) -> [ScoredSegment] {
        let segments = passes.filter { !($0.nospeech > noSpeechThreshold && $0.score < logProbThreshold) }
            .sorted { $0.start < $1.start }
        guard var cursor = segments.first?.start else { return [] }
        var merged: [ScoredSegment] = []
        while true {
            let candidates = segments.filter { $0.end > cursor + 0.2 && $0.start <= cursor + 2 }
            // Keep the first candidate on ties, matching Python's max().
            if let best = candidates.max(by: { $0.score < $1.score }) {
                merged.append(best)
                cursor = best.end
            } else if let next = segments.first(where: { $0.start > cursor }) {
                cursor = next.start
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
