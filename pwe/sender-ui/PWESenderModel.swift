import AppKit
import Combine
import Foundation
import ServiceManagement

/// What the PWE window shows, derived from TargetBridge's engine and nothing else.
///
/// The PWE layer never drives the pipeline itself: connecting goes through the
/// engine's own automation path (`TBSenderAutomation`), which already waits for a
/// remembered receiver, refuses to guess between several, and retries a lost link.
/// This type only translates engine state into the four questions a person has —
/// is my iMac there, is it connecting, is it showing my screen, and if not, why.
struct PWEReceiver: Equatable, Identifiable {
    let id: String
    let name: String
    let detail: String
}

enum PWEStage: Equatable {
    case reaching        // TCP to the receiver
    case preparing       // receiver profile, virtual display
    case waitingForPicture
}

enum PWEReason: Equatable {
    case cableOrReceiverGone
    case receiverQuit
    case couldNotConnect
    case captureFailed
    case other
}

enum PWEPhase: Equatable {
    case needsPermission
    case searching
    case choose([PWEReceiver])
    case ready(PWEReceiver)
    case connecting(PWEReceiver?, PWEStage)
    case connected(PWEReceiver?)
    case interrupted(PWEReceiver?, PWEReason, retrying: Bool)
}

enum PWEDisplayMode: String, CaseIterable, Identifiable {
    case extended, mirror
    var id: String { rawValue }
}

@MainActor
final class PWESenderModel: ObservableObject {
    @Published private(set) var phase: PWEPhase = .searching
    @Published var autoConnect: Bool {
        didSet { defaults.set(autoConnect, forKey: Keys.autoConnect) }
    }
    @Published var displayMode: PWEDisplayMode {
        didSet { defaults.set(displayMode.rawValue, forKey: Keys.displayMode) }
    }
    @Published private(set) var launchAtLogin = false
    @Published private(set) var launchAtLoginNeedsApproval = false

    let service: TBDisplaySenderService?
    private let defaults: UserDefaults
    private var cancellables: Set<AnyCancellable> = []
    private var sessionCancellables: Set<AnyCancellable> = []
    /// True while the engine is retrying on our behalf, from the moment we ask it
    /// to keep a connection up until the person disconnects.
    private var keepingConnected = false
    /// Set when the person disconnects; cleared when their iMac disappears, so the
    /// next time the cable goes in it connects again.
    private var pausedUntilReplug = false
    private var preferredWasPresent = false

    enum Keys {
        static let autoConnect = "pwe.autoConnect"
        static let displayMode = "pwe.displayMode"
    }

