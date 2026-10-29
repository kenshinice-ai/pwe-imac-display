import AppKit
import SwiftUI

/// The PWE window: first setup, and the iMac's status at a glance. One question
/// answered at a time, one primary action.
///
/// Day-to-day controls live in the menu bar (PWEStatusMenu) and set-once choices
/// in Settings (PWESettingsView); this window is for first setup and for when
/// something needs the person: once the iMac is a display it says so, and offers
/// only Arrange Displays and Disconnect.
struct PWEMainView: View {
    @ObservedObject var model: PWESenderModel
    let strings: PWEStrings
    var openAbout: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The title bar above is empty (PWEUntitledWindow) and the traffic
            // lights end about 16 pt above the header: 8 here makes the gap above
            // the icon match the 16 below it.
            header
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 16)

            Divider()

            ZStack(alignment: .topLeading) {
                phaseView
                    .id(phaseKey)
                    .transition(reduceMotion ? .identity : Self.phaseChange)
            }
            // One height for every phase, content from the top: the window never
            // jumps, and the symbol and title (PWEPhaseLayout) stay in one place
            // when the connection changes state.
            .frame(maxWidth: .infinity, minHeight: 250, alignment: .topLeading)
            .padding(24)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: phaseKey)
        }
        .frame(width: 440)
        // The window changes by itself as the connection moves on; VoiceOver
        // hears the new state instead of finding it by moving around.
        .onChange(of: phaseKey) {
            AccessibilityNotification.Announcement(strings.status(model.phase)).post()
        }
    }

    /// One phase on screen at a time (T28): the old one fades out in 0.08 s,
    /// then the new one fades in, 0.2 s in all. A symmetric cross-fade showed
    /// "no longer connected" and "Connecting" on top of each other.
    private static let phaseChange = AnyTransition.asymmetric(
        insertion: .opacity.animation(.easeOut(duration: 0.12).delay(0.08)),
        removal: .opacity.animation(.easeIn(duration: 0.08)))

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable()
                .frame(width: 40, height: 40)
                .accessibilityHidden(true)
            Text(strings.appName)
                .font(.title2.weight(.semibold))
            Spacer()
            Button(action: openAbout) {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.borderless)
            .help(strings.about)
            .accessibilityLabel(strings.about)
        }
    }

    // MARK: - Phases

    /// Changes only when the kind of screen changes, so a brightness tweak never cross-fades the card.
    private var phaseKey: String {
        switch model.phase {
        case .needsPermission: return "permission"
        case .searching: return "searching"
        case .choose: return "choose"
        case .ready: return "ready"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .interrupted: return "interrupted"
        case .security(_, let security):
            switch security {
            case .needsCode, .wrongCode, .codeExpired, .checkingCode: return "code"
            default: return "question"
            }
        }
    }

    @ViewBuilder private var phaseView: some View {
        switch model.phase {
        case .needsPermission: permissionView
        case .searching: searchingView
        case .choose(let receivers): chooseView(receivers)
        case .ready(let receiver): readyView(receiver)
        case .connecting(let receiver, let stage): connectingView(receiver, stage)
        case .connected(let receiver): connectedView(receiver)
        case .interrupted(let receiver, let reason, let retrying): interruptedView(receiver, reason, retrying)
        case .security(let receiver, let security): PWEPairingView(model: model, strings: strings,
                                                                   receiver: receiver, security: security)
        }
    }

    private var permissionView: some View {
        PWEPhaseLayout(title: strings.permissionTitle) {
            PWESymbol(name: "rectangle.dashed.badge.record")
        } detail: {
            PWEPhaseText(strings.permissionBody)
        } actions: {
            VStack(alignment: .leading, spacing: 12) {
                Button(strings.permissionOpen) { model.requestScreenRecording() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                VStack(alignment: .leading, spacing: 4) {
                    Text(strings.permissionRestartHint)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(strings.permissionRestart) { model.restartForPermission() }
                        .buttonStyle(.link)
                }
                .font(.callout)
            }
        }
    }

    private var searchingView: some View {
        PWEPhaseLayout(title: strings.searchingTitle, busy: true) {
            HStack(spacing: 10) {
                Image(systemName: "laptopcomputer")
                Image(systemName: "cable.connector.horizontal")
                Image(systemName: "desktopcomputer")
            }
            .font(.system(size: 30, weight: .light))
            .foregroundStyle(.secondary)
        } detail: {
            VStack(alignment: .leading, spacing: 8) {
                step(1, strings.searchingStep1)
                step(2, strings.searchingStep2)
                Text(strings.searchingHint)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 4)
        } actions: {
            EmptyView()
        }
    }

    private func chooseView(_ receivers: [PWEReceiver]) -> some View {
        PWEPhaseLayout(title: strings.chooseTitle) {
            PWESymbol(name: "desktopcomputer")
        } detail: {
            EmptyView()
        } actions: {
            VStack(spacing: 8) {
                ForEach(receivers) { receiver in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(receiver.name).font(.headline)
                            if !receiver.detail.isEmpty {
                                Text(receiver.detail).font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button(strings.useAsDisplay) { model.connect(to: receiver) }
                    }
                    .padding(12)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityElement(children: .contain)
                }
            }
        }
    }

    private func readyView(_ receiver: PWEReceiver) -> some View {
        PWEPhaseLayout(title: receiver.name) {
            PWESymbol(name: "desktopcomputer")
        } detail: {
            if !receiver.detail.isEmpty { PWEPhaseText(receiver.detail) }
        } actions: {
            Button(strings.useAsDisplay) { model.connect(to: receiver) }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
    }

    private func connectingView(_ receiver: PWEReceiver?, _ stage: PWEStage) -> some View {
        PWEPhaseLayout(title: strings.connectingTitle(receiver?.name)) {
            PWESymbol(name: "desktopcomputer")
        } detail: {
            PWEProgressLine(strings.stage(stage))
            // A setting that reconnects says so here too, not only in Settings.
            if model.reconnectNotice {
                Text(strings.reconnectNotice)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            Button(strings.cancel) { model.disconnect() }
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)
        }
    }

    private func connectedView(_ receiver: PWEReceiver?) -> some View {
        PWEPhaseLayout(title: strings.connectedTitle(receiver?.name)) {
            PWESymbol(name: "checkmark.circle", tint: .green)
        } detail: {
            EmptyView()
        } actions: {
            VStack(alignment: .leading, spacing: 16) {
                if model.isUnencrypted { unencryptedWarning }
                // A14: the picture loop Screen Sharing makes, and how to end it.
                if model.viewedWithScreenSharing { PWENote(strings.screenSharingNotice) }
                HStack(spacing: 10) {
                    Button(strings.arrange) { model.openDisplaySettings() }
                    Button(strings.disconnect) { model.disconnect() }
                }
                .controlSize(.large)
                if model.firstConnection { firstConnectionTips }
            }
        }
    }

    /// Two lines the first time an iMac becomes a display, and never again: where
    /// the everyday controls are, and Open at login, already ticked.
    private var firstConnectionTips: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            if model.menuBarIconHidden {
                // T19: the icon the tip points at is not there to see.
                Text(strings.menuBarHiddenTip())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                let tip = strings.menuBarTip
                // The glyph the menu bar shows (PWEStatusMenu.updateButton).
                Text("\(tip.before)\(Image("PWEMenuBarReady"))\(tip.after)")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(strings.menuBarTipSpoken)
            }
            Toggle(strings.launchAtLogin, isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }))
                .toggleStyle(.checkbox)
                .disabled(!model.launchAtLoginDisplay.isEnabled)
            if model.launchAtLoginNeedsApproval {
                Button(strings.launchAtLoginApproval()) { model.openLoginItemsSettings() }
                    .buttonStyle(.link)
                    .font(.callout)
            }
            if model.launchAtLoginDisplay.showsMoveHint {
                Text(strings.launchAtLoginMove)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// D1: an unencrypted session is allowed, and always says so, with the way out.
    /// The colour is in the icon and the tint; the words keep the text colour.
    private var unencryptedWarning: some View {
        VStack(alignment: .leading, spacing: 8) {
            PWENote(strings.unencryptedBanner, symbol: "lock.open.fill")
            Button(strings.turnOffUnencrypted) { model.turnOffUnencrypted() }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }

    private func interruptedView(_ receiver: PWEReceiver?, _ reason: PWEReason, _ retrying: Bool) -> some View {
        PWEPhaseLayout(title: strings.interruptedTitle(reason)) {
            PWESymbol(name: "exclamationmark.triangle", tint: .orange)
        } detail: {
            PWEPhaseText(strings.interruptedHint(reason, retrying: retrying, overNetwork: model.connectsOverNetwork))
            if retrying { PWEProgressLine(strings.retrying) }
        } actions: {
            // Like Connecting: what is happening above, the way to stop it below.
            HStack(spacing: 10) {
                if retrying {
                    Button(strings.stopRetrying) { model.stopRetrying() }
                        .keyboardShortcut(.cancelAction)
                } else if let receiver {
                    Button(strings.tryAgain) { model.connect(to: receiver) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
                // Settings › Advanced's checks, run on arrival: what to look at
                // when the hint above has not been enough.
                Button(strings.checkSetupEllipsis) {
                    PWEWindows.shared.showSettings(tab: .advanced, checkSetup: true)
                }
            }
            .controlSize(.large)
        }
    }

    // MARK: - Pieces

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)")
                .font(.callout.monospacedDigit().weight(.semibold))
                .frame(width: 20, height: 20)
                .background(.quaternary, in: Circle())
                .accessibilityHidden(true)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - One phase's layout

/// One phase of the window, laid out the same way every time: a symbol, the title
/// with what to know under it, then what to do. Every phase and every pairing step
/// uses it, so the symbol and the title sit in the same place on each and only the
/// words change as the connection moves on (the receiver's screen works the same
/// way: BRAND-iMac-Display §2.6).
///
/// Spacing, top to bottom: a 40 pt symbol slot, 12 to the title, 6 to the detail
/// (it belongs to the title), 16 to the actions (a separate group).
struct PWEPhaseLayout<Symbol: View, Detail: View, Actions: View>: View {
    let title: String
    /// A small spinner before the title, for a phase that is itself the wait.
    var busy = false
    @ViewBuilder var symbol: () -> Symbol
    @ViewBuilder var detail: () -> Detail
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                symbol()
                    .frame(height: 40, alignment: .bottomLeading)
                    .padding(.bottom, 6)
                    .accessibilityHidden(true)
                HStack(spacing: 8) {
                    if busy { ProgressView().controlSize(.small) }
                    Text(title)
                        .font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                detail()
            }
            actions()
        }
    }
}

/// The phase's symbol: grey for a step, green or orange for an outcome. Outline
/// symbols only, in one light weight: an outcome differs by colour, not by a
/// heavier, filled shape that would shout over the title.
struct PWESymbol: View {
    let name: String
    var tint: Color?

    var body: some View {
        Image(systemName: name)
            .font(.system(size: 34, weight: .light))
            .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
    }
}

/// A phase's explanation, in the secondary colour.
struct PWEPhaseText: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Something under way: a small spinner and what it is doing.
struct PWEProgressLine: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A warning or an error in a line of text. The orange is in the icon; the words
/// keep the text colour, because system orange on a light window is about 2:1,
/// too faint to read as text.
struct PWENote: View {
    let text: String
    var symbol = "exclamationmark.circle.fill"

    init(_ text: String, symbol: String = "exclamationmark.circle.fill") {
        self.text = text
        self.symbol = symbol
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Version, credit, source, support and the update check — the app's one About,
/// and the one place it mentions support (PWE Tools handoff §0.9) or offers a
/// check right now. The daily check is switched in Settings › General.
struct PWEAboutView: View {
    @ObservedObject var updates: UpdateCheck
    let strings: PWEStrings
    /// A Done button, for a sheet; the About window closes like any window.
    var dismiss: (() -> Void)?

    @State private var checking = false
    @State private var lastResult: String?
    /// The site answered without naming a release, so the page is the honest next step.
    @State private var offerPage = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                    .resizable().frame(width: 48, height: 48)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(strings.appName).font(.title3.weight(.semibold))
                    Text("\(strings.forIMac) · \(strings.version) \(UpdateCheck.currentVersion) (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(strings.builtBy)
                    .font(.callout)
                Text(strings.credits)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 14) {
                Link(strings.source, destination: URL(string: "https://github.com/kenshinice-ai/pwe-imac-display")!)
                Link(strings.support, destination: URL(string: "https://pwestudio.site/support")!)
            }
            Divider()
            HStack(spacing: 10) {
                Button(strings.checkUpdates) {
                    checking = true
                    Task {
                        // Asked for, so it reports the newest version whatever was dismissed,
                        // and claims "latest" only when the site named a release.
                        let outcome = await updates.check(manual: true)
                        checking = false
                        switch outcome {
                        case .newer(let release): lastResult = strings.updateAvailable(release.version)
                        case .current: lastResult = strings.upToDate
                        case .unknown: lastResult = strings.latestUnknown
                        case .unreachable: lastResult = strings.couldNotCheck
                        }
                        offerPage = outcome == .unknown
                    }
                }
                .disabled(checking)
                if checking { ProgressView().controlSize(.small) }
                if let lastResult { Text(lastResult).font(.callout).foregroundStyle(.secondary) }
                if updates.available != nil || offerPage {
                    Link(strings.download, destination: UpdateCheck.downloadPage)
                }
            }
            // The PWE signature line, as in PWE Lumen Bar; the same in both languages.
            Text(verbatim: "PWE · 天域出品 · © 2026 PWE Group Pty Ltd")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let dismiss {
                HStack {
                    Spacer()
                    Button(strings.done, action: dismiss).keyboardShortcut(.defaultAction)
                }
            }
        }
        // Top 8: the empty title bar above already gives the space (PWEUntitledWindow).
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 24)
        .frame(width: 400)
    }
}
