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

    func testSettingsWithoutEngineUseParakeetButSavedMeetingsKeepWhisper() throws {
        let legacy = """
        {"model":"openai_whisper-small","temperature":0,"fallbackCount":5,"fallbackIncrement":0.2,
         "noSpeechThreshold":0.6,"logProbThreshold":-1,"compressionRatioThreshold":2.4,"speakerLabels":true}
        """
        let settings = try JSONDecoder().decode(SpeechSettings.self, from: Data(legacy.utf8))
        XCTAssertNil(settings.engine)
        XCTAssertEqual(settings.selectedEngine, .parakeet)
        XCTAssertFalse(settings.usesWhisperOptions)
        XCTAssertEqual(settings.model, .small)
        XCTAssertEqual(settings.withResolvedEngine.engine, .parakeet, "New meetings record the engine that ran")
        let folder = makeTempRoot()
        defer { removeTempRoot(folder) }
        try MeetingArtifacts.writeMetadata(title: "Old", recordedAt: Date(), duration: 60, speechSettings: settings, to: folder)
        XCTAssertEqual(MeetingArtifacts.speechSettings(in: folder)?.engine, .whisper,
                       "Meetings saved without an engine were transcribed by Whisper")
    }

    @MainActor
    func testSavedLanguagesParakeetLacksKeepWhisper() throws {
        let (defaults, suite, root) = try makeTempDefaults("SpeechSettingsLanguages")
        defer { removeTempDefaults(defaults, suite: suite, root: root) }
        defaults.set(["ja", "en"], forKey: "transcriptionLanguages")
        XCTAssertEqual(AppModel(defaults: defaults).speechSettings.engine, .whisper)
        XCTAssertEqual(AppModel(defaults: defaults).speechSettings.engine, .whisper, "The choice is saved")
        defaults.removeObject(forKey: "speechSettings")
        defaults.set(["uk", "ru", "en"], forKey: "transcriptionLanguages")
        XCTAssertEqual(AppModel(defaults: defaults).speechSettings.selectedEngine, .parakeet)
    }

    func testEngineSwitchKeepsCompletedWhisperPasses() async throws {
        let folder = makeTempRoot()
        defer { removeTempRoot(folder) }
        let audio = folder.appendingPathComponent("audio.m4a")
        try Data([1]).write(to: audio)
        var settings = SpeechSettings()
        var runs = 0
        for engine: TranscriptionEngine in [.whisper, .parakeet] {
            settings.engine = engine
            _ = try await TranscriptionPasses.run(
                audioURL: audio, languages: ["en"], settings: settings, progressHandler: { _ in }
            ) { _, _ in
                runs += 1
                return []
            }
        }
        XCTAssertEqual(runs, 1, "Switching engines must not invalidate completed Whisper passes")
    }

    @MainActor
    func testSettingsPersistWithDefaultsAndMeeting() throws {
        let (defaults, suite, root) = try makeTempDefaults("SpeechSettings")
        defer { removeTempDefaults(defaults, suite: suite, root: root) }
        let model = AppModel(defaults: defaults)
        XCTAssertEqual(model.speechSettings.model, .turbo)
        XCTAssertEqual(model.speechSettings.selectedEngine, .parakeet)
        XCTAssertFalse(model.speechSettings.speakerLabels == true)
        model.speechSettings.speakerLabels = true
        model.speechSettings.engine = .parakeet
        model.speechSettings.model = .large
        model.speechSettings.noSpeechThreshold = 0.7
        XCTAssertEqual(AppModel(defaults: defaults).speechSettings, model.speechSettings)
        let date = Date()
        let folder = try MeetingArtifacts.createDirectory(in: root, title: "Options", recordedAt: date)
        XCTAssertNil(MeetingArtifacts.speechSettings(in: folder))
        try MeetingArtifacts.write(title: "Options", recordedAt: date, duration: 1, segments: [], speechSettings: model.speechSettings, to: folder)
        XCTAssertEqual(MeetingArtifacts.speechSettings(in: folder), model.speechSettings)
        let meeting = try XCTUnwrap(MeetingLibrary().meetings(in: root).first)
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
