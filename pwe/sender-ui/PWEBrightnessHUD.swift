import AppKit
import SwiftUI

/// The brightness HUD on the iMac, drawn like the system's own for the macOS
/// it runs on: a square low in the middle of the screen up to macOS 15, a
/// small panel at the top right from macOS 26.
///
/// It is an ordinary window on the virtual display, so it reaches the iMac in
/// the video stream like everything else there. It never takes clicks or focus.
/// Reduce Motion: it appears and goes at once instead of fading. Reduce
/// Transparency: a solid background instead of the blurred material. Increase
/// Contrast: an outline.
@MainActor
final class PWEBrightnessHUD {
    private static let holdSeconds: TimeInterval = 1.5

    private let model = PWEBrightnessHUDModel()
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    func show(level: Double, on displayID: CGDirectDisplayID, label: String) {
        guard let screen = NSScreen.screens.first(where: { $0.pweDisplayID == displayID }) else { return }
        let workspace = NSWorkspace.shared
        model.level = PWEBrightnessRules.clamp(level)
        model.label = label
        model.solid = workspace.accessibilityDisplayShouldReduceTransparency
        model.outlined = workspace.accessibilityDisplayShouldIncreaseContrast
        let reduceMotion = workspace.accessibilityDisplayShouldReduceMotion

        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.setFrame(Self.frame(on: screen, compact: model.compact), display: false)

        if !panel.isVisible || panel.alphaValue < 1 {
            if !panel.isVisible { panel.alphaValue = reduceMotion ? 1 : 0 }
            panel.orderFrontRegardless()
            if reduceMotion {
                panel.alphaValue = 1
            } else {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.12
                    panel.animator().alphaValue = 1
                }
            }
        }
        NSAccessibility.post(element: panel, notification: .announcementRequested, userInfo: [
            .announcement: "\(label) \(Int((model.level * 100).rounded()))%",
            .priority: NSAccessibilityPriorityLevel.medium.rawValue,
        ])

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.fadeOut() }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdSeconds, execute: work)
    }

    func hide() {
        hideWork?.cancel()
        hideWork = nil
        panel?.orderOut(nil)
    }

    private func fadeOut() {
        guard let panel, panel.isVisible else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.5
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // A key pressed during the fade brought it back: keep it.
                guard let self, let panel = self.panel, panel.alphaValue < 0.01 else { return }
                panel.orderOut(nil)
            }
        })
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.overlayWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: PWEBrightnessHUDView(model: model))
        return panel
    }

    private static func frame(on screen: NSScreen, compact: Bool) -> NSRect {
        if compact {
            let size = NSSize(width: 260, height: 54)
            let area = screen.visibleFrame
            return NSRect(x: area.maxX - size.width - 12, y: area.maxY - size.height - 8,
                          width: size.width, height: size.height)
        }
        let size = NSSize(width: 200, height: 200)
        let area = screen.frame
        return NSRect(x: area.midX - size.width / 2, y: area.minY + 140,
                      width: size.width, height: size.height)
    }
}

@MainActor
final class PWEBrightnessHUDModel: ObservableObject {
    @Published var level = 1.0
    @Published var label = ""
    @Published var solid = false
    @Published var outlined = false
    /// macOS 26 moved its volume and brightness HUD to the top right.
    let compact: Bool = {
        if #available(macOS 26, *) { return true }
        return false
    }()
}

private struct PWEBrightnessHUDView: View {
    @ObservedObject var model: PWEBrightnessHUDModel

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: model.compact ? 16 : 18, style: .continuous)
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                if model.solid {
                    shape.fill(Color(nsColor: .windowBackgroundColor))
                } else {
                    PWEHUDMaterial().clipShape(shape)
                }
            }
            .overlay {
                if model.outlined { shape.strokeBorder(Color.primary.opacity(0.5), lineWidth: 1) }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(model.label)
            .accessibilityValue("\(Int((model.level * 100).rounded()))%")
    }

    @ViewBuilder private var content: some View {
        if model.compact {
            HStack(spacing: 12) {
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.primary)
                PWEBrightnessSegments(level: model.level, height: 6)
            }
            .padding(.horizontal, 18)
        } else {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 76, weight: .regular))
                    .foregroundStyle(.primary.opacity(0.85))
                Spacer(minLength: 0)
                PWEBrightnessSegments(level: model.level, height: 7)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 22)
            }
        }
    }
}

/// The 16 segments, each filled as far as the level reaches into it.
private struct PWEBrightnessSegments: View {
    let level: Double
    let height: CGFloat

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(PWEBrightnessRules.segments(for: level).enumerated()), id: \.offset) { _, fill in
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.primary.opacity(0.18))
                        Rectangle().fill(Color.primary.opacity(0.85))
                            .frame(width: proxy.size.width * fill)
                    }
                }
            }
        }
        .frame(height: height)
    }
}

/// The HUD material behind the content, as the system's HUD windows use.
private struct PWEHUDMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

private extension NSScreen {
    var pweDisplayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
