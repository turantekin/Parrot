import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Settings pages, System Settings-style: topics on the left, ONE topic per
/// page on the right. Content rules: controls at body size, hints one line at
/// secondary size — long explanations live in the control's own label instead.
enum SettingsSection: String, CaseIterable, Identifiable {
    case general, recording, transcription, copilot, apiKeys, knowledge, profiles, connections, privacy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .recording: "Recording"
        case .transcription: "Transcription"
        case .copilot: "Copilot"
        case .apiKeys: "API Keys"
        case .knowledge: "Knowledge"
        case .profiles: "Profiles"
        case .connections: "Connections"
        case .privacy: "Privacy"
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .recording: "mic"
        case .transcription: "text.quote"
        case .copilot: "sparkles"
        case .apiKeys: "key"
        case .knowledge: "books.vertical"
        case .profiles: "person.2"
        case .connections: "arrow.triangle.branch"
        case .privacy: "lock.shield"
        }
    }
}

struct SettingsView: View {
    /// True when rendered inside the main window's detail pane (wide, fills the
    /// space); false for the standalone Cmd-, Settings window, which needs a
    /// fixed sane size.
    var isEmbedded = false

    init(isEmbedded: Bool = false, initialSection: SettingsSection = .general) {
        self.isEmbedded = isEmbedded
        _section = State(initialValue: initialSection)
    }

