import Foundation
import Network

// PWE: pairing and encrypted sessions, sender side.
//
// The protocol is one C implementation shared with the receiver
// (TargetBridge-Shared/secure/pwe_secure.h, through the bridging header).
// This file adapts it to NWConnection:
//   - PWESecurityState: what the window shows (TBDisplaySenderSession.pweSecurity)
//   - PWEPairingStore:  this Mac's key and the paired iMacs (login keychain)
//   - PWESecureLink:    one connection; seals every packet once secure

/// Why a connection was refused before it became a display.
enum PWESecurityRefusal: Equatable, Sendable {
    /// Pairing works only over the cable (Thunderbolt Bridge or USB), not the network.
    case notOnCable
    /// The iMac could not read its keychain (for example, it is locked).
    case receiverKeychain
    /// This Mac could not read its keychain.
    case senderKeychain
    /// The iMac's receiver speaks a different version of the protocol.
    case version
    /// A malformed or unexpected handshake message.
    case protocolError
    /// The iMac turned away this Mac (for example, the user cancelled on the Mac).
    case cancelled
    /// The receiver is the original TargetBridge (or PWE 1.0) and this Mac
    /// has "Allow unencrypted connections" turned off.
    case unencryptedNotAllowed
}

/// Security state of one session, for the UI. The engine sets it; the UI
/// answers through TBDisplaySenderSession.pweSubmitPairingCode(_:) and friends.
enum PWESecurityState: Equatable, Sendable {
    /// Not connected, or nothing to show yet.
    case none
    /// Handshake in progress (normally a few milliseconds).
    case negotiating
    /// The iMac is showing a 6-digit code: ask for it. `identityChanged` when
    /// this iMac was paired before with another key (reinstalled).
    case needsCode(secondsLeft: Int, identityChanged: Bool)
    /// A code was sent; waiting for the iMac.
    case checkingCode
    /// The code was wrong. The iMac is showing a new one: ask again.
    case wrongCode
    /// The code was typed after it expired. The iMac shows a new one on the next try.
    case codeExpired
    /// Too many wrong codes: pairing is locked for `seconds`.
    case locked(seconds: Int)
    case refused(PWESecurityRefusal)
    /// The receiver does not speak this protocol (original TargetBridge, or
    /// PWE iMac Display 1.0). The connection would be unencrypted and
    /// unverified. `previouslyPaired`: this Mac had paired with this iMac, so
    /// it should not happen — do not offer a one-click downgrade.
    case legacyReceiver(previouslyPaired: Bool)
    /// Encrypted and authenticated.
    case encrypted(receiverName: String)
    /// Unencrypted, by the user's choice: picture, sound, brightness and volume only.
    case unencrypted

    /// While true, automatic reconnect waits: the next step is the user's.
    var waitsForUser: Bool {
        switch self {
        case .needsCode, .wrongCode, .codeExpired, .locked, .refused, .legacyReceiver: return true
        default: return false
        }
    }

    var isEncrypted: Bool {
        if case .encrypted = self { return true }
        return false
    }
}

struct PWEPairedReceiver: Identifiable, Equatable, Sendable {
    /// The receiver's key id (hex): stable until the receiver is reinstalled.
    let id: String
    let name: String
    let pairedAt: Date
}

/// This Mac's pairing key and the iMacs it has paired with, in the login keychain.
final class PWEPairingStore: @unchecked Sendable {
    /// Replaceable in tests only (a throwaway keychain service).
    nonisolated(unsafe) static var shared = PWEPairingStore()
    static let keychainService = "com.pwegroup.pweimacdisplay.pairing"

    /// D1: unencrypted connections are allowed (with a warning) unless the user turns them off.
    static let allowUnencryptedKey = "pwe.allowUnencryptedConnections"
    static var allowUnencrypted: Bool {
        get { UserDefaults.standard.object(forKey: allowUnencryptedKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: allowUnencryptedKey) }
    }

    /// Which key id each receiver (by its Bonjour identity) had when paired. Only a
    /// hint: it lets the engine notice "this iMac's identity changed" and refuse to
    /// downgrade an iMac it paired with. Trust comes from the keys, never from this.
    private static let hintsKey = "pwe.pairedReceiverHints"

