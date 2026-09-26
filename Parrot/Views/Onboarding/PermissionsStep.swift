import SwiftUI
import AVFoundation

struct PermissionsStep: View {
    @State private var micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var screenGranted = false
    @State private var screenAsked = UserDefaults.standard.bool(forKey: PermissionFlow.screenAskedKey)

    // CGPreflight is side-effect-free — querying SCShareableContent instead
    // triggered the macOS permission prompt before the user hit Grant.
    private func refreshPermissions() {
        // Harness seam: --help-shots sets this (the register(defaults:) trick)
        // to render the granted look without touching this Mac's real grants.
        if UserDefaults.standard.bool(forKey: "onboardingSnapshotGranted") {
            micGranted = true
            screenGranted = true
            return
        }
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        if #available(macOS 15.0, *) {
            // Audio-only tap permission. "Granted" is inferred (proven audio or
            // a Screen Recording grant) — there is no status API to ask.
            screenGranted = PermissionFlow.systemAudioLooksGranted()
            screenAsked = UserDefaults.standard.bool(forKey: PermissionFlow.tapAskedKey)
        } else {
            screenGranted = CGPreflightScreenCaptureAccess()
            screenAsked = UserDefaults.standard.bool(forKey: PermissionFlow.screenAskedKey)
        }
    }

    /// The subtitle keeps the real macOS permission name so people can match
    /// it to the System Settings pane. On 15+ that's the audio-only category.
    private var systemAudioSubtitle: String {
        if #available(macOS 15.0, *) {
            return "System Audio Recording, the other side of the call"
        }
        return "Screen Recording, the other side of the call"
    }

    private var systemAudioPendingHint: String {
        if #available(macOS 15.0, *) {
            return "Clicked Allow on the macOS prompt? You're set — this row turns green the first time Parrot hears meeting audio. No restart needed."
        }
        return "Already flipped the switch? macOS applies Screen Recording when Parrot restarts — quit and reopen Parrot, and this page will pick up right here."
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Text("Start with permissions")
                .font(Theme.Typography.title())

            Text("Parrot needs two macOS permissions to hear your calls. Audio only: it never sees your screen, and nothing leaves your Mac.")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.ink2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)

            VStack(alignment: .leading, spacing: 10) {
                PermissionRow(
                    icon: "mic",
                    askTitle: "Help Parrot hear you",
                    grantedTitle: "Parrot can hear you",
                    subtitle: "Microphone, your side of the call",
                    isGranted: micGranted,
                    action: {
                        Task { @MainActor in
                            micGranted = await PermissionFlow.requestMicrophone()
                        }
                    }
                )

                PermissionRow(
                    icon: "speaker.wave.2",
                    askTitle: "Help Parrot hear your meeting",
                    grantedTitle: "Parrot can hear your meeting",
                    subtitle: systemAudioSubtitle,
                    isGranted: screenGranted,
                    action: {
                        if #available(macOS 15.0, *) {
                            if PermissionFlow.requestSystemAudioCapture() == .granted {
                                screenGranted = true
                            }
                        } else if PermissionFlow.requestScreenCapture() == .granted {
                            screenGranted = true
                        }
                        screenAsked = true
                    }
                )

                if screenAsked && !screenGranted {
                    Text(systemAudioPendingHint)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.ink2)
                }
            }
            .frame(maxWidth: 380)
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: micGranted)
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: screenGranted)

            Spacer()
        }
        .padding(Theme.Metrics.pad)
        .onAppear(perform: refreshPermissions)
        // Rows flip to their granted look on their own: returning from System
        // Settings fires didBecomeActive, and the 1 s poll catches grants made
        // while the OS dialog (a separate process) had focus.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
        .task {
            while !Task.isCancelled {
                refreshPermissions()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
}
