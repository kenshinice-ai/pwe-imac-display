import Network
import XCTest
@testable import TargetBridge

/// Pairing and encrypted sessions, sender side: TBDisplayShared/PWESecureLink.swift
/// over the shared C layer (TargetBridge-Shared/secure). The C layer has its own
/// tests (TBReceiverC: make test); these check the same vectors through the
/// bridging header, the Swift link against the C responder, and the engine.
/// pwe/rebrand.py copies this file into the sender's test target.
///
/// Keychain items go under throwaway service names and are deleted afterwards.
final class PWESecureLinkTests: XCTestCase {
    private var stores: [PWEPairingStore] = []
    private var gates: [UnsafeMutablePointer<pwe_sec_gate>] = []

    private func makeStore(_ role: String) -> PWEPairingStore {
        let service = "com.pwegroup.pweimacdisplay.test.\(UUID().uuidString).\(role)"
        let store = PWEPairingStore(service: service, defaults: UserDefaults(suiteName: service)!)
        stores.append(store)
        return store
    }

    override func tearDown() {
        for store in stores { store.deleteEverything() }
        stores.removeAll()
        gates.forEach { $0.deallocate() }
        gates.removeAll()
        super.tearDown()
    }

    // MARK: Vectors, through the bridging header

    private func bytes(_ hex: String) -> [UInt8] {
        [UInt8](PWEPairingStore.data(hex: hex)!)
    }

    func testCPaceRistrettoVectorFromSwift() {
        // draft-irtf-cfrg-cpace-21, B.3
        let prs = Array("Password".utf8)
        let ci: [UInt8] = [0x0b] + Array("A_initiator".utf8) + [0x0b] + Array("B_responder".utf8)
        let sid = bytes("7e4b4791d6a8ef019b936c79fb7f2c57")
        var g = [UInt8](repeating: 0, count: 32)
        XCTAssertEqual(pwe_cpace_generator(prs, prs.count, ci, ci.count, sid, sid.count, &g), 0)
        XCTAssertEqual(PWEPairingStore.hex(Data(g)), "222b6b195fe84b1652badb6f6a3ae3d24341e7306967f0b8115b40d5698c7e56")
        let ya = bytes("da3d23700a9e5699258aef94dc060dfda5ebb61f02a5ea77fad53f4ff0976d08")
        var Ya = [UInt8](repeating: 0, count: 32)
        XCTAssertEqual(pwe_cpace_share(g, ya, &Ya), 0)
        XCTAssertEqual(PWEPairingStore.hex(Data(Ya)), "d6bac480f2c386c394efc7c47adb9925dcd2630b64f240c50f8d0eec482b9157")
    }

    func testNoiseKKFirstMessageVectorFromSwift() {
        // cacophony: Noise_KK_25519_ChaChaPoly_SHA256
        let prologue = bytes("4a6f686e2047616c74")
        let initStatic = bytes("e61ef9919cde45dd5f82166404bd08e38bceb5dfdfded0a34c8df7ed542214d1")
        let initEphemeral = bytes("893e28b9dc6ca8d611ab664754b8ceb7bac5117349a4439a6b0569da977c464a")
        let remoteStatic = bytes("31e0303fd6418d2f8c0e78b91f22e8caed0fbe48656dcf4767e4834f701b8f62")
        let payload = bytes("4c756477696720766f6e204d69736573")
        var hs = pwe_noise_hs()
        XCTAssertEqual(pwe_noise_kk_init(&hs, 1, prologue, prologue.count, initStatic, remoteStatic), 0)
        pwe_noise_set_ephemeral(&hs, initEphemeral)
        var out = [UInt8](repeating: 0, count: 128)
        var outLength = 0
        XCTAssertEqual(pwe_noise_write(&hs, payload, payload.count, &out, out.count, &outLength), 0)
        XCTAssertEqual(PWEPairingStore.hex(Data(out.prefix(outLength))),
                       "ca35def5ae56cec33dc2036731ab14896bc4c75dbb07a61f879f8e3afa4c79440177015efc1fe7a37c629af7120a96274e6ab7afcc9261901d0e09ae32a5bb96")
    }

