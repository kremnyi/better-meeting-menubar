import Foundation
import XCTest
@testable import BetterMeetingApp

final class AutomaticTitleTests: XCTestCase {
    private let pricing = "Anna will lead the pricing review. Anna reviewed pricing yesterday. The pricing review needs another look. We should finish the pricing review on Friday."

    func testNamesAndRecurringTopics() {
        XCTAssertEqual(MeetingTitle.suggest(from: pricing), "Anna — Pricing Review")
        XCTAssertEqual(MeetingTitle.suggest(from: "Microsoft discussed the product launch. Microsoft will prepare the product launch. We will review the product launch next week."), "Microsoft — Product Launch")
        XCTAssertEqual(MeetingTitle.suggest(from: "The iPhone needs a battery test. We should repeat the battery test on the iPhone. This iPhone passed the battery test."), "iPhone — Battery Test")
        XCTAssertNil(MeetingTitle.suggest(from: ""))
        XCTAssertNil(MeetingTitle.suggest(from: "Anna called today. We talked about the weather and said goodbye."))
        XCTAssertNil(MeetingTitle.suggest(from: "We discussed the pricing review. We finished the pricing review."))
        XCTAssertNil(MeetingTitle.suggest(from: "Anna will call tomorrow. Anna will call tomorrow."))
    }

    func testUnnamedMeetingCanBeRetriedAndRenamedWithoutLosingFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let date = Date(timeIntervalSince1970: 1_788_530_400)
        let folder = try MeetingArtifacts.createDirectory(in: root, title: " \n ", recordedAt: date)
        let recording = Data("saved recording".utf8)
        try recording.write(to: folder.appendingPathComponent("recording.mp4"))
        let pending = try XCTUnwrap(MeetingArtifacts.meetings(in: root).first)
        XCTAssertFalse(pending.titleWasProvided)
        XCTAssertEqual(pending.title, folder.lastPathComponent)
        XCTAssertFalse(pending.title.contains("Meeting"))
        try MeetingArtifacts.writeMetadata(
            title: pending.title, recordedAt: date, duration: 30,
            titleWasProvided: pending.titleWasProvided, to: folder
        )
        XCTAssertFalse(try XCTUnwrap(MeetingArtifacts.meetings(in: root).first).titleWasProvided)

        let title = try XCTUnwrap(MeetingTitle.suggest(from: pricing))
        let renamed = try MeetingArtifacts.renameDirectory(folder, title: title, recordedAt: date)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertEqual(renamed.lastPathComponent, "\(folder.lastPathComponent) — Anna — Pricing Review")
        XCTAssertEqual(try Data(contentsOf: renamed.appendingPathComponent("recording.mp4")), recording)

        // If writing was interrupted after the move, retry the same folder without adding another suffix.
        let interrupted = try XCTUnwrap(MeetingArtifacts.meetings(in: root).first)
        XCTAssertTrue(interrupted.needsTranscription)
        XCTAssertFalse(interrupted.titleWasProvided)
        let retried = try MeetingArtifacts.renameDirectory(URL(fileURLWithPath: renamed.path), title: title, recordedAt: date)
        XCTAssertEqual(retried.path, renamed.path)

