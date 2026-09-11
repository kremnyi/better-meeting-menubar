import AVFoundation
import CoreText
import XCTest
@testable import BetterMeetingApp

final class ScreenExtractionTests: XCTestCase {
    func testChangedScreensAndTextDeduplication() {
        let original = [UInt8](repeating: 50, count: 256)
        XCTAssertTrue(ScreenExtractor.shouldKeep(original, previous: nil, gap: 0))
        XCTAssertFalse(ScreenExtractor.shouldKeep(original, previous: original, gap: 2))
        XCTAssertTrue(ScreenExtractor.shouldKeep(original, previous: original, gap: 90))
        var changed = original
        changed[8] = 120
        XCTAssertTrue(ScreenExtractor.shouldKeep(changed, previous: original, gap: 2))
        XCTAssertEqual(ScreenExtractor.addedLines([" PRICING   REVIEW ", "New plan", "New plan"], previous: ["Pricing review"]), ["New plan"])
        let events = (0..<100).map { ScreenEvent(time: Double($0 * 2), added: []) }
        let selected = ScreenExtractor.selectedIndices(in: events, duration: 200, limit: 30)
        XCTAssertEqual(Set(selected).count, 30)
        XCTAssertGreaterThan(selected.last ?? 0, 90)
    }

    func testRealVideoFrameExtractionAndVisionOCR() async throws {
        let root = makeTempRoot()
        defer { removeTempRoot(root) }
        let video = root.appendingPathComponent("recording.mp4")
        try await Self.makeVideo(at: video)
        let events = try await ScreenExtractor.extract(video: video, to: root, languages: ["en", "uk"]) { _ in }
        let text = events.flatMap(\.added).joined(separator: " ").lowercased()
        XCTAssertTrue(text.contains("pricing"), text)
        XCTAssertTrue(text.contains("release"), text)
        XCTAssertEqual(events.compactMap(\.screenshot).count, 2)
        for event in events {
            if let screenshot = event.screenshot {
                XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(screenshot).path))
            }
        }
        XCTAssertTrue(events.allSatisfy { $0.time >= 0 && $0.time < 4 })
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ScreenExtractor.extract(video: video, to: root.appendingPathComponent("cancelled"), languages: ["en"]) { _ in }
        }
        do { _ = try await cancelled.value; XCTFail("Expected cancellation") }
        catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("cancelled").path))
    }

    static func makeVideo(at url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 960, AVVideoHeightKey: 540
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 960, kCVPixelBufferHeightKey as String: 540,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for index in 0..<4 {
            while !input.isReadyForMoreMediaData {
                if let error = writer.error { throw error }
                try await Task.sleep(for: .milliseconds(10))
            }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &buffer)
            let pixels = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            let context = try XCTUnwrap(CGContext(data: CVPixelBufferGetBaseAddress(pixels), width: 960, height: 540,
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixels), space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue))
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 960, height: 540))
            context.setFillColor(CGColor(gray: index < 2 ? 0.2 : 0.7, alpha: 1))
            context.fill(CGRect(x: 0, y: 300, width: 960, height: 240))
            let title = NSAttributedString(string: index < 2 ? "Pricing review" : "Release schedule", attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 60, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
            ])
            context.textPosition = CGPoint(x: 80, y: 120)
            CTLineDraw(CTLineCreateWithAttributedString(title), context)
            CVPixelBufferUnlockBaseAddress(pixels, [])
            XCTAssertTrue(adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(index), timescale: 1)))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 4, timescale: 1))
        await writer.finishWriting()
        if let error = writer.error { throw error }
    }
}
