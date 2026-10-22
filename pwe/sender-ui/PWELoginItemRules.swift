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
}
