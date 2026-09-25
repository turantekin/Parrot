import SwiftUI

/// Picks the Whisper model, preselecting what fits this Mac's memory, and
/// starts the download right away. The engine owns the download, so it
/// keeps going after this step or the whole sheet goes away.
struct SpeechModelStep: View {
    @Environment(RecordingManager.self) private var recordingManager
    @AppStorage("whisperModel") private var selectedModel = "base"
    @State private var showAll = false
    private let memoryGB = MachineFit.memoryGB()

    /// Same five the Settings picker offers, same order. Sizes are what the
    /// hub actually serves, not what the folder is called.
    static let modelChoices: [(tag: String, size: String, blurb: String)] = [
        ("tiny", "~40 MB", "Fastest, basic accuracy"),
        ("base", "~140 MB", "Good balance of speed and accuracy"),
        ("small", "~460 MB", "Better accuracy, moderate speed"),
        ("large-v3-v20240930_626MB", "~626 MB", "Near-best accuracy, light on memory"),
        ("large-v3-turbo", "~1.6 GB", "Best accuracy, needs more RAM"),
    ]
    private static let shortList: Set<String> = ["base", "large-v3-v20240930_626MB", "large-v3-turbo"]

    var body: some View {
        let recommended = MachineFit.whisperModel(memoryGB: memoryGB)
        VStack(spacing: 14) {
            StepHeader(title: "Speech to text",
                       subtitle: "Turns what's said into text, right on this Mac.\nYour Mac has \(memoryGB) GB of memory, so we picked:")
            VStack(spacing: 8) {
                ForEach(Self.modelChoices.filter { showAll || Self.shortList.contains($0.tag) || $0.tag == selectedModel },
                        id: \.tag) { choice in
                    ModelOption(tag: choice.tag, size: choice.size, description: choice.blurb,
                                isSelected: selectedModel == choice.tag,
                                isRecommended: choice.tag == recommended,
                                action: { select(choice.tag) })
                }
            }
            .frame(maxWidth: 460)
            if !showAll {
                Button("Show all 5 models") { showAll = true }
                    .buttonStyle(.link)
            }
            SpeechDownloadRow()
                .frame(maxWidth: 460)
        }
        .padding(Theme.Metrics.pad)
        .onAppear {
            // The help-shot harness sets this so screenshots never start a
            // model download.
            if UserDefaults.standard.bool(forKey: "onboardingNoAutoDownload") { return }
            if UserDefaults.standard.object(forKey: "whisperModel") == nil {
                select(recommended)
                return
            }
            switch recordingManager.transcriptionEngine.modelState {
            case .notLoaded, .error: select(selectedModel)
            default: break
            }
        }
    }

    private func select(_ tag: String) {
        selectedModel = tag
        let engine = recordingManager.transcriptionEngine
        // Launch already started loading this one; don't restart it.
        // (`where` binds to one pattern only, so each case carries its own.)
        switch engine.modelState {
        case .downloading where engine.loadingModelName == TranscriptionEngine.displayName(for: tag),
             .loading where engine.loadingModelName == TranscriptionEngine.displayName(for: tag):
            return
        default:
            Task { await engine.loadModel(tag) }
        }
    }
}
