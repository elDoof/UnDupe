import XCTest
@testable import UnDupeCore

/// `SafeDelete` is the only code in the app that removes files, and since the
/// undo feature it is also the only code that puts them back. These tests pin
/// down the round trip — trash, then restore to the exact original path — plus
/// the refusals that keep a protected path from ever reaching `FileManager`.
///
/// Every test that really trashes something restores and then deletes its own
/// fixture, so running the suite never leaves debris in the user's Trash.
final class SafeDeleteTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("UnDupeSafeDeleteTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { [directory] in
            if let directory { try? FileManager.default.removeItem(at: directory) }
        }
    }

    /// Writes a file into the temp directory and returns its URL.
    private func makeFile(named name: String, contents: String = "undupe") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Trashes `url`, guaranteeing the item is cleaned out of the real Trash even
    /// if the test fails partway through.
    private func trashCleaningUp(_ url: URL, size: Int64 = 6) -> TrashResult {
        let result = SafeDelete.moveToTrash([SafeDelete.TrashTarget(path: url.path, size: size)])[0]
        addTeardownBlock {
            if let trashed = result.trashedURL {
                try? FileManager.default.removeItem(at: trashed)
            }
        }
        return result
    }

    // MARK: - Trashing

    func testTrashingRecordsWhereTheItemLandedInTheTrash() throws {
        let file = try makeFile(named: "landed.txt")

        let result = trashCleaningUp(file)

        XCTAssertTrue(result.success, "a plain temp file should be trashable: \(result.error ?? "")")
        XCTAssertEqual(result.path, file.path, "the result reports the original location")
        let trashed = try XCTUnwrap(result.trashedURL, "a successful trash must record its Trash location")
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashed.path),
                      "the recorded Trash location should actually hold the item")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path),
                       "the file should be gone from its original location")
    }

    func testRefusesAProtectedPathWithoutTouchingTheFilesystem() {
        let results = SafeDelete.moveToTrash([SafeDelete.TrashTarget(path: "/System/Library", size: 0)])

        XCTAssertEqual(results.count, 1, "one result per input, always")
        XCTAssertFalse(results[0].success, "/System/Library must never be trashable")
        XCTAssertEqual(results[0].error, ProtectedPaths.refusalReason("/System/Library"),
                       "a refusal surfaces the ProtectedPaths reason")
        XCTAssertNil(results[0].trashedURL, "a refused item never reaches the Trash")
        XCTAssertTrue(FileManager.default.fileExists(atPath: "/System/Library"),
                      "the refusal must not have removed anything")
    }

    func testReturnsOneResultPerInputInOrder() throws {
        let first = try makeFile(named: "first.txt")
        let second = try makeFile(named: "second.txt")
        let targets = [
            SafeDelete.TrashTarget(path: first.path, size: 6),
            SafeDelete.TrashTarget(path: "/usr/bin", size: 0),
            SafeDelete.TrashTarget(path: second.path, size: 6),
        ]

        let results = SafeDelete.moveToTrash(targets)
        addTeardownBlock {
            for trashed in results.compactMap(\.trashedURL) {
                try? FileManager.default.removeItem(at: trashed)
            }
        }

        XCTAssertEqual(results.map(\.path), targets.map(\.path), "order and count must match the input")
        XCTAssertTrue(results[0].success)
        XCTAssertFalse(results[1].success, "the protected path in the middle is refused, not skipped")
        XCTAssertTrue(results[2].success, "a refusal must not abort the rest of the batch")
    }

    // MARK: - Putting back

    func testPutBackRestoresTheFileToItsOriginalPathWithItsContents() throws {
        let file = try makeFile(named: "restore-me.txt", contents: "the original bytes")
        let trashed = trashCleaningUp(file)
        XCTAssertTrue(trashed.success, "precondition: the file was trashed")

        let restored = SafeDelete.putBack([trashed])

        XCTAssertEqual(restored.count, 1, "one result per input, always")
        XCTAssertTrue(restored[0].success, "the file should come back: \(restored[0].error ?? "")")
        XCTAssertEqual(restored[0].path, file.path, "it comes back to exactly where it was")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path),
                      "the file should exist at its original path again")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "the original bytes",
                       "a restore must not alter the contents")
        XCTAssertEqual(restored[0].reclaimedBytes, trashed.reclaimedBytes,
                       "the restored size is reported so callers can total it")
    }

    func testPutBackReportsAnEmptiedTrashInsteadOfThrowing() throws {
        let file = try makeFile(named: "emptied.txt")
        let trashed = trashCleaningUp(file)
        // Simulate the user emptying the Trash between the delete and the undo.
        try FileManager.default.removeItem(at: XCTUnwrap(trashed.trashedURL))

        let restored = SafeDelete.putBack([trashed])

        XCTAssertFalse(restored[0].success, "there is nothing left to restore")
        XCTAssertNotNil(restored[0].error, "the user needs to be told why the undo failed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testPutBackRefusesToOverwriteSomethingAtTheOriginalPath() throws {
        let file = try makeFile(named: "taken.txt", contents: "original")
        let trashed = trashCleaningUp(file)
        // Something new has taken the old name since the delete.
        try "a different file".write(to: file, atomically: true, encoding: .utf8)

        let restored = SafeDelete.putBack([trashed])

        XCTAssertFalse(restored[0].success, "an undo must never clobber an existing file")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "a different file",
                       "the file occupying the path is left untouched")
    }

    func testPutBackRejectsAResultThatNeverReachedTheTrash() {
        let refusal = TrashResult(path: "/System/Library", success: false,
                                  reclaimedBytes: 0, error: "refused")

        let restored = SafeDelete.putBack([refusal])

        XCTAssertFalse(restored[0].success, "a failed delete has nothing to undo")
        XCTAssertNotNil(restored[0].error)
    }

    func testPermanentDeletionRecordsNoTrashLocation() throws {
        let file = try makeFile(named: "gone-for-good.txt")

        let results = SafeDelete.deletePermanently(
            [SafeDelete.TrashTarget(path: file.path, size: 6)]
        )

        XCTAssertTrue(results[0].success)
        XCTAssertNil(results[0].trashedURL,
                     "a permanent delete is irreversible, so it must not look undoable")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}
