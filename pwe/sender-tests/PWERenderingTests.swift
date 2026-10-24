import XCTest
@testable import TargetBridge

/// The iMac's renderer: the choice in Settings › Advanced and the hello field
/// that carries it. pwe/rebrand.py copies this file into the sender's test target.
@MainActor
final class PWERenderingTests: XCTestCase {
    private func hello(_ renderer: String?) throws -> [String: Any] {
        var value = TBMonitorHelloReceiver(senderName: "Mac", captureWidth: 5120, captureHeight: 2880)
        value.receiverRenderer = renderer
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testTheHelloCarriesTheChoice() throws {
        XCTAssertEqual(try hello("metal")["receiverRenderer"] as? String, "metal")
        XCTAssertEqual(try hello("opengl")["receiverRenderer"] as? String, "opengl")
    }

    func testNoChoiceLeavesTheFieldOut() throws {
        // What an upstream sender sends: the receiver keeps its default.
        XCTAssertNil(try hello(nil)["receiverRenderer"])
    }

    func testTheRawValuesAreWhatTheReceiverReads() {
        // display.c compares against exactly these.
        XCTAssertEqual(PWERendering.openGL.rawValue, "opengl")
        XCTAssertEqual(PWERendering.metal.rawValue, "metal")
    }

    /// 1.1.1: Metal for a Mac where nobody chose (Lee 2026-10-24); a choice,
    /// OpenGL included, is kept.
    func testMetalByDefaultAndTheLastChoiceIsKept() {
        let defaults = UserDefaults(suiteName: "pwe.preview")!
        defaults.removeObject(forKey: PWESenderModel.Keys.rendering)
        defer { defaults.removeObject(forKey: PWESenderModel.Keys.rendering) }
        let model = PWESenderModel(preview: .searching)
        XCTAssertEqual(model.rendering, .metal)
        // No iMac known yet: the choice still sticks, for the next iMac.
        model.rendering = .openGL
        XCTAssertEqual(model.rendering, .openGL)
        XCTAssertEqual(PWESenderModel(preview: .searching).rendering, .openGL)
        XCTAssertEqual(defaults.string(forKey: PWESenderModel.Keys.rendering), "opengl")
    }

    func testAnEarlierOpenGLChoiceSurvivesTheNewDefault() {
        let defaults = UserDefaults(suiteName: "pwe.preview")!
        defaults.set("opengl", forKey: PWESenderModel.Keys.rendering)
        defer { defaults.removeObject(forKey: PWESenderModel.Keys.rendering) }
        XCTAssertEqual(PWESenderModel(preview: .searching).rendering, .openGL)
    }
}
