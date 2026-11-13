import XCTest
@testable import BetterMeetingApp
import CoreML

final class ModelStorageTests: XCTestCase {
    func testStoredModelsReportInstallationAndSize() throws {
        let base = makeTempRoot()
        defer { removeTempRoot(base) }
        let whisper = base.appendingPathComponent("models/argmaxinc/whisperkit-coreml/openai_whisper-small")
        for name in ["MelSpectrogram", "AudioEncoder", "TextDecoder"] {
            try write(Data(repeating: 0, count: 1024), to: whisper.appendingPathComponent("\(name).mlmodelc/coremldata.bin"))
        }
        let speakers = base.appendingPathComponent("models/argmaxinc/speakerkit-coreml")
        // A partial download (or Finder metadata) must not count as installed speaker labels.
        try write("partial", to: speakers.appendingPathComponent(".DS_Store"))
        try write(Data(repeating: 1, count: 64), to: speakers.appendingPathComponent("speaker_segmenter/pyannote-v3/W8A16/SpeakerSegmenter.mlmodelc/coremldata.bin"))
        try write(Data(repeating: 1, count: 8192), to: base.appendingPathComponent("models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3-v20240930/AudioEncoder.mlmodelc/partial.bin"))
        try write(Data(repeating: 1, count: 8192), to: base.appendingPathComponent("models/parakeet-tdt-0.6b-v3/Encoder.mlmodelc/partial.bin"))

        let models = LocalTranscriber.storedModels(in: base)

        XCTAssertEqual(models.map(\.title), [
            "Whisper Small", "Whisper Large v3 Turbo", "Whisper Large v3", "Parakeet v3", "Speaker labels",
        ])
        let small = try XCTUnwrap(models.first)
        XCTAssertTrue(small.installed)
        XCTAssertGreaterThan(small.sizeBytes, 0)
        XCTAssertEqual(small.url.lastPathComponent, whisper.lastPathComponent)
        guard case .whisper(.small) = small.kind else { return XCTFail("Expected Whisper Small") }
        let turbo = try XCTUnwrap(models.first { $0.title.contains("Turbo") })
        XCTAssertFalse(turbo.installed)
        XCTAssertGreaterThan(turbo.sizeBytes, 0, "An incomplete download still occupies disk space")
        let parakeet = try XCTUnwrap(models.first { $0.title == "Parakeet v3" })
        XCTAssertEqual(parakeet.url.deletingLastPathComponent().lastPathComponent, "models")
        XCTAssertFalse(parakeet.installed)
        XCTAssertGreaterThan(parakeet.sizeBytes, 0)
        XCTAssertFalse(try XCTUnwrap(models.last).installed)
        for path in [
            "speaker_embedder/pyannote-v3/W8A16/SpeakerEmbedderPreprocessor",
            "speaker_embedder/pyannote-v3/W8A16/SpeakerEmbedder",
            "speaker_clusterer/pyannote-v4/W32A32/PldaProjector",
        ] {
            try write(Data(repeating: 1, count: 64), to: speakers.appendingPathComponent("\(path).mlmodelc/coremldata.bin"))
        }
        XCTAssertTrue(try XCTUnwrap(LocalTranscriber.storedModels(in: base, sizes: false).last).installed)
    }

    func testDeleteStoredModelRemovesOnlyThatFolder() async throws {
        let base = makeTempRoot()
        defer { removeTempRoot(base) }
        let folder = base.appendingPathComponent("models/argmaxinc/whisperkit-coreml/openai_whisper-small")
        try write("model", to: folder.appendingPathComponent("model.bin"))
        let other = folder.deletingLastPathComponent().appendingPathComponent("openai_whisper-large-v3/model.bin")
        try write("keep", to: other)

        let transcriber = LocalTranscriber(downloadBase: base)
        try await transcriber.deleteStoredModel(at: folder)

        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertEqual(try String(contentsOf: other, encoding: .utf8), "keep", "Deleting one model must leave the others")

        let locked = folder.appendingPathComponent("locked.bin")
        try write("keep until deletion succeeds", to: locked)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: locked.path) }
        do {
            try await transcriber.deleteStoredModel(at: folder)
            XCTFail("A failed model deletion must report its error")
        } catch {
            XCTAssertTrue(FileManager.default.fileExists(atPath: locked.path))
        }
    }

    func testDamagedModelIsRemovedOnlyForCoreMLLoadFailure() async throws {
        let base = makeTempRoot()
        defer { removeTempRoot(base) }
        let folder = base.appendingPathComponent("model")
        try write("weights", to: folder.appendingPathComponent("weights.bin"))

        for error in [CancellationError() as Error, NSError(domain: NSCocoaErrorDomain, code: 4)] {
            do {
                _ = try await LocalTranscriber.removingDamagedModel(at: folder) { throw error }
                XCTFail("The load error must propagate")
            } catch {}
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path), "Only a CoreML load failure removes the model")
        }

        // A temporary CoreML failure must not cost a multi-GB download.
        var attempts = 0
        let loaded = try await LocalTranscriber.removingDamagedModel(at: folder) {
            attempts += 1
            if attempts == 1 { throw NSError(domain: MLModelErrorDomain, code: 0) }
            return "model"
        }
        XCTAssertEqual(loaded, "model")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path), "A model that loads on retry must stay")

        do {
            _ = try await LocalTranscriber.removingDamagedModel(at: folder) {
                throw NSError(domain: MLModelErrorDomain, code: 0)
            }
            XCTFail("A damaged model must report that it is unavailable")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "A damaged model must download again")
    }

    private func write(_ contents: String, to url: URL) throws {
        try write(Data(contents.utf8), to: url)
    }

    private func write(_ contents: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url)
    }
}
