import SwiftUI

struct UpdateOptionsView: View {
    @ObservedObject var updates: AppUpdater
    var version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

    private var updateInProgress: Bool {
        [.checking, .downloading, .preparing, .installing].contains(updates.status)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(version.map { "Version \($0)" } ?? "Development build")
                    .textSelection(.enabled)
                    .layoutPriority(1)
                if updates.status != .unchecked && !updateInProgress {
                    Text("· \(updates.status.message)")
                }
            }
            .lineLimit(1)
            .font(.caption)
            .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    if updateInProgress {
                        Text(updates.status.message).foregroundStyle(.secondary)
                    } else {
                        Button(updates.actionTitle) { updates.performAction() }
                            .disabled(!updates.canPerformAction || version == nil)
                    }
                    Spacer()
                    Link("Release notes", destination: AppUpdater.releaseURL)
                        .font(.caption)
                }
                .frame(minHeight: 22)
                if let error = updates.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(3).help(error)
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
            }
        }
        .font(.callout)
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
