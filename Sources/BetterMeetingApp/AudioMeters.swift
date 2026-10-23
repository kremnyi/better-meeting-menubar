import SwiftUI

/// Levels change several times a second, so only the meters observe them, not the whole menu and menu bar item.
@MainActor
final class AudioMeters: ObservableObject {
    struct Levels: Equatable {
        var microphone = 0.0
        var system = 0.0
    }

    @Published private(set) var levels = Levels()

    /// Levels are compared in whole percent; finer changes are invisible and would redraw every tick.
    func update(microphone: Double, system: Double) {
        let next = Levels(microphone: Self.quantized(microphone), system: Self.quantized(system))
        if levels != next { levels = next }
    }

    private static func quantized(_ level: Double) -> Double { (level * 100).rounded() / 100 }
}

struct AudioMetersView: View {
    @ObservedObject var meters: AudioMeters
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 6) {
            meter("Microphone", level: meters.levels.microphone)
            meter("System audio", level: meters.levels.system)
        }
    }

    private func meter(_ label: String, level: Double) -> some View {
        let percent = Int((level * 100).rounded())
        return HStack(spacing: 8) {
            Text(label).font(.caption).frame(width: 78, alignment: .leading)
            // Empty when silent; a progress bar's rounded start looked like a slider knob.
            Capsule()
                .fill(Color.primary.opacity(0.1))
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule()
                            .fill(colorScheme == .dark
                                ? Color.green
                                : Color(red: 0.13, green: 0.60, blue: 0.22))
                            .frame(width: proxy.size.width * min(max(level, 0), 1))
                            // Levels arrive every 0.25 s; gliding over that interval reads as live audio, not steps.
                            .animation(reduceMotion ? nil : .linear(duration: 0.25), value: level)
                    }
                }
                .frame(height: 5)
                .accessibilityElement()
                .accessibilityLabel(label)
                .accessibilityValue(percent > 0 ? "\(percent) percent" : "No audio detected")
        }
    }
}