    let keystore: UnsafeMutablePointer<pwe_keystore>
    let identity: UnsafeMutablePointer<pwe_sec_identity>
    let store: UnsafeMutablePointer<pwe_sec_store>
    private let lock = NSLock()
    private var loaded = false
    private let defaults: UserDefaults

    init(service: String = PWEPairingStore.keychainService, defaults: UserDefaults = .standard) {
        keystore = .allocate(capacity: 1)
        identity = .allocate(capacity: 1)
        store = .allocate(capacity: 1)
        keystore.initialize(to: pwe_keystore())
        identity.initialize(to: pwe_sec_identity())
        store.initialize(to: pwe_sec_store())
        self.defaults = defaults
        _ = pwe_sec_global_init()
        pwe_keystore_init(keystore, service, 0)
        pwe_keystore_as_store(keystore, store)
    }

    deinit {
        withUnsafeMutableBytes(of: &identity.pointee) { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) }
        keystore.deallocate()
        identity.deallocate()
        store.deallocate()
    }

    /// Loads (or creates, the first time) this Mac's key. False if the keychain cannot be used.
    func loadIdentity() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if loaded { return true }
        let name = Host.current().localizedName ?? "Mac"
        loaded = pwe_keystore_load_identity(keystore, name, identity) == 0
        if !loaded {
            TBLog.connection.error("pairing: keychain unavailable (\(self.keystore.pointee.last_status, privacy: .public))")
        }
        return loaded
    }

    func pairedReceivers() -> [PWEPairedReceiver] {
        var peers = [pwe_keystore_peer](repeating: pwe_keystore_peer(), count: 64)
        let count = Int(pwe_keystore_list_peers(keystore, &peers, Int32(peers.count)))
        guard count > 0 else { return [] }
        return peers.prefix(count).map { peer in
            var p = peer
            return PWEPairedReceiver(
                id: Self.hex(withUnsafeBytes(of: &p.id) { Data($0) }),
                name: withUnsafeBytes(of: &p.name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) },
                pairedAt: Date(timeIntervalSince1970: TimeInterval(p.paired_at))
            )
        }
    }

    /// Forget one iMac: its keychain item (`peer.<id>`) and every Bonjour hint
    /// that points to it, so the next connection asks for its code again.
    /// `receiverID` is the key id in hex (PWEPairedReceiver.id), never a
    /// Bonjour identity. False, and the hints kept, when the keychain refused
    /// or the item is still there afterwards; the reason is logged.
    @discardableResult
    func forget(receiverID: String) -> Bool {
        let hex = receiverID.lowercased()
        guard let id = Self.data(hex: hex), id.count == Int(PWE_SEC_ID_BYTES) else {
            TBLog.connection.error("pairing: cannot forget \(receiverID, privacy: .public): not a key id")
            return false
        }
        let rc = id.withUnsafeBytes { pwe_keystore_forget_peer(keystore, $0.bindMemory(to: UInt8.self).baseAddress!) }
        let deleteStatus = keystore.pointee.last_delete_status
        let stillThere = pairedReceivers().contains { $0.id == hex }
        guard rc == 0, !stillThere else {
            TBLog.connection.error("pairing: forgetting \(hex, privacy: .public) failed (delete status \(deleteStatus, privacy: .public), still listed: \(stillThere, privacy: .public))")
            return false
        }
        let hints = receiverHints
        let kept = hints.filter { $0.value.lowercased() != hex }
        defaults.set(kept, forKey: Self.hintsKey)
        TBLog.connection.info("pairing: forgot \(hex, privacy: .public) and \(hints.count - kept.count, privacy: .public) hint(s)")
        return true
    }

    /// The Bonjour identities this Mac connected to the receiver with key id `receiverID` (hex).
    func hints(forReceiverID receiverID: String) -> [String] {
        let hex = receiverID.lowercased()
        return receiverHints.filter { $0.value.lowercased() == hex }.map(\.key).sorted()
    }

    func forgetAll() {
        _ = pwe_keystore_forget_all_peers(keystore)
        defaults.removeObject(forKey: Self.hintsKey)
    }

    func expectedReceiverID(forHint hint: String) -> Data? {
        guard !hint.isEmpty, let hex = receiverHints[hint] else { return nil }
        return Self.data(hex: hex)
    }

    func rememberReceiver(hint: String, id: Data) {
        guard !hint.isEmpty else { return }
        var hints = receiverHints
        hints[hint] = Self.hex(id)
        defaults.set(hints, forKey: Self.hintsKey)
    }

    /// Deletes this Mac's key too (tests).
    func deleteEverything() {
        _ = pwe_keystore_delete_everything(keystore)
        defaults.removeObject(forKey: Self.hintsKey)
        lock.lock(); loaded = false; lock.unlock()
    }

    private var receiverHints: [String: String] {
        defaults.dictionary(forKey: Self.hintsKey) as? [String: String] ?? [:]
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    static func data(hex: String) -> Data? {
        var out = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        return out
    }
}

