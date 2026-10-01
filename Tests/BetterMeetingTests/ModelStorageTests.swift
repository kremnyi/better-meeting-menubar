import XCTest
@testable import BetterMeetingApp

final class ModelStorageTests: XCTestCase {
    func testModelStorageMigrationMovesKnownModels() throws {
        let root = makeTempRoot()
        defer { removeTempRoot(root) }
        let legacy = root.appendingPathComponent("legacy")
        let destination = root.appendingPathComponent("current")

        let moved = [
            "models/argmaxinc/whisperkit-coreml/openai_whisper-small/model.bin",
            "models/argmaxinc/speakerkit-coreml/segmenter/model.bin",
            "models/openai/tokenizer.json",
        ]
        for path in moved {
            try write("data", to: legacy.appendingPathComponent(path))
        }
        try write("data", to: legacy.appendingPathComponent("parakeet-tdt-0.6b-v3/model.bin"))
        try write("keep", to: legacy.appendingPathComponent("other/file.txt"))

        LocalTranscriber.prepareModelStorage(legacy: legacy, destination: destination)

        for path in moved {
            XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent(path).path), path)
            XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.appendingPathComponent(path).path), path)
        }
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("models/parakeet-tdt-0.6b-v3/model.bin").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.appendingPathComponent("parakeet-tdt-0.6b-v3").path))
        XCTAssertEqual(try String(contentsOf: legacy.appendingPathComponent("other/file.txt")), "keep")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("other/file.txt").path))
    }

    func testModelStorageMigrationMergesPartialDestinationsAndPreservesConflicts() throws {
        let root = makeTempRoot()
        defer { removeTempRoot(root) }
        let legacy = root.appendingPathComponent("legacy")
        let destination = root.appendingPathComponent("current")
        try write("old", to: legacy.appendingPathComponent("models/openai/tokenizer.json"))
        try write("new", to: destination.appendingPathComponent("models/openai/tokenizer.json"))
        try write("same", to: legacy.appendingPathComponent("models/openai/duplicate.json"))
        try write("same", to: destination.appendingPathComponent("models/openai/duplicate.json"))
        let small = "models/argmaxinc/whisperkit-coreml/openai_whisper-small/model.bin"
        let large = "models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3/model.bin"
        try write("small", to: legacy.appendingPathComponent(small))
        try write("large", to: legacy.appendingPathComponent(large))
        try FileManager.default.createDirectory(
            at: destination.appendingPathComponent(small).deletingLastPathComponent(), withIntermediateDirectories: true
        )

        LocalTranscriber.prepareModelStorage(legacy: legacy, destination: destination)

        let tokenizer = destination.appendingPathComponent("models/openai/tokenizer.json")
        XCTAssertEqual(try String(contentsOf: tokenizer), "new")
        XCTAssertEqual(try String(contentsOf: legacy.appendingPathComponent("models/openai/tokenizer.json")), "old",
                       "An unverified conflicting file must survive migration")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.appendingPathComponent("models/openai/duplicate.json").path))
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent(small)), "small")
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent(large)), "large",
                       "A partial destination must not discard another installed model")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.appendingPathComponent("models/argmaxinc/whisperkit-coreml").path))
    }

    func testPrepareModelStorageRelocatesStrayParakeetFolder() throws {
        let root = makeTempRoot()
        defer { removeTempRoot(root) }
        let destination = root.appendingPathComponent("current")
        try write("model", to: destination.appendingPathComponent("parakeet-tdt-0.6b-v3/model.bin"))

        LocalTranscriber.prepareModelStorage(legacy: root.appendingPathComponent("legacy"), destination: destination)

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("models/parakeet-tdt-0.6b-v3/model.bin").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("parakeet-tdt-0.6b-v3").path))
    }

    func testStoredModelsReportInstallationAndSize() throws {
        let base = makeTempRoot()
        defer { removeTempRoot(base) }
        let whisper = base.appendingPathComponent("models/argmaxinc/whisperkit-coreml/openai_whisper-small")
        for name in ["MelSpectrogram", "AudioEncoder", "TextDecoder"] {
            try write(Data(repeating: 0, count: 1024), to: whisper.appendingPathComponent("\(name).mlmodelc/coremldata.bin"))
        }
        try write("speaker", to: base.appendingPathComponent("models/argmaxinc/speakerkit-coreml/model.bin"))
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
        XCTAssertTrue(try XCTUnwrap(models.last).installed)
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
        XCTAssertEqual(try String(contentsOf: other), "keep", "Deleting one model must leave the others")

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

    private func write(_ contents: String, to url: URL) throws {
        try write(Data(contents.utf8), to: url)
    }

    private func write(_ contents: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url)
    }
}