    init(service: TBDisplaySenderService, defaults: UserDefaults = .standard) {
        self.service = service
        self.defaults = defaults
        self.autoConnect = defaults.object(forKey: Keys.autoConnect) as? Bool ?? true
        self.displayMode = PWEDisplayMode(rawValue: defaults.string(forKey: Keys.displayMode) ?? "") ?? .extended
        refreshLaunchAtLogin()

        service.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.engineChanged() }
            .store(in: &cancellables)
        // Coming back from System Settings is when a permission changes; check
        // then, so nobody has to press "I have allowed it".
        NotificationCenter.default
            .publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.recheckPermission() }
            .store(in: &cancellables)
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in self?.resumeIfDue(reason: "wake") }
            .store(in: &cancellables)
        engineChanged()
    }

    /// A fixed phase for snapshots: no engine, nothing changes.
    init(preview phase: PWEPhase) {
        self.service = nil
        self.defaults = UserDefaults(suiteName: "pwe.preview") ?? .standard
        self.autoConnect = true
        self.displayMode = .extended
        self.phase = phase
    }

    // MARK: - Reading the engine

    private var session: TBDisplaySenderSession? { service?.sessions.first }

    private func engineChanged() {
        guard let service else { return }
        observeSessions()
        let next = computePhase(service)
        if next != phase { phase = next }
        watchForReplug(service)
    }

    private func observeSessions() {
        sessionCancellables.removeAll()
        for session in service?.sessions ?? [] {
            session.objectWillChange
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    guard let self, let service = self.service else { return }
                    let next = self.computePhase(service)
                    if next != self.phase { self.phase = next }
                }
                .store(in: &sessionCancellables)
        }
    }

    private func receivers(_ service: TBDisplaySenderService) -> [PWEReceiver] {
        service.discoveredReceivers.map {
            PWEReceiver(id: $0.stableIdentity, name: $0.receiverName.isEmpty ? $0.serviceName : $0.receiverName,
                        detail: $0.panelSummary)
        }
    }

    private func current(_ service: TBDisplaySenderService) -> PWEReceiver? {
        let all = receivers(service)
        if let id = session?.selectedReceiverID, !id.isEmpty,
           let match = service.discoveredReceivers.first(where: { $0.matchesPersistedIdentity(id) }) {
            return all.first { $0.id == match.stableIdentity }
        }
        return all.count == 1 ? all[0] : nil
    }

    private func computePhase(_ service: TBDisplaySenderService) -> PWEPhase {
        if !CGPreflightScreenCaptureAccess() { return .needsPermission }
        let target = current(service)

        if let session {
            switch session.statusState {
            case .connecting, .testingCable:
                return .connecting(target, .reaching)
            case .waitingDisplayProfile, .creatingVirtualDisplay, .startingCapture:
                return .connecting(target, .preparing)
            case .captureStartedWaitingFirstFrame:
                return .connecting(target, .waitingForPicture)
            case .captureActive:
                return .connected(target)
            case .connectionFailed:
                if keepingConnected { return .interrupted(target, .couldNotConnect, retrying: true) }
            case .connectionClosed:
                if keepingConnected { return .interrupted(target, .cableOrReceiverGone, retrying: true) }
            case .receiverClosedDuringCapture, .receiverClosedConnection, .receiverTerminatedSession:
                if keepingConnected { return .interrupted(target, .receiverQuit, retrying: true) }
            case .virtualDisplayCreationFailed, .captureError, .captureDesktopError,
                 .noShareableDisplay, .hevcNoFrames, .noFirstFrame:
                return .interrupted(target, .captureFailed, retrying: keepingConnected)
            case .ready, .stopped:
                break
            }
            if session.isStreaming { return .connected(target) }
            if session.isConnected { return .connecting(target, .preparing) }
        }

        let all = receivers(service)
        if keepingConnected, all.isEmpty {
            return .interrupted(target, .cableOrReceiverGone, retrying: true)
        }
        if let target { return .ready(target) }
        if all.count > 1 { return .choose(all) }
        return .searching
    }

    // MARK: - Actions

    func connect(to receiver: PWEReceiver) {
        guard let service else { return }
        if service.sessions.isEmpty { service.addSession() }
        guard let session = service.sessions.first,
              let discovered = service.discoveredReceivers.first(where: { $0.stableIdentity == receiver.id })
        else { return }
        service.applyDiscoveredReceiver(discovered, to: session)
        startConnecting()
    }

    /// Hands the connection to the engine: `receiver=auto` with the receiver we
    /// just selected as the preferred one, so the engine never picks another Mac.
    private func startConnecting() {
        pausedUntilReplug = false
        keepingConnected = autoConnect
        var components = URLComponents()
        components.scheme = "pweimacdisplay"
        components.host = "connect"
        components.queryItems = [
            URLQueryItem(name: "receiver", value: "auto"),
            URLQueryItem(name: "mode", value: displayMode == .extended ? "extended" : "mirror"),
            URLQueryItem(name: "retry", value: autoConnect ? "1" : "0"),
        ]
        if let url = components.url { TBSenderAutomation.handle(url: url) }
        engineChanged()
    }

    func disconnect() {
        keepingConnected = false
        pausedUntilReplug = true
        session?.stop()
        engineChanged()
    }

    func stopRetrying() { disconnect() }

    /// On launch: if a receiver was used before and the person wants it, keep it connected.
    func startIfDue() {
        guard autoConnect, CGPreflightScreenCaptureAccess(),
              let id = session?.selectedReceiverID, !id.isEmpty else { return }
        startConnecting()
    }

    private func resumeIfDue(reason: String) {
        guard autoConnect, !pausedUntilReplug, !keepingConnected,
              let session, !session.isConnected, !session.isStreaming,
              !session.selectedReceiverID.isEmpty else { return }
        NSLog("[pwe] resuming automatic connection after \(reason)")
        startConnecting()
    }

    /// The remembered iMac disappearing means the cable came out or the iMac
    /// went away; when it comes back, connect again unless the person said stop
    /// while it was still there.
    private func watchForReplug(_ service: TBDisplaySenderService) {
        guard let id = session?.selectedReceiverID, !id.isEmpty else { return }
        let present = service.discoveredReceivers.contains { $0.matchesPersistedIdentity(id) }
        defer { preferredWasPresent = present }
        if !present, preferredWasPresent { pausedUntilReplug = false }
        if present, !preferredWasPresent { resumeIfDue(reason: "the iMac reappeared") }
    }

    // MARK: - Permission

    func requestScreenRecording() {
        service?.requestScreenRecordingPermission()
        service?.openScreenRecordingSettings()
    }

    func recheckPermission() {
        service?.refreshPrivacyPermissions()
        engineChanged()
    }

    func restartForPermission() { service?.restartAfterPermissionChange() }

    // MARK: - Connected controls

    var brightness: Double {
        get { session?.brightness ?? 1 }
        set { session?.brightness = newValue; objectWillChange.send() }
    }

    var soundOn: Bool {
        get { session?.audioEnabled ?? true }
        set { session?.audioEnabled = newValue; objectWillChange.send() }
    }

    func openDisplaySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Launch at login

    func refreshLaunchAtLogin() {
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled
        launchAtLoginNeedsApproval = status == .requiresApproval
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("[pwe] launch at login: \(error.localizedDescription)")
        }
        refreshLaunchAtLogin()
    }

    func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }
}
