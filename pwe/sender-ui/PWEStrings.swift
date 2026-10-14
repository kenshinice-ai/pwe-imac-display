import Foundation

/// The PWE window's words, in the person's language. Chinese and English are
/// written for this window; the other languages TargetBridge speaks fall back to
/// English here, while the advanced window keeps all five.
///
/// Rule for every line: the person's words, not the engine's. "Your iMac is not
/// showing your screen yet", never "HEVC path produced no frames".
struct PWEStrings {
    let zh: Bool

    init(language: TBDisplaySenderLanguage) { zh = language == .chinese }

    private func t(_ en: String, _ cn: String) -> String { zh ? cn : en }

    // Window
    var appName: String { "PWE iMac Display" }
    var advanced: String { t("Advanced…", "高级设置…") }
    var about: String { t("About", "关于") }

    // Permission
    var permissionTitle: String { t("Allow Screen Recording", "允许录屏") }
    var permissionBody: String {
        t("macOS asks once. PWE iMac Display records only the screen it shows on your iMac, and sends it nowhere else.",
          "macOS 只问一次。PWE iMac Display 只录制要显示在 iMac 上的画面，不发往其他任何地方。")
    }
    var permissionOpen: String { t("Open System Settings", "打开系统设置") }
    var permissionRestart: String { t("Reopen PWE iMac Display", "重新打开 PWE iMac Display") }
    var permissionRestartHint: String {
        t("If it still asks after you allowed it, reopen the app once.",
          "如果允许之后仍然提示，重新打开一次 App。")
    }

    // Searching
    var searchingTitle: String { t("Looking for your iMac", "正在找你的 iMac") }
    var searchingStep1: String { t("On the iMac, open PWE iMac Display Receiver.", "在 iMac 上打开「PWE iMac Display Receiver」。") }
    var searchingStep2: String { t("Connect the two Macs with a Thunderbolt cable.", "用雷雳线连接两台电脑。") }
    var searchingHint: String {
        t("Your iMac appears here by itself. A 2014 or 2015 iMac needs Apple's Thunderbolt 3 to Thunderbolt 2 Adapter.",
          "iMac 会自己出现在这里。2014、2015 款 iMac 需要 Apple 的雷雳 3 转雷雳 2 转换器。")
    }

    // Choose / ready
    var chooseTitle: String { t("Choose your iMac", "选择你的 iMac") }
    var readyTitle: String { t("Your iMac is connected by cable", "iMac 已经接上") }
    var useAsDisplay: String { t("Use as Display", "用作显示器") }
    var modeLabel: String { t("Show", "显示方式") }
    var modeExtended: String { t("Separate display", "独立的一块屏") }
    var modeMirror: String { t("Same as this Mac", "和这台 Mac 一样") }

    // Connecting
    func connectingTitle(_ name: String?) -> String {
        guard let name else { return t("Connecting", "正在连接") }
        return t("Connecting to \(name)", "正在连接 \(name)")
    }
    func stage(_ stage: PWEStage) -> String {
        switch stage {
        case .reaching: return t("Reaching the iMac", "正在连上 iMac")
        case .preparing: return t("Preparing the display", "正在准备显示器")
        case .waitingForPicture: return t("Waiting for the picture", "正在等待画面")
        }
    }
    var cancel: String { t("Cancel", "取消") }

    // Connected
    func connectedTitle(_ name: String?) -> String {
        guard let name else { return t("Your iMac is a display", "iMac 正在用作显示器") }
        return t("\(name) is a display", "\(name) 正在用作显示器")
    }
    var brightness: String { t("Brightness", "亮度") }
    var sound: String { t("Play sound on the iMac", "用 iMac 的扬声器播放声音") }
    var arrange: String { t("Arrange Displays…", "排列显示器…") }
    var disconnect: String { t("Disconnect", "断开") }

    // Interrupted
    func interruptedTitle(_ reason: PWEReason) -> String {
        switch reason {
        case .cableOrReceiverGone: return t("The iMac is no longer connected", "iMac 断开了")
        case .receiverQuit: return t("The receiver on the iMac was closed", "iMac 上的接收端关闭了")
        case .couldNotConnect: return t("Could not reach the iMac", "连不上 iMac")
        case .captureFailed: return t("The picture did not start", "画面没有出来")
        case .other: return t("The connection stopped", "连接停止了")
        }
    }
    func interruptedHint(_ reason: PWEReason) -> String {
        switch reason {
        case .cableOrReceiverGone: return t("Check the cable. It connects again when the iMac is back.", "检查一下线。iMac 回来后会自动重新连接。")
        case .receiverQuit: return t("Open PWE iMac Display Receiver on the iMac again.", "在 iMac 上重新打开接收端。")
        case .couldNotConnect: return t("Check that the receiver is open and the cable is in.", "确认 iMac 上的接收端开着、线插好了。")
        case .captureFailed: return t("Try again, or choose a lower quality in Advanced.", "再试一次，或在「高级设置」里降低画质。")
        case .other: return t("Try again.", "再试一次。")
        }
    }
    var retrying: String { t("Trying again…", "正在重试…") }
    var stopRetrying: String { t("Stop", "停止") }
    var tryAgain: String { t("Try Again", "重试") }

    // Preferences
    var autoConnect: String { t("Connect automatically when the cable goes in", "接上线就自动连接") }
    var launchAtLogin: String { t("Open at login", "登录时打开") }
    var launchAtLoginApproval: String { t("Allow in Login Items…", "在「登录项」里允许…") }

    // About
    var version: String { t("Version", "版本") }
    var credits: String {
        t("Based on TargetBridge by Marco Caciotti (swellweb) and its open-source community, MIT License. Built and signed by PWE Group.",
          "基于 TargetBridge（作者 Marco Caciotti，swellweb，及其开源社区，MIT 许可）。由 PWE Group 构建并签名。")
    }
    var source: String { t("Source Code", "源代码") }
    var support: String { t("Support PWE…", "支持 PWE…") }
    var checkUpdates: String { t("Check for Updates", "检查更新") }
    var checkUpdatesDaily: String { t("Check for updates once a day", "每天检查一次更新") }
    var upToDate: String { t("You have the latest version.", "已经是最新版本。") }
    var couldNotCheck: String { t("Could not check right now.", "暂时无法检查。") }
    func updateAvailable(_ version: String) -> String { t("Version \(version) is available.", "有新版本 \(version)。") }
    var download: String { t("Download", "下载") }
    var done: String { t("Done", "完成") }
}

/// What UpdateCheck asks to choose its notes' language. Its copies in the other PWE
/// apps ask their own L10n the same question.
enum L10n {
    static var isChinese: Bool { TBDisplaySenderLanguage.load() == .chinese }
}
