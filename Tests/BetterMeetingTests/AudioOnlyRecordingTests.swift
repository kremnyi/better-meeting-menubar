import Accelerate
import AVFoundation
import IOKit.pwr_mgt
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
        // Delay readiness only; the writer must keep both signals and their timestamps once the encoder is ready again.
        let readyAt = ContinuousClock.now.advanced(by: .seconds(1))
        let capture = DispatchQueue(label: "capture")
        let writer = try AudioOnlyRecording(to: recording, queue: capture,
            isReady: { ContinuousClock.now >= readyAt && $0.isReadyForMoreMediaData }) { _ in }
        // Bursts at start and stop stress the encoder; the middle runs at capture cadence, system sound before the mic.
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
        // Transcription may read the recording or its m4a, so both must give the same samples, also with a disabled mic track.
        let movie = AVMutableMovie(url: recording)
        try XCTUnwrap(movie.tracks(withMediaType: .audio).last).isEnabled = false
        let disabled = root.appendingPathComponent("disabled.mov")
        try movie.writeHeader(to: disabled, fileType: .mov, options: .addMovieHeaderToDestination)
        let disabledAudio = root.appendingPathComponent("disabled.m4a")
        try await AudioExtractor.extract(from: disabled, to: disabledAudio) { _ in }
        var levels: [Double] = []
        for (source, exported) in [(recording, audioURL), (disabled, disabledAudio)] {
            let direct = try await MeetingAudio(url: source).load()
            let loaded = try await MeetingAudio(url: exported).load()
            XCTAssertEqual(direct.count, loaded.count, accuracy: 160, source.lastPathComponent)
            let rms = { (samples: [Float]) in Double(vDSP.rootMeanSquare(samples)) }
            XCTAssertEqual(rms(direct), rms(loaded), accuracy: 0.05 * rms(loaded), source.lastPathComponent)
            levels.append(rms(loaded))
        }
        XCTAssertNotEqual(levels[0], levels[1], accuracy: 0.05 * levels[0], "The fixture must exclude the disabled track")
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
            isReady: { input in !blocked.withLock { $0 } && input.isReadyForMoreMediaData },
            stallLimit: .milliseconds(300)) { _ in }
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
        XCTAssertGreaterThanOrEqual(waitingSince.duration(to: .now), .milliseconds(300), "Temporary pressure must be given time to recover")
        let audioURL = root.appendingPathComponent("stalled.m4a")
        try await AudioExtractor.extract(from: url, to: audioURL) { _ in }
        let audio = try AVAudioFile(forReading: audioURL)
        XCTAssertEqual(Double(audio.length) / audio.processingFormat.sampleRate, 0.5, accuracy: 0.06,
                       "The media written before the stall remains recoverable")
    }

    @MainActor
    func testFailedStopKeepsTheAudioOnlyRecording() async throws {
        struct StopFailure: Error {}
        let root = makeTempRoot()
        defer { removeTempRoot(root) }
        let url = root.appendingPathComponent("recording.mov")
        let recorder = MeetingRecorder()
        recorder.startCapture = { _ in }
        recorder.stopCapture = { _ in throw StopFailure() }
        let stream = SCStream(filter: SCContentFilter(), configuration: SCStreamConfiguration(), delegate: nil)
        try await recorder.begin(stream, to: url, microphone: nil, mode: .audioOnly)
        for index in 0..<25 {
            let buffer = try sample(at: Double(index) * 0.02, frequency: 440, channels: 2)
            recorder.audioQueue.sync { recorder.stream(stream, didOutputSampleBuffer: buffer, of: .audio) }
            try await Task.sleep(for: .milliseconds(20))
        }
        do {
            try await recorder.stop().value
            XCTFail("A failed stop must be reported")
        } catch is StopFailure {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "A failed stop must not delete the recording")
        let audioURL = root.appendingPathComponent("recording.m4a")
        try await AudioExtractor.extract(from: url, to: audioURL) { _ in }
        let audio = try AVAudioFile(forReading: audioURL)
        XCTAssertEqual(Double(audio.length) / audio.processingFormat.sampleRate, 0.5, accuracy: 0.06,
                       "The audio recorded before a failed stop must be kept")
    }

    @MainActor
    func testScreenStartWithoutOutputCallbackFailsAndReleasesCapture() async throws {
        let root = makeTempRoot()
        defer { removeTempRoot(root) }
        // The output never reports in, whether startCapture returns or never does.
        let starts: [(SCStream) async throws -> Void] = [{ _ in }, { _ in try await Task.sleep(for: .seconds(3600)) }]
        for startCapture in starts {
            let recorder = MeetingRecorder()
            recorder.callbackTimeout = .milliseconds(200)
            recorder.startCapture = startCapture
            let captureStopped = expectation(description: "the stream is stopped")
            recorder.stopCapture = { _ in captureStopped.fulfill() }
            let before = idleSleepAssertions()
            let stream = SCStream(filter: SCContentFilter(), configuration: SCStreamConfiguration(), delegate: nil)
            do {
                try await recorder.begin(stream, to: root.appendingPathComponent("recording.mp4"), microphone: nil, mode: .screen)
                XCTFail("A start that never reports must fail")
            } catch RecorderError.startTimedOut {}
            await fulfillment(of: [captureStopped], timeout: 5)
            XCTAssertEqual(idleSleepAssertions(), before, "A failed start must let the Mac sleep again")
            XCTAssertNil(recorder.recordingOutput)
        }
    }

    @MainActor
    func testLateResultOfATimedOutStartDoesNotSettleTheNextStart() async throws {
        let root = makeTempRoot()
        defer { removeTempRoot(root) }
        let recorder = MeetingRecorder()
        recorder.callbackTimeout = .milliseconds(300)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        recorder.startCapture = { _ in
            // Only the first start is slow; it succeeds after its own timeout.
            if calls.withLock({ $0 += 1; return $0 }) == 1 { try await Task.sleep(for: .milliseconds(450)) }
        }
        recorder.stopCapture = { _ in }
        let first = SCStream(filter: SCContentFilter(), configuration: SCStreamConfiguration(), delegate: nil)
        do {
            try await recorder.begin(first, to: root.appendingPathComponent("first.mov"), microphone: nil, mode: .audioOnly)
            XCTFail("A slow start must time out")
        } catch RecorderError.startTimedOut {}
        // A screen start settles only on its output callback, which never comes here.
        recorder.callbackTimeout = .seconds(1)
        let second = SCStream(filter: SCContentFilter(), configuration: SCStreamConfiguration(), delegate: nil)
        do {
            try await recorder.begin(second, to: root.appendingPathComponent("second.mp4"), microphone: nil, mode: .screen)
            XCTFail("The earlier start finishing late must not start this one")
        } catch RecorderError.startTimedOut {}
    }

    @MainActor
    func testAudioOnlyStopThatNeverFinishesFailsAndKeepsTheFile() async throws {
        let root = makeTempRoot()
        defer { removeTempRoot(root) }
        let url = root.appendingPathComponent("recording.mov")
        let recorder = MeetingRecorder()
        recorder.callbackTimeout = .milliseconds(200)
        recorder.startCapture = { _ in }
        recorder.stopCapture = { _ in }
        let stream = SCStream(filter: SCContentFilter(), configuration: SCStreamConfiguration(), delegate: nil)
        try await recorder.begin(stream, to: url, microphone: nil, mode: .audioOnly)
        for index in 0..<5 {
            let buffer = try sample(at: Double(index) * 0.02, frequency: 440, channels: 2)
            recorder.audioQueue.sync { recorder.stream(stream, didOutputSampleBuffer: buffer, of: .audio) }
        }
        // A capture queue that never drains stands in for a writer that never answers.
        let release = DispatchSemaphore(value: 0)
        recorder.audioQueue.async { release.wait() }
        defer { release.signal() }
        let stopped = expectation(description: "the stop gives up")
        Task {
            do { try await recorder.stop().value; XCTFail("A stop that never finishes must fail") }
            catch RecorderError.stopTimedOut {} catch { XCTFail("\(error)") }
            stopped.fulfill()
        }
        await fulfillment(of: [stopped], timeout: 5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "A timed-out stop must not delete the recording")
    }

    @MainActor
    func testScreenStopWithoutFinishCallbackFailsAndIgnoresALateCallback() async throws {
        let root = makeTempRoot()
        defer { removeTempRoot(root) }
        let recorder = MeetingRecorder()
        recorder.callbackTimeout = .milliseconds(200)
        recorder.startCapture = { _ in
            recorder.recordingOutputDidStartRecording(try XCTUnwrap(recorder.recordingOutput))
        }
        recorder.stopCapture = { _ in }
        let before = idleSleepAssertions()
        let stream = SCStream(filter: SCContentFilter(), configuration: SCStreamConfiguration(), delegate: nil)
        try await recorder.begin(stream, to: root.appendingPathComponent("recording.mp4"), microphone: nil, mode: .screen)
        let output = try XCTUnwrap(recorder.recordingOutput)
        XCTAssertEqual(idleSleepAssertions(), before + 1)
        do {
            try await recorder.stop().value
            XCTFail("A stop that never reports must fail")
        } catch RecorderError.stopTimedOut {}
        XCTAssertEqual(idleSleepAssertions(), before, "A failed stop must let the Mac sleep again")
        let unexpected = expectation(description: "a late callback must not report another stop")
        unexpected.isInverted = true
        recorder.onUnexpectedStop = { _ in unexpected.fulfill() }
        recorder.recordingOutputDidFinishRecording(output)
        await fulfillment(of: [unexpected], timeout: 0.2)
    }

    @MainActor
    func testScreenStopFreesTheRecorderWhileALongerRecordingFinishesItsFile() async throws {
        // ScreenCaptureKit finished a 23-minute MP4 82 seconds after capture stopped: past the fixed one-minute wait, and
        // the next meeting could not start until then.
        let root = makeTempRoot()
        defer { removeTempRoot(root) }
        let recorder = MeetingRecorder()
        recorder.callbackTimeout = .milliseconds(100)
        recorder.startCapture = { _ in
            recorder.recordingOutputDidStartRecording(try XCTUnwrap(recorder.recordingOutput))
        }
        recorder.stopCapture = { _ in }
        let first = SCStream(filter: SCContentFilter(), configuration: SCStreamConfiguration(), delegate: nil)
        try await recorder.begin(first, to: root.appendingPathComponent("first.mp4"), microphone: nil, mode: .screen)
        let output = try XCTUnwrap(recorder.recordingOutput)
        try await Task.sleep(for: .seconds(2))
        let file = try await recorder.stop()
        let second = SCStream(filter: SCContentFilter(), configuration: SCStreamConfiguration(), delegate: nil)
        try await recorder.begin(second, to: root.appendingPathComponent("second.mp4"), microphone: nil, mode: .screen)
        let unexpected = expectation(description: "the old file finishing must not stop the new recording")
        unexpected.isInverted = true
        recorder.onUnexpectedStop = { _ in unexpected.fulfill() }
        // Past callbackTimeout, but well within the quarter of the recorded time added to it.
        try await Task.sleep(for: .milliseconds(250))
        recorder.recordingOutputDidFinishRecording(output)
        try await file.value
        await fulfillment(of: [unexpected], timeout: 0.2)
        XCTAssertNotNil(recorder.recordingOutput)
    }

    @MainActor
    func testRecordingKeepsTheMacAwakeUntilItStops() async throws {
        let root = makeTempRoot()
        defer { removeTempRoot(root) }
        let url = root.appendingPathComponent("recording.mov")
        let recorder = MeetingRecorder()
        recorder.startCapture = { _ in }
        recorder.stopCapture = { _ in }
        let before = idleSleepAssertions()
        let stream = SCStream(filter: SCContentFilter(), configuration: SCStreamConfiguration(), delegate: nil)
        try await recorder.begin(stream, to: url, microphone: nil, mode: .audioOnly)
        XCTAssertEqual(idleSleepAssertions(), before + 1, "A recording without user input must not let the Mac idle-sleep")
        for index in 0..<5 {
            let buffer = try sample(at: Double(index) * 0.02, frequency: 440, channels: 2)
            recorder.audioQueue.sync { recorder.stream(stream, didOutputSampleBuffer: buffer, of: .audio) }
        }
        try await recorder.stop().value
        XCTAssertEqual(idleSleepAssertions(), before, "Stopping must let the Mac sleep again")
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
        return try audioSampleBuffer(buffer, at: time)
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

    private func idleSleepAssertions() -> Int {
        var byProcess: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&byProcess) == kIOReturnSuccess,
              let all = byProcess?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return 0 }
        let own = all[NSNumber(value: ProcessInfo.processInfo.processIdentifier)] ?? []
        return own.filter { $0[kIOPMAssertionTypeKey] as? String == kIOPMAssertionTypePreventUserIdleSystemSleep }.count
    }
}