/// Where a link's bytes go: an NWConnection, or a test double.
protocol PWEPacketTransport: AnyObject, Sendable {
    func send(content: Data?, contentContext: NWConnection.ContentContext, isComplete: Bool,
              completion: NWConnection.SendCompletion)
    func cancel()
}

extension NWConnection: PWEPacketTransport {}

/// One connection's security. Thread-safe: video frames are sealed on the
/// encoder's queue, everything else on the main actor. Sealing and handing the
/// packet to NWConnection happen under one lock, so record numbers go out in order.
final class PWESecureLink: @unchecked Sendable {
    enum Mode: Equatable, Sendable { case negotiating, secure, plaintext, closed }

    /// What one handshake step produced.
    struct Step: Sendable {
        var events: Int32 = 0
        var peerError: Int32 = 0
        var localError: Int32 = 0
        var lockSeconds = 0
        var codeSeconds = 0
        var peerName = ""
        var peerID: Data?

        func has(_ event: pwe_sec_event) -> Bool { events & Int32(bitPattern: event.rawValue) != 0 }
        var closes: Bool { has(PWE_SEC_EV_CLOSE) }
    }

    private let transport: PWEPacketTransport
    private let lock = NSLock()
    private var sec: OpaquePointer?
    private var currentMode: Mode
    private var withheld = 0

    var mode: Mode {
        lock.lock(); defer { lock.unlock() }
        return currentMode
    }

    /// `plaintext`: the user agreed to an unencrypted session with this receiver.
    convenience init(connection: NWConnection, plaintext: Bool, store: PWEPairingStore = .shared) {
        self.init(transport: connection, plaintext: plaintext, store: store)
    }

    init(transport: PWEPacketTransport, plaintext: Bool, store: PWEPairingStore = .shared) {
        self.transport = transport
        if plaintext {
            currentMode = .plaintext
        } else {
            currentMode = .negotiating
            if store.loadIdentity() {
                sec = pwe_sec_new(PWE_SEC_INITIATOR, store.identity, store.store, nil, nil)
            }
        }
    }

    deinit {
        if let sec { pwe_sec_free(sec) }
    }

    var hasKeys: Bool { lock.lock(); defer { lock.unlock() }; return sec != nil }

    /// Never pair on this connection (see pwe_sec_set_resume_only).
    func setResumeOnly() {
        lock.lock(); defer { lock.unlock() }
        if let sec { pwe_sec_set_resume_only(sec) }
    }

    // MARK: Handshake

    /// Sends HELLO. `expectedID`: the key id this receiver had when paired.
    /// `code`: a code the user already typed (pair at once with it).
    func start(expectedID: Data?, code: String?) -> Step {
        run { sec, out in
            let now = Self.nowMs
            return Self.withOptionalBytes(expectedID) { idPtr in
                Self.withOptionalCString(code) { codePtr in
                    pwe_sec_start(sec, idPtr, codePtr, out, now)
                }
            }
        }
    }

    /// The user typed the code (nil: cancelled).
    func submit(code: String?) -> Step {
        run { sec, out in
            Self.withOptionalCString(code) { pwe_sec_submit_code(sec, $0, out) }
        }
    }

    /// One handshake packet from the receiver (0x50-0x5E).
    func handle(type: UInt8, payload: Data) -> Step {
        run { sec, out in
            let now = Self.nowMs
            return payload.withUnsafeBytes { raw in
                pwe_sec_handle(sec, type, raw.bindMemory(to: UInt8.self).baseAddress, raw.count, out, now)
            }
        }
    }

    /// Closes the underlying connection.
    func cancel() { transport.cancel() }

    func close() {
        lock.lock(); defer { lock.unlock() }
        if let sec { _ = pwe_sec_closed(sec, Self.nowMs) }
        currentMode = .closed
    }

