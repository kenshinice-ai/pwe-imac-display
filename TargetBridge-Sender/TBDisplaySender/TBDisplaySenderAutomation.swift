import AppKit
import Foundation
import OSLog
import SystemConfiguration

/// PWE: this file's `[automation]` lines go to the unified log (public text).
/// Foundation's NSLog from the shipped app reached only stderr, so a wake or
/// replug on the test Mac left no trace of the retry loop's steps (T38, RC4 Q3).
/// This shadows Foundation's NSLog in this file only.
///
/// Level: info by default, which the system keeps in memory only (`log stream
/// --level info` and a sysdiagnose still see it). The retry loop runs every
/// 2 s while the iMac is absent; persisting each of its lines would keep
/// 30–60k lines a day. Call sites that record a state change pass `.notice`,
/// which is kept on disk: the sleep gate, a command, a dial (connecting,
/// redialing), and how a dial ended.
private let automationLog = Logger(subsystem: "com.targetbridge.sender", category: "automation")

private enum AutomationLogLevel { case info, notice }

private func NSLog(_ message: String, level: AutomationLogLevel = .info) {
    switch level {
    case .info: automationLog.info("\(message, privacy: .public)")
    case .notice: automationLog.notice("\(message, privacy: .public)")
    }
}

// Sender-side automation entry points.
//
// Lets the Sender be driven for scripting / SSH / login & wake automation WITHOUT a
// separate control daemon: it reuses the existing TBDisplaySenderService / session model.
//
// Two equivalent ways in:
//   • URL scheme:   open "targetbridge://connect?receiver=auto&mode=mirror&preset=native5k"
//                   open "targetbridge://disconnect"
//   • Launch args:  TargetBridge --connect --receiver auto --mode mirror --preset native5k
//                   (handy for a login item / LaunchAgent that should connect on launch)
//
// Both resolve to the same in-process actions on TBDisplaySenderService.shared, so there is
// no parallel connection logic — connect()/stop() are the same paths the GUI uses.
@MainActor
enum TBSenderAutomation {
    private static var didHandleLaunchArguments = false
    private static var continuousConnectTask: Task<Void, Never>?

