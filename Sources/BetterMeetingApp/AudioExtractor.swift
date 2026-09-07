import AVFoundation
import Foundation

enum AudioExtractor {
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
