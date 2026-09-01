import AppKit
import Carbon.HIToolbox
import SwiftUI

struct ProcessingHUD: View {
    let text: String

    var body: some View {
        if !text.isEmpty {
            Text(text)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.ink)
                .padding(.horizontal, Theme.Metrics.radius * 2)
                .padding(.vertical, Theme.Metrics.radius)
                .background(Theme.Colors.panel, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.Colors.line))
                .padding(.top, Theme.Metrics.radius * 2)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

/// Wispr-style orb: mic only. Shortcuts and transforms live in the app.
struct ProcessingBarView: View {
    @Environment(RecordingManager.self) private var recordingManager

    private var listening: Bool {
        recordingManager.dictation.phase == .listening
    }

    private var status: String {
        let dictation = recordingManager.dictation.phase.hud
        if !dictation.isEmpty { return dictation }
        return recordingManager.transforms.phase.hud
    }

    private var idleHint: String {
        if let hold = HotkeyBinding.load(key: HotkeySlot.dictationHold.defaultsKey) {
            return "Hold \(hold.display)"
        }
        if let tap = HotkeyBinding.load(key: HotkeySlot.dictation.defaultsKey) {
            return tap.display
        }
        return ""
    }

    var body: some View {
        HStack(spacing: 6) {
            Button {
                recordingManager.dictation.toggleHandsFree()
            } label: {
                Image(systemName: listening
                      ? (recordingManager.dictation.isHolding ? "waveform" : "stop.fill")
                      : "mic.fill")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(listening ? Theme.Colors.stop : Theme.Colors.ink)
            }
            .buttonStyle(.plain)
            .help(listening ? "Stop and paste" : "Hands-free dictation")

            if !status.isEmpty {
                Text(status)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.ink2)
                    .lineLimit(1)
            } else if !idleHint.isEmpty {
                Text(idleHint)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.ink3)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.Colors.line))
        .onChange(of: status) {
            ProcessingBarController.shared.fitSize()
        }
        .onReceive(NotificationCenter.default.publisher(for: .parrotHotkeysChanged)) { _ in
            ProcessingBarController.shared.fitSize()
        }
        .contextMenu {
            Button("Settings…") {
                SettingsSection.pending = .create
                NotificationCenter.default.post(name: .parrotShowTranscriptionSettings, object: nil)
                NSApp.activate(ignoringOtherApps: true)
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
            Button("Paste last transcript") {
                recordingManager.dictation.pasteLast()
            }
            Button("Hide bar") { ProcessingBarController.shared.setVisible(false) }
        }
    }
}

struct HotkeyRecorderRow: View {
    let title: String
    let slot: HotkeySlot
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                HotkeyChip(slot: slot) { notice = $0 }
                if HotkeyBinding.load(key: slot.defaultsKey) != nil {
                    Button("Clear") {
                        HotkeyBinding.clear(key: slot.defaultsKey)
                        HotkeyCenter.shared.reload()
                        notice = nil
                    }
                    .buttonStyle(.link)
                    .font(Theme.Typography.secondary)
                }
            }
            if let notice {
                Text(notice)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.warn)
            } else if HotkeyCenter.shared.failedSlots.contains(slot) {
                Text("Couldn't register — another app may own it.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.warn)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .parrotHotkeysChanged)) { _ in }
    }
}

struct HotkeyChip: View {
    let slot: HotkeySlot
    var onNotice: (String?) -> Void = { _ in }
    @State private var listening = false
    @State private var stamp = 0
    @State private var localMonitor: Any?
    @State private var globalMonitor: Any?

