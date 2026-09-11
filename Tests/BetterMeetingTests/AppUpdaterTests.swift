import AppKit
import Combine
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
    func testBetaChannelOptInDefaultsOffAndAppliesToUpdater() throws {
        let suite = "BetterMeetingUpdates.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults)
        XCTAssertFalse(model.betaUpdates)
        XCTAssertFalse(model.updates.allowsBetaUpdates)
        model.betaUpdates = true
        XCTAssertTrue(model.updates.allowsBetaUpdates)
        XCTAssertTrue(AppModel(defaults: defaults).betaUpdates)
        XCTAssertTrue(AppModel(defaults: defaults).updates.allowsBetaUpdates)
        model.betaUpdates = false
        XCTAssertFalse(model.updates.allowsBetaUpdates)
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
    func testBackgroundNoUpdateClearsErrorsAndActions() {
        _ = NSApplication.shared
        let updates = AppUpdater(isBusy: { false })
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: updates, delegate: updates)
        updates.showUpdaterError(URLError(.notConnectedToInternet)) {}
        updates.showReady(toInstallAndRelaunch: { _ in XCTFail("A completed check must discard stale installation actions") })
        let error = NSError(domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue))
        updates.updater(updater, didAbortWithError: error)
        XCTAssertEqual(updates.status, .current)
        XCTAssertNil(updates.errorMessage)
        XCTAssertEqual(updates.actionTitle, "Check for Updates")
        updates.canCheckForUpdates = true
        XCTAssertTrue(updates.canPerformAction)
        updates.status = .ready("test")
        XCTAssertFalse(updates.canPerformAction)
    }

    @MainActor
    func testInstallationWaitsForWorkAndResumesOnlyOnce() {
        _ = NSApplication.shared
        var busy = true
        let updates = AppUpdater(isBusy: { busy })
        var changes = 0
        let observation = updates.objectWillChange.sink { changes += 1 }
        defer { observation.cancel() }
        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: updates, userDriverDelegate: nil
        )
        let item = SUAppcastItem.empty()
        var installations = 0
        XCTAssertTrue(updates.updater(controller.updater, shouldPostponeRelaunchForUpdate: item) {
            installations += 1
        })
        XCTAssertTrue(updates.installationWaiting)
        XCTAssertEqual(changes, 1, "Deferring installation must notify the UI")
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
