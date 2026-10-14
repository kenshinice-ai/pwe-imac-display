import AppKit
import ApplicationServices
import Darwin
import SwiftUI

/// The PWE iMac Display app: TargetBridge's engine behind PWE's own window.
///
/// pwe/rebrand.py removes `@main` from TargetBridge's `TBDisplaySenderApp` and
/// adds this file, so the engine, the menu bar item, the settings and the full
/// TargetBridge dashboard (the "Advanced" window) are upstream's, unchanged.
@main
struct PWEApp: App {
    @StateObject private var service: TBDisplaySenderService
    @StateObject private var model: PWESenderModel
    @StateObject private var updates = UpdateCheck()
    private let statusItemController: TBDisplaySenderStatusItemController

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
        _service = StateObject(wrappedValue: shared)
        _model = StateObject(wrappedValue: PWESenderModel(service: shared))
        statusItemController = TBDisplaySenderStatusItemController(service: shared)
        TBSenderAutomation.handleLaunchArguments(CommandLine.arguments)
    }

    var body: some Scene {
        WindowGroup("PWE iMac Display", id: "main") {
            PWEWindowContent(model: model, service: service, updates: updates,
                             statusItemController: statusItemController)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button(TBDisplaySenderL10n.quitApp(service.language)) {
                    service.quitAfterUserRequest()
                }
                .keyboardShortcut("q")
            }
        }

        Window(PWEStrings(language: service.language).advanced, id: "advanced") {
            TBDisplaySenderContentView(service: service)
                .frame(minWidth: 540)
                .onOpenURL { TBSenderAutomation.handle(url: $0) }
        }
        .defaultSize(width: 860, height: 860)

        Settings {
            TBDisplaySenderSettingsView(service: service)
                .frame(minWidth: 760, minHeight: 620)
        }
    }
}

private struct PWEWindowContent: View {
    @ObservedObject var model: PWESenderModel
    @ObservedObject var service: TBDisplaySenderService
    @ObservedObject var updates: UpdateCheck
    let statusItemController: TBDisplaySenderStatusItemController

    @Environment(\.openWindow) private var openWindow
    @State private var showingAbout = false
    @AppStorage("pwe.updateChecks") private var dailyChecks = false

    var body: some View {
        let strings = PWEStrings(language: service.language)
        PWEMainView(model: model, strings: strings,
                    openAdvanced: { openWindow(id: "advanced") },
                    openAbout: { showingAbout = true })
            .sheet(isPresented: $showingAbout) {
                PWEAboutView(updates: updates, strings: strings) { showingAbout = false }
            }
            .task {
                statusItemController.activate()
                model.startIfDue()
                await updates.checkIfDue(enabled: dailyChecks)
            }
            .onOpenURL { TBSenderAutomation.handle(url: $0) }
    }
}

/// `--pwe-snapshot <dir>`: renders every phase of the window, in English and in
/// Chinese, to PNG files. It draws the app's own views off screen, so checking
/// the layout needs no screen recording and touches no real connection.
enum PWESnapshot {
    @MainActor
    static func render(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let imac = PWEReceiver(id: "preview", name: "Lee's iMac", detail: "27-inch Retina 5K · 5120 × 2880")
        let other = PWEReceiver(id: "preview-2", name: "Studio iMac", detail: "27-inch Retina 5K · 5120 × 2880")
        let phases: [(String, PWEPhase)] = [
            ("1-permission", .needsPermission),
            ("2-searching", .searching),
            ("3-choose", .choose([imac, other])),
            ("4-ready", .ready(imac)),
            ("5-connecting", .connecting(imac, .preparing)),
            ("6-connected", .connected(imac)),
            ("7-interrupted-retrying", .interrupted(imac, .cableOrReceiverGone, retrying: true)),
            ("8-interrupted", .interrupted(imac, .captureFailed, retrying: false)),
        ]
        for language in [TBDisplaySenderLanguage.english, .chinese] {
            let strings = PWEStrings(language: language)
            for (name, phase) in phases {
                let view = PWEMainView(model: PWESenderModel(preview: phase), strings: strings)
                write(view, to: directory.appendingPathComponent("\(language.fileStem)-\(name).png"))
            }
            write(PWEAboutView(updates: UpdateCheck(), strings: strings),
                  to: directory.appendingPathComponent("\(language.fileStem)-9-about.png"))
        }
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
