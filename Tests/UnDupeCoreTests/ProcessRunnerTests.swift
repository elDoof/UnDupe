import XCTest
@testable import UnDupeCore

/// `ProcessRunner` sits behind every cleanup spinner and the update installer.
/// The properties worth pinning are the ones whose failure is a hang rather
/// than a wrong answer: it must report failure instead of blocking, whatever
/// the tool does.
final class ProcessRunnerTests: XCTestCase {

    func testCapturesStandardOutputAndASuccessfulExit() throws {
        let output = try XCTUnwrap(ProcessRunner.run("/bin/echo", ["hello"]))

        XCTAssertTrue(output.isSuccess)
        XCTAssertEqual(output.text, "hello\n")
    }

    func testReportsANonZeroExitStatus() throws {
        let output = try XCTUnwrap(ProcessRunner.run("/bin/sh", ["-c", "exit 7"]))

        XCTAssertFalse(output.isSuccess)
        XCTAssertEqual(output.status, 7)
    }

    func testReturnsNilWhenTheToolCannotBeLaunched() {
        XCTAssertNil(ProcessRunner.run("/nonexistent/tool-\(UUID().uuidString)", []))
    }

    func testGivesUpOnAToolThatNeverFinishes() {
        let started = Date()

        let output = ProcessRunner.run("/bin/sleep", ["30"], timeout: 0.3)

        XCTAssertNil(output)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10,
                          "a timed-out tool must be abandoned promptly, not waited out")
    }

    func testAToolThatFloodsStandardErrorDoesNotBlock() throws {
        // Far more than a pipe buffer's worth. With an unread stderr pipe this
        // is exactly the write that never returns.
        let script = "head -c 400000 /dev/zero >&2; echo done"

        let output = try XCTUnwrap(ProcessRunner.run("/bin/sh", ["-c", script], timeout: 10))

        XCTAssertEqual(output.text, "done\n")
    }

    func testCollectsOutputLargerThanThePipeBuffer() throws {
        let output = try XCTUnwrap(
            ProcessRunner.run("/bin/sh", ["-c", "head -c 400000 /dev/zero"], timeout: 10)
        )

        XCTAssertEqual(output.data.count, 400_000)
    }

    func testAToolWaitingOnInputSeesEndOfFileInsteadOfHanging() throws {
        // `cat` with no arguments reads stdin until it closes.
        let output = try XCTUnwrap(ProcessRunner.run("/bin/cat", [], timeout: 10))

        XCTAssertTrue(output.isSuccess)
        XCTAssertEqual(output.data.count, 0)
    }
}