    static func senderEnabledFlagURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support/TargetBridge/Sender", isDirectory: true)
            .appendingPathComponent("enabled", isDirectory: false)
    }

    static func suspendAutomaticReconnectAfterUserStop(
        enabledFlagURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        suspendAutomaticReconnect(
            enabledFlagURL: enabledFlagURL,
            fileManager: fileManager,
            logReason: "user stopped session"
        )
    }

    static func suspendAutomaticReconnectForRequiredPermission(
        enabledFlagURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        suspendAutomaticReconnect(
            enabledFlagURL: enabledFlagURL,
            fileManager: fileManager,
            logReason: "screen recording permission required"
        )
    }

    static func suspendAutomaticReconnectAfterCaptureFailure(
        enabledFlagURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        suspendAutomaticReconnect(
            enabledFlagURL: enabledFlagURL,
            fileManager: fileManager,
            logReason: "capture produced no frames"
        )
    }

    private static func suspendAutomaticReconnect(
        enabledFlagURL: URL?,
        fileManager: FileManager,
        logReason: String
    ) {
        continuousConnectTask?.cancel()
        continuousConnectTask = nil
        let marker = enabledFlagURL ?? senderEnabledFlagURL()
        do {
            if fileManager.fileExists(atPath: marker.path) {
                try fileManager.removeItem(at: marker)
            }
            NSLog("[automation] \(logReason); automatic reconnect suspended", level: .notice)
        } catch {
            NSLog("[automation] unable to clear automatic reconnect marker: \(error.localizedDescription)", level: .notice)
        }
    }

    /// Handle a `targetbridge://` URL (from `.onOpenURL`).
    static func handle(url: URL) {
        guard url.scheme?.lowercased() == "targetbridge" else { return }
        let action = (url.host ?? "").lowercased()
        var params: [String: String] = [:]
        if let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems {
            for item in items where item.value != nil {
                params[item.name.lowercased()] = item.value
            }
        }
        run(action: action, params: params)
    }

    /// Handle process launch arguments. No-op for a normal launch (no `--connect`/`--disconnect`).
    /// Runs at most once per process so a second window / state restoration can't re-trigger it.
    static func handleLaunchArguments(_ arguments: [String]) {
        guard !didHandleLaunchArguments else { return }
        didHandleLaunchArguments = true
        var action: String?
        var params: [String: String] = [:]
        var index = 1
        while index < arguments.count {
            let arg = arguments[index]
            if arg == "--connect" {
                action = "connect"
            } else if arg == "--disconnect" {
                action = "disconnect"
            } else if arg.hasPrefix("--") {
                let key = String(arg.dropFirst(2)).lowercased()
                if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
                    params[key] = arguments[index + 1]
                    index += 1
                } else {
                    params[key] = ""
                }
            }
            index += 1
        }
        guard let action else { return }
        run(action: action, params: params)
    }

    // MARK: - Dispatch

    private static func run(action: String, params: [String: String]) {
        switch action {
        case "connect":
            continuousConnectTask?.cancel()
            // PWE: a bridge redial still in flight belongs to the loop just
            // cancelled; drop it so the new loop's dial is not refused.
            TBDisplaySenderService.shared.sessions.forEach { $0.pweAbandonSpeculativeDial() }
            if flagEnabled(params["retry"] ?? params["autoreconnect"] ?? params["auto-reconnect"]) {
                continuousConnectTask = Task { await connectContinuously(params) }
            } else {
                continuousConnectTask = nil
                Task { _ = await connect(params) }
            }
        case "disconnect":
            continuousConnectTask?.cancel()
            continuousConnectTask = nil
            disconnect(params)
        default:
            NSLog("[automation] unknown action '\(action)' (expected connect|disconnect)", level: .notice)
        }
    }

    /// PWE: the attempt under way logs nothing per attempt (PWERetryPacing).
    private static var quietAttempt = false

    private static func connectContinuously(_ params: [String: String]) async {
        TBBridgeRedial.install()
        TBBridgeRedial.leftSessionConnecting = false
        var attempt = 0
        // PWE: when the iMac was last seen connected in this loop; nil before
        // the first failed attempt. Paces the log and the pauses (PWERetryPacing).
        var absentSince: TimeInterval?
        while !Task.isCancelled {
            await TBSystemSleepGate.waitUntilAwake()
            guard !Task.isCancelled else { return }
            // PWE: a pairing code or an unencrypted-connection question waits for the user.
            if let session = resolveSession(TBDisplaySenderService.shared, params["session"]),
               session.pweSecurity.waitsForUser {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                continue
            }

            // PWE: the bridge link just came back: dial the receiver's last bridge
            // address before Bonjour lists it again (TBBridgeRedial).
            var connected: TBDisplaySenderSession?
            switch await redialBridge(params) {
            case .connected(let session):
                connected = session
            case .failed:
                continue
            case .notDue:
                attempt += 1
                quietAttempt = !PWERetryPacing.logsAttempt(attempt)
                if !quietAttempt { NSLog("[automation] automatic connection attempt \(attempt)") }
                connected = await connect(params)
                quietAttempt = false
            }

            if let session = connected {
                if await waitForConnection(session) {
                    attempt = 0
                    absentSince = nil
                    NSLog("[automation] automatic connection active; monitoring link", level: .notice)
                    while !Task.isCancelled && (session.isConnected || session.isStreaming) {
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                    }
                    guard !Task.isCancelled else { return }
                    NSLog("[automation] connection lost; retrying", level: .notice)
                } else {
                    NSLog("[automation] connection attempt did not become active; retrying", level: .notice)
                }

                if !session.isConnected && !session.isStreaming {
                    session.stopForAutomaticReconnect()
                }
            }

            guard !Task.isCancelled else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if absentSince == nil { absentSince = now }
            await pauseBeforeRetry(params, upTo: PWERetryPacing.pauseCap(absentFor: absentSince.map { now - $0 }))
        }
    }

    /// PWE: up to `cap` seconds between attempts (2 s, as before; 5 s once the
    /// iMac has been absent a minute), but cut short when a bridge redial falls
    /// due or the remembered receiver appears in Bonjour. Sleeping through
    /// either cost up to 2.6 s after Bonjour's `Add` (T10, 2026-10-20).
    private static func pauseBeforeRetry(_ params: [String: String], upTo cap: TimeInterval) async {
        let service = TBDisplaySenderService.shared
        let session = resolveSession(service, params["session"])
        let wasListed = session.map { isListedWithAddress(service, $0) } ?? false
        for _ in 0..<Int((cap / 0.25).rounded()) {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let session else { continue }
            if TBBridgeRedial.isDue(for: session, service: service) { return }
            if !wasListed, isListedWithAddress(service, session) { return }
        }
    }

    /// The session's remembered receiver is in Bonjour with an address for its transport.
    private static func isListedWithAddress(_ service: TBDisplaySenderService, _ session: TBDisplaySenderSession) -> Bool {
        guard !session.selectedReceiverID.isEmpty else { return false }
        return service.discoveredReceivers.contains {
            $0.matchesPersistedIdentity(session.selectedReceiverID) && !$0.ip(for: session.transportKind).isEmpty
        }
    }

    private enum RedialOutcome {
        case notDue
        case failed
        case connected(TBDisplaySenderSession)
    }

    /// PWE: one redial of the receiver's last bridge address, if one is due
    /// (TBBridgeRedial.decide). The retry loop is the only caller, and it waits
    /// for this dial to connect or be abandoned before Bonjour's path can dial,
    /// so the two never connect at once.
    private static func redialBridge(_ params: [String: String]) async -> RedialOutcome {
        let service = TBDisplaySenderService.shared
        // Only for the plain automatic connection PWE uses: a named receiver, a
        // transport or a path probe in the request keeps the normal path.
        let receiver = params["receiver"].flatMap { $0.isEmpty ? nil : $0 } ?? "auto"
        guard receiver.lowercased() == "auto", params["transport"] == nil,
              (params["path"] ?? params["connection-path"] ?? params["connection"]) == nil,
              let session = resolveSession(service, params["session"]) else { return .notDue }

        guard case .dial(let receiverIP, let localIP) = TBBridgeRedial.decision(for: session, service: service) else {
            if TBBridgeRedial.leftSessionConnecting {
                // The last redial of this window left "Connecting…" up; Bonjour's
                // path takes over from a plain stopped session.
                TBBridgeRedial.leftSessionConnecting = false
                if !session.isConnected, !session.isStreaming { session.stopForAutomaticReconnect() }
            }
            return .notDue
        }

        applyModeAndPreset(params, to: session)
        session.receiverIP = receiverIP
        // An IPv6 redial binds no local address; keep the IPv4 one for Bonjour's path.
        if !localIP.isEmpty { session.localInterfaceIP = localIP }
        TBBridgeRedial.lastDialAt = ProcessInfo.processInfo.systemUptime
        NSLog("[automation] redialing \(receiverIP) over the Thunderbolt Bridge (\(TBBridgeRedial.triggerReason))", level: .notice)
        session.pweSpeculativeDial = true
        session.connect()

        let deadline = ProcessInfo.processInfo.systemUptime + TBBridgeRedial.dialTimeout
        while ProcessInfo.processInfo.systemUptime < deadline, !Task.isCancelled,
              session.pweSpeculativeDial, !session.isConnected {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if session.isConnected || session.isStreaming {
            TBBridgeRedial.leftSessionConnecting = false
            NSLog("[automation] redial connected to \(receiverIP)", level: .notice)
            return .connected(session)
        }
        session.pweAbandonSpeculativeDial()
        guard !Task.isCancelled else { return .failed }
        TBBridgeRedial.leftSessionConnecting = true
        // Pace the redials: the next one starts an interval after this one did.
        let next = TBBridgeRedial.lastDialAt.map { $0 + TBBridgeRedial.interval } ?? 0
        let wait = next - ProcessInfo.processInfo.systemUptime
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        return .failed
    }

    @discardableResult
    private static func connect(_ params: [String: String]) async -> TBDisplaySenderSession? {
        let service = TBDisplaySenderService.shared
        guard let session = resolveSession(service, params["session"]) else { return nil }

        // PWE: restarting Bonjour drops a receiver that is already listed, and
        // this attempt would then wait for it to be found and resolved again.
        let listed = !session.selectedReceiverID.isEmpty
            && service.discoveredReceivers.contains { $0.matchesPersistedIdentity(session.selectedReceiverID) }
        service.refreshLocalInterfaces(restartDiscovery: !listed)

        if let transport = params["transport"] {
            session.transportKind = parseTransport(transport)
        }

        let rawPath = params["path"] ?? params["connection-path"] ?? params["connection"]
        let pathPreference: TBConnectionPathPreference?
        if let rawPath {
            guard let parsed = TBConnectionPathPreference.parse(rawPath) else {
                NSLog("[automation] unknown connection path '\(rawPath)'; aborting connect")
                return nil
            }
            pathPreference = parsed
        } else {
            pathPreference = nil
        }

        let receiver = params["receiver"].flatMap { $0.isEmpty ? nil : $0 } ?? "auto"
        let discoveredReceivers = await waitForReceivers(
            service,
            preferredIdentity: receiver.lowercased() == "auto"
                ? session.selectedReceiverID
                : receiver,
            transportKind: session.transportKind,
            session: session
        )
        if receiver.lowercased() == "auto" {
            guard let discovered = automaticReceiver(
                in: discoveredReceivers,
                preferredIdentity: session.selectedReceiverID
            ) else {
                if quietAttempt {
                    // PWE: the retry loop said nothing for this attempt either.
                } else if !session.selectedReceiverID.isEmpty {
                    NSLog("[automation] preferred monitor unavailable or ambiguous; waiting for that monitor")
                } else if discoveredReceivers.count > 1 {
                    NSLog("[automation] multiple receivers discovered and no preferred monitor is selected; waiting for user choice")
                } else {
                    NSLog("[automation] no receivers discovered; aborting connect")
                }
                return nil
            }
            if let pathPreference {
                guard let selected = await selectConnectionPath(
                    receiver: discovered,
                    preference: pathPreference,
                    requestedLocalIP: params["localip"] ?? params["local-ip"]
                ) else {
                    NSLog("[automation] no working \(pathPreference.rawValue) path; aborting connect")
                    return nil
                }
                apply(selected, receiver: discovered, to: session)
            } else {
                guard hasAddress(discovered, for: session) else { return nil }
                service.applyDiscoveredReceiver(discovered, to: session)
            }
        } else if let discovered = discoveredReceivers.first(where: { matches(receiver, $0) }) {
            if let pathPreference {
                guard let selected = await selectConnectionPath(
                    receiver: discovered,
                    preference: pathPreference,
                    requestedLocalIP: params["localip"] ?? params["local-ip"]
                ) else {
                    NSLog("[automation] no working \(pathPreference.rawValue) path to \(receiver); aborting connect")
                    return nil
                }
                apply(selected, receiver: discovered, to: session)
            } else {
                guard hasAddress(discovered, for: session) else { return nil }
                service.applyDiscoveredReceiver(discovered, to: session)
            }
        } else {
            guard !isPersistedReceiverReference(receiver) else {
                NSLog("[automation] requested monitor identity is not available; aborting connect")
                return nil
            }
            // Treat as a raw IP / hostname (bypasses Bonjour).
            session.receiverIP = receiver
            session.selectedReceiverID = ""
        }

        if pathPreference == nil,
           let localIP = (params["localip"] ?? params["local-ip"]),
           !localIP.isEmpty {
            session.localInterfaceIP = localIP
        }
        if session.localInterfaceIP.isEmpty {
            session.localInterfaceIP = service.defaultLocalInterfaceIP(for: session.transportKind)
        }

        applyModeAndPreset(params, to: session)

        guard !session.receiverIP.isEmpty else {
            NSLog("[automation] no receiver IP resolved; aborting connect")
            return nil
        }
        // PWE (T34): a scoped IPv6 link-local dial over the bridge needs no local IPv4 address.
        let bridgeIPv6 = session.pweDialsBridgeIPv6
        guard session.pweHasDialAddresses else {
            NSLog("[automation] no local interface for transport \(session.transportKind.rawValue); aborting connect")
            return nil
        }
        guard !TBSystemSleepGate.isSleeping else {
            NSLog("[automation] the system is going to sleep; not connecting")
            return nil
        }
        NSLog("[automation] connecting to \(session.receiverIP) from \(bridgeIPv6 ? "IPv6 link-local" : session.localInterfaceIP) via \(session.transportKind.rawValue) — \(session.captureSource.rawValue)/\(session.capturePreset.rawValue)", level: .notice)
        session.connect()
        return session
    }

    private static func applyModeAndPreset(_ params: [String: String], to session: TBDisplaySenderSession) {
        if let mode = params["mode"] {
            if let source = parseMode(mode) { session.captureSource = source }
            else { NSLog("[automation] unknown mode '\(mode)' (ignored)") }
        }
        if let presetName = params["preset"] {
            if let preset = parsePreset(presetName) { session.capturePreset = preset }
            else { NSLog("[automation] unknown preset '\(presetName)' (ignored)") }
        }
    }

    private static func disconnect(_ params: [String: String]) {
        let service = TBDisplaySenderService.shared
        guard let target = resolveSessionIndex(params["session"], sessionCount: service.sessions.count, createDefaultIfNeeded: false) else {
            if params["session"] != nil {
                NSLog("[automation] invalid session '\(params["session"] ?? "")'; refusing to disconnect", level: .notice)
            } else {
                NSLog("[automation] no sessions available to disconnect", level: .notice)
            }
            return
        }

        if let target {
            service.sessions[target].stop(persistArrangement: true)
        } else {
            service.stopAll()
        }
    }

    // MARK: - Helpers

    private static func resolveSession(_ service: TBDisplaySenderService, _ raw: String?) -> TBDisplaySenderSession? {
        guard let index = resolveSessionIndex(raw, sessionCount: service.sessions.count, createDefaultIfNeeded: true) else {
            NSLog("[automation] invalid session '\(raw ?? "")'; aborting connect")
            return nil
        }

        if service.sessions.isEmpty {
            service.addSession()
        }
        guard !service.sessions.isEmpty, let safeIndex = index, safeIndex < service.sessions.count else { return nil }
        return service.sessions[safeIndex]
    }

    /// Resolves a 1-based session number from automation input.
    /// - Returns:
    ///   - `nil` when the explicit session is invalid.
    ///   - `.some(nil)` when no session was requested and the caller should target all sessions.
    ///   - `.some(index)` with a zero-based index for a specific session.
    /// - Note: `internal` (not `private`) so the unit-test bundle can exercise the tri-state logic.
    static func resolveSessionIndex(
        _ raw: String?,
        sessionCount: Int,
        createDefaultIfNeeded: Bool
    ) -> Int?? {
        guard let raw, !raw.isEmpty else {
            if createDefaultIfNeeded && sessionCount == 0 {
                return .some(0)
            }
            return createDefaultIfNeeded ? .some(0) : .some(nil)
        }

        guard let number = Int(raw), number >= 1 else {
            return nil
        }

        let index = number - 1
        if index < sessionCount {
            return .some(index)
        }
        if createDefaultIfNeeded && sessionCount == 0 && index == 0 {
            return .some(0)
        }
        return nil
    }

    /// Bonjour results arrive incrementally. Waiting for a short settled window
    /// prevents `auto` from connecting to whichever of several displays happens
    /// to advertise first. A previously selected stable identity may return
    /// immediately because it is unambiguous.
    private static func waitForReceivers(
        _ service: TBDisplaySenderService,
        preferredIdentity: String,
        transportKind: TBTransportKind,
        session: TBDisplaySenderSession? = nil
    ) async -> [TBDiscoveredReceiver] {
        var lastSignature: [String] = []
        var unchangedIterations = 0
        var firstNonEmptyIteration: Int?

        for iteration in 0..<24 {
            let receivers = service.discoveredReceivers
            // PWE: the bridge link came back meanwhile; the retry loop redials
            // the last bridge address rather than waiting here for Bonjour.
            if let session, TBBridgeRedial.isDue(for: session, service: service) {
                return receivers
            }
            if !preferredIdentity.isEmpty {
                let preferred = receivers.filter { $0.matchesPersistedIdentity(preferredIdentity) }
                if preferred.contains(where: { !$0.ip(for: transportKind).isEmpty }) {
                    return receivers
                }
                // Present but not yet reachable on this transport: its bridge
                // address usually follows within a second or two of a replug.
                if !preferred.isEmpty {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    continue
                }
            }

            if !receivers.isEmpty {
                if firstNonEmptyIteration == nil { firstNonEmptyIteration = iteration }
                let signature = receivers
                    .map { "\($0.stableIdentity)|\($0.preferredIP)" }
                    .sorted()
                if signature == lastSignature {
                    unchangedIterations += 1
                } else {
                    lastSignature = signature
                    unchangedIterations = 0
                }

                if let firstNonEmptyIteration,
                   iteration - firstNonEmptyIteration >= 6,
                   unchangedIterations >= 3 {
                    return receivers
                }
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return service.discoveredReceivers
    }

    /// A receiver seen only with its Wi-Fi or LAN address cannot be dialed over
    /// the Thunderbolt Bridge. Skip this attempt; the retry loop asks again.
    private static func hasAddress(_ receiver: TBDiscoveredReceiver, for session: TBDisplaySenderSession) -> Bool {
        let transportKind = session.transportKind
        guard receiver.ip(for: transportKind).isEmpty else { return true }
        if transportKind == .networkLink {
            // PWE: not a moment's wait as on the bridge: a receiver announced on
            // the cable only has no network address until its network is allowed.
            let reason = "\(receiver.receiverName) announces no network address: it accepts the cable only "
                + "(allow the network on the receiver, preference AllowLocalNetwork). Not dialing its cable address."
            NSLog("[automation] \(reason)")
            session.pweReportNoAddress(reason)
        } else {
            NSLog("[automation] \(receiver.receiverName) has no \(transportKind.rawValue) address yet; waiting for it")
        }
        return false
    }

    /// Automatic startup is safe only when the preferred display is present or
    /// exactly one Receiver exists and no preference was saved. With multiple unpaired displays, returning
    /// nil is intentional: silently choosing the first one would send the user's
    /// desktop to the wrong Mac.
    static func automaticReceiver(
        in receivers: [TBDiscoveredReceiver],
        preferredIdentity: String
    ) -> TBDiscoveredReceiver? {
        if !preferredIdentity.isEmpty {
            let preferred = receivers.filter {
               $0.matchesPersistedIdentity(preferredIdentity)
            }
            return preferred.count == 1 ? preferred[0] : nil
        }
        return receivers.count == 1 ? receivers[0] : nil
    }

    static func isPersistedReceiverReference(_ value: String) -> Bool {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value.hasPrefix("receiver:") || value.hasPrefix("service:") ||
            value.contains("|") || UUID(uuidString: value) != nil
    }

    private static func selectConnectionPath(
        receiver: TBDiscoveredReceiver,
        preference: TBConnectionPathPreference,
        requestedLocalIP: String?
    ) async -> TBConnectionMeasurement? {
        let allInterfaces = TBConnectionDiagnostics.currentIPv4Interfaces()
        let eligibleInterfaces: [TBConnectionDiagnostics.LocalInterface]
        if let requestedLocalIP, !requestedLocalIP.isEmpty {
            eligibleInterfaces = allInterfaces.filter { $0.ip == requestedLocalIP }
        } else {
            eligibleInterfaces = allInterfaces
        }

        let allCandidates = TBConnectionDiagnostics.connectionCandidates(
            receiver: receiver,
            interfaces: eligibleInterfaces,
            hardwareKinds: TBConnectionDiagnostics.hardwarePathKinds()
        )
        let candidates = allCandidates.filter { preference.allows($0.kind) }
        guard !candidates.isEmpty else {
            NSLog("[automation] no candidate interfaces/endpoints for path \(preference.rawValue)")
            return nil
        }

        let measurements = await Task.detached(priority: .userInitiated) {
            var values: [TBConnectionMeasurement] = []
            for candidate in candidates {
                guard !Task.isCancelled else { break }
                NSLog("[automation] probing \(candidate.kind.rawValue): \(candidate.localIP) (\(candidate.localInterfaceName)) -> \(candidate.receiverIP)")
                do {
                    let measurement = try TBConnectionDiagnostics.probe(candidate)
                    NSLog(
                        "[automation] path \(candidate.kind.rawValue) measured \(String(format: "%.3f", measurement.throughputGbps)) Gbit/s, \(String(format: "%.2f", measurement.connectLatencyMilliseconds)) ms"
                    )
                    values.append(measurement)
                } catch {
                    NSLog("[automation] path \(candidate.kind.rawValue) unavailable: \(error.localizedDescription)")
                }
                usleep(100_000)
            }
            return values
        }.value

        guard let selected = TBConnectionDiagnostics.selectBestMeasurement(
            measurements,
            preference: preference
        ) else { return nil }
        NSLog(
            "[automation] selected \(selected.candidate.kind.rawValue) on \(selected.candidate.localInterfaceName) at \(String(format: "%.3f", selected.throughputGbps)) Gbit/s"
        )
        return selected
    }

    private static func apply(
        _ measurement: TBConnectionMeasurement,
        receiver: TBDiscoveredReceiver,
        to session: TBDisplaySenderSession
    ) {
        session.transportKind = measurement.candidate.transportKind
        session.localInterfaceIP = measurement.candidate.localIP
        session.receiverIP = measurement.candidate.receiverIP
        session.receiverSupportsHEVCDecodeHint = receiver.supportsHEVCDecode
    }

    private static func waitForConnection(_ session: TBDisplaySenderSession) async -> Bool {
        for _ in 0..<40 {
            if session.isConnected || session.isStreaming { return true }
            guard !Task.isCancelled else { return false }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return session.isConnected || session.isStreaming
    }

    static func flagEnabled(_ value: String?) -> Bool {
        guard let value else { return false }
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "0", "false", "no", "off":
            return false
        default:
            return true
        }
    }

    // The pure parsing helpers below are `internal` (not `private`) so the
    // unit-test bundle can exercise them directly.
    static func matches(_ value: String, _ receiver: TBDiscoveredReceiver) -> Bool {
        let needle = value.lowercased()
        if receiver.matchesPersistedIdentity(needle) { return true }
        if receiver.receiverName.lowercased() == needle { return true }
        if let host = receiver.shortHostName?.lowercased(), host == needle { return true }
        return receiver.preferredIP.lowercased() == needle
            || receiver.thunderboltIP.lowercased() == needle
            || receiver.usbIP.lowercased() == needle
            || receiver.ethernetIP.lowercased() == needle
            || receiver.wifiIP.lowercased() == needle
            || receiver.networkIP.lowercased() == needle
            || receiver.resolvedIPv4Addresses.contains(where: { $0.lowercased() == needle })
    }

    static func parseTransport(_ value: String) -> TBTransportKind {
        switch value.lowercased() {
        case "net", "network", "networklink", "link":
            return .networkLink
        default:
            return .thunderboltBridge
        }
    }

    static func parseMode(_ value: String) -> TBDisplayCaptureSource? {
        switch value.lowercased() {
        case "extended", "extend", "extendeddesktop", "ext":
            return .extendedDesktop
        case "mirror", "mirrored", "desktopmirror":
            return .desktopMirror
        default:
            return TBDisplayCaptureSource(rawValue: value)
        }
    }

    static func parsePreset(_ value: String) -> TBDisplayCapturePreset? {
        if let preset = TBDisplayCapturePreset(rawValue: value) { return preset }
        switch value.lowercased() {
        case "1080p", "1080", "fullhd", "1920x1080": return .standard1080p
        case "1080p60", "fullhd60", "smooth1080": return .smooth1080p60
        case "1440p", "1440", "standard": return .standard1440p
        case "1440p60", "smooth", "smooth1440": return .smooth1440p60
        case "1800p", "1800p60", "smooth1800": return .smooth1800p60
        case "2160p", "2160p60", "4k", "crisp": return .crisp2160p60
        case "retina4k", "retina4k60", "4096x2304", "imac4k": return .retina4k60
        case "5k60", "native5k60": return .native5k60Experimental
        case "5k", "native", "5120x2880": return .native5k
        default: return nil
        }
    }
}

/// Between `willSleep` and `didWake` the sender must not reconnect or declare
/// user activity: either one wakes the Mac that is going to sleep. When the
/// link drops as the Mac goes to sleep, the retry loop used to reconnect within
/// a second or two and wake it again (3 of 6 sleeps on an iMac18,3).
@MainActor
enum TBSystemSleepGate {
    private static var sleepingSince: TimeInterval?
    private static var observers: [NSObjectProtocol] = []
    /// A refused sleep posts `willSleep` but no `didWake`. Uptime does not
    /// advance while the Mac sleeps, so this much of it means the Mac never slept.
    static let refusedSleepTimeout: TimeInterval = 120

    static var isSleeping: Bool {
        guard let since = sleepingSince else { return false }
        guard ProcessInfo.processInfo.systemUptime - since < refusedSleepTimeout else {
            NSLog("[automation] still awake \(Int(refusedSleepTimeout)) s after willSleep; the sleep was refused", level: .notice)
            sleepingSince = nil
            return false
        }
        return true
    }

    static func install() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                sleepingSince = ProcessInfo.processInfo.systemUptime
                NSLog("[automation] the system is going to sleep; no reconnects until it wakes", level: .notice)
            }
        })
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    // PWE: sleep took the Thunderbolt link down; it returns now.
                    TBBridgeRedial.noteTrigger("wake")
                    guard sleepingSince != nil else { return }
                    sleepingSince = nil
                    NSLog("[automation] the system is awake; reconnects allowed", level: .notice)
                }
            })
        }
    }

    static func waitUntilAwake() async {
        while isSleeping, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }
}

