import AVFoundation
import CoreML
import Foundation
import WhisperKit

enum LocalTranscriptionProgress: Sendable {
    case preparingModel
    case downloadingModel(Double)
    case loadingModel
    case transcribing(Double, language: String, pass: Int, total: Int)
}

actor LocalTranscriber {
    private var whisper: WhisperKit?
    private var loadedModel: SpeechModel?
    private let downloadBase: URL

    static let defaultDownloadBase = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("huggingface")

    init(downloadBase: URL = defaultDownloadBase) {
        self.downloadBase = downloadBase
    }

    static func cachedModelFolder(in downloadBase: URL = defaultDownloadBase, model: SpeechModel = .turbo) -> URL? {
        let folder = downloadBase.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(model.rawValue)")
        return hasModelFiles(in: folder) ? folder : nil
    }

    static func hasModelFiles(in folder: URL) -> Bool {
        ["MelSpectrogram", "AudioEncoder", "TextDecoder"].allSatisfy { name in
            ["mlmodelc", "mlpackage"].contains { ext in
                let manifest = folder.appendingPathComponent("\(name).\(ext)")
                    .appendingPathComponent(ext == "mlmodelc" ? "coremldata.bin" : "Manifest.json")
                let values = try? manifest.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                return values?.isRegularFile == true && (values?.fileSize ?? 0) > 0
            }
        }
    }

    @discardableResult
    func prepare(
        model: SpeechModel = .turbo,
        progressHandler: @escaping @Sendable (LocalTranscriptionProgress) -> Void
    ) async throws -> WhisperKit {
        try Task.checkCancellation()
        if let whisper, loadedModel == model { return whisper }
        if let whisper { await whisper.unloadModels() }
        whisper = nil
        loadedModel = nil
        try Task.checkCancellation()
        progressHandler(.preparingModel)
        let modelFolder: URL
        if let cached = Self.cachedModelFolder(in: downloadBase, model: model) {
            modelFolder = cached
        } else {
            modelFolder = try await WhisperKit.download(
                variant: model.rawValue,
                downloadBase: downloadBase,
                progressCallback: { progress in
                    let fraction = progress.fractionCompleted
                    guard fraction.isFinite else { return }
                    progressHandler(.downloadingModel(min(max(fraction, 0), 1)))
                }
            )
        }

        progressHandler(.loadingModel)
        let loaded: MeetingWhisperKit
        do {
            loaded = try await MeetingWhisperKit(
                modelFolder: modelFolder.path,
                tokenizerFolder: downloadBase,
                verbose: false,
                prewarm: false,
                load: true,
                download: false
            )
        } catch {
            try Task.checkCancellation()
            guard (error as NSError).domain == MLModelErrorDomain else { throw error }
            // The downloader reuses existing files, even when their contents are damaged.
            try FileManager.default.removeItem(at: modelFolder)
            throw WhisperError.modelsUnavailable("Speech model files could not be loaded. Retry to download them again.")
        }
        whisper = loaded
        loadedModel = model
        try Task.checkCancellation()
        return loaded
    }

    func transcribe(
        audioURL: URL,
        languages: [String] = TranscriptionLanguage.defaultCandidates,
        hints: String = "",
        settings: SpeechSettings = SpeechSettings(),
        progressHandler: @escaping @Sendable (LocalTranscriptionProgress) -> Void
    ) async throws -> [TranscriptSegment] {
        let audioFile = try AVAudioFile(forReading: audioURL)
        let duration = Double(audioFile.length) / audioFile.fileFormat.sampleRate

        return try await TranscriptionPasses.run(
            audioURL: audioURL, languages: languages, hints: hints, settings: settings, progressHandler: progressHandler
        ) { options, index in
            let whisper = try await self.prepare(model: settings.model, progressHandler: progressHandler)
            var options = options
            let hints = hints.trimmingCharacters(in: .whitespacesAndNewlines)
            if !hints.isEmpty {
                guard let tokenizer = whisper.tokenizer else { throw WhisperError.tokenizerUnavailable() }
                // Cache the text alongside decoding options; tokenize only on a cache miss.
                options.promptTokens = tokenizer.encode(text: " " + hints)
            }
            let language = languages[index]
            let report: @Sendable (Double) -> Void = { fraction in
                progressHandler(.transcribing(
                    (Double(index) + fraction) / Double(languages.count),
                    language: language, pass: index + 1, total: languages.count
                ))
            }
            report(0)
            whisper.segmentDiscoveryCallback = { segments in
                guard duration > 0, let end = segments.last?.end else { return }
                report(min(max(Double(end) / duration, 0), 0.99))
            }
            defer { whisper.segmentDiscoveryCallback = nil }
            let results = try await whisper.transcribe(
                audioPath: audioURL.path,
                audioInputOptions: AudioInputOptions(audioLoadingMode: .incremental),
                decodeOptions: options
            )
            try Task.checkCancellation()
            return results.flatMap(\.segments).compactMap { segment in
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return ScoredSegment(
                    start: Double(segment.start), end: Double(segment.end), text: text,
                    lang: language, score: segment.avgLogprob, nospeech: segment.noSpeechProb
                )
            }
        }
    }
}
