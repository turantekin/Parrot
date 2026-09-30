import AppKit
import SwiftUI

/// The floating pill: one nudge over every app, full-screen calls included,
/// for about 10 seconds. A non-activating panel, so the call app keeps the
/// keyboard, and left out of screen capture so a screen share never shows
/// the other side what Parrot noticed.
@MainActor
final class NudgePillController {
    static let shared = NudgePillController()
    static let visibleFor: TimeInterval = 10

    /// Brings Parrot forward on the live call (set by RecordingManager).
    var onOpen: (() -> Void)?
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private var hovering = false
    private var generation = 0

    func show(_ nudge: Nudge) {
        generation += 1
        hovering = false
        let panel = self.panel ?? Self.makePanel()
        self.panel = panel
        let host = NSHostingView(rootView: NudgePillView(
            nudge: nudge,
            onOpen: { [weak self] in
                self?.hide()
                self?.onOpen?()
            },
            onDismiss: { [weak self] in self?.hide() },
            onHover: { [weak self] inside in self?.hover(inside) }))
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host
        panel.setContentSize(size)
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - size.height - 12))
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 1
        }
        scheduleHide()
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        guard let panel, panel.isVisible else { return }
        let fading = generation
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // A newer nudge may have arrived during the fade.
                if self?.generation == fading { panel.orderOut(nil) }
            }
        })
    }

    private func hover(_ inside: Bool) {
        hovering = inside
        if inside { hideTask?.cancel() } else { scheduleHide() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.visibleFor))
            guard !Task.isCancelled, let self, !self.hovering else { return }
            self.hide()
        }
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Theme.Metrics.pillWidth, height: 48),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Never in a screen share or recording: the other side mustn't see it.
        panel.sharingType = .none
        return panel
    }
}

struct NudgePillView: View {
    let nudge: Nudge
    var onOpen: () -> Void = {}
    var onDismiss: () -> Void = {}
    var onHover: (Bool) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: nudge.kind.symbol)
                .foregroundStyle(Theme.Colors.warn)
            Text(nudge.text)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.ink)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onDismiss) {
                Image(systemName: "xmark").font(Theme.Typography.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.Colors.ink3)
            .help("Dismiss")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(width: Theme.Metrics.pillWidth)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Metrics.pillRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.pillRadius).strokeBorder(Theme.Colors.nudgeLine))
        .contentShape(RoundedRectangle(cornerRadius: Theme.Metrics.pillRadius))
        .onTapGesture(perform: onOpen)
        .onHover(perform: onHover)
    }
}

/// The same nudge inside the Copilot panel, above the coach line, until
/// dismissed or replaced.
struct NudgeBanner: View {
    let nudge: Nudge
    var onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: nudge.kind.symbol)
                .foregroundStyle(Theme.Colors.warn)
            Text(nudge.text)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark").font(Theme.Typography.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.Colors.ink3)
            .help("Dismiss")
        }
        .padding(10)
        .background(Theme.Colors.nudge, in: RoundedRectangle(cornerRadius: Theme.Metrics.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.radius).strokeBorder(Theme.Colors.nudgeLine))
    }
}
