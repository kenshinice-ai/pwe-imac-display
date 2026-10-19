import CoreGraphics
import Foundation

/// The decisions behind the iMac brightness keys, kept free of AppKit state so
/// they can be unit tested (PWEBrightnessRulesTests).
///
/// The step sizes and the Shift+Option fine mode follow monitorOS
/// (github.com/eriskhan/monitorOS, apps/helper-macos/Sources/MonitorOSHelper/
/// BrightnessControl.swift, MIT License, Copyright (c) 2026 Eriskhan Geshaev),
/// as do the key codes below. The code here is written anew, not copied.
enum PWEBrightnessRules {
    /// Virtual displays made by TargetBridge, and so by PWE iMac Display, carry
    /// this vendor ID (ReceiverBackedVirtualDisplaySession).
    static let virtualDisplayVendorID: UInt32 = 0xEEEE

    /// One press of F1/F2 moves a sixteenth; with Shift+Option, a sixty-fourth,
    /// as macOS does for its own displays.
    static let coarseSteps = 16
    static let fineSteps = 64

    // MARK: - Steps

    /// The level one key press leads to: the next mark on the 16 (or 64) step
    /// scale, never a fixed amount added to an in-between level. A level the
    /// slider left between two marks therefore lands on a mark, as macOS does.
    static func step(from level: Double, up: Bool, fine: Bool) -> Double {
        let steps = Double(fine ? fineSteps : coarseSteps)
        let position = clamp(level) * steps
        // Absorb floating point noise, so 0.75 counts as being on a mark.
        let tolerance = 1e-6
        let mark = up ? (position + tolerance).rounded(.down) + 1
                      : (position - tolerance).rounded(.up) - 1
        return clamp(mark / steps)
    }

    static func clamp(_ level: Double) -> Double {
        guard level.isFinite else { return 1 }
        return min(max(level, 0), 1)
    }

    // MARK: - Which display the keys belong to

    /// One display under the pointer, as CoreGraphics describes it.
    struct Display: Equatable {
        var id: CGDirectDisplayID
        var vendorID: UInt32
        var inMirrorSet: Bool
    }

    /// The display the keys should drive, or nil to leave them to macOS.
    ///
    /// It must be one of this app's own virtual displays (`ownDisplays`):
    /// TargetBridge itself makes 0xEEEE displays too, and those are not ours to
    /// drive. A mirrored display is left alone: the pointer is then on the
    /// Mac's own screen as well, and macOS keeps the keys for that screen.
    static func target(underPointer displays: [Display], ownDisplays: Set<CGDirectDisplayID>) -> CGDirectDisplayID? {
        displays.first {
            $0.vendorID == virtualDisplayVendorID && !$0.inMirrorSet && ownDisplays.contains($0.id)
        }?.id
    }

    // MARK: - Keys

    enum Key: Equatable {
        case down
        case up
    }

    /// NX_SYSDEFINED (14), subtype 8: the media keys of Apple keyboards and the
    /// Touch Bar. data1 carries the key in its high 16 bits and the state in
    /// bits 8–15 (0x0a down, 0x0b up).
    static let systemDefinedEventType: UInt32 = 14
    static let auxControlSubtype = 8
    static let auxBrightnessUp = 2
    static let auxBrightnessDown = 3

    /// kVK_F1 / kVK_F2: plain F1/F2 on other keyboards, or on Apple keyboards
    /// set to use them as standard function keys.
    static let functionKeyF1: Int64 = 122
    static let functionKeyF2: Int64 = 120
    /// The key codes recent macOS also sends for the brightness keys, as a
    /// second event next to the NX_SYSDEFINED one (seen by monitorOS on macOS 26).
    static let brightnessKeyDown: Int64 = 145
    static let brightnessKeyUp: Int64 = 144

    struct AuxKey: Equatable {
        var key: Key
        var isDown: Bool
        var isRepeat: Bool
    }

    /// Reads an NX_SYSDEFINED media key event. Nil for anything that is not a
    /// brightness key.
    static func auxKey(subtype: Int, data1: Int) -> AuxKey? {
        guard subtype == auxControlSubtype else { return nil }
        let code = (data1 & 0xffff_0000) >> 16
        let state = (data1 & 0x0000_ff00) >> 8
        let key: Key
        switch code {
        case auxBrightnessDown: key = .down
        case auxBrightnessUp: key = .up
        default: return nil
        }
        switch state {
        case 0x0a: return AuxKey(key: key, isDown: true, isRepeat: data1 & 0x1 != 0)
        case 0x0b: return AuxKey(key: key, isDown: false, isRepeat: false)
        default: return nil
        }
    }

    /// Reads a key code. Nil for anything that is not F1/F2 or a brightness key.
    static func key(keyCode: Int64) -> Key? {
        switch keyCode {
        case functionKeyF1, brightnessKeyDown: return .down
        case functionKeyF2, brightnessKeyUp: return .up
        default: return nil
        }
    }

    static func isFunctionKey(_ keyCode: Int64) -> Bool {
        keyCode == functionKeyF1 || keyCode == functionKeyF2
    }

    /// Whether the modifiers held leave the key to us, and at which step size.
    /// Command or Control means a shortcut, which stays with macOS and the app
    /// in front. Shift+Option together means the fine steps.
    static func modifiers(_ flags: CGEventFlags) -> (handled: Bool, fine: Bool) {
        if flags.contains(.maskCommand) || flags.contains(.maskControl) {
            return (false, false)
        }
        return (true, flags.contains(.maskShift) && flags.contains(.maskAlternate))
    }

    // MARK: - URL

    /// What `pweimacdisplay://brightness?…` asks for.
    enum Request: Equatable {
        /// `level=0…100`: set this level (0…1 here).
        case set(Double)
        /// `step=+1` / `step=-1` (any whole number): move that many key presses;
        /// `fine=1` for the 64 step scale.
        case step(Int, fine: Bool)
    }

    /// Parses the query of a brightness URL. `level` wins over `step`; anything
    /// unreadable is nil, so a malformed URL changes nothing.
    static func request(_ params: [String: String]) -> Request? {
        if let raw = params["level"] {
            // "+" may arrive decoded as a space by form-style encoders.
            guard let value = Double(raw.trimmingCharacters(in: .whitespaces)), value.isFinite else { return nil }
            return .set(clamp(value / 100))
        }
        if let raw = params["step"] {
            var text = raw.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("+") { text.removeFirst() }
            guard let count = Int(text), count != 0 else { return nil }
            // Far more presses than the scale has steps is a typo, not a request.
            guard abs(count) <= fineSteps else { return nil }
            return .step(count, fine: flag(params["fine"]))
        }
        return nil
    }

    static func level(after request: Request, from level: Double) -> Double {
        switch request {
        case .set(let value):
            return clamp(value)
        case .step(let count, let fine):
            var result = clamp(level)
            for _ in 0..<abs(count) {
                result = step(from: result, up: count > 0, fine: fine)
            }
            return result
        }
    }

    private static func flag(_ value: String?) -> Bool {
        switch value?.lowercased() {
        case "1", "true", "yes", "on": return true
        default: return false
        }
    }

    // MARK: - HUD

    /// How full each of the HUD's 16 segments is (0…1), so a fine step shows as
    /// a quarter segment the way the system's own HUD does.
    static func segments(for level: Double) -> [Double] {
        let filled = clamp(level) * Double(coarseSteps)
        return (0..<coarseSteps).map { min(max(filled - Double($0), 0), 1) }
    }
}