/// PWE: redial a receiver's last Thunderbolt Bridge address as soon as the
/// bridge link comes back, instead of waiting for Bonjour to list it again.
///
/// After a replug or a real sleep the picture took 22.5-26.8 s to return on an
/// iMac18,3 (2026-10-20). About 20 s of that was Bonjour: the link was up at
/// 13:27:13.4, `dns-sd -B` saw the receiver again at 13:27:33.4, yet its bridge
/// address (169.254.6.224) was the same every time. So when a link comes up,
/// a bridge address appears or the Mac wakes, the retry loop dials the address
/// that last worked, once a second for 10 s, each dial given 1 s. Bonjour keeps
/// looking meanwhile; the loop takes whichever answers first. It is the only dialer and waits for each redial to connect
/// or be abandoned, so there is never a second connection. Nothing here runs
/// unless the retry loop does: a Disconnect or automatic connection turned off
/// means no loop, and so no redial.
///
/// The address that last worked may be the receiver's IPv6 link-local one
/// (T34: a "Using DHCP" bridge has no IPv4 address for about 19 s). It is
/// dialed on this Mac's one settings-listed cable bridge, the rule discovery
/// uses for `tbIP6`: "fe80::…%bridge0". After a real sleep the dial waited
/// 2.8 s after the display came on, for Bonjour to list the iMac again (RC4 Q3).
///
/// A redial happens only while this Mac's session is gone (not connected, not
/// streaming): the receiver hands its connection to a new cable dial once the
/// old session has been silent for 2.5 s, and must never be led to drop a
/// session the sender still holds.
@MainActor
enum TBBridgeRedial {
    nonisolated static let window: TimeInterval = 10
    nonisolated static let interval: TimeInterval = 1
    nonisolated static let dialTimeout: TimeInterval = 1

