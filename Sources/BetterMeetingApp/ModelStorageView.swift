import AppKit
import SwiftUI

struct ModelStorageView: View {
    @EnvironmentObject private var model: AppModel
    @State private var pendingDelete: StoredModelInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Downloaded models").font(.headline)
            ForEach(model.storedModels) { item in
                row(item)
            }
            Divider()
            Button("Show models folder") {
                NSWorkspace.shared.activateFileViewerSelecting([LocalTranscriber.defaultDownloadBase])
            }
            Text("Models stay on this Mac. Deleting one frees its disk space; it downloads again the next time it is needed.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { await model.refreshStoredModels() }
        .confirmationDialog(
            pendingDelete.map { "Delete \($0.title)?" } ?? "Delete model?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let item = pendingDelete else { return }
                pendingDelete = nil
                Task { await model.deleteStoredModel(item) }
            }
        } message: {
            Text("It downloads again the next time it is needed.")
        }
    }

    private func row(_ item: StoredModelInfo) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                Text(item.installed
                    ? ByteCountFormatter.string(fromByteCount: item.sizeBytes, countStyle: .file)
                    : "Not downloaded")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if item.installed {
                Button("Reveal") {
                    NSWorkspace.shared.activateFileViewerSelecting([item.url])
                }
                Button("Delete…") { pendingDelete = item }
                    .disabled(model.isProcessing || model.isCapturing || model.modelPreparationTask != nil)
            }
        }
    }

}
