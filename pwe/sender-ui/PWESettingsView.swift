import SwiftUI

/// PWE's one Settings window (⌘,): a standard grouped Form per tab, in the
/// system's appearance. It replaces upstream's settings window and the session
/// sheet of its dashboard; that dashboard is still reachable as the Full Console
/// from the Advanced tab.
///
/// Only what is set once and left alone. What changes day to day — brightness,
/// volume, picture, display mode, sound — is in the menu bar and not repeated
/// here; engine options with a good default (compression, render matching,
/// keeping the displays awake) are left to the Full Console.
///
/// Every setting can change while the iMac is a display. One the engine reads
/// only when a connection starts reconnects for a moment, and says so.
struct PWESettingsView: View {
    @ObservedObject var model: PWESenderModel
    @ObservedObject var updates: UpdateCheck
    let strings: PWEStrings

    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @ObservedObject private var navigation = PWESettingsNavigation.shared

    var body: some View {
        TabView(selection: $navigation.tab) {
            PWEGeneralSettings(model: model, updates: updates, strings: strings)
                .tabItem { Label(strings.general, systemImage: "gearshape") }
                .tag(PWESettingsNavigation.Tab.general)
            PWEInputSettings(model: model, strings: strings)
                .tabItem { Label(strings.keyboardMouse, systemImage: "keyboard") }
                .tag(PWESettingsNavigation.Tab.input)
            PWEAdvancedSettings(model: model, strings: strings, openConsole: {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "advanced")
            })
                .tabItem { Label(strings.advancedTab, systemImage: "gearshape.2") }
                .tag(PWESettingsNavigation.Tab.advanced)
        }
        .frame(width: PWESettingsLayout.width)
        .overlay(alignment: .bottom) { PWEReconnectNotice(model: model, strings: strings) }
        .onAppear {
            PWEWindows.shared.openWindow = openWindow
            PWEWindows.shared.openSettings = openSettings
        }
    }
}

/// Which Settings tab shows, shared so a button outside Settings can open it
/// at a tab (PWEWindows.showSettings): the interrupted phase's Check Setup…
/// and the unencrypted refusal's Settings… both go to Advanced.
@MainActor
final class PWESettingsNavigation: ObservableObject {
    enum Tab: Hashable { case general, input, advanced }
    static let shared = PWESettingsNavigation()
    @Published var tab: Tab = .general
    /// Advanced runs Check Setup when it next shows, then clears this.
    @Published var checkSetup = false
}

enum PWESettingsLayout {
    static let width: CGFloat = 540
}

/// "Reconnecting to apply the change…", for a few seconds after a change that reconnects.
struct PWEReconnectNotice: View {
    @ObservedObject var model: PWESenderModel
    let strings: PWEStrings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if model.reconnectNotice {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(strings.reconnectNotice).font(.callout)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 14)
                .transition(.opacity)
                .accessibilityElement(children: .combine)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: model.reconnectNotice)
    }
}

/// A small capsule next to a setting's name. Grey, not orange: orange is this
/// app's one warning colour, and an experimental option is not a warning.
private struct ExperimentalBadge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
    }
}

private func footnote(_ text: String) -> some View {
    Text(text)
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
}

// MARK: - General

struct PWEGeneralSettings: View {
    @ObservedObject var model: PWESenderModel
    @ObservedObject var updates: UpdateCheck
    let strings: PWEStrings

