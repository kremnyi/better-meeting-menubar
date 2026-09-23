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

    func testModelStorageMigrationKeepsDestinationAndDropsDuplicate() throws {
        let root = makeTempRoot()
        defer { removeTempRoot(root) }
        let legacy = root.appendingPathComponent("legacy")
        let destination = root.appendingPathComponent("current")
        try write("old", to: legacy.appendingPathComponent("models/openai/tokenizer.json"))
        try write("new", to: destination.appendingPathComponent("models/openai/tokenizer.json"))

        LocalTranscriber.prepareModelStorage(legacy: legacy, destination: destination)

        let tokenizer = destination.appendingPathComponent("models/openai/tokenizer.json")
        XCTAssertEqual(try String(contentsOf: tokenizer), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.appendingPathComponent("models/openai").path))
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

        let models = LocalTranscriber.storedModels(in: base)

        XCTAssertEqual(models.map(\.title), [
            "Whisper Small", "Whisper Large v3 Turbo", "Whisper Large v3", "Parakeet v3", "Speaker labels",
        ])
        let small = try XCTUnwrap(models.first)
        XCTAssertTrue(small.installed)
        XCTAssertGreaterThan(small.sizeBytes, 0)
        XCTAssertEqual(small.url.lastPathComponent, whisper.lastPathComponent)
        XCTAssertEqual(small.downloadBytes, SpeechModel.small.downloadBytes)
        guard case .whisper(.small) = small.kind else { return XCTFail("Expected Whisper Small") }
        let turbo = try XCTUnwrap(models.first { $0.title.contains("Turbo") })
        XCTAssertFalse(turbo.installed)
        XCTAssertEqual(turbo.sizeBytes, 0)
        XCTAssertEqual(turbo.downloadBytes, SpeechModel.turbo.downloadBytes)
        let parakeet = try XCTUnwrap(models.first { $0.title == "Parakeet v3" })
        XCTAssertEqual(parakeet.url.deletingLastPathComponent().lastPathComponent, "models")
        XCTAssertTrue(try XCTUnwrap(models.last).installed)
        XCTAssertGreaterThan(SpeechModel.small.downloadBytes, 0)
        XCTAssertLessThan(SpeechModel.small.downloadBytes, SpeechModel.turbo.downloadBytes)
        XCTAssertLessThan(SpeechModel.turbo.downloadBytes, SpeechModel.large.downloadBytes)
    }

    func testDeleteStoredModelRemovesFolder() async throws {
        let base = makeTempRoot()
        defer { removeTempRoot(base) }
        let folder = base.appendingPathComponent("models/argmaxinc/whisperkit-coreml/openai_whisper-small")
        try write("model", to: folder.appendingPathComponent("model.bin"))

        let transcriber = LocalTranscriber(downloadBase: base)
        await transcriber.deleteStoredModel(at: folder)

        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    private func write(_ contents: String, to url: URL) throws {
        try write(Data(contents.utf8), to: url)
    }

    private func write(_ contents: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url)
    }
}