    private func run(_ body: (OpaquePointer, UnsafeMutablePointer<pwe_sec_out>) -> Int32) -> Step {
        lock.lock(); defer { lock.unlock() }
        guard let sec, currentMode == .negotiating else {
            return Step(events: Int32(bitPattern: PWE_SEC_EV_CLOSE.rawValue), localError: Int32(PWE_SEC_ERR_STORE.rawValue))
        }
        var buffer = [UInt8](repeating: 0, count: 8192)
        var step = Step()
        let produced: Data = buffer.withUnsafeMutableBufferPointer { buf in
            var out = pwe_sec_out(buf: buf.baseAddress, len: 0, cap: buf.count)
            let rc = body(sec, &out)
            step.events = rc < 0 ? Int32(bitPattern: PWE_SEC_EV_CLOSE.rawValue) : rc
            return Data(buf.prefix(out.len))
        }
        step.peerError = pwe_sec_peer_error(sec)
        step.localError = pwe_sec_local_error(sec)
        step.lockSeconds = Int(pwe_sec_lock_seconds(sec))
        step.codeSeconds = Int(pwe_sec_code_seconds(sec))
        step.peerName = String(cString: pwe_sec_peer_name(sec))
        if let id = pwe_sec_peer_id(sec) { step.peerID = Data(bytes: id, count: Int(PWE_SEC_ID_BYTES)) }
        if pwe_sec_is_secure(sec) != 0 { currentMode = .secure }
        if step.closes { currentMode = .closed }
        if !produced.isEmpty {
            transport.send(content: produced, contentContext: .defaultMessage, isComplete: true,
                           completion: .contentProcessed({ _ in }))
        }
        return step
    }

    // MARK: Records

    /// Drop-in for NWConnection.send(content:completion:) with one whole packet
    /// [BE32 len][type][payload]: sealed once secure; in an unencrypted session
    /// only what pwe_sec_plaintext_allowed permits goes out.
    func send(content packet: Data, completion: NWConnection.SendCompletion) {
        send(content: packet, contentContext: .defaultMessage, isComplete: true, completion: completion)
    }

    func send(content packet: Data, contentContext: NWConnection.ContentContext,
              isComplete: Bool, completion: NWConnection.SendCompletion) {
        lock.lock()
        defer { lock.unlock() }
        guard packet.count >= 5 else { return Self.complete(completion) }
        let type = packet[packet.startIndex + 4]
        switch currentMode {
        case .secure:
            guard let sec else { return Self.complete(completion) }
            let innerLength = packet.count - 5
            var sealed = Data(count: innerLength + Int(PWE_SEC_SEAL_OVERHEAD))
            var sealedLength = 0
            let rc = sealed.withUnsafeMutableBytes { out in
                packet.withUnsafeBytes { raw in
                    pwe_sec_seal(sec, type, raw.bindMemory(to: UInt8.self).baseAddress! + 5, innerLength,
                                 out.bindMemory(to: UInt8.self).baseAddress, out.count, &sealedLength)
                }
            }
            guard rc == 0 else {
                TBLog.connection.error("pairing: could not seal a packet; closing")
                transport.cancel()
                return Self.complete(completion)
            }
            transport.send(content: sealed, contentContext: contentContext, isComplete: isComplete, completion: completion)
        case .plaintext:
            guard pwe_sec_plaintext_allowed(type, 1) != 0 else {
                withheld += 1
                if withheld <= 5 {
                    TBLog.connection.info("unencrypted session: not sending packet 0x\(String(type, radix: 16), privacy: .public)")
                }
                return Self.complete(completion)
            }
            transport.send(content: packet, contentContext: contentContext, isComplete: isComplete, completion: completion)
        case .negotiating, .closed:
            // Nothing but the handshake goes out before the keys exist.
            Self.complete(completion)
        }
    }

    /// Decrypts a 0x5F payload. nil means the record failed: close the connection.
    func open(_ payload: Data) -> (UInt8, Data)? {
        lock.lock(); defer { lock.unlock() }
        guard let sec, currentMode == .secure else { return nil }
        var buffer = payload
        var innerType: UInt8 = 0
        var innerLength = 0
        let inner: Data? = buffer.withUnsafeMutableBytes { raw in
            var innerPtr: UnsafeMutablePointer<UInt8>?
            guard pwe_sec_open(sec, raw.bindMemory(to: UInt8.self).baseAddress, raw.count,
                               &innerType, &innerPtr, &innerLength) == 0, let innerPtr else { return nil }
            return Data(bytes: innerPtr, count: innerLength)
        }
        guard let inner else {
            currentMode = .closed
            return nil
        }
        return (innerType, inner)
    }

