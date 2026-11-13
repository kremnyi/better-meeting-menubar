import FluidAudio
import XCTest
@testable import BetterMeetingApp

final class ParakeetEngineTests: XCTestCase {
    func testMalformedVocabularyIsNotReadyAndRepairKeepsModels() async throws {
        let root = makeTempRoot("ParakeetVocabulary")
        defer { removeTempRoot(root) }
        let folder = root.appendingPathComponent("models/parakeet-tdt-0.6b-v3")
        let fm = FileManager.default
        for name in ["Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc", "JointDecisionv3.mlmodelc"] {
            try fm.createDirectory(at: folder.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let vocabulary = folder.appendingPathComponent("parakeet_vocab.json")
        let valid = Data("{\"0\":\"<blank>\",\"1\":\"hello\"}".utf8)
        try valid.write(to: vocabulary)
        XCTAssertTrue(AsrModels.modelsExist(at: folder, version: .v3), "Fixture must reach the vocabulary check")
        XCTAssertTrue(LocalTranscriber.cachedParakeetModels(in: root))
        let transcriber = LocalTranscriber(downloadBase: root)
        try await transcriber.repairParakeetVocabulary()
        XCTAssertEqual(try Data(contentsOf: vocabulary), valid)
        for invalid in ["{broken", "{}", "{\"word\":\"hello\"}"] {
            try Data(invalid.utf8).write(to: vocabulary)
            XCTAssertFalse(LocalTranscriber.cachedParakeetModels(in: root))
            let cancelled = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                try await transcriber.repairParakeetVocabulary()
            }
            if case .success = await cancelled.result { XCTFail("Cancellation must stop repair") }
            XCTAssertTrue(fm.fileExists(atPath: vocabulary.path), "Cancellation must preserve every cached file")
            try await transcriber.repairParakeetVocabulary()
            XCTAssertFalse(fm.fileExists(atPath: vocabulary.path), "The next download must fetch a fresh vocabulary")
            XCTAssertTrue(fm.fileExists(atPath: folder.appendingPathComponent("Encoder.mlmodelc").path),
                          "Repair must keep the large model files")
        }
    }

    func testTooShortAudioGivesAnEmptyTranscriptWithoutTheModel() async throws {
        let root = makeTempRoot("ParakeetShortAudio")
        defer { removeTempRoot(root) }
        // A folder where the vocabulary belongs makes any model access fail at once instead of downloading.
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("models/parakeet-tdt-0.6b-v3/parakeet_vocab.json"), withIntermediateDirectories: true
        )
        let transcriber = LocalTranscriber(downloadBase: root)
        // A recording stopped at once: no samples, or 0.1 s, which FluidAudio rejects as invalid audio.
        for samples in [[Float](), [Float](repeating: 0, count: 1_600)] {
            let audio = MeetingAudio(url: root.appendingPathComponent("audio.m4a")) { _ in samples }
            let segments = try await transcriber.transcribe(
                audioURL: audio.url, audio: audio, settings: SpeechSettings(engine: .parakeet), progressHandler: { _ in }
            )
            XCTAssertEqual(segments, [])
        }
    }

    func testSegmentsSplitOnSentencesAndPauses() throws {
        let timings = [
            TokenTiming(token: "Hello", tokenId: 1, startTime: 0, endTime: 0.5, confidence: 0),
            TokenTiming(token: " world", tokenId: 2, startTime: 0.5, endTime: 1.0, confidence: 0),
            TokenTiming(token: ".", tokenId: 3, startTime: 1.0, endTime: 1.1, confidence: 0),
            TokenTiming(token: " Next", tokenId: 4, startTime: 3.0, endTime: 3.4, confidence: 0),
            TokenTiming(token: " sentence", tokenId: 5, startTime: 3.4, endTime: 3.9, confidence: 0),
        ]
        let result = ASRResult(
            text: "Hello world. Next sentence", confidence: 1, duration: 4, processingTime: 1, tokenTimings: timings
        )
        let segments = LocalTranscriber.segments(from: result)
        XCTAssertEqual(segments.map(\.text), ["Hello world.", "Next sentence"])
        XCTAssertEqual(segments[0].start, 0, accuracy: 0.001)
        XCTAssertEqual(segments[1].start, 3.0, accuracy: 0.001)
    }

    func testSegmentsCapLongUnpunctuatedRuns() throws {
        let timings = (0..<90).map { index in
            TokenTiming(
                token: " word\(index)", tokenId: index,
                startTime: Double(index) * 0.5, endTime: Double(index) * 0.5 + 0.4, confidence: 0
            )
        }
        let result = ASRResult(text: "words", confidence: 1, duration: 45, processingTime: 1, tokenTimings: timings)
        let segments = LocalTranscriber.segments(from: result)
        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments.map { $0.text.split(separator: " ").count }, [40, 40, 10])
    }

    func testParakeetLanguageTagsScriptAndWords() throws {
        XCTAssertEqual(ParakeetLanguage.tag("Привіт, як справи?"), "uk")
        XCTAssertEqual(ParakeetLanguage.tag("Що це таке"), "uk")
        XCTAssertEqual(ParakeetLanguage.tag("Привет, как дела?"), "ru")
        XCTAssertEqual(ParakeetLanguage.tag("Что это такое"), "ru")
        // "ъ" is common in Bulgarian, so it must not make a Bulgarian line Russian.
        XCTAssertNil(ParakeetLanguage.tag("Събранието в България започва утре"))
        XCTAssertEqual(ParakeetLanguage.tag("We should ship this today"), "en")
        XCTAssertNil(ParakeetLanguage.tag("Ок"))
        XCTAssertNil(ParakeetLanguage.tag("Так"))
        XCTAssertNil(ParakeetLanguage.tag("Hallo zusammen"))
        XCTAssertEqual(ParakeetLanguage.tag("So the API is down again"), "en")
        // "was", "to", "is" and "on" are English words too; these lines must not be tagged English.
        XCTAssertNil(ParakeetLanguage.tag("Was machen wir heute?"))
        XCTAssertNil(ParakeetLanguage.tag("To jest dobry plan i termin"))
        XCTAssertNil(ParakeetLanguage.tag("Het is goed, we gaan door"))
        XCTAssertNil(ParakeetLanguage.tag("On va voir demain"))
        XCTAssertEqual(ParakeetLanguage.tagging([
            TranscriptSegment(start: 0, end: 1, text: "Що це таке", language: nil),
            TranscriptSegment(start: 1, end: 2, text: "We should ship this today", language: nil),
        ]).map(\.language), ["uk", "en"])
    }

    func testSegmentsFallBackToWholeTextWithoutTimings() throws {
        let result = ASRResult(text: "  One line  ", confidence: 1, duration: 12, processingTime: 1)
        XCTAssertEqual(LocalTranscriber.segments(from: result).map(\.text), ["One line"])
        let empty = ASRResult(text: " ", confidence: 1, duration: 0, processingTime: 0)
        XCTAssertTrue(LocalTranscriber.segments(from: empty).isEmpty)
    }
}
