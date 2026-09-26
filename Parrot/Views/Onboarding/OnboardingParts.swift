import SwiftUI

/// Title and one line, centred: the top of every step.
struct StepHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(Theme.Typography.title(24))
            if let subtitle {
                Text(subtitle)
                    .font(Theme.Typography.sans(14))
                    .foregroundStyle(Theme.Colors.ink2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 460)
    }
}

/// The big Copilot card: sparkles, one line on how it runs, and whatever
/// sits on the right (the on/off switch, a check, a close button).
struct CopilotHeroCard<Accessory: View>: View {
    let title: String
    let subtitle: String
    var emphasized = true
    var bordered = true
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.appTitle2)
                .foregroundStyle(Theme.Colors.accent)
                .frame(width: 44, height: 44)
                .background(Theme.Colors.spotlight, in: RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Typography.heroTitle)
                Text(subtitle)
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Colors.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            accessory()
        }
        .padding(bordered ? Theme.Metrics.pad : 0)
        .overlay {
            if bordered {
                RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius)
                    .stroke(emphasized ? Theme.Colors.spotlightLine : Theme.Colors.line,
                            lineWidth: emphasized ? 1.5 : 1)
            }
        }
    }
}

/// A download that carries on in the background. nil progress = starting.
struct DownloadRow: View {
    let title: String
    let progress: Double?
    let note: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "arrow.down.circle")
                .font(.appTitle3)
                .foregroundStyle(Theme.Colors.warn)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(progress.map { "\(title)… \(Int($0 * 100))%" } ?? "\(title)…")
                    .font(Theme.Typography.cardTitle)
                ProgressView(value: progress)
                Text(note)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.ink2)
            }
        }
        .padding(Theme.Metrics.popoverPad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.chip, in: RoundedRectangle(cornerRadius: Theme.Metrics.radius))
    }
}

/// A step that can't start yet.
struct PendingRow: View {
    let title: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "circle")
                .font(.appTitle3)
                .frame(width: 24)
            Text(title)
                .font(Theme.Typography.cardTitle)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.Colors.ink3)
        .padding(Theme.Metrics.popoverPad)
    }
}

/// The Whisper model's state, from the engine that owns the download (it
/// outlives the sheet).
struct SpeechDownloadRow: View {
    @Environment(RecordingManager.self) private var recordingManager
    var backup = false

    var body: some View {
        switch recordingManager.transcriptionEngine.modelState {
        case .downloading(let progress):
            DownloadRow(title: backup ? "Downloading backup speech model" : "Downloading speech model",
                        progress: progress,
                        note: "You can keep going. It carries on after this window closes.")
        case .loading:
            DownloadRow(title: "Preparing speech model", progress: nil, note: "Almost done.")
        case .ready:
            PermissionRow(icon: "waveform", askTitle: "", grantedTitle: "Speech model ready",
                          subtitle: "Turns what's said into text on this Mac", isGranted: true, action: {})
        case .error(let message):
            HStack {
                Label(message, systemImage: "xmark.circle")
                    .foregroundStyle(Theme.Colors.stop)
                Button("Retry") {
                    Task {
                        await recordingManager.transcriptionEngine.loadModel(
                            UserDefaults.standard.string(forKey: "whisperModel") ?? "base")
                    }
                }
            }
            .font(Theme.Typography.caption)
        case .notLoaded:
            EmptyView()
        }
    }
}
