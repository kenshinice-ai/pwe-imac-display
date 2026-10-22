import AppKit
import Combine
import SwiftUI

/// PWE's menu bar item: where a person goes day to day once the iMac is set up.
/// It replaces upstream's status item (sessions, IP addresses, "Show main window")
/// with what someone using one iMac as a display needs: is it showing, how bright,
/// how loud, which picture, where the sound plays, and a way out. Everyday
/// controls live here and nowhere else.
///
/// The menu is rebuilt each time it opens (`menuNeedsUpdate`), and again while
/// open when the connection changes which items it needs, from the same model
/// the window reads. The slider rows reuse upstream's slider target.
/// It always shows: the app is menu bar first, and its window is a click on the
/// Dock icon away, so the menu has no item for it.
@MainActor
final class PWEStatusMenu: NSObject {
    private let model: PWESenderModel
    /// The daily check's finding, for one line under the status; nil in snapshots.
    private let updates: UpdateCheck?
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()
    private let actions = PWEMenuActionQueue()
    private var sliderTargets: [TBMenuSliderTarget] = []
    /// The menu's first line, kept current while the menu is open.
    private weak var statusLine: NSMenuItem?
    /// The top menu while it is open, and which items it was built with.
    private weak var openMenu: NSMenu?
    private var builtShape: Shape?
    /// Snapshots: the words without an engine to ask.
    private let previewLanguage: TBDisplaySenderLanguage?

