import Darwin
import Foundation
import XCTest
@testable import BetterMeetingApp

/// Opt-in benchmark: set BETTER_MEETING_ENGINE_CHECK to a disposable recording,
/// plus independently annotated phrases/silence in <recording>.expected.json.
/// Compare recognition quality, elapsed time, and peak memory for both engines.
final class EngineComparisonTests: XCTestCase {
    func testCompareEnginesOnRealAudio() async throws {
        guard let path = ProcessInfo.processInfo.environment["BETTER_MEETING_ENGINE_CHECK"] else {
            throw XCTSkip("Set BETTER_MEETING_ENGINE_CHECK to a disposable recording to compare engines")
        }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/engine-check", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = URL(fileURLWithPath: path)
        let reference = try JSONDecoder().decode([ExpectedAudioWindow].self,
            from: Data(contentsOf: URL(fileURLWithPath: path + ".expected.json")))
        guard !reference.isEmpty, reference.allSatisfy({
            $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start
                && $0.phrases.allSatisfy { !ExpectedAudioWindow.normalize($0).isEmpty }
        }) else {
            XCTFail("Provide nonempty reference windows with valid times; use [] for silence, never a blank phrase")
            return
        }
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
        XCTAssertFalse(runs.isEmpty, "Engine filter matched no supported engines")
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
            XCTAssertTrue(segments.allSatisfy { $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start },
                          "\(run.name) returned invalid timestamps")
            let failures = reference.flatMap { $0.failures(in: segments) }
            XCTAssertTrue(failures.isEmpty, "\(run.name): " + failures.joined(separator: "; "))
        }
    }

    func testQualityReferenceDetectsMissingLanguagesOverlapAndSilenceText() throws {
        let reference = try JSONDecoder().decode([ExpectedAudioWindow].self, from: Data("""
        [
          {"start":0,"end":2,"phrases":["план запуску"]},
          {"start":2,"end":4,"phrases":["проверим бюджет"]},
          {"start":4,"end":6,"phrases":[]},
          {"start":6,"end":8,"phrases":["release Friday","pricing report"]}
        ]
        """.utf8))
        let recognized = [
            TranscriptSegment(start: 0, end: 2, text: "План запуску.", language: "uk"),
            TranscriptSegment(start: 2, end: 4, text: "Проверим бюджет!", language: "ru"),
            TranscriptSegment(start: 6, end: 8, text: "Release Friday; pricing report.", language: "en")
        ]
        XCTAssertTrue(reference.flatMap { $0.failures(in: recognized) }.isEmpty)
        XCTAssertFalse(reference[0].failures(in: Array(recognized.dropFirst())).isEmpty,
                       "A nonempty transcript can still drop a language")
        let oneSpeaker = [TranscriptSegment(start: 6, end: 8, text: "Release Friday", language: "en")]
        XCTAssertFalse(reference[3].failures(in: oneSpeaker).isEmpty, "Both annotated speakers must survive overlap")
        let hallucination = [TranscriptSegment(start: 4.5, end: 5.5, text: "Thank you", language: "en")]
        XCTAssertFalse(reference[2].failures(in: hallucination).isEmpty, "Silence must not produce words")
    }

}

private struct ExpectedAudioWindow: Decodable {
    let start: Double
    let end: Double
    /// Independently chosen phrases; an empty array marks a silent interval.
    let phrases: [String]

    static func normalize(_ text: String) -> String {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: " ")
    }

    func failures(in segments: [TranscriptSegment]) -> [String] {
        let text = Self.normalize(segments.filter { $0.start < end && $0.end > start }.map(\.text).joined(separator: " "))
        if phrases.isEmpty {
            return text.isEmpty ? [] : ["Unexpected speech in silence at \(start)–\(end)s: \(text)"]
        }
        return phrases.compactMap { phrase in
            (" " + text + " ").contains(" " + Self.normalize(phrase) + " ") ? nil
                : "Missing ‘\(phrase)’ at \(start)–\(end)s"
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