    /// Whether a packet from the receiver may be used in this session.
    func allowsInbound(plaintextType type: UInt8) -> Bool {
        mode == .plaintext && pwe_sec_plaintext_allowed(type, 0) != 0
    }

    // MARK: Helpers

    private static func complete(_ completion: NWConnection.SendCompletion) {
        if case .contentProcessed(let handler) = completion { handler(nil) }
    }

    private static var nowMs: UInt64 {
        UInt64(ProcessInfo.processInfo.systemUptime * 1000)
    }

    private static func withOptionalBytes<R>(_ data: Data?, _ body: (UnsafePointer<UInt8>?) -> R) -> R {
        guard let data, data.count >= Int(PWE_SEC_ID_BYTES) else { return body(nil) }
        return data.withUnsafeBytes { body($0.bindMemory(to: UInt8.self).baseAddress) }
    }

    private static func withOptionalCString<R>(_ string: String?, _ body: (UnsafePointer<CChar>?) -> R) -> R {
        guard let string else { return body(nil) }
        return string.withCString { body($0) }
    }
}

/// A short encrypted connection to a paired receiver that is not showing this
/// Mac, to deliver one packet (the UI language for its idle screen). It never
/// pairs and never falls back to an unencrypted connection: anything but the
/// stored-key handshake just closes.
final class PWESecureOneShot: @unchecked Sendable {
    private let connection: NWConnection
    private let link: PWESecureLink
    private let packet: Data
    private let expectedID: Data
    private let queue = DispatchQueue(label: "pwe.secure.oneshot")
    private var buffer = Data()
    private var finished = false
    /// Called once, with whether the packet was handed to the connection.
    private let completion: (Bool) -> Void

    private init(packet: Data, host: String, expectedID: Data, store: PWEPairingStore,
                 completion: @escaping (Bool) -> Void) {
        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: TBMonitorProtocol.port)!,
            using: .tcp
        )
        link = PWESecureLink(connection: connection, plaintext: false, store: store)
        self.packet = packet
        self.expectedID = expectedID
        self.completion = completion
    }

    /// Tries `hosts` in order and stops at the first that takes the packet:
    /// one connection when the first address answers.
    static func send(_ packet: Data, toFirstOf hosts: [String], expectedID: Data, store: PWEPairingStore = .shared) {
        guard let host = hosts.first else { return }
        let shot = PWESecureOneShot(packet: packet, host: host, expectedID: expectedID, store: store) { delivered in
            guard !delivered else { return }
            send(packet, toFirstOf: Array(hosts.dropFirst()), expectedID: expectedID, store: store)
        }
        shot.run()
    }

    private func run() {
        guard link.hasKeys else { return }
        link.setResumeOnly()
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                let step = link.start(expectedID: expectedID, code: nil)
                if step.closes { finish() } else { receive() }
            case .failed, .cancelled:
                finish()
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 3) { [self] in finish() }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, done, error in
            if let data { buffer.append(data) }
            do {
                while let (type, payload) = try TBMonitorProtocol.drainPacket(from: &buffer) {
                    guard (0x50...0x5E).contains(type.rawValue) else { return finish() }
                    let step = link.handle(type: type.rawValue, payload: payload)
                    if step.has(PWE_SEC_EV_SECURE) {
                        link.send(content: packet, completion: .contentProcessed({ [self] error in
                            finish(delivered: error == nil)
                        }))
                        return
                    }
                    if step.closes || step.has(PWE_SEC_EV_NEED_CODE) { return finish() }
                }
            } catch {
                return finish()
            }
            if done || error != nil { return finish() }
            receive()
        }
    }

    private func finish(delivered: Bool = false) {
        guard !finished else { return }
        finished = true
        link.close()
        connection.cancel()
        completion(delivered)
    }
}

