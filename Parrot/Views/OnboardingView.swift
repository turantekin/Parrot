import SwiftUI
import AVFoundation

struct OnboardingView: View {
    @Environment(RecordingManager.self) private var recordingManager
    @Binding var isPresented: Bool
    @State private var currentStep = 0

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
                            .fill(step == currentStep ? Color.accentColor : Color.secondary.opacity(0.3))
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
            .padding()
        }
        .frame(width: 500, height: 540)
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "bird")
                .font(.system(size: 64))
                .foregroundStyle(Color.accentColor)

            Text("Meet Parrot")
                .font(.appLargeTitle)
                .fontWeight(.bold)

            Text("Your private, on-device meeting recorder.\nParrot listens, transcribes, and remembers — all locally on your Mac.")
                .font(.appBody)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            Spacer()
        }
        .padding()
    }

    // MARK: - Step 2: Permissions

    @State private var micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var screenGranted = false

    private var permissionsStep: some View {
        VStack(spacing: 24) {
            Spacer()

            Text("Permissions Needed")
                .font(.appTitle)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 16) {
                PermissionRow(
                    icon: "rectangle.inset.filled.and.person.filled",
                    title: "Screen Recording",
                    description: "Required to capture system audio from meetings. Parrot only records audio — never your screen content.",
                    isGranted: screenGranted,
                    action: {
                        // Single official prompt if never asked; if previously
                        // denied macOS won't re-prompt, so open Settings instead.
                        if CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() {
                            screenGranted = true
                        } else {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                        }
                    }
                )

                PermissionRow(
                    icon: "mic",
                    title: "Microphone",
                    description: "Captures your voice for better speaker identification. Your audio stays on this Mac.",
                    isGranted: micGranted,
                    action: {
                        // Trigger system permission dialog
                        AVCaptureDevice.requestAccess(for: .audio) { granted in
                            Task { @MainActor in
                                micGranted = granted
                                if !granted {
                                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                                }
                            }
                        }
                    }
                )
            }
            .frame(maxWidth: 380)

            Text("All processing happens locally. Nothing leaves your Mac.")
                .font(.appCaption)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding()
        .onAppear {
            // Check current permission status. CGPreflight is side-effect-free —
            // querying SCShareableContent here triggered the macOS permission
            // prompt the moment the step appeared, before the user hit Grant.
            micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            screenGranted = CGPreflightScreenCaptureAccess()
        }
    }

    // MARK: - Step 3: Model Download

    private var modelStep: some View {
        VStack(spacing: 24) {
            Spacer()

            Text("Choose a Model")
                .font(.appTitle)
                .fontWeight(.semibold)

            Text("Parrot uses WhisperKit for transcription.\nLarger models are more accurate but use more memory.")
                .font(.appBody)
                .foregroundStyle(.secondary)
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
        .padding()
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
                    .font(.appCaption)
                    .foregroundStyle(.secondary)
            }
        case .ready:
            Label("Model ready!", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.appCallout)
        case .error(let msg):
            Label(msg, systemImage: "xmark.circle")
                .foregroundStyle(.red)
                .font(.appCaption)
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
                .foregroundStyle(Color.accentColor)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.appHeadline)
                Text(description)
                    .font(.appCaption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isGranted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
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
                        .font(.appHeadline)
                    Text("\(description) (\(size))")
                        .font(.appCaption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(10)
            .background(
                isSelected ? Color.accentColor.opacity(0.1) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
