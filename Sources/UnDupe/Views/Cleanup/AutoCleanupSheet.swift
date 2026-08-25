import SwiftUI
import UnDupeCore

/// One-click "Automatic Cleanup" modal. Presented over the cleanup dashboard.
///
/// Deliberately scoped to **System Junk** only — caches, logs, and developer
/// leftovers. That's the one category safe to clear without per-file judgment:
/// it's strictly allowlisted to `~/Library`, passes `ProtectedPaths.isDeletable`,
/// and goes to the Trash (recoverable). App leftovers, extensions, and startup
/// items are intentionally excluded — those need deliberate per-item review.
///
/// The user picks which categories to clear; each shows a live size preview.
struct AutoCleanupSheet: View {
    @EnvironmentObject var cleanup: CleanupModel
    @Environment(\.dismiss) private var dismiss

    /// Where the modal is in its flow.
    private enum Phase: Equatable {
        case selecting
        case cleaning
        case done(reclaimed: Int64, failed: Int)
    }

    /// Category names selected for cleaning. Defaults to all once a scan lands.
    @State private var selected: Set<String> = []
    @State private var phase: Phase = .selecting
    /// Tracks whether we've seeded the default selection yet for this presentation.
    @State private var didSeedSelection = false
    /// Opt-in: skip the Trash and delete outright. Off by default (Trash is safe).
    @State private var deletePermanently = false
    /// Drives the extra confirmation required before an irreversible delete.
    @State private var confirmingPermanent = false

