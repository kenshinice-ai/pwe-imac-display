import Foundation

/// When Open at login may be registered (PWELoginItemRulesTests). Stricter than
/// the receiver's `tb_login_item.m` (which only refuses transient copies): the
/// sender accepts the two Applications folders only, so that a copy that will
/// still be there at the next login is also one Finder will show. A copy run from a disk image, an external volume or App
/// Translocation's read-only mount would leave login pointing at nothing, and
/// macOS would show a login item the person never sees open.
enum PWELoginItemRules {
    static func canRegister(bundlePath: String, home: String = NSHomeDirectory()) -> Bool {
        guard bundlePath.hasSuffix(".app") else { return false }
        if bundlePath.contains("/AppTranslocation/") { return false }
        if bundlePath.hasPrefix("/Volumes/") { return false }
        let homeApplications = (home as NSString).appendingPathComponent("Applications")
        return bundlePath.hasPrefix("/Applications/") || bundlePath.hasPrefix(homeApplications + "/")
    }

    /// What the Open at login switch shows (A7, 1.1.1). macOS keeps one login
    /// item per bundle ID, so a copy run from a disk image sees the status the
    /// installed copy registered: the switch shows that real status. The hint
    /// to move the app shows only while the switch is off, so "on" and "move
    /// the app to Applications" never stand together (RC8 W11.4). Turning it on
    /// needs a copy that can register; turning it off always works.
    struct Display: Equatable {
        var isOn: Bool
        var isEnabled: Bool
        var showsMoveHint: Bool
    }

    static func display(registered: Bool, canRegister: Bool) -> Display {
        Display(isOn: registered, isEnabled: registered || canRegister, showsMoveHint: !registered && !canRegister)
    }
}
