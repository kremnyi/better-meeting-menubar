import AVFoundation
import CoreML
import FluidAudio
import Foundation
import WhisperKit

enum LocalTranscriptionProgress: Sendable {
    case preparingModel
    case downloadingModel(Double)
    case loadingModel
    case transcribing(Double, language: String, pass: Int, total: Int)
    case engineTranscribing(Double?)
}

struct StoredModelInfo: Identifiable, Sendable {
    let title: String
    let url: URL
    let installed: Bool
    let sizeBytes: Int64

    var id: String { url.path }
}

actor LocalTranscriber {
    private var whisper: WhisperKit?
    private var loadedModel: SpeechModel?
    private var parakeet: AsrManager?
    private let downloadBase: URL

    static let defaultDownloadBase = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("BetterMeeting", isDirectory: true)

    // Models used to live in Documents; moved here for one-time migration.
    static let legacyDownloadBase = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("huggingface", isDirectory: true)

    static func prepareModelStorage(legacy: URL = legacyDownloadBase, destination: URL = defaultDownloadBase) {
        let fm = FileManager.default
        try? fm.createDirectory(at: destination, withIntermediateDirectories: true)
        for path in [
            "models/argmaxinc/whisperkit-coreml",
            "models/argmaxinc/speakerkit-coreml",
            "models/openai",
            "parakeet-tdt-0.6b-v3",
        ] {
            let source = legacy.appendingPathComponent(path)
            let target = destination.appendingPathComponent(path)
            guard fm.fileExists(atPath: source.path) else { continue }
            if fm.fileExists(atPath: target.path) {
                // A build before the move downloaded the model here again; the legacy copy is a duplicate.
                try? fm.removeItem(at: source)
            } else {
                try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.moveItem(at: source, to: target)
            }
        }
    }

    init(downloadBase: URL = defaultDownloadBase) {
        self.downloadBase = downloadBase
    }

    static func cachedModelFolder(in downloadBase: URL = defaultDownloadBase, model: SpeechModel = .turbo) -> URL? {
        let folder = downloadBase.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(model.rawValue)")
        return hasModelFiles(in: folder) ? folder : nil
    }

    static func cachedParakeetModels(in downloadBase: URL = defaultDownloadBase) -> Bool {
        AsrModels.modelsExist(at: parakeetDirectory(in: downloadBase), version: parakeetVersion)
    }

    private static func parakeetDirectory(in downloadBase: URL) -> URL {
        downloadBase.appendingPathComponent("parakeet-tdt-0.6b-v3", isDirectory: true)
    }

    private static let parakeetVersion = AsrModelVersion.v3

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

    private static func speakerKitDirectory(in downloadBase: URL) -> URL {
        downloadBase.appendingPathComponent("models/argmaxinc/speakerkit-coreml", isDirectory: true)
    }

    static func storedModels(in downloadBase: URL = defaultDownloadBase) -> [StoredModelInfo] {
        var models = SpeechModel.allCases.map { model in
            let url = downloadBase.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(model.rawValue)")
            return info(title: "Whisper \(model.label)", url: url, installed: hasModelFiles(in: url))
        }
        let parakeet = parakeetDirectory(in: downloadBase)
        models.append(info(title: "Parakeet v3", url: parakeet, installed: cachedParakeetModels(in: downloadBase)))
        let speakers = speakerKitDirectory(in: downloadBase)
        let speakersInstalled = (try? FileManager.default.contentsOfDirectory(atPath: speakers.path))?.isEmpty == false
        models.append(info(title: "Speaker labels", url: speakers, installed: speakersInstalled))
        return models
    }

    private static func info(title: String, url: URL, installed: Bool) -> StoredModelInfo {
        StoredModelInfo(title: title, url: url, installed: installed, sizeBytes: installed ? sizeOnDisk(of: url) : 0)
    }

    static func sizeOnDisk(of folder: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Array(keys)) else {
            return 0
        }
        var total: Int64 = 0
        for case let file as URL in files {
            guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }

    @discardableResult
    func prepare(
        model: SpeechModel = .turbo,
        progressHandler: @escaping @Sendable (LocalTranscriptionProgress) -> Void
    ) async throws -> WhisperKit {
        try Task.checkCancellation()
        if let whisper, loadedModel == model { return whisper }
        await unloadLoadedModels()
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

    func prepare(
        settings: SpeechSettings,
        progressHandler: @escaping @Sendable (LocalTranscriptionProgress) -> Void
    ) async throws {
        switch settings.selectedEngine {
        case .whisper:
            _ = try await prepare(model: settings.model, progressHandler: progressHandler)
        case .parakeet:
            _ = try await prepareParakeet(progressHandler: progressHandler)
        }
    }

    private func unloadLoadedModels() async {
        if let whisper { await whisper.unloadModels() }
        whisper = nil
        loadedModel = nil
        if let parakeet { await parakeet.cleanup() }
        parakeet = nil
    }

    func deleteStoredModel(at url: URL) async {
        await unloadLoadedModels()
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    func prepareParakeet(
        progressHandler: @escaping @Sendable (LocalTranscriptionProgress) -> Void
    ) async throws -> AsrManager {
        if let parakeet { return parakeet }
        await unloadLoadedModels()
        try Task.checkCancellation()
        progressHandler(.preparingModel)
        let models = try await AsrModels.downloadAndLoad(
            to: Self.parakeetDirectory(in: downloadBase),
            version: Self.parakeetVersion,
            progressHandler: { progress in
                switch progress.phase {
                case .listing:
                    progressHandler(.preparingModel)
                case .downloading:
                    let fraction = progress.fractionCompleted
                    guard fraction.isFinite else { return }
                    progressHandler(.downloadingModel(min(max(fraction, 0), 1)))
                case .compiling:
                    progressHandler(.loadingModel)
                }
            }
        )
        try Task.checkCancellation()
        progressHandler(.loadingModel)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        parakeet = manager
        try Task.checkCancellation()
        return manager
    }

    func transcribe(
        audioURL: URL,
        languages: [String] = TranscriptionLanguage.defaultCandidates,
        hints: String = "",
        settings: SpeechSettings = SpeechSettings(),
        progressHandler: @escaping @Sendable (LocalTranscriptionProgress) -> Void
    ) async throws -> [TranscriptSegment] {
        switch settings.selectedEngine {
        case .whisper:
            return try await transcribeWhisper(
                audioURL: audioURL, languages: languages, hints: hints, settings: settings,
                progressHandler: progressHandler
            )
        case .parakeet:
            return try await transcribeParakeet(
                audioURL: audioURL, languages: languages, progressHandler: progressHandler
            )
        }
    }

    private func transcribeWhisper(
        audioURL: URL,
        languages: [String],
        hints: String,
        settings: SpeechSettings,
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

    private func transcribeParakeet(
        audioURL: URL,
        languages: [String],
        progressHandler: @escaping @Sendable (LocalTranscriptionProgress) -> Void
    ) async throws -> [TranscriptSegment] {
        let manager = try await prepareParakeet(progressHandler: progressHandler)
        let language = languages.count == 1 ? Language(rawValue: languages[0]) : nil
        progressHandler(.engineTranscribing(nil))
        let progressTask = Task {
            do {
                for try await fraction in await manager.transcriptionProgressStream {
                    progressHandler(.engineTranscribing(fraction))
                }
            } catch {}
        }
        defer { progressTask.cancel() }
        var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(audioURL, decoderState: &decoderState, language: language)
        try Task.checkCancellation()
        // ponytail: Parakeet returns one fast pass, so cancellation just restarts it; no pass cache until measurements ask for one.
        return Self.segments(from: result)
    }

    static func segments(from result: ASRResult) -> [TranscriptSegment] {
        let words = buildWordTimings(from: result.tokenTimings ?? [])
        guard !words.isEmpty else {
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return [] }
            return [TranscriptSegment(start: 0, end: max(result.duration, 0), text: text, language: nil)]
        }
        var segments: [TranscriptSegment] = []
        var start = 0
        for index in words.indices {
            let isLast = index == words.count - 1
            let longEnough = index - start + 1 >= 40
            let sentenceEnd = words[index].word.last.map { ".!?…".contains($0) } == true
            let nextGap = isLast ? 0 : words[index + 1].startTime - words[index].endTime
            guard isLast || longEnough || sentenceEnd || nextGap > 1.0 else { continue }
            let text = words[start...index].map(\.word).joined(separator: " ")
                .replacingOccurrences(of: " ,", with: ",")
                .replacingOccurrences(of: " .", with: ".")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                segments.append(TranscriptSegment(
                    start: words[start].startTime, end: words[index].endTime, text: text, language: nil
                ))
            }
            start = index + 1
        }
        return segments
    }
}
