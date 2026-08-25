import SwiftUI
import AppKit
import UnDupeCore

/// System Junk module. Shows regenerable caches/logs/developer leftovers grouped
/// by category, each with a plain-language reason it's safe. Selection is opt-in;
/// clearing moves items to the Trash (recoverable).
struct JunkView: View {
    @EnvironmentObject var cleanup: CleanupModel

    /// Junk items selected for clearing, keyed by path.
    @State private var selected: Set<String> = []
    @State private var confirmingClear = false

    var body: some View {
        VStack(spacing: 0) {
            CleanupHeader(
                title: "System Junk",
                subtitle: "Caches, logs & developer leftovers — safe to clear."
            ) {
                cleanup.closeModule()
            }

            if cleanup.isScanningJunk && cleanup.junkCategories.isEmpty {
                CleanupLoadingState(label: "Measuring junk…")
            } else if cleanup.junkCategories.isEmpty {
                CleanupEmptyState(icon: "sparkles", title: "Nothing to clear", message: "No removable caches or logs found.")
            } else {
                content
            }
        }
        .onAppear { if cleanup.junkCategories.isEmpty { cleanup.loadJunk() } }
        .onChange(of: cleanup.junkCategories) { _ in selected.removeAll() }
        .confirmationDialog(
            "Move junk to Trash?",
            isPresented: $confirmingClear,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) { performClear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(selectedItems.count) item(s) (\(ByteFormat.string(selectedBytes))) will be moved to the Trash. Apps rebuild these as needed; you can restore them until you empty the Trash.")
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            actionBar
            Divider().overlay(Theme.hairline)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let message = cleanup.statusMessage {
                        CleanupStatusBanner(message: message) { cleanup.statusMessage = nil }
                    }
                    ForEach(cleanup.junkCategories) { category in
                        categorySection(category)
                    }
                }
                .padding(20)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Action bar

    private var actionBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(ByteFormat.string(totalBytes)) of junk found")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                Text("Select what to clear — everything here is safe and recoverable.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            if !selectedItems.isEmpty {
                Text("\(selectedItems.count) selected · \(ByteFormat.string(selectedBytes))")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
            }
            Button(role: .destructive) { confirmingClear = true } label: {
                Label("Move to Trash", systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.danger)
            .disabled(selectedItems.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Category

    private func categorySection(_ category: JunkCategory) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button { toggleCategory(category) } label: {
                    Image(systemName: categoryCheckmark(category))
                        .font(.system(size: 15))
                        .foregroundStyle(allSelected(category) ? Theme.accent : Theme.tertiaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(allSelected(category) ? "Deselect all in \(category.name)" : "Select all in \(category.name)")
                Text(category.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                Text("· \(ByteFormat.string(category.totalBytes))")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
            }
            Text(category.explanation)
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiaryText)
            VStack(spacing: 6) {
                ForEach(category.items) { item in
                    itemRow(item)
                }
            }
        }
        .padding(12)
        .glassPanel(cornerRadius: 12)
    }

    private func itemRow(_ item: JunkItem) -> some View {
        let isSelected = selected.contains(item.id)
        return HStack(spacing: 10) {
            Button { toggleItem(item) } label: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(isSelected ? Theme.accent : Theme.tertiaryText)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isSelected ? "Deselect \(item.name)" : "Select \(item.name)")

            Text(item.name)
                .font(.system(size: 12))
                .foregroundStyle(Theme.primaryText)
                .lineLimit(1).truncationMode(.middle)

            Spacer()
            Text(ByteFormat.string(item.sizeBytes))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Theme.secondaryText)
            RevealButton(path: item.path)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
    }

    // MARK: - Derived

    private var allItems: [JunkItem] {
        cleanup.junkCategories.flatMap { $0.items }
    }

    private var totalBytes: Int64 {
        cleanup.junkCategories.reduce(0) { $0 + $1.totalBytes }
    }

    private var selectedItems: [JunkItem] {
        allItems.filter { selected.contains($0.id) }
    }

    private var selectedBytes: Int64 {
        selectedItems.reduce(0) { $0 + $1.sizeBytes }
    }

    // MARK: - Logic

    private func toggleItem(_ item: JunkItem) {
        if selected.contains(item.id) { selected.remove(item.id) }
        else { selected.insert(item.id) }
    }

    private func allSelected(_ category: JunkCategory) -> Bool {
        !category.items.isEmpty && category.items.allSatisfy { selected.contains($0.id) }
    }

    private func categoryCheckmark(_ category: JunkCategory) -> String {
        if allSelected(category) { return "checkmark.circle.fill" }
        if category.items.contains(where: { selected.contains($0.id) }) { return "minus.circle.fill" }
        return "circle"
    }

    private func toggleCategory(_ category: JunkCategory) {
        if allSelected(category) {
            category.items.forEach { selected.remove($0.id) }
        } else {
            category.items.forEach { selected.insert($0.id) }
        }
    }

    private func performClear() {
        cleanup.removeJunk(selectedItems)
        selected.removeAll()
    }
}
