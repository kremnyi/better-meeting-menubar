import AppKit
import SwiftUI

enum BrandAssets {
    static let menuBarIcon: NSImage = {
        guard let image = NSImage(named: "MenuBarIconTemplate") else {
            return NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)!
        }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }()

    // MenuBarExtra extracts an image from its label; symbol effects do not animate it.
    static let processingMenuBarFrames: [NSImage] = (0..<12).map { frame in
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            let arc = NSBezierPath()
            arc.lineWidth = 2
            arc.lineCapStyle = .round
            let angle = CGFloat(frame) * -30
            arc.appendArc(withCenter: NSPoint(x: 9, y: 9), radius: 6,
                          startAngle: angle, endAngle: angle + 270)
            arc.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }

    private static let recordingIconLight = makeRecordingMenuBarIcon(dark: false)
    private static let recordingIconDark = makeRecordingMenuBarIcon(dark: true)

    static func recordingMenuBarIcon(for colorScheme: ColorScheme) -> NSImage {
        colorScheme == .dark ? recordingIconDark : recordingIconLight
    }

    private static func makeRecordingMenuBarIcon(dark: Bool) -> NSImage {
        let pointSize = NSSize(width: 18, height: 18)
        let image = NSImage(size: pointSize, flipped: false) { rect in
            NSGraphicsContext.saveGraphicsState()
            menuBarIcon.draw(in: rect)
            (dark ? NSColor.white : NSColor.black).setFill()
            rect.fill(using: .sourceIn)
            NSGraphicsContext.restoreGraphicsState()

            NSColor.systemRed.setFill()
            // Tint the artwork's lower-right dot while preserving its alpha mask.
            NSRect(x: 13, y: 0, width: 5, height: 5).fill(using: .sourceAtop)
            return true
        }
        image.isTemplate = false
        return image
    }
}

struct MenuBarStatusIcon: View {
    @Environment(\.colorScheme) private var colorScheme

    let state: AppState
    var processing = false
    var processingFrame = 0
    var attention = false
    var breath: Double = 1

    var body: some View {
        Group {
            if processing, state == .idle {
                Image(nsImage: BrandAssets.processingMenuBarFrames[processingFrame])
            } else if state == .failed {
                Image(systemName: "exclamationmark.triangle.fill")
            } else if attention, state == .idle {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.attention(colorScheme))
            } else {
                Image(
                    nsImage: state == .recording
                        ? BrandAssets.recordingMenuBarIcon(for: colorScheme)
                        : BrandAssets.menuBarIcon
                )
            }
        }
        .frame(width: 18, height: 18)
        .opacity(state == .recording ? breath : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        if processing, state == .idle { return "Better Meeting, processing recording" }
        if attention, state == .idle { return "Better Meeting, needs attention" }
        return switch state {
        case .idle: "Better Meeting"
        case .preparing: "Better Meeting, preparing to record"
        case .recording: "Better Meeting, recording"
        case .stopping: "Better Meeting, stopping recording"
        case .failed: "Better Meeting, needs attention"
        }
    }
}

/// Separate object so the 10 Hz frames redraw only the label, not the whole App scene.
@MainActor
final class MenuBarSpinner: ObservableObject {
    @Published private(set) var frame = 0
    private var timer: Timer?

    func setAnimating(_ animate: Bool) {
        timer?.invalidate()
        timer = nil
        frame = 0
        guard animate else { return }
        let count = BrandAssets.processingMenuBarFrames.count
        // Added to the main run loop, so the callback already runs on the main actor.
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.frame = (self.frame + 1) % count
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}

struct MenuBarStatusLabel: View {
    @ObservedObject var calendar: CalendarIntegration
    @ObservedObject var spinner: MenuBarSpinner
    @ObservedObject var clock: RecordingClock
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let state: AppState
    // Plain values rather than the model, so progress updates don't redraw the menu bar item.
    var processing = false
    var attention = false
    var showRecordingTime = false

    // macOS 26 sizes MenuBarExtra from the label's unbounded ideal width, so the preview shows the time only.
    static let previewLeadTime: TimeInterval = 60 * 60