    // MARK: Swift link against the C responder, in process

    private final class FakeTransport: PWEPacketTransport, @unchecked Sendable {
        var sent = Data()
        var cancelled = false
        func send(content: Data?, contentContext: NWConnection.ContentContext, isComplete: Bool,
                  completion: NWConnection.SendCompletion) {
            if let content { sent.append(content) }
            if case .contentProcessed(let handler) = completion { handler(nil) }
        }
        func cancel() { cancelled = true }
        func take() -> [(UInt8, Data)] {
            var packets: [(UInt8, Data)] = []
            var raw = sent
            sent.removeAll()
            while raw.count >= 5 {
                let length = Int(TBMonitorProtocol.readBE32(raw, offset: 0))
                packets.append((raw[raw.startIndex + 4], raw.subdata(in: raw.startIndex + 5 ..< raw.startIndex + 4 + length)))
                raw = raw.subdata(in: raw.startIndex + 4 + length ..< raw.endIndex)
            }
            return packets
        }
    }

    /// The receiver side: the C state machine with its own keychain store.
    private final class Responder {
        let sec: OpaquePointer
        let gate: UnsafeMutablePointer<pwe_sec_gate>
        var events: Int32 = 0
        init(store: PWEPairingStore, gate: UnsafeMutablePointer<pwe_sec_gate>) {
            XCTAssertTrue(store.loadIdentity())
            var opts = pwe_sec_responder_opts(direct_link: 1)
            sec = pwe_sec_new(PWE_SEC_RESPONDER, store.identity, store.store, gate, &opts)
            self.gate = gate
        }
        deinit { pwe_sec_free(sec) }
        /// Handles packets, returns what it would send.
        func handle(_ packets: [(UInt8, Data)]) -> [(UInt8, Data)] {
            var out: [(UInt8, Data)] = []
            for (type, payload) in packets {
                var buffer = [UInt8](repeating: 0, count: 8192)
                buffer.withUnsafeMutableBufferPointer { buf in
                    var o = pwe_sec_out(buf: buf.baseAddress, len: 0, cap: buf.count)
                    payload.withUnsafeBytes { raw in
                        events |= pwe_sec_handle(sec, type, raw.bindMemory(to: UInt8.self).baseAddress, raw.count, &o, 1000)
                    }
                    let t = FakeTransport()
                    t.sent = Data(buf.prefix(o.len))
                    out += t.take()
                }
            }
            return out
        }
        var code: String { String(cString: pwe_sec_code(sec)) }
        var isSecure: Bool { pwe_sec_is_secure(sec) != 0 }
    }

    private func gate() -> UnsafeMutablePointer<pwe_sec_gate> {
        let g = UnsafeMutablePointer<pwe_sec_gate>.allocate(capacity: 1)
        g.initialize(to: pwe_sec_gate())
        gates.append(g)
        return g
    }

    /// Runs packets between the two until nothing moves; returns the link's last step.
    @discardableResult
    private func pump(_ link: PWESecureLink, _ transport: FakeTransport, _ responder: Responder,
                      first: PWESecureLink.Step) -> PWESecureLink.Step {
        var last = first
        for _ in 0..<10 {
            let toReceiver = transport.take()
            if toReceiver.isEmpty { break }
            for (type, payload) in responder.handle(toReceiver) {
                last = link.handle(type: type, payload: payload)
            }
        }
        return last
    }

