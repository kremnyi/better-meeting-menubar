import SwiftUI

struct ErrorPanel: View {
    let message: String
    var title: String?
    var details: String?

    var body: some View {
        // The icon sits on the first line's baseline, so it stays beside the title when the text wraps.
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 4) {
                if let title {
                    Text(title)
                        .fontWeight(.semibold)
                }
                Text(message)
                    .foregroundStyle(title == nil ? .primary : .secondary)
                    .textSelection(.enabled)
                if let details {
                    Text(details)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                        .padding(.top, 2)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.red.opacity(0.15)))
    }
}
