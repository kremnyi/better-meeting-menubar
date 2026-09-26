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

    // The label redraws often while recording; build each appearance's icon once.
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
    /// Idle work waits: permissions to grant or recordings to transcribe.
    var attention = false

    var body: some View {
        Group {
            if processing, state == .idle {
                Image(nsImage: BrandAssets.processingMenuBarFrames[processingFrame])
            } else if state == .failed {
                Image(systemName: "exclamationmark.triangle.fill")
            } else if attention, state == .idle {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(colorScheme == .dark ? Color.orange : Color.attentionOrange)
            } else {
                Image(
                    nsImage: state == .recording
                        ? BrandAssets.recordingMenuBarIcon(for: colorScheme)
                        : BrandAssets.menuBarIcon
                )
            }
        }
        .frame(width: 18, height: 18)
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
        case .failed: "Better Meeting, needs attention"
        }
    }
}

/// Frames for the menu-bar processing spinner. The timer lives here so 10 Hz
/// updates redraw the label that observes this object, not the whole App scene.
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
    let state: AppState
    // Plain values rather than the model, so progress updates don't redraw the menu bar item.
    var processing = false
    /// Permissions to grant or recordings to transcribe; beats the calendar preview.
    var attention = false
    /// Whether to show elapsed time beside the icon while recording.
    var showRecordingTime = false

    // Menu bar space is scarce and macOS 26 sizes MenuBarExtra from the label's
    // unbounded ideal width, so the preview shows only actionable meetings
    // (in progress, or starting within previewLeadTime) and carries no title:
    // event names are too long to ever fit, so the label states the time only.
    static let previewLeadTime: TimeInterval = 60 * 60

    var body: some View {
        if state == .recording, showRecordingTime {
            let elapsed = Timecode.compact(clock.elapsed)
            HStack(spacing: 5) {
                MenuBarStatusIcon(state: state)
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
            MenuBarStatusIcon(state: state, processing: processing, processingFrame: spinner.frame, attention: attention)
        }
    }

    // Picks the first actionable meeting: in progress, or starting within
    // previewLeadTime. Tomorrow's meetings surface only in that final hour.
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

extension Color {
    /// WCAG AA (≥4.5:1) with white button labels and on light backgrounds.
    static let signalCoral = Color(red: 0.85, green: 0.16, blue: 0.13)
    /// The original bright coral; AA on the dark menu bar (5.66:1) but not on light chrome.
    static let signalCoralBright = Color(red: 0.96, green: 0.25, blue: 0.22)
    /// Attention icons: ≥3:1 non-text contrast on light backgrounds; system orange on dark (7.6:1).
    static let attentionOrange = Color(red: 0.85, green: 0.45, blue: 0.0)
}
