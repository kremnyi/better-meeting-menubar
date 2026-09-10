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

    static func recordingMenuBarIcon(for colorScheme: ColorScheme) -> NSImage {
        let pointSize = NSSize(width: 18, height: 18)
        let image = NSImage(size: pointSize, flipped: false) { rect in
            NSGraphicsContext.saveGraphicsState()
            menuBarIcon.draw(in: rect)
            (colorScheme == .dark ? NSColor.white : NSColor.black).setFill()
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
    var processingFrame = 0

    var body: some View {
        Group {
            if state == .processing {
                Image(nsImage: BrandAssets.processingMenuBarFrames[processingFrame])
            } else if state == .failed {
                Image(systemName: "exclamationmark.triangle.fill")
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
        switch state {
        case .idle: "Better Meeting"
        case .preparing: "Better Meeting, preparing to record"
        case .recording: "Better Meeting, recording"
        case .processing: "Better Meeting, processing recording"
        case .failed: "Better Meeting, needs attention"
        }
    }
}

struct MenuBarStatusLabel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var calendar: CalendarIntegration
    let state: AppState
    var processingFrame = 0

    // Menu bar space is scarce and macOS 26 sizes MenuBarExtra from the label's
    // unbounded ideal width, so the preview shows only actionable meetings
    // (in progress, or starting within previewLeadTime) and carries no title:
    // event names are too long to ever fit, so the label states the time only.
    static let previewLeadTime: TimeInterval = 60 * 60

    var body: some View {
        if let event = previewEvent {
            let now = Date()
            let relative = event.relativeStart(at: now)
            HStack(spacing: 5) {
                Image(nsImage: BrandAssets.menuBarIcon)
                    .frame(width: 18, height: 18)
                Text(relative)
                    .foregroundStyle(event.scheduledStart <= now ? Color.signalCoral : Color.primary)
            }
            .font(.system(size: 13))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Better Meeting, next meeting \(event.title), \(relative)")
        } else {
            MenuBarStatusIcon(state: state, processingFrame: processingFrame)
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
              calendar.menuBarPreview,
              calendar.enabled,
              calendar.authorization == .fullAccess
        else { return nil }
        return Self.actionablePreviewEvent(from: calendar.events, at: Date())
    }
}

extension Color {
    static let signalCoral = Color(red: 0.96, green: 0.25, blue: 0.22)
}
