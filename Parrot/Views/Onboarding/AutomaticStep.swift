import SwiftUI

struct AutomaticStep: View {
    @Environment(RecordingManager.self) private var recordingManager
    @AppStorage(AutoRecordMode.defaultsKey) private var autoRecordRaw = AutoRecordMode.ask.rawValue
    @State private var calendarConnecting = false
    @State private var notifications: NotificationAccess.State = .notAsked
    @State private var loginItemOn = LoginItem.state == .on || LoginItem.state == .needsApproval

    var body: some View {
        let calendar = recordingManager.calendar
        return VStack(spacing: 20) {
            Spacer()

            Text("Make it automatic")
                .font(Theme.Typography.title())

            Text("All optional, all on your Mac. Change any of it later in Settings.")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.ink2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)

            VStack(alignment: .leading, spacing: 14) {
                PermissionRow(
                    icon: "calendar",
                    askTitle: calendarConnecting ? "Connecting…" : "Connect your calendar",
                    grantedTitle: "Calendar connected",
                    subtitle: "Names meetings and knows who's invited. Read-only.",
                    isGranted: calendar.isConnected,
                    action: {
                        guard !calendarConnecting else { return }
                        calendarConnecting = true
                        Task { @MainActor in
                            await calendar.connect()
                            calendarConnecting = false
                        }
                    }
                )

                VStack(alignment: .leading, spacing: 6) {
                    Text("When a call starts in Zoom, Meet or Teams")
                        .font(Theme.Typography.cardTitle)
                    Picker("", selection: $autoRecordRaw) {
                        ForEach(AutoRecordMode.allCases) { mode in
                            Text(mode.label).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text(autoRecordRaw == AutoRecordMode.auto.rawValue
                         ? "Records by itself. Many places require telling everyone on the call."
                         : "Parrot only notices the mic is in use, never the audio.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // The "record this call?" offer is a notification: without
                // the permission, call detection quietly does nothing.
                if autoRecordRaw != AutoRecordMode.off.rawValue {
                    PermissionRow(
                        icon: "bell.badge",
                        askTitle: notifications == .off ? "Turn on notifications in Settings" : "Allow notifications",
                        grantedTitle: "Notifications on",
                        subtitle: "So Parrot can ask to record when a call starts.",
                        isGranted: notifications == .on,
                        action: { Task { notifications = await NotificationAccess.turnOn() } }
                    )
                }

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Open Parrot at login")
                            .font(Theme.Typography.cardTitle)
                        Text("So it's ready for your first call of the day.")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.ink2)
                    }
                    Spacer(minLength: 0)
                    Toggle("Open Parrot at login", isOn: Binding(
                        get: { loginItemOn },
                        set: { newValue in
                            let state = LoginItem.set(newValue).state
                            loginItemOn = state == .on || state == .needsApproval
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(LoginItem.state == .unavailable)
                }
            }
            .frame(maxWidth: 380)

            Spacer()
        }
        .padding(Theme.Metrics.pad)
        .task { notifications = await NotificationAccess.state() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { notifications = await NotificationAccess.state() }
        }
    }
}
