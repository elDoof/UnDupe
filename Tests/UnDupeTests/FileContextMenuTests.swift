import XCTest
@testable import UnDupe
@testable import UnDupeCore

/// The right-click menu decides *before* the user clicks whether an item can be
/// trashed. That check is the only thing standing between a user and a menu
/// action that looks available but always fails, so these tests pin down which
/// reason wins and when the action is offered at all.
///
/// `ProtectedPaths` is still the real guard inside `SafeDelete` — this is the
/// UI honouring it up front, not replacing it.
final class FileContextMenuTests: XCTestCase {

    private func reason(_ path: String, extra: String? = nil) -> String? {
        FileContextMenu.trashBlockReason(path: path, extra: extra)
    }

    func testOffersTrashForAnOrdinaryFileInTheUsersHome() {
        let path = NSHomeDirectory() + "/Downloads/some-big-video.mov"

        XCTAssertNil(reason(path), "a plain file in the user's own space must stay trashable")
    }

    func testBlocksTrashForASystemPathAndExplainsWhy() {
        let blocked = reason("/System/Library/CoreServices")

        XCTAssertNotNil(blocked, "a protected path must never offer a working Trash action")
        XCTAssertEqual(blocked, ProtectedPaths.refusalReason("/System/Library/CoreServices"),
                       "the menu shows the same reason SafeDelete would have refused with")
    }

    func testBlocksTrashForFilesInsideAnAppBundle() {
        let inside = NSHomeDirectory() + "/Applications/Thing.app/Contents/Info.plist"

        XCTAssertNotNil(reason(inside),
                        "deleting a file inside a bundle corrupts the app, so it is never offered")
    }

    func testACallerSuppliedReasonWinsOverTheGenericProtectionNotice() {
        let lastCopy = "This is the last copy in its set — UnDupe always keeps one."

        XCTAssertEqual(reason("/System/Library", extra: lastCopy), lastCopy,
                       "the more specific reason is the one worth showing the user")
    }

    func testACallerSuppliedReasonAlsoBlocksAnOtherwiseTrashablePath() {
        let path = NSHomeDirectory() + "/Movies/copy-2.mov"
        XCTAssertNil(reason(path), "precondition: this path is trashable on its own")

        XCTAssertEqual(reason(path, extra: "Keeping the last copy."), "Keeping the last copy.",
                       "the duplicates list can block a path ProtectedPaths would allow")
    }
}
