import XCTest
@testable import TargetBridge

/// What the input log (Application Support/…/Logs/input-debug.log) may hold
/// in a release build: event kinds and counts, never key codes (TBInputDebugLog).
/// pwe/rebrand.py copies this file into the sender's test target.
final class PWEInputDebugLogTests: XCTestCase {
    func testTheReleaseLineHasNoKeyCodeOrMovement() {
        let line = TBInputDebugLog.receivedEventLine(count: 7, kind: "keyDown", dx: 12, dy: -3, scrollX: 1, scrollY: 2,
                                                     keyCode: 0x26, detailed: false)
        XCTAssertEqual(line, "sender received #7 kind=keyDown")
        XCTAssertFalse(line.contains("key="))
        XCTAssertFalse(line.contains("dx="))
    }

    func testTheDetailedLineOnlyWhenAskedFor() {
        let line = TBInputDebugLog.receivedEventLine(count: 7, kind: "keyDown", dx: nil, dy: nil, scrollX: nil,
                                                     scrollY: nil, keyCode: 38, detailed: true)
        XCTAssertTrue(line.hasSuffix("key=38"))
        // Off unless the environment says PWE_INPUT_DEBUG=1 (the test runner does not).
        XCTAssertFalse(TBInputDebugLog.detailed)
    }

    func testModifiersAreCountedNotNamed() {
        let line = TBInputDebugLog.remoteModifierLine(keyCode: 55, isDown: true, flags: 0x100000, modifiersHeld: 1,
                                                      detailed: false)
        XCTAssertEqual(line, "sender remote modifier change (1 held)")
        XCTAssertFalse(line.contains("55"))
    }

    func testBindingsAndInjectErrorsKeepTheShortcutOut() {
        XCTAssertEqual(TBInputDebugLog.bindingLine(trigger: "⌃←", action: "⌃⌘←", detailed: false),
                       "binding matched; injecting its shortcut")
        let info: NSDictionary = [NSAppleScript.errorNumber: NSNumber(value: 1002),
                                  NSAppleScript.errorMessage: "key code 123 using {control down}"]
        XCTAssertEqual(TBInputDebugLog.injectErrorLine(info, detailed: false), "system-events inject error 1002")
    }

    func testTheFileIsCappedAtOneMegabyte() {
        XCTAssertFalse(TBInputDebugLog.shouldRotate(size: 1_048_575))
        XCTAssertTrue(TBInputDebugLog.shouldRotate(size: 1_048_576))
    }
}