    /// What the decision depends on, read from the engine in one go.
    struct Inputs: Equatable {
        var transport: TBTransportKind
        /// A connection is up, or a pairing question waits for the person.
        var sessionBusy: Bool
        var sleeping: Bool
        /// Bonjour lists the remembered receiver with its bridge address:
        /// the normal path dials it at once.
        var listedWithBridgeAddress: Bool
        /// Where the remembered receiver last answered on the bridge, without a
        /// scope: "169.254.…" or "fe80::…"; empty if never.
        var rememberedAddress: String
        /// This Mac's address on a Thunderbolt Bridge interface; empty if it has none.
        var localBridgeIP: String
        /// Seconds since the link came back (or the Mac woke); nil if not since launch.
        var secondsSinceTrigger: TimeInterval?
        /// Seconds since the last redial started; nil if none yet.
        var secondsSinceLastDial: TimeInterval?
        /// This Mac's settings-listed bridges that hold an IPv6 link-local
        /// address (TBConnectionDiagnostics.currentCableBridgeIPv6Interfaces).
        var cableBridgesIPv6: [String] = []
    }

    enum Decision: Equatable {
        case wait
        case dial(receiverIP: String, localIP: String)
    }

    /// The rule, with no clock and no engine (PWEBridgeRedialTests).
    nonisolated static func decide(_ inputs: Inputs) -> Decision {
        guard inputs.transport == .thunderboltBridge,
              !inputs.sessionBusy,
              !inputs.sleeping,
              !inputs.listedWithBridgeAddress,
              let sinceTrigger = inputs.secondsSinceTrigger, sinceTrigger >= 0, sinceTrigger < window
        else { return .wait }
        if let sinceDial = inputs.secondsSinceLastDial, sinceDial >= 0, sinceDial < interval { return .wait }
        let remembered = inputs.rememberedAddress
        if remembered.hasPrefix("169.254.") {
            guard inputs.localBridgeIP.hasPrefix("169.254.") else { return .wait }
            return .dial(receiverIP: remembered, localIP: inputs.localBridgeIP)
        }
        // IPv6: no local address to bind; the scope picks the bridge.
        let scoped = TBConnectionDiagnostics.scopedBridgeIPv6(
            advertised: remembered, resolved: [], cableBridges: inputs.cableBridgesIPv6)
        guard !scoped.isEmpty else { return .wait }
        return .dial(receiverIP: scoped, localIP: "")
    }

