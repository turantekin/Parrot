import SwiftUI
import AVFoundation

struct OnboardingView: View {
    @Environment(RecordingManager.self) private var recordingManager
    @Binding var isPresented: Bool
    // Persisted so the flow survives the quit-and-reopen macOS may require
    // after granting Screen Recording — the user lands back on this step.
    @AppStorage("onboardingStep") private var currentStep = 0

    var body: some View {
        VStack(spacing: 0) {
            // Content
            Group {
                switch currentStep {
                case 0: welcomeStep
                case 1: permissionsStep
                case 2: modelStep
                case 3: readyStep
                default: welcomeStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Navigation
            HStack {
                if currentStep > 0 {
                    Button("Back") {
                        withAnimation { currentStep -= 1 }
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                // Step indicators
                HStack(spacing: 6) {
                    ForEach(0..<4) { step in
                        Circle()
                            .fill(step == currentStep ? Theme.Colors.accent : Theme.Colors.chip)
                            .frame(width: 8, height: 8)
                    }
                }

                Spacer()

                if currentStep < 3 {
                    Button("Continue") {
                        withAnimation { currentStep += 1 }
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    // Dismissal marks completion: the app-side binding writes
                    // hasCompletedOnboarding when this flips to false.
                    Button("Let's start") {
                        isPresented = false
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(Theme.Metrics.pad)
        }
        // 600, not 540: the model step lists five models now, and at 540 the
        // intro line truncated and the Back/Continue row was clipped.
        .frame(width: 500, height: 600)
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "bird")
                .font(.system(size: 64))
                .foregroundStyle(Theme.Colors.accent)

            Text("Meet Parrot")
                .font(.appLargeTitle)
                .fontWeight(.bold)

            Text("Your private, on-device meeting recorder.\nParrot listens, transcribes, and remembers — all locally on your Mac.")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.ink2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            Spacer()
        }
        .padding(Theme.Metrics.pad)
    }

    // MARK: - Step 2: Permissions

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

    private var permissionsStep: some View {
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

    // MARK: - Step 3: Model Download

    /// Same five the Settings picker offers, same order. Sizes are what the
    /// hub actually serves, not what the folder is called.
    private static let modelChoices: [(tag: String, size: String, blurb: String)] = [
        ("tiny", "~40 MB", "Fastest, basic accuracy"),
        ("base", "~140 MB", "Good balance of speed and accuracy"),
        ("small", "~460 MB", "Better accuracy, moderate speed"),
        ("large-v3-v20240930_626MB", "~626 MB", "Near-best accuracy, light on memory"),
        ("large-v3-turbo", "~1.6 GB", "Best accuracy, needs more RAM"),
    ]

    private var modelStep: some View {
        VStack(spacing: 24) {
            Spacer()

            Text("Choose a Model")
                .font(Theme.Typography.title())

            Text("Parrot uses WhisperKit for transcription.\nLarger models are more accurate but use more memory.")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.ink2)
                .multilineTextAlignment(.center)
                // Without this the VStack compresses it to one truncated line
                // ("…for transcription….") — it lost to the cards for height.
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)

            VStack(spacing: 8) {
                ForEach(Self.modelChoices, id: \.tag) { choice in
                    ModelOption(
                        tag: choice.tag,
                        size: choice.size,
                        description: choice.blurb,
                        isSelected: selectedModel == choice.tag,
                        action: { selectModel(choice.tag) }
                    )
                }
            }
            .frame(maxWidth: 380)

            // Model loading status
            modelLoadingStatus

            Spacer()
        }
        .padding(Theme.Metrics.pad)
    }

    @AppStorage("whisperModel") private var selectedModel = "base"

    private func selectModel(_ model: String) {
        selectedModel = model
        Task {
            await recordingManager.transcriptionEngine.loadModel(model)
        }
    }

    @ViewBuilder
    private var modelLoadingStatus: some View {
        switch recordingManager.transcriptionEngine.modelState {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Preparing model...")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.ink2)
            }
        case .downloading(let progress):
            ModelDownloadProgressView(progress: progress,
                                      modelName: recordingManager.transcriptionEngine.loadingModelName)
        case .ready:
            Label("Model ready!", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Theme.Colors.good)
                .font(Theme.Typography.secondary)
        case .error(let msg):
            Label(msg, systemImage: "xmark.circle")
                .foregroundStyle(Theme.Colors.stop)
                .font(Theme.Typography.caption)
        default:
            Button("Download Model") {
                selectModel(selectedModel)
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Step 4: Ready

    @State private var celebrate = false

    private var readyStep: some View {
        VStack(spacing: 20) {
            Spacer()

            Text("🎉")
                .font(.system(size: 72))
                .scaleEffect(celebrate ? 1.0 : 0.4)
                .opacity(celebrate ? 1 : 0)

            Text("Ready to go!")
                .font(.appLargeTitle)
                .fontWeight(.bold)

            Text("Parrot is set up. Open your next call, hit record, and the transcript stays right here on your Mac.")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.ink2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360)

            Spacer()
        }
        .padding(Theme.Metrics.pad)
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.55).delay(0.05)) {
                celebrate = true
            }
        }
        .onDisappear { celebrate = false }
    }
}

// MARK: - Permission Row

/// One permission as a big tappable row, Anarlog-style. Ask state: a dark,
/// full-width button phrased by outcome ("Help Parrot hear you"). Granted:
/// an inert light row whose copy flips to the confirmation ("Parrot can hear
/// you"). The subtitle keeps the real macOS permission name so people can
/// still recognize the matching System Settings pane.
struct PermissionRow: View {
    let icon: String
    let askTitle: String
    let grantedTitle: String
    let subtitle: String
    var isGranted: Bool = false
    let action: () -> Void

    var body: some View {
        if isGranted {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.appTitle3)
                    .foregroundStyle(Theme.Colors.good)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 1) {
                    Text(grantedTitle)
                        .font(Theme.Typography.cardTitle)
                    Text(subtitle)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.ink3)
                }

                Spacer()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Colors.chip, in: RoundedRectangle(cornerRadius: Theme.Metrics.radius))
        } else {
            Button(action: action) {
                HStack(spacing: 12) {
                    Image(systemName: icon)
                        .font(.appTitle3)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(askTitle)
                            .font(Theme.Typography.cardTitle)
                        Text(subtitle)
                            .font(Theme.Typography.caption)
                            .opacity(0.75)
                    }

                    Spacer()

                    Image(systemName: "arrow.right")
                        .font(Theme.Typography.cardTitle)
                }
                // ink-on-canvas inverted: near-black pill in light mode, light
                // pill in dark mode — high contrast in both without new tokens.
                .foregroundStyle(Theme.Colors.canvas)
                .padding(12)
                .frame(maxWidth: .infinity)
                .background(Theme.Colors.ink, in: RoundedRectangle(cornerRadius: Theme.Metrics.radius))
                .contentShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius))
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Model Option

struct ModelOption: View {
    /// The stored @AppStorage value; the card shows its friendly name, so the
    /// hub's spelling ("large-v3-v20240930_626MB") never reaches a user's eyes.
    let tag: String
    let size: String
    let description: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(TranscriptionEngine.displayName(for: tag))
                        .font(Theme.Typography.cardTitle)
                    Text("\(description) (\(size))")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.ink2)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.Colors.accent)
                }
            }
            .padding(12)
            .background(
                isSelected ? Theme.Colors.accent.opacity(0.1) : Color.clear,
                in: RoundedRectangle(cornerRadius: Theme.Metrics.radius)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Metrics.radius)
                    .stroke(isSelected ? Theme.Colors.accent : Theme.Colors.line, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
