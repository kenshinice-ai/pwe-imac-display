import AppKit
import SwiftUI

/// The PWE window: one question answered at a time, one primary action.
///
/// Everything TargetBridge offers is still one click away in the advanced window;
/// this window shows only what someone needs to turn an iMac into a display and
/// to know, at a glance, whether it is one.
struct PWEMainView: View {
    @ObservedObject var model: PWESenderModel
    let strings: PWEStrings
    var openAdvanced: () -> Void = {}
    var openAbout: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 16)

            Divider()

            ZStack(alignment: .leading) {
                phaseView
                    .id(phaseKey)
                    .transition(.opacity)
            }
            // One height for every phase, content centred in it: the window never
            // jumps when the connection changes state.
            .frame(maxWidth: .infinity, minHeight: 250, alignment: .leading)
            .padding(24)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: phaseKey)

            Divider()

            preferences
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
        }
        .frame(width: 440)
    }

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
            Button(strings.advanced, action: openAdvanced)
                .buttonStyle(.borderless)
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
        }
    }

    private var permissionView: some View {
        VStack(alignment: .leading, spacing: 14) {
            symbol("rectangle.dashed.badge.record")
            Text(strings.permissionTitle).font(.title3.weight(.semibold))
            Text(strings.permissionBody).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button(strings.permissionOpen) { model.requestScreenRecording() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
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

    private var searchingView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "laptopcomputer")
                Image(systemName: "cable.connector.horizontal")
                Image(systemName: "desktopcomputer")
            }
            .font(.system(size: 30, weight: .light))
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(strings.searchingTitle).font(.title3.weight(.semibold))
            }
            step(1, strings.searchingStep1)
            step(2, strings.searchingStep2)
            Text(strings.searchingHint)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func chooseView(_ receivers: [PWEReceiver]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(strings.chooseTitle).font(.title3.weight(.semibold))
            ForEach(receivers) { receiver in
                HStack(spacing: 12) {
                    Image(systemName: "desktopcomputer").font(.title2).foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    receiverLabel(receiver)
                    Spacer()
                    Button(strings.useAsDisplay) { model.connect(to: receiver) }
                }
                .padding(12)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func readyView(_ receiver: PWEReceiver) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            symbol("desktopcomputer")
            receiverLabel(receiver, large: true)
            Picker(strings.modeLabel, selection: $model.displayMode) {
                Text(strings.modeExtended).tag(PWEDisplayMode.extended)
                Text(strings.modeMirror).tag(PWEDisplayMode.mirror)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            // Decided when the picture starts, so it is set here, not while connected.
            if model.soundAvailable {
                Toggle(strings.sound, isOn: $model.soundOn)
            }
            Button(strings.useAsDisplay) { model.connect(to: receiver) }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
    }

    private func connectingView(_ receiver: PWEReceiver?, _ stage: PWEStage) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            symbol("desktopcomputer")
            Text(strings.connectingTitle(receiver?.name)).font(.title3.weight(.semibold))
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(strings.stage(stage)).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            Button(strings.cancel) { model.disconnect() }
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)
        }
    }

    private func connectedView(_ receiver: PWEReceiver?) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
                Text(strings.connectedTitle(receiver?.name)).font(.title3.weight(.semibold))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(strings.brightness).font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Image(systemName: "sun.min").foregroundStyle(.secondary).accessibilityHidden(true)
                    Slider(value: $model.brightness, in: 0...1)
                        .accessibilityLabel(strings.brightness)
                    Image(systemName: "sun.max").foregroundStyle(.secondary).accessibilityHidden(true)
                }
            }
            HStack(spacing: 10) {
                Button(strings.arrange) { model.openDisplaySettings() }
                    .controlSize(.large)
                Button(strings.disconnect) { model.disconnect() }
                    .controlSize(.large)
            }
        }
    }

    private func interruptedView(_ receiver: PWEReceiver?, _ reason: PWEReason, _ retrying: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(.yellow)
                    .accessibilityHidden(true)
                Text(strings.interruptedTitle(reason)).font(.title3.weight(.semibold))
            }
            Text(strings.interruptedHint(reason, retrying: retrying))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if retrying {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(strings.retrying).foregroundStyle(.secondary)
                    Spacer()
                    Button(strings.stopRetrying) { model.stopRetrying() }
                }
            } else if let receiver {
                Button(strings.tryAgain) { model.connect(to: receiver) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
    }

    // MARK: - Preferences

    private var preferences: some View {
        VStack(alignment: .leading, spacing: 10) {
            preference(strings.autoConnect, isOn: $model.autoConnect)
            preference(strings.launchAtLogin, isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }))
            if model.launchAtLoginNeedsApproval {
                Button(strings.launchAtLoginApproval) { model.openLoginItemsSettings() }
                    .buttonStyle(.link)
                    .font(.callout)
            }
        }
    }

    /// Label on the leading edge, switch on the trailing edge, as in System Settings.
    private func preference(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title)
            Spacer()
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    // MARK: - Pieces

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 34, weight: .light))
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)")
                .font(.callout.monospacedDigit().weight(.semibold))
                .frame(width: 20, height: 20)
                .background(.quaternary, in: Circle())
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func receiverLabel(_ receiver: PWEReceiver, large: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(receiver.name).font(large ? .title3.weight(.semibold) : .headline)
            if !receiver.detail.isEmpty {
                Text(receiver.detail).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

/// Version, credit, source, support and the update check — the one place the app
/// mentions support (PWE Tools handoff §0.9).
struct PWEAboutView: View {
    @ObservedObject var updates: UpdateCheck
    let strings: PWEStrings
    var dismiss: () -> Void = {}

    @AppStorage("pwe.updateChecks") private var dailyChecks = false
    @State private var checking = false
    @State private var lastResult: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                    .resizable().frame(width: 48, height: 48)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(strings.appName).font(.title3.weight(.semibold))
                    Text("\(strings.version) \(UpdateCheck.currentVersion)")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Text(strings.credits)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                Link(strings.source, destination: URL(string: "https://github.com/kenshinice-ai/pwe-imac-display")!)
                Link(strings.support, destination: URL(string: "https://pwestudio.site/support")!)
            }
            Divider()
            HStack {
                Text(strings.checkUpdatesDaily)
                Spacer()
                Toggle(strings.checkUpdatesDaily, isOn: $dailyChecks)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            HStack(spacing: 10) {
                Button(strings.checkUpdates) {
                    checking = true
                    Task {
                        let answered = await updates.check()
                        checking = false
                        if let available = updates.available {
                            lastResult = strings.updateAvailable(available.version)
                        } else {
                            lastResult = answered ? strings.upToDate : strings.couldNotCheck
                        }
                    }
                }
                .disabled(checking)
                if checking { ProgressView().controlSize(.small) }
                if let lastResult { Text(lastResult).font(.callout).foregroundStyle(.secondary) }
                if updates.available != nil {
                    Link(strings.download, destination: UpdateCheck.downloadPage)
                }
            }
            HStack {
                Spacer()
                Button(strings.done, action: dismiss).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 400)
    }
}
