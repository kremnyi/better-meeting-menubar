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
    var existsOnDisk: Bool = false

    var id: String { url.path }
}

actor LocalTranscriber {
    private var whisper: WhisperKit?
    private var loadedModel: SpeechModel?
    private var parakeet: AsrManager?
    private var speakerKit: SpeakerKit?
    private var activeTranscriptions = 0
    private let downloadBase: URL

    static let defaultDownloadBase = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("BetterMeeting", isDirectory: true)

    // Models used to live in Documents; moved here for one-time migration.
    static let legacyDownloadBase = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("huggingface", isDirectory: true)

    /// Present once Documents holds nothing left to migrate, so later launches don't touch that folder.
    static let legacyMigrationMarker = ".legacy-models-migrated"

    static func prepareModelStorage(legacy: URL = legacyDownloadBase, destination: URL = defaultDownloadBase) {
        let fm = FileManager.default
        try? fm.createDirectory(at: destination, withIntermediateDirectories: true)
        // Parakeet lives under models/ too; earlier builds kept it beside models/ and the original copy sits at the legacy root.
        let parakeet = destination.appendingPathComponent("models/parakeet-tdt-0.6b-v3")
        move(destination.appendingPathComponent("parakeet-tdt-0.6b-v3"), to: parakeet)

        let marker = destination.appendingPathComponent(legacyMigrationMarker)
        guard !fm.fileExists(atPath: marker.path) else { return }
        let legacyPaths = [
            "models/argmaxinc/whisperkit-coreml",
            "models/argmaxinc/speakerkit-coreml",
            "models/openai",
        ].map { (legacy.appendingPathComponent($0), destination.appendingPathComponent($0)) }
            + [(legacy.appendingPathComponent("parakeet-tdt-0.6b-v3"), parakeet)]
        if !isMissing(legacy) {
            for (source, target) in legacyPaths { move(source, to: target) }
        }
        // Conflicting files left behind keep the check running; a read error such as a denied
        // Documents permission is not proof that nothing is left.
        if isMissing(legacy) || legacyPaths.allSatisfy({ isMissing($0.0) }) {
            fm.createFile(atPath: marker.path, contents: nil)
        }
    }

    private static func isMissing(_ url: URL) -> Bool {
        do {
            return try !url.checkResourceIsReachable()
        } catch {
            return (error as NSError).domain == NSCocoaErrorDomain && (error as NSError).code == NSFileReadNoSuchFileError
        }
    }

    private static func move(_ source: URL, to target: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else { return }
        if !fm.fileExists(atPath: target.path) {
            try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.moveItem(at: source, to: target)
        } else if (try? source.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  (try? target.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            // Merge missing models/files into partial destinations. Conflicting files remain
            // at the old location until there is a verified replacement for them.
            guard let children = try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) else { return }
            for child in children { move(child, to: target.appendingPathComponent(child.lastPathComponent)) }
            if (try? fm.contentsOfDirectory(atPath: source.path))?.isEmpty == true {
                try? fm.removeItem(at: source)
            }
        } else if fm.contentsEqual(atPath: source.path, andPath: target.path) {
            try? fm.removeItem(at: source)
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
            && vocabularyIsValid(at: parakeetVocabulary(in: downloadBase))
    }

    // The menu asks on every open; parse the vocabulary again only after the file changes.
    private static let vocabularyCheck =
        OSAllocatedUnfairLock<(path: String, size: Int, modified: Date, valid: Bool)?>(initialState: nil)

    private static func vocabularyIsValid(at url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.intValue,
              let modified = attributes[.modificationDate] as? Date else { return false }
        if let check = vocabularyCheck.withLock({ $0 }), check.path == url.path, check.size == size, check.modified == modified {
            return check.valid
        }
        let valid = (try? Data(contentsOf: url)).map(validParakeetVocabulary) == true
        vocabularyCheck.withLock { $0 = (url.path, size, modified, valid) }
        return valid
    }

    private static func parakeetVocabulary(in downloadBase: URL) -> URL {
        parakeetDirectory(in: downloadBase).appendingPathComponent(ModelNames.ASR.vocabularyFile)
    }

    private static func validParakeetVocabulary(_ data: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return false }
        if let tokens = json as? [String] { return !tokens.isEmpty }
        guard let tokens = json as? [String: String], !tokens.isEmpty else { return false }
        return tokens.keys.allSatisfy { Int($0).map { $0 >= 0 } == true }
    }

    /// Remove only a malformed vocabulary; FluidAudio fetches that file again on download.
    /// Read failures and cancellation preserve the cache rather than treating it as corrupt.
    func repairParakeetVocabulary() throws {
        try Task.checkCancellation()
        let vocabulary = Self.parakeetVocabulary(in: downloadBase)
        guard FileManager.default.fileExists(atPath: vocabulary.path) else { return }
        let data = try Data(contentsOf: vocabulary)
        guard !Self.validParakeetVocabulary(data) else { return }
        try Task.checkCancellation()
        try FileManager.default.removeItem(at: vocabulary)
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

    /// The compiled bundles SpeakerKit's default pyannote setup loads, at the paths it reads them from.
    static func hasSpeakerModels(in folder: URL) -> Bool {
        [
            (ModelInfo.segmenter(), "SpeakerSegmenter"),
            (ModelInfo.embedder(), "SpeakerEmbedderPreprocessor"),
            (ModelInfo.embedder(), "SpeakerEmbedder"),
            (ModelInfo.plda(), "PldaProjector"),
        ].allSatisfy { info, name in
            let manifest = info.modelURL(baseURL: folder)
                .appendingPathComponent("\(name).mlmodelc").appendingPathComponent("coremldata.bin")
            let values = try? manifest.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            return values?.isRegularFile == true && (values?.fileSize ?? 0) > 0
        }
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
            installed: hasSpeakerModels(in: speakers), downloadBytes: 11_000_000, sizes: sizes
        ))
        return models
    }

    private static func info(
        title: String, kind: StoredModelInfo.Kind, url: URL, installed: Bool, downloadBytes: Int64, sizes: Bool
    ) -> StoredModelInfo {
        StoredModelInfo(
            title: title, kind: kind, url: url,
            installed: installed, sizeBytes: sizes ? sizeOnDisk(of: url) : 0, downloadBytes: downloadBytes,
            existsOnDisk: FileManager.default.fileExists(atPath: url.path)
        )
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
        await unloadWhisper()
        await unloadParakeet()
        await unloadSpeakerKit()
    }

    // Each unload forgets its engine before awaiting cleanup, so a transcription that starts
    // meanwhile loads a fresh engine instead of using one that is being unloaded.
    private func unloadWhisper() async {
        let loaded = whisper
        whisper = nil
        loadedModel = nil
        if let loaded { await loaded.unloadModels() }
    }

    private func unloadParakeet() async {
        let loaded = parakeet
        parakeet = nil
        if let loaded { await loaded.cleanup() }
    }

    private func unloadSpeakerKit() async {
        let loaded = speakerKit
        speakerKit = nil
        if let loaded { await loaded.unloadModels() }
    }

    /// Deletes one model folder, unloading only the engine that runs from it.
    func deleteStoredModel(at url: URL) async throws {
        let path = url.standardizedFileURL.path
        func holds(_ folder: URL) -> Bool { folder.standardizedFileURL.path == path }
        if let loadedModel, holds(downloadBase.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(loadedModel.rawValue)")) {
            await unloadWhisper()
        }
        if parakeet != nil, holds(Self.parakeetDirectory(in: downloadBase)) { await unloadParakeet() }
        if speakerKit != nil, holds(Self.speakerKitDirectory(in: downloadBase)) { await unloadSpeakerKit() }
        try FileManager.default.removeItem(at: url)
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
        try repairParakeetVocabulary()
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
        guard !Self.hasSpeakerModels(in: Self.speakerKitDirectory(in: downloadBase)) else { return }
        _ = try await SpeakerKit(PyannoteConfig(downloadBase: downloadBase.path, verbose: false))
    }

    private func prepareSpeakerKit() async throws -> SpeakerKit {
        if let speakerKit { return speakerKit }
        try Task.checkCancellation()
        let kit = try await SpeakerKit(PyannoteConfig(downloadBase: downloadBase.path, verbose: false))
        try Task.checkCancellation()
        // Another caller may have finished loading while this one waited.
        if let speakerKit {
            await kit.unloadModels()
            return speakerKit
        }
        speakerKit = kit
        return kit
    }

    /// Speaker turns from SpeakerKit, which stays loaded between meetings like the speech engines.
    func detectSpeakers(
        audio: MeetingAudio, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [SpeakerLabels.Turn] {
        activeTranscriptions += 1
        defer { activeTranscriptions -= 1 }
        let kit = try await prepareSpeakerKit()
        do {
            return try await SpeakerLabels.detect(audio: audio, kit: kit, progress: progress)
        } catch {
            // A failed run may leave the models in an unknown state; load them fresh next time.
            if !(error is CancellationError), speakerKit === kit { await unloadSpeakerKit() }
            throw error
        }
    }

    @discardableResult
    func prepareParakeet(
        progressHandler: @escaping @Sendable (LocalTranscriptionProgress) -> Void
    ) async throws -> AsrManager {
        if let parakeet { return parakeet }
        await unloadLoadedModels()
        try Task.checkCancellation()
        progressHandler(.preparingModel)
        try repairParakeetVocabulary()
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
            // Speaker labels decode the samples anyway; share them instead of letting FluidAudio decode the file again.
            return try await transcribeParakeet(
                audioURL: audioURL, audio: settings.speakerLabels == true ? audio : nil,
                progressHandler: progressHandler
            )
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
            let samples = try await audio.load()
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
        audio: MeetingAudio?,
        progressHandler: @escaping @Sendable (LocalTranscriptionProgress) -> Void
    ) async throws -> [TranscriptSegment] {
        let manager = try await prepareParakeet(progressHandler: progressHandler)
        let samples = try await audio?.load()
        try Task.checkCancellation()
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
        let result = if let samples {
            try await manager.transcribe(samples, decoderState: &decoderState, language: nil)
        } else {
            try await manager.transcribe(audioURL, decoderState: &decoderState, language: nil)
        }
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
