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
                    ForEach(0..<3) { step in
                        Circle()
                            .fill(step == currentStep ? Theme.Colors.accent : Theme.Colors.chip)
                            .frame(width: 8, height: 8)
                    }
                }

                Spacer()

                if currentStep < 2 {
                    Button("Continue") {
                        withAnimation { currentStep += 1 }
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Get Started") {
                        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
                        isPresented = false
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(Theme.Metrics.pad)
        }
        .frame(width: 500, height: 540)
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
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        screenGranted = CGPreflightScreenCaptureAccess()
        screenAsked = UserDefaults.standard.bool(forKey: PermissionFlow.screenAskedKey)
    }

    private var permissionsStep: some View {
        VStack(spacing: 24) {
            Spacer()

            Text("Permissions Needed")
                .font(Theme.Typography.title())

            VStack(alignment: .leading, spacing: 16) {
                PermissionRow(
                    icon: "rectangle.inset.filled.and.person.filled",
                    title: "Screen Recording",
                    description: "Required to capture system audio from meetings. Parrot only records audio — never your screen content.",
                    isGranted: screenGranted,
                    action: {
                        if PermissionFlow.requestScreenCapture() == .granted {
                            screenGranted = true
                        }
                        screenAsked = true
                    }
                )

                if screenAsked && !screenGranted {
                    Text("Already flipped the switch? macOS applies Screen Recording when Parrot restarts — quit and reopen Parrot, and this page will pick up right here.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.ink2)
                        .padding(.leading, 44) // align under the row's text column
                }

                PermissionRow(
                    icon: "mic",
                    title: "Microphone",
                    description: "Captures your voice for better speaker identification. Your audio stays on this Mac.",
                    isGranted: micGranted,
                    action: {
                        Task { @MainActor in
                            micGranted = await PermissionFlow.requestMicrophone()
                        }
                    }
                )
            }
            .frame(maxWidth: 380)

            Text("All processing happens locally. Nothing leaves your Mac.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.ink2)

            Spacer()
        }
        .padding(Theme.Metrics.pad)
        .onAppear(perform: refreshPermissions)
        // Rows flip green on their own: returning from System Settings fires
        // didBecomeActive, and the 1 s poll catches grants made while the OS
        // dialog (a separate process) had focus.
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

    private var modelStep: some View {
        VStack(spacing: 24) {
            Spacer()

            Text("Choose a Model")
                .font(Theme.Typography.title())

            Text("Parrot uses WhisperKit for transcription.\nLarger models are more accurate but use more memory.")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.ink2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)

            VStack(spacing: 8) {
                ModelOption(
                    name: "tiny",
                    size: "~40 MB",
                    description: "Fastest, basic accuracy",
                    isSelected: selectedModel == "tiny",
                    action: { selectModel("tiny") }
                )
                ModelOption(
                    name: "base",
                    size: "~140 MB",
                    description: "Good balance of speed and accuracy",
                    isSelected: selectedModel == "base",
                    action: { selectModel("base") }
                )
                ModelOption(
                    name: "small",
                    size: "~460 MB",
                    description: "Better accuracy, moderate speed",
                    isSelected: selectedModel == "small",
                    action: { selectModel("small") }
                )
                ModelOption(
                    name: "large-v3-turbo",
                    size: "~1.5 GB",
                    description: "Best accuracy, needs more RAM",
                    isSelected: selectedModel == "large-v3-turbo",
                    action: { selectModel("large-v3-turbo") }
                )
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
                Text("Downloading and loading model...")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.ink2)
            }
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
}

// MARK: - Permission Row

struct PermissionRow: View {
    let icon: String
    let title: String
    let description: String
    var isGranted: Bool = false
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.appTitle2)
                .foregroundStyle(Theme.Colors.accent)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(Theme.Typography.cardTitle)
                Text(description)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.ink2)
            }

            Spacer()

            if isGranted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.Colors.good)
                    .font(.appTitle3)
            } else {
                Button("Grant") {
                    action()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }
}

// MARK: - Model Option

struct ModelOption: View {
    let name: String
    let size: String
    let description: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
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
