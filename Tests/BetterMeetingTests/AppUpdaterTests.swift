import AppKit
import Sparkle
import XCTest
@testable import BetterMeetingApp

final class AppUpdaterTests: XCTestCase {
    @MainActor
    func testPreservesUpdateOptIn() throws {
        let suite = "BetterMeetingUpdates.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(AppModel(defaults: defaults).automaticUpdateChecks)
        defaults.set(true, forKey: "checkUpdatesOnLaunch")
        let model = AppModel(defaults: defaults)
        XCTAssertTrue(model.automaticUpdateChecks)
        model.automaticUpdateChecks = false
        XCTAssertFalse(AppModel(defaults: defaults).automaticUpdateChecks)
    }

    @MainActor
    func testInlineUpdateWaitsForClickAndNeverRestartsWhileBusy() {
        _ = NSApplication.shared
        var busy = false
        let updates = AppUpdater(isBusy: { busy })
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: updates, delegate: updates)
        let item = SUAppcastItem.empty()
        let windows = NSApp.windows.count
        updates.updater(updater, willDownloadUpdate: item, with: NSMutableURLRequest(url: AppUpdater.releaseURL))
        XCTAssertEqual(updates.status, .downloading)
        XCTAssertFalse(updates.canPerformAction)
        updates.updater(updater, willExtractUpdate: item)
        XCTAssertEqual(updates.status, .preparing)
        var installations = 0
        XCTAssertTrue(updates.updater(updater, willInstallUpdateOnQuit: item) { installations += 1 })
        XCTAssertEqual(updates.status, .ready(item.displayVersionString))
        XCTAssertEqual(updates.actionTitle, "Restart to Update")
        XCTAssertEqual(installations, 0, "Preparation must not trigger a restart")
        busy = true
        XCTAssertFalse(updates.canPerformAction)
        updates.performAction()
        XCTAssertEqual(installations, 0, "A stale UI click must not interrupt a meeting")
        busy = false
        XCTAssertTrue(updates.canPerformAction)
        updates.performAction()
        updates.performAction()
        XCTAssertEqual(installations, 1)
        XCTAssertEqual(updates.status, .installing)

        updates.showReady(toInstallAndRelaunch: { _ in XCTFail("An aborted installation must not run") })
        updates.updater(updater, didAbortWithError: URLError(.notConnectedToInternet))
        XCTAssertEqual(updates.status, .failed)
        XCTAssertNotNil(updates.errorMessage)
        updates.status = .ready(item.displayVersionString)
        XCTAssertFalse(updates.canPerformAction, "Failure must discard the retained install action")
        updates.performAction()
        XCTAssertEqual(NSApp.windows.count, windows, "Update states must not open Sparkle dialogs")
        var acknowledged = false
        updates.showUpdateNotFoundWithError(NSError(domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue))) {
            acknowledged = true
        }
        updates.dismissUpdateInstallation()
        XCTAssertTrue(acknowledged)
        XCTAssertEqual(updates.status, .current)
    }

    @MainActor
    func testInstallationWaitsForWorkAndResumesOnlyOnce() {
        _ = NSApplication.shared
        var busy = true
        let updates = AppUpdater(isBusy: { busy })
        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: updates, userDriverDelegate: nil
        )
        let item = SUAppcastItem.empty()
        var installations = 0
        XCTAssertTrue(updates.updater(controller.updater, shouldPostponeRelaunchForUpdate: item) {
            installations += 1
        })
        XCTAssertTrue(updates.installationWaiting)
        updates.resumePendingInstallation()
        XCTAssertEqual(installations, 0)
        busy = false
        updates.resumePendingInstallation()
        updates.resumePendingInstallation()
        XCTAssertEqual(installations, 1)
        XCTAssertFalse(updates.installationWaiting)
        XCTAssertFalse(updates.updater(controller.updater, shouldPostponeRelaunchForUpdate: item) {
            XCTFail("Sparkle handles an idle installation directly")
        })
        busy = true
        XCTAssertTrue(updates.updater(controller.updater, shouldPostponeRelaunchForUpdate: item) {
            XCTFail("An aborted update must not resume")
        })
        updates.updater(controller.updater, didAbortWithError: URLError(.cancelled))
        busy = false
        updates.resumePendingInstallation()
        XCTAssertFalse(updates.installationWaiting)
    }
}
