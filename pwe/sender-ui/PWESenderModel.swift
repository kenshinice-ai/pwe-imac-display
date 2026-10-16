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

/// Everything the window's phase depends on, read from the engine in one go.
struct PWEEngineState {
    var hasPermission = true
    /// The first session's status; nil before the engine has a session.
    var status: TBDisplaySenderStatusState?
    var isConnected = false
    var isStreaming = false
    /// The engine is keeping a connection up and retries it by itself.
    var retrying = false
    var receivers: [PWEReceiver] = []
    var target: PWEReceiver?
}

/// Engine state in, phase out: no engine, no clock, so every rule has a test
/// (PWEPhaseRulesTests).
enum PWEPhaseRules {
    /// What a status says went wrong, if anything.
    static func failure(_ status: TBDisplaySenderStatusState) -> PWEReason? {
        switch status {
        case .connectionFailed: return .couldNotConnect
        case .connectionClosed: return .cableOrReceiverGone
        case .receiverClosedDuringCapture, .receiverClosedConnection, .receiverTerminatedSession: return .receiverQuit
        case .virtualDisplayCreationFailed, .captureError, .captureDesktopError,
             .noShareableDisplay, .hevcNoFrames, .noFirstFrame: return .captureFailed
        case .ready, .stopped, .connecting, .testingCable, .waitingDisplayProfile, .creatingVirtualDisplay,
             .startingCapture, .captureStartedWaitingFirstFrame, .captureActive: return nil
        }
    }

    /// The failure to keep on screen while the engine retries. Between attempts
    /// the engine resets the session to "stopped" and starts over; without this
    /// the window would flash Ready and Connecting every two seconds.
    static func heldFailure(after previous: PWEReason?, _ state: PWEEngineState) -> PWEReason? {
        guard state.retrying, !state.isStreaming else { return nil }
        if let status = state.status {
            if case .captureActive = status { return nil }
            if let reason = failure(status) { return reason }
        }
        return previous
    }

    static func phase(_ state: PWEEngineState, held: PWEReason?) -> PWEPhase {
        guard state.hasPermission else { return .needsPermission }
        let target = state.target

        if let status = state.status {
            switch status {
            case .connecting, .testingCable:
                // A retry reaching for an iMac that just failed: still the same failure.
                if state.retrying, let held { return .interrupted(target, held, retrying: true) }
                return .connecting(target, .reaching)
            case .waitingDisplayProfile, .creatingVirtualDisplay, .startingCapture:
                return .connecting(target, .preparing)
            case .captureStartedWaitingFirstFrame:
                return .connecting(target, .waitingForPicture)
            case .captureActive:
                return .connected(target)
            case .ready, .stopped:
                break
            default:
                if let reason = failure(status) {
                    return .interrupted(target, reason, retrying: state.retrying)
                }
            }
            if state.isStreaming { return .connected(target) }
            if state.isConnected { return .connecting(target, .preparing) }
        }

        if state.retrying {
            if let held { return .interrupted(target, held, retrying: true) }
            if state.receivers.isEmpty { return .interrupted(target, .cableOrReceiverGone, retrying: true) }
            return .connecting(target, .reaching)
        }
        if let target { return .ready(target) }
        if state.receivers.count > 1 { return .choose(state.receivers) }
        return .searching
    }
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
    /// The last failure while the engine retries (PWEPhaseRules.heldFailure).
    private var heldFailure: PWEReason?
    /// Whether the engine was retrying at the last look. When it stops without
    /// PWE asking (a Stop from the menu bar, a capture failure), that counts as
    /// the person's Disconnect: nothing resumes until the iMac is replugged.
    private var wasRetrying = false
    /// Set when the person disconnects; cleared when their iMac disappears, so the
    /// next time the cable goes in it connects again.
    private var pausedUntilReplug = false
    private var preferredWasPresent = false
    /// The launch-time connection runs once per process, not once per window.
    private var didStartOnLaunch = false
    /// Sleep takes the Thunderbolt link down and wake brings it back, so the iMac
    /// leaves and rejoins Bonjour. That is not a replug and must not undo a
    /// Disconnect; ignore the iMac coming and going until the link has settled.
    private var asleep = false
    private var awokeAt = Date.distantPast
    private static let wakeSettleTime: TimeInterval = 15

    enum Keys {
        static let autoConnect = "pwe.autoConnect"
        static let displayMode = "pwe.displayMode"
        static let askedForScreenRecording = "pwe.askedForScreenRecording"
    }

