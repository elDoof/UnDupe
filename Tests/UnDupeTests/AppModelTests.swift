import XCTest
@testable import UnDupe
@testable import UnDupeCore

/// `AppModel` runs scans and duplicate searches on background queues and hops
/// back to the main queue to publish. That leaves room for a result to arrive
/// after the thing it belongs to has been replaced — a cancelled scan finishing
/// late, a duplicate search outliving a rescan. These tests pin down that a
/// stale result is dropped rather than acted on, and that the duplicate trash
/// path honours the keep-one guarantee against the real disk.
///
/// Nothing here reaches the Trash: every destructive path is exercised only in
/// the cases where it must refuse.
final class AppModelTests: XCTestCase {

    /// Big enough to clear the duplicate finder's 1 MB floor.
    private static let duplicateFileBytes = 1_200_000

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("UnDupeAppModelTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { [directory] in
            if let directory { try? FileManager.default.removeItem(at: directory) }
        }
    }

    // MARK: - Fixtures

    /// Creates `relative` under the test directory and returns its path.
    @discardableResult
    private func makeFile(_ relative: String, bytes: Int = 4_096, fill: UInt8 = 0x5A) throws -> String {
        let url = directory.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(repeating: fill, count: bytes).write(to: url)
        return url.path
    }

    /// Spins the main run loop until `condition` holds, so the model's
    /// `DispatchQueue.main.async` hops get to run.
    private func wait(
        _ description: String,
        timeout: TimeInterval = 20,
        until condition: () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), "timed out waiting for: \(description)")
    }

    /// Lets any late completions land before asserting that nothing changed.
    private func settle(_ interval: TimeInterval = 0.4) {
        RunLoop.main.run(until: Date().addingTimeInterval(interval))
    }

    private func scannedModel(at path: String) -> AppModel {
        let model = AppModel()
        model.enterDiskMode()
        model.startScan(path: path)
        wait("the scan to finish") { model.phase == .results }
        return model
    }

    // MARK: - Scan races

    func testACancelledScanFinishingLateDoesNotInterruptTheNextOne() throws {
        // Arrange
        let first = directory.appendingPathComponent("first")
        let second = directory.appendingPathComponent("second")
        try makeFile("first/a.bin")
        try makeFile("second/b.bin")
        let model = AppModel()
        model.enterDiskMode()

        // Act: cancel one scan and start another before the first has unwound.
        model.startScan(path: first.path)
        model.cancelScan()
        model.startScan(path: second.path)
        wait("the second scan to finish") { model.phase == .results }
        settle()

        // Assert: the first scan's late `.cancelled` must not send us home.
        XCTAssertEqual(model.phase, .results)
        XCTAssertEqual(model.selectedRoot?.path, second.path)
    }

    func testResetMakesAnInFlightScansCompletionANoOp() throws {
        try makeFile("a.bin")
        let model = AppModel()
        model.enterDiskMode()

        model.startScan(path: directory.path)
        model.reset()
        settle()

        XCTAssertEqual(model.phase, .home)
        XCTAssertNil(model.selectedRoot)
    }

    func testRescanDoesNothingUnlessResultsAreOnScreen() throws {
        try makeFile("a.bin")
        let model = scannedModel(at: directory.path)

        // In System Cleanup the map isn't on screen; ⌘R must not start a scan
        // underneath it.
        model.enterCleanupMode()
        model.rescan()

        XCTAssertEqual(model.phase, .results)
        XCTAssertFalse(model.isShowingResults)
    }

    func testNewScanLeavesCleanupAndShowsTheTargetChooser() {
        let model = AppModel()
        model.enterCleanupMode()

        model.startNewScan()

        XCTAssertEqual(model.topLevel, .disk)
        XCTAssertEqual(model.phase, .home)
    }

    func testARescanHandsBackTheFolderToReturnToExactlyOnce() throws {
        try makeFile("sub/a.bin")
        let model = scannedModel(at: directory.path)
        let sub = directory.appendingPathComponent("sub").path

        model.focusedPath = sub
        model.rescan()
        wait("the rescan to finish") { model.phase == .results }

        XCTAssertEqual(model.takeFocusPathToRestore(), sub)
        XCTAssertNil(model.takeFocusPathToRestore())
    }

    func testReportsFoldersTheScanCouldNotRead() throws {
        try XCTSkipIf(getuid() == 0, "root ignores permission bits")
        try makeFile("open/a.bin")
        try makeFile("locked/b.bin")
        let locked = directory.appendingPathComponent("locked").path
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked)
        }

        let model = scannedModel(at: directory.path)

        XCTAssertEqual(model.skippedDirectoryCount, 1)
    }

    // MARK: - Duplicate search

    func testFindsDuplicatesOnceAndSelectsAllButOneCopy() throws {
        try makeFile("one.bin", bytes: Self.duplicateFileBytes)
        try makeFile("deeper/two.bin", bytes: Self.duplicateFileBytes)
        let model = scannedModel(at: directory.path)

        model.findDuplicates()
        wait("the duplicate search to finish") { model.hasSearchedDuplicates }

        XCTAssertEqual(model.duplicates.count, 1)
        XCTAssertFalse(model.isFindingDuplicates)
        let marked = model.duplicates[0].files.filter { model.markedDuplicateIDs.contains($0.id) }
        XCTAssertEqual(marked.map(\.name), ["two.bin"], "the shorter path is the copy to keep")
    }

    func testASearchThatFindsNothingStillCountsAsSearched() throws {
        // This is what stops the search re-running on every visit to the tab.
        try makeFile("only.bin", bytes: Self.duplicateFileBytes)
        let model = scannedModel(at: directory.path)

        model.findDuplicates()
        wait("the duplicate search to finish") { model.hasSearchedDuplicates }

        XCTAssertTrue(model.duplicates.isEmpty)
    }

    func testACancelledSearchInstallsNothingAndIsNotMarkedSearched() throws {
        try makeFile("one.bin", bytes: Self.duplicateFileBytes)
        try makeFile("two.bin", bytes: Self.duplicateFileBytes)
        let model = scannedModel(at: directory.path)

        model.findDuplicates()
        model.cancelDuplicateSearch()
        settle()

        XCTAssertFalse(model.isFindingDuplicates)
        XCTAssertFalse(model.hasSearchedDuplicates)
        XCTAssertTrue(model.duplicates.isEmpty)
    }

    func testASearchOutlivedByARescanDoesNotInstallStaleGroups() throws {
        try makeFile("one.bin", bytes: Self.duplicateFileBytes)
        try makeFile("two.bin", bytes: Self.duplicateFileBytes)
        let model = scannedModel(at: directory.path)

        // The search belongs to the tree the rescan is about to replace.
        model.findDuplicates()
        model.rescan()
        wait("the rescan to finish") { model.phase == .results }
        settle()

        XCTAssertTrue(model.duplicates.isEmpty)
        XCTAssertFalse(model.hasSearchedDuplicates)
    }

    // MARK: - Duplicate trash safety

    func testRefusesToTrashASetWhoseKeptCopyHasVanished() throws {
        // Arrange: a set of two, then delete the copy the selection keeps —
        // as the user might in Finder after the search ran.
        let kept = try makeFile("one.bin", bytes: Self.duplicateFileBytes)
        let marked = try makeFile("deeper/two.bin", bytes: Self.duplicateFileBytes)
        let model = scannedModel(at: directory.path)
        model.findDuplicates()
        wait("the duplicate search to finish") { model.hasSearchedDuplicates }
        try FileManager.default.removeItem(atPath: kept)

        // Act
        model.trashMarkedDuplicates()
        wait("the trash attempt to report back") { model.statusMessage != nil }

        // Assert: the only surviving copy is still where it was.
        XCTAssertTrue(FileManager.default.fileExists(atPath: marked),
                      "the last remaining copy must not be trashed")
        XCTAssertTrue(model.statusIsWarning)
        XCTAssertFalse(model.canUndoTrash, "nothing moved, so there is nothing to undo")
    }

    func testRefusesASingleTrashWhenNoOtherCopyRemains() throws {
        let other = try makeFile("one.bin", bytes: Self.duplicateFileBytes)
        let target = try makeFile("deeper/two.bin", bytes: Self.duplicateFileBytes)
        let model = scannedModel(at: directory.path)
        model.findDuplicates()
        wait("the duplicate search to finish") { model.hasSearchedDuplicates }
        let group = try XCTUnwrap(model.duplicates.first)
        let file = try XCTUnwrap(group.files.first { $0.path == target })
        try FileManager.default.removeItem(atPath: other)

        model.trashDuplicate(file, in: group)
        wait("the trash attempt to report back") { model.statusMessage != nil }

        XCTAssertTrue(FileManager.default.fileExists(atPath: target))
        XCTAssertTrue(model.statusIsWarning)
    }

    // MARK: - Messages

    func testTrashSummaryCoversEachOutcome() {
        let clean = AppModel.trashSummary(moved: 1, reclaimed: 2_000_000, failed: 0, skippedSets: 0)
        XCTAssertTrue(clean.hasPrefix("Moved 1 item to Trash"), clean)

        let mixed = AppModel.trashSummary(moved: 3, reclaimed: 2_000_000, failed: 2, skippedSets: 1)
        XCTAssertTrue(mixed.contains("Moved 3 items to Trash"), mixed)
        XCTAssertTrue(mixed.contains("2 items couldn't be removed"), mixed)
        XCTAssertTrue(mixed.contains("Left 1 set alone"), mixed)

        let nothing = AppModel.trashSummary(moved: 0, reclaimed: 0, failed: 0, skippedSets: 2)
        XCTAssertTrue(nothing.hasPrefix("Nothing was moved to the Trash."), nothing)
        XCTAssertTrue(nothing.contains("Left 2 sets alone"), nothing)
    }

    func testAutomaticCleanupNeverPromisesTheTrashAfterAPermanentDelete() {
        let trashed = AutoCleanupSheet.doneMessage(failed: 0, permanently: false)
        XCTAssertTrue(trashed.contains("in the Trash"), trashed)

        let permanent = AutoCleanupSheet.doneMessage(failed: 0, permanently: true)
        XCTAssertFalse(permanent.contains("in the Trash"), permanent)
        XCTAssertTrue(permanent.contains("can't be restored"), permanent)

        let partial = AutoCleanupSheet.doneMessage(failed: 1, permanently: true)
        XCTAssertTrue(partial.hasPrefix("1 item couldn't be removed and was left in place."), partial)
        XCTAssertFalse(partial.contains("in the Trash"), partial)
    }
}