    /// The form a bridge address is remembered in: without its scope, and only
    /// a link-local one ("169.254.…", "fe80::…"); "" for anything else.
    nonisolated static func rememberable(_ receiverIP: String) -> String {
        let address = receiverIP.split(separator: "%").first.map(String.init) ?? ""
        if address.hasPrefix("169.254.") { return address }
        return TBConnectionDiagnostics.isIPv6LinkLocal(address) ? address : ""
    }

    // MARK: - State

    private static var triggeredAt: TimeInterval?
    private(set) static var triggerReason = ""
    static var lastDialAt: TimeInterval?
    /// The last redial was abandoned and the session still reads "Connecting…".
    static var leftSessionConnecting = false
    private static let addressesKey = "pwe.bridgeRedial.addresses"
    private static var store: SCDynamicStore?

    static func noteTrigger(_ reason: String) {
        triggeredAt = ProcessInfo.processInfo.systemUptime
        triggerReason = reason
        lastDialAt = nil
    }

    /// The session's receiver answered on the bridge at this address.
    static func remember(_ receiverIP: String, for identity: String) {
        let address = rememberable(receiverIP)
        guard !identity.isEmpty, !address.isEmpty else { return }
        var addresses = UserDefaults.standard.dictionary(forKey: addressesKey) as? [String: String] ?? [:]
        guard addresses[identity] != address else { return }
        addresses[identity] = address
        UserDefaults.standard.set(addresses, forKey: addressesKey)
    }