    func testPairThenResumeThenRecordsBothWays() {
        let mac = makeStore("sender"), imac = makeStore("receiver")
        let g = gate()

        // First connection: the iMac shows a code, the user types it.
        var transport = FakeTransport()
        var link = PWESecureLink(transport: transport, plaintext: false, store: mac)
        var responder = Responder(store: imac, gate: g)
        var step = pump(link, transport, responder, first: link.start(expectedID: nil, code: nil))
        XCTAssertTrue(step.has(PWE_SEC_EV_NEED_CODE))
        XCTAssertEqual(responder.code.count, 6)
        step = pump(link, transport, responder, first: link.submit(code: responder.code))
        XCTAssertEqual(link.mode, .secure)
        XCTAssertTrue(responder.isSecure)
        XCTAssertEqual(mac.pairedReceivers().count, 1)
        XCTAssertEqual(imac.pairedReceivers().first?.name, Host.current().localizedName ?? "Mac")

        // A sealed packet: NWConnection-style send, opened by the receiver.
        let clipboard = TBMonitorProtocol.makeJSONPacket(type: .clipboard, value: TBMonitorClipboard(text: "secret text"))!
        link.send(content: clipboard, completion: .contentProcessed({ _ in }))
        let sealed = transport.take()
        XCTAssertEqual(sealed.count, 1)
        XCTAssertEqual(sealed[0].0, TBMonitorPacketType.secSealed.rawValue)
        XCTAssertNil(sealed[0].1.range(of: Data("secret".utf8)))
        var payload = [UInt8](sealed[0].1)
        var innerType: UInt8 = 0
        var innerPointer: UnsafeMutablePointer<UInt8>?
        var innerLength = 0
        XCTAssertEqual(pwe_sec_open(responder.sec, &payload, payload.count, &innerType, &innerPointer, &innerLength), 0)
        XCTAssertEqual(innerType, TBMonitorPacketType.clipboard.rawValue)

        // And back: the receiver seals, the link opens.
        let profile = Array(#"{"name":"iMac"}"#.utf8)
        var out = [UInt8](repeating: 0, count: profile.count + Int(PWE_SEC_SEAL_OVERHEAD))
        var outLength = 0
        XCTAssertEqual(pwe_sec_seal(responder.sec, 0x11, profile, profile.count, &out, out.count, &outLength), 0)
        let opened = link.open(Data(out[5..<outLength]))
        XCTAssertEqual(opened?.0, 0x11)
        XCTAssertEqual(opened?.1, Data(profile))
        XCTAssertNil(link.open(Data(out[5..<outLength])), "a replayed record is refused")
        XCTAssertEqual(link.mode, .closed)

        // Second connection: stored keys, no code.
        transport = FakeTransport()
        link = PWESecureLink(transport: transport, plaintext: false, store: mac)
        responder = Responder(store: imac, gate: g)
        let receiverID = PWEPairingStore.data(hex: mac.pairedReceivers()[0].id)
        step = pump(link, transport, responder, first: link.start(expectedID: receiverID, code: nil))
        XCTAssertFalse(step.has(PWE_SEC_EV_NEED_CODE))
        XCTAssertFalse(step.has(PWE_SEC_EV_IDENTITY_CHANGED))
        XCTAssertEqual(link.mode, .secure)

        // Forget on the Mac: the next connection asks for a code again.
        mac.forget(receiverID: mac.pairedReceivers()[0].id)
        XCTAssertTrue(mac.pairedReceivers().isEmpty)
        transport = FakeTransport()
        link = PWESecureLink(transport: transport, plaintext: false, store: mac)
        responder = Responder(store: imac, gate: g)
        step = pump(link, transport, responder, first: link.start(expectedID: nil, code: nil))
        XCTAssertTrue(step.has(PWE_SEC_EV_NEED_CODE))
    }

    func testNothingButTheHandshakeLeavesBeforeTheKeys() {
        let transport = FakeTransport()
        let link = PWESecureLink(transport: transport, plaintext: false, store: makeStore("sender"))
        var completed = false
        link.send(content: TBMonitorProtocol.makeInputEventPacket(TBMonitorInputEvent(kind: "keyDown", keyCode: 0)),
                  completion: .contentProcessed({ _ in completed = true }))
        XCTAssertTrue(transport.sent.isEmpty)
        XCTAssertTrue(completed, "a withheld packet still completes, so counters stay right")
    }

    func testUnencryptedSessionCarriesPictureAndLevelsOnly() {
        let transport = FakeTransport()
        let link = PWESecureLink(transport: transport, plaintext: true, store: makeStore("sender"))
        XCTAssertEqual(link.mode, .plaintext)
        let frame = TBMonitorProtocol.makePacket(type: .frame, payload: Data([1, 2, 3]))
        let brightness = TBMonitorProtocol.makeJSONPacket(type: .brightness, value: TBMonitorBrightness(level: 0.5))!
        let input = TBMonitorProtocol.makeInputEventPacket(TBMonitorInputEvent(kind: "keyDown", keyCode: 0))
        let clipboard = TBMonitorProtocol.makeJSONPacket(type: .clipboard, value: TBMonitorClipboard(text: "x"))!
        for packet in [frame, brightness, input, clipboard] {
            link.send(content: packet, completion: .contentProcessed({ _ in }))
        }
        XCTAssertEqual(transport.take().map(\.0), [TBMonitorPacketType.frame.rawValue, TBMonitorPacketType.brightness.rawValue])
        XCTAssertTrue(link.allowsInbound(plaintextType: TBMonitorPacketType.displayProfile.rawValue))
        XCTAssertFalse(link.allowsInbound(plaintextType: TBMonitorPacketType.inputEvent.rawValue))
        XCTAssertFalse(link.allowsInbound(plaintextType: TBMonitorPacketType.clipboard.rawValue))
    }

    func testSecurityStatesThatWaitForTheUser() {
        XCTAssertTrue(PWESecurityState.needsCode(secondsLeft: 60, identityChanged: false).waitsForUser)
        XCTAssertTrue(PWESecurityState.wrongCode.waitsForUser)
        XCTAssertTrue(PWESecurityState.legacyReceiver(previouslyPaired: false).waitsForUser)
        XCTAssertTrue(PWESecurityState.refused(.notOnCable).waitsForUser)
        XCTAssertFalse(PWESecurityState.negotiating.waitsForUser)
        XCTAssertFalse(PWESecurityState.encrypted(receiverName: "iMac").waitsForUser)
        XCTAssertFalse(PWESecurityState.unencrypted.waitsForUser)
    }

    // MARK: The engine against the C receiver hook, over loopback

    /// Runs only with TEST_RUNNER_PWE_SECURE_RECEIVER=<path to TBReceiverC's secure_receiver>.
    /// The engine dials TBMonitorProtocol.port, so 54321 must be free on this Mac.
    @MainActor
    func testEngineSessionPairsAndResumesWithLoopbackReceiver() async throws {
        guard let harness = ProcessInfo.processInfo.environment["PWE_SECURE_RECEIVER"] else {
            throw XCTSkip("set TEST_RUNNER_PWE_SECURE_RECEIVER to run the loopback test")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pwe-loopback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let codeFile = dir.appendingPathComponent("code"), logFile = dir.appendingPathComponent("receiver.log")
        FileManager.default.createFile(atPath: logFile.path, contents: nil)
        let receiver = Process()
        receiver.executableURL = URL(fileURLWithPath: harness)
        receiver.arguments = ["--port", "\(TBMonitorProtocol.port)", "--code-file", codeFile.path,
                              "--connections", "2", "--no-profile"]
        receiver.standardOutput = try FileHandle(forWritingTo: logFile)
        let errFile = dir.appendingPathComponent("receiver.err")
        FileManager.default.createFile(atPath: errFile.path, contents: nil)
        receiver.standardError = try FileHandle(forWritingTo: errFile)
        // Not the test host's environment: its DYLD_* injection stops a sanitizer build.
        receiver.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]
        try receiver.run()
        defer { receiver.terminate() }
        func log() -> String { (try? String(contentsOf: logFile, encoding: .utf8)) ?? "" }
        func until(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if condition() { return true }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            return condition()
        }
        guard await until(5, { log().contains("LISTENING") }) else {
            let err = (try? String(contentsOf: errFile, encoding: .utf8)) ?? ""
            let status = receiver.isRunning ? "running" : "exit \(receiver.terminationStatus)"
            throw XCTSkip("receiver hook did not listen on \(TBMonitorProtocol.port) (\(status)): \(log()) \(err)")
        }

        // The engine writes the receiver IP into the app's defaults; put it back.
        let ipKey = "fd.tbdisplaysender.receiverIP"
        let savedIP = UserDefaults.standard.object(forKey: ipKey)
        defer { UserDefaults.standard.set(savedIP, forKey: ipKey) }
        let savedStore = PWEPairingStore.shared
        PWEPairingStore.shared = makeStore("engine")
        defer { PWEPairingStore.shared = savedStore }

        let session = TBDisplaySenderSession(language: .english, largeCursor: false, preventDisplaySleep: false,
                                             autoRestartOnWake: false, audioEnabled: false)
        session.transportKind = .networkLink
        session.receiverIP = "127.0.0.1"
        session.localInterfaceIP = "127.0.0.1"

        // 1. First connection: code shown by the receiver, typed into the engine.
        session.connect()
        let asked = await until(5) {
            if case .needsCode = session.pweSecurity { return true }
            return false
        }
        XCTAssertTrue(asked, "engine asks for the code: \(session.pweSecurity)")
        let code = (try? String(contentsOf: codeFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        session.pweSubmitPairingCode(code)
        let ok1 = await until(5) { session.pweSecurity.isEncrypted }
        XCTAssertTrue(ok1, "encrypted: \(session.pweSecurity)")
        let ok2 = await until(3) { log().contains("PAIRED") }
        XCTAssertTrue(ok2)
        try await Task.sleep(nanoseconds: 300_000_000)
        session.language = .italian            // reaches the receiver inside the session
        try await Task.sleep(nanoseconds: 300_000_000)
        session.stopForAutomaticReconnect()    // sealed teardown; leaves the automation marker alone
        let ok3 = await until(5) { log().components(separatedBy: "SESSION").count > 1 }
        XCTAssertTrue(ok3)

        // 2. Second connection: stored keys, no code.
        session.connect()
        let ok4 = await until(5) { session.pweSecurity.isEncrypted }
        XCTAssertTrue(ok4, "resumed: \(session.pweSecurity)")
        session.stopForAutomaticReconnect()
        let ok5 = await until(5) { log().components(separatedBy: "SESSION").count > 2 }
        XCTAssertTrue(ok5)

        let sessions = log().split(separator: "\n").filter { $0.hasPrefix("SESSION") }
        XCTAssertEqual(sessions.count, 2, log())
        guard sessions.count == 2 else { return }
        for field in ["secure=1", "hello=1", "mode=1", "brightness=1", "volume=1", "language=1", "teardown=1"] {
            XCTAssertTrue(sessions[0].contains(field), "first session \(field): \(sessions[0])")
        }
        XCTAssertTrue(sessions[1].contains("secure=1") && sessions[1].contains("hello=1"), String(sessions[1]))
        XCTAssertEqual(log().components(separatedBy: "\nCODE ").count - 1, 1, "only the first connection showed a code")
    }

    /// An original TargetBridge receiver: talks first, in the clear, and ignores
    /// the handshake. A small Python stand-in on 54321 (TEST_RUNNER_PWE_SECURE_RECEIVER
    /// set, as for the loopback test above).
    @MainActor
    func testEngineDetectsOriginalReceiverAndLimitsAnUnencryptedSession() async throws {
        guard ProcessInfo.processInfo.environment["PWE_SECURE_RECEIVER"] != nil else {
            throw XCTSkip("set TEST_RUNNER_PWE_SECURE_RECEIVER to run the loopback tests")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pwe-legacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let logFile = dir.appendingPathComponent("legacy.log")
        FileManager.default.createFile(atPath: logFile.path, contents: nil)
        let script = """
        import json, socket, struct, sys
        log = open(sys.argv[1], "a", buffering=1)
        srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind(("127.0.0.1", 54321)); srv.listen(1); log.write("LISTENING\\n")
        for n in range(2):
            c, _ = srv.accept()
            if n == 0:   # like upstream: the display profile right after accept
                b = json.dumps({"name": "Old iMac"}).encode(); c.sendall(struct.pack(">IB", len(b) + 1, 0x11) + b)
            buf = b""; types = []
            while True:
                d = c.recv(65536)
                if not d: break
                buf += d
                while len(buf) >= 5:
                    l = struct.unpack(">I", buf[:4])[0]
                    if len(buf) < 4 + l: break
                    types.append(buf[4]); buf = buf[4 + l:]
                if 0x31 in types: break
            log.write("TYPES " + ",".join("%02x" % t for t in types) + "\\n"); c.close()
        """
        let receiver = Process()
        receiver.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        receiver.arguments = ["-I", "-c", script, logFile.path]
        receiver.environment = ["PATH": "/usr/bin:/bin"]
        try receiver.run()
        defer { receiver.terminate() }
        func log() -> String { (try? String(contentsOf: logFile, encoding: .utf8)) ?? "" }
        func until(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if condition() { return true }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            return condition()
        }
        guard await until(5, { log().contains("LISTENING") }) else { throw XCTSkip("port 54321 is in use") }

        let ipKey = "fd.tbdisplaysender.receiverIP"
        let savedIP = UserDefaults.standard.object(forKey: ipKey)
        defer { UserDefaults.standard.set(savedIP, forKey: ipKey) }
        let savedStore = PWEPairingStore.shared
        PWEPairingStore.shared = makeStore("legacy")
        defer { PWEPairingStore.shared = savedStore }
        let savedAllow = UserDefaults.standard.object(forKey: PWEPairingStore.allowUnencryptedKey)
        defer { UserDefaults.standard.set(savedAllow, forKey: PWEPairingStore.allowUnencryptedKey) }
        PWEPairingStore.allowUnencrypted = true

        let session = TBDisplaySenderSession(language: .english, largeCursor: false, preventDisplaySleep: false,
                                             autoRestartOnWake: false, audioEnabled: false)
        session.transportKind = .networkLink
        session.receiverIP = "127.0.0.1"
        session.localInterfaceIP = "127.0.0.1"
        session.connect()
        let detected = await until(3) { session.pweSecurity == .legacyReceiver(previouslyPaired: false) }
        XCTAssertTrue(detected, "original receiver detected: \(session.pweSecurity)")
        XCTAssertTrue(session.pweSecurity.waitsForUser)

        // The user agrees: an unencrypted session, without input or clipboard.
        session.pweConnectUnencrypted()
        let unencrypted = await until(3) { session.pweSecurity == .unencrypted }
        XCTAssertTrue(unencrypted, "unencrypted: \(session.pweSecurity)")
        try await Task.sleep(nanoseconds: 300_000_000)
        session.sendClipboardText("must not leave this Mac")
        session.sendInputEvent(TBMonitorInputEvent(kind: "keyDown", keyCode: 0))
        try await Task.sleep(nanoseconds: 200_000_000)
        session.stopForAutomaticReconnect()
        let done = await until(5) { log().components(separatedBy: "TYPES").count > 2 }
        XCTAssertTrue(done, log())
        let lines = log().split(separator: "\n").filter { $0.hasPrefix("TYPES") }
        guard lines.count == 2 else { return }
        XCTAssertTrue(lines[0].hasPrefix("TYPES 50"), "first connection opened with the handshake: \(lines[0])")
        let second = lines[1].dropFirst(6).split(separator: ",")
        XCTAssertTrue(second.contains("10"), "hello sent: \(lines[1])")
        XCTAssertTrue(second.contains("35") && second.contains("37"), "brightness and volume sent: \(lines[1])")
        XCTAssertFalse(second.contains("33") || second.contains("34") || second.contains("36"),
                       "no input, input mode or clipboard: \(lines[1])")
        XCTAssertFalse(second.contains("50"), "no handshake once the user chose unencrypted: \(lines[1])")
    }
}
