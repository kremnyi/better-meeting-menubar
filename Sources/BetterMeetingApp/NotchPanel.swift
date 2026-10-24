import AppKit
import SwiftUI

/// Where the app shows its status and opens its menu.
enum StatusPlacement: String, CaseIterable, Identifiable {
    case menuBar, notch, both

    var id: Self { self }

    var label: String {
        switch self {
        case .menuBar: "Menu bar"
        case .notch: "Notch"
        case .both: "Menu bar and notch"
        }
    }

    var showsMenuBarIcon: Bool { self != .notch }
    var showsNotch: Bool { self != .menuBar }
}

enum NotchGeometry {
    /// Width of the drawn notch on a display without a camera housing.
    static let drawnWidth: CGFloat = 180

    /// The camera housing in screen coordinates, or a drawn notch centred on the top edge of a display without one.
    static func notchFrame(screenFrame: NSRect, safeAreaTop: CGFloat, leftAreaWidth: CGFloat?,
                           rightAreaWidth: CGFloat?, menuBarHeight: CGFloat) -> NSRect {
        guard safeAreaTop > 0, let leftAreaWidth, let rightAreaWidth else {
            return NSRect(x: screenFrame.midX - drawnWidth / 2, y: screenFrame.maxY - menuBarHeight,
                          width: drawnWidth, height: menuBarHeight)
        }
        // The housing can sit half a point off centre, so measure from the left edge.
        return NSRect(x: screenFrame.minX + leftAreaWidth, y: screenFrame.maxY - safeAreaTop,
                      width: screenFrame.width - leftAreaWidth - rightAreaWidth, height: safeAreaTop)
    }

    static func notchFrame(on screen: NSScreen) -> NSRect {
        notchFrame(screenFrame: screen.frame, safeAreaTop: screen.safeAreaInsets.top,
                   leftAreaWidth: screen.auxiliaryTopLeftArea?.width,
                   rightAreaWidth: screen.auxiliaryTopRightArea?.width,
                   menuBarHeight: NSStatusBar.system.thickness)
    }

    /// The built-in display while it is on; otherwise the main display.
    static var screen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }
}

/// Shows status beside the notch and opens the menu below it on click.
@MainActor
final class NotchController: ObservableObject {
    @Published private(set) var expanded = false
    @Published private(set) var notchSize = CGSize(width: NotchGeometry.drawnWidth, height: 24)
    private let model: AppModel
    private let spinner: MenuBarSpinner
    private var panel: NotchPanel?
    private var anchor = NSPoint.zero
    private var contentSize = CGSize.zero
    private var observers: [NSObjectProtocol] = []
    private var clickMonitor: Any?

    init(model: AppModel, spinner: MenuBarSpinner) {
        self.model = model
        self.spinner = spinner
    }

    var isShown: Bool { panel != nil }

    func setShown(_ shown: Bool) {
        if shown { show() } else { hide() }
    }

    private func show() {
        guard panel == nil else { return }
        let panel = NotchPanel()
        panel.onCancel = { [weak self] in self?.collapse() }
        panel.onInactiveClick = { [weak self] in
            guard let self, !expanded else { return false }
            expand()
            return true
        }
        let content = NSHostingView(rootView:
            NotchView(controller: self, spinner: spinner, clock: model.recordingClock, calendar: model.calendar)
                .environmentObject(model)
                .environmentObject(model.updates)
        )
        // The controller sizes the panel from the content, anchored to the notch.
        content.sizingOptions = []
        panel.contentView = content
        self.panel = panel
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.place() }
            },
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.collapse() }
            },
        ]
        place()
        panel.orderFrontRegardless()
    }

    private func hide() {
        collapse()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        panel?.orderOut(nil)
        panel = nil
    }

    private func place() {
        guard let screen = NotchGeometry.screen else { return }
        let notch = NotchGeometry.notchFrame(on: screen)
        if notchSize != notch.size { notchSize = notch.size }
        anchor = NSPoint(x: notch.midX, y: notch.maxY)
        resize(to: contentSize)
    }

    func resize(to size: CGSize) {
        contentSize = size
        guard let panel, size.width > 0, size.height > 0 else { return }
        panel.setFrame(NSRect(x: (anchor.x - size.width / 2).rounded(), y: anchor.y - size.height,
                              width: size.width, height: size.height), display: false)
        panel.invalidateShadow()
    }

    func toggle() {
        expanded ? collapse() : expand()
    }

    func expand() {
        guard let panel, !expanded else { return }
        expanded = true
        panel.hasShadow = true
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        // Clicks in other apps; clicks in the app's own popovers and sheets keep the menu open.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.collapse() }
        }
    }

    func collapse() {
        guard expanded else { return }
        expanded = false
        panel?.hasShadow = false
        clickMonitor.map(NSEvent.removeMonitor)
        clickMonitor = nil
        // Return the keyboard to the previous app, as closing a menu does.
        if NSApp.isActive { NSApp.deactivate() }
    }
}

