import XCTest
@testable import BetterMeetingApp

final class SpeechSettingsTests: XCTestCase {
    func testModelAndDecodingChangesInvalidatePasses() async throws {
        let folder = makeTempRoot()
        defer { removeTempRoot(folder) }
        let audio = folder.appendingPathComponent("audio.m4a")
        try Data([1]).write(to: audio)
        var settings = SpeechSettings()
        for index in 0..<4 {
            if index == 1 { settings.speakerLabels = true }
            if index == 2 { settings.model = .small }
            if index == 3 { settings.temperature = 0.3; settings.fallbackCount = 2 }
            var ran = false
            _ = try await TranscriptionPasses.run(audioURL: audio, languages: ["en"], settings: settings, progressHandler: { _ in }) { options, _ in
                ran = true
                XCTAssertEqual(options.temperature, settings.temperature)
                XCTAssertEqual(options.temperatureFallbackCount, settings.fallbackCount)
                return []
            }
            XCTAssertEqual(ran, index != 1)
        }
        let segment = ScoredSegment(start: 0, end: 2, text: "Noise", lang: "en", score: -1.2, nospeech: 0.5)
        XCTAssertEqual(TranscriptionPasses.merge([segment]).count, 1)
        XCTAssertTrue(TranscriptionPasses.merge([segment], noSpeechThreshold: 0.4).isEmpty)
    }

    func testActualModelSwitching() async throws {
        guard let path = ProcessInfo.processInfo.environment["BETTER_MEETING_MODEL_SWITCH_CHECK"] else {
            throw XCTSkip("Set BETTER_MEETING_MODEL_SWITCH_CHECK to disposable English audio to check all three models")
        }
        let cache = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/model-check")
        let transcriber = LocalTranscriber(downloadBase: cache)
        let audio = URL(fileURLWithPath: path)
        for model in SpeechModel.allCases + [.small] {
            var settings = SpeechSettings()
            settings.model = model
            settings.fallbackCount = 0
            let segments = try await transcriber.transcribe(audioURL: audio, languages: ["en"], hints: "Anna, pricing, release", settings: settings) { _ in }
            let text = segments.map(\.text).joined(separator: " ").lowercased()
            XCTAssertTrue(text.contains("pricing"), "\(model.label): \(text)")
            XCTAssertTrue(segments.allSatisfy { $0.language == "en" && $0.end > $0.start })
            XCTAssertNotNil(LocalTranscriber.cachedModelFolder(in: cache, model: model))
        }
    }

    @MainActor
    func testSettingsPersistWithDefaultsAndMeeting() throws {
        let (defaults, suite, root) = try makeTempDefaults("SpeechSettings")
        defer { removeTempDefaults(defaults, suite: suite, root: root) }
        let model = AppModel(defaults: defaults)
        XCTAssertEqual(model.speechSettings.model, .turbo)
        XCTAssertFalse(model.speechSettings.speakerLabels == true)
        model.speechSettings.speakerLabels = true
        model.speechSettings.model = .large
        model.speechSettings.noSpeechThreshold = 0.7
        XCTAssertEqual(AppModel(defaults: defaults).speechSettings, model.speechSettings)
        let date = Date()
        let folder = try MeetingArtifacts.createDirectory(in: root, title: "Options", recordedAt: date)
        XCTAssertNil(MeetingArtifacts.speechSettings(in: folder))
        try MeetingArtifacts.write(title: "Options", recordedAt: date, duration: 1, segments: [], speechSettings: model.speechSettings, to: folder)
        XCTAssertEqual(MeetingArtifacts.speechSettings(in: folder), model.speechSettings)
        let meeting = try XCTUnwrap(MeetingArtifacts.meetings(in: root).first)
        var changed = model.speechSettings
        changed.model = .small
        try MeetingArtifacts.replaceTranscript(for: meeting, duration: 1, segments: [], speechSettings: changed)
        XCTAssertEqual(MeetingArtifacts.speechSettings(in: folder), changed)
        changed.temperature = .nan
        XCTAssertThrowsError(try changed.validate())
        changed.temperature = .infinity
        XCTAssertThrowsError(try changed.validate())
        changed.temperature = 0
        changed.fallbackCount = -1
        XCTAssertThrowsError(try changed.validate())
    }
}
