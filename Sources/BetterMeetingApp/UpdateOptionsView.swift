import SwiftUI

struct UpdateOptionsView: View {
    @ObservedObject var updates: AppUpdater
    var version: String?

    private var updateInProgress: Bool {
        [.checking, .downloading, .preparing, .installing].contains(updates.status)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button(updates.actionTitle) { updates.performAction() }
                    .disabled(!updates.canPerformAction || version == nil)
                    .opacity(updates.status == .installing ? 0 : 1)
                    .accessibilityHidden(updates.status == .installing)
                if updateInProgress {
                    ProgressView().controlSize(.small).accessibilityHidden(true)
                    Text(updates.status.message)
                        .foregroundStyle(.secondary)
                } else {
                    Spacer(minLength: 8)
                    Text(updates.status.message)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(minHeight: 22)

            if let error = updates.errorMessage {
                Text(error).font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if updates.installationWaiting {
                Text("The update will install when this meeting finishes.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if updates.meetingInProgress {
                Text("Finish recording or processing before updating.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Text(version.map { "Better Meeting · Installed \($0)" } ?? "Better Meeting · Development build")
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Link("Release notes", destination: AppUpdater.releaseURL)
            }
            .font(.caption)
        }
        .font(.callout)
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
