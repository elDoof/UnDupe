import XCTest
@testable import UnDupeCore

/// "A duplicate set never loses its last copy" is the promise the whole
/// duplicates screen rests on. These tests hold the selection rules to it,
/// including against a list that has gone stale since the search ran.
final class DuplicateSelectionTests: XCTestCase {

    private func file(_ path: String) -> FileNode {
        FileNode(name: (path as NSString).lastPathComponent, path: path,
                 isDirectory: false, size: 1_000)
    }

    private func group(_ paths: String...) -> DuplicateGroup {
        DuplicateGroup(sizeBytes: 1_000, files: paths.map(file))
    }

    // MARK: - Default selection

    func testKeepsTheShortestPathAndMarksTheRest() {
        let set = group("/a/deep/nested/copy.bin", "/a/copy.bin", "/a/deep/copy.bin")

        let marks = DuplicateSelection.defaultMarks(for: [set])

        let kept = set.files.filter { !marks.contains($0.id) }.map(\.path)
        XCTAssertEqual(kept, ["/a/copy.bin"])
        XCTAssertEqual(marks.count, 2)
    }

    func testEverySetKeepsExactlyOneByDefault() {
        let sets = [group("/x/1", "/x/2"), group("/y/aa", "/y/b", "/y/ccc"), group("/z/same", "/q/same")]

        let marks = DuplicateSelection.defaultMarks(for: sets)

        for set in sets {
            XCTAssertEqual(DuplicateSelection.keptCount(in: set, marked: marks), 1)
        }
    }

    func testEqualLengthPathsBreakTheTieTheSameWayEveryTime() {
        let set = group("/b/file", "/a/file")

        let first = DuplicateSelection.defaultMarks(for: [set])
        let second = DuplicateSelection.defaultMarks(for: [set])

        XCTAssertEqual(first, second)
        XCTAssertEqual(set.files.filter { !first.contains($0.id) }.map(\.path), ["/a/file"])
    }

    // MARK: - Toggling

    func testRefusesToMarkTheLastKeptCopy() {
        let set = group("/a/one", "/a/two")
        let marks = DuplicateSelection.defaultMarks(for: [set])
        let keeper = set.files.first { !marks.contains($0.id) }!

        let after = DuplicateSelection.toggling(keeper, in: set, marked: marks)

        XCTAssertEqual(after, marks, "marking the last kept copy must change nothing")
        XCTAssertTrue(DuplicateSelection.isLastKept(keeper, in: set, marked: marks))
    }

    func testUnmarkingIsAlwaysAllowedAndThenFreesTheOtherCopy() {
        let set = group("/a/one", "/a/two")
        let marks = DuplicateSelection.defaultMarks(for: [set])
        let keeper = set.files.first { !marks.contains($0.id) }!
        let marked = set.files.first { marks.contains($0.id) }!

        // Keep both…
        let bothKept = DuplicateSelection.toggling(marked, in: set, marked: marks)
        XCTAssertEqual(DuplicateSelection.keptCount(in: set, marked: bothKept), 2)

        // …after which the original keeper may be marked instead.
        let swapped = DuplicateSelection.toggling(keeper, in: set, marked: bothKept)
        XCTAssertTrue(swapped.contains(keeper.id))
        XCTAssertEqual(DuplicateSelection.keptCount(in: set, marked: swapped), 1)
    }

    func testNoSequenceOfTogglesCanMarkAWholeSet() {
        let set = group("/a/1", "/a/2", "/a/3")
        var marks: Set<UUID> = []

        // Click every checkbox, repeatedly, in order.
        for _ in 0..<3 {
            for file in set.files where !marks.contains(file.id) {
                marks = DuplicateSelection.toggling(file, in: set, marked: marks)
            }
        }

        XCTAssertGreaterThanOrEqual(DuplicateSelection.keptCount(in: set, marked: marks), 1)
    }

    func testMarksForFilesNoLongerInAnyGroupAreIgnored() {
        let set = group("/a/one", "/a/two")
        let stale: Set<UUID> = [UUID(), UUID()]

        XCTAssertEqual(DuplicateSelection.keptCount(in: set, marked: stale), 2)
    }

    // MARK: - Trash plan

    func testPlansToTrashTheMarkedFilesWhenAKeptCopyIsOnDisk() {
        let set = group("/a/keep", "/a/deep/extra")
        let marks = DuplicateSelection.defaultMarks(for: [set])

        let plan = DuplicateSelection.trashPlan(for: [set], marked: marks) { _ in true }

        XCTAssertEqual(plan.files.map(\.path), ["/a/deep/extra"])
        XCTAssertEqual(plan.skippedGroupCount, 0)
    }

    func testSkipsASetWhoseKeptCopyHasVanishedSinceTheSearch() {
        // The copy we meant to keep was deleted in Finder after the search ran.
        let stale = group("/a/keep", "/a/deep/extra")
        let fine = group("/b/keep", "/b/deep/extra")
        let marks = DuplicateSelection.defaultMarks(for: [stale, fine])

        let plan = DuplicateSelection.trashPlan(for: [stale, fine], marked: marks) { path in
            path != "/a/keep"
        }

        XCTAssertEqual(plan.files.map(\.path), ["/b/deep/extra"])
        XCTAssertEqual(plan.skippedGroupCount, 1)
    }

    func testASetWithNothingMarkedIsNeitherTrashedNorCountedAsSkipped() {
        let set = group("/a/one", "/a/two")

        let plan = DuplicateSelection.trashPlan(for: [set], marked: []) { _ in false }

        XCTAssertTrue(plan.files.isEmpty)
        XCTAssertEqual(plan.skippedGroupCount, 0)
    }

    func testASingleTrashNeedsAnotherCopyStillOnDisk() {
        let set = group("/a/one", "/a/two")
        let target = set.files[0]

        XCTAssertTrue(DuplicateSelection.hasOtherCopyOnDisk(than: target, in: set) { _ in true })
        XCTAssertFalse(DuplicateSelection.hasOtherCopyOnDisk(than: target, in: set) { path in
            path == target.path   // only the file being trashed still exists
        })
    }
}
