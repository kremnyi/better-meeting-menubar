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

    /// Audio routinely outlasts the last video frame, which stretches the movie past the video track; the
    /// samples there can't decode, and they must not cost the screens that do.
    func testAudioOutlastingVideoStillExtractsScreens() async throws {
        let root = makeTempRoot()
        defer { removeTempRoot(root) }
        let video = root.appendingPathComponent("recording.mp4")
        try await Self.makeVideo(at: video, audioSeconds: 9)
        let asset = AVURLAsset(url: video)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let videoEnd = try await XCTUnwrap(tracks.first).load(.timeRange).end.seconds
        let duration = try await asset.load(.duration).seconds
        XCTAssertGreaterThan(duration, videoEnd + 2, "The fixture must leave samples past the video track")
        let events = try await ScreenExtractor.extract(video: video, to: root, languages: ["en"]) { _ in }
        let text = events.flatMap(\.added).joined(separator: " ").lowercased()
        XCTAssertTrue(text.contains("pricing"), text)
        XCTAssertTrue(text.contains("release"), text)
        XCTAssertEqual(events.compactMap(\.screenshot).count, 2)
    }

    /// Four seconds of video; `audioSeconds` adds a silent audio track of that length.
    static func makeVideo(at url: URL, audioSeconds: Int? = nil) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 960, AVVideoHeightKey: 540
        ])
        let sampleRate = 16_000
        let audio = audioSeconds.map { _ in
            AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1
            ])
        }
        if let audio { writer.add(audio) }
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
        if let audio, let audioSeconds {
            var format = AudioStreamBasicDescription(
                mSampleRate: Double(sampleRate), mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
                mBitsPerChannel: 16, mReserved: 0)
            var description: CMAudioFormatDescription?
            CMAudioFormatDescriptionCreate(allocator: nil, asbd: &format, layoutSize: 0, layout: nil,
                magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description)
            for second in 0..<audioSeconds {
                while !audio.isReadyForMoreMediaData {
                    if let error = writer.error { throw error }
                    try await Task.sleep(for: .milliseconds(10))
                }
                let bytes = sampleRate * 2
                var block: CMBlockBuffer?
                CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes,
                    blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: bytes,
                    flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
                CMBlockBufferFillDataBytes(with: 0, blockBuffer: try XCTUnwrap(block), offsetIntoDestination: 0, dataLength: bytes)
                var sample: CMSampleBuffer?
                CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: try XCTUnwrap(block),
                    formatDescription: try XCTUnwrap(description), sampleCount: sampleRate,
                    presentationTimeStamp: CMTime(value: Int64(second), timescale: 1),
                    packetDescriptions: nil, sampleBufferOut: &sample)
                XCTAssertTrue(audio.append(try XCTUnwrap(sample)))
            }
            audio.markAsFinished()
        }
        writer.endSession(atSourceTime: CMTime(value: Int64(max(4, audioSeconds ?? 0)), timescale: 1))
        await writer.finishWriting()
        if let error = writer.error { throw error }
    }
}
