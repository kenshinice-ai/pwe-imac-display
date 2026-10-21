import Foundation

/// How an iMac is named and described in PWE's windows and menu. Pure functions,
/// so every rule has a test (PWEReceiverRulesTests).
enum PWEReceiverNaming {
    /// The receiver advertises "<app name> <host name>", e.g. "PWE Screen Encore
    /// LL-iMac-2017.local". A person calls that iMac "LL-iMac-2017".
    private static let appPrefixes = ["PWE Screen Encore Receiver ", "PWE Screen Encore "]
        + legacyAppNames.flatMap { ["\($0) Receiver ", "\($0) "] }
        + ["TargetBridge Receiver ", "TargetBridge "]
    /// What PWE receivers built before the 2026-10-20 rename advertise. Kept so
    /// that an iMac still running one is named and recognised the same way.
    static let legacyAppNames = ["PWE iMac Display"]

    static func friendlyName(receiverName: String, serviceName: String, hostName: String?) -> String {
        for candidate in [receiverName, serviceName, hostName ?? ""] {
            let name = stripped(candidate)
            if !name.isEmpty { return name }
        }
        return "iMac"
    }

    private static func stripped(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // The app's name alone names no iMac.
        if appPrefixes.contains(name + " ") { return "" }
        for prefix in appPrefixes where name.hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
            break
        }
        if name.hasSuffix(".") { name.removeLast() }
        if name.lowercased().hasSuffix(".local") { name = String(name.dropLast(".local".count)) }
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// PWE's receiver advertises its own name; upstream's says TargetBridge. Used
    /// only to word a message (update to 1.1, or the original receiver), never to trust.
    static func isPWE(receiverName: String, serviceName: String) -> Bool {
        (["PWE Screen Encore"] + legacyAppNames).contains { receiverName.hasPrefix($0) || serviceName.hasPrefix($0) }
    }

    /// The receiver's "iMac (5120x2880)" becomes "5120 × 2880": the panel always
    /// calls itself iMac, so the name adds nothing next to the iMac's own name.
    static func friendlyDetail(panelSummary: String) -> String {
        guard let size = panelSize(panelSummary) else { return panelSummary }
        return "\(size.width) × \(size.height)"
    }

    static func panelSize(_ panelSummary: String) -> (width: Int, height: Int)? {
        guard let match = panelSummary.firstMatch(of: #/(\d+)x(\d+)\)?$/#),
              let width = Int(match.1), let height = Int(match.2) else { return nil }
        return (width, height)
    }
}

/// The Picture a new iMac starts with, before anything has been remembered for it.
enum PWEPictureRules {
    /// 5K at 60 Hz on a 5K iMac that decodes HEVC in hardware: the 2017 iMac18,3
    /// (iMac18,3 baseline, 2026-10-19: decode at about 19 % of one core, and 60 Hz
    /// clearly smoother than 48 to Lee's eye). The 2014 and 2015 5K iMacs report
    /// no HEVC decode; their default stays what the engine already uses until
    /// they are measured, as do iMacs whose panel is not 5K.
    ///
    /// A 21.5-inch Retina 4K iMac (late 2015 iMac16,2, 2017 iMac18,2, 2019
    /// iMac19,2) starts at its own 4096 × 2304: the receiver reports its real
    /// panel, so the Mac's virtual display already matches it, and anything else
    /// is either scaled down on the iMac (5K) or stretched up (1440p). The engine
    /// picks HEVC or H.264 for it as for any preset. Not measured on such an iMac.
    static func defaultPicture(supportsHEVC: Bool, panelWidth: Int?, engineDefault: TBDisplayCapturePreset) -> TBDisplayCapturePreset {
        if isRetina4K(panelWidth) { return .retina4k60 }
        guard supportsHEVC, let panelWidth, panelWidth >= 5120 else { return engineDefault }
        return .native5k60Experimental
    }

    /// What the Picture menu offers for this iMac, best first. 5K choices on a
    /// 4K panel only cost encoding work the iMac then throws away.
    static func choices(panelWidth: Int?) -> [TBDisplayCapturePreset] {
        isRetina4K(panelWidth) ? [.retina4k60, .standard1440p] : [.native5k60Experimental, .native5k, .standard1440p]
    }

    /// 4096 wide, with room for a scaled or rounded report; never a 5K panel.
    static func isRetina4K(_ panelWidth: Int?) -> Bool {
        guard let panelWidth else { return false }
        return (3840...4608).contains(panelWidth)
    }
}