/// PWE (T39): a session's 2 s heartbeat, sent from its own queue.
///
/// The receiver closes a session after 10 s without data, and on an idle
/// desktop the heartbeat can be the only packet. Upstream sent it from a
/// main-run-loop Timer, which stops firing while the main thread is blocked and
/// also while the run loop is out of its default mode (a menu open, a modal
/// panel, a live resize). On the test Mac (2026-10-21) the sender sent nothing
/// for 10 s and the iMac closed the session.
///
/// Sending from this queue is safe: PWESecureLink seals a packet and hands it to
/// the connection under one lock, as it already does for video frames from the
/// encoder's queue and for the pointer from its own thread.
///
/// Dead-man: a sender whose main thread hangs for good must not hold the iMac
/// in a frozen session (in receiverMaster mode, with its keyboard and mouse
/// captured). Each beat also posts a cheap probe to the main queue, which GCD
/// drains in the run loop's common modes, so an open menu or a modal panel
/// still answers it. Once main has not answered for `mainStallLimit`, beats
/// stop and the receiver's 10 s check ends the session; they resume when main
/// answers again.
final class PWEHeartbeat: @unchecked Sendable {
    static let interval: TimeInterval = 2
    /// Far above any hang a live sender recovers from, far below "forever".
    static let mainStallLimit: TimeInterval = 30

    /// Runs `answer` on the thread whose liveness the beats stand for.
    typealias MainProbe = @Sendable (_ answer: @escaping @Sendable () -> Void) -> Void
    static let mainQueueProbe: MainProbe = { answer in DispatchQueue.main.async(execute: answer) }

    private let queue = DispatchQueue(label: "pwe.heartbeat", qos: .userInteractive)
    private let interval: TimeInterval
    private let mainStallLimit: TimeInterval
    private let probeMain: MainProbe
    private let send: @Sendable (Data) -> Void
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var stopped = false
    /// Under `lock`: when main last answered a probe, and whether one is queued.
    private var mainAnsweredAt: TimeInterval = 0
    private var probeOutstanding = false
    /// Read and written on `queue` only.
    private var sequence: UInt64 = 0
    private var holding = false

    /// `send` gets one whole heartbeat packet per beat, on the heartbeat's queue.
    init(
        interval: TimeInterval = PWEHeartbeat.interval,
        mainStallLimit: TimeInterval = PWEHeartbeat.mainStallLimit,
        probeMain: @escaping MainProbe = PWEHeartbeat.mainQueueProbe,
        send: @escaping @Sendable (Data) -> Void
    ) {
        self.interval = interval
        self.mainStallLimit = mainStallLimit
        self.probeMain = probeMain
        self.send = send
    }

    convenience init(link: PWESecureLink, interval: TimeInterval = PWEHeartbeat.interval) {
        self.init(interval: interval) { packet in
            link.send(content: packet, completion: .contentProcessed({ _ in }))
        }
    }

    deinit { timer?.cancel() }

    /// Uptime: it stands still while the Mac sleeps, so a sleep is not a hang.
    private static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// The first beat goes out one interval from now, as upstream's did.
    func start() {
        lock.lock(); defer { lock.unlock() }
        guard timer == nil, !stopped else { return }
        mainAnsweredAt = Self.now()
        // Strict: App Nap must not stretch the interval toward the receiver's 10 s.
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.beat() }
        self.timer = timer
        timer.resume()
    }

    /// No beat starts after this returns. One already sealing may still go out;
    /// after the teardown it is harmless (the receiver has closed the session).
    func stop() {
        lock.lock(); defer { lock.unlock() }
        stopped = true
        timer?.cancel()
        timer = nil
    }

    private func mainAnswered() {
        lock.lock()
        mainAnsweredAt = Self.now()
        probeOutstanding = false
        lock.unlock()
    }

    private func beat() {
        lock.lock()
        let live = !stopped
        let mainSilentFor = Self.now() - mainAnsweredAt
        let probe = live && !probeOutstanding
        if probe { probeOutstanding = true }
        lock.unlock()
        guard live else { return }
        if probe { probeMain { [weak self] in self?.mainAnswered() } }

        if mainSilentFor > mainStallLimit {
            if !holding {
                holding = true
                TBLog.connection.notice("heartbeat: main thread silent \(Int(mainSilentFor), privacy: .public) s; holding beats")
            }
            return
        }
        if holding {
            holding = false
            TBLog.connection.notice("heartbeat: main thread answers again; beats resume")
        }
        sequence &+= 1
        guard let packet = TBMonitorProtocol.makeJSONPacket(
            type: .heartbeat,
            value: TBMonitorHeartbeat(sequence: sequence)
        ) else { return }
        send(packet)
    }
}
