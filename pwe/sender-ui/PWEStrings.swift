import Foundation

/// PWE's words, in the language macOS gives this app (System Settings › General ›
/// Language & Region › Applications). Chinese and English are written for PWE's
/// window, menu and settings; the other languages TargetBridge speaks fall back to
/// English here, while the full console keeps all five.
///
/// Rule for every line: the person's words, not the engine's. "Your iMac is not
/// showing your screen yet", never "HEVC path produced no frames".
struct PWEStrings {
    let zh: Bool

    init(language: TBDisplaySenderLanguage) { zh = language == .chinese }

    /// For views that bring their own words (PWEBrightnessKeysSetting).
    var language: TBDisplaySenderLanguage { zh ? .chinese : .english }

    /// The language macOS gives this app. There is no language choice inside PWE.
    static func systemLanguage(_ preferred: [String] = Locale.preferredLanguages) -> TBDisplaySenderLanguage {
        for code in preferred {
            if code.hasPrefix("zh") { return .chinese }
            if code.hasPrefix("it") { return .italian }
            if code.hasPrefix("de") { return .german }
            if code.hasPrefix("fr") { return .french }
            if code.hasPrefix("en") { return .english }
        }
        return .english
    }

    private func t(_ en: String, _ cn: String) -> String { zh ? cn : en }

    // Window
    var appName: String { "PWE Screen Encore" }
    /// The full TargetBridge console's window title.
    var consoleTitle: String { t("Full Console", "完整控制台") }
    var about: String { t("About", "关于") }
    var aboutApp: String { t("About PWE Screen Encore", "关于 PWE Screen Encore") }

    // Permission
    var permissionTitle: String { t("Allow Screen Recording", "允许录屏") }
    var permissionBody: String {
        t("To show this Mac's screen on your iMac, PWE Screen Encore needs your permission. It records only the screen it shows on your iMac, and sends it nowhere else.",
          "要把这台 Mac 的画面显示到 iMac 上，PWE Screen Encore 需要你的允许。它只录制要显示在 iMac 上的画面，不发往其他任何地方。")
    }
    var permissionOpen: String { t("Open System Settings", "打开系统设置") }
    var permissionRestart: String { t("Reopen PWE Screen Encore", "重新打开 PWE Screen Encore") }
    var permissionRestartHint: String {
        t("If it still asks after you allowed it, reopen the app once.",
          "如果允许之后仍然提示，重新打开一次 App。")
    }

    // Searching
    var searchingTitle: String { t("Looking for your iMac", "正在找你的 iMac") }
    var searchingStep1: String { t("On the iMac, open PWE Screen Encore Receiver.", "在 iMac 上打开「PWE Screen Encore Receiver」。") }
    var searchingStep2: String { t("Connect the two Macs with a Thunderbolt cable.", "用雷雳线连接两台电脑。") }
    var searchingHint: String {
        t("Your iMac appears here by itself. A 2014 or 2015 iMac needs Apple's Thunderbolt 3 to Thunderbolt 2 Adapter.",
          "iMac 会自己出现在这里。2014、2015 款 iMac 需要 Apple 的雷雳 3 转雷雳 2 转换器。")
    }

    // Choose / ready
    var chooseTitle: String { t("Choose your iMac", "选择你的 iMac") }
    var useAsDisplay: String { t("Use as Display", "用作显示器") }
    /// macOS's own words for the two ways a display joins (Extend / Mirror).
    func modeName(_ mode: PWEDisplayMode) -> String {
        switch mode {
        case .extended: return t("Extend Display", "扩展显示")
        case .mirror: return t("Mirror Display", "镜像显示")
        }
    }
    var picture: String { t("Picture", "画面") }
    func pictureName(_ preset: TBDisplayCapturePreset) -> String {
        switch preset {
        case .standard1440p: return t("Standard · 1440p", "标准 · 1440p")
        case .native5k: return t("5K · 48 Hz", "5K · 48 Hz")
        case .native5k60Experimental: return t("5K · 60 Hz", "5K · 60 Hz")
        default: return "\(preset.title) · \(preset.description)"
        }
    }

