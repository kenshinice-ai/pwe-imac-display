import CoreGraphics
import XCTest
@testable import TargetBridge

/// Step math, key reading, URL parsing and which display the brightness keys
/// belong to (PWEBrightnessRules). pwe/rebrand.py copies this file into the
/// sender's test target.
final class PWEBrightnessRulesTests: XCTestCase {
    private typealias Rules = PWEBrightnessRules

    // MARK: Steps

    func testSixteenStepsFromTopToBottom() {
        var level = 1.0
        var presses = 0
        while level > 0 {
            level = Rules.step(from: level, up: false, fine: false)
            presses += 1
        }
        XCTAssertEqual(presses, 16)
        XCTAssertEqual(Rules.step(from: 0, up: true, fine: false), 1.0 / 16, accuracy: 1e-12)
    }

    func testSixtyFourFineSteps() {
        var level = 0.0
        var presses = 0
        while level < 1 {
            level = Rules.step(from: level, up: true, fine: true)
            presses += 1
        }
        XCTAssertEqual(presses, 64)
        XCTAssertEqual(Rules.step(from: 0.5, up: false, fine: true), 0.5 - 1.0 / 64, accuracy: 1e-12)
    }

    func testStepsStopAtTheEnds() {
        XCTAssertEqual(Rules.step(from: 1, up: true, fine: false), 1)
        XCTAssertEqual(Rules.step(from: 0, up: false, fine: false), 0)
        XCTAssertEqual(Rules.step(from: 1, up: true, fine: true), 1)
        XCTAssertEqual(Rules.step(from: 0, up: false, fine: true), 0)
    }

    func testAnInBetweenLevelLandsOnTheNextMark() {
        // The slider left 0.70: between 11/16 (0.6875) and 12/16 (0.75).
        XCTAssertEqual(Rules.step(from: 0.70, up: true, fine: false), 0.75, accuracy: 1e-12)
        XCTAssertEqual(Rules.step(from: 0.70, up: false, fine: false), 0.6875, accuracy: 1e-12)
    }

    func testAMarkWithRoundingNoiseStillMovesAWholeStep() {
        let nearlyHalf = 0.5 - 1e-9
        XCTAssertEqual(Rules.step(from: nearlyHalf, up: true, fine: false), 0.5625, accuracy: 1e-12)
        XCTAssertEqual(Rules.step(from: 0.5 + 1e-9, up: false, fine: false), 0.4375, accuracy: 1e-12)
    }

    func testFineAndCoarseStepsShareTheirMarks() {
        // Four fine steps up from a coarse mark reach the next coarse mark.
        var level = 0.25
        for _ in 0..<4 { level = Rules.step(from: level, up: true, fine: true) }
        XCTAssertEqual(level, 0.3125, accuracy: 1e-12)
    }

    func testOutOfRangeLevelsAreClamped() {
        XCTAssertEqual(Rules.step(from: 3, up: false, fine: false), 0.9375, accuracy: 1e-12)
        XCTAssertEqual(Rules.step(from: -1, up: true, fine: false), 0.0625, accuracy: 1e-12)
        XCTAssertEqual(Rules.clamp(.nan), 1)
    }

    // MARK: Which display

    private let imac: CGDirectDisplayID = 0x4242
    private func display(_ id: CGDirectDisplayID, vendor: UInt32 = 0xEEEE, mirrored: Bool = false) -> Rules.Display {
        Rules.Display(id: id, vendorID: vendor, inMirrorSet: mirrored)
    }

    func testPointerOnOurVirtualDisplay() {
        XCTAssertEqual(Rules.target(underPointer: [display(imac)], ownDisplays: [imac]), imac)
    }

    func testPointerOnTheBuiltInDisplay() {
        XCTAssertNil(Rules.target(underPointer: [display(1, vendor: 0x610)], ownDisplays: [imac]))
    }

    func testPointerNowhere() {
        XCTAssertNil(Rules.target(underPointer: [], ownDisplays: [imac]))
    }

    func testNoIMacConnected() {
        XCTAssertNil(Rules.target(underPointer: [display(imac)], ownDisplays: []))
    }

    func testAnotherAppsVirtualDisplayIsNotOurs() {
        // TargetBridge itself also makes 0xEEEE displays.
        XCTAssertNil(Rules.target(underPointer: [display(0x9999)], ownDisplays: [imac]))
    }

    func testOwnDisplayWithAnotherVendorIsNotTaken() {
        XCTAssertNil(Rules.target(underPointer: [display(imac, vendor: 0x610)], ownDisplays: [imac]))
    }

    func testMirroredIMacLeavesTheKeysToMacOS() {
        let pointer = [display(1, vendor: 0x610, mirrored: true), display(imac, mirrored: true)]
        XCTAssertNil(Rules.target(underPointer: pointer, ownDisplays: [imac]))
    }

    func testTheRightIMacOfTwo() {
        let other: CGDirectDisplayID = 0x4343
        XCTAssertEqual(Rules.target(underPointer: [display(other)], ownDisplays: [imac, other]), other)
    }

    // MARK: Keys

    private func data1(key: Int, state: Int, repeating: Bool = false) -> Int {
        (key << 16) | (state << 8) | (repeating ? 1 : 0)
    }

    func testMediaBrightnessKeys() {
        XCTAssertEqual(Rules.auxKey(subtype: 8, data1: data1(key: 3, state: 0x0a)),
                       Rules.AuxKey(key: .down, isDown: true, isRepeat: false))
        XCTAssertEqual(Rules.auxKey(subtype: 8, data1: data1(key: 2, state: 0x0a, repeating: true)),
                       Rules.AuxKey(key: .up, isDown: true, isRepeat: true))
        XCTAssertEqual(Rules.auxKey(subtype: 8, data1: data1(key: 2, state: 0x0b)),
                       Rules.AuxKey(key: .up, isDown: false, isRepeat: false))
    }