    /// Stepped by the clock's 1 Hz tick, so a closed menu redraws no faster than the elapsed time needs.
    static func recordingBreath(elapsed: TimeInterval, reduceMotion: Bool) -> Double {
        guard !reduceMotion else { return 1 }
        return Int(elapsed / 2) % 2 == 0 ? 1 : 0.45
    }

    var body: some View {
        let breath = Self.recordingBreath(elapsed: clock.elapsed, reduceMotion: reduceMotion)
        if state == .recording, showRecordingTime {
            let elapsed = Timecode.compact(clock.elapsed)
            HStack(spacing: 5) {
                MenuBarStatusIcon(state: state, breath: breath)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.6), value: breath)
                Text(elapsed)
                    .monospacedDigit()
            }
            .font(.system(size: 13))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Better Meeting, recording, \(elapsed)")
        } else if !attention, let event = previewEvent {
            let now = Date()
            let relative = event.relativeStart(at: now, compact: true)
            HStack(spacing: 5) {
                Image(nsImage: BrandAssets.menuBarIcon)
                    .frame(width: 18, height: 18)
                Text(relative)
                    .foregroundStyle(event.scheduledStart <= now
                        ? (colorScheme == .dark ? Color.signalCoralBright : Color.signalCoral)
                        : Color.primary)
            }
            .font(.system(size: 13))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Better Meeting, next meeting \(event.title), \(relative)")
        } else {
            MenuBarStatusIcon(state: state, processing: processing, processingFrame: spinner.frame,
                              attention: attention, breath: breath)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.6), value: breath)
        }
    }

    static func actionablePreviewEvent(from events: [CalendarEvent], at now: Date) -> CalendarEvent? {
        events.first { event in
            if event.scheduledStart <= now { return event.scheduledEnd > now }
            return event.scheduledStart.timeIntervalSince(now) <= previewLeadTime
        }
    }

    private var previewEvent: CalendarEvent? {
        guard state == .idle,
              !processing,
              calendar.menuBarPreview,
              calendar.enabled,
              calendar.authorization == .fullAccess
        else { return nil }
        return Self.actionablePreviewEvent(from: calendar.events, at: Date())
    }
}

private struct HoverHighlight: ViewModifier {
    let cornerRadius: CGFloat
    let pressed: Bool
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(
                Color.primary.opacity(pressed ? 0.1 : hovering ? 0.06 : 0),
                in: RoundedRectangle(cornerRadius: cornerRadius)
            )
            .onHover { hovering = $0 }
    }
}

extension View {
    func hoverHighlight(cornerRadius: CGFloat, pressed: Bool = false) -> some View {
        modifier(HoverHighlight(cornerRadius: cornerRadius, pressed: pressed))
    }

    /// Secondary caption text aligned with a checkbox's title rather than its box.
    func toggleCaption() -> some View {
        font(.caption).foregroundStyle(.secondary).padding(.leading, 18)
    }

    func wrappingCaption() -> some View {
        font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    /// Apply `.disabled` before this so it dims only the toggle; the caption explains the setting either way.
    func setting(help: LocalizedStringKey? = nil, caption: LocalizedStringKey? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            self.help(help ?? "")
            if let caption { Text(caption).toggleCaption() }
        }
    }

    func gridPicker(_ label: LocalizedStringKey, disabled: Bool) -> some View {
        labelsHidden().frame(maxWidth: .infinity).disabled(disabled).accessibilityLabel(label)
    }
}

extension Color {
    /// WCAG AA (≥4.5:1) with white button labels and on light backgrounds.
    static let signalCoral = Color(red: 0.85, green: 0.16, blue: 0.13)
    static let signalCoralHover = Color(red: 0.78, green: 0.13, blue: 0.10)
    /// AA on the dark menu bar (5.66:1) but not on light chrome.
    static let signalCoralBright = Color(red: 0.96, green: 0.25, blue: 0.22)
    /// ≥3:1 non-text contrast on light backgrounds; system orange on dark (7.6:1).
    static let attentionOrange = Color(red: 0.85, green: 0.45, blue: 0.0)

    static func attention(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? .orange : attentionOrange
    }
}
