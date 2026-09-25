import SwiftUI

struct OnboardingView: View {
    @Environment(RecordingManager.self) private var recordingManager
    @Binding var isPresented: Bool
    // Persisted so the flow survives the quit-and-reopen macOS may require
    // after granting Screen Recording — the user lands back on this step.
    @AppStorage("onboardingStep") private var currentStep = 0
    static let stepCount = 5

    var body: some View {
        VStack(spacing: 0) {
            // Content
            Group {
                switch currentStep {
                case 0: WelcomeStep()
                case 1: PermissionsStep()
                case 2: SpeechModelStep()
                case 3: AutomaticStep()
                case 4: readyStep
                default: WelcomeStep()
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
                    ForEach(0..<Self.stepCount, id: \.self) { step in
                        Circle()
                            .fill(step == currentStep ? Theme.Colors.accent : Theme.Colors.chip)
                            .frame(width: 8, height: 8)
                    }
                }

                Spacer()

                if currentStep < Self.stepCount - 1 {
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

    // MARK: - Step 5: Ready

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
    var isRecommended = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(TranscriptionEngine.displayName(for: tag))
                            .font(Theme.Typography.cardTitle)
                        if isRecommended {
                            Text("Best for your Mac")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Colors.accent)
                                .padding(.horizontal, Theme.Metrics.chipInsetH)
                                .padding(.vertical, Theme.Metrics.chipInsetV)
                                .background(Theme.Colors.spotlight, in: Capsule())
                        }
                    }
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
