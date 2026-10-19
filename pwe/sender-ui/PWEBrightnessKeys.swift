import AppKit
import ApplicationServices
import SwiftUI

/// The iMac's brightness, from this Mac's keys and from other apps.
///
/// - Keys: while the pointer is on the iMac (this app's virtual display), F1/F2
///   and the brightness keys step the iMac's backlight in 16 steps, or 64 with
///   Shift+Option, and a brightness HUD shows on the iMac. Anywhere else the
///   keys go to macOS untouched. Seeing the keys takes Accessibility
///   permission; without it the keys simply stay with macOS.
/// - URL: `pweimacdisplay://brightness?level=0…100` sets the level and
///   `…?step=+1` / `step=-1` moves it like a key press (`&fine=1` for the 64
///   step scale; `&display=<CGDirectDisplayID>` picks one iMac, otherwise every
///   connected iMac follows). PWE Lumen Bar uses this for the virtual display.
///
/// Both end in the engine's own call, `TBDisplaySenderSession.brightness`, the
/// one the Advanced window's slider sets; the receiver turns it into the iMac's
/// backlight (TBReceiverC main.c, TB_PKT_BRIGHTNESS).
@MainActor
final class PWEBrightness: NSObject, ObservableObject {
    static let shared = PWEBrightness()

    enum KeysState: Equatable {
        /// The person turned the keys off, or never turned them on and the app
        /// has no Accessibility permission.
        case off
        /// Turned on, but the permission is missing: the keys stay with macOS.
        case needsPermission
        /// Turned on and permitted. The key watch itself runs only while an
        /// iMac is showing.
        case on
    }

    /// The person's choice; nil until they make one.
    static let defaultsKey = "pwe.brightnessKeys"

    @Published private(set) var accessibilityTrusted = AXIsProcessTrusted()
    @Published private var storedChoice: Bool? = UserDefaults.standard.object(forKey: PWEBrightness.defaultsKey) as? Bool

    /// On by default only when the permission is already there (for instance
    /// from keyboard and mouse sharing); otherwise off until turned on.
    var keysEnabled: Bool { storedChoice ?? accessibilityTrusted }

    var keysState: KeysState {
        guard keysEnabled else { return .off }
        return accessibilityTrusted ? .on : .needsPermission
    }

    /// True while the key watch is installed, which is only while an iMac shows.
    @Published private(set) var watchingKeys = false

    private let hud = PWEBrightnessHUD()
    private var started = false
    private var observers: [NSObjectProtocol] = []
    private var permissionPoll: Timer?
    // Mutated on the main actor; deinit only invalidates the CF resources.
    nonisolated(unsafe) private var tap: CFMachPort?
    nonisolated(unsafe) private var tapSource: CFRunLoopSource?
    /// Key codes whose key down was taken, so their key up is taken as well.
    private var takenKeyCodes = Set<Int64>()
    /// When the last NX_SYSDEFINED brightness key arrived (system uptime).
    private var lastAuxKeyUptime: TimeInterval = 0

    private var service: TBDisplaySenderService { .shared }

    // MARK: - Life cycle

