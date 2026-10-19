import SwiftUI

/// PWE's one Settings window (⌘,): a standard grouped Form per tab, in the
/// system's appearance. It replaces upstream's settings window and the session
/// sheet of its dashboard; that dashboard is still reachable as the Full Console
/// from the Advanced tab.
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
            PWEDisplaySettings(model: model, strings: strings)
                .tabItem { Label(strings.display, systemImage: "display") }
            PWESoundSettings(model: model, strings: strings)
                .tabItem { Label(strings.sound, systemImage: "speaker.wave.2") }
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
    @State private var checking = false
    @State private var lastResult: String?

    var body: some View {
        Form {
            Section(strings.startup) {
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
                Toggle(strings.showMenuBarIcon, isOn: $model.showsMenuBarIcon)
            } footer: {
                if !model.showsMenuBarIcon { footnote(strings.showMenuBarIconHint) }
            }
            Section(strings.updates) {
                Toggle(strings.checkUpdatesDaily, isOn: $dailyChecks)
                HStack(spacing: 10) {
                    Button(strings.checkUpdates) { checkNow() }
                        .disabled(checking)
                    if checking { ProgressView().controlSize(.small) }
                    if let lastResult { Text(lastResult).foregroundStyle(.secondary) }
                    Spacer()
                    if updates.available != nil {
                        Link(strings.download, destination: UpdateCheck.downloadPage)
                    }
                }
            }
            Section {
            } footer: {
                footnote(strings.languageHint)
            }
        }
        .formStyle(.grouped)
        .frame(height: 400)
    }

    private func checkNow() {
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
}

// MARK: - Display

struct PWEDisplaySettings: View {
    @ObservedObject var model: PWESenderModel
    let strings: PWEStrings

    var body: some View {
        Form {
            Section {
                Picker(model.knownReceiverName.map(strings.pictureFor) ?? strings.picture, selection: $model.picture) {
                    ForEach(model.pictureChoices) { preset in
                        Text(strings.pictureName(preset)).tag(preset)
                    }
                }
                .disabled(model.knownReceiverName == nil)
                Picker(strings.modeLabel, selection: $model.displayMode) {
                    Text(strings.modeExtended).tag(PWEDisplayMode.extended)
                    Text(strings.modeMirror).tag(PWEDisplayMode.mirror)
                }
            } footer: {
                footnote(model.knownReceiverName == nil ? strings.noIMacYet : strings.pictureHint)
            }
            Section {
                Toggle(strings.keepAwake, isOn: $model.keepAwake)
                Toggle(isOn: $model.largeCursor) {
                    Text(strings.largeCursor)
                    Text(strings.changesReconnect)
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 340)
    }
}

// MARK: - Sound

struct PWESoundSettings: View {
    @ObservedObject var model: PWESenderModel
    let strings: PWEStrings

    var body: some View {
        Form {
            Section {
                Picker(strings.soundTitle, selection: $model.sound) {
                    ForEach(PWESound.allCases) { sound in
                        Text(strings.soundName(sound)).tag(sound)
                    }
                }
                .pickerStyle(.radioGroup)
            } footer: {
                footnote(strings.soundDetail(model.sound))
            }
            Section {
                LabeledContent(strings.iMacVolume) {
                    HStack(spacing: 8) {
                        Image(systemName: "speaker.fill").foregroundStyle(.secondary).accessibilityHidden(true)
                        Slider(value: $model.volume, in: 0...1)
                            .accessibilityLabel(strings.iMacVolume)
                        Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary).accessibilityHidden(true)
                    }
                    .frame(width: 220)
                }
                .disabled(!model.isShowing || model.sound == .onlyThisMac)
            } footer: {
                footnote(strings.iMacVolumeHint)
            }
        }
        .formStyle(.grouped)
        .frame(height: 320)
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
                footnote(strings.inputHint)
            }
            if model.inputRole != .off {
                Section(strings.permissionsNeeded) {
                    switch model.inputRole {
                    case .macControlsIMac:
                        thisMac(strings.inputMonitoring, allowed: model.thisMacInputMonitoring,
                                open: model.openInputMonitoringSettings)
                        iMac(strings.accessibility, allowed: model.iMacAccessibility)
                    case .iMacControlsMac:
                        thisMac(strings.accessibility, allowed: model.thisMacAccessibility,
                                open: model.openAccessibilitySettings)
                        iMac(strings.inputMonitoring, allowed: model.iMacInputMonitoring)
                    case .off:
                        EmptyView()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 400)
    }

    private func thisMac(_ setting: String, allowed: Bool, open: @escaping () -> Void) -> some View {
        LabeledContent {
            HStack(spacing: 10) {
                status(allowed)
                if !allowed { Button(strings.open, action: open) }
            }
        } label: {
            Text(setting)
            Text(strings.onThisMac)
        }
    }

    private func iMac(_ setting: String, allowed: Bool?) -> some View {
        LabeledContent {
            status(allowed)
        } label: {
            Text(setting)
            Text(strings.iMacPermissionHint(setting))
        }
    }

    @ViewBuilder private func status(_ allowed: Bool?) -> some View {
        switch allowed {
        case true?:
            Label(strings.allowed, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case false?:
            Label(strings.notAllowed, systemImage: "exclamationmark.circle.fill").foregroundStyle(.orange)
        case nil:
            Text(strings.unknownUntilConnected).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Advanced

struct PWEAdvancedSettings: View {
    @ObservedObject var model: PWESenderModel
    let strings: PWEStrings
    var openConsole: () -> Void = {}

    @State private var checks: [PWESenderModel.Check] = []

    var body: some View {
        Form {
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
            } header: {
                Text(strings.connectionSection)
            }
            Section {
                Picker(strings.compression, selection: $model.codec) {
                    ForEach(TBDisplayCodecPreference.allCases) { codec in
                        Text(strings.codecName(codec)).tag(codec)
                    }
                }
                Toggle(isOn: $model.renderMatching) {
                    Text(strings.renderMatching)
                    Text(strings.renderMatchingHint)
                }
                .disabled(!model.renderMatchingApplies)
            } header: {
                Text(strings.videoSection)
            } footer: {
                footnote(strings.changesReconnect)
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
                    } label: {
                        Text(check.title)
                        Text(check.detail)
                    }
                }
                LabeledContent {
                    HStack(spacing: 10) {
                        if model.isTestingCable { ProgressView().controlSize(.small) }
                        Text(strings.cableResult(model.cableRate)).foregroundStyle(.secondary)
                        Button(model.isTestingCable ? strings.cableTesting : strings.cableTest) { model.testCable() }
                            .disabled(!model.canTestCable)
                    }
                } label: {
                    Text(strings.cableLabel)
                    Text(strings.cableTestHint)
                }
                LabeledContent {
                    Button(strings.restartPicture) { model.restartPicture() }
                        .disabled(!model.canRestartPicture)
                } label: {
                    Text(strings.restartPictureLabel)
                }
                Toggle(strings.detailedLogging, isOn: $model.detailedLogging)
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
        .frame(height: 620)
    }
}
