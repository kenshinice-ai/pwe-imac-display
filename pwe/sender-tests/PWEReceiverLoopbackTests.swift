import XCTest
@testable import TargetBridge

/// The sender engine against the real receiver, over loopback: pairing with the
/// code the receiver shows, an encrypted 5K HEVC stream, the receiver-drawn
/// pointer, and a reconnect without a code. pwe/rebrand.py copies this file
/// into the sender's test target.
///
/// Runs only with TEST_RUNNER_PWE_REAL_RECEIVER=<tbreceiver built with
/// `make TEST_HOOKS=1`, copied outside iCloud Drive>, and port 54321 free.
/// The frames are generated (TBDisplaySenderSession.pweTestSyntheticFrames) and
/// go through the real encoder and send path; screen capture is not used, so no
/// Screen Recording permission or unlocked screen is needed.
final class PWEReceiverLoopbackTests: XCTestCase {
    @MainActor
    func testEncrypted5KStreamWithPointerToRealReceiver() async throws {
        guard let receiverPath = ProcessInfo.processInfo.environment["PWE_REAL_RECEIVER"] else {
            throw XCTSkip("set TEST_RUNNER_PWE_REAL_RECEIVER to run the receiver loopback test")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pwe-real-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let codeFile = dir.appendingPathComponent("code"), logFile = dir.appendingPathComponent("receiver.log")
        FileManager.default.createFile(atPath: logFile.path, contents: nil)
        let receiverService = "com.pwegroup.pweimacdisplay.test.\(UUID().uuidString).receiver"

        let receiver = Process()
        receiver.executableURL = URL(fileURLWithPath: receiverPath)
        receiver.arguments = ["--windowed"]
        receiver.environment = [
            "PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "TB_LANG": "en",
            "TB_RECEIVER_NO_BONJOUR": "1",
            "TB_RECEIVER_TEST_LOOPBACK_IS_CABLE": "1",
            "TB_RECEIVER_TEST_CODE_FILE": codeFile.path,
            "TB_RECEIVER_TEST_KEYCHAIN_SERVICE": receiverService,
            "TB_RECEIVER_TEST_CLEAN_ON_EXIT": "1",
        ]
        receiver.standardOutput = FileHandle.nullDevice
        receiver.standardError = try FileHandle(forWritingTo: logFile)
        try receiver.run()
        defer {
            receiver.terminate()   // SIGTERM: the receiver closes and deletes its test keychain items
            receiver.waitUntilExit()
        }
        func log() -> String { (try? String(contentsOf: logFile, encoding: .utf8)) ?? "" }
        func until(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if condition() { return true }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            return condition()
        }
        let started = await until(10) { log().contains("[sec] pairing key ready") }
        guard started, receiver.isRunning else {
            throw XCTSkip("receiver did not start: \(log().suffix(400))")
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        guard receiver.isRunning, !log().contains("tb_net_listen failed") else {
            throw XCTSkip("port \(TBMonitorProtocol.port) is in use")
        }

        let ipKey = "fd.tbdisplaysender.receiverIP"
        let savedIP = UserDefaults.standard.object(forKey: ipKey)
        defer { UserDefaults.standard.set(savedIP, forKey: ipKey) }
        let senderService = "com.pwegroup.pweimacdisplay.test.\(UUID().uuidString).sender"
        let store = PWEPairingStore(service: senderService, defaults: UserDefaults(suiteName: senderService)!)
        let savedStore = PWEPairingStore.shared
        PWEPairingStore.shared = store
        defer {
            PWEPairingStore.shared = savedStore
            store.deleteEverything()
        }

        let session = TBDisplaySenderSession(language: .english, largeCursor: false, preventDisplaySleep: false,
                                             autoRestartOnWake: false, audioEnabled: false)
        session.transportKind = .networkLink
        session.capturePreset = .native5k60Experimental
        session.receiverIP = "127.0.0.1"
        session.localInterfaceIP = "127.0.0.1"

        // 1. Pair with the code the receiver shows, then 4 s of 5K at 30 fps.
        session.pweTestSyntheticFrames = (count: 120, fps: 30)
        session.connect()
        let asked = await until(10) {
            if case .needsCode = session.pweSecurity { return true }
            return false
        }
        XCTAssertTrue(asked, "the engine asks for the code: \(session.pweSecurity) \(log().suffix(600))")
        let code = (try? String(contentsOf: codeFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        XCTAssertEqual(code.count, 6, "the receiver showed a code")
        session.pweSubmitPairingCode(code)
        let encrypted = await until(10) { session.pweSecurity.isEncrypted }
        XCTAssertTrue(encrypted, "encrypted: \(session.pweSecurity) \(log().suffix(600))")
        let streamed = await until(20) { session.pweTestStreamFinished }
        XCTAssertTrue(streamed, "stream finished: \(session.pweTestFramesSent) frames generated")
        try await Task.sleep(nanoseconds: 1_000_000_000)
        session.stopForAutomaticReconnect()
        let summary1 = await until(5) { log().components(separatedBy: "[test] session:").count > 1 }
        XCTAssertTrue(summary1, log().suffix(800).description)

        // 2. Reconnect: stored keys, no code, a short stream.
        session.pweTestSyntheticFrames = (count: 30, fps: 30)
        session.connect()
        let resumed = await until(10) { session.pweSecurity.isEncrypted }
        XCTAssertTrue(resumed, "resumed: \(session.pweSecurity)")
        _ = await until(10) { session.pweTestStreamFinished }
        try await Task.sleep(nanoseconds: 500_000_000)
        session.stopForAutomaticReconnect()
        let summary2 = await until(5) { log().components(separatedBy: "[test] session:").count > 2 }
        XCTAssertTrue(summary2, log().suffix(800).description)

        let text = log()
        print("PWE receiver log (tail):\n\(text.suffix(3000))")
        let sessions = text.split(separator: "\n").filter { $0.contains("[test] session:") }
        guard sessions.count == 2 else { return XCTFail("expected 2 sessions:\n\(text.suffix(1500))") }
        func value(_ line: Substring, _ key: String) -> Int {
            guard let range = line.range(of: " \(key)=") else { return -1 }
            return Int(line[range.upperBound...].prefix { $0.isNumber }) ?? -1
        }
        for (index, line) in sessions.enumerated() {
            XCTAssertEqual(value(line, "secure"), 1, "session \(index + 1) encrypted: \(line)")
            XCTAssertGreaterThan(value(line, "hello"), 0, "session \(index + 1) hello: \(line)")
            XCTAssertGreaterThan(value(line, "paramSets"), 0, "session \(index + 1) parameter sets: \(line)")
            XCTAssertGreaterThan(value(line, "frames"), 0, "session \(index + 1) frames: \(line)")
            XCTAssertGreaterThan(value(line, "decoded"), 0, "session \(index + 1) decoded frames: \(line)")
            XCTAssertGreaterThan(value(line, "cursorImage"), 0, "session \(index + 1) pointer picture: \(line)")
            XCTAssertGreaterThan(value(line, "cursor"), 0, "session \(index + 1) pointer positions: \(line)")
            XCTAssertEqual(value(line, "teardown"), 1, "session \(index + 1) teardown: \(line)")
        }
        XCTAssertGreaterThanOrEqual(value(sessions[0], "frames"), 60, "most of the 120 frames arrived: \(sessions[0])")
        XCTAssertEqual(text.components(separatedBy: "[sec] paired with").count - 1, 1, "paired once")
        XCTAssertFalse(text.contains("record failed authentication"), "no record failures")
        XCTAssertFalse(text.contains("unsealed packet"), "nothing unsealed in an encrypted session")
    }
}