    // Connecting
    func connectingTitle(_ name: String?) -> String {
        guard let name else { return t("Connecting", "正在连接") }
        return t("Connecting to \(name)", "正在连接 \(name)")
    }
    func stage(_ stage: PWEStage) -> String {
        switch stage {
        case .reaching: return t("Reaching the iMac", "正在连接 iMac")
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
    var sound: String { t("Sound", "声音") }
    func soundName(_ sound: PWESound) -> String {
        switch sound {
        case .onlyIMac: return t("Only on the iMac", "只在 iMac 播放")
        case .both: return t("On both", "两边都播放")
        case .onlyThisMac: return t("Only on this Mac", "只在这台 Mac 播放")
        }
    }
    var arrange: String { t("Arrange Displays…", "排列显示器…") }
    var disconnect: String { t("Disconnect", "断开") }

    // Interrupted
    func interruptedTitle(_ reason: PWEReason) -> String {
        switch reason {
        case .cableOrReceiverGone: return t("The iMac is no longer connected", "iMac 断开了")
        case .receiverQuit: return t("The receiver on the iMac was closed", "iMac 上的接收端关闭了")
        case .couldNotConnect: return t("Could not reach the iMac", "连不上 iMac")
        case .captureFailed: return t("The picture did not start", "画面没有出来")
        }
    }
    func interruptedHint(_ reason: PWEReason, retrying: Bool, overNetwork: Bool = false) -> String {
        switch reason {
        case .cableOrReceiverGone:
            return retrying
                ? t("Check the cable. It connects again when the iMac is back.", "检查一下线。iMac 回来后会自动重新连接。")
                : t("Check the cable. When the iMac is back, choose Try Again.", "检查一下线。iMac 回来后，点「重试」。")
        case .receiverQuit:
            return t("Open PWE Screen Encore Receiver on the iMac again.", "在 iMac 上重新打开「PWE Screen Encore Receiver」。")
        case .couldNotConnect where overNetwork:
            // The cable hint would be wrong here: a network connection also needs the
            // receiver to allow it (local-network mode, see the install guide).
            return t("Over a network, the receiver on the iMac must allow network connections first. See the install guide.",
                     "经网络连接时，要先在 iMac 的接收端打开局域网模式，步骤见安装指南。")
        case .couldNotConnect:
            return t("Check that PWE Screen Encore Receiver is open on the iMac and the cable is in.",
                     "确认 iMac 上的「PWE Screen Encore Receiver」开着、线插好了。")
        case .captureFailed:
            return t("Try again, or choose Standard under Picture in the menu bar.", "再试一次，或在菜单栏的「画面」里选「标准」。")
        }
    }
    var retrying: String { t("Trying again…", "正在重试…") }
    var stopRetrying: String { t("Stop", "停止") }
    var tryAgain: String { t("Try Again", "重试") }

    // First connection: the one line that says where the everyday controls are.
    /// The words either side of the menu bar icon, drawn inline.
    var menuBarTip: (before: String, after: String) {
        zh ? ("以后在菜单栏的 ", " 里调亮度、画面和声音。")
           : ("From now on, brightness, picture and sound are under ", " in the menu bar.")
    }
    var menuBarTipSpoken: String {
        t("From now on, brightness, picture and sound are under the PWE Screen Encore icon in the menu bar.",
          "以后在菜单栏的 PWE Screen Encore 图标里调亮度、画面和声音。")
    }

    // Preferences
    var autoConnect: String { t("Connect automatically when the cable goes in", "接上线就自动连接") }
    var launchAtLogin: String { t("Open at login", "登录时打开") }
    var launchAtLoginApproval: String { t("Allow in Login Items…", "在「登录项」里允许…") }

    // Menu bar
    func menuConnectTo(_ name: String) -> String { t("Use \(name) as Display", "把 \(name) 用作显示器") }
    var settingsMenu: String { t("Settings…", "设置…") }
    var quit: String { t("Quit PWE Screen Encore", "退出 PWE Screen Encore") }
    func status(_ phase: PWEPhase) -> String {
        switch phase {
        case .needsPermission: return t("Needs Screen Recording permission", "需要录屏权限")
        case .searching: return t("Looking for your iMac…", "正在找你的 iMac…")
        case .choose: return t("Choose an iMac in the window", "请在窗口里选择 iMac")
        case .ready(let receiver): return t("\(receiver.name) is ready", "\(receiver.name) 已就绪")
        case .connecting(let receiver, _): return connectingTitle(receiver?.name) + "…"
        case .connected(let receiver): return connectedTitle(receiver?.name)
        case .interrupted(_, let reason, let retrying):
            return retrying ? interruptedTitle(reason) + " · " + t("trying again", "正在重试") : interruptedTitle(reason)
        case .security(_, let security):
            switch security {
            case .needsCode, .wrongCode, .codeExpired: return waitingForCode
            case .checkingCode: return codeChecking
            case .locked: return codeLockedStatus
            default: return needsAnswer
            }
        }
    }

    // Pairing and encryption. Text from docs/pwe/DESIGN-pairing-2026-10-19.md §3.2
    // where it has one; the lines marked DRAFT wait for Lee (listed in the hand-over note).
    var codeTitle: String { t("Enter the code shown on your iMac", "输入 iMac 上的配对码") }
    var codeBody: String {
        t("Your iMac is showing a 6-digit code. Enter it once, and this Mac will connect automatically from now on.",
          "iMac 屏幕上显示了 6 位数字。输入一次，以后插线就会自动连接。")
    }
    var codeIdentityChanged: String {
        t("This iMac’s identity has changed — it may have been reinstalled. Enter its pairing code again.",
          "这台 iMac 的身份变了，可能重装过。请重新输入配对码。")
    }
    var codeWrong: String {
        t("That code didn’t match. Your iMac is showing a new one.", "配对码不对。iMac 上已换了新码，请重新输入。")
    }
    var codeExpired: String {
        t("The code expired. Your iMac is showing a new one.", "配对码已过期。iMac 上已换了新码，请重新输入。")
    }
    /// While the Mac asks the iMac for a new code (a moment): why, then what is happening.
    var codeWrongShort: String { t("That code didn’t match.", "配对码不对。") }
    var codeExpiredShort: String { t("The code expired.", "配对码已过期。") }
    var codeRequesting: String { t("Asking your iMac for a new code…", "正在向 iMac 要新的配对码…") }
    /// Five wrong codes lock pairing on the iMac for a minute; this counts down.
    func codeLocked(seconds: Int) -> String {
        zh ? "输错太多次。请 \(seconds) 秒后再试。"
           : "Too many wrong codes. Try again in \(seconds) \(seconds == 1 ? "second" : "seconds")."
    }
    var codeLockedNext: String {
        t("Then this Mac asks your iMac for a new code.", "到时这台 Mac 会自动向 iMac 要新码。")
    }
    var codeLockedStatus: String { t("Too many wrong codes", "配对码输错太多次") }   // menu status
    /// DRAFT
    var codeChecking: String { t("Checking the code…", "正在核对配对码…") }
    var codePlaceholder: String { t("6 digits", "6 位数字") }
    var pair: String { t("Pair", "配对") }
    var legacyTitle: String { t("Connect without encryption?", "不加密连接？") }   // DRAFT (title only)
    var legacyOriginal: String {
        t("This iMac runs the original TargetBridge receiver. The connection won’t be encrypted or verified. Connect anyway?",
          "这台 iMac 运行的是 TargetBridge 原版接收端。连接不会加密，也无法确认对方身份。仍然连接？")
    }
    var connectAnyway: String { t("Connect Anyway", "仍然连接") }
    /// §3.4 gives the Chinese only; the English is a DRAFT.
    var legacyOlderPWE: String { t("Update the receiver on your iMac to 1.1", "请把 iMac 上的接收端更新到 1.1") }
    var connectAnywayUnencrypted: String { t("Connect Anyway (Unencrypted)", "仍然连接（不加密）") }
    /// DRAFT
    var legacyPreviouslyPaired: String {
        t("This iMac was paired for encrypted connections but now offers only an unencrypted one. Update the receiver on your iMac to 1.1 first.",
          "这台 iMac 配对过加密连接，现在却只提供不加密连接。请先把 iMac 上的接收端更新到 1.1。")
    }
    var forgetThisIMac: String { t("Forget This iMac", "忘记这台 iMac") }   // DRAFT
    var refusedTitle: String { t("Could not connect securely", "无法安全连接") }   // DRAFT
    /// DRAFT (protocolError has no text in the design or the engine's note)
    func refused(_ reason: PWESecurityRefusal) -> String {
        switch reason {
        case .notOnCable:
            return t("Pairing needs the Thunderbolt cable the first time. Plug it in and try again.",
                     "第一次配对需要用雷雳线连接。插上线再试。")
        case .receiverKeychain:
            return t("Your iMac can’t read its keychain (it may be locked), so the connection can’t be encrypted. Log in on the iMac and try again.",
                     "iMac 读不到它的钥匙串（可能已锁定），无法加密连接。请在 iMac 上登录后再试。")
        case .senderKeychain:
            return t("This Mac can’t read its keychain, so the connection can’t be encrypted.", "这台 Mac 读不到钥匙串，无法加密连接。")
        case .version:
            return t("The receiver on your iMac is a different version. Update both to the same version.",
                     "iMac 上的接收端版本不同。请把两台都更新到同一版本。")
        case .protocolError:
            return t("The connection to your iMac failed a security check. Try again.", "与 iMac 的连接没通过安全检查。请重试。")
        case .cancelled:
            return t("Pairing was cancelled.", "配对已取消。")
        case .unencryptedNotAllowed:
            return t("This iMac can only connect without encryption, and unencrypted connections are turned off.",
                     "这台 iMac 只能不加密连接，而你已关闭不加密连接。")
        }
    }
    /// DRAFT
    var unencryptedBanner: String {
        t("Not encrypted: picture and sound only. Keyboard, mouse and clipboard are off.",
          "未加密：只传画面和声音，键鼠和剪贴板已关闭。")
    }
    /// DRAFT
    var turnOffUnencrypted: String { t("Turn Off Unencrypted Connections", "关闭不加密连接") }
    var notEncrypted: String { t("Not encrypted", "未加密") }   // DRAFT (menu status)
    var waitingForCode: String { t("Waiting for the pairing code", "等待输入配对码") }   // DRAFT (menu status)
    var needsAnswer: String { t("Waiting for your answer in the window", "请在窗口里回答") }   // DRAFT (menu status)
    // Settings › Advanced
    var allowUnencrypted: String { t("Allow unencrypted connections", "允许不加密的连接") }   // DRAFT
    var allowUnencryptedHint: String {
        t("For iMacs that run the original TargetBridge or a 1.0 receiver: picture and sound only, always with a warning.",
          "用于运行 TargetBridge 原版或 1.0 版接收端的 iMac：只传画面和声音，并始终提示未加密。")
    }   // DRAFT
    var pairedIMacs: String { t("Paired iMacs", "已配对的 iMac") }
    var noPairedIMacs: String { t("None yet. An iMac is paired the first time you enter its code.", "还没有。第一次输入 iMac 的配对码时就会配对。") }   // DRAFT
    func pairedOn(_ date: Date) -> String {
        let formatted = date.formatted(date: .abbreviated, time: .omitted)
        return t("Paired \(formatted)", "\(formatted) 配对")
    }   // DRAFT
    var forget: String { t("Forget", "忘记") }
    /// DRAFT
    func forgetConfirm(_ name: String) -> String {
        t("Forget “\(name)”? You’ll enter its pairing code again next time.", "忘记“\(name)”？下次连接要重新输入配对码。")
    }
    /// DRAFT (D3)
    var inputNeedsEncryption: String {
        t("Works only on an encrypted connection.", "只在加密连接中可用。")
    }

    // Settings
    var general: String { t("General", "通用") }
    var keyboardMouse: String { t("Keyboard & Mouse", "键盘与鼠标") }
    var advancedTab: String { t("Advanced", "高级") }
    var reconnectNotice: String { t("Reconnecting to apply the change…", "正在重新连接以应用更改…") }
    var largeCursor: String { t("Larger pointer on the iMac", "iMac 上使用大指针") }
    var changesReconnect: String { t("Changes reconnect for a moment.", "更改后会重新连接一下。") }
    var iMacRendering: String { t("iMac rendering", "iMac 上的渲染方式") }
    func renderingName(_ rendering: PWERendering) -> String {
        switch rendering {
        case .openGL: return t("Lowest latency (OpenGL)", "低延迟（OpenGL）")
        case .metal: return t("Lower power (Metal)", "省电（Metal）")
        }
    }
    var iMacVolume: String { t("iMac volume", "iMac 音量") }
    var experimental: String { t("Experimental", "实验性") }
    var inputTitle: String { t("Share keyboard and mouse", "共享键盘和鼠标") }
    func inputRoleName(_ role: PWEInputRole) -> String {
        switch role {
        case .off: return t("Off", "关")
        case .macControlsIMac: return t("Control the iMac from this Mac", "用这台 Mac 控制 iMac")
        case .iMacControlsMac: return t("Control this Mac from the iMac", "用 iMac 控制这台 Mac")
        }
    }
    var inputHint: String {
        t("Applies while the iMac is a display. Press Control-Option-Command-K to stop controlling at once.",
          "iMac 用作显示器时生效。按 Control-Option-Command-K 可立即停止控制。")
    }
    func permissionMissing(_ setting: String) -> String { t("\(setting) is not allowed", "未允许「\(setting)」") }
    var onThisMac: String { t("On this Mac", "在这台 Mac 上") }
    var inputMonitoring: String { t("Input Monitoring", "输入监控") }
    var accessibility: String { t("Accessibility", "辅助功能") }
    var open: String { t("Open…", "打开…") }
    func iMacPermissionHint(_ setting: String) -> String {
        t("On the iMac: System Settings › Privacy & Security › \(setting) › PWE Screen Encore Receiver.",
          "在 iMac 上：系统设置 › 隐私与安全性 › \(setting) › PWE Screen Encore Receiver。")
    }
    var networkLink: String { t("Also allow a network cable or Wi‑Fi", "也允许用网线或 Wi‑Fi 连接") }
    var networkLinkHint: String {
        t("Thunderbolt is fastest. Over a network the picture can lag or drop.",
          "雷雳最快。走网络时画面可能延迟或掉帧。")
    }
    var connectOver: String { t("Connect over", "连接方式") }
    func connectionName(_ connection: PWEConnection) -> String {
        switch connection {
        case .thunderbolt: return t("Thunderbolt cable", "雷雳线")
        case .network: return t("Network", "网络")
        }
    }
    var diagnostics: String { t("Diagnostics", "诊断") }
    var checkSetup: String { t("Check Setup", "检查配置") }
    var checkSetupLabel: String { t("This Mac, the link and permissions", "这台 Mac、连接和权限") }
    var reportLabel: String { t("Report for support", "求助报告") }
    var passed: String { t("Passed", "通过") }
    var needsAttention: String { t("Needs attention", "需要处理") }
    var afterConnecting: String { t("Checked after connecting", "连接后检查") }
    var exportReport: String { t("Save Report…", "保存报告…") }
    var exportReportHint: String {
        t("A text file with versions, settings and the last 30 minutes of this app's log, for support.",
          "一个文本文件，含版本、设置和本 App 最近 30 分钟的日志，用于求助。")
    }
    var openConsoleHint: String {
        t("TargetBridge's own console: every engine setting, in the upstream interface.",
          "TargetBridge 引擎自带的控制台：全部设置都在这里，界面保持上游原样。")
    }

    // About
    var version: String { t("Version", "版本") }
    /// Under the name in About: what the app is for. "for iMac" is a reference, not part of the name.
    var forIMac: String { t("For iMac", "用于 iMac") }
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
