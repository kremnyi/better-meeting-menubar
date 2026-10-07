import AVFoundation
import Foundation

enum AudioExtractor {
    /// ScreenCaptureKit can report a recording as finished before the MP4 index is written,
    /// notably when the capture was stopped from the macOS screen-sharing menu.
    static func waitUntilReadable(
        _ recordingURL: URL, timeout: Duration = .seconds(300), interval: Duration = .seconds(1)
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while true {
            do {
                _ = try await AVURLAsset(url: recordingURL).load(.tracks)
                return
            } catch let error as AVError
                where [.fileFormatNotRecognized, .fileFailedToParse].contains(error.code)
                && ContinuousClock.now < deadline {
                try await Task.sleep(for: interval)
            }
        }
    }

    /// Levels for a recording's system and microphone tracks; MeetingAudio decodes with the same mix.
    static func mix(for recordingURL: URL, tracks: [AVAssetTrack]) -> AVAudioMix? {
        guard recordingURL.pathExtension == "mov", tracks.count > 1 else { return nil }
        let mix = AVMutableAudioMix()
        mix.inputParameters = tracks.map { track in
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.setVolume(1 / Float(tracks.count), at: .zero)
            return parameters
        }
        return mix
    }

    static func extract(
        from recordingURL: URL,
        to audioURL: URL,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws {
        try Task.checkCancellation()
        let temporaryURL = audioURL.deletingLastPathComponent()
            .appendingPathComponent(".audio-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        let asset = AVURLAsset(url: recordingURL)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else { throw AudioExtractionError.cannotCreateExporter }
        guard let exporter = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw AudioExtractionError.cannotCreateExporter
        }

        exporter.shouldOptimizeForNetworkUse = false
        exporter.audioMix = mix(for: recordingURL, tracks: audioTracks)
        progressHandler(0)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await state in exporter.states(updateInterval: 0.2) {
                    guard case .exporting(let progress) = state else { continue }
                    progressHandler(progress.fractionCompleted)
                }
            }
            defer { group.cancelAll() }
            // macOS 15 can raise an Objective-C exception when export starts already cancelled.
            try Task.checkCancellation()
            try await exporter.export(to: temporaryURL, as: .m4a)
        }

        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: audioURL.path) {
            _ = try FileManager.default.replaceItemAt(audioURL, withItemAt: temporaryURL)
        } else {
            try FileManager.default.moveItem(at: temporaryURL, to: audioURL)
        }
        progressHandler(1)
    }
}

enum AudioExtractionError: LocalizedError {
    case cannotCreateExporter

    var errorDescription: String? {
        "The recording does not contain audio that can be prepared for transcription."
    }
}