    /// Starts watching for iMacs coming and going, and takes the app's URLs
    /// (`takeURLsQuietly`). Call once, at launch or after; calling it again
    /// does nothing.
    func start() {
        guard !started else { return }
        started = true
        let center = NotificationCenter.default
        // AppKit installs its own URL handler while launching. Installing ours
        // now covers a call after launch; installing it again when launching
        // ends covers a call from the App's init.
        takeURLsQuietly()
        observers.append(center.addObserver(forName: NSApplication.didFinishLaunchingNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.takeURLsQuietly() }
        })
        // The virtual display appears and disappears with each connection.
        // Looked at again a second later, in case the session records the new
        // display ID only after macOS announces the display.
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.update()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.update() }
            }
        })
        // Back from System Settings: the permission may have changed.
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        })
        update()
    }

    /// Removes the key watch. Call on quit.
    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        permissionPoll?.invalidate()
        permissionPoll = nil
        removeTap()
        hud.hide()
        started = false
    }

    /// The Settings switch. Turning it on without permission asks macOS for it
    /// (the system's own dialog) and starts waiting for the answer.
    func setKeysEnabled(_ enabled: Bool) {
        storedChoice = enabled
        UserDefaults.standard.set(enabled, forKey: Self.defaultsKey)
        if enabled && !AXIsProcessTrusted() {
            requestAccessibility()
        }
        update()
    }

    func requestAccessibility() {
        // The value of kAXTrustedCheckOptionPrompt, spelled out as upstream does:
        // Swift 6 rejects the global itself as shared mutable state.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        waitForPermission()
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        waitForPermission()
    }

    /// Checks the permission every second for up to three minutes, so the keys
    /// start the moment it is granted, without a relaunch.
    private func waitForPermission() {
        permissionPoll?.invalidate()
        let deadline = Date().addingTimeInterval(180)
        permissionPoll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.update()
                if self.accessibilityTrusted || Date() > deadline {
                    self.permissionPoll?.invalidate()
                    self.permissionPoll = nil
                }
            }
        }
    }

    /// Installs the key watch exactly when it is needed: turned on, permitted,
    /// and at least one iMac showing. No iMac, no key watch.
    private func update() {
        let trusted = AXIsProcessTrusted()
        if trusted != accessibilityTrusted { accessibilityTrusted = trusted }
        if started && keysState == .on && !ownDisplays().isEmpty {
            installTap()
        } else {
            removeTap()
        }
    }

    // MARK: - Displays

    /// The virtual displays this app's sessions are showing right now.
    private func ownDisplays() -> Set<CGDirectDisplayID> {
        Set(service.sessions.map(\.virtualDisplayID).filter { $0 != kCGNullDirectDisplay && CGDisplayIsOnline($0) != 0 })
    }

    private func session(for displayID: CGDirectDisplayID) -> TBDisplaySenderSession? {
        service.sessions.first { $0.virtualDisplayID == displayID }
    }

    /// The iMac under the pointer, or nil when the pointer is anywhere else.
    private func displayUnderPointer() -> CGDirectDisplayID? {
        guard let point = CGEvent(source: nil)?.location else { return nil }
        var ids = [CGDirectDisplayID](repeating: kCGNullDirectDisplay, count: 8)
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(point, UInt32(ids.count), &ids, &count) == .success else { return nil }
        let displays = ids.prefix(Int(count)).map {
            PWEBrightnessRules.Display(id: $0, vendorID: CGDisplayVendorNumber($0),
                                       inMirrorSet: CGDisplayIsInMirrorSet($0) != 0)
        }
        return PWEBrightnessRules.target(underPointer: displays, ownDisplays: ownDisplays())
    }

    // MARK: - Key watch

    private func installTap() {
        guard tap == nil else { return }
        let types: [UInt32] = [PWEBrightnessRules.systemDefinedEventType,
                               CGEventType.keyDown.rawValue, CGEventType.keyUp.rawValue]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                // The tap is serviced by the main run loop only.
                let take = MainActor.assumeIsolated {
                    Unmanaged<PWEBrightness>.fromOpaque(context).takeUnretainedValue().handle(type: type, event: event)
                }
                return take ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            NSLog("[pwe] brightness keys: no key watch (Accessibility permission missing?)")
            return
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return
        }
        self.tap = tap
        tapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        watchingKeys = true
        NSLog("[pwe] brightness keys: watching F1/F2 and the brightness keys")
    }

    private func removeTap() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        CFMachPortInvalidate(tap)
        self.tap = nil
        tapSource = nil
        takenKeyCodes.removeAll()
        watchingKeys = false
        NSLog("[pwe] brightness keys: stopped watching")
    }

    /// Decides, while macOS waits, whether a key is the iMac's. Returns true to
    /// take the event away from macOS. Must stay quick: the change itself runs
    /// after the event has been answered.
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }

        if type.rawValue == PWEBrightnessRules.systemDefinedEventType {
            guard let nsEvent = NSEvent(cgEvent: event),
                  let aux = PWEBrightnessRules.auxKey(subtype: Int(nsEvent.subtype.rawValue), data1: nsEvent.data1)
            else { return false }
            lastAuxKeyUptime = ProcessInfo.processInfo.systemUptime
            let modifiers = PWEBrightnessRules.modifiers(event.flags)
            guard modifiers.handled, let display = displayUnderPointer() else { return false }
            if aux.isDown {
                DispatchQueue.main.async { self.press(aux.key, fine: modifiers.fine, on: display) }
            }
            return true
        }

        guard type == .keyDown || type == .keyUp else { return false }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard let key = PWEBrightnessRules.key(keyCode: keyCode) else { return false }
        if type == .keyUp {
            return takenKeyCodes.remove(keyCode) != nil
        }
        let modifiers = PWEBrightnessRules.modifiers(event.flags)
        guard modifiers.handled, let display = displayUnderPointer() else { return false }
        takenKeyCodes.insert(keyCode)

        if PWEBrightnessRules.isFunctionKey(keyCode) {
            DispatchQueue.main.async { self.press(key, fine: modifiers.fine, on: display) }
            return true
        }
        // A brightness key code (144/145) usually comes with an NX_SYSDEFINED
        // twin that already did the work. Act on it only if no twin turns up.
        let pressed = ProcessInfo.processInfo.systemUptime
        if pressed - lastAuxKeyUptime < 0.5 { return true }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(60)) {
            guard self.lastAuxKeyUptime < pressed else { return }
            self.press(key, fine: modifiers.fine, on: display)
        }
        return true
    }

    private func press(_ key: PWEBrightnessRules.Key, fine: Bool, on display: CGDirectDisplayID) {
        guard let session = session(for: display) else { return }
        let level = PWEBrightnessRules.step(from: session.brightness, up: key == .up, fine: fine)
        if level != session.brightness { session.brightness = level }
        hud.show(level: level, on: display, label: PWEBrightnessStrings(language: service.language).hudLabel)
    }

    // MARK: - URL

    /// `pweimacdisplay://brightness?…`, reached through the engine's URL
    /// handling (`TBSenderAutomation`, after its scheme check; pwe/rebrand.py
    /// adds the `brightness` action there).
    func handleURL(_ params: [String: String]) {
        guard let request = PWEBrightnessRules.request(params) else {
            NSLog("[pwe] brightness URL: expected level=0…100 or step=+1/-1")
            return
        }
        let targets: [TBDisplaySenderSession]
        if let raw = params["display"] {
            guard let id = CGDirectDisplayID(raw), let session = session(for: id) else {
                NSLog("[pwe] brightness URL: no iMac on display \(raw)")
                return
            }
            targets = [session]
        } else {
            targets = service.sessions.filter { $0.isConnected || $0.isStreaming }
        }
        guard !targets.isEmpty else {
            NSLog("[pwe] brightness URL: no iMac connected")
            return
        }
        let label = PWEBrightnessStrings(language: service.language).hudLabel
        for session in targets {
            let level = PWEBrightnessRules.level(after: request, from: session.brightness)
            if level != session.brightness { session.brightness = level }
            // A step is a key press from another app, so it gets the key's HUD.
            // A level comes from a slider, which shows its own value.
            if case .step = request, session.virtualDisplayID != kCGNullDirectDisplay {
                hud.show(level: level, on: session.virtualDisplayID, label: label)
            }
        }
    }

    /// Takes `pweimacdisplay://` URLs straight from Apple events, in place of
    /// SwiftUI's handling. SwiftUI opens a new window for a URL when none is
    /// open (measured 2026-10-19 with a probe app on macOS 27.2: `open -g`
    /// with the window closed → one new window), which Lumen Bar's slider
    /// would do on every move. Every URL still goes through
    /// `TBSenderAutomation.handle(url:)` and its scheme check, as the windows'
    /// `.onOpenURL` do; only the window no longer comes up.
    private func takeURLsQuietly() {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleGetURL(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: text) else { return }
        TBSenderAutomation.handle(url: url)
    }

    deinit {
        if let tap { CFMachPortInvalidate(tap) }
    }
}

