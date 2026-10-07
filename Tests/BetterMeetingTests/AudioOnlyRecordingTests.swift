import AVFoundation
import os
import ScreenCaptureKit
import XCTest
@testable import BetterMeetingApp

final class AudioOnlyRecordingTests: XCTestCase {
    func testBothSourcesRemainAudibleAndAudioOnlyMeetingExports() async throws {
        let root = makeTempRoot()
        defer { removeTempRoot(root) }
        let date = Date()
        let folder = try MeetingArtifacts.createDirectory(in: root, title: "Audio meeting", recordedAt: date)
        let recording = folder.appendingPathComponent("recording.mov")
        // Delay readiness, not the resulting audio: the real writer must preserve
        // both signals and timestamps after the encoder becomes available again.
        let readyAt = ContinuousClock.now.advanced(by: .seconds(1))
        let capture = DispatchQueue(label: "capture")
        let writer = try AudioOnlyRecording(to: recording, queue: capture,
            isReady: { ContinuousClock.now >= readyAt && $0.isReadyForMoreMediaData }) { _ in }
        // Burst delivery exercises encoder pressure at startup and stop;
        // the middle runs at capture cadence, with system sound before the mic.
        for index in 0..<75 {
            let time = Double(index) * 0.02
            if index < 60 { let buffer = try sample(at: time, frequency: 440, channels: 2); capture.sync { writer.append(buffer, type: .audio) } }
            if index >= 15 { let buffer = try sample(at: time, frequency: 880, channels: 1, rate: 44_100); capture.sync { writer.append(buffer, type: .microphone) } }
            if (35..<60).contains(index) { try await Task.sleep(for: .milliseconds(20)) }
        }
        try await writer.finish()
        let asset = AVURLAsset(url: recording)
        let video = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertTrue(video.isEmpty, "Audio-only must not persist screen frames")
        XCTAssertEqual(audioTracks.count, 2)
        XCTAssertTrue(try XCTUnwrap(MeetingLibrary().meetings(in: root).first).needsTranscription,
                      "The original audio must remain recoverable before extraction")
        let audioURL = folder.appendingPathComponent("audio.m4a")
        try await AudioExtractor.extract(from: recording, to: audioURL) { _ in }
        let audio = try AVAudioFile(forReading: audioURL)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length)))
        try audio.read(into: buffer)
        let samples = try XCTUnwrap(buffer.floatChannelData)[0]
        let rate = buffer.format.sampleRate
        XCTAssertEqual(Double(buffer.frameLength) / rate, 1.5, accuracy: 0.06)
        XCTAssertGreaterThan(amplitude(samples, rate: rate, frequency: 440, from: 0.6, to: 1), 0.07)
        XCTAssertGreaterThan(amplitude(samples, rate: rate, frequency: 880, from: 0.6, to: 1), 0.07,
                             "Export must mix the microphone instead of selecting only system audio")
        XCTAssertLessThan(amplitude(samples, rate: rate, frequency: 880, from: 0.1, to: 0.2), 0.02,
                          "A late microphone must keep its original time offset")
        let segments = [TranscriptSegment(start: 0, end: 1.5, text: "Audio meeting", language: "en")]
        try MeetingArtifacts.write(title: "Audio meeting", recordedAt: date, duration: 1.5, segments: segments, to: folder)
        var meeting = try XCTUnwrap(MeetingLibrary().meetings(in: root).first)
        try MeetingArtifacts.replaceTranscript(for: meeting, duration: 1.5, segments: segments)
        let markdown = try String(contentsOf: folder.appendingPathComponent("transcript.md"), encoding: .utf8)
        XCTAssertTrue(markdown.contains("[recording.mov](recording.mov)"))
        meeting = try XCTUnwrap(MeetingLibrary().meetings(in: root).first)
        let bundle = try await MeetingBundle.build(for: meeting) { _ in }
        let screens = try JSONDecoder().decode([ScreenEvent].self, from: Data(contentsOf: bundle.appendingPathComponent("screen.json")))
        XCTAssertTrue(screens.isEmpty)
        let exported = try String(contentsOf: bundle.appendingPathComponent("transcript.md"), encoding: .utf8)
        XCTAssertFalse(exported.contains("](recording.mov)"))
        XCTAssertTrue(exported.contains("Audio meeting"))
        try FileManager.default.removeItem(at: recording)
        let audioBundle = try await MeetingBundle.build(for: meeting) { _ in }
        let audioExport = try String(contentsOf: audioBundle.appendingPathComponent("transcript.md"), encoding: .utf8)
        XCTAssertFalse(audioExport.contains("](recording.mov)"), "Remaining mixed audio must not leave a broken video link")
        let audioGuide = try String(contentsOf: audioBundle.appendingPathComponent("HOW-TO.md"), encoding: .utf8)
        XCTAssertTrue(audioGuide.contains("Screen video is unavailable"))
        XCTAssertFalse(audioGuide.contains("audio-only meeting"), "The fallback audio does not establish the original capture mode")
    }

    func testProlongedEncoderStallStopsExplicitlyAndKeepsWrittenAudio() async throws {
        let root = makeTempRoot()
        defer { removeTempRoot(root) }
        let url = root.appendingPathComponent("stalled.mov")
        let blocked = OSAllocatedUnfairLock(initialState: false)
        let capture = DispatchQueue(label: "capture")
        let writer = try AudioOnlyRecording(to: url, queue: capture,
            isReady: { input in !blocked.withLock { $0 } && input.isReadyForMoreMediaData }) { _ in }
        for index in 0..<25 {
            let buffer = try sample(at: Double(index) * 0.02, frequency: 440, channels: 1)
            capture.sync { writer.append(buffer, type: .audio) }
            try await Task.sleep(for: .milliseconds(20))
        }
        blocked.withLock { $0 = true }
        let late = try sample(at: 0.5, frequency: 440, channels: 1)
        capture.sync { writer.append(late, type: .audio) }
        let waitingSince = ContinuousClock.now
        do {
            try await writer.finish()
            XCTFail("A prolonged encoder stall must be reported, not silently omit queued audio")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("encoder could not keep up"))
        }
        XCTAssertGreaterThan(waitingSince.duration(to: .now), .seconds(1), "Temporary pressure must be given time to recover")
        XCTAssertLessThan(waitingSince.duration(to: .now), .seconds(5), "Stopping must not wait indefinitely for an encoder")
        let audioURL = root.appendingPathComponent("stalled.m4a")
        try await AudioExtractor.extract(from: url, to: audioURL) { _ in }
        let audio = try AVAudioFile(forReading: audioURL)
        XCTAssertEqual(Double(audio.length) / audio.processingFormat.sampleRate, 0.5, accuracy: 0.06,
                       "The media written before the stall remains recoverable")
    }

    func testEitherSourceCanRecordWhenTheOtherSendsNoBuffers() async throws {
        let root = makeTempRoot()
        defer { removeTempRoot(root) }
        let capture = DispatchQueue(label: "capture")
        for source: SCStreamOutputType in [.microphone, .audio] {
            let url = root.appendingPathComponent("\(source.rawValue).mov")
            let writer = try AudioOnlyRecording(to: url, queue: capture) { _ in }
            for index in 0..<20 {
                let buffer = try sample(at: Double(index) * 0.02, frequency: 440, channels: 1)
                capture.sync { writer.append(buffer, type: source) }
                try await Task.sleep(for: .milliseconds(20))
            }
            try await writer.finish()
            let audioURL = root.appendingPathComponent("\(source.rawValue).m4a")
            try await AudioExtractor.extract(from: url, to: audioURL) { _ in }
            let audio = try AVAudioFile(forReading: audioURL)
            XCTAssertEqual(Double(audio.length) / audio.processingFormat.sampleRate, 0.4, accuracy: 0.06)
        }
    }

    func testStoppingBeforeAnyAudioDoesNotBlameTheDrive() async throws {
        let root = makeTempRoot()
        defer { removeTempRoot(root) }
        let writer = try AudioOnlyRecording(to: root.appendingPathComponent("empty.mov"), queue: DispatchQueue(label: "capture")) { _ in }
        do {
            try await writer.finish()
            XCTFail("A recording without audio must not finish as a saved file")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("No audio was captured"), error.localizedDescription)
            XCTAssertFalse(error.localizedDescription.contains("recording drive"),
                           "An instant stop is not a storage failure")
        }
    }

    private func sample(at time: Double, frequency: Double, channels: AVAudioChannelCount, rate: Double = 48_000) throws -> CMSampleBuffer {
        let frames = Int(rate * 0.02)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let data = try XCTUnwrap(buffer.floatChannelData)
        for channel in 0..<Int(channels) {
            for frame in 0..<frames {
                data[channel][frame] = Float(0.2 * sin(2 * .pi * frequency * (time + Double(frame) / rate)))
            }
        }
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMAudioSampleBufferCreateWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: format.formatDescription,
            sampleCount: frames, presentationTimeStamp: CMTime(seconds: time, preferredTimescale: Int32(rate)),
            packetDescriptions: nil, sampleBufferOut: &sample
        ), noErr)
        let result = try XCTUnwrap(sample)
        XCTAssertEqual(CMSampleBufferSetDataBufferFromAudioBufferList(result, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: buffer.audioBufferList), noErr)
        return result
    }

    private func amplitude(_ samples: UnsafePointer<Float>, rate: Double, frequency: Double,
                           from start: Double, to end: Double) -> Double {
        let range = Int(start * rate)..<Int(end * rate)
        var real = 0.0, imaginary = 0.0
        for index in range {
            let phase = 2 * Double.pi * frequency * Double(index) / rate
            real += Double(samples[index]) * cos(phase)
            imaginary += Double(samples[index]) * sin(phase)
        }
        return 2 * hypot(real, imaginary) / Double(range.count)
    }
}
