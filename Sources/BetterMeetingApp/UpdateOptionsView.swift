import SwiftUI

struct UpdateOptionsView: View {
    @ObservedObject var updates: AppUpdater
    var version: String?

    private var releaseNotesURL: URL {
        let notesVersion: String?
        switch updates.status {
        case .available(let offered), .downloaded(let offered), .ready(let offered): notesVersion = offered
        default: notesVersion = version
        }
        guard let notesVersion, !notesVersion.isEmpty else { return AppUpdater.releaseURL }
        return URL(string: "https://github.com/kremnyi/better-meeting-menubar/releases/tag/v\(notesVersion)") ?? AppUpdater.releaseURL
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button(updates.actionTitle) { updates.performAction() }
                    .disabled(!updates.canPerformAction || version == nil)
                    .fixedSize()
                    .opacity(updates.status == .installing ? 0 : 1)
                    .accessibilityHidden(updates.status == .installing)
                if [.checking, .downloading, .preparing, .installing].contains(updates.status) {
                    ProgressView().controlSize(.small).accessibilityHidden(true)
                }
                Spacer(minLength: 8)
                Text(updates.status.message).wrappingCaption()
            }
            .frame(minHeight: 22)

            if let error = updates.errorMessage {
                ErrorPanel(message: error)
            }
            if updates.installationWaiting {
                Text("The update will install when this meeting finishes.").wrappingCaption()
            } else if updates.isBusy() {
                Text("Finish recording or processing before updating.").wrappingCaption()
            }

            HStack {
                Text(version.map { "Better Meeting · Installed \($0)" } ?? "Better Meeting · Development build")
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Link("Release notes", destination: releaseNotesURL)
            }
            .font(.caption)
        }
        .font(.callout)
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
