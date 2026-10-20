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

    var body: some View {
        TabView {
            PWEGeneralSettings(model: model, updates: updates, strings: strings)
                .tabItem { Label(strings.general, systemImage: "gearshape") }
            PWEInputSettings(model: model, strings: strings)
                .tabItem { Label(strings.keyboardMouse, systemImage: "keyboard") }
            PWEAdvancedSettings(model: model, strings: strings, openConsole: {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "advanced")
            })
                .tabItem { Label(strings.advancedTab, systemImage: "gearshape.2") }
        }
        .frame(width: PWESettingsLayout.width)
        .overlay(alignment: .bottom) { PWEReconnectNotice(model: model, strings: strings) }
        .onAppear {
            PWEWindows.shared.openWindow = openWindow
            PWEWindows.shared.openSettings = openSettings
        }
    }
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

/// A small capsule next to a setting's name.
private struct ExperimentalBadge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.orange.opacity(0.12), in: Capsule())
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

    @AppStorage("pwe.updateChecks") private var dailyChecks = false

    var body: some View {
        Form {
            Section {
                Toggle(strings.launchAtLogin, isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }))
                if model.launchAtLoginNeedsApproval {
                    Button(strings.launchAtLoginApproval) { model.openLoginItemsSettings() }
                        .buttonStyle(.link)
                }
                Toggle(strings.autoConnect, isOn: $model.autoConnect)
            }
            Section {
                PWEBrightnessKeysSetting(language: strings.language)
            }
            Section {
                Toggle(strings.checkUpdatesDaily, isOn: $dailyChecks)
                // What the daily check found; checking by hand is in About.
                if let available = updates.available {
                    LabeledContent(strings.updateAvailable(available.version)) {
                        Link(strings.download, destination: UpdateCheck.downloadPage)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 300)
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
                    Button(strings.checkSetup) { checks = model.configurationChecks() }
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
                        PWELogExport.save(model.diagnosticReport(), suggestedName: "PWE iMac Display report.txt")
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
        .onAppear { model.refreshPairedIMacs() }
        .alert(forgetting.map { strings.forgetConfirm($0.name) } ?? "", isPresented: Binding(
            get: { forgetting != nil },
            set: { if !$0 { forgetting = nil } }
        )) {
            Button(strings.forget, role: .destructive) {
                if let forgetting { model.forget(forgetting) }
                forgetting = nil
            }
            Button(strings.cancel, role: .cancel) { forgetting = nil }
        }
    }
}
