import AppKit
import Combine
import Sparkle

@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate, SPUUserDriver {
    enum Status: Equatable {
        case unchecked, checking, current, available(String), downloaded(String), downloading, preparing, ready(String), installing, failed

        var message: String {
            switch self {
            case .unchecked: ""
            case .checking: "Checking…"
            case .current: "Up to date"
            case .available(let version): "\(version) available"
            case .downloaded(let version): "\(version) downloaded"
            case .downloading: "Downloading update…"
            case .preparing: "Preparing update…"
            case .ready(let version): "\(version) ready to install"
            case .installing: "Restarting…"
            case .failed: "Update failed"
            }
        }
    }

    static let releaseURL = URL(string: "https://github.com/kremnyi/better-meeting-menubar/releases/latest")!
    @Published var status: Status = .unchecked
    @Published var canCheckForUpdates = false
    var installationWaiting: Bool { pendingInstallation != nil }
    @Published private(set) var errorMessage: String?
    var allowsBetaUpdates = false
    let isBusy: () -> Bool
    private var updateAction: (() -> Void)?
    @Published private var pendingInstallation: (() -> Void)?
    private var updateVersion = ""
    private var informationURL: URL?
    private var started = false
    private lazy var updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)

    init(isBusy: @escaping () -> Bool) {
        self.isBusy = isBusy
        super.init()
    }

    // Sparkle ignores items tagged with a channel unless the updater asks for it.
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        allowsBetaUpdates ? ["beta"] : []
    }

    func start(automaticChecks: Bool) {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        updater.automaticallyChecksForUpdates = automaticChecks
        updater.automaticallyDownloadsUpdates = true
        guard !started else { return }
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
        do {
            try updater.start()
            started = true
            if automaticChecks { updater.checkForUpdatesInBackground() }
        } catch {
            showUpdaterError(error) {}
        }
    }

    var actionTitle: String {
        if informationURL != nil { return "View details" }
        switch status {
        case .available: return "Download Update"
        case .downloaded: return "Install Update"
        case .ready: return "Restart to Update"
        case .failed: return "Try Again"
        default: return "Check for Updates"
        }
    }

    var canPerformAction: Bool {
        guard !isBusy() else { return false }
        switch status {
        case .available, .downloaded, .ready: return updateAction != nil
        case .unchecked, .current, .failed: return canCheckForUpdates
        default: return false
        }
    }

    func performAction() {
        guard canPerformAction else { return }
        if let action = updateAction {
            updateAction = nil
            if case .ready = status { status = .installing }
            action()
        } else {
            errorMessage = nil
            status = .checking
            updater.checkForUpdates()
        }
    }

    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        errorMessage = nil
        updateVersion = item.displayVersionString
        status = .downloading
    }

    func updater(_ updater: SPUUpdater, willExtractUpdate item: SUAppcastItem) {
        status = .preparing
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock installHandler: @escaping () -> Void) -> Bool {
        status = .ready(item.displayVersionString)
        updateAction = installHandler
        return true
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let sparkleError = (error as NSError).domain == SUSparkleErrorDomain
        if sparkleError && (error as NSError).code == SUError.noUpdateError.rawValue {
            errorMessage = nil
            status = .current
        } else if sparkleError && (error as NSError).code == SUError.installationCanceledError.rawValue {
            status = .unchecked
        } else {
            errorMessage = error.localizedDescription
            status = .failed
        }
        dismissUpdateInstallation()
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard isBusy() else { return false }
        pendingInstallation = installHandler
        return true
    }

    func resumePendingInstallation() {
        guard !isBusy() else { return }
        let install = pendingInstallation
        pendingInstallation = nil
        install?()
    }

    // Sparkle owns downloads, validation, and installation; its UI stays in our menu.
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) { status = .checking }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        errorMessage = nil
        updateVersion = appcastItem.displayVersionString
        if appcastItem.isInformationOnlyUpdate {
            let url = appcastItem.infoURL
            informationURL = url?.scheme == "https" ? url : Self.releaseURL
            status = .available(updateVersion)
            updateAction = { [weak self] in
                if let url = self?.informationURL { NSWorkspace.shared.open(url) }
                reply(.dismiss)
            }
        } else {
            switch state.stage {
            case .installing: status = .ready(updateVersion)
            case .downloaded: status = .downloaded(updateVersion)
            default: status = .available(updateVersion)
            }
            // Downloaded updates may need authorization; wait for the user's click.
            updateAction = { reply(.install) }
        }
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        status = .ready(updateVersion)
        updateAction = { reply(.install) }
    }

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        errorMessage = nil
        status = .current
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        errorMessage = error.localizedDescription
        status = .failed
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) { status = .downloading }
    func showDownloadDidStartExtractingUpdate() { status = .preparing }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        status = .installing
    }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { acknowledgement() }
    func dismissUpdateInstallation() {
        updateAction = nil
        pendingInstallation = nil
        informationURL = nil
        if status != .failed && status != .current { status = .unchecked }
    }

    // A release-page link and an indeterminate progress indicator keep the menu compact.
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
    func showDownloadDidReceiveData(ofLength length: UInt64) {}
    func showExtractionReceivedProgress(_ progress: Double) {}
}