    var body: some View {
        ZStack {
            Theme.windowBackground.ignoresSafeArea()
            content
                .frame(width: 480)
                .frame(minHeight: 360)
        }
        .onAppear {
            if cleanup.junkCategories.isEmpty { cleanup.loadJunk() }
            seedSelectionIfNeeded()
        }
        .onChange(of: cleanup.junkCategories) { _ in seedSelectionIfNeeded(force: true) }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .selecting: selecting
        case .cleaning:  cleaning
        case .done(let reclaimed, let failed): doneView(reclaimed: reclaimed, failed: failed)
        }
    }

    // MARK: - Selecting

    private var selecting: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if cleanup.isScanningJunk && cleanup.junkCategories.isEmpty {
                CleanupLoadingState(label: "Finding safe-to-clear files…")
                    .frame(maxHeight: .infinity)
            } else if cleanup.junkCategories.isEmpty {
                CleanupEmptyState(
                    icon: "sparkles",
                    title: "Nothing to clean",
                    message: "No removable caches or logs were found."
                )
                .frame(maxHeight: .infinity)
            } else {
                categoryList
                footer
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "wand.and.sparkles")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Automatic Cleanup")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.primaryText)
                    Text("Choose what to clear — everything is safe and recoverable.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                }
                Spacer()
            }

            CleanupInfoNote {
                Text("Only regenerable junk (caches, logs, developer leftovers) is offered here. By default files move to the Trash, so you can restore them until you empty it. Nothing under your documents, apps, or personal data is touched.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(20)
    }

    private var categoryList: some View {
        ScrollView {
            VStack(spacing: 10) {
                ForEach(cleanup.junkCategories) { category in
                    categoryRow(category)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        }
    }

    private func categoryRow(_ category: JunkCategory) -> some View {
        let isOn = selected.contains(category.id)
        return Button {
            toggle(category)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(isOn ? Theme.accent : Theme.tertiaryText)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(category.name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.primaryText)
                        Text(ByteFormat.string(category.totalBytes))
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                            .foregroundStyle(Theme.accent)
                    }
                    Text(category.explanation)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                        .multilineTextAlignment(.leading)
                    Text("\(category.items.count) item(s)")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.tertiaryText)
                }
                Spacer()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassPanel(cornerRadius: 12)
            .hoverHighlight(cornerRadius: 12)
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        VStack(spacing: 12) {
            permanentToggle
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Selected to free")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.tertiaryText)
                    Text(ByteFormat.string(selectedBytes))
                        .font(.system(size: 18, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(Theme.primaryText)
                        .contentTransition(.numericText())
                        .animation(.easeOut(duration: 0.25), value: selectedBytes)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)

                Button {
                    startCleaning()
                } label: {
                    Label(deletePermanently ? "Delete \(ByteFormat.string(selectedBytes))"
                                            : "Clean \(ByteFormat.string(selectedBytes))",
                          systemImage: deletePermanently ? "trash.slash" : "trash")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(deletePermanently ? Theme.danger : Theme.accent)
                .disabled(selectedItems.isEmpty)
            }
        }
        .padding(20)
        .background(Theme.windowBackground)
        .overlay(Divider().overlay(Theme.hairline), alignment: .top)
        .confirmationDialog(
            "Delete permanently?",
            isPresented: $confirmingPermanent,
            titleVisibility: .visible
        ) {
            Button("Delete \(ByteFormat.string(selectedBytes))", role: .destructive) { performClean() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(selectedItems.count) item(s) will be deleted immediately, bypassing the Trash. This can't be undone. These are regenerable caches and logs, but they won't be recoverable.")
        }
    }

    /// The opt-in "skip the Trash" switch. When on, the row turns to a danger tint
    /// to make the irreversible choice obvious.
    private var permanentToggle: some View {
        HStack(spacing: 10) {
            Image(systemName: deletePermanently ? "exclamationmark.triangle.fill" : "trash")
                .font(.system(size: 12))
                .foregroundStyle(deletePermanently ? Theme.danger : Theme.secondaryText)
            VStack(alignment: .leading, spacing: 1) {
                Text("Delete permanently (skip the Trash)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.primaryText)
                Text(deletePermanently
                     ? "Files are removed immediately and can't be recovered."
                     : "Off — cleared files go to the Trash so you can restore them.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            Toggle("", isOn: $deletePermanently)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Theme.danger)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(deletePermanently ? Theme.danger.opacity(0.10) : Theme.hairline)
        )
    }

    // MARK: - Cleaning

    private var cleaning: some View {
        VStack(spacing: 16) {
            ProgressView().scaleEffect(1.3).tint(Theme.accent)
            Text("Moving files to the Trash…")
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Done

    private func doneView(reclaimed: Int64, failed: Int) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(Theme.success)
            Text("Freed \(ByteFormat.string(reclaimed))")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.primaryText)
            Text(failed == 0
                 ? "Cleared files are in the Trash — restore any until you empty it."
                 : "\(failed) item(s) couldn't be removed and were left in place.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    // MARK: - Derived

    private var selectedItems: [JunkItem] {
        cleanup.junkCategories
            .filter { selected.contains($0.id) }
            .flatMap { $0.items }
    }

    private var selectedBytes: Int64 {
        selectedItems.reduce(0) { $0 + $1.sizeBytes }
    }

    // MARK: - Logic

    private func toggle(_ category: JunkCategory) {
        if selected.contains(category.id) { selected.remove(category.id) }
        else { selected.insert(category.id) }
    }

    /// Selects every category by default the first time a non-empty scan arrives.
    private func seedSelectionIfNeeded(force: Bool = false) {
        guard !cleanup.junkCategories.isEmpty else { return }
        guard force || !didSeedSelection else { return }
        selected = Set(cleanup.junkCategories.map(\.id))
        didSeedSelection = true
    }

    private func startCleaning() {
        guard !selectedItems.isEmpty else { return }
        // Trashing is reversible, so it proceeds directly; a permanent delete is
        // irreversible, so it routes through an extra confirmation first.
        if deletePermanently {
            confirmingPermanent = true
        } else {
            performClean()
        }
    }

    private func performClean() {
        let items = selectedItems
        guard !items.isEmpty else { return }
        phase = .cleaning
        cleanup.autoCleanJunk(items, permanently: deletePermanently) { reclaimed, failed in
            phase = .done(reclaimed: reclaimed, failed: failed)
        }
    }
}
