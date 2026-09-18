import AppKit
import SwiftUI

struct ModelStorageView: View {
    @EnvironmentObject private var model: AppModel
    @State private var pendingDelete: StoredModelInfo?

    private var busy: Bool {
        model.isProcessing || model.isCapturing || model.modelPreparationTask != nil || model.modelDownloadTask != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(model.storedModels) { item in
                row(item)
            }
            Divider()
            if let error = model.modelDownloadError {
                Text(error)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Show models folder") {
                NSWorkspace.shared.activateFileViewerSelecting([LocalTranscriber.defaultDownloadBase])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { await model.refreshStoredModels() }
    }

    private func row(_ item: StoredModelInfo) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                Text(size(item))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            actions(item)
        }
    }

    @ViewBuilder
    private func actions(_ item: StoredModelInfo) -> some View {
        if pendingDelete?.id == item.id {
            Button("Cancel") { pendingDelete = nil }
            Button("Delete") {
                pendingDelete = nil
                Task { await model.deleteStoredModel(item) }
            }
            .foregroundStyle(.red)
        } else if let fraction = model.modelDownloads[item.id] {
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .frame(width: 70)
            Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                .font(.caption).foregroundStyle(.secondary)
        } else if item.installed {
            Button("Delete…") { pendingDelete = item }
                .disabled(busy)
                .help("Deletes the downloaded files and frees their disk space. They download again when next needed.")
        } else {
            Button("Download") { model.downloadStoredModel(item) }
                .disabled(busy)
                .help("Downloads now so transcription does not wait later")
        }
    }

    /// A downloaded model reads "Downloaded" until the first refresh measures it.
    private func size(_ item: StoredModelInfo) -> String {
        guard item.installed else { return "Not downloaded · about \(ByteCountFormatter.string(fromByteCount: item.downloadBytes, countStyle: .file))" }
        return item.sizeBytes > 0 ? ByteCountFormatter.string(fromByteCount: item.sizeBytes, countStyle: .file) : "Downloaded"
    }
}
