import SwiftUI

struct OnboardingView: View {
    @Binding var isPresented: Bool
    /// Rebuilt each time the sheet is presented, so it reads the current
    /// mode (full tour or Set up Copilot) and saved step.
    @State private var model = OnboardingModel()

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch model.step {
                case .welcome: WelcomeStep()
                case .permissions: PermissionsStep()
                case .meetCopilot: MeetCopilotStep()
                case .copilotPath: CopilotPathStep()
                case .speechModel: SpeechModelStep()
                case .copilotSetup: CopilotSetupStep()
                case .automatic: AutomaticStep()
                case .ready: ReadyStep()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .environment(model)

            Divider()

            HStack {
                if !model.isFirst {
                    Button("Back") { withAnimation { model.move(-1) } }
                        .buttonStyle(.plain)
                }
                Spacer()
                HStack(spacing: 6) {
                    ForEach(model.steps, id: \.self) { step in
                        Circle()
                            .fill(step == model.step ? Theme.Colors.accent : Theme.Colors.chip)
                            .frame(width: 8, height: 8)
                    }
                }
                Spacer()
                if model.isLast {
                    // Dismissal marks completion: the app-side binding writes
                    // hasCompletedOnboarding when this flips to false.
                    Button(model.mode == .copilot ? "Done" : "Let's start") {
                        model.finish()
                        isPresented = false
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Continue") { withAnimation { model.move(1) } }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(Theme.Metrics.pad)
        }
        .frame(width: 600, height: 680)
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
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.ink3)
                    }
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
                        if !subtitle.isEmpty {
                            Text(subtitle)
                                .font(Theme.Typography.caption)
                                .opacity(0.75)
                        }
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
