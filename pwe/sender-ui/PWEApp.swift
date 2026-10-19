import AppKit
import ApplicationServices
import Darwin
import SwiftUI

/// The PWE iMac Display app: TargetBridge's engine behind PWE's own window,
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
        let model = PWESenderModel(service: shared)
        _service = StateObject(wrappedValue: shared)
        _model = StateObject(wrappedValue: model)
        statusMenu = PWEStatusMenu(model: model)
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

/// `--pwe-snapshot <dir>`: renders every phase of the window, the Settings tabs
/// and About, in English and in Chinese, to PNG files. It draws the app's own
/// views off screen, so checking the layout needs no screen recording and
/// touches no real connection. (The menu bar menu is AppKit and is not drawn.)
enum PWESnapshot {
    @MainActor
    static func render(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let imac = PWEReceiver(id: "preview", name: "LL-iMac-2017", detail: "5120 × 2880",
                               supportsHEVC: true, panelWidth: 5120)
        let other = PWEReceiver(id: "preview-2", name: "Studio iMac", detail: "5120 × 2880")
        let phases: [(String, PWEPhase, Bool)] = [
            ("1-permission", .needsPermission, true),
            ("2-searching", .searching, true),
            ("3-choose", .choose([imac, other]), true),
            ("4-ready", .ready(imac), true),
            ("5-connecting", .connecting(imac, .preparing), true),
            ("6a-first-connection-setup", .connected(imac), false),
            ("6b-connected", .connected(imac), true),
            ("7-interrupted-retrying", .interrupted(imac, .cableOrReceiverGone, retrying: true), true),
            ("8-interrupted", .interrupted(imac, .captureFailed, retrying: false), true),
            ("8b-interrupted-cable", .interrupted(imac, .cableOrReceiverGone, retrying: false), true),
        ]
        for language in [TBDisplaySenderLanguage.english, .chinese] {
            let strings = PWEStrings(language: language)
            let stem = language.fileStem
            for (name, phase, setupFinished) in phases {
                let view = PWEMainView(model: PWESenderModel(preview: phase, setupFinished: setupFinished), strings: strings)
                write(view, to: directory.appendingPathComponent("\(stem)-\(name).png"))
            }
            write(PWEAboutView(updates: UpdateCheck(), strings: strings),
                  to: directory.appendingPathComponent("\(stem)-9-about.png"))

            let connected = PWESenderModel(preview: .connected(imac))
            let sharing = PWESenderModel(preview: .connected(imac), inputRole: .macControlsIMac)
            let tabs: [(String, String, AnyView)] = [
                ("s1-general", strings.general, AnyView(PWEGeneralSettings(model: connected, updates: UpdateCheck(), strings: strings))),
                ("s2-display", strings.display, AnyView(PWEDisplaySettings(model: connected, strings: strings))),
                ("s3-sound", strings.sound, AnyView(PWESoundSettings(model: connected, strings: strings))),
                ("s4-keyboard-mouse", strings.keyboardMouse, AnyView(PWEInputSettings(model: connected, strings: strings))),
                ("s4b-keyboard-mouse-on", strings.keyboardMouse, AnyView(PWEInputSettings(model: sharing, strings: strings))),
                ("s5-advanced", strings.advancedTab, AnyView(PWEAdvancedSettings(model: connected, strings: strings))),
            ]
            for (name, title, tab) in tabs {
                write(settingsFrame(title: title, tab), to: directory.appendingPathComponent("\(stem)-\(name).png"))
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
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
