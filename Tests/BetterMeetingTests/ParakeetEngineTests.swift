import FluidAudio
import XCTest
@testable import BetterMeetingApp

final class ParakeetEngineTests: XCTestCase {
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
        XCTAssertNil(segments[0].language)
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

    func testSegmentsFallBackToWholeTextWithoutTimings() throws {
        let result = ASRResult(text: "  One line  ", confidence: 1, duration: 12, processingTime: 1)
        XCTAssertEqual(LocalTranscriber.segments(from: result).map(\.text), ["One line"])
        let empty = ASRResult(text: " ", confidence: 1, duration: 0, processingTime: 0)
        XCTAssertTrue(LocalTranscriber.segments(from: empty).isEmpty)
    }
}
