import AppKit
import ApplicationServices
import Darwin
import SwiftUI

/// The PWE Screen Encore app: TargetBridge's engine behind PWE's own window,
/// menu bar item, settings and About.
///
/// pwe/rebrand.py removes `@main` from TargetBridge's `TBDisplaySenderApp` and
/// adds this file. The engine is upstream's, unchanged; upstream's dashboard is
/// still there as the "Full Console", opened from Settings › Advanced.
@main
struct PWEApp: App {
    @StateObject private var service: TBDisplaySenderService
    @StateObject private var model: PWESenderModel
    @StateObject private var updates = UpdateCheck()
    private let statusMenu: PWEStatusMenu

    @MainActor
    init() {
        // Same probe as upstream: answer before the service exists, so a script
        // can read the installed binary's permissions without opening anything.
        if CommandLine.arguments.contains("--permission-status") {
            let screenRecording = CGPreflightScreenCaptureAccess() ? 1 : 0
            let accessibility = AXIsProcessTrusted() ? 1 : 0
            let inputMonitoring = CGPreflightListenEventAccess() ? 1 : 0
            print("TB_PERMISSION_STATUS:screen_recording=\(screenRecording):accessibility=\(accessibility):input_monitoring=\(inputMonitoring)")
            fflush(stdout)
            Darwin.exit(EXIT_SUCCESS)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--pwe-snapshot"),
           index + 1 < CommandLine.arguments.count {
            PWESnapshot.render(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            Darwin.exit(EXIT_SUCCESS)
        }

        let shared = TBDisplaySenderService.shared
        // The language is the one macOS gives this app, every launch. Upstream
        // remembers a choice made in its settings; 1.1 has none to make, and a
        // stale one showed a Chinese window on an English Mac (UX review 2026-10-19).
        let language = PWEStrings.systemLanguage()
        if shared.language != language { shared.language = language }
        // Keeping the displays awake while showing has no switch in PWE's UI, so
        // every launch starts from its default (on), whatever was stored before.
        if !shared.preventDisplaySleep { shared.preventDisplaySleep = true }
        let model = PWESenderModel(service: shared)
        _service = StateObject(wrappedValue: shared)
        _model = StateObject(wrappedValue: model)
        statusMenu = PWEStatusMenu(model: model)
        // The iMac's brightness keys and HUD; it also takes the app's URLs from
        // Apple events, so a background URL never opens a window (PWEBrightnessKeys).
        PWEBrightness.shared.start()
        TBSenderAutomation.handleLaunchArguments(CommandLine.arguments)
    }

    var body: some Scene {
        let strings = PWEStrings(language: service.language)

        WindowGroup(strings.appName, id: "main") {
            PWEWindowContent(model: model, service: service, updates: updates)
        }
        .windowResizability(.contentSize)
        .commands {
            // One main window: a second would only repeat the first.
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appInfo) {
                PWEOpenWindowButton(title: strings.aboutApp, id: "about")
            }
            CommandGroup(replacing: .appTermination) {
                Button(strings.quit) { service.quitAfterUserRequest() }
                    .keyboardShortcut("q")
            }
        }

        Window(strings.aboutApp, id: "about") {
            PWEAboutView(updates: updates, strings: strings)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        // Upstream's dashboard, every engine setting in one place.
        Window(strings.consoleTitle, id: "advanced") {
            TBDisplaySenderContentView(service: service)
                .frame(minWidth: 540)
                .onOpenURL { TBSenderAutomation.handle(url: $0) }
        }
        .defaultSize(width: 860, height: 860)

        Settings {
            PWESettingsView(model: model, updates: updates, strings: strings)
        }
    }
}

/// A menu command that opens one of PWE's windows.
private struct PWEOpenWindowButton: View {
    let title: String
    let id: String
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(title) {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: id)
        }
    }
}

