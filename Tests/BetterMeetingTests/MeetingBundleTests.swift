import XCTest
@testable import BetterMeetingApp

final class MeetingBundleTests: XCTestCase {
    func testLanguageSharesAndCombinedTimeline() {
        let segments = [
            TranscriptSegment(start: 0, end: 10, text: "Hello", language: "en"),
            TranscriptSegment(start: 20, end: 50, text: "Вітаю", language: "uk")
        ]
        let shares = MeetingBundle.languageShares(segments)
        XCTAssertEqual(shares.map(\.language), ["uk", "en"])
        XCTAssertEqual(shares.map(\.share), [0.75, 0.25])
        XCTAssertTrue(MeetingBundle.languageShares([]).isEmpty)
        let timeline = MeetingBundle.timeline(segments: segments, screens: [ScreenEvent(time: 12, added: ["Pricing"], screenshot: "screens/001.jpg")])
        XCTAssertTrue(timeline.contains("Gap between speech segments: 10 seconds"))
        XCTAssertTrue(timeline.contains("[Screenshot](screens/001.jpg)"))
        XCTAssertTrue(timeline.contains("> Pricing"))
        let gap = timeline.range(of: "Gap between")!.lowerBound
        let screen = timeline.range(of: "Screen:")!.lowerBound
        let ukrainian = timeline.range(of: "Вітаю")!.lowerBound
        XCTAssertTrue(gap < screen && screen < ukrainian)

        let tied = MeetingBundle.timeline(
            segments: [segments[0], TranscriptSegment(start: 0, end: 5, text: "Second", language: "en")],
            screens: [ScreenEvent(time: 0, added: ["Same time"])]
        )
        XCTAssertLessThan(tied.range(of: "Hello")!.lowerBound, tied.range(of: "Second")!.lowerBound)
        XCTAssertLessThan(tied.range(of: "Second")!.lowerBound, tied.range(of: "Screen:")!.lowerBound)
    }

    func testPortableBundleReplacementAndFailurePreserveMeeting() async throws {
        let root = makeTempRoot()
        defer { removeTempRoot(root) }
        let date = Date()
        let folder = try MeetingArtifacts.createDirectory(in: root, title: "Product review", recordedAt: date)
        let video = folder.appendingPathComponent("recording.mp4")
        try await ScreenExtractionTests.makeVideo(at: video)
        let segments = [TranscriptSegment(start: 0, end: 4, text: "Plan", language: "en")]
        try MeetingArtifacts.write(title: "Product review", recordedAt: date, duration: 4, segments: segments, to: folder)
        let markdownURL = folder.appendingPathComponent("transcript.md")
        var markdown = try String(contentsOf: markdownURL, encoding: .utf8)
        markdown += "\nManual correction: release on Tuesday.\n"
        try markdown.write(to: markdownURL, atomically: true, encoding: .utf8)
        let meeting = try XCTUnwrap(MeetingArtifacts.meetings(in: root).first)
        let bundle = try await MeetingBundle.build(for: meeting) { _ in }
        for file in ["transcript.md", "transcript.json", "timeline.md", "screens_index.md", "screen.json", "languages.json", "HOW-TO.md", "PROMPT.md"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.appendingPathComponent(file).path), file)
        }
        let exported = try String(contentsOf: bundle.appendingPathComponent("transcript.md"), encoding: .utf8)
        XCTAssertTrue(exported.contains("Manual correction"))
        XCTAssertFalse(exported.contains("](recording.mp4)"))
        XCTAssertEqual(try String(contentsOf: markdownURL, encoding: .utf8), markdown)
        try Data([1]).write(to: bundle.appendingPathComponent("old-export-marker"))
        _ = try await MeetingBundle.build(for: meeting) { _ in }
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.appendingPathComponent("old-export-marker").path))
        let previous = try Data(contentsOf: bundle.appendingPathComponent("timeline.md"))
        let cancelled = Task {
            try await MeetingBundle.build(for: meeting) { fraction in
                if fraction > 0 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do { _ = try await cancelled.value; XCTFail("Expected cancellation") }
        catch is CancellationError {}
        XCTAssertEqual(try Data(contentsOf: bundle.appendingPathComponent("timeline.md")), previous)
        try Data("Broken video".utf8).write(to: video)
        do { _ = try await MeetingBundle.build(for: meeting) { _ in }; XCTFail("Expected invalid video") }
        catch {}
        XCTAssertEqual(try Data(contentsOf: bundle.appendingPathComponent("timeline.md")), previous)
        XCTAssertEqual(try String(contentsOf: markdownURL, encoding: .utf8), markdown)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: folder.path).contains { $0.hasPrefix(".artifacts-") })
    }
}
