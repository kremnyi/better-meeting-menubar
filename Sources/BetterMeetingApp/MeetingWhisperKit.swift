import CoreML
import Foundation
import WhisperKit

final class MeetingWhisperKit: WhisperKit {
    override func setupTranscribeTask(
        currentTimings: TranscriptionTimings, progress: Progress,
        audioProcessor: any AudioProcessing, audioEncoder: any AudioEncoding,
        featureExtractor: any FeatureExtracting, segmentSeeker: any SegmentSeeking,
        textDecoder: any TextDecoding, tokenizer: any WhisperTokenizer
    ) -> TranscribeTask {
        super.setupTranscribeTask(
            currentTimings: currentTimings, progress: progress,
            audioProcessor: audioProcessor, audioEncoder: audioEncoder,
            featureExtractor: featureExtractor, segmentSeeker: segmentSeeker,
            textDecoder: SpeechProbabilityDecoder(base: textDecoder), tokenizer: tokenizer
        )
    }
}

// WhisperKit 1.1.0 hardcodes noSpeechProb to zero. Read the unfiltered SOT logits,
// as OpenAI Whisper does, so the original repo's silence filter has real input.
// Remove this adapter when WhisperKit supplies the probability itself.
final class SpeechProbabilityDecoder: TextDecoding {
    private var base: any TextDecoding
    init(base: any TextDecoding) { self.base = base }

    var tokenizer: (any WhisperTokenizer)? {
        get { base.tokenizer }
        set { base.tokenizer = newValue }
    }
    var isModelMultilingual: Bool {
        get { base.isModelMultilingual }
        set { base.isModelMultilingual = newValue }
    }
    var logitsFilters: [any LogitsFiltering]? {
        get { base.logitsFilters }
        set { base.logitsFilters = newValue }
    }
    var supportsWordTimestamps: Bool { base.supportsWordTimestamps }
    var logitsSize: Int? { base.logitsSize }
    var kvCacheEmbedDim: Int? { base.kvCacheEmbedDim }
    var kvCacheMaxSequenceLength: Int? { base.kvCacheMaxSequenceLength }
    var windowSize: Int? { base.windowSize }
    var embedSize: Int? { base.embedSize }

    func predictLogits(_ inputs: any TextDecoderInputType) async throws -> (any TextDecoderOutputType)? {
        try await base.predictLogits(inputs)
    }

    func detectLanguage(
        from encoderOutput: any AudioEncoderOutputType, using decoderInputs: any DecodingInputsType,
        sampler tokenSampler: any TokenSampling, options: DecodingOptions, temperature: FloatType
    ) async throws -> DecodingResult {
        try await base.detectLanguage(
            from: encoderOutput, using: decoderInputs, sampler: tokenSampler,
            options: options, temperature: temperature
        )
    }

    func decodeText(
        from encoderOutput: any AudioEncoderOutputType, using decoderInputs: any DecodingInputsType,
        sampler tokenSampler: any TokenSampling, options: DecodingOptions,
        callback: TranscriptionCallback?
    ) async throws -> DecodingResult {
        guard let tokenizer, let inputs = decoderInputs as? DecodingInputs,
              let audio = encoderOutput as? MLMultiArray else {
            throw WhisperError.prepareDecoderInputsFailed("Missing inputs for speech detection")
        }
        inputs.inputIds[0] = NSNumber(value: tokenizer.specialTokens.startOfTranscriptToken)
        inputs.cacheLength[0] = 0
        let prediction = try await base.predictLogits(TextDecoderMLMultiArrayInputType(
            inputIds: inputs.inputIds, cacheLength: inputs.cacheLength,
            keyCache: inputs.keyCache, valueCache: inputs.valueCache,
            kvCacheUpdateMask: inputs.kvCacheUpdateMask, encoderOutputEmbeds: audio,
            decoderKeyPaddingMask: inputs.decoderKeyPaddingMask
        )) as? TextDecoderMLMultiArrayOutputType
        guard let logits = prediction?.logits else {
            throw WhisperError.decodingLogitsFailed("Missing logits for speech detection")
        }
        // HF tokenizers use either spelling; unknown tokens may resolve to end-of-text.
        guard let noSpeechToken = ["<|nospeech|>", "<|nocaptions|>"].compactMap({ name -> Int? in
            guard let id = tokenizer.convertTokenToId(name), tokenizer.convertIdToToken(id) == name else { return nil }
            return id
        }).first else { throw WhisperError.tokenizerUnavailable("Missing no-speech token") }
        let noSpeech = Self.probability(of: noSpeechToken, in: logits)
        var result = try await base.decodeText(
            from: encoderOutput, using: decoderInputs, sampler: tokenSampler,
            options: options, callback: callback
        )
        result.noSpeechProb = noSpeech
        result.fallback = DecodingFallback(
            options: options,
            isFirstTokenLogProbTooLow: result.fallback?.fallbackReason == "firstTokenLogProbThreshold",
            noSpeechProb: noSpeech, compressionRatio: result.compressionRatio, avgLogProb: result.avgLogProb
        )
        return result
    }

    /// Softmax of one logit, in the same order of operations as reading each value as a Double.
    static func probability(of token: Int, in logits: MLMultiArray) -> Float {
        // Reading the buffer directly avoids boxing every vocabulary entry in an NSNumber.
        logits.withUnsafeBufferPointer(ofType: Float16.self) { buffer in
            let values = buffer.prefix(logits.count)
            let maximum = values.lazy.map { Double($0) }.max() ?? 0
            let denominator = values.reduce(0.0) { $0 + exp(Double($1) - maximum) }
            return Float(exp(Double(values[token]) - maximum) / denominator)
        }
    }
}
