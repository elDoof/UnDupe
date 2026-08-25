import SwiftUI
import AppKit
import UnDupeCore

/// Review-first duplicate manager. Identical files are grouped; the user picks
/// which copies to trash. We never let a group lose its last copy.
struct DuplicatesView: View {
    @EnvironmentObject var model: AppModel

    /// File ids marked for trashing (everything not marked is kept).
    @State private var marked: Set<UUID> = []

    var body: some View {
        Group {
            if model.isFindingDuplicates {
                findingState
            } else if model.duplicates.isEmpty {
                emptyState
            } else {
                resultsList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: model.duplicates.count) { _ in resetSelection() }
        .onAppear { if marked.isEmpty { resetSelection() } }
    }

    // MARK: - States

    private var findingState: some View {
        VStack(spacing: 16) {
            ProgressView().scaleEffect(1.3).tint(Theme.accent)
            Text("Finding duplicates…")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
            if model.dupTotal > 0 {
                Text("Hashed \(model.dupHashed.formatted()) of \(model.dupTotal.formatted()) candidates")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 40))
                .foregroundStyle(Theme.success)
            Text("No duplicates found")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
            Text("Nothing redundant in what you scanned.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
        }
    }

    private var resultsList: some View {
        VStack(spacing: 0) {
            summaryBar
            Divider().overlay(Theme.hairline)
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(model.duplicates) { group in
                        groupCard(group)
                    }
                }
                .padding(16)
            }
        }
    }

    private var summaryBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(model.duplicates.count) duplicate sets")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                Text("Up to \(ByteFormat.string(model.totalReclaimable)) reclaimable")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            Text("\(markedReclaimable.count) selected · \(ByteFormat.string(markedReclaimableBytes))")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText)
            Button { resetSelection() } label: {
                Label("Reset", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .help("Re-select the default: keep one copy of each set, trash the rest")
            Button(role: .destructive) { trashMarked() } label: {
                Label("Move Selected to Trash", systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.danger)
            .disabled(markedReclaimable.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func groupCard(_ group: DuplicateGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.success)
                Text("\(group.files.count) identical files")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                Text("· \(ByteFormat.string(group.sizeBytes)) each")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
                Text("verified byte-for-byte")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiaryText)
            }
            ForEach(group.files) { file in
                fileRow(file, in: group)
            }
        }
        .padding(12)
        .glassPanel(cornerRadius: 12)
    }

    private func fileRow(_ file: FileNode, in group: DuplicateGroup) -> some View {
        let isMarked = marked.contains(file.id)
        let isLastKept = !isMarked && keptCount(in: group) == 1
        return HStack(spacing: 10) {
            Button {
                toggle(file, in: group)
            } label: {
                Image(systemName: isMarked ? "trash.circle.fill" : "checkmark.circle")
                    .font(.system(size: 16))
                    .foregroundStyle(isMarked ? Theme.danger : Theme.success)
            }
            .buttonStyle(.plain)
            .disabled(isLastKept)            // can't trash the only remaining copy
            .help(isMarked ? "Will be moved to Trash" : (isLastKept ? "Kept (last copy)" : "Kept"))
            .accessibilityLabel(isMarked ? "Marked for Trash, activate to keep" : (isLastKept ? "Kept, last copy" : "Kept, activate to mark for Trash"))
            .accessibilityValue(file.path)

            Text(file.path)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(isMarked ? Theme.tertiaryText : Theme.primaryText)
                .strikethrough(isMarked)
                .lineLimit(1).truncationMode(.middle)
                .animation(.easeOut(duration: 0.15), value: isMarked)

            Spacer()

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)])
            } label: {
                Image(systemName: "magnifyingglass").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.secondaryText)
            .help("Reveal in Finder")
            .accessibilityLabel("Reveal in Finder")
        }
        .padding(.vertical, 3)
    }

    // MARK: - Selection logic

    /// Default selection: keep the copy with the shortest path (likely the
    /// original / least-nested), mark the rest for trashing.
    private func resetSelection() {
        var next: Set<UUID> = []
        for group in model.duplicates {
            let sorted = group.files.sorted { $0.path.count < $1.path.count }
            for file in sorted.dropFirst() { next.insert(file.id) }
        }
        marked = next
    }

    private func keptCount(in group: DuplicateGroup) -> Int {
        group.files.filter { !marked.contains($0.id) }.count
    }

    private func toggle(_ file: FileNode, in group: DuplicateGroup) {
        if marked.contains(file.id) {
            marked.remove(file.id)
        } else if keptCount(in: group) > 1 {
            marked.insert(file.id)        // refuse to mark the last kept copy
        }
    }

    private var markedReclaimable: [FileNode] {
        model.duplicates.flatMap { $0.files }.filter { marked.contains($0.id) }
    }

    private var markedReclaimableBytes: Int64 {
        markedReclaimable.reduce(0) { $0 + $1.size }
    }

    private func trashMarked() {
        let files = markedReclaimable
        guard !files.isEmpty else { return }
        model.trash(files)
        marked.removeAll()
    }
}
