import AppKit
import SwiftUI

/// Options → App & updates → About: who made the app, where to find them, and the attribution
/// the Apache License asks derivative works to keep wherever they show credits.
struct AboutView: View {
    var version: String?

    private struct AboutLink: Identifiable {
        let title: String
        let detail: String
        let systemImage: String
        let accessibilityLabel: String
        let url: URL
        var id: String { title }
    }

    private static let links = [
        AboutLink(title: "GitHub", detail: "better-meeting-menubar", systemImage: "chevron.left.forwardslash.chevron.right",
                  accessibilityLabel: "Better Meeting on GitHub",
                  url: URL(string: "https://github.com/kremnyi/better-meeting-menubar")!),
        AboutLink(title: "Website", detail: "kremnyi.com", systemImage: "globe",
                  accessibilityLabel: "Bohdan Kremnyi’s website", url: URL(string: "https://kremnyi.com")!),
        AboutLink(title: "X", detail: "@kremnyi", systemImage: "at",
                  accessibilityLabel: "Bohdan Kremnyi on X", url: URL(string: "https://x.com/kremnyi")!),
        AboutLink(title: "LinkedIn", detail: "in/kremnyi", systemImage: "person.crop.square",
                  accessibilityLabel: "Bohdan Kremnyi on LinkedIn", url: URL(string: "https://www.linkedin.com/in/kremnyi/")!),
    ]

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 2) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .padding(.bottom, 6)
                    .accessibilityHidden(true)
                Text("Better Meeting")
                    .font(.title3.weight(.semibold))
                Text(version.map { "Version \($0)" } ?? "Development build")
                    .font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text("Made by Bohdan Kremnyi")
                    .padding(.top, 8)
            }
            .frame(maxWidth: .infinity)

            VStack(spacing: 0) {
                ForEach(Self.links) { link in
                    LinkRow(link: link)
                    if link.id != Self.links.last?.id {
                        Divider().padding(.leading, 36)
                    }
                }
            }
            .padding(4)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)))

            VStack(spacing: 2) {
                Text("Based on [better-meeting](https://github.com/GivenFLY/better-meeting) © 2026 Oleksii Moshura (GivenFLY)")
                Text("[Apache License 2.0](https://github.com/kremnyi/better-meeting-menubar/blob/main/LICENSE)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
        }
    }

    private struct LinkRow: View {
        let link: AboutLink
        @Environment(\.openURL) private var openURL
        @State private var hovering = false

        var body: some View {
            Button { openURL(link.url) } label: {
                HStack(spacing: 10) {
                    Image(systemName: link.systemImage)
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    Text(link.title)
                    Spacer(minLength: 8)
                    Text(link.detail)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Image(systemName: "arrow.up.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 6)
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(hovering ? Color.primary.opacity(0.06) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
            .onHover { hovering = $0 }
            .help(link.url.absoluteString)
            .accessibilityLabel(link.accessibilityLabel)
        }
    }
}
