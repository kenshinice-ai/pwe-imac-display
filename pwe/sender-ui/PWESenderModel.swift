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

/// When the remembered iMac's Thunderbolt Bridge address counts as a replug.
/// The iMac can stay listed through Wi-Fi while the cable is out, so it never
/// disappears; its bridge address leaving and coming back is the replug.
enum PWEReplugRules {
    enum BridgeChange: Equatable {
        case none
        case lost        // the bridge address went away
        case replugged   // it came back, or changed
    }

    /// A bridge address gone for less than this is a Bonjour update, not a cable.
    static let minimumLoss: TimeInterval = 2

    static func bridgeChange(from old: String, to new: String, lostAt: Date?, now: Date) -> BridgeChange {
        if old == new { return .none }
        if new.isEmpty { return .lost }
        if old.isEmpty, let lostAt, now.timeIntervalSince(lostAt) < minimumLoss { return .none }
        return .replugged
    }
}

/// Where this Mac's sound plays while the iMac is its display.
enum PWESound: String, CaseIterable, Identifiable {
    case onlyIMac, both, onlyThisMac
    var id: String { rawValue }
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
    /// While the iMac plays this Mac's sound, keep the Mac's own speakers muted
    /// (PWESound.onlyIMac rather than .both).
    @Published private var soundOnlyOnIMac: Bool {
        didSet { defaults.set(soundOnlyOnIMac, forKey: Keys.soundOnlyOnIMac) }
    }
    @Published private(set) var launchAtLogin = false
    @Published private(set) var launchAtLoginNeedsApproval = false

