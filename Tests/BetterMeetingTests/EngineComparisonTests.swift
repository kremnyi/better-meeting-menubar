import Darwin
import Foundation
import XCTest
@testable import BetterMeetingApp

/// Opt-in benchmark: set BETTER_MEETING_ENGINE_CHECK to a disposable recording,
/// then compare both transcripts, elapsed time, and peak memory before deciding
/// whether Parakeet should replace Whisper as the default.
final class EngineComparisonTests: XCTestCase {
    func testCompareEnginesOnRealAudio() async throws {
        guard let path = ProcessInfo.processInfo.environment["BETTER_MEETING_ENGINE_CHECK"] else {
            throw XCTSkip("Set BETTER_MEETING_ENGINE_CHECK to a disposable recording to compare engines")
        }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/engine-check", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = URL(fileURLWithPath: path)
        let audio = root.appendingPathComponent("sample-\(source.lastPathComponent)")
        try? FileManager.default.removeItem(at: audio)
        try FileManager.default.copyItem(at: source, to: audio)
        // Pass caches sit next to the audio; clear them so every timed run transcribes.
        for file in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            if file.lastPathComponent.hasPrefix("pass_") || file.lastPathComponent == "speaker_turns.json" {
                try? FileManager.default.removeItem(at: file)
            }
        }
        let transcriber = LocalTranscriber(downloadBase: root)
        // Optional comma-separated filters, for example ENGINES=parakeet-v3 and LANGUAGES=ru.
        let environment = ProcessInfo.processInfo.environment
        let engines = environment["BETTER_MEETING_ENGINE_CHECK_ENGINES"]?.split(separator: ",").map(String.init)
        let languages = environment["BETTER_MEETING_ENGINE_CHECK_LANGUAGES"]?.split(separator: ",").map(String.init)
            ?? TranscriptionLanguage.defaultCandidates
        let runs: [(name: String, settings: SpeechSettings)] = [
            ("whisper-turbo", SpeechSettings(engine: .whisper)),
            ("parakeet-v3", SpeechSettings(engine: .parakeet)),
        ].filter { engines?.contains($0.name) ?? true }
        for run in runs {
            switch run.settings.selectedEngine {
            case .whisper: try await transcriber.prepare(model: run.settings.model, progressHandler: { _ in })
            case .parakeet: _ = try await transcriber.prepareParakeet(progressHandler: { _ in })
            }
            let probe = MemoryProbe()
            let sampler = Task {
                while !Task.isCancelled {
                    await probe.sample()
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            let started = Date()
            defer { sampler.cancel() }
            let segments = try await transcriber.transcribe(
                audioURL: audio, languages: languages, settings: run.settings, progressHandler: { _ in }
            )
            let elapsed = Date().timeIntervalSince(started)
            sampler.cancel()
            let peakMB = await probe.peakMB
            let lines = segments.map { "[\(Timecode.string($0.start))] \($0.text)" }
            let report = """
            # \(run.name)

            Elapsed: \(String(format: "%.1f", elapsed)) s
            Segments: \(segments.count)
            Characters: \(lines.joined().count)
            Peak memory: \(String(format: "%.0f", peakMB)) MB

            \(lines.joined(separator: "\n"))
            """
            try report.write(to: root.appendingPathComponent("\(run.name).md"), atomically: true, encoding: .utf8)
            print("ENGINE \(run.name): \(String(format: "%.1f", elapsed)) s, \(segments.count) segments, peak \(String(format: "%.0f", peakMB)) MB")
            XCTAssertFalse(segments.isEmpty, "\(run.name) returned no transcript")
        }
    }
}

private actor MemoryProbe {
    private(set) var peakMB = 0.0

    func sample() {
        peakMB = max(peakMB, Self.residentMB())
    }

    private static func residentMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
    }
}
