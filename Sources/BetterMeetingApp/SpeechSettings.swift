import Foundation
import WhisperKit

enum SpeechModel: String, CaseIterable, Codable, Sendable {
    case small = "openai_whisper-small"
    case turbo = "openai_whisper-large-v3-v20240930"
    case large = "openai_whisper-large-v3"

    var label: String {
        switch self {
        case .small: "Small"
        case .turbo: "Large v3 Turbo (default)"
        case .large: "Large v3"
        }
    }

    var detail: String {
        switch self {
        case .small: "Uses the least memory; may miss more words."
        case .turbo: "Faster than Large v3; uses more memory than Small."
        case .large: "Uses the most memory and processing time."
        }
    }
}

struct SpeechSettings: Codable, Equatable, Sendable {
    var model: SpeechModel = .turbo
    var temperature: Float = 0
    var fallbackCount = 5
    var fallbackIncrement: Float = 0.2
    var noSpeechThreshold: Float = 0.6
    var logProbThreshold: Float = -1
    var compressionRatioThreshold: Float = 2.4
    // Optional so preferences and meeting metadata saved before speaker labels still decode.
    var speakerLabels: Bool? = nil

    func validate() throws {
        guard (0...1).contains(temperature), (0...10).contains(fallbackCount),
              (0...1).contains(fallbackIncrement), (0...1).contains(noSpeechThreshold),
              (-5...0).contains(logProbThreshold), (1...5).contains(compressionRatioThreshold) else {
            throw SpeechSettingsError.invalidOptions
        }
    }

    func decodingOptions(language: String) -> DecodingOptions {
        DecodingOptions(
            language: language, temperature: temperature,
            temperatureIncrementOnFallback: fallbackIncrement, temperatureFallbackCount: fallbackCount,
            detectLanguage: false, skipSpecialTokens: true, wordTimestamps: false,
            compressionRatioThreshold: compressionRatioThreshold, logProbThreshold: logProbThreshold,
            noSpeechThreshold: noSpeechThreshold, concurrentWorkerCount: 1, chunkingStrategy: .vad
        )
    }
}

enum SpeechSettingsError: LocalizedError {
    case invalidOptions
    var errorDescription: String? { "Invalid decoding settings. Reset Advanced settings and try again." }
}
