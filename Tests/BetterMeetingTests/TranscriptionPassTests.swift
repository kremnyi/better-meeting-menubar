import AVFoundation
import CoreML
import os
import WhisperKit
import XCTest
@testable import BetterMeetingApp

final class TranscriptionPassTests: XCTestCase {
    private enum Interrupted: Error { case pass }

    func testOriginalConfidenceMergeAndSilenceRules() {
        let segments = [
            segment(0, 2, "uk", -0.1), segment(0, 2, "ru", -0.4),
            segment(2, 4, "en", -0.2), segment(2, 4, "uk", -0.7),
            segment(4, 6, "ru", -0.3), segment(6, 8, "en", -1.5, silence: 0.9),
            segment(10, 12, "uk", -0.4), segment(14, 16, "en", -0.5, silence: 0.9)
        ]
        let merged = TranscriptionPasses.merge(segments)
        XCTAssertEqual(merged.map(\.lang), ["uk", "en", "ru", "uk", "en"])
        XCTAssertEqual(merged.map(\.start), [0, 2, 4, 10, 14])
        XCTAssertTrue(TranscriptionPasses.merge([]).isEmpty)
        XCTAssertEqual(TranscriptionPasses.merge([segment(0, 2, "uk", -1, silence: 0.9)]).count, 1)
        XCTAssertEqual(TranscriptionPasses.merge([segment(0, 2, "uk", -2, silence: 0.6)]).count, 1)
        let noise = segment(0, 2, "en", -1.2, silence: 0.5)
        XCTAssertEqual(TranscriptionPasses.merge([noise]).count, 1)
        XCTAssertTrue(TranscriptionPasses.merge([noise], noSpeechThreshold: 0.4).isEmpty, "A lower threshold drops the same segment")
        XCTAssertEqual(TranscriptionPasses.merge([
            segment(0, 2, "uk", -0.2), segment(0, 2, "ru", -0.2)
        ]).first?.lang, "uk")
    }

    func testMergeSkipsSentencesAnotherPassAlreadyCovered() {
        // The longer copy of the same sentence outscores the next sentence but adds only half a second.
        let merged = TranscriptionPasses.merge([
            segment(3, 9.5, "en", -0.2), segment(3, 10, "uk", -0.25), segment(10, 16, "ru", -0.3)
        ])
        XCTAssertEqual(merged.map(\.lang), ["en", "ru"])
        XCTAssertEqual(TranscriptionPasses.merge([
            segment(0, 5, "en", -0.2), segment(4, 12, "uk", -0.3)
        ]).map(\.lang), ["en", "uk"])
    }

    func testMergeKeepsShortLinesBeforeALongerLineInAnotherLanguage() {
        // The 3.5 s line outscores the earlier "Yes."; taking it first would lose "Yes." from both passes.
        let lines: [(Double, Double, Float)] = [(0, 1.5, -0.6), (1.5, 5, -0.2), (5, 8, -0.3)]
        let merged = TranscriptionPasses.merge(["en", "uk"].flatMap { language in
            lines.map { segment($0.0, $0.1, language, $0.2) }
        })
        XCTAssertEqual(merged.map(\.start), [0, 1.5, 5])
    }

    func testSinglePassDropsSilenceButKeepsEveryOtherLine() async throws {
        let root = makeTempRoot()
        defer { removeTempRoot(root) }
        let audio = root.appendingPathComponent("audio.m4a")
        try Data([1]).write(to: audio)
        let transcript = try await TranscriptionPasses.run(audioURL: audio, languages: ["en"], progressHandler: { _ in }) { _, _ in
            [
                self.segment(6, 8, "en", -0.3), self.segment(0, 2, "en", -0.2),
                self.segment(2, 4, "en", -1.5, silence: 0.9),
                // Merging would drop a line shorter than 0.2 s, which a single pass has no reason to.
                self.segment(4, 4.1, "en", -0.4),
            ]
        }
        XCTAssertEqual(transcript.map(\.start), [0, 4, 6])
    }