    let service: TBDisplaySenderService?
    private let defaults: UserDefaults
    private var localMute: PWELocalAudioMute?
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
    /// The remembered iMac's bridge address at the last look, and when it went away.
    private var preferredBridgeIP = ""
    private var bridgeLostAt: Date?
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
        /// [receiver identity: TBDisplayCapturePreset raw value]
        static let pictures = "pwe.pictures"
        static let soundOnlyOnIMac = "pwe.soundOnlyOnIMac"
    }

    /// What the Picture menu offers. A preset chosen in Advanced shows up too.
    static let pictureChoices: [TBDisplayCapturePreset] = [.standard1440p, .native5k, .native5k60Experimental]

    init(service: TBDisplaySenderService, defaults: UserDefaults = .standard) {
        self.service = service
        self.defaults = defaults
        self.autoConnect = defaults.object(forKey: Keys.autoConnect) as? Bool ?? true
        self.displayMode = PWEDisplayMode(rawValue: defaults.string(forKey: Keys.displayMode) ?? "") ?? .extended
        self.soundOnlyOnIMac = defaults.object(forKey: Keys.soundOnlyOnIMac) as? Bool ?? true
        self.localMute = PWELocalAudioMute(defaults: defaults)
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
        // Quitting while the iMac plays the sound must give the Mac its speakers back.
        NotificationCenter.default
            .publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in self?.localMute?.release() }
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
        self.soundOnlyOnIMac = true
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
        rememberShowingPicture()
        localMute?.update(mute: soundOnlyOnIMac && isRelayingSound)
        watchForReplug(service)
    }

    /// The picture is up with sound relayed: the iMac is playing this Mac's audio.
    private var isRelayingSound: Bool {
        guard let session else { return false }
        return session.isStreaming && session.audioEnabled && session.audioAddonAvailable
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
        // The engine applies this after the receiver's saved display profile, on
        // every attempt of this connection: reconnects, replugs and wakes alike.
        if let preset = rememberedPicture(for: receiverKey) {
            components.queryItems?.append(URLQueryItem(name: "preset", value: preset.rawValue))
        }
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
    /// while it was still there. Its bridge address coming back or changing is
    /// a replug too: with Wi-Fi on, the iMac stays listed while the cable is out.
    private func watchForReplug(_ service: TBDisplaySenderService) {
        guard let id = session?.selectedReceiverID, !id.isEmpty else { return }
        let receiver = service.discoveredReceivers.first { $0.matchesPersistedIdentity(id) }
        let present = receiver != nil
        let bridgeIP = receiver?.thunderboltIP ?? ""
        let bridge = PWEReplugRules.bridgeChange(from: preferredBridgeIP, to: bridgeIP, lostAt: bridgeLostAt, now: Date())
        defer {
            preferredWasPresent = present
            preferredBridgeIP = bridgeIP
        }
        guard !asleep, Date().timeIntervalSince(awokeAt) >= Self.wakeSettleTime else {
            bridgeLostAt = nil
            return
        }
        if !present, preferredWasPresent { pausedUntilReplug = false }
        if present, !preferredWasPresent { resumeIfDue(reason: "the iMac reappeared") }
        switch bridge {
        case .none:
            break
        case .lost:
            bridgeLostAt = Date()
        case .replugged:
            bridgeLostAt = nil
            pausedUntilReplug = false
            resumeIfDue(reason: "the iMac's Thunderbolt Bridge address came back (\(bridgeIP))")
        }
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

    // MARK: - Picture

    /// The receiver the Picture choice belongs to: the one on screen, or the
    /// session's remembered one while it is briefly out of the list.
    private var receiverKey: String? {
        if let service, let target = current(service) { return target.id }
        guard let id = session?.selectedReceiverID, !id.isEmpty else { return nil }
        return id
    }

    private func rememberedPicture(for key: String?) -> TBDisplayCapturePreset? {
        guard let key, let raw = (defaults.dictionary(forKey: Keys.pictures) as? [String: String])?[key] else { return nil }
        return TBDisplayCapturePreset(rawValue: raw)
    }

    private func remember(_ preset: TBDisplayCapturePreset, for key: String) {
        var pictures = defaults.dictionary(forKey: Keys.pictures) as? [String: String] ?? [:]
        guard pictures[key] != preset.rawValue else { return }
        pictures[key] = preset.rawValue
        defaults.set(pictures, forKey: Keys.pictures)
        NSLog("[pwe] remembered picture \(preset.rawValue) for \(key)")
    }

    /// Whatever showed a picture last is what this iMac gets next time, however
    /// it was chosen: here, in Advanced, or by URL. Upstream remembers only a
    /// display profile per receiver, and its Work 5K profile is 48 Hz, so 5K 60
    /// came back as 48 after every reconnect (iMac18,3 baseline, 2026-10-19).
    private func rememberShowingPicture() {
        guard let session, session.isStreaming, case .captureActive = session.statusState,
              let key = receiverKey else { return }
        remember(session.capturePreset, for: key)
    }

    /// The stream preset for this iMac. Changing it while connected reconnects.
    var picture: TBDisplayCapturePreset {
        get { rememberedPicture(for: receiverKey) ?? session?.capturePreset ?? .standard1440p }
        set {
            guard let key = receiverKey, newValue != picture else { return }
            remember(newValue, for: key)
            objectWillChange.send()
            reconnectIfShowing(because: "picture changed to \(newValue.rawValue)")
        }
    }

    /// A choice the engine reads only when a connection starts: start it again.
    private func reconnectIfShowing(because reason: String) {
        guard let session else { return }
        if session.isConnected || session.isStreaming {
            NSLog("[pwe] \(reason); reconnecting")
            session.stopForAutomaticReconnect()
            startConnecting()
        } else if TBSenderAutomation.isConnectingAutomatically {
            startConnecting()  // the retry loop holds the old settings
        }
    }

    var pictureChoices: [TBDisplayCapturePreset] {
        Self.pictureChoices.contains(picture) ? Self.pictureChoices : Self.pictureChoices + [picture]
    }

    // MARK: - Connected controls

    var brightness: Double {
        get { session?.brightness ?? 1 }
        set { session?.brightness = newValue; objectWillChange.send() }
    }

    /// Offered only with the audio add-on; without it the sound stays on this Mac.
    var soundAvailable: Bool { service?.audioRelayAvailable ?? true }

    /// Relay on or off is the engine's `audioEnabled`; muting this Mac is PWE's.
    var sound: PWESound {
        get {
            guard session?.audioEnabled ?? true else { return .onlyThisMac }
            return soundOnlyOnIMac ? .onlyIMac : .both
        }
        set {
            guard newValue != sound else { return }
            let relayWasOn = session?.audioEnabled ?? true
            if newValue != .onlyThisMac { soundOnlyOnIMac = newValue == .onlyIMac }
            session?.audioEnabled = newValue != .onlyThisMac
            objectWillChange.send()
            refresh()
            // The engine opens its audio capture only if relay was on when the
            // picture started; turning relay off takes effect at once.
            if !relayWasOn, newValue != .onlyThisMac {
                reconnectIfShowing(because: "sound now relayed to the iMac")
            }
        }
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
