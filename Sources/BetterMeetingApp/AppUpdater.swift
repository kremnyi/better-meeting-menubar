import AppKit
import Combine
import Network
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
    private var retryTermination: (() -> Void)?
    private var installWhenReady = false
    @Published private var pendingInstallation: (() -> Void)?
    private var updateVersion = ""
    private var informationURL: URL?
    private var started = false
    private var userInitiated = false
    private static let retryDelays: [Duration] = [.seconds(10), .seconds(60), .seconds(300), .seconds(900), .seconds(3600)]
    private var retries = 0
    private var retryTask: Task<Void, Never>?
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
        // Start once: toggling automatic checks must not retry a failed start or stack subscriptions.
        guard !started else { return }
        started = true
        do {
            try updater.start()
            updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
            if automaticChecks { updater.checkForUpdatesInBackground() }
        } catch {
            showUpdaterError(error) {}
        }
    }

    var actionTitle: String {
        if informationURL != nil { return "View details" }
        switch status {
        case .available, .downloaded, .downloading, .preparing: return "Update and Restart"
        case .ready: return "Restart to Update"
        case .failed: return "Try Again"
        default: return "Check for Updates"
        }
    }

    var canPerformAction: Bool {
        guard !isBusy() else { return false }
        switch status {
        case .available, .downloaded, .ready: return updateAction != nil || retryTermination != nil
        case .unchecked, .current, .failed: return canCheckForUpdates
        default: return false
        }
    }

    func performAction() {
        guard canPerformAction else { return }
        userInitiated = true
        if let retryTermination {
            retryTermination()
            return
        }
        if let action = updateAction {
            updateAction = nil
            switch status {
            case .ready: status = .installing
            case .available, .downloaded: installWhenReady = informationURL == nil
            default: break
            }
            action()
        } else {
            errorMessage = nil
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
        updateVersion = item.displayVersionString
        status = .ready(updateVersion)
        updateAction = installHandler
        return true
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let sparkleError = (error as NSError).domain == SUSparkleErrorDomain
        if sparkleError && (error as NSError).code == SUError.noUpdateError.rawValue {
            errorMessage = nil
            status = .current
            retries = 0
        } else if sparkleError && (error as NSError).code == SUError.installationCanceledError.rawValue {
            status = .unchecked
        } else if userInitiated {
            errorMessage = error.localizedDescription
            status = .failed
        } else {
            // Sparkle hides background failures, such as a launch before the network connects; retry later.
            retryBackgroundCheck()
        }
        dismissUpdateInstallation()
    }

    // Sparkle calls this after every cycle, also one that ends without an error, such as View details.
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        userInitiated = false
        if error == nil { retries = 0 }
    }

    private func retryBackgroundCheck() {
        guard started, retries < Self.retryDelays.count else { return }
        let delay = Self.retryDelays[retries]
        retries += 1
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            for await path in NWPathMonitor() where path.status == .satisfied { break }
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, canCheckForUpdates, updater.automaticallyChecksForUpdates else { return }
            updater.checkForUpdatesInBackground()
        }
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
        // Sparkle still postpones the relaunch while a recording or transcription runs.
        if installWhenReady {
            installWhenReady = false
            status = .installing
            reply(.install)
            return
        }
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
        updateAction = nil
        // Termination may be canceled more than once; keep the retry available until Sparkle finishes.
        retryTermination = applicationTerminated ? nil : retryTerminatingApplication
        status = applicationTerminated ? .installing : .ready(updateVersion)
    }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { acknowledgement() }
    func dismissUpdateInstallation() {
        updateAction = nil
        retryTermination = nil
        installWhenReady = false
        pendingInstallation = nil
        informationURL = nil
        if status != .failed && status != .current { status = .unchecked }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
    func showDownloadDidReceiveData(ofLength length: UInt64) {}
    func showExtractionReceivedProgress(_ progress: Double) {}
}
