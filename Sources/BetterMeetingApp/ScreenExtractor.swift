import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

struct ScreenEvent: Codable, Equatable, Sendable {
    let time: TimeInterval
    let added: [String]
    var screenshot: String?
}

enum ScreenExtractor {
    // Match OG's 16×16 grid comparison, two-second sampling, and 90-second refresh.
    static func extract(
        video: URL, to folder: URL, languages: [String],
        progress: @Sendable (Double) -> Void
    ) async throws -> [ScreenEvent] {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: video)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw ScreenExtractionError.invalidVideo }
        let thumbnails = generator(for: asset, width: 320)
        let frames = generator(for: asset, width: 1920)
        defer { thumbnails.cancelAllCGImageGeneration(); frames.cancelAllCGImageGeneration() }
        var previousSignature: [UInt8]?
        var previousTime = -90.0
        var previousText: [String] = []
        var keyframes: [ScreenEvent] = []
        for time in stride(from: 0.0, to: duration, by: 2.0) {
            try Task.checkCancellation()
            let timestamp = CMTime(seconds: time, preferredTimescale: 600)
            let thumbnail = try await thumbnails.image(at: timestamp).image
            let signature = try signature(of: thumbnail)
            if shouldKeep(signature, previous: previousSignature, gap: time - previousTime) {
                let image = try await frames.image(at: timestamp).image
                let lines = try recognizeText(in: image, languages: languages)
                let added = addedLines(lines, previous: previousText)
                keyframes.append(ScreenEvent(time: time, added: added))
                previousText = lines
                previousSignature = signature
                previousTime = time
            }
            progress(0.9 * min((time + 2) / duration, 1))
        }
        try Task.checkCancellation()
        let screens = folder.appendingPathComponent("screens", isDirectory: true)
        try FileManager.default.createDirectory(at: screens, withIntermediateDirectories: true)
        let selected = selectedIndices(in: keyframes, duration: duration, limit: 30)
        frames.maximumSize = CGSize(width: 1400, height: 1400)
        for (number, index) in selected.enumerated() {
            try Task.checkCancellation()
            let event = keyframes[index]
            let image = try await frames.image(at: CMTime(seconds: event.time, preferredTimescale: 600)).image
            let name = String(format: "%03d_", number + 1) + Timecode.string(event.time).replacingOccurrences(of: ":", with: "-") + ".jpg"
            try writeJPEG(image, to: screens.appendingPathComponent(name))
            keyframes[index].screenshot = "screens/" + name
            progress(0.9 + 0.1 * Double(number + 1) / Double(selected.count))
        }
        try Task.checkCancellation()
        let events = keyframes.filter { !$0.added.isEmpty || $0.screenshot != nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(events).write(to: folder.appendingPathComponent("screen.json"), options: .atomic)
        progress(1)
        return events
    }

    private static func generator(for asset: AVAsset, width: CGFloat) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: width, height: width)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return generator
    }

    static func signature(of image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: 256)
        try pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: 16, height: 16,
                                          bitsPerComponent: 8, bytesPerRow: 16,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else {
                throw ScreenExtractionError.imageEncoding
            }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        return pixels
    }

    static func shouldKeep(_ signature: [UInt8], previous: [UInt8]?, gap: Double) -> Bool {
        guard let previous else { return true }
        let changes = zip(signature, previous).map { abs(Int($0) - Int($1)) }
        return gap >= 90 || changes.filter { $0 > 14 }.count >= 3 || (changes.max() ?? 0) > 60
    }

    static func recognizeText(in image: CGImage, languages: [String]) throws -> [String] {
        try Task.checkCancellation()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let supported = try request.supportedRecognitionLanguages()
        let preferred = languages.compactMap { language in
            supported.first { $0 == language || $0.hasPrefix(language + "-") }
        }
        if !preferred.isEmpty { request.recognitionLanguages = preferred }
        try VNImageRequestHandler(cgImage: image).perform([request])
        try Task.checkCancellation()
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }

    static func addedLines(_ lines: [String], previous: [String]) -> [String] {
        func normalized(_ text: String) -> String {
            text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        var seen = Set(previous.map(normalized))
        return lines.filter { line in
            let text = normalized(line)
            return text.count > 1 && seen.insert(text).inserted
        }
    }

    static func selectedIndices(in events: [ScreenEvent], duration: Double, limit: Int) -> [Int] {
        guard limit > 0, !events.isEmpty else { return [] }
        let text = events.indices.filter { !events[$0].added.isEmpty }
        let candidates = text.isEmpty ? Array(events.indices) : text
        guard candidates.count > limit else { return candidates }
        if text.isEmpty {
            return (0..<limit).map { candidates[$0 * candidates.count / limit] }
        }
        func score(_ index: Int) -> Int { events[index].added.reduce(0) { $0 + $1.count } }
        var buckets: [Int: Int] = [:]
        for index in candidates {
            let bucket = min(Int(events[index].time / max(duration, 1) * Double(limit)), limit - 1)
            if buckets[bucket].map({ score(index) > score($0) }) ?? true { buckets[bucket] = index }
        }
        var chosen = Set(buckets.values)
        let remaining = candidates.filter { !chosen.contains($0) }.sorted {
            score($0) == score($1) ? $0 < $1 : score($0) > score($1)
        }
        chosen.formUnion(remaining.prefix(limit - chosen.count))
        return chosen.sorted()
    }

    private static func writeJPEG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ScreenExtractionError.imageEncoding
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.72] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ScreenExtractionError.imageEncoding }
    }
}

enum ScreenExtractionError: LocalizedError {
    case missingRecording, invalidVideo, imageEncoding
    var errorDescription: String? {
        switch self {
        case .missingRecording: "This meeting has no screen recording to export."
        case .invalidVideo: "The recording has no readable video."
        case .imageEncoding: "A screenshot could not be saved. Check the meeting folder and free disk space."
        }
    }
}
