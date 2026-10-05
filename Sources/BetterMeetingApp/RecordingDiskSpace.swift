import Foundation

struct RecordingDiskSpace: Equatable {
    let availableBytes: Int64

    var isLow: Bool { availableBytes < 2_000_000_000 }
    var available: String { ByteCountFormatter.string(fromByteCount: availableBytes, countStyle: .file) }
    var warning: String { "\(available) available. Free space or stop recording soon." }

    func preflight() throws {
        guard availableBytes >= 250_000_000 else { throw InsufficientSpace(available: available) }
    }

    static func read(at destination: URL) -> Self? {
        // A newly selected destination may not exist yet. Check its containing volume.
        var directory = destination.standardizedFileURL
        while !FileManager.default.fileExists(atPath: directory.path), directory.path != "/" {
            directory.deleteLastPathComponent()
        }
        guard let values = try? directory.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey
        ]), let bytes = values.volumeAvailableCapacityForImportantUsage
            ?? values.volumeAvailableCapacity.map(Int64.init) else { return nil }
        return Self(availableBytes: bytes)
    }

    struct InsufficientSpace: LocalizedError {
        let available: String
        var errorDescription: String? {
            "Only \(available) is available on the recording drive. Make at least 250 MB available or choose another save folder in Options, then try again."
        }
    }
}
