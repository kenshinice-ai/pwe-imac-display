import Foundation

/// A2 (1.1.1): Settings › General's "Use only the iMac" list. Done once while
/// this Mac still has a screen (a borrowed one, say), so that afterwards the
/// iMac is all it needs: screen recording allowed, the app opening at login
/// and connecting when the cable goes in, the iMac's keyboard and mouse in
/// control, and, for getting in from elsewhere, Screen Sharing and Remote
/// Login. Each row only reads; its button flips PWE's own setting or opens the
/// System Settings pane. The app never turns on Screen Sharing or Remote Login
/// itself: they need an administrator and are the person's choice.
/// No engine and no clock here (PWEOnlyIMacTests).
enum PWEOnlyIMacRules {
    enum Row: String, CaseIterable, Identifiable {
        case screenRecording, openAtLogin, autoConnect, keyboardMouse, screenSharing, remoteLogin
        var id: String { rawValue }
    }

    enum State: Equatable {
        case done
        /// PWE's own setting, off: the button turns it on.
        case turnOn
        /// Off in System Settings: the button opens the pane.
        case openSettings
        /// Open at login from a copy outside Applications (PWELoginItemRules).
        case moveToApplications
        /// Could not be read: the button opens the pane to look.
        case check
    }

    struct Inputs: Equatable {
        var screenRecording: Bool
        var launchAtLogin: Bool
        var launchAtLoginNeedsApproval: Bool
        var canRegisterLogin: Bool
        var autoConnect: Bool
        var inputRole: PWEInputRole
        /// nil: not known (PWESharingState).
        var screenSharing: Bool?
        var remoteLogin: Bool?
    }

    static func state(_ row: Row, _ inputs: Inputs) -> State {
        switch row {
        case .screenRecording:
            return inputs.screenRecording ? .done : .openSettings
        case .openAtLogin:
            if inputs.launchAtLogin { return .done }
            if inputs.launchAtLoginNeedsApproval { return .openSettings }
            return inputs.canRegisterLogin ? .turnOn : .moveToApplications
        case .autoConnect:
            return inputs.autoConnect ? .done : .turnOn
        case .keyboardMouse:
            return inputs.inputRole == .iMacControlsMac ? .done : .turnOn
        case .screenSharing:
            return systemState(inputs.screenSharing)
        case .remoteLogin:
            return systemState(inputs.remoteLogin)
        }
    }

    private static func systemState(_ on: Bool?) -> State {
        guard let on else { return .check }
        return on ? .done : .openSettings
    }
}

/// Whether Screen Sharing and Remote Login are on, read without privileges
/// (K3, audit A3: a port in LISTEN alone is weak evidence). Two readings:
///
/// - launchd's on/off list for the system services (`launchctl print-disabled
///   system`, readable by any user; measured on macOS 27.2, 2026-10-28, other
///   versions not verified): `"com.apple.screensharing" => enabled` or
///   `disabled`, likewise `com.openssh.sshd`; older systems wrote true for
///   disabled. A service missing from the list is in its default state, which
///   for both is off.
/// - who listens on its port (`netstat -an`): only a listener on an address
///   other than loopback (127.x, ::1, lo0) can be reached from elsewhere.
///
/// "On" needs both: the service enabled and listening beyond this Mac.
/// Not listening beyond this Mac and not enabled is "off". Anything else (enabled but
/// not listening, a listener with the service not on the list, a reading that
/// failed) is nil: the row says "Check in System Settings…".
struct PWESharingState: Equatable {
    var screenSharing: Bool?
    var remoteLogin: Bool?

    static let screenSharingPort = 5900
    static let remoteLoginPort = 22
    static let screenSharingLabel = "com.apple.screensharing"
    static let remoteLoginLabel = "com.openssh.sshd"

    static func from(netstat: String?, printDisabled: String?) -> PWESharingState {
        guard let netstat else { return PWESharingState() }
        let external = externallyListeningPorts(netstat: netstat)
        let overrides = printDisabled.map(launchdOverrides) ?? [:]
        func state(_ label: String, _ port: Int) -> Bool? {
            serviceState(enabled: overrides[label], listensBeyondThisMac: external.contains(port))
        }
        return PWESharingState(screenSharing: state(screenSharingLabel, screenSharingPort),
                               remoteLogin: state(remoteLoginLabel, remoteLoginPort))
    }

    /// `enabled`: launchd's entry; nil when the service is not on its list
    /// or the list could not be read.
    static func serviceState(enabled: Bool?, listensBeyondThisMac: Bool) -> Bool? {
        // Disabled, yet something listens on its port beyond this Mac: the
        // readings disagree, so neither on nor off (review 2026-10-28).
        if enabled == false { return listensBeyondThisMac ? nil : false }
        if enabled == true { return listensBeyondThisMac ? true : nil }
        // Not on the list: nothing reachable is off; a listener alone proves nothing.
        return listensBeyondThisMac ? nil : false
    }

    /// `"label" => enabled|disabled` (or true for disabled, false for enabled).
    static func launchdOverrides(_ output: String) -> [String: Bool] {
        var result: [String: Bool] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "=>", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, parts[0].hasPrefix("\""), parts[0].hasSuffix("\""), parts[0].count > 2 else { continue }
            let label = String(parts[0].dropFirst().dropLast())
            switch parts[1] {
            case "enabled", "false": result[label] = true
            case "disabled", "true": result[label] = false
            default: continue
            }
        }
        return result
    }

    /// The ports of TCP sockets in LISTEN on an address other than loopback
    /// ("*.22", "192.168.1.5.5900", "*.5900" yes; "127.0.0.1.22", "::1.22",
    /// "fe80::1%lo0.22" no).
    static func externallyListeningPorts(netstat output: String) -> Set<Int> {
        var ports = Set<Int>()
        for line in output.split(separator: "\n") {
            let columns = line.split(whereSeparator: \.isWhitespace)
            guard columns.count >= 6, columns.last == "LISTEN", columns[0].hasPrefix("tcp"),
                  let dot = columns[3].lastIndex(of: "."), let port = Int(columns[3][columns[3].index(after: dot)...])
            else { continue }
            let address = String(columns[3][..<dot])
            if address.hasPrefix("127.") || address == "::1" || address.hasSuffix("%lo0") || address == "localhost" { continue }
            ports.insert(port)
        }
        return ports
    }

    /// Runs `netstat -an` and `launchctl print-disabled system`; call it off
    /// the main thread.
    static func read() -> PWESharingState {
        from(netstat: run("/usr/sbin/netstat", ["-an"]), printDisabled: run("/bin/launchctl", ["print-disabled", "system"]))
    }

    private static func run(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
