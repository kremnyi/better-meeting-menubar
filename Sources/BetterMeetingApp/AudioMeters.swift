import SwiftUI

/// Microphone and system-audio levels while recording. They change several times a
/// second, so only the meters observe them instead of the whole menu and menu bar item.
@MainActor
final class AudioMeters: ObservableObject {
    @Published private(set) var microphone = 0.0
    @Published private(set) var system = 0.0

    func update(microphone: Double, system: Double) {
        if self.microphone != microphone { self.microphone = microphone }
        if self.system != system { self.system = system }
    }
}

struct AudioMetersView: View {
    @ObservedObject var meters: AudioMeters

    var body: some View {
        VStack(spacing: 6) {
            meter("Microphone", level: meters.microphone)
            meter("System audio", level: meters.system)
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
                            .fill(Color.green)
                            .frame(width: proxy.size.width * min(max(level, 0), 1))
                    }
                }
                .frame(height: 5)
                .accessibilityElement()
                .accessibilityLabel(label)
                .accessibilityValue(percent > 0 ? "\(percent) percent" : "No audio detected")
        }
    }
}