    func testOtherMediaKeysAreNotOurs() {
        // NX_KEYTYPE_SOUND_UP (0), PLAY (16), and the wrong subtype.
        XCTAssertNil(Rules.auxKey(subtype: 8, data1: data1(key: 0, state: 0x0a)))
        XCTAssertNil(Rules.auxKey(subtype: 8, data1: data1(key: 16, state: 0x0a)))
        XCTAssertNil(Rules.auxKey(subtype: 7, data1: data1(key: 3, state: 0x0a)))
        XCTAssertNil(Rules.auxKey(subtype: 8, data1: data1(key: 3, state: 0x05)))
    }

    func testKeyCodes() {
        XCTAssertEqual(Rules.key(keyCode: 122), .down)  // F1
        XCTAssertEqual(Rules.key(keyCode: 120), .up)    // F2
        XCTAssertEqual(Rules.key(keyCode: 145), .down)
        XCTAssertEqual(Rules.key(keyCode: 144), .up)
        XCTAssertNil(Rules.key(keyCode: 99))            // F3
        XCTAssertNil(Rules.key(keyCode: 0))             // A
        XCTAssertTrue(Rules.isFunctionKey(122))
        XCTAssertFalse(Rules.isFunctionKey(145))
    }

    func testModifiers() {
        XCTAssertTrue(Rules.modifiers([]) == (true, false))
        XCTAssertTrue(Rules.modifiers([.maskSecondaryFn]) == (true, false))
        XCTAssertTrue(Rules.modifiers([.maskShift, .maskAlternate]) == (true, true))
        XCTAssertTrue(Rules.modifiers([.maskShift]) == (true, false))
        XCTAssertTrue(Rules.modifiers([.maskAlternate]) == (true, false))
        XCTAssertFalse(Rules.modifiers([.maskCommand]).handled)
        XCTAssertFalse(Rules.modifiers([.maskControl, .maskShift, .maskAlternate]).handled)
    }

    // MARK: URL

    func testLevel() {
        XCTAssertEqual(Rules.request(["level": "50"]), .set(0.5))
        XCTAssertEqual(Rules.request(["level": "0"]), .set(0))
        XCTAssertEqual(Rules.request(["level": "100"]), .set(1))
        XCTAssertEqual(Rules.request(["level": "12.5"]), .set(0.125))
        XCTAssertEqual(Rules.request(["level": "250"]), .set(1))
        XCTAssertEqual(Rules.request(["level": "-5"]), .set(0))
    }

    func testStep() {
        XCTAssertEqual(Rules.request(["step": "+1"]), .step(1, fine: false))
        XCTAssertEqual(Rules.request(["step": " 1"]), .step(1, fine: false))  // "+" decoded as a space
        XCTAssertEqual(Rules.request(["step": "1"]), .step(1, fine: false))
        XCTAssertEqual(Rules.request(["step": "-1"]), .step(-1, fine: false))
        XCTAssertEqual(Rules.request(["step": "-2", "fine": "1"]), .step(-2, fine: true))
    }

    func testLevelWinsOverStep() {
        XCTAssertEqual(Rules.request(["level": "30", "step": "+1"]), .set(0.3))
    }

    func testMalformedRequestsChangeNothing() {
        XCTAssertNil(Rules.request([:]))
        XCTAssertNil(Rules.request(["level": ""]))
        XCTAssertNil(Rules.request(["level": "bright"]))
        XCTAssertNil(Rules.request(["level": "nan"]))
        XCTAssertNil(Rules.request(["level": "inf"]))
        XCTAssertNil(Rules.request(["step": "0"]))
        XCTAssertNil(Rules.request(["step": "up"]))
        XCTAssertNil(Rules.request(["step": "1.5"]))
        XCTAssertNil(Rules.request(["step": "1000"]))
    }

    func testURLQueryReachesTheParser() {
        // As TBSenderAutomation.handle(url:) collects them: lowercased names, raw values.
        let url = URL(string: "pweimacdisplay://brightness?step=+1&fine=1")!
        var params: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            params[item.name.lowercased()] = item.value
        }
        XCTAssertEqual(url.host, "brightness")
        XCTAssertEqual(Rules.request(params), .step(1, fine: true))
    }

    func testLevelAfterARequest() {
        XCTAssertEqual(Rules.level(after: .set(0.3), from: 0.9), 0.3)
        XCTAssertEqual(Rules.level(after: .step(1, fine: false), from: 0.5), 0.5625, accuracy: 1e-12)
        XCTAssertEqual(Rules.level(after: .step(-2, fine: false), from: 0.5), 0.375, accuracy: 1e-12)
        XCTAssertEqual(Rules.level(after: .step(3, fine: true), from: 0.5), 0.5 + 3.0 / 64, accuracy: 1e-12)
        XCTAssertEqual(Rules.level(after: .step(40, fine: false), from: 0.5), 1)
    }

    // MARK: HUD

    func testSegments() {
        XCTAssertEqual(Rules.segments(for: 0), Array(repeating: 0, count: 16))
        XCTAssertEqual(Rules.segments(for: 1), Array(repeating: 1, count: 16))
        let half = Rules.segments(for: 0.5)
        XCTAssertEqual(half.filter { $0 == 1 }.count, 8)
        XCTAssertEqual(half.filter { $0 == 0 }.count, 8)
        // One fine step past a mark fills a quarter of the next segment.
        let quarter = Rules.segments(for: 0.5 + 1.0 / 64)
        XCTAssertEqual(quarter[8], 0.25, accuracy: 1e-12)
    }
}