final class NotchPanel: NSPanel {
    var onCancel: (() -> Void)?
    /// Returns true when it handled the click.
    var onInactiveClick: (() -> Bool)?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Above the menu bar, and over full-screen apps where the menu bar is hidden.
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false
        canHide = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        appearance = NSAppearance(named: .darkAqua)
    }

    // The menu's search field and Options page need keyboard input.
    override var canBecomeKey: Bool { true }

    // SwiftUI spends the first click on a panel that isn't key making it key, so the notch would need two clicks.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, !isKeyWindow, onInactiveClick?() == true { return }
        super.sendEvent(event)
    }

    // Escape reaches the panel only after the search field and popovers decline it.
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

struct NotchView: View {
    @ObservedObject var controller: NotchController
    @ObservedObject var spinner: MenuBarSpinner
    @ObservedObject var clock: RecordingClock
    @ObservedObject var calendar: CalendarIntegration
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let radius: CGFloat = controller.expanded ? 18 : 10
        VStack(spacing: 0) {
            statusRow
            if controller.expanded {
                MenuBarControlView()
            }
        }
        .background(Color.black)
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius))
        .environment(\.colorScheme, .dark)
        .fixedSize()
        .onGeometryChange(for: CGSize.self, of: \.size) { size in
            // Resizing the window inside its own layout pass makes SwiftUI lay it out again.
            DispatchQueue.main.async { controller.resize(to: size) }
        }
    }

    private var statusRow: some View {
        let breath = MenuBarStatusLabel.recordingBreath(elapsed: clock.elapsed, reduceMotion: reduceMotion)
        let detail = statusDetail
        // Equal sides keep the camera housing centred.
        let side: CGFloat = detail == nil ? 34 : 66
        let icon = MenuBarStatusIcon(state: model.state, processing: model.processing.isProcessing,
                                     processingFrame: spinner.frame, attention: model.needsAttention, breath: breath)
        return HStack(spacing: 0) {
            icon
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.6), value: breath)
                .frame(width: side)
            Color.clear.frame(width: controller.notchSize.width)
            Color.clear
                .frame(width: side)
                .overlay {
                    if let detail {
                        Text(detail.text)
                            .monospacedDigit()
                            .foregroundStyle(detail.highlighted ? Color.signalCoralBright : Color.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                }
                .font(.system(size: 13, weight: .medium))
        }
        .frame(height: controller.notchSize.height)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(perform: controller.toggle)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(icon: icon, detail: detail?.text))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, controller.toggle)
        .help(controller.expanded ? "Close Better Meeting" : "Open Better Meeting")
    }

    private var statusDetail: (text: String, highlighted: Bool)? {
        if model.state == .recording { return (Timecode.compact(clock.elapsed), true) }
        guard !model.needsAttention,
              let event = MenuBarStatusLabel.previewEvent(
                  calendar: calendar, state: model.state, processing: model.processing.isProcessing)
        else { return nil }
        let now = Date()
        return (event.relativeStart(at: now, compact: true), event.scheduledStart <= now)
    }

    private func accessibilityLabel(icon: MenuBarStatusIcon, detail: String?) -> String {
        guard let detail else { return icon.statusDescription }
        return model.state == .recording ? "Better Meeting, recording, \(detail)" : "Better Meeting, next meeting \(detail)"
    }
}
