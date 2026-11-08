import XCTest
@testable import GrokCore

final class ShortcutTests: XCTestCase {
    func testDualCommandWorksInEitherOrder() {
        for leftFirst in [true, false] {
            var chord = DualCommandChord()
            XCTAssertFalse(chord.update(leftPressed: leftFirst, rightPressed: !leftFirst))
            XCTAssertTrue(chord.update(leftPressed: true, rightPressed: true))
        }
    }

    func testDualCommandDoesNotRepeatUntilBothKeysAreReleased() {
        var chord = DualCommandChord()
        XCTAssertTrue(chord.update(leftPressed: true, rightPressed: true))
        XCTAssertFalse(chord.update(leftPressed: true, rightPressed: true))
        XCTAssertFalse(chord.update(leftPressed: false, rightPressed: true))
        XCTAssertFalse(chord.update(leftPressed: true, rightPressed: true))
        XCTAssertFalse(chord.update(leftPressed: false, rightPressed: false))
        XCTAssertTrue(chord.update(leftPressed: true, rightPressed: true))
    }

    func testOtherModifiersDoNotBecomeAScreenshotWhenReleased() {
        var chord = DualCommandChord()
        XCTAssertFalse(chord.update(leftPressed: true, rightPressed: true, otherModifiers: true))
        XCTAssertFalse(chord.update(leftPressed: true, rightPressed: true))
        XCTAssertFalse(chord.update(leftPressed: false, rightPressed: false))
        XCTAssertTrue(chord.update(leftPressed: true, rightPressed: true))
    }

    func testEnablingWhileCommandIsHeldDoesNotTriggerACapture() {
        for leftFirst in [true, false] {
            var chord = DualCommandChord(leftPressed: leftFirst, rightPressed: !leftFirst)
            XCTAssertFalse(chord.update(leftPressed: true, rightPressed: true))
            XCTAssertFalse(chord.update(leftPressed: false, rightPressed: false))
            XCTAssertTrue(chord.update(leftPressed: true, rightPressed: true))
        }
    }
}
