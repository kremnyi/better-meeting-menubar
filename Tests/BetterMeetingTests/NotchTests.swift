import AppKit
import SwiftUI
import XCTest
@testable import BetterMeetingApp

@MainActor
final class NotchTests: XCTestCase {
    func testStatusPlacementIsSavedAndDefaultsToMenuBar() throws {
        let (defaults, suite, root) = try makeTempDefaults("BetterMeetingStatusPlacement")
        defer { removeTempDefaults(defaults, suite: suite, root: root) }
        XCTAssertEqual(makeModel(defaults).statusPlacement, .menuBar, "Existing installs keep the menu bar icon")
        makeModel(defaults).statusPlacement = .notch
        XCTAssertEqual(makeModel(defaults).statusPlacement, .notch)
        defaults.set("dock", forKey: "statusPlacement")
        XCTAssertEqual(makeModel(defaults).statusPlacement, .menuBar, "An unknown value must not hide the menu bar icon")
    }

    func testNotchFrameCoversCameraHousing() {
        // 16-inch MacBook Pro at its default scale: the housing spans 771–956 and the safe area is 32 points tall.
        let screen = NSRect(x: 0, y: 0, width: 1728, height: 1117)
        let notched = NotchGeometry.notchFrame(screenFrame: screen, safeAreaTop: 32, leftAreaWidth: 771,
                                               rightAreaWidth: 772, menuBarHeight: 24)
        XCTAssertEqual(notched, NSRect(x: 771, y: 1085, width: 185, height: 32))
        // An external display placed to the right of the built-in one, without a housing.
        let external = NSRect(x: 1728, y: 0, width: 1920, height: 1080)
        let drawn = NotchGeometry.notchFrame(screenFrame: external, safeAreaTop: 0, leftAreaWidth: nil,
                                             rightAreaWidth: nil, menuBarHeight: 24)
        XCTAssertEqual(drawn, NSRect(x: 2598, y: 1056, width: 180, height: 24))
    }

    func testNotchOpensMenuBelowHousingAndRoutesNotificationsOnlyWhileOpen() async throws {
        let (defaults, suite, root) = try makeTempDefaults("BetterMeetingNotch")
        defer { removeTempDefaults(defaults, suite: suite, root: root) }
        _ = NSApplication.shared
        let model = makeModel(defaults)
        await model.historyRefreshTask?.value
        let notch = NotchController(model: model, spinner: MenuBarSpinner())
        notch.setShown(true)
        defer { notch.setShown(false) }
        let panel = try XCTUnwrap(NSApp.windows.first { $0 is NotchPanel })
        let screen = try XCTUnwrap(NotchGeometry.screen)
        let housing = NotchGeometry.notchFrame(on: screen)

        func settle() async {
            for _ in 0..<5 {
                panel.contentView?.layoutSubtreeIfNeeded()
                await Task.yield()
                try? await Task.sleep(for: .milliseconds(20))
            }
        }

        await settle()
        XCTAssertEqual(panel.frame.maxY, screen.frame.maxY, "The panel hangs from the top edge")
        XCTAssertEqual(panel.frame.height, housing.height, "Collapsed, the panel is as tall as the notch")
        XCTAssertEqual(panel.frame.midX, housing.midX, accuracy: 1, "Status sits evenly on both sides of the notch")
        XCTAssertGreaterThan(panel.frame.width, housing.width + 60, "Status needs room beside the housing")
        XCTAssertNil(model.menuWindow, "A collapsed notch must not hide audio and disk warnings")
        try writePreview(of: panel, name: "notch-collapsed")

        notch.expand()
        await settle()
        XCTAssertTrue(notch.expanded)
        XCTAssertEqual(panel.frame.maxY, screen.frame.maxY)
        XCTAssertEqual(panel.frame.midX, housing.midX, accuracy: 1, "The menu opens centred under the notch")
        XCTAssertGreaterThanOrEqual(panel.frame.width, 304, "The menu keeps its fixed width")
        XCTAssertGreaterThan(panel.frame.height, housing.height + 100, "The menu opens below the notch")
        XCTAssertTrue(model.menuWindow === panel, "Notifications must see the open menu")
        try writePreview(of: panel, name: "notch-expanded")

        notch.collapse()
        await settle()
        XCTAssertFalse(notch.expanded)
        XCTAssertEqual(panel.frame.height, housing.height)
        XCTAssertNil(model.menuWindow, "Closing the menu must let warnings through again")
    }

    /// Like `writePanelPreview`, at the size the controller gave the panel.
    private func writePreview(of panel: NSWindow, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["BETTER_MEETING_PANELS_PREVIEW_PATH"],
              let view = panel.contentView else { return }
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try writePNG(bitmap, to: URL(fileURLWithPath: path).appendingPathComponent("\(name).png"))
    }
}