// MARK: - Words

/// This feature's words. Chinese and English, like the rest of the PWE window;
/// other languages fall back to English.
struct PWEBrightnessStrings {
    let zh: Bool

    init(language: TBDisplaySenderLanguage) { zh = language == .chinese }

    private func t(_ en: String, _ cn: String) -> String { zh ? cn : en }

    var toggle: String { t("Brightness keys adjust the iMac", "用亮度键调 iMac") }
    var detail: String {
        t("When the pointer is on the iMac, F1 and F2 (or the brightness keys) change the iMac's backlight. Hold Shift-Option for finer steps. Anywhere else, the keys work as usual.",
          "指针在 iMac 上时，F1、F2（或亮度键）调 iMac 的背光，按住 Shift-Option 可以细调。指针在别处时，按键照常。")
    }
    var why: String {
        t("To notice these keys, PWE iMac Display needs Accessibility permission. It looks only at F1, F2 and the brightness keys, and records nothing.",
          "要识别这些按键，PWE iMac Display 需要「辅助功能」权限。它只看 F1、F2 和亮度键，不记录任何按键。")
    }
    var needsPermission: String {
        t("Turn on PWE iMac Display in System Settings › Privacy & Security › Accessibility. Until then, the keys stay with this Mac.",
          "请在「系统设置 › 隐私与安全性 › 辅助功能」里打开 PWE iMac Display。在那之前，按键仍归这台 Mac。")
    }
    var openSettings: String { t("Open System Settings", "打开系统设置") }
    var hudLabel: String { t("iMac brightness", "iMac 亮度") }
}

// MARK: - Settings row

/// The switch for Settings, with its explanation and, when the permission is
/// missing, the way to grant it.
struct PWEBrightnessKeysSetting: View {
    @ObservedObject var brightness: PWEBrightness = .shared
    let language: TBDisplaySenderLanguage

    var body: some View {
        let strings = PWEBrightnessStrings(language: language)
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(get: { brightness.keysEnabled }, set: { brightness.setKeysEnabled($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(strings.toggle)
                    Text(strings.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if brightness.keysState != .on {
                Text(strings.why)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if brightness.keysState == .needsPermission {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .accessibilityHidden(true)
                    Text(strings.needsPermission)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button(strings.openSettings) { brightness.openAccessibilitySettings() }
                    .controlSize(.small)
            }
        }
    }
}
