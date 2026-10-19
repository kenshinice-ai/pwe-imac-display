import AppKit
import Combine
import SwiftUI

/// PWE's menu bar item: where a person goes day to day once the iMac is set up.
/// It replaces upstream's status item (sessions, IP addresses, "Show main window")
/// with what someone using one iMac as a display needs: is it showing, how bright,
/// which picture, where the sound plays, and a way out.
///
/// The menu is rebuilt each time it opens (`menuNeedsUpdate`), from the same
/// model the window reads. The custom rows reuse upstream's slider target and
/// Control Center–style toggle row.
@MainActor
final class PWEStatusMenu: NSObject {
    private let model: PWESenderModel
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()
    private var pendingAction: (@MainActor () -> Void)?
    private var sliderTargets: [TBMenuSliderTarget] = []
    private var toggleRows: [TBMenuToggleRowView] = []

    init(model: PWESenderModel) {
        self.model = model
        super.init()
        model.$showsMenuBarIcon
            .removeDuplicates()
            .sink { [weak self] shows in self?.setVisible(shows) }
            .store(in: &cancellables)
        model.$phase
            .removeDuplicates()
            .sink { [weak self] phase in self?.updateButton(phase) }
            .store(in: &cancellables)
    }

    private var strings: PWEStrings { PWEStrings(language: model.service?.language ?? .english) }

    private func setVisible(_ visible: Bool) {
        if visible, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.imagePosition = .imageOnly
            // One menu for the item's lifetime, filled in menuNeedsUpdate: swapping
            // `item.menu` under an open menu leaves an invisible window that
            // swallows clicks (upstream's note in its status item controller).
            let menu = NSMenu()
            menu.delegate = self
            // Items say themselves whether they are enabled (the Picture submenu).
            menu.autoenablesItems = false
            item.menu = menu
            statusItem = item
            updateButton(model.phase)
        } else if !visible, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    /// The iMac outline, filled while it is a display.
    private func updateButton(_ phase: PWEPhase) {
        guard let button = statusItem?.button else { return }
        let showing: Bool
        if case .connected = phase { showing = true } else { showing = false }
        let image = NSImage(systemSymbolName: showing ? "desktopcomputer" : "display",
                            accessibilityDescription: strings.appName)
        image?.isTemplate = true
        button.image = image
        button.appearsDisabled = !showing
        button.toolTip = "\(strings.appName) — \(strings.status(phase))"
    }

    // MARK: - Building the menu

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        sliderTargets.removeAll()
        toggleRows.removeAll()
        let strings = strings

        menu.addItem(disabled(strings.status(model.phase)))

        if model.isShowing {
            menu.addItem(.separator())
            menu.addItem(sliderItem(label: strings.brightness, value: model.brightness) { [weak model] value in
                model?.brightness = value
            })
            var toggles: [TBMenuToggleSpec] = []
            if model.nightShiftAvailable {
                toggles.append(TBMenuToggleSpec(
                    symbol: "sun.lefthalf.filled", title: strings.nightShift,
                    stateText: model.nightShift ? strings.on : strings.off, isOn: model.nightShift
                ) { [weak model] on in model?.nightShift = on })
            }
            if model.trueToneAvailable {
                toggles.append(TBMenuToggleSpec(
                    symbol: "sun.max.fill", title: strings.trueTone,
                    stateText: model.trueTone ? strings.on : strings.off, isOn: model.trueTone
                ) { [weak model] on in model?.trueTone = on })
            }
            if !toggles.isEmpty {
                let row = TBMenuToggleRowView(specs: toggles, width: TBMenuMetrics.width, leadingInset: TBMenuMetrics.inset)
                row.onWord = strings.on
                row.offWord = strings.off
                let item = NSMenuItem()
                item.view = row
                menu.addItem(item)
                toggleRows.append(row)
            }
        }

        menu.addItem(.separator())
        menu.addItem(pictureSubmenu())
        menu.addItem(soundSubmenu())

        menu.addItem(.separator())
        if model.canDisconnect {
            menu.addItem(action(model.isShowing ? strings.disconnect : strings.cancel) { [weak model] in
                model?.disconnect()
            })
        } else if let receiver = model.connectableReceiver {
            menu.addItem(action(strings.menuConnectTo(receiver.name)) { [weak model] in
                model?.connect(to: receiver)
            })
        }
        if model.isShowing {
            menu.addItem(action(strings.arrange) { [weak model] in model?.openDisplaySettings() })
        }

        menu.addItem(.separator())
        menu.addItem(action(strings.menuOpenWindow) { PWEWindows.shared.showMain() })
        let settings = action(strings.settingsMenu) { PWEWindows.shared.showSettings() }
        settings.keyEquivalent = ","
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = action(strings.quit) { [weak model] in model?.service?.quitAfterUserRequest() }
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    private func pictureSubmenu() -> NSMenuItem {
        let item = NSMenuItem(title: strings.picture, action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for preset in model.pictureChoices {
            let choice = action(strings.pictureName(preset)) { [weak model] in model?.picture = preset }
            choice.state = preset == model.picture ? .on : .off
            submenu.addItem(choice)
        }
        if model.isShowing {
            submenu.addItem(.separator())
            submenu.addItem(disabled(strings.pictureChangeHint))
        }
        item.submenu = submenu
        // The picture is remembered per iMac; with none in sight there is nothing to set.
        item.isEnabled = model.knownReceiverName != nil
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
        pendingAction = action.work
    }

    /// The brightness row: the same layout as upstream's (small sun, slider, big sun).
    private func sliderItem(label: String, value: Double, onChange: @escaping (Double) -> Void) -> NSMenuItem {
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
        container.addSubview(glyph("sun.min.fill", size: 13, x: inset))
        container.addSubview(glyph("sun.max.fill", size: 17, x: width - inset - 17))

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

    func menuDidClose(_ menu: NSMenu) {
        guard let work = pendingAction else { return }
        pendingAction = nil
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

    func showMain() {
        NSApp.activate(ignoringOtherApps: true)
        // WindowGroup's openWindow always makes another window: reuse a shown one.
        if let window = NSApp.windows.first(where: {
            $0.identifier?.rawValue.hasPrefix("main") == true && ($0.isVisible || $0.isMiniaturized)
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
