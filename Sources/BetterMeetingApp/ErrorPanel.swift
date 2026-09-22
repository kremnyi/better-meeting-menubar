import SwiftUI

/// The one failure panel: a cause-aware title, the error's own message, and the
/// error domain behind a Details disclosure. Recording failures, update errors,
/// calendar errors, and model download errors all render through here so a
/// failure looks the same wherever it happens.
struct ErrorPanel: View {
    let message: String
    var title: String?
    var details: String?

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                if let title {
                    Text(title)
                        .fontWeight(.medium)
                }
                Text(message)
                    .foregroundStyle(title == nil ? .primary : .secondary)
                    .textSelection(.enabled)
                if let details {
                    DisclosureGroup("Details") {
                        Text(details)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .font(.caption)
                    .tint(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}