    @AppStorage(UpdateCheck.dailyKey) private var dailyChecks = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) })) {
                    Text(strings.launchAtLogin)
                    if model.launchAtLoginDisplay.showsMoveHint { Text(strings.launchAtLoginMove) }
                }
                .disabled(!model.launchAtLoginDisplay.isEnabled)
                if model.launchAtLoginNeedsApproval {
                    Button(strings.launchAtLoginApproval) { model.openLoginItemsSettings() }
                        .buttonStyle(.link)
                }
                Toggle(strings.autoConnect, isOn: $model.autoConnect)
            }
            Section {
                PWEBrightnessKeysSetting(language: strings.language)
            }
            PWEOnlyIMacSection(model: model, strings: strings)
            Section {
                Toggle(strings.checkUpdatesDaily, isOn: $dailyChecks)
                    .onChange(of: dailyChecks) { _, on in
                        if on { Task { await updates.checkIfDue(enabled: true) } }
                    }
                // What the daily check found; checking by hand is in About.
                if let available = updates.available {
                    LabeledContent(strings.updateAvailable(available.version)) {
                        HStack(spacing: 12) {
                            Link(strings.download, destination: UpdateCheck.downloadPage)
                            Button(strings.later) { updates.dismiss() }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 620)
    }
}

/// A2: what makes the iMac enough on its own, one row each (PWEOnlyIMacRules).
/// Shown always: it is most useful before a borrowed screen goes back.
struct PWEOnlyIMacSection: View {
    @ObservedObject var model: PWESenderModel
    let strings: PWEStrings

    var body: some View {
        Section(strings.onlyIMacTitle) {
            footnote(strings.onlyIMacBody)
            let inputs = model.onlyIMacInputs
            ForEach(PWEOnlyIMacRules.Row.allCases) { row in
                LabeledContent {
                    control(row, PWEOnlyIMacRules.state(row, inputs))
                } label: {
                    Text(strings.onlyIMacRow(row))
                }
            }
        }
        .onAppear { model.refreshSharingState() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshSharingState()
        }
    }

    @ViewBuilder
    private func control(_ row: PWEOnlyIMacRules.Row, _ state: PWEOnlyIMacRules.State) -> some View {
        switch state {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel(strings.passed)
        case .turnOn:
            Button(strings.turnOn) { model.fixOnlyIMac(row) }
        case .openSettings:
            Button(strings.open) { model.fixOnlyIMac(row) }
        case .check:
            Button(strings.checkInSystemSettings) { model.fixOnlyIMac(row) }
        case .moveToApplications:
            Text(strings.launchAtLoginMove)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Keyboard & Mouse

struct PWEInputSettings: View {
    @ObservedObject var model: PWESenderModel
    let strings: PWEStrings

    var body: some View {
        Form {
            Section {
                Picker(selection: $model.inputRole) {
                    ForEach(PWEInputRole.allCases) { role in
                        Text(strings.inputRoleName(role)).tag(role)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(strings.inputTitle)
                        ExperimentalBadge(text: strings.experimental)
                    }
                }
                .pickerStyle(.radioGroup)
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    footnote(strings.inputHint)
                    footnote(strings.inputNeedsEncryption)
                }
            }
            // A permission appears only while it is missing; one the iMac has not
            // reported yet is not shown as missing.
            let missing = missingPermissions
            if !missing.isEmpty {
                Section {
                    ForEach(missing) { permission in
                        LabeledContent {
                            if let open = permission.open { Button(strings.open, action: open) }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .foregroundStyle(.orange)
                                    .accessibilityHidden(true)
                                Text(strings.permissionMissing(permission.setting))
                            }
                            Text(permission.onIMac ? strings.iMacPermissionHint(permission.setting) : strings.onThisMac)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 360)
    }

    private struct Permission: Identifiable {
        let setting: String
        let onIMac: Bool
        /// Opens the right pane of System Settings; nil for the iMac's.
        let open: (() -> Void)?
        var id: String { "\(onIMac)-\(setting)" }
    }

    private var missingPermissions: [Permission] {
        var missing: [Permission] = []
        switch model.inputRole {
        case .off:
            break
        case .macControlsIMac:
            if !model.thisMacInputMonitoring {
                missing.append(Permission(setting: strings.inputMonitoring, onIMac: false,
                                          open: model.openInputMonitoringSettings))
            }
            if model.iMacAccessibility == false {
                missing.append(Permission(setting: strings.accessibility, onIMac: true, open: nil))
            }
        case .iMacControlsMac:
            if !model.thisMacAccessibility {
                missing.append(Permission(setting: strings.accessibility, onIMac: false,
                                          open: model.openAccessibilitySettings))
            }
            if model.iMacInputMonitoring == false {
                missing.append(Permission(setting: strings.inputMonitoring, onIMac: true, open: nil))
            }
        }
        return missing
    }
}

// MARK: - Advanced

struct PWEAdvancedSettings: View {
    @ObservedObject var model: PWESenderModel
    let strings: PWEStrings
    var openConsole: () -> Void = {}

    @State private var checks: [PWESenderModel.Check] = []
    /// Check Setup was pressed: from then on the list follows the connection.
    @State private var checking = false
    @ObservedObject private var navigation = PWESettingsNavigation.shared
    @State private var forgetting: PWEPairedReceiver?

    var body: some View {
        Form {
            Section(strings.pairedIMacs) {
                if model.pairedIMacs.isEmpty {
                    Text(strings.noPairedIMacs).foregroundStyle(.secondary)
                } else {
                    ForEach(model.pairedIMacs) { paired in
                        LabeledContent {
                            Button(strings.forget) { forgetting = paired }
                        } label: {
                            Label(paired.name, systemImage: "desktopcomputer")
                            Text(strings.pairedOn(paired.pairedAt))
                        }
                    }
                }
                if let name = model.forgetFailure {
                    PWENote(strings.forgetFailed(name), symbol: "exclamationmark.triangle.fill")
                }
            }
            Section {
                Toggle(isOn: $model.allowUnencrypted) {
                    Text(strings.allowUnencrypted)
                    Text(strings.allowUnencryptedHint)
                }
            }
            Section {
                Toggle(isOn: $model.networkLinkEnabled) {
                    HStack(spacing: 6) {
                        Text(strings.networkLink)
                        ExperimentalBadge(text: strings.experimental)
                    }
                    Text(strings.networkLinkHint)
                }
                if model.networkLinkEnabled {
                    Picker(strings.connectOver, selection: $model.connection) {
                        ForEach(PWEConnection.allCases) { connection in
                            Text(strings.connectionName(connection)).tag(connection)
                        }
                    }
                }
                Picker(selection: $model.rendering) {
                    ForEach(PWERendering.allCases) { rendering in
                        Text(strings.renderingName(rendering)).tag(rendering)
                    }
                } label: {
                    Text(strings.iMacRendering)
                    Text(strings.changesReconnect)
                }
                Toggle(isOn: $model.largeCursor) {
                    Text(strings.largeCursor)
                    Text(strings.changesReconnect)
                }
            }
            Section(strings.diagnostics) {
                LabeledContent {
                    Button(strings.checkSetup, action: checkSetup)
                } label: {
                    Text(strings.checkSetupLabel)
                }
                ForEach(checks) { check in
                    LabeledContent {
                        Image(systemName: check.passed == true ? "checkmark.circle.fill"
                              : check.passed == false ? "exclamationmark.circle.fill" : "clock")
                            .foregroundStyle(check.passed == true ? .green : check.passed == false ? .orange : .secondary)
                            .accessibilityLabel(check.passed == true ? strings.passed
                                                : check.passed == false ? strings.needsAttention : strings.afterConnecting)
                    } label: {
                        Text(check.title)
                        Text(check.detail)
                    }
                }
                LabeledContent {
                    Button(strings.exportReport) {
                        PWELogExport.save(header: model.diagnosticReportHeader(), suggestedName: "PWE Screen Encore report.txt")
                    }
                } label: {
                    Text(strings.reportLabel)
                    Text(strings.exportReportHint)
                }
            }
            Section {
                LabeledContent {
                    Button(strings.open, action: openConsole)
                } label: {
                    Text(strings.consoleTitle)
                    Text(strings.openConsoleHint)
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 640)
        .onAppear {
            model.refreshPairedIMacs()
            if navigation.checkSetup { checkSetup() }
        }
        // Asked from the main window while Advanced is already showing.
        .onChange(of: navigation.checkSetup) { _, asked in
            if asked { checkSetup() }
        }
        // A list taken before connecting says "after connecting" for half its
        // lines: once shown, it is taken again whenever the connection moves.
        .onChange(of: model.phase) {
            if checking { checks = model.configurationChecks() }
        }
        // The iMac travels with the alert (`presenting:`). Dismissing sets the
        // binding to false before a button's action runs, and the setter clears
        // `forgetting`: an action reading `forgetting` saw nil and forgot
        // nothing (T37, test Mac 2026-10-21).
        .alert(forgetting.map { strings.forgetConfirm($0.name) } ?? "", isPresented: Binding(
            get: { forgetting != nil },
            set: { if !$0 { forgetting = nil } }
        ), presenting: forgetting) { paired in
            Button(strings.forget, role: .destructive) { model.forget(paired) }
            Button(strings.cancel, role: .cancel) {}
        }
    }

    private func checkSetup() {
        navigation.checkSetup = false
        checking = true
        checks = model.configurationChecks()
    }
}
