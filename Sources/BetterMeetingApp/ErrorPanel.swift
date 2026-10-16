import SwiftUI

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