    init(model: PWESenderModel, updates: UpdateCheck) {
        self.model = model
        self.updates = updates
        self.previewLanguage = nil
        super.init()
        installItem()
        updates.$available
            .removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { [weak self] in self?.refreshOpenMenu() } }
            .store(in: &cancellables)
        model.$phase
            .removeDuplicates()
            .sink { [weak self] phase in
                self?.updateButton(phase)
                guard let self else { return }
                if let line = self.statusLine { line.title = self.statusText(phase) }
                // `$phase` publishes before the model changes. Look again on the
                // next turn (the main queue also runs while a menu tracks) and
                // rebuild an open menu whose items no longer fit: open while it
                // reconnected, it kept Cancel and lost the sliders (T33, RC2).
                DispatchQueue.main.async { [weak self] in self?.refreshOpenMenu() }
            }
            .store(in: &cancellables)
        // "Reconnecting to apply the change…" for a few seconds after a setting
        // that reconnects, in place of the phase's words (also in the window).
        model.$reconnectNotice
            .removeDuplicates()
            .sink { [weak self] notice in
                guard let self, let line = self.statusLine else { return }
                line.title = self.statusText(self.model.phase, reconnecting: notice)
            }
            .store(in: &cancellables)
        // A code to type or a question to answer needs the window, even when the
        // person only ever uses the menu bar: bring it up once per question.
        model.$phase
            .map { phase -> String? in
                guard case .security(_, let security) = phase else { return nil }
                switch security {
                case .needsCode, .wrongCode, .codeExpired, .checkingCode: return "code"
                default: return "question"
                }
            }
            .removeDuplicates()
            .dropFirst()
            .sink { asks in if asks != nil { PWEWindows.shared.showMain() } }
            .store(in: &cancellables)
    }

    /// The menu as it would open, for `--pwe-snapshot`: no status item, nothing on screen.
    init(preview model: PWESenderModel, language: TBDisplaySenderLanguage) {
        self.model = model
        self.updates = nil
        self.previewLanguage = language
        super.init()
    }

    func previewMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        rebuild(menu)
        return menu
    }

    private var strings: PWEStrings {
        PWEStrings(language: previewLanguage ?? model.service?.language ?? .english)
    }

    /// The first line's words: the phase, or the reconnect notice while it shows.
    /// `$reconnectNotice` publishes before the model changes, so a sink passes
    /// the new value in.
    private func statusText(_ phase: PWEPhase, reconnecting: Bool? = nil) -> String {
        (reconnecting ?? model.reconnectNotice) ? strings.reconnectNotice : strings.status(phase)
    }

    private func installItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.imagePosition = .imageOnly
        // One menu for the item's lifetime, filled in menuNeedsUpdate: swapping
        // `item.menu` under an open menu leaves an invisible window that
        // swallows clicks (upstream's note in its status item controller).
        let menu = NSMenu()
        menu.delegate = self
        // Items say themselves whether they are enabled (the Picture choices).
        menu.autoenablesItems = false
        item.menu = menu
        statusItem = item
        updateButton(model.phase)
    }

    /// One iMac in two states: its outline, and its screen lit while it is a
    /// display. PWE's own template glyphs (pwe/brand/menubar), so the item never
    /// changes object or looks like the system's Displays menu.
    private func updateButton(_ phase: PWEPhase) {
        guard let button = statusItem?.button else { return }
        let showing: Bool
        if case .connected = phase { showing = true } else { showing = false }
        let image = NSImage(named: showing ? "PWEMenuBarShowing" : "PWEMenuBarReady")
        image?.accessibilityDescription = strings.appName
        image?.isTemplate = true
        button.image = image
        button.appearsDisabled = !showing
        button.toolTip = "\(strings.appName) — \(strings.status(phase))"
    }

    // MARK: - Building the menu

    /// Which items the menu holds: what `rebuild` decides on. The first line's
    /// words are not part of it; they change in place.
    private struct Shape: Equatable {
        var showing, unencrypted, canDisconnect, volume: Bool
        var connectable: String?
        var update: String?
    }

    private var shape: Shape {
        Shape(showing: model.isShowing, unencrypted: model.isUnencrypted, canDisconnect: model.canDisconnect,
              volume: model.sound != .onlyThisMac, connectable: model.connectableReceiver?.id,
              update: updates?.available?.version)
    }

    private func refreshOpenMenu() {
        guard let menu = openMenu, shape != builtShape else { return }
        rebuild(menu)
    }

    private func rebuild(_ menu: NSMenu) {
        builtShape = shape
        menu.removeAllItems()
        sliderTargets.removeAll()
        let strings = strings

        let line = disabled(statusText(model.phase))
        statusLine = line
        menu.addItem(line)
        if let version = updates?.available?.version {
            menu.addItem(action(strings.updateAvailableMenu(version)) { NSWorkspace.shared.open(UpdateCheck.downloadPage) })
        }
        if model.isUnencrypted {
            let warning = disabled(strings.notEncrypted)
            warning.image = NSImage(systemSymbolName: "lock.open.fill", accessibilityDescription: nil)
            menu.addItem(warning)
            menu.addItem(action(strings.turnOffUnencrypted) { [weak model] in model?.turnOffUnencrypted() })
        }

        if model.isShowing {
            menu.addItem(.separator())
            menu.addItem(sliderItem(label: strings.brightness, value: model.brightness,
                                    glyphs: ("sun.min.fill", "sun.max.fill")) { [weak model] value in
                model?.brightness = value
            })
            if model.sound != .onlyThisMac {
                menu.addItem(sliderItem(label: strings.iMacVolume, value: model.volume,
                                        glyphs: ("speaker.fill", "speaker.wave.3.fill")) { [weak model] value in
                    model?.volume = value
                })
            }
        }

        menu.addItem(.separator())
        menu.addItem(pictureSubmenu())
        menu.addItem(soundSubmenu())

        var connection: [NSMenuItem] = []
        if model.canDisconnect {
            connection.append(action(model.isShowing ? strings.disconnect : strings.cancel) { [weak model] in
                model?.disconnect()
            })
        } else if let receiver = model.connectableReceiver {
            connection.append(action(strings.menuConnectTo(receiver.name)) { [weak model] in
                model?.connect(to: receiver)
            })
        }
        if model.isShowing {
            connection.append(action(strings.arrange) { [weak model] in model?.openDisplaySettings() })
        }
        // No iMac to connect to: no empty group between two separators.
        if !connection.isEmpty {
            menu.addItem(.separator())
            connection.forEach(menu.addItem)
        }

        menu.addItem(.separator())
        let settings = action(strings.settingsMenu) { PWEWindows.shared.showSettings() }
        settings.keyEquivalent = ","
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = action(strings.quit) { [weak model] in model?.service?.quitAfterUserRequest() }
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    /// The iMac's picture (remembered for each iMac), then how it joins this Mac's
    /// displays. Changing either reconnects for a moment.
    private func pictureSubmenu() -> NSMenuItem {
        let item = NSMenuItem(title: strings.picture, action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        // The picture is remembered per iMac; with none in sight there is nothing to set.
        let knowsIMac = model.knownReceiverName != nil
        for preset in model.pictureChoices {
            let choice = action(strings.pictureName(preset)) { [weak model] in model?.picture = preset }
            choice.state = knowsIMac && preset == model.picture ? .on : .off
            choice.isEnabled = knowsIMac
            submenu.addItem(choice)
        }
        submenu.addItem(.separator())
        for mode in PWEDisplayMode.allCases {
            let choice = action(strings.modeName(mode)) { [weak model] in model?.displayMode = mode }
            choice.state = mode == model.displayMode ? .on : .off
            submenu.addItem(choice)
        }
        item.submenu = submenu
        return item
    }

    private func soundSubmenu() -> NSMenuItem {
        let item = NSMenuItem(title: strings.sound, action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for sound in PWESound.allCases {
            let choice = action(strings.soundName(sound)) { [weak model] in model?.sound = sound }
            choice.state = sound == model.sound ? .on : .off
            submenu.addItem(choice)
        }
        item.submenu = submenu
        return item
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// A menu item whose work runs after the menu has closed. Changing a
    /// connection or opening a window from inside AppKit's menu tracking loop
    /// can leave an invisible menu window over the streamed desktop.
    private func action(_ title: String, _ work: @escaping @MainActor () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(runMenuAction(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = PWEMenuAction(work)
        return item
    }

    @objc private func runMenuAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? PWEMenuAction else { return }
        actions.chose(action.work)
    }

    /// A slider row: the same layout as upstream's brightness row (small glyph,
    /// slider, big glyph).
    private func sliderItem(label: String, value: Double, glyphs: (low: String, high: String),
                            onChange: @escaping (Double) -> Void) -> NSMenuItem {
        let width = TBMenuMetrics.width
        let inset = TBMenuMetrics.inset
        let height: CGFloat = 28
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))

        func glyph(_ name: String, size: CGFloat, x: CGFloat) -> NSImageView {
            let view = NSImageView(frame: NSRect(x: x, y: (height - size) / 2, width: size, height: size))
            view.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            view.setAccessibilityElement(false)
            view.contentTintColor = .secondaryLabelColor
            view.imageScaling = .scaleProportionallyUpOrDown
            return view
        }
        container.addSubview(glyph(glyphs.low, size: 13, x: inset))
        container.addSubview(glyph(glyphs.high, size: 17, x: width - inset - 17))

        let sliderX = inset + 13 + 8
        let slider = NSSlider(frame: NSRect(x: sliderX, y: (height - 19) / 2,
                                            width: width - sliderX - 8 - 17 - inset, height: 19))
        slider.minValue = 0
        slider.maxValue = 1
        slider.doubleValue = value
        slider.isContinuous = true
        slider.controlSize = .small
        slider.setAccessibilityLabel(label)
        let target = TBMenuSliderTarget(onChange)
        slider.target = target
        slider.action = #selector(TBMenuSliderTarget.changed(_:))
        sliderTargets.append(target)
        container.addSubview(slider)

        let item = NSMenuItem()
        item.view = container
        item.toolTip = label
        return item
    }
}

extension PWEStatusMenu: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        // Submenus have no delegate; only the top menu is rebuilt.
        guard menu === statusItem?.menu else { return }
        rebuild(menu)
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === statusItem?.menu else { return }
        openMenu = menu
        actions.menuWillOpen()
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === statusItem?.menu else { return }
        openMenu = nil
        actions.menuDidClose()
    }
}

