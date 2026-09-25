import SwiftUI

// Settings → General "Startup", Settings → Recording "Call detection" and
// "Calendar". Shared with onboarding's "Make it automatic" step.

/// "Open Parrot at login" — the system login item, read back from macOS so
/// the switch never disagrees with System Settings.
struct LoginItemRow: View {
    var first = false
    @State private var state = LoginItem.state
    @State private var error: String?

    var body: some View {
        SettingsToggleRow(
            title: "Open Parrot at login",
            detail: "Starts quietly when you log in, so it can offer to record your first call of the day. Listed in System Settings → General → Login Items.",
            first: first,
            isOn: Binding(
                get: { state == .on || state == .needsApproval },
                set: { newValue in
                    let result = LoginItem.set(newValue)
                    state = result.state
                    error = result.error
                }
            )
        )
        .disabled(state == .unavailable)
        .onAppear { state = LoginItem.state }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            state = LoginItem.state
        }

        if state == .needsApproval {
            SettingsLabeledRow(title: "Needs your OK", detail: "macOS wants you to allow Parrot in Login Items.") {
                Button("Open Login Items") { LoginItem.openSystemSettings() }
            }
        } else if state == .unavailable {
            SettingsRow { Hint("Available once Parrot runs from the Applications folder.") }
        } else if let error {
            SettingsRow { Hint("Couldn't change it: \(error)") }
        }
    }
}

/// Off / Ask me / Record automatically, plus the apps the user told us to
/// leave alone.
struct CallDetectionCard: View {
    @AppStorage(AutoRecordMode.defaultsKey) private var modeRaw = AutoRecordMode.ask.rawValue
    @State private var ignored: [String] = CallWatcher.ignoredApps.sorted()
    @AppStorage(CalendarService.remindersKey) private var reminders = false
    @State private var notifications: NotificationAccess.State = .on