    var body: some View {
        Button(listening ? "Press keys…" : (HotkeyBinding.load(key: slot.defaultsKey)?.display ?? label)) {
            startListening()
        }
        .buttonStyle(.plain)
        .font(Theme.Typography.mono(11))
        .foregroundStyle(listening ? Theme.Colors.accent : Theme.Colors.ink2)
        .help("Click, then hold a modifier and a key. Function keys work alone. Escape cancels.")
        .onExitCommand { stopListening() }
        .onDisappear { stopListening() }
        .onReceive(NotificationCenter.default.publisher(for: .parrotHotkeysChanged)) { _ in
            stamp += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .parrotHotkeyListen)) { note in
            if let other = note.object as? UInt32, other != slot.rawValue {
                stopListening()
            }
        }
        .id(stamp)
    }

    private var label: String {
        "Click to set"
    }

    private func startListening() {
        guard !listening else { return }
        listening = true
        onNotice(nil)
        NotificationCenter.default.post(name: .parrotHotkeyListen, object: slot.rawValue)
        let handle: (NSEvent) -> Void = { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stopListening()
                return
            }
            guard let binding = HotkeyBinding.from(event: event) else { return }
            if binding.isReserved {
                onNotice("That shortcut belongs to the app (⌘Q, ⌘W, ⌘V, ⌘Space, ⌘Tab).")
                stopListening()
                return
            }
            if let other = HotkeyBinding.slot(using: binding, excluding: slot) {
                onNotice("Already used for \(other.label).")
                stopListening()
                return
            }
            binding.save(key: slot.defaultsKey)
            HotkeyCenter.shared.reload()
            onNotice(nil)
            stopListening()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
        }
    }

    private func stopListening() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        listening = false
    }
}

@MainActor
final class ProcessingBarController {
    static let shared = ProcessingBarController()
    private static let originKey = "processingBarOrigin"

    private var panel: NSPanel?
    private var host: NSHostingView<AnyView>?
    private var moveObserver: NSObjectProtocol?

    func attach(manager: RecordingManager) {
        if panel == nil {
            let view = AnyView(ProcessingBarView().environment(manager))
            let host = NSHostingView(rootView: view)
            host.sizingOptions = [.intrinsicContentSize]
            self.host = host

            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 120, height: 32),
                styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            panel.becomesKeyOnlyIfNeeded = true
            panel.isMovableByWindowBackground = true
            panel.contentView = host
            self.panel = panel
            moveObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didMoveNotification, object: panel, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.saveOrigin() }
            }
        }
        syncVisibility()
    }

    func setVisible(_ show: Bool) {
        UserDefaults.standard.set(show, forKey: FeatureProcessing.showBarKey)
        syncVisibility()
    }

    func fitSize() {
        guard let panel else { return }
        panel.contentView?.layoutSubtreeIfNeeded()
        let size = host?.fittingSize ?? NSSize(width: 72, height: 28)
        panel.setContentSize(NSSize(width: max(size.width, 56), height: max(size.height, 28)))
    }

    func syncVisibility() {
        let show = UserDefaults.standard.object(forKey: FeatureProcessing.showBarKey) as? Bool ?? true
        guard let panel else { return }
        if show {
            fitSize()
            if let saved = savedOrigin(), originIsOnScreen(saved) {
                panel.setFrameOrigin(saved)
            } else if let screen = NSScreen.main {
                let visible = screen.visibleFrame
                let x = visible.midX - panel.frame.width / 2
                let y = visible.minY + 12
                panel.setFrameOrigin(NSPoint(x: x, y: y))
            }
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

    private func saveOrigin() {
        guard let panel else { return }
        UserDefaults.standard.set(
            [panel.frame.origin.x, panel.frame.origin.y], forKey: Self.originKey)
    }

    private func savedOrigin() -> NSPoint? {
        let pair = UserDefaults.standard.array(forKey: Self.originKey) as? [CGFloat]
            ?? (UserDefaults.standard.array(forKey: Self.originKey) as? [Double])?.map { CGFloat($0) }
        guard let pair, pair.count == 2 else { return nil }
        return NSPoint(x: pair[0], y: pair[1])
    }

    private func originIsOnScreen(_ origin: NSPoint) -> Bool {
        NSScreen.screens.contains { $0.visibleFrame.contains(origin) }
    }
}