/// Runs a chosen menu item's work exactly once, after the menu has closed.
///
/// AppKit calls the delegate's `menuDidClose` before it sends the chosen
/// item's action. Work parked by the action and run from `menuDidClose` so ran
/// one choice late: each click did what the previous click asked (T11,
/// 2026-10-20). Both orders work here: work chosen while the menu is open waits
/// for the close, and work chosen after the close runs on the next turn of the
/// main run loop, outside menu tracking. Tested in PWEMenuActionQueueTests.
@MainActor
final class PWEMenuActionQueue {
    typealias Work = @MainActor () -> Void
    private var isOpen = false
    private var pending: Work?
    private let schedule: @MainActor (@escaping Work) -> Void

    init(schedule: @escaping @MainActor (@escaping Work) -> Void = PWEMenuActionQueue.nextTurn) {
        self.schedule = schedule
    }

    func menuWillOpen() {
        isOpen = true
        pending = nil
    }

    /// A menu item's action (or its key equivalent while the menu is closed).
    func chose(_ work: @escaping Work) {
        if isOpen { pending = work } else { schedule(work) }
    }

    func menuDidClose() {
        isOpen = false
        guard let work = pending else { return }
        pending = nil
        schedule(work)
    }

    nonisolated static func nextTurn(_ work: @escaping Work) {
        DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
    }
}

private final class PWEMenuAction: NSObject {
    let work: @MainActor () -> Void
    init(_ work: @escaping @MainActor () -> Void) { self.work = work }
}

/// Opens PWE's windows from places SwiftUI's environment does not reach (the
/// status menu). The actions are captured from the first view that has them;
/// they stay valid after that view's window closes.
@MainActor
final class PWEWindows {
    static let shared = PWEWindows()
    var openWindow: OpenWindowAction?
    var openSettings: OpenSettingsAction?

    /// The main window is on screen (not closed, not in the Dock).
    var isMainShown: Bool {
        NSApp.windows.contains { Self.isMain($0) && $0.isVisible && !$0.isMiniaturized }
    }

    private static func isMain(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue.hasPrefix("main") == true
    }

    func showMain() {
        NSApp.activate(ignoringOtherApps: true)
        // WindowGroup's openWindow always makes another window: reuse a shown one.
        if let window = NSApp.windows.first(where: {
            Self.isMain($0) && ($0.isVisible || $0.isMiniaturized)
        }) {
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow?(id: "main")
        }
    }

    func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if let openSettings {
            openSettings()
        } else {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
    }

    func show(_ id: String) {
        NSApp.activate(ignoringOtherApps: true)
        openWindow?(id: id)
    }
}
