import SwiftUI

/// Private / Balanced / Cloud, plus Decide later on the full tour.
struct CopilotPathStep: View {
    @Environment(OnboardingModel.self) private var model
    @AppStorage(CloudGate.globalKey) private var onDeviceOnly = false

    var body: some View {
        VStack(spacing: 14) {
            StepHeader(title: "How should Copilot work?",
                       subtitle: "Pick how private you want it. You can change this later.")
            VStack(spacing: 10) {
                card(.private, icon: "lock", title: "Private",
                     detail: "Copilot runs on this Mac. Nothing leaves it. Free. Uses the Ollama app.")
                card(.balanced, icon: "slider.horizontal.3", title: "Balanced",
                     detail: "Audio stays on this Mac. Only text goes to Claude. Smartest answers. Needs a Claude key.",
                     badge: "Recommended")
                card(.cloud, icon: "cloud", title: "Cloud",
                     detail: "Live word-by-word text plus Claude. Needs Deepgram and Claude keys.")
            }
            .frame(maxWidth: 480)
            if onDeviceOnly {
                Text("Balanced and Cloud are off because On-device only is on in Settings → Privacy.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.ink2)
            }
            if model.mode == .full {
                Button("Decide later") { withAnimation { model.decideLater() } }
                    .buttonStyle(.link)
            }
            if let error = model.pathError {
                Text(error)
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Colors.stop)
            }
        }
        .padding(Theme.Metrics.pad)
    }

    private func card(_ path: CopilotPath, icon: String, title: String, detail: String,
                      badge: String? = nil) -> some View {
        let locked = onDeviceOnly && path != .private
        let selected = model.path == path
        let shape = RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius)
        return Button { model.path = path } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.appTitle3)
                    .foregroundStyle(selected ? Theme.Colors.accent : Theme.Colors.ink)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(Theme.Typography.heroTitle)
                        if let badge {
                            Text(badge)
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Colors.accent)
                                .padding(.horizontal, Theme.Metrics.chipInsetH)
                                .padding(.vertical, Theme.Metrics.chipInsetV)
                                .background(Theme.Colors.spotlight, in: Capsule())
                        }
                    }
                    Text(detail)
                        .font(Theme.Typography.secondary)
                        .foregroundStyle(Theme.Colors.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.Colors.accent)
                }
            }
            .padding(Theme.Metrics.popoverPad)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Theme.Colors.spotlight : .clear, in: shape)
            .overlay(shape.stroke(selected ? Theme.Colors.spotlightLine : Theme.Colors.line,
                                  lineWidth: selected ? 1.5 : 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(locked)
        .opacity(locked ? 0.45 : 1)
    }
}