private struct PWEWindowContent: View {
    @ObservedObject var model: PWESenderModel
    @ObservedObject var service: TBDisplaySenderService
    @ObservedObject var updates: UpdateCheck

    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @AppStorage("pwe.updateChecks") private var dailyChecks = false

    var body: some View {
        PWEMainView(model: model, strings: PWEStrings(language: service.language),
                    openAbout: { openWindow(id: "about") })
            .onAppear {
                PWEWindows.shared.openWindow = openWindow
                PWEWindows.shared.openSettings = openSettings
            }
            .task {
                model.startIfDue()
                await updates.checkIfDue(enabled: dailyChecks)
            }
            .onOpenURL { TBSenderAutomation.handle(url: $0) }
            // A pweimacdisplay:// URL goes to the open window instead of opening another.
            .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
    }
}

/// `--pwe-snapshot <dir>`: renders every phase of the window, the Settings tabs,
/// About and the menu bar menu, in English and in Chinese, to PNG files. It draws
/// the app's own views off screen, so checking the layout needs no screen
/// recording and touches no real connection. The menu is the real NSMenu that
/// PWEStatusMenu builds, laid out as rows (AppKit draws menus only on screen).
enum PWESnapshot {
    @MainActor
    static func render(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let imac = PWEReceiver(id: "preview", name: "LL-iMac-2017", detail: "5120 × 2880",
                               supportsHEVC: true, panelWidth: 5120)
        let other = PWEReceiver(id: "preview-2", name: "Studio iMac", detail: "5120 × 2880")
        let upstream = PWEReceiver(id: "preview-3", name: "Den", detail: "5120 × 2880", runsPWE: false)
        // Pairing and encryption: (name, phase, the session's security state).
        let pairing: [(String, PWEPhase, PWESecurityState)] = [
            ("p01-code", .security(imac, .needsCode(secondsLeft: 60, identityChanged: false)), .none),
            ("p02-code-identity-changed", .security(imac, .needsCode(secondsLeft: 60, identityChanged: true)), .none),
            ("p03-checking", .security(imac, .checkingCode), .none),
            ("p04-wrong-code", .security(imac, .wrongCode), .none),
            ("p04b-new-code-after-wrong", .security(imac, .needsCode(secondsLeft: 59, identityChanged: false)), .none),
            ("p05-code-expired", .security(imac, .codeExpired), .none),
            ("p05b-new-code-after-expiry", .security(imac, .needsCode(secondsLeft: 59, identityChanged: false)), .none),
            ("p06-locked", .security(imac, .locked(seconds: 60)), .none),
            ("p07-original-receiver", .security(upstream, .legacyReceiver(previouslyPaired: false)), .none),
            ("p08-pwe-1.0-receiver", .security(imac, .legacyReceiver(previouslyPaired: false)), .none),
            ("p09-paired-before-now-unencrypted", .security(imac, .legacyReceiver(previouslyPaired: true)), .none),
            ("p10-not-on-cable", .security(imac, .refused(.notOnCable)), .none),
            ("p11-unencrypted-turned-off", .security(upstream, .refused(.unencryptedNotAllowed)), .none),
            ("p12-imac-keychain", .security(imac, .refused(.receiverKeychain)), .none),
            ("p13-connected-unencrypted", .connected(upstream), .unencrypted),
        ]
        // (name, phase, the first connection's extra lines)
        let phases: [(String, PWEPhase, Bool)] = [
            ("1-permission", .needsPermission, false),
            ("2-searching", .searching, false),
            ("3-choose", .choose([imac, other]), false),
            ("4-ready", .ready(imac), false),
            ("5-connecting", .connecting(imac, .preparing), false),
            ("6a-first-connection", .connected(imac), true),
            ("6b-connected", .connected(imac), false),
            ("7-interrupted-retrying", .interrupted(imac, .cableOrReceiverGone, retrying: true), false),
            ("8-interrupted", .interrupted(imac, .captureFailed, retrying: false), false),
            ("8b-interrupted-cable", .interrupted(imac, .cableOrReceiverGone, retrying: false), false),
        ]
        // The menu bar menu: (name, model, submenus drawn beside it)
        let menus: [(String, PWESenderModel, Bool)] = [
            ("m1-menu-connected", PWESenderModel(preview: .connected(imac)), true),
            ("m2-menu-connected-unencrypted", PWESenderModel(preview: .connected(upstream), security: .unencrypted), false),
            ("m3-menu-ready", PWESenderModel(preview: .ready(imac)), false),
            ("m4-menu-searching", PWESenderModel(preview: .searching), true),
        ]
        for language in [TBDisplaySenderLanguage.english, .chinese] {
            let strings = PWEStrings(language: language)
            let stem = language.fileStem
            for (name, phase, firstConnection) in phases {
                let view = PWEMainView(model: PWESenderModel(preview: phase, firstConnection: firstConnection),
                                       strings: strings)
                write(view, to: directory.appendingPathComponent("\(stem)-\(name).png"))
            }
            write(PWEAboutView(updates: UpdateCheck(), strings: strings),
                  to: directory.appendingPathComponent("\(stem)-9-about.png"))
            for (name, phase, security) in pairing {
                // The code step after a wrong or expired code says why it asks again.
                let note: PWECodeNote? = name.hasPrefix("p04b") ? .wrong : name.hasPrefix("p05b") ? .expired : nil
                let model = PWESenderModel(preview: phase, security: security, codeNote: note)
                let view = PWEMainView(model: model, strings: strings)
                write(view, to: directory.appendingPathComponent("\(stem)-\(name).png"))
            }

            let connected = PWESenderModel(preview: .connected(imac))
            let sharing = PWESenderModel(preview: .connected(imac), inputRole: .macControlsIMac)
            let day = Date(timeIntervalSince1970: 1_792_368_000)   // 2026-10-19
            let paired = PWESenderModel(preview: .connected(imac), paired: [
                PWEPairedReceiver(id: "a1", name: "LL-iMac-2017", pairedAt: day),
                PWEPairedReceiver(id: "b2", name: "Studio iMac", pairedAt: day.addingTimeInterval(-86_400 * 3)),
            ])
            let tabs: [(String, String, AnyView)] = [
                ("s1-general", strings.general, AnyView(PWEGeneralSettings(model: connected, updates: UpdateCheck(), strings: strings))),
                ("s2-keyboard-mouse", strings.keyboardMouse, AnyView(PWEInputSettings(model: connected, strings: strings))),
                ("s2b-keyboard-mouse-on", strings.keyboardMouse, AnyView(PWEInputSettings(model: sharing, strings: strings))),
                ("s3-advanced", strings.advancedTab, AnyView(PWEAdvancedSettings(model: connected, strings: strings))),
                ("s3b-advanced-paired", strings.advancedTab, AnyView(PWEAdvancedSettings(model: paired, strings: strings))),
            ]
            for (name, title, tab) in tabs {
                write(settingsFrame(title: title, tab), to: directory.appendingPathComponent("\(stem)-\(name).png"))
            }

            for (name, model, withSubmenus) in menus {
                let menu = PWEStatusMenu(preview: model, language: language).previewMenu()
                var columns = [menu]
                if withSubmenus { columns += menu.items.compactMap(\.submenu) }
                write(menuSheet(columns), to: directory.appendingPathComponent("\(stem)-\(name).png"))
            }
        }
    }