    var body: some View {
        SettingsCard(title: "Call Detection",
                     blurb: "When Zoom, Meet, Teams or any app starts using your microphone, Parrot notices the call. It only sees that the mic is in use, never the audio.") {
            SettingsBlockRow(title: "When a call starts", first: true) {
                Picker("", selection: $modeRaw) {
                    ForEach(AutoRecordMode.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 380)
            }
            SettingsRow {
                Hint(detail)
            }
            if NotificationAccess.needsWarning(notifications, mode: AutoRecordMode(rawValue: modeRaw) ?? .ask,
                                               reminders: reminders) {
                SettingsLabeledRow(title: "Notifications are off",
                                   detail: "Parrot can't ask to record a call or remind you of a meeting. It only bounces its Dock icon.") {
                    Button(notifications == .notAsked ? "Turn On" : "Open Settings") {
                        Task { notifications = await NotificationAccess.turnOn() }
                    }
                }
            }
            if !ignored.isEmpty {
                SettingsBlockRow(title: "Never asked for") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(ignored, id: \.self) { app in
                            HStack {
                                Text(CallDetector.displayName(for: app))
                                    .font(Theme.Typography.body)
                                Spacer()
                                Button("Ask Again") {
                                    CallWatcher.ignoredApps.remove(app)
                                    ignored = CallWatcher.ignoredApps.sorted()
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                }
            }
        }
        .onAppear { ignored = CallWatcher.ignoredApps.sorted() }
        .task { notifications = await NotificationAccess.state() }
        // Back from System Settings: pick up the new switch.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { notifications = await NotificationAccess.state() }
        }
    }

    private var detail: String {
        switch AutoRecordMode(rawValue: modeRaw) ?? .ask {
        case .off:
            return "Parrot won't watch for calls. Start recordings yourself."
        case .ask:
            return "A notification asks whether to record, and offers to stop when the call ends. Nothing records until you say so."
        case .auto:
            return "Parrot starts recording by itself and stops when the call ends. Recording laws differ by place; many require telling everyone on the call. That's on you in this mode."
        }
    }
}

/// Connect / disconnect the Mac's calendars, and what the calendar may do.
struct CalendarCard: View {
    @Environment(RecordingManager.self) private var recordingManager
    @AppStorage(CalendarService.enabledKey) private var enabled = false
    @AppStorage(CalendarService.useDetailsKey) private var useDetails = false
    @AppStorage(CalendarService.remindersKey) private var reminders = false
    @State private var connecting = false

    private var calendar: CalendarService { recordingManager.calendar }

    var body: some View {
        SettingsCard(title: "Calendar",
                     blurb: "Names each meeting after its calendar event and knows who's invited. Uses the calendars already on your Mac (iCloud, Google, Outlook). Read-only, and nothing leaves your Mac.") {
            SettingsLabeledRow(title: statusTitle, detail: statusDetail, first: true) {
                if calendar.isConnected {
                    Button("Disconnect") {
                        calendar.disconnect()
                        enabled = false
                    }
                } else if calendar.access == .denied {
                    Button("Open Privacy Settings") {
                        PermissionFlow.openSettings(pane: "Privacy_Calendars")
                    }
                } else {
                    Button(connecting ? "Connecting…" : "Connect Calendar") {
                        connecting = true
                        Task {
                            await calendar.connect()
                            enabled = calendar.isConnected
                            connecting = false
                        }
                    }
                    .disabled(connecting)
                }
            }
            if calendar.isConnected {
                SettingsToggleRow(
                    title: "Brief the copilot from the invite",
                    detail: "The live copilot reads the event's title, guests and notes. With a cloud copilot (Claude or a custom server) that text is sent to it, like the transcript is.",
                    isOn: $useDetails
                )
                SettingsToggleRow(
                    title: "Remind me before meetings",
                    detail: "A notification a minute before a meeting with guests or a video link starts.",
                    isOn: $reminders
                )
            }
        }
        .onAppear { calendar.refreshAccess() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            calendar.refreshAccess()
        }
    }

    private var statusTitle: String {
        if calendar.isConnected { return "Connected" }
        return calendar.access == .denied ? "No access" : "Not connected"
    }

    private var statusDetail: String {
        if calendar.isConnected { return "Meetings take their event's name and guest list." }
        if calendar.access == .denied {
            return "Allow Parrot under Privacy & Security → Calendars, then come back."
        }
        return "macOS will ask once for permission to read your calendars."
    }
}

// MARK: - Detected-call banner

/// The in-window twin of the "call started / call ended" notification — so
/// the question still reaches someone with notifications turned off.
struct CallPromptBanner: View {
    let prompt: CallWatcher.Prompt
    let onAccept: () -> Void
    let onDismiss: () -> Void
    var onIgnoreApp: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: prompt.kind == .start ? "phone.arrow.up.right" : "phone.down")
                .foregroundStyle(Theme.Colors.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(Theme.Typography.cardTitle)
                    .foregroundStyle(Theme.Colors.ink)
                    .lineLimit(1)
                Text(subtitle)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.ink2)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button(prompt.kind == .start ? "Record" : "Stop", action: onAccept)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Menu {
                Button(prompt.kind == .start ? "Not Now" : "Keep Recording", action: onDismiss)
                if let onIgnoreApp, prompt.kind == .start, prompt.appID != CallDetector.unknownApp {
                    Button("Never for \(prompt.appName)", action: onIgnoreApp)
                }
            } label: {
                Image(systemName: "xmark")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, Theme.Metrics.popoverPad)
        .padding(.vertical, Theme.Metrics.bannerInsetV)
        .frame(maxWidth: 420, alignment: .leading)
        .background(Theme.Colors.panel, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.Colors.line))
    }

    private var title: String {
        switch prompt.kind {
        case .start: return "\(prompt.appName) call started"
        case .stop: return "Call ended?"
        }
    }

    private var subtitle: String {
        switch prompt.kind {
        case .start: return prompt.eventTitle.map { "Record “\($0)”?" } ?? "Record it with Parrot?"
        case .stop: return "Parrot is still recording."
        }
    }
}
