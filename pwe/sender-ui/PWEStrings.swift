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
    var appName: String { "PWE iMac Display" }
    /// The full TargetBridge console's window title.
    var consoleTitle: String { t("Full Console", "完整控制台") }
    var about: String { t("About", "关于") }
    var aboutApp: String { t("About PWE iMac Display", "关于 PWE iMac Display") }

    // Permission
    var permissionTitle: String { t("Allow Screen Recording", "允许录屏") }
    var permissionBody: String {
        t("To show this Mac's screen on your iMac, PWE iMac Display needs your permission. It records only the screen it shows on your iMac, and sends it nowhere else.",
          "要把这台 Mac 的画面显示到 iMac 上，PWE iMac Display 需要你的允许。它只录制要显示在 iMac 上的画面，不发往其他任何地方。")
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
    var useAsDisplay: String { t("Use as Display", "用作显示器") }
    var modeLabel: String { t("Show", "显示方式") }
    var modeExtended: String { t("Separate display", "独立的一块屏") }
    var modeMirror: String { t("Same as this Mac", "和这台 Mac 一样") }
    var picture: String { t("Picture", "画面") }
    func pictureName(_ preset: TBDisplayCapturePreset) -> String {
        switch preset {
        case .standard1440p: return t("Standard · 1440p", "标准 · 1440p")
        case .native5k: return t("5K · 48 Hz", "5K · 48 Hz")
        case .native5k60Experimental: return t("5K · 60 Hz", "5K · 60 Hz")
        default: return "\(preset.title) · \(preset.description)"
        }
    }
    var pictureChangeHint: String { t("Changing it reconnects for a moment.", "更改后会重新连接一下。") }
    var pictureHint: String {
        t("Remembered for each iMac. 5K · 60 Hz is the smoothest; choose Standard if the picture stutters.",
          "每台 iMac 各记各的。5K · 60 Hz 最流畅；画面卡顿时选「标准」。")
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
    func interruptedHint(_ reason: PWEReason, retrying: Bool) -> String {
        switch reason {
        case .cableOrReceiverGone:
            return retrying
                ? t("Check the cable. It connects again when the iMac is back.", "检查一下线。iMac 回来后会自动重新连接。")
                : t("Check the cable. When the iMac is back, choose Try Again.", "检查一下线。iMac 回来后，点「重试」。")
        case .receiverQuit:
            return t("Open PWE iMac Display Receiver on the iMac again.", "在 iMac 上重新打开「PWE iMac Display Receiver」。")
        case .couldNotConnect:
            return t("Check that PWE iMac Display Receiver is open on the iMac and the cable is in.",
                     "确认 iMac 上的「PWE iMac Display Receiver」开着、线插好了。")
        case .captureFailed:
            return t("Try again, or choose Standard under Picture in the menu bar.", "再试一次，或在菜单栏的「画面」里选「标准」。")
        }
    }
    var retrying: String { t("Trying again…", "正在重试…") }
    var stopRetrying: String { t("Stop", "停止") }
    var tryAgain: String { t("Try Again", "重试") }

    // Last setup screen
    var setupTitle: String { t("Two more things", "还有两件事") }
    var setupBody: String {
        t("You can change these later in Settings.", "以后可以在「设置」里更改。")
    }
    var setupDone: String { t("Done", "完成") }
    var menuBarHint: String {
        t("Brightness, picture and sound are in the menu bar.", "亮度、画面和声音都在菜单栏里。")
    }

    // Preferences
    var autoConnect: String { t("Connect automatically when the cable goes in", "接上线就自动连接") }
    var launchAtLogin: String { t("Open at login", "登录时打开") }
    var launchAtLoginApproval: String { t("Allow in Login Items…", "在「登录项」里允许…") }

    // Menu bar
    var menuOpenWindow: String { t("Open PWE iMac Display", "打开 PWE iMac Display") }
    var menuConnect: String { t("Use as Display", "用作显示器") }
    func menuConnectTo(_ name: String) -> String { t("Use \(name) as Display", "把 \(name) 用作显示器") }
    var settingsMenu: String { t("Settings…", "设置…") }
    var quit: String { t("Quit PWE iMac Display", "退出 PWE iMac Display") }
    var nightShift: String { t("Night Shift", "夜览") }
    var trueTone: String { t("True Tone", "原彩显示") }
    var on: String { t("On", "开") }
    var off: String { t("Off", "关") }
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
        }
    }

    // Settings
    var settingsTitle: String { t("Settings", "设置") }
    var general: String { t("General", "通用") }
    var display: String { t("Display", "显示") }
    var keyboardMouse: String { t("Keyboard & Mouse", "键盘与鼠标") }
    var advancedTab: String { t("Advanced", "高级") }
    var reconnectNotice: String { t("Reconnecting to apply the change…", "正在重新连接以应用更改…") }
    var showMenuBarIcon: String { t("Show in menu bar", "在菜单栏中显示") }
    var showMenuBarIconHint: String {
        t("When it is hidden, open PWE iMac Display again to see this window.",
          "隐藏后，再次打开 PWE iMac Display 即可看到窗口。")
    }
    var languageHint: String {
        t("PWE iMac Display uses the language set for it in System Settings › General › Language & Region.",
          "PWE iMac Display 的语言跟随「系统设置 › 通用 › 语言与地区」。")
    }
    var updates: String { t("Updates", "更新") }
    var startup: String { t("Startup", "启动") }
    var noIMacYet: String { t("Connect an iMac once to choose its picture.", "先连接一次 iMac，再选择它的画面。") }
    func pictureFor(_ name: String) -> String { t("Picture on \(name)", "\(name) 的画面") }
    var keepAwake: String { t("Keep the displays awake while showing", "显示时不让屏幕休眠") }
    var largeCursor: String { t("Larger pointer on the iMac", "iMac 上使用大指针") }
    var changesReconnect: String { t("Changes reconnect for a moment.", "更改后会重新连接一下。") }
    var soundTitle: String { t("Play this Mac's sound", "这台 Mac 的声音") }
    func soundDetail(_ sound: PWESound) -> String {
        switch sound {
        case .onlyIMac: return t("This Mac's speakers stay quiet while the iMac plays.", "iMac 播放时，这台 Mac 的扬声器静音。")
        case .both: return t("Both play; the iMac is a moment behind.", "两边同时播放，iMac 会稍慢一点。")
        case .onlyThisMac: return t("The iMac stays silent.", "iMac 不出声。")
        }
    }
    var iMacVolume: String { t("iMac volume", "iMac 音量") }
    var iMacVolumeHint: String { t("Works while the iMac is a display.", "iMac 用作显示器时可调。") }
    var experimental: String { t("Experimental", "实验性") }
    var inputTitle: String { t("Share keyboard and mouse", "共享键盘和鼠标") }
    func inputRoleName(_ role: PWEInputRole) -> String {
        switch role {
        case .off: return t("Off", "关闭")
        case .macControlsIMac: return t("This Mac's keyboard and mouse control the iMac", "用这台 Mac 的键盘鼠标控制 iMac")
        case .iMacControlsMac: return t("The iMac's keyboard and mouse control this Mac", "用 iMac 的键盘鼠标控制这台 Mac")
        }
    }
    var inputHint: String {
        t("Applies while the iMac is a display. Press Control-Option-Command-K to stop controlling at once.",
          "iMac 用作显示器时生效。按 Control-Option-Command-K 可立即停止控制。")
    }
    var permissionsNeeded: String { t("Permissions", "所需权限") }
    var onThisMac: String { t("On this Mac", "在这台 Mac 上") }
    var onTheIMac: String { t("On the iMac", "在 iMac 上") }
    var inputMonitoring: String { t("Input Monitoring", "输入监控") }
    var accessibility: String { t("Accessibility", "辅助功能") }
    var allowed: String { t("Allowed", "已允许") }
    var notAllowed: String { t("Not allowed", "未允许") }
    var unknownUntilConnected: String { t("Known after connecting", "连接后才知道") }
    var open: String { t("Open…", "打开…") }
    func iMacPermissionHint(_ setting: String) -> String {
        t("On the iMac: System Settings › Privacy & Security › \(setting) › PWE iMac Display Receiver.",
          "在 iMac 上：系统设置 › 隐私与安全性 › \(setting) › PWE iMac Display Receiver。")
    }
    var connectionSection: String { t("Connection", "连接") }
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
    var videoSection: String { t("Video", "视频") }
    var compression: String { t("Compression", "压缩方式") }
    func codecName(_ codec: TBDisplayCodecPreference) -> String {
        switch codec {
        case .automatic: return t("Automatic", "自动")
        case .hevc: return "HEVC"
        case .h264: return "H.264"
        }
    }
    var renderMatching: String { t("Render the desktop at the picture's size", "按画面尺寸渲染桌面") }
    var renderMatchingHint: String {
        t("Sharper text at Standard; 5K pictures always render at full size.",
          "「标准」画面下文字更清晰；5K 画面始终按原尺寸渲染。")
    }
    var diagnostics: String { t("Diagnostics", "诊断") }
    var checkSetup: String { t("Check Setup", "检查配置") }
    var checkSetupLabel: String { t("This Mac, the link and permissions", "这台 Mac、连接和权限") }
    var cableLabel: String { t("Cable speed", "线缆速度") }
    var restartPictureLabel: String { t("If the picture freezes", "画面卡住时") }
    var reportLabel: String { t("Report for support", "求助报告") }
    var cableTest: String { t("Test Cable", "测试线缆") }
    var cableTesting: String { t("Testing…", "正在测试…") }
    func cableResult(_ rate: Double?) -> String {
        guard let rate else { return t("Not tested yet", "还没测过") }
        return String(format: "%.2f Gbit/s", rate)
    }
    var cableTestHint: String { t("Works while the iMac is not showing a picture.", "在 iMac 没有显示画面时才能测试。") }
    var restartPicture: String { t("Restart Picture", "重启画面") }
    var detailedLogging: String { t("Detailed logging", "详细日志") }
    var exportReport: String { t("Save Report…", "保存报告…") }
    var exportReportHint: String {
        t("A text file with versions, settings and the last 30 minutes of this app's log, for support.",
          "一个文本文件，含版本、设置和本 App 最近 30 分钟的日志，用于求助。")
    }
    var openConsoleHint: String {
        t("TargetBridge's own console, with every engine setting.", "TargetBridge 自己的控制台，包含引擎的全部设置。")
    }

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