    @Environment(RecordingManager.self) private var recordingManager
    @AppStorage("whisperModel") private var selectedModel = "base"
    @AppStorage("appearance") private var appearance = Appearance.system
    @AppStorage("copilotEnabled") private var copilotEnabled = false
    @AppStorage("copilotProvider") private var copilotProvider = CopilotProviderKind.claude.rawValue
    @AppStorage("copilotPace") private var copilotPace = CopilotPace.fast.rawValue
    @AppStorage("copilotWindow") private var copilotWindow = CopilotWindow.standard.rawValue
    /// "" = same backend as live cards.
    @AppStorage("reportsProvider") private var reportsProvider = ""
    /// "" = same backend as reports.
    @AppStorage("askProvider") private var askProvider = ""
    @AppStorage("copilotOllamaModel") private var copilotOllamaModel = "llama3.2:3b"
    @AppStorage("copilotCustomBaseURL") private var copilotCustomBaseURL = ""
    @AppStorage("copilotCustomModel") private var copilotCustomModel = ""
    /// True after picking "Custom…" in the Ollama model dropdown, so the free
    /// text field stays visible even while the typed name matches nothing.
    @State private var ollamaCustomModelEditing = false
    @AppStorage("transcriptionLanguage") private var transcriptionLanguage = "auto"
    @AppStorage("customVocabulary") private var customVocabulary = ""
    @AppStorage("echoCancellationEnabled") private var echoCancellation = true
    @AppStorage(TranscriptionBackend.defaultsKey) private var transcriptionBackend = TranscriptionBackend.local.rawValue
    @AppStorage("polishAfterCall") private var polishAfterCall = false
    @AppStorage("livePreview") private var livePreview = true
    @State private var section: SettingsSection = .general
    @State private var diarizerDownloading = false
    @AppStorage("rememberVoices") private var rememberVoices = false
    @AppStorage(RecordingManager.globalMarkHotKeyDefaultsKey) private var globalMarkHotKey = true
    @AppStorage("liveSpeakerLabels") private var liveSpeakerLabels = false
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SpeakerProfile.name) private var voiceProfiles: [SpeakerProfile]
    @Query(sort: \CallProfile.sortOrder) private var allProfiles: [CallProfile]
    @State private var showFileImporter = false
    /// There's no Save button — @AppStorage persists on every change. This
    /// drives a small transient "Saved" chip so that's visible, debounced so
    /// typing in a field shows one toast when the user pauses, not per key.
    @State private var showSavedToast = false
    @State private var savedToastTask: Task<Void, Never>?
    /// Mirrors Sparkle's own setting so the toggle survives a relaunch without
    /// us storing a second copy of the truth.
    @State private var automaticUpdates = AppUpdater.shared.automaticallyUpdates

    /// Opens the bundled Help Book at a specific page anchor (hiutil indexes
    /// anchors — the -a in assemble-help.sh). Dev binaries carry no book, so
    /// Help Viewer just no-ops there.
    static func openHelp(anchor: String) {
        let book = Bundle.main.object(forInfoDictionaryKey: "CFBundleHelpBookName") as? String
        NSHelpManager.shared.openHelpAnchor(anchor, inBook: book)
    }

    /// Deep-links into one section from anywhere (dashboard, live panel): the
    /// request is parked in defaults, the Settings window is opened or brought
    /// forward, and whichever SettingsView is showing picks it up in onAppear
    /// (fresh window) or via the notification (already open).
    static let requestedSectionKey = "settingsRequestedSection"
    static func open(_ target: SettingsSection, with openSettings: OpenSettingsAction) {
        UserDefaults.standard.set(target.rawValue, forKey: requestedSectionKey)
        openSettings()
        NotificationCenter.default.post(name: .parrotOpenSettingsSection, object: nil)
    }

    private func consumeRequestedSection() {
        guard let raw = UserDefaults.standard.string(forKey: Self.requestedSectionKey),
              let target = SettingsSection(rawValue: raw) else { return }
        UserDefaults.standard.removeObject(forKey: Self.requestedSectionKey)
        section = target
    }

    /// One Equatable snapshot of every auto-saved setting on this screen —
    /// a single onChange instead of one per field.
    private var settingsFingerprint: String {
        "\(selectedModel)|\(appearance)|\(copilotEnabled)|\(transcriptionLanguage)|"
            + "\(customVocabulary)|\(echoCancellation)|\(transcriptionBackend)|\(polishAfterCall)|"
            + "\(copilotPace)|\(copilotWindow)|\(livePreview)"
    }

    private func flashSavedToast() {
        savedToastTask?.cancel()
        savedToastTask = Task {
            // Debounce: wait for the user to pause before announcing the save.
            try? await Task.sleep(for: .seconds(0.8))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { showSavedToast = true }
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.3)) { showSavedToast = false }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // MARK: Section nav
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsSection.allCases) { item in
                    SettingsNavRow(title: item.title, icon: item.icon, selected: section == item) {
                        section = item
                    }
                }
                Spacer()
                // Pinned at the bottom: a hello from the author (jumps to the
                // help book's "Hi from Uygar" page) and the standard macOS
                // help button for the guide itself.
                HStack(spacing: 6) {
                    SettingsNavRow(title: "About", icon: "hand.wave", selected: false) {
                        Self.openHelp(anchor: "hi-from-uygar")
                    }
                    HelpCircleButton { NSApp.showHelp(nil) }
                }
            }
            .padding(8)
            .frame(width: 168)
            .background(Theme.Colors.panel)

            Divider()

            // MARK: Page
            Group {
                switch section {
                case .general: generalPage
                case .recording: recordingPage
                case .transcription: transcriptionPage
                case .copilot: copilotPage
                case .apiKeys: apiKeysPage
                case .knowledge: knowledgePage
                case .profiles: ProfilesSettingsView()
                case .connections: ConnectionsSettingsPage()
                case .privacy: PrivacySettingsPage()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .formStyle(.grouped)
        .onAppear { consumeRequestedSection() }
        .onReceive(NotificationCenter.default.publisher(for: .parrotOpenSettingsSection)) { _ in
            consumeRequestedSection()
        }
        .onChange(of: settingsFingerprint) { flashSavedToast() }
        .overlay(alignment: .bottom) {
            if showSavedToast {
                Label("Saved", systemImage: "checkmark.circle.fill")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.ink)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.Colors.line))
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .frame(width: isEmbedded ? nil : 780, height: isEmbedded ? nil : 620)
        .frame(maxWidth: isEmbedded ? .infinity : nil,
               maxHeight: isEmbedded ? .infinity : nil)
    }

    // MARK: - General

    private var generalPage: some View {
        let path = AudioCaptureManager.storageDirectory().path
        return SettingsPage {
            SettingsCard(title: "Startup") {
                LoginItemRow(first: true)
            }

            SettingsCard(title: "Appearance") {
                SettingsLabeledRow(title: "Appearance", first: true) {
                    Picker("", selection: $appearance) {
                        Text("System").tag(Appearance.system)
                        Text("Light").tag(Appearance.light)
                        Text("Dark").tag(Appearance.dark)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 220)
                }
            }

            SettingsCard(title: "Storage") {
                SettingsRow(first: true) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Audio files")
                                .font(Theme.Typography.body)
                            Text(path)
                                .font(Theme.Typography.secondary)
                                .foregroundStyle(Theme.Colors.ink2)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 12)
                        Button("Show in Finder") {
                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
                        }
                    }
                }
            }

            SettingsCard(title: "About") {
                SettingsLabeledRow(title: "Version", first: true) {
                    Text("Parrot \(AppUpdater.currentVersion)")
                        .font(Theme.Typography.secondary)
                        .foregroundStyle(Theme.Colors.ink2)
                }
                SettingsToggleRow(
                    title: "Keep Parrot up to date",
                    detail: "Downloads new versions in the background and installs them when you quit. Never during a recording.",
                    isOn: $automaticUpdates
                )
                .onChange(of: automaticUpdates) {
                    AppUpdater.shared.automaticallyUpdates = automaticUpdates
                }
                SettingsLabeledRow(title: "Check for updates", detail: "Or look right now.") {
                    Button("Check Now") { AppUpdater.shared.checkForUpdates() }
                }
                SettingsLabeledRow(title: "User guide", detail: "Every screen explained, with setup and troubleshooting.") {
                    Button("Open User Guide") { NSApp.showHelp(nil) }
                }
                SettingsLabeledRow(title: "Welcome tour", detail: "The first-run tour: permissions and model choice.") {
                    Button("Show Welcome Tour") { MeetingActions.showWelcomeTour() }
                }
                SettingsLabeledRow(title: "Website", detail: "The landing page, with a demo you can scroll and the honest privacy list.") {
                    Button("Open openparrot.app") { MeetingActions.open(MeetingActions.websiteURL) }
                }
            }
        }
    }

    // MARK: - Recording

    private var recordingPage: some View {
        SettingsPage {
            SettingsCard(title: "Echo Cancellation") {
                SettingsToggleRow(
                    title: "Cancel speaker echo from the mic",
                    detail: "On speakers, this keeps the other person's voice out of your \"Me\" track. Turn off with headphones.",
                    first: true,
                    isOn: $echoCancellation
                )
            }

            SettingsCard(title: "Input") {
                SettingsRow(first: true) {
                    Hint("System audio comes straight from macOS (audio only, never the screen); the microphone uses your default input device.")
                }
            }

            CallDetectionCard()

            CalendarCard()

            SettingsCard(title: "Bookmarks") {
                SettingsToggleRow(
                    title: "Mark moments from any app with \(GlobalHotKey.Combo.markMoment.display)",
                    detail: "While a call records, \(GlobalHotKey.Combo.markMoment.display) marks the moment even when Zoom or your browser is in front. Parrot only hears that one shortcut, never other keys, and only during a recording.",
                    first: true,
                    isOn: $globalMarkHotKey
                )
                .onChange(of: globalMarkHotKey) { recordingManager.refreshMarkHotKey() }
            }
        }
    }

    // MARK: - Transcription

    private var transcriptionPage: some View {
        SettingsPage {
            SettingsCard(title: "Engine") {
                SettingsBlockRow(title: "Engine", first: true) {
                    Picker("", selection: $transcriptionBackend) {
                        Text("On-device Whisper — private, free").tag(TranscriptionBackend.local.rawValue)
                        Text("Groq cloud — big-model accuracy, ~$0.08/hr").tag(TranscriptionBackend.groq.rawValue)
                        Text("Deepgram cloud — word-by-word streaming, ~$0.70/hr").tag(TranscriptionBackend.deepgram.rawValue)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()

                    if transcriptionBackend == TranscriptionBackend.local.rawValue {
                        Hint("Every second of audio stays on this Mac.")
                    } else {
                        HStack(spacing: 10) {
                            Hint("Cloud engines need a key, and fall back to on-device if it's missing.")
                            Button("Open API Keys") { section = .apiKeys }
                        }
                    }
                }
                SettingsToggleRow(
                    title: "Polish transcript after each call",
                    detail: "Re-transcribes the saved audio with a large Groq model (~$0.08/hr) and regenerates the report.",
                    isOn: $polishAfterCall
                )
                SettingsToggleRow(
                    title: "Show words as they're spoken",
                    detail: "Gray preview text while someone is mid-sentence, replaced by the final line. On-device engine only; turn off if calls make your Mac run hot. Applies to the next recording.",
                    isOn: $livePreview
                )
            }

            SettingsCard(title: "On-Device Model") {
                SettingsBlockRow(title: "Model", first: true) {
                    Picker("", selection: $selectedModel) {
                        Text("Tiny — 40 MB, fastest").tag("tiny")
                        Text("Base — 140 MB, good balance").tag("base")
                        Text("Small — 460 MB, better accuracy").tag("small")
                        Text("Large V3 Turbo Compressed — 626 MB, fast, low memory").tag("large-v3-v20240930_626MB")
                        Text("Large V3 Turbo — 1.6 GB, best accuracy").tag("large-v3-turbo")
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                }
                SettingsRow {
                    HStack(spacing: 12) {
                        modelStatusView
                        Spacer(minLength: 12)
                        Button("Download / Reload Model") {
                            Task {
                                await recordingManager.transcriptionEngine.loadModel(selectedModel)
                            }
                        }
                    }
                }
            }

            SettingsCard(
                title: "Speaker Detection",
                blurb: "Tells apart the different people on a call, on this Mac. Downloads automatically after a call if missing. Uses pyannote models via FluidAudio (CC-BY-4.0)."
            ) {
                if DiarizationEngine.modelsInstalled {
                    SettingsLabeledRow(title: "Models", detail: "Downloaded (~13 MB)", first: true) {
                        Button("Remove Models") { DiarizationEngine.removeModels() }
                    }
                } else {
                    SettingsLabeledRow(title: "Models", detail: "Not downloaded", first: true) {
                        Button(diarizerDownloading ? "Downloading…" : "Download (~13 MB)") {
                            diarizerDownloading = true
                            Task {
                                try? await recordingManager.diarizationEngine.ensureModels()
                                diarizerDownloading = false
                            }
                        }
                        .disabled(diarizerDownloading)
                    }
                }
                SettingsToggleRow(
                    title: "Live speaker labels",
                    detail: "Experimental. During a call, tells the other people apart every 30 seconds instead of waiting for the end. The final pass when the call ends is still the accurate one.",
                    isOn: $liveSpeakerLabels
                )
                SettingsToggleRow(
                    title: "Remember voices",
                    detail: "When on, naming a speaker saves their voiceprint on this Mac so future calls can suggest who's talking. Never leaves your Mac; delete anytime.",
                    isOn: $rememberVoices
                )
                if rememberVoices {
                    ForEach(voiceProfiles) { profile in
                        SettingsLabeledRow(title: profile.name, detail: "heard \(profile.sampleCount)×") {
                            Button("Forget") {
                                SpeakerProfileStore.delete(profile, in: modelContext)
                            }
                        }
                    }
                    if !voiceProfiles.isEmpty {
                        SettingsRow {
                            Button("Forget All Voices") {
                                SpeakerProfileStore.deleteAll(in: modelContext)
                            }
                        }
                    }
                }
            }

            SettingsCard(title: "Language") {
                SettingsLabeledRow(
                    title: "Language",
                    detail: "Applies to the next recording. Pick a language only if auto-detect keeps guessing wrong.",
                    first: true
                ) {
                    Picker("", selection: $transcriptionLanguage) {
                        Text("Auto-detect").tag("auto")
                        Text("English").tag("en")
                        Text("Turkish").tag("tr")
                        Text("Spanish").tag("es")
                        Text("German").tag("de")
                        Text("French").tag("fr")
                        Text("Italian").tag("it")
                        Text("Portuguese").tag("pt")
                        Text("Dutch").tag("nl")
                        Text("Russian").tag("ru")
                        Text("Arabic").tag("ar")
                        Text("Chinese").tag("zh")
                        Text("Japanese").tag("ja")
                        Text("Korean").tag("ko")
                        Text("Hindi").tag("hi")
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
            }

            SettingsCard(title: "Custom Vocabulary") {
                SettingsBlockRow(
                    title: "Names and jargon Whisper mis-hears",
                    detail: "Comma or line separated (e.g. LaunchEase, Uygar).",
                    first: true
                ) {
                    TextEditor(text: $customVocabulary)
                        .frame(height: 64)
                        .font(Theme.Typography.secondary)
                        .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.radius).strokeBorder(Theme.Colors.line))
                }
            }
        }
    }

    @ViewBuilder
    private var modelStatusView: some View {
        switch recordingManager.transcriptionEngine.modelState {
        case .ready:
            Label("Model loaded and ready", systemImage: "checkmark.circle")
                .foregroundStyle(Theme.Colors.good)
                .font(Theme.Typography.secondary)
        case .loading:
            HStack(alignment: .top) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Preparing \(recordingManager.transcriptionEngine.loadingModelName ?? "model")…")
                    Text("The first load can take a few minutes.")
                        .font(Theme.Typography.caption)
                }
                .font(Theme.Typography.secondary)
                .foregroundStyle(Theme.Colors.ink2)
            }
        case .downloading(let progress):
            ModelDownloadProgressView(progress: progress,
                                      modelName: recordingManager.transcriptionEngine.loadingModelName)
        case .error(let msg):
            Label(msg, systemImage: "xmark.circle")
                .foregroundStyle(Theme.Colors.stop)
                .font(Theme.Typography.secondary)
        default:
            EmptyView()
        }
    }

    // MARK: - Copilot

    private var copilotPage: some View {
        let liveKind = CopilotProviderKind(rawValue: copilotProvider) ?? .claude
        return SettingsPage {
            SettingsCard(title: "Live Call Copilot") {
                SettingsToggleRow(
                    title: "Enable Copilot during recordings",
                    detail: "Suggests answers, flags blockers, and captures action items live. No button needed.",
                    first: true,
                    isOn: $copilotEnabled
                )
                SettingsLabeledRow(title: "Call profiles", detail: "What it says and watches for is set per call profile.") {
                    Button("Open Profiles") { section = .profiles }
                }
            }

            // What each call costs, in the user's hands: how often the model is
            // asked, and how much conversation each request carries. Both apply
            // live, mid-call. Fast + Standard = the original behavior.
            SettingsCard(title: "Pace") {
                SettingsBlockRow(
                    title: "How often Copilot asks the model",
                    detail: (CopilotPace(rawValue: copilotPace) ?? .fast).caption,
                    first: true
                ) {
                    Picker("", selection: $copilotPace) {
                        ForEach(CopilotPace.allCases) { pace in
                            Text(pace.label).tag(pace.rawValue)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                }
                SettingsLabeledRow(
                    title: "Conversation sent per request",
                    detail: "Only recent talk is sent. Insight cards always go along, so Copilot still remembers the whole call. Smaller is cheaper and faster, especially on free or local models."
                ) {
                    Picker("", selection: $copilotWindow) {
                        ForEach(CopilotWindow.allCases) { window in
                            Text(window.label).tag(window.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
            }

            SettingsCard(title: "Model") {
                // Two jobs, two backends: live cards need speed and sharpness;
                // reports run after the call where a slow local model costs nothing.
                SettingsBlockRow(title: "Live cards", first: true) {
                    Picker("", selection: $copilotProvider) {
                        ForEach(CopilotProviderKind.allCases) { kind in
                            Text(kind.label).tag(kind.rawValue)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                }

                providerConfig(for: liveKind)

                SettingsLabeledRow(
                    title: "Post-call reports",
                    detail: "Reports generate after the call, so a local model keeps them free and private without slowing live cards. If the reports backend isn't set up, reports fall back to the live one."
                ) {
                    Picker("", selection: $reportsProvider) {
                        Text("Same as live cards").tag("")
                        ForEach(CopilotProviderKind.allCases) { kind in
                            Text(kind.label).tag(kind.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }

                if let reportsKind = CopilotProviderKind(rawValue: reportsProvider), reportsKind != liveKind {
                    providerConfig(for: reportsKind)
                }

                SettingsLabeledRow(
                    title: "Ask Parrot",
                    detail: "Answers questions about your past calls. Pick Ollama to keep them free and on this Mac. If this one isn't set up, Ask uses the reports AI."
                ) {
                    Picker("", selection: $askProvider) {
                        Text("Same as reports").tag("")
                        ForEach(CopilotProviderKind.allCases) { kind in
                            Text(kind.label).tag(kind.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }

                if let askKind = CopilotProviderKind(rawValue: askProvider), askKind != liveKind,
                   askKind.rawValue != reportsProvider {
                    providerConfig(for: askKind)
                }
            }
        }
    }

    /// Per-backend configuration rows, shared by the live and reports pickers.
    @ViewBuilder
    private func providerConfig(for kind: CopilotProviderKind) -> some View {
        switch kind {
        case .claude:
            SettingsLabeledRow(title: "Claude", detail: "Best quality. Needs a key. Transcript text is sent, audio never.") {
                Button("Open API Keys") { section = .apiKeys }
            }
            SettingsRow {
                Hint("Optional: add a TypeSafe key to show matching excerpts from your documents within a second of a question.")
            }
        case .ollama:
            SettingsLabeledRow(
                title: "Ollama model",
                detail: "Runs entirely on this Mac: free, private, no key, works offline. Live cards arrive slower and read rougher than Claude's; reports are unaffected."
            ) {
                Picker("", selection: ollamaModelSelection) {
                    ForEach(OllamaCatalog.models, id: \.id) { entry in
                        Text(entry.label).tag(entry.id)
                    }
                    Divider()
                    Text("Custom…").tag("custom")
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            if showsOllamaCustomField {
                SettingsLabeledRow(
                    title: "Model name",
                    detail: "Any model from ollama.com/library. Prefer small instruct models; \"thinking\" models (qwen3, deepseek-r1) are too slow for live cards."
                ) {
                    TextField("", text: $copilotOllamaModel, prompt: Text("model:tag"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                }
            }
            SettingsRow {
                OllamaModelStatusView(model: copilotOllamaModel)
            }
        case .custom:
            SettingsLabeledRow(title: "Server URL") {
                TextField("", text: $copilotCustomBaseURL, prompt: Text("https://api.openai.com/v1"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 280)
            }
            SettingsLabeledRow(title: "Model") {
                TextField("", text: $copilotCustomModel, prompt: Text("gpt-5-mini"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
            }
            SettingsRow {
                ProviderKeyField(
                    label: "API key",
                    account: "custom-llm-api-key",
                    placeholder: "optional — not needed for local servers",
                    hint: "Any OpenAI-compatible server: OpenAI, Gemini, Groq, OpenRouter, LM Studio… Costs aren't estimated for custom servers."
                )
            }
        }
    }

    /// Dropdown selection for the Ollama model: catalog id, or "custom" when the
    /// stored model isn't in the catalog (or the user picked Custom…).
    private var ollamaModelSelection: Binding<String> {
        Binding(
            get: {
                if ollamaCustomModelEditing { return "custom" }
                return OllamaCatalog.ids.contains(copilotOllamaModel) ? copilotOllamaModel : "custom"
            },
            set: { picked in
                if picked == "custom" {
                    ollamaCustomModelEditing = true
                } else {
                    ollamaCustomModelEditing = false
                    copilotOllamaModel = picked
                }
            }
        )
    }

    private var showsOllamaCustomField: Bool {
        ollamaCustomModelEditing || !OllamaCatalog.ids.contains(copilotOllamaModel)
    }

    // MARK: - API Keys

    private var apiKeysPage: some View {
        SettingsPage {
            SettingsCard(title: "Claude", blurb: "Powers the copilot. Only transcript text is sent; audio never leaves your Mac.") {
                SettingsRow(first: true) {
                    ProviderKeyField(
                        label: "Claude API key",
                        account: nil,
                        placeholder: "sk-ant-…",
                        hint: "Keys: console.anthropic.com"
                    )
                }
            }

            SettingsCard(title: "Groq", blurb: "Cloud transcription and the post-call polish pass.") {
                SettingsRow(first: true) {
                    ProviderKeyField(
                        label: "Groq API key",
                        account: TranscriptionBackend.groq.keychainAccount!,
                        placeholder: "gsk_…",
                        hint: "Used when the Groq engine or polish is on. Keys: console.groq.com"
                    )
                }
            }

            SettingsCard(title: "Deepgram", blurb: "Streaming transcription, billed per audio track. New accounts include $200 credit.") {
                SettingsRow(first: true) {
                    ProviderKeyField(
                        label: "Deepgram API key",
                        account: TranscriptionBackend.deepgram.keychainAccount!,
                        placeholder: "40-character hex key",
                        hint: "Keys: console.deepgram.com"
                    )
                }
            }

            SettingsCard(title: "TypeSafe", blurb: "Instant answers from your documents while Claude is still writing.") {
                SettingsRow(first: true) {
                    ProviderKeyField(
                        label: "TypeSafe API key",
                        account: JevDocMatcher.keychainAccount,
                        placeholder: "apikey_…",
                        hint: "When the other side asks something your documents cover, the matching excerpt shows within about a second. Sends the question, a couple of lines of context and the matching document snippets to TypeSafe AI (hosted in the US). Audio never. Claude mode only. Keys: typesafe.ai"
                    )
                }
            }

            Hint("All keys are stored in your macOS keychain, never in the app's files.")
        }
    }

    // MARK: - Knowledge

    private var knowledgePage: some View {
        let kb = recordingManager.knowledgeBase
        return SettingsPage {
            SettingsCard(
                title: "Documents",
                blurb: "The copilot grounds its answers in these and cites the source. Indexed on this Mac, never uploaded."
            ) {
                if kb.documents.isEmpty {
                    SettingsRow(first: true) {
                        Text("No documents yet. Add a pricing sheet or an FAQ and the copilot can quote it.")
                            .font(Theme.Typography.secondary)
                            .foregroundStyle(Theme.Colors.ink3)
                    }
                }
                ForEach(Array(kb.documents.enumerated()), id: \.element.id) { index, document in
                    SettingsRow(first: index == 0) {
                        KBDocumentRow(document: document, knowledgeBase: kb, profiles: allProfiles)
                    }
                }
                SettingsRow {
                    HStack(spacing: 10) {
                        Button("Add Documents…") {
                            showFileImporter = true
                        }
                        if kb.isIndexing {
                            ProgressView()
                                .controlSize(.small)
                            Text("Embedding on this Mac…")
                                .font(Theme.Typography.secondary)
                                .foregroundStyle(Theme.Colors.ink2)
                        }
                        if let error = kb.lastError {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(Theme.Typography.secondary)
                                .foregroundStyle(Theme.Colors.warn)
                        }
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.pdf, .plainText, .text],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                Task {
                    await recordingManager.knowledgeBase.addDocuments(at: urls)
                }
            }
        }
    }
}

enum Appearance: String, CaseIterable {
    case system, light, dark
}

// MARK: - Settings nav row

/// The guide button. macOS's stock HelpLink is a hairline grey circle nobody
/// sees, so this is a filled accent disc with a white glyph that lifts on
/// hover — the one control in the sidebar that should catch a lost eye.
private struct HelpCircleButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "questionmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Theme.Colors.accent.opacity(hovering ? 1 : 0.9), in: Circle())
                .shadow(color: Theme.Colors.accent.opacity(hovering ? 0.45 : 0.25),
                        radius: hovering ? 5 : 3, y: 1)
                .scaleEffect(hovering ? 1.06 : 1)
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
        .help("Parrot Help")
        .accessibilityLabel("Parrot Help")
    }
}

private struct SettingsNavRow: View {
    let title: String
    let icon: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .frame(width: 18)
                    .foregroundStyle(selected ? Theme.Colors.accent : Theme.Colors.ink2)
                Text(title)
                    .font(Theme.Typography.sans(13, .medium))
                    .foregroundStyle(Theme.Colors.ink)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(selected ? Theme.Colors.selection : Color.clear,
                        in: RoundedRectangle(cornerRadius: Theme.Metrics.radius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - One-line hint

/// The ONE way explanatory text appears on a settings page: a single readable
/// line at secondary size. Anything longer belongs in the control's own label.
struct Hint: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Theme.Typography.secondary)
            .foregroundStyle(Theme.Colors.ink2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Knowledge Base Document Row

struct KBDocumentRow: View {
    let document: KBDocument
    let knowledgeBase: KnowledgeBaseService
    /// Every call profile, so the row can show and toggle which ones use this document.
    let profiles: [CallProfile]

    @State private var note: String
    /// Removal asks first: a document is work the user prepared, and the
    /// trash icon sits next to a text field they click into all the time.
    @State private var confirmingRemove = false

    init(document: KBDocument, knowledgeBase: KnowledgeBaseService, profiles: [CallProfile]) {
        self.document = document
        self.knowledgeBase = knowledgeBase
        self.profiles = profiles
        _note = State(initialValue: document.note)
    }

    private var isPDF: Bool { document.name.lowercased().hasSuffix(".pdf") }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: isPDF ? "doc.richtext" : "doc.text")
                    .foregroundStyle(Theme.Colors.accent)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 2) {
                    Text(document.name)
                        .font(Theme.Typography.sans(13, .medium))
                        .lineLimit(1)
                    TextField(
                        "When should the copilot use this? e.g. \"use for pricing questions\"",
                        text: $note
                    )
                    .textFieldStyle(.plain)
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Colors.ink2)
                    .onSubmit {
                        knowledgeBase.updateNote(note, for: document)
                    }
                }

                Spacer(minLength: 8)

                Text("\(document.chunkCount) chunks · on-device")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.ink3)
                    .monospacedDigit()
                    .lineLimit(1)

                Button {
                    confirmingRemove = true
                } label: {
                    Image(systemName: "trash")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.ink3)
                }
                .buttonStyle(.plain)
                .help("Remove from knowledge base")
                .confirmationDialog("Remove \(document.name)?", isPresented: $confirmingRemove) {
                    Button("Remove", role: .destructive) { knowledgeBase.removeDocument(document) }
                } message: {
                    Text("The copilot stops using it right away. You can add the file again any time.")
                }
            }

            // Which profiles may quote it. Same data Profiles → documents edits.
            FlowLayout(spacing: 6) {
                Text("Use for")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.ink3)
                    .padding(.vertical, 4)
                ForEach(profiles) { profile in
                    Button {
                        toggle(profile)
                    } label: {
                        TagChip(label: profile.name, on: document.profileIDs.contains(profile.id))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.leading, 24)
        }
    }

    private func toggle(_ profile: CallProfile) {
        var ids = document.profileIDs
        if ids.contains(profile.id) { ids.remove(profile.id) } else { ids.insert(profile.id) }
        knowledgeBase.setProfiles(ids, for: document)
    }
}

// MARK: - Provider API key field

/// Reusable BYO-key field: Keychain-backed, explicit Save, and a visible error
/// when the write fails. `account: nil` targets the default (Claude) slot.
struct ProviderKeyField: View {
    let label: String
    let account: String?
    let placeholder: String
    let hint: String

    @State private var key: String
    @State private var saved = false
    @State private var failed = false

    init(label: String, account: String?, placeholder: String, hint: String) {
        self.label = label
        self.account = account
        self.placeholder = placeholder
        self.hint = hint
        let stored = account.map { APIKeyStore.load(account: $0) } ?? APIKeyStore.load()
        _key = State(initialValue: stored ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SecureField(placeholder, text: $key, prompt: Text(placeholder))
                .textFieldStyle(.roundedBorder)
                .onChange(of: key) {
                    saved = false
                    failed = false
                }

            HStack {
                Button("Save Key") {
                    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
                    let ok = account.map { APIKeyStore.save(trimmed, account: $0) }
                        ?? APIKeyStore.save(trimmed)
                    failed = !ok
                    saved = ok
                }
                .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if saved {
                    Label("Saved", systemImage: "checkmark.circle")
                        .foregroundStyle(Theme.Colors.good)
                        .font(Theme.Typography.secondary)
                } else if failed {
                    Label("Keychain rejected the key — try again", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Theme.Colors.warn)
                        .font(Theme.Typography.secondary)
                }
            }

            Hint(hint)
        }
    }
}
