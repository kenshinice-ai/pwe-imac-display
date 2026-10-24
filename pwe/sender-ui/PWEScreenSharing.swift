import AppKit
import CoreGraphics

/// A14 (T50): the Screen Sharing app showing the iMac that is this Mac's
/// display. The iMac then shows this Mac's desktop with the Screen Sharing
/// window in it, which shows the iMac again: the picture repeats itself
/// (Lee, 2026-10-24). It is a picture loop, not a fault; the window says how
/// to end it.
///
/// Rules here are pure (PWEScreenSharingTests); the watch below reads window
/// names with CGWindowListCopyWindowInfo, which Screen Recording (already
/// granted to stream) permits, at most every 5 s, only while connected and
/// only while Screen Sharing runs.
enum PWEScreenSharingRules {
    static let bundleID = "com.apple.ScreenSharing"

    /// A window of Screen Sharing names this iMac. A name must be the whole
    /// of the title's name part (what comes before a bracketed note such as
    /// "(Observe)" or a dash separator); case, ".local", hyphens and
    /// underscores do not count, so "LL-iMac-2017.local" and "LL iMac 2017" are
    /// one name, while "iMac" is not "Office iMac". An address must be a whole
    /// word of the title: "10.0.0.5" is not "10.0.0.51".
    static func isViewing(windowTitles: [String], names: [String]) -> Bool {
        let cores = Set(windowTitles.map(namePart).filter { !$0.isEmpty })
        let words = Set(windowTitles.flatMap(self.words))
        return names.contains { name in
            if isAddress(name) { return words.contains(name.lowercased()) }
            let wanted = normalized(name)
            return wanted.count >= 3 && cores.contains(wanted)
        }
    }

    /// The title before a bracketed note or a dash separator, normalised.
    static func namePart(_ title: String) -> String {
        var part = title
        for marker in ["(", "[", " — ", " – "] {
            if let range = part.range(of: marker) { part = String(part[..<range.lowerBound]) }
        }
        return normalized(part)
    }

    static func words(_ title: String) -> [String] {
        title.lowercased()
            .split(whereSeparator: { $0.isWhitespace || "()[],;".contains($0) })
            .map(String.init)
    }

    /// An IPv4 or IPv6 address, as the receiver announces its addresses.
    static func isAddress(_ text: String) -> Bool {
        if text.contains(":") { return true }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    static func normalized(_ text: String) -> String {
        var value = text.lowercased()
        if value.hasSuffix(".") { value.removeLast() }
        value = value.replacingOccurrences(of: ".local", with: "")
        value = value.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        return value.split(separator: " ").joined(separator: " ")
    }

    /// What the iMac goes by: the window's name for it, what it announces,
    /// its host name and its addresses.
    static func names(for receiver: TBDiscoveredReceiver, friendlyName: String, pairedName: String?) -> [String] {
        var names = [friendlyName, receiver.hostName ?? "", pairedName ?? ""]
        names += [receiver.preferredIP, receiver.thunderboltIP, receiver.networkIP, receiver.ethernetIP, receiver.wifiIP]
        names += receiver.resolvedIPv4Addresses
        return names.filter { !$0.isEmpty }
    }
}

/// Watches for Screen Sharing showing the iMac while it is a display.
@MainActor
final class PWEScreenSharingWatch {
    private let onChange: (Bool) -> Void
    private var names: [String] = []
    private var active = false
    private var screenSharingPIDs = Set<pid_t>()
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private(set) var viewing = false

    init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.bundleIdentifier == PWEScreenSharingRules.bundleID else { return }
                let launched = note.name == NSWorkspace.didLaunchApplicationNotification
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if launched { self.screenSharingPIDs.insert(app.processIdentifier) } else {
                        self.screenSharingPIDs.remove(app.processIdentifier)
                    }
                    self.reschedule()
                }
            })
        }
    }

    /// While connected, with the names the iMac goes by; nil names stop the watch.
    func update(names: [String]?) {
        let wasActive = active
        active = names != nil
        self.names = names ?? []
        if active, !wasActive {
            screenSharingPIDs = Set(NSRunningApplication.runningApplications(withBundleIdentifier: PWEScreenSharingRules.bundleID)
                .map(\.processIdentifier))
        }
        if active != wasActive { reschedule() }
    }

    private func reschedule() {
        let watching = active && !screenSharingPIDs.isEmpty
        if watching, timer == nil {
            let timer = Timer(timeInterval: PWEPollRules.interval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.check() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            check()
        } else if !watching {
            timer?.invalidate()
            timer = nil
            set(false)
        }
    }

    private func check() {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return }
        let titles = info.compactMap { window -> String? in
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t, screenSharingPIDs.contains(pid) else { return nil }
            return window[kCGWindowName as String] as? String
        }
        set(PWEScreenSharingRules.isViewing(windowTitles: titles, names: names))
    }

    private func set(_ value: Bool) {
        guard value != viewing else { return }
        viewing = value
        PWELog.note("[pwe] Screen Sharing \(value ? "is showing" : "no longer shows") the iMac in use as a display")
        onChange(value)
    }
}
