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
    /// What the receiver reports: hardware HEVC decode and its panel's width.
    var supportsHEVC = false
    var panelWidth: Int?
    /// A PWE receiver (any version), not upstream's TargetBridge.
    var runsPWE = true
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
    /// Pairing, or a question about an unencrypted connection: the next step is the person's.
    case security(PWEReceiver?, PWESecurityState)
}

/// Everything the window's phase depends on, read from the engine in one go.
struct PWEEngineState {
    var hasPermission = true
    /// The first session's status; nil before the engine has a session.
    var status: TBDisplaySenderStatusState?
    var isConnected = false
    var isStreaming = false
    /// The current capture has sent its first encoded frame: the picture is up.
    var hasFirstFrame = false
    /// The engine is keeping a connection up and retries it by itself.
    var retrying = false
    var receivers: [PWEReceiver] = []
    var target: PWEReceiver?
    /// The session's pairing and encryption state.
    var security: PWESecurityState = .none
    /// Why the code step asks for a new code (PWEPairingRules.note).
    var codeNote: PWECodeNote?
}

extension PWEEngineState {
    /// What one engine session says. The model adds the permission, the
    /// retrying, the receivers and the stale-failure rule; the connection
    /// phase tests read a real session through this same initializer.
    @MainActor init(session: TBDisplaySenderSession?) {
        self.init()
        status = session?.statusState
        isConnected = session?.isConnected ?? false
        isStreaming = session?.isStreaming ?? false
        hasFirstFrame = session?.pweHasFirstFrame ?? false
        security = session?.pweSecurity ?? .none
    }
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
        // A pairing step ends a connection on purpose; it is not a failure to hold.
        guard state.retrying, !state.isStreaming, !asksPerson(state.security) else { return nil }
        if let status = state.status {
            if case .captureActive = status { return nil }
            if let reason = failure(status) { return reason }
        }
        return previous
    }

    /// Security states the window answers: a code to type, a question, a refusal.
    static func asksPerson(_ security: PWESecurityState) -> Bool {
        security.waitsForUser || security == .checkingCode
    }

    /// The engine keeps the last failure as its status until the next attempt
    /// dials. A connection the person just started must not show it: "no longer
    /// connected" flashed between Use as Display and Connecting (T28, test Mac
    /// 2026-10-20). `stale` describes the status at the press; while the status
    /// is still that one, it reads as connecting. Returns the status to use and
    /// whether it is still stale.
    static func freshStatus(_ status: TBDisplaySenderStatusState?, stale: String?)
        -> (status: TBDisplaySenderStatusState?, stillStale: Bool) {
        guard let stale, let status, String(describing: status) == stale else { return (status, false) }
        return (.connecting(""), true)
    }

    static func phase(_ state: PWEEngineState, held: PWEReason?) -> PWEPhase {
        guard state.hasPermission else { return .needsPermission }
        let target = state.target
        // Asking the iMac for a new code after a wrong or expired one.
        if let held = PWEPairingRules.holdsCodeStep(state.codeNote, state) { return .security(target, held) }
        // The engine closes the connection to ask, so its status reads as a failure;
        // the security state says what really happened.
        if asksPerson(state.security) { return .security(target, state.security) }

        if let status = state.status {
            // The picture is up: the engine streams and this capture has sent a
            // frame. A status that still reads connecting or "waiting for the
            // picture" is stale, never the truth (T33, test Mac 2026-10-20).
            if state.isStreaming, state.hasFirstFrame, failure(status) == nil { return .connected(target) }
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

extension PWEPhase {
    /// The phase in a few words, for the log.
    var logName: String {
        switch self {
        case .needsPermission: return "needsPermission"
        case .searching: return "searching"
        case .choose(let receivers): return "choose(\(receivers.count))"
        case .ready: return "ready"
        case .connecting(_, let stage): return "connecting(\(stage))"
        case .connected: return "connected"
        case .interrupted(_, let reason, let retrying): return "interrupted(\(reason)\(retrying ? ", retrying" : ""))"
        case .security(_, let security): return "security(\(security))"
        }
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

    /// The receiver's bridge address that marks a plug: its IPv6 link-local
    /// address when it announces one (T34), else its IPv4 one. The IPv6 address
    /// comes first after a plug and stays; the IPv4 address follows some 19 s
    /// later and is not a second plug.
    static func bridgeAddress(thunderboltIP: String, thunderboltIPv6: String) -> String {
        thunderboltIPv6.isEmpty ? thunderboltIP : thunderboltIPv6
    }

    static func bridgeChange(from old: String, to new: String, lostAt: Date?, now: Date) -> BridgeChange {
        if old == new { return .none }
        if new.isEmpty { return .lost }
        if old.isEmpty, let lostAt, now.timeIntervalSince(lostAt) < minimumLoss { return .none }
        return .replugged
    }
}

/// How often the model may look at system state that costs a query (B11):
/// at most once per `interval`. While connected, the Mac Studio showed about
/// 2 TCC queries, 10 preference reads and 3 LaunchServices queries a second
/// (2026-10-24), from refreshes the engine's fps counter set off every second.
enum PWEPollRules {
    static let interval: TimeInterval = 5

    static func isDue(lastAt: TimeInterval?, now: TimeInterval, every interval: TimeInterval = interval) -> Bool {
        guard let lastAt, now >= lastAt else { return true }
        return now - lastAt >= interval
    }
}

/// T54: what a connect URL from outside does (PWESenderModel.handleConnectURL).
/// A plain automatic one (no named receiver, transport, path or session) for
/// the iMac PWE already knows is PWE's to apply: like the Picture menu, a
/// changed picture or display mode reconnects to apply it, an unchanged one
/// does nothing, and with no connection it connects under PWE's own rules
/// (retrying when "connect automatically" is on; a `retry` in the URL is not
/// read). Anything else keeps upstream's handling (PWEConnectURLTests).
enum PWEConnectURLRules {
    enum Plan: Equatable { case notOurs, nothing, reconnect, connect }

    static func isPlainAutomatic(_ params: [String: String]) -> Bool {
        let receiver = params["receiver"] ?? ""
        guard receiver.isEmpty || receiver.lowercased() == "auto" else { return false }
        return ["transport", "path", "connection-path", "connection", "session", "localip", "local-ip"]
            .allSatisfy { params[$0] == nil }
    }

    /// The picture a URL may ask for: one of the Picture menu's choices for
    /// this iMac, under the menu's name for it (PWEPictureRules.offered).
    static func acceptedPicture(_ asked: TBDisplayCapturePreset, choices: [TBDisplayCapturePreset]) -> TBDisplayCapturePreset? {
        let offered = PWEPictureRules.offered(asked)
        return choices.contains(offered) ? offered : nil
    }

    static func plan(plainAutomatic: Bool, knowsIMac: Bool, connected: Bool,
                     picture: TBDisplayCapturePreset, wantedPicture: TBDisplayCapturePreset?,
                     mode: PWEDisplayMode, wantedMode: PWEDisplayMode?) -> Plan {
        guard plainAutomatic, knowsIMac else { return .notOurs }
        guard connected else { return .connect }
        let changes = (wantedPicture.map { $0 != picture } ?? false) || (wantedMode.map { $0 != mode } ?? false)
        return changes ? .reconnect : .nothing
    }
}

/// The first connection's two extra lines in the window: where the menu bar
/// controls are, and Open at login (PWEPhaseRulesTests).
enum PWEFirstConnectionRules {
    /// Shown from the first time an iMac becomes a display until that connection
    /// ends. A reconnect that applies a setting passes through Connecting and
    /// keeps them; anything else ends them for good.
    static func showsTips(previously: Bool, setupFinished: Bool, phase: PWEPhase) -> Bool {
        switch phase {
        case .connected: return previously || !setupFinished
        case .connecting: return previously
        default: return false
        }
    }
}

/// Where this Mac's sound plays while the iMac is its display.
enum PWESound: String, CaseIterable, Identifiable {
    case onlyIMac, both, onlyThisMac
    var id: String { rawValue }
}

/// When changing the sound choice must reconnect (PWESoundRulesTests). The
/// engine captures system audio only when relay is on as the picture starts,
/// so turning relay on reconnects unless this connection's capture already
/// has audio (relay was on when it started, then turned off). Relay on with
/// no audio captured while the picture is up (the direct path's sound stream
/// stopped, K2) reconnects too when an iMac choice is made again: that
/// rebuilds the stream. Not while connecting, retrying or waiting for a
/// pairing code: nothing is captured yet then, and a reconnect would only
/// interrupt it.
enum PWESoundRules {
    static func needsReconnect(relayOn: Bool, relayWasOn: Bool, capturingAudio: Bool, streaming: Bool = true) -> Bool {
        relayOn && !capturingAudio && (!relayWasOn || streaming)
    }
}

enum PWEDisplayMode: String, CaseIterable, Identifiable {
    case extended, mirror
    var id: String { rawValue }
}

/// Keyboard and mouse sharing (the engine's Input Dockstation add-on).
enum PWEInputRole: String, CaseIterable, Identifiable {
    case off
    case macControlsIMac     // TBInputControlRole.senderMaster
    case iMacControlsMac     // TBInputControlRole.receiverMaster
    var id: String { rawValue }

    var engineRole: TBInputControlRole {
        switch self {
        case .off: return .off
        case .macControlsIMac: return .senderMaster
        case .iMacControlsMac: return .receiverMaster
        }
    }
}

/// Network Link: which way the picture travels.
enum PWEConnection: String, CaseIterable, Identifiable {
    case thunderbolt, network
    var id: String { rawValue }
}

/// How the iMac draws the picture. The raw value travels in the hello as
/// "receiverRenderer". On iMac18,3 (2026-10-20, BASELINE "E 组") Metal used
/// 25–40 % less of the iMac's CPU; OpenGL measured 11–13 ms lower and dropped
/// no frames, but its trace stops at the hand-off to the window server while
/// Metal's runs to the screen. Lee then kept both, OpenGL by default.
/// 2026-10-24 receiver trace on iMac18,3 with a Mac Studio: Metal paces frames
/// to the refresh and hands off ~2.4 ms sooner; Lee chose Metal as the default.
/// A choice made in Settings › Advanced (per iMac, or the last one) is kept.
enum PWERendering: String, CaseIterable, Identifiable {
    case openGL = "opengl"
    case metal
    var id: String { rawValue }

    /// For a Mac where nobody has chosen.
    static let `default`: PWERendering = .metal
}

@MainActor
final class PWESenderModel: ObservableObject {
    @Published private(set) var phase: PWEPhase = .searching
    @Published var autoConnect: Bool {
        didSet { defaults.set(autoConnect, forKey: Keys.autoConnect) }
    }
    @Published var displayMode: PWEDisplayMode {
        didSet {
            defaults.set(displayMode.rawValue, forKey: Keys.displayMode)
            if displayMode != oldValue, !applyingConnectURL {
                reconnectIfShowing(because: "display mode changed to \(displayMode.rawValue)")
            }
        }
    }
    /// An iMac has been a display on this Mac before: the first connection's
    /// extra lines (PWEFirstConnectionRules) have had their turn.
    @Published private(set) var setupFinished: Bool {
        didSet { defaults.set(setupFinished, forKey: Keys.setupFinished) }
    }
    /// The window shows the first connection's extra lines.
    @Published private(set) var firstConnection = false
    /// Keyboard and mouse sharing, applied each time a connection comes up.
    @Published var inputRole: PWEInputRole {
        didSet {
            defaults.set(inputRole.rawValue, forKey: Keys.inputRole)
            guard inputRole != oldValue else { return }
            if inputRole != .off, !(service?.inputDockstationAvailable ?? true) {
                // Upstream switches add-ons only between connections.
                reconnectIfShowing(because: "keyboard and mouse sharing on") { enableAddon(.inputDockstation) }
            } else {
                applyInputRole(force: true)
            }
        }
    }
    /// The menu bar item is not on screen (PWEStatusMenu says so). The first
    /// connection's tip then does not point at it (T19).
    @Published var menuBarIconHidden = false
    /// Screen Sharing and Remote Login, as last read (A2, PWESharingState).
    @Published private(set) var sharingState = PWESharingState()
    /// Screen Sharing on this Mac shows the iMac in use as its display (A14).
    @Published private(set) var viewedWithScreenSharing = false
    private var screenSharingWatch: PWEScreenSharingWatch?
    /// A one-line notice while a changed setting reconnects ("Reconnecting to apply…").
    @Published private(set) var reconnectNotice = false
    /// While the iMac plays this Mac's sound, keep the Mac's own speakers muted
    /// (PWESound.onlyIMac rather than .both).
    @Published private var soundOnlyOnIMac: Bool {
        didSet { defaults.set(soundOnlyOnIMac, forKey: Keys.soundOnlyOnIMac) }
    }
    @Published private(set) var launchAtLogin = false
    @Published private(set) var launchAtLoginNeedsApproval = false
    /// This copy runs from a place it may not be at the next login (a disk
    /// image, a download), so Open at login is not offered (PWELoginItemRules).
    let launchAtLoginUnavailable: Bool

    let service: TBDisplaySenderService?
    private let defaults: UserDefaults
    private var localMute: PWELocalAudioMute?
    private var cancellables: Set<AnyCancellable> = []
    private var sessionCancellables: Set<AnyCancellable> = []
    /// The last failure while the engine retries (PWEPhaseRules.heldFailure).
    private var heldFailure: PWEReason?
    /// The engine's failure status when the person started a connection
    /// (PWEPhaseRules.freshStatus); nil once the engine has moved on, or after
    /// a few seconds, so a dial that never starts shows the failure again.
    private var staleFailure: String?
    private var staleFailureUntil = Date.distantPast
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
    /// T54: a connect URL's picture and mode are being applied together; one reconnect follows.
    private var applyingConnectURL = false
    /// T54: a connect URL's picture for the next connection. It is remembered
    /// only once it shows (rememberShowingPicture), like any picture that works.
    private var urlPicture: TBDisplayCapturePreset?
    /// A1: a Disconnect (or Cancel) happened in this run; no automatic pairing after it.
    private var disconnectedThisRun = false
    /// A1: iMacs automatic pairing has been started for in this run; cleared by a replug (C5).
    private var headlessPairingStarted = Set<String>()
    /// C3: since when no physical display has been online, and until when the
    /// launch or the last cable event lets automatic pairing start.
    private var noPhysicalDisplaySince: TimeInterval?
    private var headlessArmedUntil = ProcessInfo.processInfo.systemUptime + PWEHeadlessPairingRules.armedFor
    private var iMacsOnCableBefore = 0
    private var headlessRecheck: Task<Void, Never>?
    /// The input role has been applied to the current connection.
    private var inputRoleApplied = false
    private var noticeTask: Task<Void, Never>?
    /// Snapshot values, for a model without an engine.
    private var previewSound: PWESound = .onlyIMac
    private var previewSecurity: PWESecurityState = .none
    /// The iMacs this Mac has paired with (keychain), read when Settings asks.
    @Published private(set) var pairedIMacs: [PWEPairedReceiver] = []
    /// pairedIMacs has been read from the keychain at least once.
    private var pairedIMacsLoaded = false
    /// The name of the iMac the last Forget could not forget; nil after a success.
    @Published private(set) var forgetFailure: String?
    /// Why the code step asks for a new code (PWEPairingRules).
    @Published private(set) var codeNote: PWECodeNote?
    /// When the iMac's pairing lock ends, while it is locked.
    @Published private(set) var lockEnd: Date?
    /// The session's security state at the last look, to act on its changes.
    private var lastSecurity: PWESecurityState = .none
    /// Codes that ran out unanswered, in a row (PWEPairingRules.renewals).
    private var expiredInARow = 0
    private var codeTimer: Task<Void, Never>?
    private var lockTimer: Task<Void, Never>?

    enum Keys {
        static let autoConnect = "pwe.autoConnect"
        static let displayMode = "pwe.displayMode"
        static let askedForScreenRecording = "pwe.askedForScreenRecording"
        /// [receiver identity: TBDisplayCapturePreset raw value]
        static let pictures = "pwe.pictures"
        /// Set once 1.1.1 has moved remembered 30-frame 1440p pictures to 60 frames.
        static let pictures1440p60 = "pwe.pictures.1440p60"
        static let soundOnlyOnIMac = "pwe.soundOnlyOnIMac"
        // "pwe.showsMenuBarIcon" (1.1 betas) is no longer read: the menu bar
        // item is the app's way in and always shows. The stored value stays.
        static let setupFinished = "pwe.setupFinished"
        static let inputRole = "pwe.inputRole"
        /// Set once 1.1 has turned off a Network Link inherited from 1.0.x.
        static let networkLinkReset = "pwe.networkLinkReset.1.1"
        /// [receiver identity: PWERendering raw value]
        static let renderings = "pwe.renderings"
        /// The last rendering chosen: what an iMac with nothing remembered gets.
        static let rendering = "pwe.rendering"
        /// Upstream's per-receiver display profile, a second memory for the picture.
        static let upstreamDisplayProfiles = "fd.tbdisplaysender.receiverDisplayProfiles.v1"
    }

    /// What the Picture menu offers, best first. A preset chosen in the Full
    /// Console shows up too.
    static let pictureChoices: [TBDisplayCapturePreset] = PWEPictureRules.choices(panelWidth: nil)

    /// Where engine changes reach the model. The main queue, not RunLoop.main:
    /// Combine's RunLoop scheduler runs only in the default mode, so no change
    /// reached the window or the menu bar while a menu was open or a window was
    /// being dragged (PWEConnectionPhaseTests).
    nonisolated static let engineUpdates = DispatchQueue.main

    init(service: TBDisplaySenderService, defaults: UserDefaults = .standard) {
        self.service = service
        self.defaults = defaults
        self.autoConnect = defaults.object(forKey: Keys.autoConnect) as? Bool ?? true
        self.displayMode = PWEDisplayMode(rawValue: defaults.string(forKey: Keys.displayMode) ?? "") ?? .extended
        self.soundOnlyOnIMac = defaults.object(forKey: Keys.soundOnlyOnIMac) as? Bool ?? true
        // Someone who used 1.1 before these lines existed has already chosen.
        self.setupFinished = defaults.object(forKey: Keys.setupFinished) as? Bool
            ?? (defaults.object(forKey: Keys.pictures) != nil)
        self.inputRole = PWEInputRole(rawValue: defaults.string(forKey: Keys.inputRole) ?? "") ?? .off
        self.launchAtLoginUnavailable = !PWELoginItemRules.canRegister(bundlePath: Bundle.main.bundlePath)
        self.localMute = PWELocalAudioMute(defaults: defaults)
        refreshLaunchAtLogin()
        resetNetworkLinkOnce()
        migratePicturesOnce()
        screenSharingWatch = PWEScreenSharingWatch { [weak self] viewing in self?.viewedWithScreenSharing = viewing }
        TBSenderAutomation.pweConnectURLHandler = { [weak self] params in self?.handleConnectURL(params) ?? false }

        service.objectWillChange
            .receive(on: Self.engineUpdates)
            .sink { [weak self] _ in
                self?.observeSessions()
                self?.refreshSoon()
            }
            .store(in: &cancellables)
        NotificationCenter.default
            .publisher(for: TBSenderAutomation.automaticConnectionDidChange)
            .receive(on: Self.engineUpdates)
            .sink { [weak self] _ in self?.refreshSoon() }
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
    init(preview phase: PWEPhase, firstConnection: Bool = false, inputRole: PWEInputRole = .off,
         security: PWESecurityState = .none, paired: [PWEPairedReceiver] = [],
         codeNote: PWECodeNote? = nil, lockEnd: Date? = nil, forgetFailure: String? = nil,
         sharing: PWESharingState = PWESharingState(screenSharing: true, remoteLogin: true)) {
        self.sharingState = sharing
        self.previewSecurity = security
        self.pairedIMacs = paired
        self.forgetFailure = forgetFailure
        self.codeNote = codeNote
        self.lockEnd = lockEnd
        self.service = nil
        self.defaults = UserDefaults(suiteName: "pwe.preview") ?? .standard
        self.autoConnect = true
        self.displayMode = .extended
        self.soundOnlyOnIMac = true
        self.setupFinished = true
        self.firstConnection = firstConnection
        // As the first connection leaves it: Open at login on.
        self.launchAtLogin = true
        self.launchAtLoginUnavailable = false
        self.inputRole = inputRole
        self.phase = phase
    }

    // MARK: - Reading the engine

    private var session: TBDisplaySenderSession? { service?.sessions.first }

    /// The picture on the iMac while it is a display, for the menu's live line.
    var showingPreset: TBDisplayCapturePreset { session?.capturePreset ?? picture }

    /// Frames sent in the last second (the engine's `senderFPS`), and its
    /// once-a-second updates. Snapshots have no engine and show none: the menu's
    /// line then gives the size alone. A sample "60" in release pictures read
    /// as a measured claim (film team, 2026-10-24).
    var framesPerSecond: Int { service == nil ? 0 : session?.liveMetrics.senderFPS ?? 0 }
    var framesPerSecondUpdates: AnyPublisher<Int, Never>? {
        session?.liveMetrics.$senderFPS.removeDuplicates().eraseToAnyPublisher()
    }

    /// Plan A (1.1.1): this Mac's encoder fell behind at 5K 60, so the Picture
    /// menu suggests Smooth · 4K 60 (PWEStreamStats.fiveK60Verdict).
    var fiveK60FallsBehind: Bool { UserDefaults.standard.bool(forKey: PWEStreamStats.fiveK60FallsBehindKey) }

    /// Whether the session dials over Network Link rather than the cable.
    var connectsOverNetwork: Bool { session?.transportKind == .networkLink }

    /// B11: one change in a session reaches the model twice, from the session
    /// and again from the service it bubbles up to. Both ask for one refresh on
    /// the next turn of the main queue (which also runs while a menu is open).
    private var refreshPending = false
    private func refreshSoon() {
        guard !refreshPending else { return }
        refreshPending = true
        Self.engineUpdates.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshPending = false
                self.refresh()
            }
        }
    }

    /// B11: the Screen Recording permission (a TCC query), read at most every
    /// `PWEPollRules.interval` seconds by refreshes, and at once when it may have
    /// changed: coming back to the app, or the person asking to check.
    private var screenRecordingAllowed = true
    private var screenRecordingCheckedAt: TimeInterval?
    private func hasScreenRecording(force: Bool = false) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if force || PWEPollRules.isDue(lastAt: screenRecordingCheckedAt, now: now) {
            screenRecordingAllowed = CGPreflightScreenCaptureAccess()
            screenRecordingCheckedAt = now
        }
        return screenRecordingAllowed
    }

    private func refresh() {
        guard let service else { return }
        syncRendering()
        let retrying = TBSenderAutomation.isConnectingAutomatically
        if wasRetrying, !retrying, !pausedUntilReplug {
            PWELog.note("[pwe] the engine stopped retrying; waiting for a replug")
            pausedUntilReplug = true
        }
        wasRetrying = retrying

        var state = engineState(service, retrying: retrying)
        let note = PWEPairingRules.note(after: codeNote, state.security)
        if note != codeNote { codeNote = note }
        state.codeNote = note
        heldFailure = PWEPhaseRules.heldFailure(after: heldFailure, state)
        let next = PWEPhaseRules.phase(state, held: heldFailure)
        if next != phase { phase = next }
        PWEMainThreadWatch.shared.update(for: next)
        logTransition(state)
        followPairing(state.security)
        updateFirstConnection()
        rememberShowingPicture()
        localMute?.update(mute: soundOnlyOnIMac && isRelayingSound)
        applyInputRole(force: false)
        watchForReplug(service)
        screenSharingWatch?.update(names: screenSharingNames(service))
        startHeadlessPairingIfDue(service)
    }

    /// A1: no screen on this Mac, one unpaired iMac on the cable: start the
    /// connection, and with it the usual pairing (PWEHeadlessPairingRules).
    /// The code step then brings the window up as key (PWEStatusMenu), so the
    /// code box takes the keys. The cheap conditions are read first.
    private func startHeadlessPairingIfDue(_ service: TBDisplaySenderService) {
        let now = ProcessInfo.processInfo.systemUptime
        // C4: on the cable means seen through this Mac's own bridge.
        let localBridgeIPv4 = TBConnectionDiagnostics.currentIPv4Interfaces()
            .filter { $0.name.hasPrefix("bridge") }.map(\.ip)
        let onCable = service.discoveredReceivers.filter {
            PWEHeadlessPairingRules.isOnCable(seenOnCableBridge: $0.seenOnCableBridge, bridgeIPv4: $0.thunderboltIP,
                                              resolvedIPv4: $0.resolvedIPv4Addresses, localBridgeIPv4: localBridgeIPv4)
        }
        // C3: an iMac newly on the cable is a cable event.
        // Bonjour can drop and list an iMac again without a replug: that opens
        // the window but does not undo "already started" (review 2026-10-28).
        if onCable.count > iMacsOnCableBefore { armHeadlessPairing(clearingStarted: false) }
        iMacsOnCableBefore = onCable.count
        let noPhysicalDisplay = TBDisplaySenderSession.pweNoPhysicalDisplay(
            onlineDisplayIDs: TBDisplaySenderSession.pweOnlineDisplays(),
            ownVirtualDisplayIDs: service.sessions.map(\.virtualDisplayID))
        if !noPhysicalDisplay { noPhysicalDisplaySince = nil } else if noPhysicalDisplaySince == nil { noPhysicalDisplaySince = now }
        guard case .ready(let receiver) = phase, autoConnect, !disconnectedThisRun,
              !headlessPairingStarted.contains(receiver.id), noPhysicalDisplay else { return }
        let inputs = PWEHeadlessPairingRules.Inputs(
            noPhysicalDisplay: noPhysicalDisplay,
            iMacsOnCable: onCable.count,
            offeredIMacIsOnCable: onCable.contains { $0.stableIdentity == receiver.id },
            offeredIMacIsPaired: PWEPairingStore.shared.expectedReceiverID(forHint: receiver.id) != nil,
            disconnectedThisRun: disconnectedThisRun,
            alreadyStarted: false,
            autoConnect: autoConnect,
            noPhysicalDisplayFor: now - (noPhysicalDisplaySince ?? now),
            armed: now <= headlessArmedUntil,
            settling: asleep || Date().timeIntervalSince(awokeAt) < Self.wakeSettleTime)
        guard PWEHeadlessPairingRules.startsPairing(inputs) else {
            // Events drive refreshes: look again once the display state has held long enough.
            var steady = inputs
            steady.noPhysicalDisplayFor = .infinity
            steady.settling = false
            if PWEHeadlessPairingRules.startsPairing(steady), headlessRecheck == nil {
                let wait = max(PWEHeadlessPairingRules.steadyFor - inputs.noPhysicalDisplayFor,
                               Self.wakeSettleTime - Date().timeIntervalSince(awokeAt), 0.5)
                headlessRecheck = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                    self?.headlessRecheck = nil
                    self?.refreshSoon()
                }
            }
            return
        }
        headlessPairingStarted.insert(receiver.id)
        PWELog.note("[pwe] no physical display: starting pairing with \(receiver.name) automatically")
        // Not from inside this refresh: connecting refreshes again.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, case .ready(let still) = self.phase, still.id == receiver.id else { return }
                self.connect(to: still)
            }
        }
    }

    /// While the iMac is a display: the names Screen Sharing may call it (A14).
    private func screenSharingNames(_ service: TBDisplaySenderService) -> [String]? {
        guard case .connected(let receiver) = phase, let receiver,
              let discovered = service.discoveredReceivers.first(where: { $0.stableIdentity == receiver.id }) else { return nil }
        var paired: String?
        if let security = session?.pweSecurity, case .encrypted(let name) = security { paired = name }
        return PWEScreenSharingRules.names(for: discovered, friendlyName: receiver.name, pairedName: paired)
    }

    /// The first time an iMac becomes a display: show the extra lines, and turn
    /// on Open at login, which the window's tick box shows and undoes. A copy
    /// that cannot be registered leaves the box off and says why.
    /// Connecting automatically is already on by default and is not asked.
    private func updateFirstConnection() {
        let shows = PWEFirstConnectionRules.showsTips(previously: firstConnection, setupFinished: setupFinished,
                                                      phase: phase)
        if shows != firstConnection { firstConnection = shows }
        guard shows, !setupFinished else { return }
        setupFinished = true
        if !launchAtLogin, !launchAtLoginNeedsApproval, !launchAtLoginUnavailable { setLaunchAtLogin(true) }
    }

    /// The picture is up with sound relayed: the iMac is playing this Mac's audio.
    /// Only while a capture really records it: on the direct path the sound
    /// comes from a separate audio stream, and if that does not start, muting
    /// this Mac would leave sound nowhere.
    private var isRelayingSound: Bool {
        guard let session else { return false }
        return Self.relaysSound(streaming: session.isStreaming, audioEnabled: session.audioEnabled,
                                addonAvailable: session.audioAddonAvailable, capturingAudio: session.pweCapturingAudio)
    }

    nonisolated static func relaysSound(streaming: Bool, audioEnabled: Bool, addonAvailable: Bool, capturingAudio: Bool) -> Bool {
        streaming && audioEnabled && addonAvailable && capturingAudio
    }

    private func observeSessions() {
        sessionCancellables.removeAll()
        for session in service?.sessions ?? [] {
            session.objectWillChange
                .receive(on: Self.engineUpdates)
                .sink { [weak self] _ in self?.refreshSoon() }
                .store(in: &sessionCancellables)
        }
    }

    private func engineState(_ service: TBDisplaySenderService, retrying: Bool) -> PWEEngineState {
        if Date() > staleFailureUntil { staleFailure = nil }
        let fresh = PWEPhaseRules.freshStatus(session?.statusState, stale: staleFailure)
        if !fresh.stillStale { staleFailure = nil }
        var state = PWEEngineState(session: session)
        state.hasPermission = hasScreenRecording()
        state.status = fresh.status
        state.retrying = retrying
        state.receivers = receivers(service)
        state.target = current(service)
        return state
    }

    /// Connection attempts so far: one each time the engine starts to dial.
    private var attempt = 0
    private var engineWasDialing = false
    private var lastTransition = ""

    /// One log line whenever the engine's status, the window's phase or the
    /// menu bar's words change, numbered by connection attempt, so the three
    /// can be matched in one log (T33). The menu's status line and its icon
    /// are drawn from `phase` alone (PWEStatusMenu).
    private func logTransition(_ state: PWEEngineState) {
        let raw = session?.statusState
        let dialing: Bool
        if case .connecting = raw { dialing = true } else { dialing = false }
        if dialing, !engineWasDialing { attempt += 1 }
        engineWasDialing = dialing
        let engine = raw.map { String(describing: $0) } ?? "none"
        let line = "[pwe] attempt \(attempt): engine=\(engine) streaming=\(state.isStreaming) "
            + "firstFrame=\(state.hasFirstFrame) security=\(state.security) retrying=\(state.retrying), "
            + "phase=\(phase.logName), menu=\"\(PWEStrings(language: .english).status(phase))\""
        guard line != lastTransition else { return }
        lastTransition = line
        PWELog.note(line)
    }

    private func receivers(_ service: TBDisplaySenderService) -> [PWEReceiver] {
        service.discoveredReceivers.map {
            PWEReceiver(id: $0.stableIdentity,
                        name: PWEReceiverNaming.friendlyName(receiverName: $0.receiverName, serviceName: $0.serviceName,
                                                             hostName: $0.hostName),
                        detail: PWEReceiverNaming.friendlyDetail(panelSummary: $0.panelSummary),
                        supportsHEVC: $0.supportsHEVCDecode,
                        panelWidth: PWEReceiverNaming.panelSize($0.panelSummary)?.width,
                        runsPWE: PWEReceiverNaming.isPWE(receiverName: $0.receiverName, serviceName: $0.serviceName))
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
        // A pairing question left over from before would hold the engine's retry loop.
        if session.pweSecurity.waitsForUser { session.pweCancelPairing() }
        service.applyDiscoveredReceiver(discovered, to: session)
        startConnecting()
    }

    /// Hands the connection to the engine: `receiver=auto` with the receiver we
    /// just selected as the preferred one, so the engine never picks another Mac.
    private func startConnecting() {
        pausedUntilReplug = false
        heldFailure = nil
        if let status = session?.statusState, PWEPhaseRules.failure(status) != nil {
            staleFailure = String(describing: status)
            staleFailureUntil = Date().addingTimeInterval(5)
        }
        inputRoleApplied = false
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
        if let preset = urlPicture ?? rememberedPicture(for: receiverKey) ?? defaultPicture {
            components.queryItems?.append(URLQueryItem(name: "preset", value: preset.rawValue))
        }
        urlPicture = nil
        syncRendering()
        if let session { Self.prepareForPWEConnection(session) }
        if let url = components.url { TBSenderAutomation.pweHandleOwn(url: url) }
        // The engine has started (or, with retry=0, ended) its retrying already;
        // that change is ours, not one to read as a Disconnect.
        wasRetrying = TBSenderAutomation.isConnectingAutomatically
        refresh()
    }

    /// T54: a `connect` URL from outside, applied like the menu's own choices
    /// (PWEConnectURLRules). False leaves it to upstream's handling.
    func handleConnectURL(_ params: [String: String]) -> Bool {
        // Only what the Picture menu offers this iMac, as the menu names it
        // (the 30-frame 1440p is the 60-frame one); anything else is ignored.
        let asked = params["preset"].flatMap { TBSenderAutomation.parsePreset($0) }
        let choices = PWEPictureRules.choices(panelWidth: service.flatMap { current($0) }?.panelWidth)
        let wantedPicture = asked.flatMap { PWEConnectURLRules.acceptedPicture($0, choices: choices) }
        if let asked, wantedPicture == nil {
            PWELog.note("[pwe] connect URL: picture \(asked.rawValue) is not offered for this iMac; ignored")
        }
        let wantedMode = params["mode"].flatMap { TBSenderAutomation.parseMode($0) }
            .map { $0 == .desktopMirror ? PWEDisplayMode.mirror : .extended }
        let plan = PWEConnectURLRules.plan(
            plainAutomatic: PWEConnectURLRules.isPlainAutomatic(params), knowsIMac: receiverKey != nil,
            connected: session.map { $0.isConnected || $0.isStreaming } ?? false,
            picture: picture, wantedPicture: wantedPicture, mode: displayMode, wantedMode: wantedMode)
        switch plan {
        case .notOurs:
            return false
        case .nothing:
            PWELog.note("[pwe] connect URL: already showing \(picture.rawValue), \(displayMode.rawValue)")
            return true
        case .reconnect, .connect:
            applyingConnectURL = true
            if let wantedPicture, wantedPicture != picture { urlPicture = wantedPicture }
            if let wantedMode, wantedMode != displayMode { displayMode = wantedMode }
            applyingConnectURL = false
            objectWillChange.send()
            let what = "picture \((urlPicture ?? picture).rawValue), \(displayMode.rawValue)"
            if plan == .reconnect {
                reconnectIfShowing(because: "connect URL: \(what)")
            } else {
                PWELog.note("[pwe] connect URL: connecting with \(what)")
                startConnecting()
            }
            return true
        }
    }

    /// C3, C5: a replug or a newly seen iMac lets automatic pairing start
    /// for a while. Only a replug (`clearingStarted`) lets it start again for
    /// an iMac it already started for.
    private func armHeadlessPairing(clearingStarted: Bool) {
        headlessArmedUntil = ProcessInfo.processInfo.systemUptime + PWEHeadlessPairingRules.armedFor
        if clearingStarted { headlessPairingStarted.removeAll() }
    }

    /// `byPerson`: Disconnect, Cancel, Forget or turning off unencrypted
    /// connections: no automatic pairing until the cable is replugged, so an
    /// iMac just forgotten is not paired again by itself. The app's own
    /// disconnect after codes ran out unanswered does not stop it (C5).
    func disconnect(byPerson: Bool = true) {
        if byPerson { disconnectedThisRun = true }
        pausedUntilReplug = true
        heldFailure = nil
        // The engine's Stop also ends its retrying. While it asks a pairing
        // question, Cancel also tells the iMac to hide its code.
        if let session, session.pweSecurity.waitsForUser { session.pweCancelPairing() } else { session?.stop() }
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
        PWELog.note("[pwe] resuming automatic connection after \(reason)")
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
        let bridgeIP = receiver.map {
            PWEReplugRules.bridgeAddress(thunderboltIP: $0.thunderboltIP, thunderboltIPv6: $0.thunderboltIPv6)
        } ?? ""
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
            // A replug is the person asking again: on a Mac with no other
            // screen it is the only way back to a picture without a relaunch.
            disconnectedThisRun = false
            armHeadlessPairing(clearingStarted: true)
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
        _ = hasScreenRecording(force: true)
        refresh()
    }

    func restartForPermission() { service?.restartAfterPermissionChange() }

    // MARK: - Picture

    /// The receiver the Picture choice belongs to: the one on screen, or the
    /// session's remembered one while it is briefly out of the list.
    private var receiverKey: String? {
        PWEPictureRules.pictureKey(onScreen: service.flatMap { current($0)?.id }, remembered: session?.selectedReceiverID)
    }

    /// The Picture menu's choices can be set: there is an iMac to remember them
    /// for. Not `knownReceiverName`, which is nil in an interruption whose iMac
    /// has left the list, while "The picture did not start" points there.
    /// Snapshots have no engine and go by the phase's iMac.
    var canChoosePicture: Bool { service == nil ? knownReceiverName != nil : receiverKey != nil }

    private func rememberedPicture(for key: String?) -> TBDisplayCapturePreset? {
        guard let key, let raw = (defaults.dictionary(forKey: Keys.pictures) as? [String: String])?[key] else { return nil }
        return TBDisplayCapturePreset(rawValue: raw)
    }

    private func remember(_ preset: TBDisplayCapturePreset, for key: String) {
        var pictures = defaults.dictionary(forKey: Keys.pictures) as? [String: String] ?? [:]
        guard pictures[key] != preset.rawValue else { return }
        pictures[key] = preset.rawValue
        defaults.set(pictures, forKey: Keys.pictures)
        PWELog.note("[pwe] remembered picture \(preset.rawValue) for \(key)")
        forgetUpstreamDisplayProfile(for: key)
    }

    /// Upstream re-applies a display profile chosen in its console on every
    /// connection (Work 5K also turns on render matching). Once PWE remembers this
    /// iMac's picture, that second memory only fights the first: drop it.
    private func forgetUpstreamDisplayProfile(for key: String) {
        guard var profiles = defaults.dictionary(forKey: Keys.upstreamDisplayProfiles) as? [String: String],
              profiles.removeValue(forKey: "id:\(key)") != nil else { return }
        defaults.set(profiles, forKey: Keys.upstreamDisplayProfiles)
        PWELog.note("[pwe] dropped the console's display profile for \(key)")
    }

    /// 1.1's Standard · 1440p was upstream's 30-frame preset; 1.1.1 offers the
    /// 60-frame one under that name (PWEPictureRules.offered). An iMac that
    /// remembered the old one moves to the new one, once.
    private func migratePicturesOnce() {
        guard !defaults.bool(forKey: Keys.pictures1440p60) else { return }
        defaults.set(true, forKey: Keys.pictures1440p60)
        guard let pictures = defaults.dictionary(forKey: Keys.pictures) as? [String: String],
              let migrated = PWEPictureRules.migrated1440p(pictures) else { return }
        defaults.set(migrated, forKey: Keys.pictures)
        PWELog.note("[pwe] remembered 1440p pictures now use 60 frames a second")
    }

    /// The picture for an iMac with nothing remembered yet (PWEPictureRules).
    private var defaultPicture: TBDisplayCapturePreset? {
        guard let service, let target = current(service) else { return nil }
        let engineDefault = session?.capturePreset ?? .standard1440p
        let preset = PWEPictureRules.defaultPicture(supportsHEVC: target.supportsHEVC, panelWidth: target.panelWidth,
                                                    engineDefault: engineDefault)
        return preset == engineDefault ? nil : preset
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
        get {
            rememberedPicture(for: receiverKey) ?? defaultPicture
                ?? session.map { PWEPictureRules.offered($0.capturePreset) } ?? .native5k60Experimental
        }
        set {
            guard let key = receiverKey, newValue != picture else { return }
            remember(newValue, for: key)
            objectWillChange.send()
            reconnectIfShowing(because: "picture changed to \(newValue.rawValue)")
        }
    }

    /// Render matching sizes the virtual display to the stream: with Smooth ·
    /// 4K 60 that is a 1920 × 1080 desktop instead of the iMac's 5K one. PWE
    /// offers no switch for it, but the engine keeps it per session and the
    /// Full Console (or its Work 5K profile) can leave it on; every connection
    /// PWE starts turns it off (PWEPictureRules.choices).
    static func prepareForPWEConnection(_ session: TBDisplaySenderSession) {
        guard session.matchRenderToStream else { return }
        session.matchRenderToStream = false
        PWELog.note("[pwe] render matching was on; turned off so the iMac keeps its 5K desktop")
    }

    /// A choice the engine reads only when a connection starts: start it again.
    /// `change` runs between the stop and the new start, for the engine's setters
    /// that refuse to change a live connection.
    private func reconnectIfShowing(because reason: String, change: () -> Void = {}) {
        guard let session else { change(); return }
        if session.isConnected || session.isStreaming {
            PWELog.note("[pwe] \(reason); reconnecting")
            session.stopForAutomaticReconnect()
            change()
            showReconnectNotice()
            startConnecting()
        } else {
            change()
            if TBSenderAutomation.isConnectingAutomatically {
                startConnecting()  // the retry loop holds the old settings
            }
        }
    }

    private func showReconnectNotice() {
        reconnectNotice = true
        noticeTask?.cancel()
        noticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.reconnectNotice = false
        }
    }

    var pictureChoices: [TBDisplayCapturePreset] {
        let choices = service.flatMap { current($0) }.map { PWEPictureRules.choices(panelWidth: $0.panelWidth) }
            ?? Self.pictureChoices
        return choices.contains(picture) ? choices : choices + [picture]
    }

    // MARK: - iMac rendering

    /// How the iMac draws the picture, remembered per iMac like the picture. An
    /// iMac with nothing remembered gets the last choice made, so the setting
    /// never snaps back while no iMac is known. The receiver applies it when a
    /// connection starts: changing it while connected reconnects.
    var rendering: PWERendering {
        get { rendering(for: receiverKey) }
        set {
            guard newValue != rendering else { return }
            if let key = receiverKey {
                var renderings = defaults.dictionary(forKey: Keys.renderings) as? [String: String] ?? [:]
                renderings[key] = newValue.rawValue
                defaults.set(renderings, forKey: Keys.renderings)
            }
            defaults.set(newValue.rawValue, forKey: Keys.rendering)
            objectWillChange.send()
            reconnectIfShowing(because: "iMac rendering changed to \(newValue.rawValue)") { syncRendering() }
        }
    }

    private func rendering(for key: String?) -> PWERendering {
        if let key, let raw = (defaults.dictionary(forKey: Keys.renderings) as? [String: String])?[key],
           let remembered = PWERendering(rawValue: raw) {
            return remembered
        }
        return PWERendering(rawValue: defaults.string(forKey: Keys.rendering) ?? "") ?? .default
    }

    /// The engine sends it in every hello, whichever path connects: here, the
    /// engine's own retries, or the Full Console.
    private func syncRendering() {
        session?.pweReceiverRenderer = rendering.rawValue
    }

    // MARK: - Connected controls

    var brightness: Double {
        get { session?.brightness ?? 1 }
        set { session?.brightness = newValue; objectWillChange.send() }
    }

    /// Relay on or off is the engine's `audioEnabled` together with its audio
    /// add-on; muting this Mac is PWE's. Choosing the iMac turns the add-on on.
    var sound: PWESound {
        get {
            guard let service else { return previewSound }
            guard service.audioRelayAvailable, session?.audioEnabled ?? service.audioEnabled else { return .onlyThisMac }
            return soundOnlyOnIMac ? .onlyIMac : .both
        }
        set {
            // K2: choosing an iMac option again rebuilds a relay whose sound stopped.
            let relayLostItsSound = newValue != .onlyThisMac
                && (session.map { $0.isStreaming && $0.audioEnabled && !$0.pweCapturingAudio } ?? false)
            guard newValue != sound || relayLostItsSound else { return }
            guard let service else { previewSound = newValue; objectWillChange.send(); return }
            let relayWasOn = service.audioRelayAvailable && (session?.audioEnabled ?? service.audioEnabled)
            let relayOn = newValue != .onlyThisMac
            if relayOn { soundOnlyOnIMac = newValue == .onlyIMac }
            objectWillChange.send()
            if PWESoundRules.needsReconnect(relayOn: relayOn, relayWasOn: relayWasOn,
                                            capturingAudio: session?.pweCapturingAudio ?? false,
                                            streaming: session?.isStreaming ?? false) {
                // The engine captures audio only if relay was on when the picture
                // started, and records nothing it does not send.
                reconnectIfShowing(because: "sound now relayed to the iMac") {
                    enableAddon(.audioRelay)
                    session?.audioEnabled = true
                    service.audioEnabled = true
                }
            } else {
                // Turning relay off (the capture's audio is dropped, not sent), on
                // again over that capture, or moving between iMac-only and both
                // takes effect at once.
                let wasOn = service.audioEnabled
                session?.audioEnabled = relayOn
                service.audioEnabled = relayOn
                // Sound back on the iMac without a reconnect: send the level now,
                // since the connection-time send was skipped while it was off.
                if relayOn, !wasOn, let session { session.volume = session.volume }
            }
            refresh()
        }
    }

    /// The iMac's own speaker volume, while the picture is up. The receiver sets
    /// the iMac's system volume from it.
    var volume: Double {
        get { session?.volume ?? 0.5 }
        set { session?.volume = newValue; objectWillChange.send() }
    }

    /// The iMac the Picture setting belongs to, if one is known.
    var knownReceiverName: String? {
        switch phase {
        case .ready(let receiver): return receiver.name
        case .connecting(let receiver, _), .connected(let receiver), .interrupted(let receiver, _, _),
             .security(let receiver, _): return receiver?.name
        case .needsPermission, .searching, .choose: return nil
        }
    }

    var isShowing: Bool {
        if case .connected = phase { return true }
        return false
    }

    /// The iMac the menu's Connect item would use: the one on screen, ready.
    var connectableReceiver: PWEReceiver? {
        switch phase {
        case .ready(let receiver): return receiver
        case .interrupted(let receiver, _, retrying: false): return receiver
        default: return nil
        }
    }

    /// Something is in progress that Disconnect (or Cancel) would end.
    var canDisconnect: Bool {
        switch phase {
        case .connecting, .connected, .security: return true
        case .interrupted(_, _, let retrying): return retrying
        default: return false
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

    /// The Open at login switch's state (PWELoginItemRules.display).
    var launchAtLoginDisplay: PWELoginItemRules.Display {
        PWELoginItemRules.display(registered: launchAtLogin, canRegister: !launchAtLoginUnavailable)
    }

    func setLaunchAtLogin(_ on: Bool) {
        guard service != nil else { launchAtLogin = on; return }
        if on, launchAtLoginUnavailable {
            PWELog.note("[pwe] launch at login: not registering a copy outside Applications (\(Bundle.main.bundlePath))")
            refreshLaunchAtLogin()
            return
        }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            PWELog.note("[pwe] launch at login: \(error.localizedDescription)")
        }
        refreshLaunchAtLogin()
    }

    func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }

    // MARK: - Use only the iMac (A2)

    /// What the "Use only the iMac" rows read (PWEOnlyIMacRules).
    var onlyIMacInputs: PWEOnlyIMacRules.Inputs {
        PWEOnlyIMacRules.Inputs(
            screenRecording: service == nil ? true : hasScreenRecording(),
            launchAtLogin: launchAtLogin, launchAtLoginNeedsApproval: launchAtLoginNeedsApproval,
            canRegisterLogin: !launchAtLoginUnavailable, autoConnect: autoConnect, inputRole: inputRole,
            screenSharing: sharingState.screenSharing, remoteLogin: sharingState.remoteLogin)
    }

    /// Reads Screen Sharing and Remote Login again, off the main thread. Called
    /// when the list shows and when the app comes back from System Settings.
    func refreshSharingState() {
        guard service != nil else { return }
        _ = hasScreenRecording(force: true)
        Task.detached(priority: .utility) { [weak self] in
            let state = PWESharingState.read()
            await MainActor.run {
                guard let self, self.sharingState != state else { return }
                self.sharingState = state
            }
        }
    }

    /// A row's button: PWE's own setting is turned on here; a system setting
    /// only gets its pane opened. Screen Sharing and Remote Login are never
    /// turned on by the app.
    func fixOnlyIMac(_ row: PWEOnlyIMacRules.Row) {
        switch row {
        case .screenRecording:
            requestScreenRecording()
        case .openAtLogin:
            if launchAtLoginNeedsApproval { openLoginItemsSettings() } else { setLaunchAtLogin(true) }
        case .autoConnect:
            autoConnect = true
        case .keyboardMouse:
            inputRole = .iMacControlsMac
        case .screenSharing, .remoteLogin:
            if let url = URL(string: "x-apple.systempreferences:com.apple.Sharing-Settings.extension") {
                NSWorkspace.shared.open(url)
            }
        }
        objectWillChange.send()
    }

    // MARK: - Pairing and encryption (the engine's PWESecureLink)

    var security: PWESecurityState {
        if case .security(_, let state) = phase { return state }
        return session?.pweSecurity ?? previewSecurity
    }

    /// The picture is up without encryption (Lee's D1: allowed, with a warning).
    var isUnencrypted: Bool { isShowing && security == .unencrypted }

    func submitCode(_ code: String) {
        heldFailure = nil
        pausedUntilReplug = false
        session?.pweSubmitPairingCode(code)
        refresh()
    }

    /// Acts on the engine's pairing steps that need no answer from the person
    /// (PWEPairingRules): a new code after a wrong or expired one, the code's
    /// own minute, and the end of a lock.
    private func followPairing(_ security: PWESecurityState) {
        guard security != lastSecurity else { return }
        lastSecurity = security
        codeTimer?.cancel()
        codeTimer = nil
        lockTimer?.cancel()
        lockTimer = nil
        if case .locked = security {} else if lockEnd != nil { lockEnd = nil }

        switch security {
        case .needsCode(let secondsLeft, _):
            let deadline = PWEPairingRules.codeDeadline(secondsLeft: secondsLeft, shownAt: Date())
            codeTimer = at(deadline) { model in
                guard let session = model.session, case .needsCode = session.pweSecurity else { return }
                PWELog.note("[pwe] the pairing code ran out; asking the iMac for a new one")
                session.pweCodeExpired()
            }
        case .wrongCode:
            expiredInARow = 0
            askForNewCode(because: "the code did not match")
        case .codeExpired:
            expiredInARow += 1
            if PWEPairingRules.renewsExpiredCode(expiredInARow: expiredInARow) {
                askForNewCode(because: "the code expired")
            } else {
                PWELog.note("[pwe] \(expiredInARow) pairing codes ran out unanswered; stopped asking")
                expiredInARow = 0
                DispatchQueue.main.async { [weak self] in self?.disconnect(byPerson: false) }
            }
        case .locked(let seconds):
            let end = PWEPairingRules.lockEnd(seconds: seconds, lockedAt: Date())
            lockEnd = end
            PWELog.note("[pwe] pairing locked on the iMac for \(seconds) s")
            lockTimer = at(end.addingTimeInterval(PWEPairingRules.lockGrace)) { model in
                guard case .locked = model.session?.pweSecurity else { return }
                PWELog.note("[pwe] the pairing lock is over; asking the iMac for a code")
                model.retrySecurely()
            }
        case .negotiating:
            break
        case .encrypted:
            expiredInARow = 0
            // A pairing that just finished shows in Settings › Advanced while it is open.
            if let session, PWEPairingRules.pairedListIsStale(
                security, sessionID: PWEPairingStore.shared.expectedReceiverID(forHint: session.pweReceiverHint),
                listLoaded: pairedIMacsLoaded, listed: pairedIMacs) {
                refreshPairedIMacs()
            }
        case .none, .checkingCode, .refused, .legacyReceiver, .unencrypted:
            expiredInARow = 0
        }
    }

    /// Ends the exchange the person cannot finish and asks the iMac for a new code.
    private func askForNewCode(because reason: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let session = self.session,
                  PWEPairingRules.asksForNewCode(session.pweSecurity) else { return }
            PWELog.note("[pwe] \(reason); asking the iMac for a new code")
            self.retrySecurely()
        }
    }

    /// Runs `work` at `date` unless cancelled first.
    private func at(_ date: Date, _ work: @escaping @MainActor (PWESenderModel) -> Void) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(max(date.timeIntervalSinceNow, 0)))
            guard !Task.isCancelled, let self else { return }
            work(self)
        }
    }

    func retrySecurely() {
        heldFailure = nil
        pausedUntilReplug = false
        session?.pweRetry()
        refresh()
    }

    func connectUnencrypted() {
        heldFailure = nil
        pausedUntilReplug = false
        session?.pweConnectUnencrypted()
        refresh()
    }

    /// For an iMac paired before that now offers only an unencrypted connection:
    /// forget it here, then ask again (the question then offers to connect).
    func forgetThisIMac() {
        guard let session else { return }
        if let id = PWEPairingStore.shared.expectedReceiverID(forHint: session.pweReceiverHint) {
            let forgot = PWEPairingStore.shared.forget(receiverID: PWEPairingStore.hex(id))
            PWELog.note("[pwe] \(forgot ? "forgot" : "could not forget") the paired iMac \(session.pweReceiverHint)")
        }
        refreshPairedIMacs()
        retrySecurely()
    }

    /// The compatibility switch: unencrypted connections allowed, with a warning.
    var allowUnencrypted: Bool {
        get { service == nil ? true : PWEPairingStore.allowUnencrypted }
        set {
            guard service != nil, newValue != allowUnencrypted else { return }
            PWEPairingStore.allowUnencrypted = newValue
            objectWillChange.send()
            PWELog.note("[pwe] unencrypted connections \(newValue ? "allowed" : "turned off")")
            if !newValue, session?.pweSecurity == .unencrypted { disconnect(byPerson: true) }
        }
    }

    func turnOffUnencrypted() { allowUnencrypted = false }

    func refreshPairedIMacs() {
        guard service != nil else { return }
        pairedIMacs = PWEPairingStore.shared.pairedReceivers().sorted { $0.pairedAt > $1.pairedAt }
        pairedIMacsLoaded = true
    }

    /// Settings › Advanced › Forget. Deletes the iMac's key and hints; an
    /// encrypted session with it ends, so the next connection asks for its code.
    /// A failure stays on screen (forgetFailure) instead of passing silently (T37).
    func forget(_ receiver: PWEPairedReceiver) {
        guard service != nil else { return }
        // C5: the person forgot an iMac: nothing pairs by itself in this run.
        disconnectedThisRun = true
        let store = PWEPairingStore.shared
        // Decided before the hints go: they are how a session names its iMac's key.
        let endsSession = session.map {
            PWEPairingRules.sessionUses(receiver, security: $0.pweSecurity,
                                        expectedID: store.expectedReceiverID(forHint: $0.pweReceiverHint))
        } ?? false
        if store.forget(receiverID: receiver.id) {
            forgetFailure = nil
            PWELog.note("[pwe] forgot the paired iMac \(receiver.name) (\(receiver.id))")
            if endsSession {
                PWELog.note("[pwe] ending the encrypted session with the iMac just forgotten")
                disconnect(byPerson: true)
            }
        } else {
            forgetFailure = receiver.name
            PWELog.note("[pwe] could not forget the paired iMac \(receiver.name) (\(receiver.id)); it stays paired")
        }
        refreshPairedIMacs()
    }

    // MARK: - Settings: advanced

    /// The engine's large cursor changes how the cursor is captured: reconnect.
    var largeCursor: Bool {
        get { service?.largeCursor ?? false }
        set {
            guard let service, newValue != service.largeCursor else { return }
            objectWillChange.send()
            reconnectIfShowing(because: "large cursor \(newValue ? "on" : "off")") { service.largeCursor = newValue }
        }
    }

    // Compression, render matching, keeping the displays awake and detailed
    // logging are left at the engine's defaults; the Full Console still sets them.

    /// 1.1 starts with Network Link off. 1.0.x kept it in the same preferences,
    /// so a Mac that tried it there dialled the iMac's old Wi-Fi address on the
    /// first 1.1 launch (T12, T17 on the test Mac, 2026-10-20). Turned off once;
    /// turning it on again in 1.1 sticks. Other preferences are left alone.
    private func resetNetworkLinkOnce() {
        guard let service, !defaults.bool(forKey: Keys.networkLinkReset) else { return }
        defaults.set(true, forKey: Keys.networkLinkReset)
        let overNetwork = service.sessions.filter { $0.transportKind == .networkLink }
        guard networkLinkEnabled || !overNetwork.isEmpty else { return }
        PWELog.note("[pwe] Network Link from an earlier version turned off; connecting over Thunderbolt")
        // The engine moves its sessions back to Thunderbolt when the add-on goes off.
        setAddon(.networkLink, enabled: false)
        for session in overNetwork {
            session.transportKind = .thunderboltBridge
            session.receiverIP = ""   // a network address; Bonjour gives the bridge one
            service.transportDidChange(for: session)
        }
    }

    var networkLinkEnabled: Bool {
        get { service?.availableTransportKinds.contains(.networkLink) ?? false }
        set {
            guard let service, newValue != networkLinkEnabled else { return }
            objectWillChange.send()
            let usesNetwork = session?.transportKind == .networkLink
            let apply = {
                self.setAddon(.networkLink, enabled: newValue)
                if !newValue, let session = self.session { service.transportDidChange(for: session) }
            }
            // Turning it off while the picture travels over the network ends that connection.
            if !newValue, usesNetwork { reconnectIfShowing(because: "Network Link off", change: apply) } else { apply() }
        }
    }

    var connection: PWEConnection {
        get { session?.transportKind == .networkLink ? .network : .thunderbolt }
        set {
            guard let service, let session, newValue != connection else { return }
            objectWillChange.send()
            reconnectIfShowing(because: "connection over \(newValue.rawValue)") {
                session.transportKind = newValue == .network ? .networkLink : .thunderboltBridge
                service.transportDidChange(for: session)
            }
        }
    }

    // MARK: - Settings: keyboard and mouse

    var inputSharingAvailable: Bool { service?.inputDockstationAvailable ?? true }
    var thisMacInputMonitoring: Bool { service?.localInputMonitoringTrusted ?? false }
    var thisMacAccessibility: Bool { service?.localInputInjectionTrusted ?? false }
    /// What the iMac reported on the last connection; nil before one.
    var iMacAccessibility: Bool? { session?.receiverAccessibilityTrustedHint }
    var iMacInputMonitoring: Bool? { session?.receiverInputMonitoringTrustedHint }

    func openInputMonitoringSettings() { service?.openInputMonitoringSettings() }
    func openAccessibilitySettings() { service?.openAccessibilitySettings() }

    /// The engine sets a role only on a live connection, and can drop it itself
    /// (Control-Option-Command-K on the iMac). Apply it once per connection, so
    /// that shortcut is not undone a second later; a change in Settings re-applies.
    private func applyInputRole(force: Bool) {
        guard let service, let session else { return }
        guard session.isConnected else { inputRoleApplied = false; return }
        guard force || !inputRoleApplied else { return }
        inputRoleApplied = true
        let wanted = service.inputDockstationAvailable ? inputRole.engineRole : .off
        if session.inputControlRole != wanted {
            PWELog.note("[pwe] keyboard and mouse: \(inputRole.rawValue)")
            service.setInputControlRole(wanted, for: session)
        }
    }

    // MARK: - Add-ons

    private func addon(_ capability: TBAddonCapability) -> TBAddonRecord? {
        service?.addons.first { $0.manifest.capabilities.contains(capability) && $0.origin == .bundled }
            ?? service?.addons.first { $0.manifest.capabilities.contains(capability) }
    }

    private func enableAddon(_ capability: TBAddonCapability) { setAddon(capability, enabled: true) }

    private func setAddon(_ capability: TBAddonCapability, enabled: Bool) {
        guard let service, let addon = addon(capability), service.isAddonEnabled(addon) != enabled else { return }
        service.setAddonEnabled(enabled, for: addon)
    }

    // MARK: - Diagnostics

    struct Check: Identifiable {
        let id: String
        let passed: Bool?    // nil: needs a connection first
        let title: String
        let detail: String
    }

    func configurationChecks() -> [Check] {
        guard let service, let session else { return [] }
        return Self.checks(service.configurationChecks(for: session), language: service.language)
    }

    /// The engine's checks in PWE's words: Chinese, or English for every other
    /// language. The engine speaks five, PWE two, so on a German, French or
    /// Italian Mac the checks under Settings › Advanced's English headings came
    /// out in that language (PWEStringsTests).
    nonisolated static func checks(_ engine: [TBConfigurationCheck], language: TBDisplaySenderLanguage) -> [Check] {
        let language = PWEStrings(language: language).language
        return engine.map {
            Check(id: $0.id,
                  passed: $0.state == .pending ? nil : $0.state == .passed,
                  title: TBDisplaySenderL10n.text($0.titleKey, language, $0.values),
                  detail: TBDisplaySenderL10n.text($0.detailKey, language, $0.values))
        }
    }

    /// The report for support is this header and the last half hour of this
    /// app's log (PWELogExport.save). Nothing leaves the Mac unless the person
    /// sends the file.
    ///
    /// Everything in the report except the log: cheap, read on the main actor.
    func diagnosticReportHeader() -> String {
        var lines: [String] = []
        let info = Bundle.main.infoDictionary ?? [:]
        lines.append("PWE Screen Encore \(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))")
        lines.append("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append(PWELogExport.thisMacLine())
        lines.append("Date \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("")
        lines.append("Phase: \(phase)")
        if let service {
            for receiver in service.discoveredReceivers {
                lines.append(PWELogExport.receiverLine(receiver))
            }
            lines.append("Network Link add-on: \(networkLinkEnabled), audio add-on: \(service.audioRelayAvailable), input add-on: \(service.inputDockstationAvailable)")
        }
        if let session {
            lines.append("Session: status=\(session.statusText) transport=\(session.transportKind.rawValue) preset=\(session.capturePreset.rawValue) source=\(session.captureSource.rawValue) codec=\(session.codecPreference.rawValue) renderMatching=\(session.matchRenderToStream)")
            lines.append("Capture: \(session.captureDisplayText) · \(session.displayStateText)")
            if let rate = session.cableTestResult { lines.append(String(format: "Cable test: %.2f Gbit/s", rate)) }
            lines.append("Security: \(session.pweSecurity)")
        }
        lines.append("PWE: picture=\(picture.rawValue) sound=\(sound.rawValue) mode=\(displayMode.rawValue) autoConnect=\(autoConnect) login=\(launchAtLogin) input=\(inputRole.rawValue) rendering=\(rendering.rawValue)")
        lines.append("")
        lines.append("Log (last 30 minutes):")
        return lines.joined(separator: "\n")
    }
}