    init(service: TBDisplaySenderService, defaults: UserDefaults = .standard) {
        self.service = service
        self.defaults = defaults
        self.autoConnect = defaults.object(forKey: Keys.autoConnect) as? Bool ?? true
        self.displayMode = PWEDisplayMode(rawValue: defaults.string(forKey: Keys.displayMode) ?? "") ?? .extended
        refreshLaunchAtLogin()

        service.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.observeSessions()
                self?.refresh()
            }
            .store(in: &cancellables)
        NotificationCenter.default
            .publisher(for: TBSenderAutomation.automaticConnectionDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        // Coming back from System Settings is when a permission or a login item
        // changes; check then, so nobody has to press "I have allowed it".
        NotificationCenter.default
            .publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                self?.recheckPermission()
                self?.refreshLaunchAtLogin()
            }
            .store(in: &cancellables)
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.willSleepNotification)
            .sink { [weak self] _ in self?.asleep = true }
            .store(in: &cancellables)
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in self?.didWake() }
            .store(in: &cancellables)
        observeSessions()
        refresh()
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

    private func refresh() {
        guard let service else { return }
        let retrying = TBSenderAutomation.isConnectingAutomatically
        if wasRetrying, !retrying, !pausedUntilReplug {
            NSLog("[pwe] the engine stopped retrying; waiting for a replug")
            pausedUntilReplug = true
        }
        wasRetrying = retrying

        let state = engineState(service, retrying: retrying)
        heldFailure = PWEPhaseRules.heldFailure(after: heldFailure, state)
        let next = PWEPhaseRules.phase(state, held: heldFailure)
        if next != phase { phase = next }
        watchForReplug(service)
    }

    private func observeSessions() {
        sessionCancellables.removeAll()
        for session in service?.sessions ?? [] {
            session.objectWillChange
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.refresh() }
                .store(in: &sessionCancellables)
        }
    }

    private func engineState(_ service: TBDisplaySenderService, retrying: Bool) -> PWEEngineState {
        PWEEngineState(
            hasPermission: CGPreflightScreenCaptureAccess(),
            status: session?.statusState,
            isConnected: session?.isConnected ?? false,
            isStreaming: session?.isStreaming ?? false,
            retrying: retrying,
            receivers: receivers(service),
            target: current(service))
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
        heldFailure = nil
        var components = URLComponents()
        components.scheme = "pweimacdisplay"
        components.host = "connect"
        components.queryItems = [
            URLQueryItem(name: "receiver", value: "auto"),
            URLQueryItem(name: "mode", value: displayMode == .extended ? "extended" : "mirror"),
            URLQueryItem(name: "retry", value: autoConnect ? "1" : "0"),
        ]
        if let url = components.url { TBSenderAutomation.handle(url: url) }
        // The engine has started (or, with retry=0, ended) its retrying already;
        // that change is ours, not one to read as a Disconnect.
        wasRetrying = TBSenderAutomation.isConnectingAutomatically
        refresh()
    }

    func disconnect() {
        pausedUntilReplug = true
        heldFailure = nil
        session?.stop()  // the engine's Stop also ends its retrying
        wasRetrying = TBSenderAutomation.isConnectingAutomatically
        refresh()
    }

    func stopRetrying() { disconnect() }

    /// On launch: if a receiver was used before and the person wants it, keep it
    /// connected. Each new window asks; only the first ask counts.
    func startIfDue() {
        guard !didStartOnLaunch else { return }
        didStartOnLaunch = true
        resumeIfDue(reason: "launch")
    }

    private func resumeIfDue(reason: String) {
        guard autoConnect, !pausedUntilReplug, !TBSenderAutomation.isConnectingAutomatically,
              CGPreflightScreenCaptureAccess(),
              let session, !session.isConnected, !session.isStreaming,
              !session.selectedReceiverID.isEmpty else { return }
        NSLog("[pwe] resuming automatic connection after \(reason)")
        startConnecting()
    }

    private func didWake() {
        asleep = false
        awokeAt = Date()
        resumeIfDue(reason: "wake")
        // The iMac usually rejoins only after the settle time; look again then.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.wakeSettleTime))
            self?.resumeIfDue(reason: "wake")
        }
    }

    /// The remembered iMac disappearing means the cable came out or the iMac
    /// went away; when it comes back, connect again unless the person said stop
    /// while it was still there.
    private func watchForReplug(_ service: TBDisplaySenderService) {
        guard let id = session?.selectedReceiverID, !id.isEmpty else { return }
        let present = service.discoveredReceivers.contains { $0.matchesPersistedIdentity(id) }
        defer { preferredWasPresent = present }
        guard !asleep, Date().timeIntervalSince(awokeAt) >= Self.wakeSettleTime else { return }
        if !present, preferredWasPresent { pausedUntilReplug = false }
        if present, !preferredWasPresent { resumeIfDue(reason: "the iMac reappeared") }
    }

    // MARK: - Permission

    /// The first press asks macOS, which shows its own prompt with a way into
    /// System Settings; asking again shows nothing, so later presses open
    /// System Settings directly. Doing both at once put two prompts on screen.
    func requestScreenRecording() {
        if defaults.bool(forKey: Keys.askedForScreenRecording) {
            service?.openScreenRecordingSettings()
        } else {
            defaults.set(true, forKey: Keys.askedForScreenRecording)
            service?.requestScreenRecordingPermission()
        }
    }

    func recheckPermission() {
        service?.refreshPrivacyPermissions()
        refresh()
    }

    func restartForPermission() { service?.restartAfterPermissionChange() }

    // MARK: - Connected controls

    var brightness: Double {
        get { session?.brightness ?? 1 }
        set { session?.brightness = newValue; objectWillChange.send() }
    }

    /// Sound is relayed only if it was on when the picture started, so the
    /// switch is offered before connecting, and only with the audio add-on.
    var soundAvailable: Bool { service?.audioRelayAvailable ?? true }

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
