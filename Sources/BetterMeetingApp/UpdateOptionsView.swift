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
            } else if updates.isBusy() {
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

/// Who made the app, and the attribution the Apache License asks derivative works to keep in their credits.
struct AppCreditsView: View {
    static let links: [(title: String, label: String, url: URL)] = [
        ("GitHub", "Better Meeting on GitHub", URL(string: "https://github.com/kremnyi/better-meeting-menubar")!),
        ("Website", "Bohdan Kremnyi’s website", URL(string: "https://kremnyi.com")!),
        ("X", "Bohdan Kremnyi on X", URL(string: "https://x.com/kremnyi")!),
        ("LinkedIn", "Bohdan Kremnyi on LinkedIn", URL(string: "https://www.linkedin.com/in/kremnyi/")!),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text("Made by Bohdan Kremnyi")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                ForEach(Self.links, id: \.title) { link in
                    Link(link.title, destination: link.url)
                        .help(link.url.absoluteString)
                        .accessibilityLabel(link.label)
                }
            }
            Text("Based on [better-meeting](https://github.com/GivenFLY/better-meeting) © 2026 Oleksii Moshura (GivenFLY). Licensed under [Apache 2.0](https://github.com/kremnyi/better-meeting-menubar/blob/main/LICENSE).")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