    static func rememberedAddress(for identity: String) -> String {
        guard !identity.isEmpty else { return "" }
        return (UserDefaults.standard.dictionary(forKey: addressesKey) as? [String: String])?[identity] ?? ""
    }

    static func decision(for session: TBDisplaySenderSession, service: TBDisplaySenderService) -> Decision {
        let now = ProcessInfo.processInfo.systemUptime
        let id = session.selectedReceiverID
        let interfaces = TBConnectionDiagnostics.currentIPv4Interfaces()
            .filter { $0.name.hasPrefix("bridge") && $0.ip.hasPrefix("169.254.") }
        let localIP = interfaces.first { $0.ip == session.localInterfaceIP }?.ip ?? interfaces.first?.ip ?? ""
        let remembered = rememberedAddress(for: id)
        let sinceTrigger = triggeredAt.map { now - $0 }
        // The retry loop asks every 250 ms and reading the settings-listed bridges
        // is not free: only inside a trigger window, for an IPv6 address.
        let mayDialIPv6 = TBConnectionDiagnostics.isIPv6LinkLocal(remembered)
            && sinceTrigger.map { $0 >= 0 && $0 < window } == true
        return decide(Inputs(
            transport: session.transportKind,
            sessionBusy: session.isConnected || session.isStreaming || session.pweSecurity.waitsForUser,
            sleeping: TBSystemSleepGate.isSleeping,
            listedWithBridgeAddress: !id.isEmpty && service.discoveredReceivers.contains {
                $0.matchesPersistedIdentity(id) && !$0.ip(for: .thunderboltBridge).isEmpty
            },
            rememberedAddress: remembered,
            localBridgeIP: localIP,
            secondsSinceTrigger: sinceTrigger,
            secondsSinceLastDial: lastDialAt.map { now - $0 },
            cableBridgesIPv6: mayDialIPv6 ? TBConnectionDiagnostics.currentCableBridgeIPv6Interfaces() : []))
    }