        try MeetingArtifacts.write(
            title: title, recordedAt: date, duration: 30,
            segments: [TranscriptSegment(start: 0, end: 30, text: pricing, language: "en")],
            titleWasProvided: false, to: renamed
        )
        let completed = try XCTUnwrap(MeetingArtifacts.meetings(in: root).first)
        XCTAssertFalse(completed.needsTranscription)
        XCTAssertFalse(completed.titleWasProvided)
        XCTAssertEqual(completed.title, title)
        let markdown = try String(contentsOf: renamed.appendingPathComponent("transcript.md"), encoding: .utf8)
        XCTAssertTrue(markdown.hasPrefix("# Anna — Pricing Review\n"))
        XCTAssertTrue(markdown.contains("[recording.mp4](recording.mp4)"))
    }

    func testDateFallbackManualTitlesAndRenameCollisions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let date = Date(timeIntervalSince1970: 1_788_530_400)
        let unnamed = try MeetingArtifacts.createDirectory(in: root, title: "", recordedAt: date)
        try MeetingArtifacts.write(title: "", recordedAt: date, duration: 0, segments: [], to: unnamed)
        let fallback = try XCTUnwrap(MeetingArtifacts.meetings(in: root).first)
        XCTAssertEqual(fallback.title, unnamed.lastPathComponent)
        XCTAssertFalse(fallback.titleWasProvided)
        XCTAssertTrue(try String(contentsOf: unnamed.appendingPathComponent("transcript.md"), encoding: .utf8)
            .hasPrefix("# \(fallback.title)\n"))

        let existing = try MeetingArtifacts.createDirectory(in: root, title: "Anna — Pricing Review", recordedAt: date)
        try Data("keep me".utf8).write(to: existing.appendingPathComponent("recording.mp4"))
        let destination = try MeetingArtifacts.renameDirectory(unnamed, title: "Anna — Pricing Review", recordedAt: date)
        XCTAssertEqual(destination.lastPathComponent, existing.lastPathComponent + " 2")
        XCTAssertEqual(try Data(contentsOf: existing.appendingPathComponent("recording.mp4")), Data("keep me".utf8))

        let manual = try MeetingArtifacts.createDirectory(in: root, title: "Meeting", recordedAt: date)
        try MeetingArtifacts.write(title: "Meeting", recordedAt: date, duration: 0, segments: [], to: manual)
        let manualItem = try XCTUnwrap(MeetingArtifacts.meetings(in: root).first { $0.title == "Meeting" })
        XCTAssertEqual(manualItem.folderURL.resolvingSymlinksInPath().path, manual.resolvingSymlinksInPath().path)
        XCTAssertTrue(manualItem.titleWasProvided, "An explicitly typed 'Meeting' must not be treated as unnamed")
        XCTAssertEqual(manualItem.title, "Meeting")
    }

    func testLongUnicodeFolderNamesKeepTitlesAndHandleCollisions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let date = Date()
        let emoji = "👨‍👩‍👧‍👦"
        let title = String(repeating: emoji, count: 40)
        let folder = try MeetingArtifacts.createDirectory(in: root, title: title, recordedAt: date)
        let duplicate = try MeetingArtifacts.createDirectory(in: root, title: title, recordedAt: date)
        XCTAssertLessThanOrEqual(folder.lastPathComponent.utf8.count, 255)
        XCTAssertTrue(folder.lastPathComponent.hasSuffix(emoji), "Do not split a compound character")
        XCTAssertEqual(duplicate.lastPathComponent, folder.lastPathComponent + " 2")
        try MeetingArtifacts.write(title: title, recordedAt: date, duration: 0, segments: [], to: folder)
        let meeting = try XCTUnwrap(MeetingArtifacts.meetings(in: root).first)
        XCTAssertEqual(meeting.title, title, "Only the folder name should be shortened")
        let renamedTitle = String(repeating: "🧑🏽‍💻", count: 50)
        let renamed = try MeetingArtifacts.renameMeeting(meeting, to: renamedTitle)
        XCTAssertLessThanOrEqual(renamed.lastPathComponent.utf8.count, 255)
        XCTAssertEqual(try XCTUnwrap(MeetingArtifacts.meetings(in: root).first).title, renamedTitle)
        XCTAssertTrue(try String(contentsOf: renamed.appendingPathComponent("transcript.md"), encoding: .utf8)
            .hasPrefix("# " + renamedTitle + "\n"))
        XCTAssertEqual(try MeetingArtifacts.renameDirectory(renamed, title: renamedTitle, recordedAt: date), renamed)
    }
}
