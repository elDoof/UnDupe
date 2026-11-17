import SwiftUI
import Foundation
import UnDupeCore

/// Review-first duplicate manager. Identical files are grouped; the user picks
/// which copies to trash. We never let a group lose its last copy.
///
/// The selection itself lives in `AppModel` (and its rules in
/// `DuplicateSelection`), so it survives a trip to the map and back and every
/// route to the Trash is held to the same keep-one guarantee.
struct DuplicatesView: View {
    @EnvironmentObject var model: AppModel

    /// Drives the confirmation dialog for the batch trash.
    @State private var isConfirmingTrash = false

    var body: some View {
        Group {
            if model.isFindingDuplicates {
                findingState
            } else if !model.hasSearchedDuplicates {
                notSearchedState
            } else if model.duplicates.isEmpty {
                emptyState
            } else {
                resultsList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Trashing several files at once is the most destructive thing this
        // screen does, so it gets the same confirmation the map's single-item
        // trash has always had.
        .confirmationDialog(
            "Move \(CountFormat.string(markedFiles.count, "item")) to Trash?",
            isPresented: $isConfirmingTrash
        ) {
            Button("Move to Trash", role: .destructive) { model.trashMarkedDuplicates() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(ByteFormat.string(markedBytes)) will be reclaimed. Every set keeps at least one copy, and you can restore anything from the Trash.")
        }
    }

    // MARK: - States

    private var findingState: some View {
        VStack(spacing: 16) {
            if model.dupTotal > 0 {
                ProgressView(value: Double(model.dupHashed), total: Double(model.dupTotal))
                    .tint(Theme.accent)
                    .frame(width: 260)
            } else {
                ProgressView().scaleEffect(1.3).tint(Theme.accent)
            }
            Text("Finding duplicates…")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
            Text(model.dupTotal > 0
                 ? "Compared \(CountFormat.number(model.dupHashed)) of \(CountFormat.string(model.dupTotal, "candidate"))"
                 : "Grouping files by size…")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Theme.secondaryText)
            Button("Cancel") { model.cancelDuplicateSearch() }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
                .padding(.top, 4)
        }
    }

    /// Shown when no search has finished for this scan — in practice, after the
    /// user cancelled one. Opening the tab starts a search on its own.
    private var notSearchedState: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 36))
                .foregroundStyle(Theme.secondaryText)
            Text("Duplicates haven't been searched")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
            Text(floorNote)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
            Button("Find Duplicates") { model.findDuplicates() }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .padding(.top, 4)
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
            Text("No two files share the same contents. \(floorNote)")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button("Search Again") { model.findDuplicates() }
                .buttonStyle(.bordered)
                .padding(.top, 4)
                .help("Compare the scanned files again")
        }
    }

    /// States the size floor wherever a result (or its absence) is reported, so
    /// "no duplicates" is never read as "no duplicates of any size".
    private var floorNote: String {
        "Only files of \(ByteFormat.string(DuplicateFinder.defaultMinSize)) or more are compared."
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
                Text(CountFormat.string(model.duplicates.count, "duplicate set"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                Text("Up to \(ByteFormat.string(model.totalReclaimable)) reclaimable")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            Text("\(CountFormat.number(markedFiles.count)) selected · \(ByteFormat.string(markedBytes))")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Theme.secondaryText)
            Button { model.resetDuplicateSelection() } label: {
                Label("Reset", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .help("Re-select the default: keep one copy of each set, trash the rest")
            Button(role: .destructive) { isConfirmingTrash = true } label: {
                Label("Move Selected to Trash", systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.danger)
            .disabled(markedFiles.isEmpty)
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
        let isMarked = model.markedDuplicateIDs.contains(file.id)
        let isLastKept = DuplicateSelection.isLastKept(file, in: group, marked: model.markedDuplicateIDs)
        return HStack(spacing: 10) {
            Button {
                model.toggleDuplicateMark(file, in: group)
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
                .help(file.path)
                .animation(.easeOut(duration: 0.15), value: isMarked)

            Spacer()

            Button { FileActions.reveal(file.path) } label: {
                Image(systemName: "magnifyingglass").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.secondaryText)
            .help("Reveal in Finder")
            .accessibilityLabel("Reveal in Finder")
        }
        .padding(.vertical, 3)
        .contextMenu {
            FileContextMenu(
                path: file.path,
                name: file.name,
                sizeBytes: file.size,
                isDirectory: false,
                // Trashing straight from the menu would bypass the review model
                // this screen is built on, so the last kept copy stays protected
                // exactly as the checkbox is.
                extraTrashBlock: isLastKept
                    ? "This is the last copy in its set — UnDupe always keeps one."
                    : nil,
                onReveal: { FileActions.reveal(file.path) },
                onTrash: { model.trashDuplicate(file, in: group) }
            )
        }
    }

    // MARK: - Derived

    /// The marked copies that are still in a set. Marks for files that have
    /// since left the list (trashed, or their set dissolved) are ignored.
    private var markedFiles: [FileNode] {
        model.duplicates.flatMap { $0.files }.filter { model.markedDuplicateIDs.contains($0.id) }
    }

    private var markedBytes: Int64 {
        markedFiles.reduce(0) { $0 + $1.size }
    }
}
