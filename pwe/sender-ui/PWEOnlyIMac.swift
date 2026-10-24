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

/// Whether Screen Sharing and Remote Login are on, read without privileges:
/// when on, launchd listens for them on their ports (5900 and 22) for the
/// whole system, which `netstat -an` lists for any user. `launchctl print
/// system/…` answers an ordinary user "Could not find service" whether they
/// are on or not (measured 2026-10-24), so it cannot tell. nil when netstat
/// could not be read.
struct PWESharingState: Equatable {
    var screenSharing: Bool?
    var remoteLogin: Bool?

    static let screenSharingPort = 5900
    static let remoteLoginPort = 22

    static func from(netstat output: String?) -> PWESharingState {
        guard let output else { return PWESharingState() }
        let ports = listeningPorts(netstat: output)
        return PWESharingState(screenSharing: ports.contains(screenSharingPort),
                               remoteLogin: ports.contains(remoteLoginPort))
    }

    /// The local ports of the TCP sockets in LISTEN ("*.22", "127.0.0.1.631", "*.5900").
    static func listeningPorts(netstat output: String) -> Set<Int> {
        var ports = Set<Int>()
        for line in output.split(separator: "\n") {
            let columns = line.split(whereSeparator: \.isWhitespace)
            guard columns.count >= 6, columns.last == "LISTEN", columns[0].hasPrefix("tcp"),
                  let dot = columns[3].lastIndex(of: "."), let port = Int(columns[3][columns[3].index(after: dot)...])
            else { continue }
            ports.insert(port)
        }
        return ports
    }

    /// Runs `netstat -an -p tcp`; call it off the main thread.
    static func read() -> PWESharingState {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
        process.arguments = ["-an", "-p", "tcp"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return PWESharingState()
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return PWESharingState() }
        return from(netstat: String(decoding: data, as: UTF8.self))
    }
}
