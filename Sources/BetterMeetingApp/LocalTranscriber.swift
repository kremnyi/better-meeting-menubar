import AVFoundation
import CoreML
import FluidAudio
import Foundation
import os
import SpeakerKit
import WhisperKit

enum LocalTranscriptionProgress: Sendable {
    case preparingModel
    case downloadingModel(Double)
    case loadingModel
    case transcribing(Double, language: String, pass: Int, total: Int)
    case engineTranscribing(Double?)
}

extension Double {
    /// A progress fraction within 0...1, or nil when a reporter sends NaN or infinity.
    var unitClamped: Double? { isFinite ? Swift.min(Swift.max(self, 0), 1) : nil }
}

struct StoredModelInfo: Identifiable, Sendable {
    enum Kind: Sendable {
        case whisper(SpeechModel)
        case parakeet
        case speakerLabels
    }

    let title: String
    let kind: Kind
    let url: URL
    let installed: Bool
    let sizeBytes: Int64
    let downloadBytes: Int64

    var id: String { url.path }
}

actor LocalTranscriber {
    private var whisper: WhisperKit?
    private var loadedModel: SpeechModel?
    private var parakeet: AsrManager?
    private var activeTranscriptions = 0
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
        ] {
            move(legacy.appendingPathComponent(path), to: destination.appendingPathComponent(path))
        }
        // Parakeet lives under models/ too; earlier builds kept it beside models/ and the original copy sits at the legacy root.
        let parakeet = destination.appendingPathComponent("models/parakeet-tdt-0.6b-v3")
        move(destination.appendingPathComponent("parakeet-tdt-0.6b-v3"), to: parakeet)
        move(legacy.appendingPathComponent("parakeet-tdt-0.6b-v3"), to: parakeet)
    }

    private static func move(_ source: URL, to target: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else { return }
        if fm.fileExists(atPath: target.path) {
            // The model was downloaded again at the new location; the source copy is a duplicate.
            try? fm.removeItem(at: source)
        } else {
            try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.moveItem(at: source, to: target)
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
        downloadBase.appendingPathComponent("models/parakeet-tdt-0.6b-v3", isDirectory: true)
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

    /// The models the app can store. `sizes: false` skips walking each folder, which keeps the call fast enough for the menu.
    static func storedModels(in downloadBase: URL = defaultDownloadBase, sizes: Bool = true) -> [StoredModelInfo] {
        var models = SpeechModel.allCases.map { model in
            let url = downloadBase.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(model.rawValue)")
            return info(
                title: "Whisper \(model.label)", kind: .whisper(model), url: url,
                installed: hasModelFiles(in: url), downloadBytes: model.downloadBytes, sizes: sizes
            )
        }
        let parakeet = parakeetDirectory(in: downloadBase)
        models.append(info(
            title: "Parakeet v3", kind: .parakeet, url: parakeet,
            installed: cachedParakeetModels(in: downloadBase), downloadBytes: 470_000_000, sizes: sizes
        ))
        let speakers = speakerKitDirectory(in: downloadBase)
        models.append(info(
            title: "Speaker labels", kind: .speakerLabels, url: speakers,
            installed: folderHasContent(speakers), downloadBytes: 11_000_000, sizes: sizes
        ))
        return models
    }

    private static func info(
        title: String, kind: StoredModelInfo.Kind, url: URL, installed: Bool, downloadBytes: Int64, sizes: Bool
    ) -> StoredModelInfo {
        StoredModelInfo(
            title: title, kind: kind, url: url,
            installed: installed, sizeBytes: installed && sizes ? sizeOnDisk(of: url) : 0, downloadBytes: downloadBytes
        )
    }

    private static func folderHasContent(_ folder: URL) -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty == false
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
        let modelFolder = try await download(model: model) {
            progressHandler(.downloadingModel($0))
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

    /// Releases loaded engines unless a transcription is still using them.
    func unloadIfIdle() async {
        guard activeTranscriptions == 0 else { return }
        await unloadLoadedModels()
    }

    private func unloadLoadedModels() async {
        // Forget the engines before awaiting their cleanup, so a transcription that starts
        // meanwhile loads a fresh engine instead of using one that is being unloaded.
        let loadedWhisper = whisper
        let loadedParakeet = parakeet
        whisper = nil
        loadedModel = nil
        parakeet = nil
        if let loadedWhisper { await loadedWhisper.unloadModels() }
        if let loadedParakeet { await loadedParakeet.cleanup() }
    }

    func deleteStoredModel(at url: URL) async {
        await unloadLoadedModels()
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    func download(model: SpeechModel, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        if let cached = Self.cachedModelFolder(in: downloadBase, model: model) { return cached }
        return try await WhisperKit.download(
            variant: model.rawValue,
            downloadBase: downloadBase,
            progressCallback: { update in
                if let fraction = update.fractionCompleted.unitClamped { progress(fraction) }
            }
        )
    }

    func downloadParakeet(progress: @escaping @Sendable (Double) -> Void) async throws {
        _ = try await AsrModels.download(
            to: Self.parakeetDirectory(in: downloadBase),
            version: Self.parakeetVersion,
            progressHandler: { update in
                guard case .downloading = update.phase, let fraction = update.fractionCompleted.unitClamped else { return }
                progress(fraction)
            }
        )
    }

    func downloadSpeakerModels() async throws {
        guard !Self.folderHasContent(Self.speakerKitDirectory(in: downloadBase)) else { return }
        _ = try await SpeakerKit(PyannoteConfig(downloadBase: downloadBase.path, verbose: false))
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
                    guard let fraction = progress.fractionCompleted.unitClamped else { return }
                    progressHandler(.downloadingModel(fraction))
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
        audio: MeetingAudio? = nil,
        languages: [String] = TranscriptionLanguage.defaultCandidates,
        hints: String = "",
        settings: SpeechSettings = SpeechSettings(),
        progressHandler: @escaping @Sendable (LocalTranscriptionProgress) -> Void
    ) async throws -> [TranscriptSegment] {
        activeTranscriptions += 1
        defer { activeTranscriptions -= 1 }
        switch settings.selectedEngine {
        case .whisper:
            return try await transcribeWhisper(
                audioURL: audioURL, audio: audio ?? MeetingAudio(url: audioURL),
                languages: languages, hints: hints, settings: settings,
                progressHandler: progressHandler
            )
        case .parakeet:
            return try await transcribeParakeet(audioURL: audioURL, progressHandler: progressHandler)
        }
    }

    private func transcribeWhisper(
        audioURL: URL,
        audio: MeetingAudio,
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
            // Chunks decoded in parallel finish out of order; report the furthest point reached.
            let furthest = OSAllocatedUnfairLock(initialState: 0.0)
            whisper.segmentDiscoveryCallback = { segments in
                guard duration > 0, let end = segments.map(\.end).max() else { return }
                report(furthest.withLock { reached in
                    reached = max(reached, min(max(Double(end) / duration, 0), 0.99))
                    return reached
                })
            }
            defer { whisper.segmentDiscoveryCallback = nil }
            // Decoded samples let WhisperKit split the audio at silences and decode several chunks at once.
            let samples = try audio.load()
            try Task.checkCancellation()
            let results = try await whisper.transcribe(audioArray: samples, decodeOptions: options)
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
        progressHandler: @escaping @Sendable (LocalTranscriptionProgress) -> Void
    ) async throws -> [TranscriptSegment] {
        let manager = try await prepareParakeet(progressHandler: progressHandler)
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
        // Parakeet detects the language itself. The language list is Whisper's setting, and pinning
        // one language garbled English product names in a Russian call.
        let result = try await manager.transcribe(audioURL, decoderState: &decoderState, language: nil)
        try Task.checkCancellation()
        // ponytail: Parakeet returns one fast pass, so cancellation just restarts it; no pass cache until measurements ask for one.
        return ParakeetLanguage.tagging(Self.segments(from: result))
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