    static func isDue(for session: TBDisplaySenderSession, service: TBDisplaySenderService) -> Bool {
        decision(for: session, service: service) != .wait
    }

    // MARK: - Watching the links

    /// Watch System Configuration for a link coming up or an address
    /// appearing on any interface. A Thunderbolt Bridge member's link state
    /// changes the moment the cable is in; the bridge's own address may not
    /// change at all. A bridge's IPv6 address counts too: it is what an IPv6
    /// redial needs on this side.
    static func install() {
        guard store == nil else { return }
        var context = SCDynamicStoreContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        guard let store = SCDynamicStoreCreate(nil, "PWE bridge redial" as CFString, { store, changedKeys, _ in
            let keys = (changedKeys as? [String]) ?? []
            let up = keys.filter { key in
                guard let value = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any] else { return false }
                if key.hasSuffix("/Link") { return value["Active"] as? Bool == true }
                return key.contains("/bridge")  // .../bridgeN/IPv4 or IPv6 with an address
            }
            guard !up.isEmpty else { return }
            MainActor.assumeIsolated {
                TBBridgeRedial.noteTrigger("link up: " + up.map { $0.replacingOccurrences(of: "State:/Network/Interface/", with: "") }
                    .joined(separator: ", "))
            }
        }, &context) else {
            NSLog("[automation] cannot watch network links; redial only after a wake", level: .notice)
            return
        }
        let patterns = ["State:/Network/Interface/[^/]+/Link", "State:/Network/Interface/[^/]+/IPv4",
                        "State:/Network/Interface/[^/]+/IPv6"] as CFArray
        guard SCDynamicStoreSetNotificationKeys(store, nil, patterns),
              SCDynamicStoreSetDispatchQueue(store, .main) else {
            NSLog("[automation] cannot watch network links; redial only after a wake", level: .notice)
            return
        }
        self.store = store
    }
}