    /// A tab as it sits in the Settings window, under a stand-in for the toolbar
    /// that the real window draws itself.
    private static func settingsFrame(title: String, _ tab: AnyView) -> some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(.bar)
            Divider()
            tab
        }
        .frame(width: PWESettingsLayout.width)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @MainActor
    private static func write<V: View>(_ view: V, to url: URL) {
        let host = NSHostingView(rootView: view.fixedSize())
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        write(host, to: url)
    }

    @MainActor
    private static func write(_ view: NSView, to url: URL) {
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    // MARK: - The menu as rows

    /// Menus side by side, top-aligned: the menu, then any submenus.
    @MainActor
    private static func menuSheet(_ menus: [NSMenu]) -> NSView {
        let margin: CGFloat = 16, gap: CGFloat = 12
        let panels = menus.map(menuPanel)
        let height = (panels.map(\.frame.height).max() ?? 0) + margin * 2
        let width = panels.reduce(margin * 2 - gap) { $0 + $1.frame.width + gap }
        let sheet = FlippedView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        sheet.fill = .underPageBackgroundColor
        var x = margin
        for panel in panels {
            panel.setFrameOrigin(NSPoint(x: x, y: margin))
            sheet.addSubview(panel)
            x += panel.frame.width + gap
        }
        return sheet
    }

    /// One menu: its text rows drawn the way AppKit lays them out (tick column,
    /// title, shortcut or submenu arrow), its custom rows as the views they are.
    @MainActor
    private static func menuPanel(_ menu: NSMenu) -> NSView {
        let width = TBMenuMetrics.width + 10, rowHeight: CGFloat = 22, pad: CGFloat = 5
        let font = NSFont.menuFont(ofSize: 0)
        let panel = FlippedView(frame: .zero)
        // Sized only at the end: rows must not move with it.
        panel.autoresizesSubviews = false
        panel.fill = .windowBackgroundColor
        panel.cornerRadius = 8

        func label(_ text: String, color: NSColor, x: CGFloat, y: CGFloat, alignRight: Bool = false) {
            let field = NSTextField(labelWithString: text)
            field.font = font
            field.textColor = color
            field.sizeToFit()
            let origin = alignRight ? x - field.frame.width : x
            field.setFrameOrigin(NSPoint(x: origin, y: y + (rowHeight - field.frame.height) / 2))
            panel.addSubview(field)
        }

        var y = pad
        for item in menu.items {
            if item.isSeparatorItem {
                let line = NSBox(frame: NSRect(x: 10, y: y + 5, width: width - 20, height: 1))
                line.boxType = .separator
                panel.addSubview(line)
                y += 11
            } else if let view = item.view {
                // A menu item's view keeps its origin at zero: place a holder instead.
                let holder = FlippedView(frame: NSRect(x: 5, y: y, width: view.frame.width, height: view.frame.height))
                holder.addSubview(view)
                panel.addSubview(holder)
                y += view.frame.height
            } else {
                let color: NSColor = item.isEnabled ? .labelColor : .disabledControlTextColor
                if item.state == .on { label("✓", color: color, x: 10, y: y) }
                var titleX: CGFloat = 24
                if let image = item.image {
                    let icon = NSImageView(frame: NSRect(x: titleX, y: y + 4, width: 14, height: 14))
                    icon.image = image
                    icon.contentTintColor = color
                    panel.addSubview(icon)
                    titleX += 20
                }
                label(item.title, color: color, x: titleX, y: y)
                if item.submenu != nil {
                    label("›", color: color, x: width - 12, y: y, alignRight: true)
                } else if !item.keyEquivalent.isEmpty {
                    label("⌘" + item.keyEquivalent.uppercased(), color: .secondaryLabelColor, x: width - 12, y: y,
                          alignRight: true)
                }
                y += rowHeight
            }
        }
        panel.frame = NSRect(x: 0, y: 0, width: width, height: y + pad)
        return panel
    }

    /// Top-down layout, drawn without layers: `cacheDisplay` misplaced the
    /// menu's own row views inside a layer-backed parent.
    private final class FlippedView: NSView {
        var fill: NSColor?
        var cornerRadius: CGFloat = 0
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) {
            guard let fill else { return }
            let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                     xRadius: cornerRadius, yRadius: cornerRadius)
            fill.setFill()
            shape.fill()
            if cornerRadius > 0 {
                NSColor.separatorColor.setStroke()
                shape.stroke()
            }
        }
    }
}
