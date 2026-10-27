import XCTest
@testable import TargetBridge

/// A launch's work (the remembered connection, the daily update check) runs
/// once, whether the app delegate or the main window's task asks first
/// (PWELaunch). pwe/rebrand.py copies this file into the sender's test target.
final class PWELaunchTests: XCTestCase {
    @MainActor
    func testTheWorkRunsOnceHoweverManyCallersAsk() {
        let launch = PWELaunch()
        var runs = 0
        // Nothing to run yet: a call before the work is set is not the launch.
        launch.runOnce()
        launch.work = { runs += 1 }
        launch.runOnce()   // applicationDidFinishLaunching
        launch.runOnce()   // the main window's onAppear
        launch.runOnce()   // a second main window
        XCTAssertEqual(runs, 1)
    }
}