    func testCancelledLoadReturnsWithoutWaitingForTheDecode() async throws {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        // Frees the stuck decode after 10 s, so a load that ignores cancellation fails instead of hanging.
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) { release.signal() }
        defer { release.signal() }
        let audio = MeetingAudio(url: URL(fileURLWithPath: "/unused")) { _ in
            try await MeetingAudio.blocking { isCancelled in
                started.signal()
                release.wait()
                if isCancelled() { throw CancellationError() }
                return [0]
            }
        }
        let load = Task { try await audio.load() }
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { started.wait(); continuation.resume() }
        }
        let begun = Date()
        load.cancel()
        do {
            _ = try await load.value
            XCTFail("Cancellation must propagate")
        } catch is CancellationError {}
        XCTAssertLessThan(Date().timeIntervalSince(begun), 5, "The cancelled load waited for the decode")
    }

    func testInterruptedPassesResumeAndChangedInputsInvalidateCache() async throws {
        let root = makeTempRoot()
        defer { removeTempRoot(root) }
        let audio = root.appendingPathComponent("audio.m4a")
        try Data([1, 2, 3]).write(to: audio)
        let languages = ["uk", "ru", "en"]
        var calls: [String] = []
        do {
            _ = try await TranscriptionPasses.run(audioURL: audio, languages: languages, detectLanguages: Self.detectAll, progressHandler: { _ in }) { options, _ in
                let language = try XCTUnwrap(options.language)
                calls.append(language)
                if language == "ru" { throw Interrupted.pass }
                return [self.segment(0, 2, language, -0.2)]
            }
            XCTFail("Expected the second language to fail")
        } catch Interrupted.pass {}
        XCTAssertEqual(calls, ["uk", "ru"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("pass_uk.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("pass_ru.json").path))

        calls = []
        _ = try await TranscriptionPasses.run(audioURL: audio, languages: languages, detectLanguages: Self.detectAll, progressHandler: { _ in }) { options, _ in
            calls.append(try XCTUnwrap(options.language))
            return []
        }
        XCTAssertEqual(calls, ["ru", "en"])
        let cached = try await TranscriptionPasses.run(audioURL: audio, languages: languages, detectLanguages: {
            XCTFail("Completed passes must not load the model to detect languages")
            return []
        }, progressHandler: { _ in }) { _, _ in
            XCTFail("Completed passes must not invoke the model")
            throw Interrupted.pass
        }
        XCTAssertEqual(cached.first?.language, "uk")

        let moved = root.appendingPathComponent("renamed")
        try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
        for name in ["audio.m4a", "pass_uk.json", "pass_ru.json", "pass_en.json"] {
            try FileManager.default.moveItem(at: root.appendingPathComponent(name), to: moved.appendingPathComponent(name))
        }
        let movedAudio = moved.appendingPathComponent("audio.m4a")
        _ = try await TranscriptionPasses.run(audioURL: movedAudio, languages: ["uk"], progressHandler: { _ in }) { _, _ in
            XCTFail("A pinned language should reuse its completed pass after rename")
            throw Interrupted.pass
        }
        let cacheURL = moved.appendingPathComponent("pass_uk.json")
        for field in ["model", "backend", "options"] {
            var cache = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: cacheURL)) as? [String: Any])
            cache[field] = field == "options" ? Data("old options".utf8).base64EncodedString() : "old"
            try JSONSerialization.data(withJSONObject: cache).write(to: cacheURL)
            var reran = false
            _ = try await TranscriptionPasses.run(audioURL: movedAudio, languages: ["uk"], progressHandler: { _ in }) { _, _ in
                reran = true
                return []
            }
            XCTAssertTrue(reran, "Changed \(field) must invalidate the cache")
        }
        try Data("partial cache".utf8).write(to: cacheURL)
        calls = []
        _ = try await TranscriptionPasses.run(audioURL: movedAudio, languages: languages, detectLanguages: Self.detectAll, progressHandler: { _ in }) { options, _ in
            calls.append(try XCTUnwrap(options.language))
            return []
        }
        XCTAssertEqual(calls, ["uk"])
        try Data([1, 2, 3, 4]).write(to: movedAudio)
        calls = []
        _ = try await TranscriptionPasses.run(audioURL: movedAudio, languages: languages, detectLanguages: Self.detectAll, progressHandler: { _ in }) { options, _ in
            calls.append(try XCTUnwrap(options.language))
            return []
        }
        XCTAssertEqual(calls, languages)
    }

    func testOnlyDetectedCandidatesGetPasses() async throws {
        let root = makeTempRoot()
        defer { removeTempRoot(root) }
        let audio = root.appendingPathComponent("audio.m4a")
        try Data([1]).write(to: audio)
        let cases: [(windows: [[String: Float]], passes: [String], reports: [String])] = [
            // Any window counts, unlikely guesses do not, and passes keep the candidates' order.
            ([["en": 0.9], ["ru": 0.1], ["uk": 0.6]], ["uk", "en"], ["uk 1/2", "en 2/2"]),
            // Without a detected candidate, the first one still runs.
            ([["ru": 0.1], ["de": 0.9]], ["uk"], ["uk 1/1"]),
            ([], ["uk"], ["uk 1/1"]),
        ]
        for (windows, passes, reports) in cases {
            for language in ["uk", "ru", "en"] {
                try? FileManager.default.removeItem(at: root.appendingPathComponent("pass_\(language).json"))
            }
            let reported = OSAllocatedUnfairLock<[String]>(initialState: [])
            var calls: [String] = []
            _ = try await TranscriptionPasses.run(audioURL: audio, languages: ["uk", "ru", "en"], detectLanguages: { windows }, progressHandler: { progress in
                guard case .transcribing(_, let language, let pass, let total) = progress else { return }
                reported.withLock { $0.append("\(language) \(pass)/\(total)") }
            }) { options, _ in
                calls.append(try XCTUnwrap(options.language))
                return []
            }
            XCTAssertEqual(calls, passes)
            XCTAssertEqual(reported.withLock { $0 }, reports, "Progress must count only the passes that run")
        }
    }

    func testNoSpeechProbabilityMatchesOnHalfAndSinglePrecision() throws {
        let half = try MLMultiArray(shape: [1, 1, 3], dataType: .float16)
        half[0] = 2.5
        half[1] = 7
        half[2] = -1
        let boxed = (0..<3).map { half[$0].doubleValue }
        let expected = Float(exp(boxed[1] - 7) / boxed.reduce(0) { $0 + exp($1 - 7) })
        XCTAssertEqual(SpeechProbabilityDecoder.probability(of: 1, in: half), expected)
        // A model that emits single precision must not trap on the half-precision fast path.
        let single = try MLMultiArray(shape: [1, 1, 3], dataType: .float32)
        for index in 0..<3 { single[index] = half[index] }
        XCTAssertEqual(SpeechProbabilityDecoder.probability(of: 1, in: single), expected)
    }

    func testCancellationKeepsOnlyCompletedPasses() async throws {
        let root = makeTempRoot()
        defer { removeTempRoot(root) }
        let audio = root.appendingPathComponent("audio.m4a")
        try Data([1]).write(to: audio)
        let task = Task {
            try await TranscriptionPasses.run(audioURL: audio, languages: ["uk", "en"], detectLanguages: Self.detectAll, progressHandler: { _ in }) { options, _ in
                if options.language == "en" { withUnsafeCurrentTask { $0?.cancel() } }
                return []
            }
        }
        do {
            _ = try await task.value
            XCTFail("Cancellation must propagate")
        } catch is CancellationError {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("pass_uk.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("pass_en.json").path))
        _ = try await TranscriptionPasses.run(audioURL: audio, languages: ["uk", "en"], detectLanguages: Self.detectAll, progressHandler: { _ in }) { options, _ in
            XCTAssertEqual(options.language, "en")
            return []
        }
    }

    @MainActor
    func testLanguagePreferencePersists() throws {
        let (defaults, suite, root) = try makeTempDefaults("BetterMeetingLanguages")
        defer { removeTempDefaults(defaults, suite: suite, root: root) }
        XCTAssertEqual(AppModel(defaults: defaults).transcriptionLanguages, ["uk", "ru", "en"])
        defaults.set("auto", forKey: "transcriptionLanguage")
        defaults.set(["pl", "en"], forKey: "candidateLanguages")
        XCTAssertEqual(AppModel(defaults: defaults).transcriptionLanguages, ["pl", "en"])
        defaults.set("uk", forKey: "transcriptionLanguage")
        let model = AppModel(defaults: defaults)
        XCTAssertEqual(model.transcriptionLanguages, ["uk"], "Preserve the previous single-language selection")
        model.transcriptionLanguages = ["ja", "en"]
        XCTAssertEqual(AppModel(defaults: defaults).transcriptionLanguages, ["ja", "en"], "New choices must override both legacy preferences")
        model.transcriptionLanguages = ["en"]
        model.transcriptionHints = "Anna, Approck, WhisperKit"
        XCTAssertEqual(AppModel(defaults: defaults).transcriptionLanguages, ["en"])
        XCTAssertEqual(AppModel(defaults: defaults).transcriptionHints, "Anna, Approck, WhisperKit")
    }

    func testCandidateLanguagesRejectUnsupportedAndDuplicateCodes() async throws {
        XCTAssertEqual(TranscriptionLanguage.candidates(from: ["pl", "pl", "en", "../bad"]), ["pl", "en"])
        for codes in [[], ["../bad"], ["en", "en"]] {
            do {
                _ = try await TranscriptionPasses.run(audioURL: URL(fileURLWithPath: "/missing"), languages: codes, progressHandler: { _ in }) { _, _ in
                    XCTFail("Invalid codes must never reach inference or cache paths")
                    return []
                }
                XCTFail("Expected invalid languages")
            } catch TranscriptionError.invalidLanguages {}
        }
    }

    func testVocabularyChangesInvalidatePassCache() async throws {
        let root = makeTempRoot()
        defer { removeTempRoot(root) }
        let audio = root.appendingPathComponent("audio.m4a")
        try Data([1]).write(to: audio)
        for (hints, shouldRun) in [("", true), ("Anna, Approck", true), (" Anna, Approck ", false), ("", true)] {
            var ran = false
            _ = try await TranscriptionPasses.run(audioURL: audio, languages: ["uk"], hints: hints, progressHandler: { _ in }) { _, _ in
                ran = true
                return []
            }
            XCTAssertEqual(ran, shouldRun)
        }
    }

    func testRealMultilingualRecording() async throws {
        guard let path = ProcessInfo.processInfo.environment["BETTER_MEETING_TRANSCRIPTION_CHECK"] else {
            throw XCTSkip("Set BETTER_MEETING_TRANSCRIPTION_CHECK to a Ukrainian/Russian/English audio fixture")
        }
        let cache = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/model-check")
        let transcriber = LocalTranscriber(downloadBase: cache)
        let segments = try await transcriber.transcribe(audioURL: URL(fileURLWithPath: path)) { _ in }
        XCTAssertEqual(Set(segments.compactMap(\.language)), Set(["uk", "ru", "en"]))
        XCTAssertTrue(segments.allSatisfy { !$0.text.contains("<|") && $0.end > $0.start })
        for language in ["uk", "ru", "en"] {
            let passURL = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("pass_\(language).json")
            let cache = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: passURL)) as? [String: Any])
            let pass = try XCTUnwrap(cache["segments"] as? [[String: Any]])
            XCTAssertTrue(pass.contains { ($0["nospeech"] as? Double ?? 0) > 0 }, "No-speech probabilities must be computed, not hardcoded")
        }
        let audio = URL(fileURLWithPath: path)
        let hinted = try await transcriber.transcribe(audioURL: audio, languages: ["en"], hints: "Anna, Michael, pricing, release schedule") { _ in }
        XCTAssertFalse(hinted.isEmpty)
        XCTAssertTrue(hinted.allSatisfy { $0.language == "en" && !$0.text.contains("<|") })
        let pass = audio.deletingLastPathComponent().appendingPathComponent("pass_en.json")
        let completedPass = try Data(contentsOf: pass)
        let work = Task {
            try await transcriber.transcribe(audioURL: audio, languages: ["en"], hints: "Different hints force another pass") { _ in }
        }
        try await Task.sleep(for: .milliseconds(100))
        work.cancel()
        if case .success = await work.result { XCTFail("Cancelled inference must not return a transcript") }
        XCTAssertEqual(try Data(contentsOf: pass), completedPass, "Cancellation must preserve the last completed pass")
    }

    private static func detectAll() -> [[String: Float]] { [["uk": 1, "ru": 1, "en": 1]] }

    private func segment(_ start: Double, _ end: Double, _ language: String, _ score: Float, silence: Float = 0) -> ScoredSegment {
        ScoredSegment(start: start, end: end, text: "\(language) at \(start)", lang: language, score: score, nospeech: silence)
    }
}
