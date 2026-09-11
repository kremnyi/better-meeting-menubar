import XCTest
@testable import BetterMeetingApp

final class SpeakerLabelsTests: XCTestCase {
    private enum Failure: Error { case detection }

    func testDisabledAndLegacySettingsKeepOriginalTranscript() async throws {
        var settings = SpeechSettings()
        settings.temperature = 0.3
        let data = try JSONEncoder().encode(settings)
        let legacy = try JSONDecoder().decode(SpeechSettings.self, from: data)
        XCTAssertFalse(legacy.speakerLabels == true)
        XCTAssertEqual(legacy.temperature, 0.3)
        let segments = try JSONDecoder().decode([TranscriptSegment].self, from: Data(
            #"[{"start":0,"end":2,"text":"Hello","language":"en"}]"#.utf8
        ))
        XCTAssertNil(segments[0].speaker)
        let result = try await SpeakerLabels.run(
            audioURL: URL(fileURLWithPath: "/nonexistent/audio.m4a"), segments: segments, enabled: false
        ) {
            XCTFail("Disabled labels must not load audio, download models, or run detection")
            throw Failure.detection
        }
        XCTAssertEqual(result, segments)
    }

    func testAssignmentPreservesTextAndHandlesGapsAndTies() {
        let segments = (0..<4).map {
            TranscriptSegment(start: Double($0 * 2), end: Double($0 * 2 + 2), text: "Line \($0)", language: "uk")
        }
        let turns: [SpeakerLabels.Turn] = [
            .init(start: 0, end: 1, speaker: 0), .init(start: 1, end: 2, speaker: 0),
            .init(start: 2, end: 4, speaker: 1),
            .init(start: 6, end: 8, speaker: 0), .init(start: 6, end: 8, speaker: 1)
        ]
        let labeled = SpeakerLabels.assign(turns, to: segments)
        XCTAssertEqual(labeled.map(\.speaker), [0, 1, nil, nil])
        XCTAssertEqual(labeled.map(\.text), segments.map(\.text))
        XCTAssertEqual(labeled.map(\.language), segments.map(\.language))
        let markdown = MeetingArtifacts.transcriptMarkdown(title: "Test", recordedAt: Date(), duration: 8, segments: labeled)
        XCTAssertTrue(markdown.contains("[00:00:02] [uk] Speaker 2: Line 1"))
        XCTAssertTrue(MeetingBundle.timeline(segments: labeled, screens: []).contains("Speech [uk] (Speaker 2): Line 1"))
        XCTAssertEqual(try? JSONDecoder().decode([TranscriptSegment].self, from: JSONEncoder().encode(labeled)), labeled)
    }

    func testCacheReuseInvalidationAndFailedDetection() async throws {
        let folder = makeTempRoot()
        defer { removeTempRoot(folder) }
        let audio = folder.appendingPathComponent("audio.m4a")
        let cache = folder.appendingPathComponent("speaker_turns.json")
        try Data([1]).write(to: audio)
        let segments = [TranscriptSegment(start: 0, end: 2, text: "Hello", language: "en")]
        let turns = [SpeakerLabels.Turn(start: 0, end: 2, speaker: 0)]
        let first = try await SpeakerLabels.run(audioURL: audio, segments: segments, enabled: true) { turns }
        XCTAssertEqual(first.first?.speaker, 0)
        let cached = try await SpeakerLabels.run(audioURL: audio, segments: segments, enabled: true) {
            XCTFail("Matching audio must reuse saved speaker turns")
            throw Failure.detection
        }
        XCTAssertEqual(first, cached)
        let originalCache = try Data(contentsOf: cache)
        try Data([1, 2]).write(to: audio)
        do {
            _ = try await SpeakerLabels.run(audioURL: audio, segments: segments, enabled: true) { throw Failure.detection }
            XCTFail("Changed audio must rerun detection")
        } catch Failure.detection {}
        XCTAssertEqual(try Data(contentsOf: cache), originalCache)
        let updated = try await SpeakerLabels.run(audioURL: audio, segments: segments, enabled: true) {
            [.init(start: 0, end: 2, speaker: 1)]
        }
        XCTAssertEqual(updated.first?.speaker, 1)
        try Data("broken cache".utf8).write(to: cache)
        let repaired = try await SpeakerLabels.run(audioURL: audio, segments: segments, enabled: true) { turns }
        XCTAssertEqual(repaired, first)
        try FileManager.default.removeItem(at: cache)
        let task = Task {
            try await SpeakerLabels.run(audioURL: audio, segments: segments, enabled: true) {
                withUnsafeCurrentTask { $0?.cancel() }
                return turns
            }
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled detection must not publish a cache")
        } catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
    }

    func testRealSpeakerDetection() async throws {
        guard let path = ProcessInfo.processInfo.environment["BETTER_MEETING_SPEAKER_CHECK"] else {
            throw XCTSkip("Set BETTER_MEETING_SPEAKER_CHECK to disposable speech audio for local model verification")
        }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/speaker-check")
        let turns = try await SpeakerLabels.detect(audioURL: URL(fileURLWithPath: path), downloadBase: root) { _ in }
        XCTAssertFalse(turns.isEmpty)
        XCTAssertTrue(turns.allSatisfy(\.isValid))
        print("Speaker check: \(Set(turns.map(\.speaker)).count) speakers, \(turns.count) turns")
    }
}
