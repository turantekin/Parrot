import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Settings pages, System Settings-style: topics on the left, ONE topic per
/// page on the right. Content rules: controls at body size, hints one line at
/// secondary size — long explanations live in the control's own label instead.
enum SettingsSection: String, CaseIterable, Identifiable {
    case general, recording, create, transcription, copilot, apiKeys, knowledge, profiles

    /// Set before opening Settings so the Create page is selected.
    static var pending: SettingsSection?

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .recording: "Recording"
        case .create: "Create"
        case .transcription: "Transcription"
        case .copilot: "Copilot"
        case .apiKeys: "API Keys"
        case .knowledge: "Knowledge"
        case .profiles: "Profiles"
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .recording: "mic"
        case .create: "keyboard"
        case .transcription: "text.quote"
        case .copilot: "sparkles"
        case .apiKeys: "key"
        case .knowledge: "books.vertical"
        case .profiles: "person.2"
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
    @AppStorage("copilotOllamaModel") private var copilotOllamaModel = "llama3.2:3b"
    @AppStorage("copilotCustomBaseURL") private var copilotCustomBaseURL = ""
    @AppStorage("copilotCustomModel") private var copilotCustomModel = ""
    @AppStorage(FeatureProcessing.translationOllamaModelKey) private var translationOllamaModel = FeatureProcessing.translationOllamaDefault
    @AppStorage("transcriptionLanguage") private var transcriptionLanguage = "auto"
    @AppStorage("customVocabulary") private var customVocabulary = ""
    @AppStorage("echoCancellationEnabled") private var echoCancellation = true
    @AppStorage(TranscriptionBackend.defaultsKey) private var transcriptionBackend = TranscriptionBackend.local.rawValue
    @AppStorage("polishAfterCall") private var polishAfterCall = false
    @AppStorage("livePreview") private var livePreview = true
    @AppStorage(FeatureProcessing.callModeKey) private var callMode = ProcessingMode.local.rawValue
    @AppStorage(FeatureProcessing.polishModeKey) private var polishMode = ProcessingMode.local.rawValue
    @AppStorage(FeatureProcessing.translationModeKey) private var translationMode = ProcessingMode.local.rawValue
    @AppStorage(FeatureProcessing.dictationModeKey) private var dictationMode = ProcessingMode.local.rawValue
    @AppStorage(FeatureProcessing.cloudVendorKey) private var cloudVendor = CloudVendor.gemini.rawValue
    @AppStorage(FeatureProcessing.refineIntervalKey) private var refineInterval = 120.0
    @AppStorage(FeatureProcessing.showBarKey) private var showProcessingBar = true
    @AppStorage(FeatureProcessing.autoPasteKey) private var autoPaste = true
    @AppStorage(FeatureProcessing.appleTranslationKey) private var useAppleTranslation = false
    @State private var section: SettingsSection = .general
    @State private var diarizerDownloading = false
    @AppStorage("rememberVoices") private var rememberVoices = false
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SpeakerProfile.name) private var voiceProfiles: [SpeakerProfile]
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

    /// One Equatable snapshot of every auto-saved setting on this screen —
    /// a single onChange instead of one per field.
    private var settingsFingerprint: String {
        "\(selectedModel)|\(appearance)|\(copilotEnabled)|\(transcriptionLanguage)|"
            + "\(customVocabulary)|\(echoCancellation)|\(transcriptionBackend)|\(polishAfterCall)|"
            + "\(copilotPace)|\(copilotWindow)|\(livePreview)|\(callMode)|\(polishMode)|"
            + "\(translationMode)|\(dictationMode)|"
            + "\(cloudVendor)|\(refineInterval)|\(useAppleTranslation)|\(translationOllamaModel)|"
            + "\(showProcessingBar)|\(autoPaste)|"
            + "\(recordingManager.translationStore.targetCode)"
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
                case .create: createPage
                case .transcription: transcriptionPage
                case .copilot: copilotPage
                case .apiKeys: apiKeysPage
                case .knowledge: knowledgePage
                case .profiles: ProfilesSettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .formStyle(.grouped)
        .onChange(of: settingsFingerprint) { flashSavedToast() }
        .onAppear {
            if let pending = SettingsSection.pending {
                section = pending
                SettingsSection.pending = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .parrotShowTranscriptionSettings)) { _ in
            section = .create
        }
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
        .frame(width: isEmbedded ? nil : 780, height: isEmbedded ? nil : 540)
        .frame(maxWidth: isEmbedded ? .infinity : nil,
               maxHeight: isEmbedded ? .infinity : nil)
    }

    // MARK: - General

    private var generalPage: some View {
        Form {
            Section("Appearance") {
                Picker("Appearance", selection: $appearance) {
                    Text("Follow System").tag(Appearance.system)
                    Text("Light").tag(Appearance.light)
                    Text("Dark").tag(Appearance.dark)
                }
                .pickerStyle(.radioGroup)
            }

            Section("Storage") {
                let path = AudioCaptureManager.storageDirectory().path
                LabeledContent("Audio files") {
                    Text(path)
                        .font(Theme.Typography.secondary)
                        .foregroundStyle(Theme.Colors.ink2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Button("Show in Finder") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
                }
            }

            Section("About") {
                LabeledContent("Version", value: "Parrot \(AppUpdater.currentVersion)")
                Toggle("Keep Parrot up to date", isOn: $automaticUpdates)
                    .onChange(of: automaticUpdates) {
                        AppUpdater.shared.automaticallyUpdates = automaticUpdates
                    }
                Hint("Downloads new versions in the background and installs them when you quit. Never during a recording.")
                HStack(spacing: 6) {
                    Hint("Or look right now.")
                    Button("Check Now") { AppUpdater.shared.checkForUpdates() }
                        .buttonStyle(.link)
                        .font(Theme.Typography.secondary)
                }
                HStack(spacing: 6) {
                    Hint("Every screen explained, with setup and troubleshooting.")
                    Button("Open User Guide") {
                        NSApp.showHelp(nil)
                    }
                    .buttonStyle(.link)
                    .font(Theme.Typography.secondary)
                }
                HStack(spacing: 6) {
                    Hint("The first-run tour: permissions and model choice.")
                    Button("Show Welcome Tour") { MeetingActions.showWelcomeTour() }
                        .buttonStyle(.link)
                        .font(Theme.Typography.secondary)
                }
            }
        }
    }

    // MARK: - Recording

    private var recordingPage: some View {
        Form {
            Section("Echo Cancellation") {
                Toggle("Cancel speaker echo from the mic", isOn: $echoCancellation)
                Hint("On speakers, this keeps the other person's voice out of your \"Me\" track. Turn off with headphones.")
            }

            Section("Input") {
                Hint("System audio is captured via ScreenCaptureKit; the microphone uses your default input device.")
            }
        }
    }

    // MARK: - Create & key bindings

    private var createPage: some View {
        Form {
            Section("Floating bar") {
                Toggle("Show floating bar", isOn: $showProcessingBar)
                    .onChange(of: showProcessingBar) { _, show in
                        ProcessingBarController.shared.setVisible(show)
                    }
                Hint("A pill at the bottom of every screen. Click the mic for hands-free dictation.")
            }

            Section("Auto-paste") {
                Toggle("Auto-paste into the focused field", isOn: $autoPaste)
                Hint("When a dictation or transform finishes, insert the text where the cursor is. Off copies only.")
                if !FocusText.isTrusted {
                    Button("Allow Accessibility so Parrot can type into the focused field") {
                        _ = FocusText.ensureTrusted()
                    }
                    .buttonStyle(.link)
                }
            }

            Section("Key Bindings") {
                HotkeyRecorderRow(title: "Press and hold to dictate", slot: .dictationHold)
                Hint("Hold to speak. Release to transcribe and paste into the focused field.")
                HotkeyRecorderRow(title: "Hands-free dictation", slot: .dictation)
                Hint("Press once to start, press again to stop and paste. Same idea as Wispr Flow.")
                HotkeyRecorderRow(title: "Paste last transcript", slot: .pasteLast)
                Hint("Re-inserts the last dictation into the focused field.")
            }

            Section("Transforms") {
                HotkeyRecorderRow(title: "Transform — local", slot: .transformLocal)
                HotkeyRecorderRow(title: "Transform — cloud", slot: .transformCloud)
                Hint("Rewrites the selected text, or the clipboard if nothing is selected. Unbound until you record a shortcut.")
                Picker("Default transform", selection: Binding(
                    get: { recordingManager.transforms.itemID },
                    set: { recordingManager.transforms.itemID = $0 }
                )) {
                    ForEach(TransformCatalog.all()) { item in
                        Text(item.name).tag(item.id)
                    }
                }
            }
        }
    }

    // MARK: - Transcription

    private var transcriptionPage: some View {
        Form {
            Section("Engine") {
                Picker("Engine", selection: $transcriptionBackend) {
                    Text("On-device Whisper — private, free").tag(TranscriptionBackend.local.rawValue)
                    Text("Groq cloud — big-model accuracy, ~$0.04/hr").tag(TranscriptionBackend.groq.rawValue)
                    Text("Deepgram cloud — word-by-word streaming, ~$1/hr").tag(TranscriptionBackend.deepgram.rawValue)
                    Text("Gemini Live — streaming meetings & translation").tag(TranscriptionBackend.gemini.rawValue)
                }
                .pickerStyle(.radioGroup)

                if transcriptionBackend == TranscriptionBackend.local.rawValue {
                    Hint("Every second of audio stays on this Mac.")
                    if callMode == ProcessingMode.cloud.rawValue && cloudVendor == CloudVendor.gemini.rawValue {
                        Hint("Cloud + Gemini still uses Gemini Live for the meeting, not Whisper.")
                    }
                } else {
                    HStack(spacing: 6) {
                        Hint("Cloud engines need a key, and fall back to on-device if it's missing.")
                        Button("Open API Keys") { section = .apiKeys }
                            .buttonStyle(.link)
                            .font(Theme.Typography.secondary)
                    }
                }

            }

            Section("Processing") {
                    modePicker("Call", selection: $callMode, allowCloud: cloudSpeechReady)
                    modePicker("Polish", selection: $polishMode, allowCloud: cloudSpeechReady)
                    modePicker("Dictation", selection: $dictationMode, allowCloud: cloudSpeechReady)
                    Picker("Cloud vendor", selection: $cloudVendor) {
                        Text("Gemini").tag(CloudVendor.gemini.rawValue)
                        Text("Groq").tag(CloudVendor.groq.rawValue)
                        Text("Custom server").tag(CloudVendor.custom.rawValue)
                    }
                    if cloudVendor == CloudVendor.custom.rawValue {
                        Hint("Custom is for text transforms only. Call, Polish, and Dictation Hybrid/Cloud need Gemini or Groq.")
                    }
                    if callMode != ProcessingMode.local.rawValue {
                        Picker("Refine window", selection: $refineInterval) {
                            Text("60 s").tag(60.0)
                            Text("120 s").tag(120.0)
                            Text("180 s").tag(180.0)
                        }
                    }
                if !cloudSpeechReady {
                    Hint("Add a Gemini or Groq key to enable Hybrid and Cloud speech.")
                }
                Button("Open API Keys") { section = .apiKeys }
                    .buttonStyle(.link)
            }

            Section("Translation") {
                Picker("Translate into", selection: Binding(
                    get: { recordingManager.translationStore.targetCode },
                    set: { recordingManager.setTranslationTarget($0) }
                )) {
                    ForEach(TranslationLanguage.allCases) { language in
                        Text(language.label).tag(language.rawValue)
                    }
                }
                modePicker("Translation", selection: $translationMode, allowCloud: translationCloudReady, translation: true)
                Hint("Hybrid and Cloud send the call's audio to Gemini. Local never does.")
                if translationMode != ProcessingMode.cloud.rawValue {
                    Picker("Local model", selection: $translationOllamaModel) {
                        ForEach(LocalTextCatalog.models) { entry in
                            Text(entry.label).tag(entry.id)
                        }
                    }
                    .pickerStyle(.menu)
                    LocalTextModelStatusView(modelID: translationOllamaModel)
                }
                if AppleTranslationGate.isSupported {
                    Toggle("Apple Translation", isOn: $useAppleTranslation)
                    Hint("Optional. Parrot asks once to download that language pack. Meetings never show that dialog.")
                }
                if !translationCloudReady {
                    Hint("Add a Gemini key in API Keys to turn on Hybrid or Cloud translation.")
                    Button("Open API Keys") { section = .apiKeys }
                        .buttonStyle(.link)
                }
            }

            Section {
                Toggle("Show words as they're spoken", isOn: $livePreview)
                Hint("Gray preview text while someone is mid-sentence, replaced by the final line. On-device engine only; turn off if calls make your Mac run hot. Applies to the next recording.")
            }

            Section("On-Device Model") {
                Picker("Model", selection: $selectedModel) {
                    Text("Tiny — 40 MB, fastest").tag("tiny")
                    Text("Base — 140 MB, good balance").tag("base")
                    Text("Small — 460 MB, better accuracy").tag("small")
                    Text("Large V3 Turbo Compressed — 626 MB, fast, low memory").tag("large-v3-v20240930_626MB")
                    Text("Large V3 Turbo — 1.6 GB, best accuracy").tag("large-v3-turbo")
                }
                .pickerStyle(.radioGroup)

                modelStatusView

                Button("Download / Reload Model") {
                    Task {
                        await recordingManager.transcriptionEngine.loadModel(selectedModel)
                    }
                }
            }

            Section("Speaker Detection") {
                if DiarizationEngine.modelsInstalled {
                    LabeledContent("Models", value: "Downloaded (~13 MB)")
                    Button("Remove Models") { DiarizationEngine.removeModels() }
                } else {
                    LabeledContent("Models", value: "Not downloaded")
                    Button(diarizerDownloading ? "Downloading…" : "Download (~13 MB)") {
                        diarizerDownloading = true
                        Task {
                            try? await recordingManager.diarizationEngine.ensureModels()
                            diarizerDownloading = false
                        }
                    }
                    .disabled(diarizerDownloading)
                }
                Text("Tells apart the different people on a call, on this Mac. Downloads automatically after a call if missing. Uses pyannote models via FluidAudio (CC-BY-4.0).")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.ink2)

                Toggle("Remember voices", isOn: $rememberVoices)
                Text("When on, naming a speaker saves their voiceprint on this Mac so future calls can suggest who's talking. Never leaves your Mac; delete anytime.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.ink2)
                if rememberVoices {
                    ForEach(voiceProfiles) { profile in
                        HStack {
                            Text(profile.name)
                            Text("heard \(profile.sampleCount)×")
                                .foregroundStyle(Theme.Colors.ink2)
                            Spacer()
                            Button("Forget") {
                                SpeakerProfileStore.delete(profile, in: modelContext)
                            }
                        }
                        .font(Theme.Typography.caption)
                    }
                    if !voiceProfiles.isEmpty {
                        Button("Forget All Voices") {
                            SpeakerProfileStore.deleteAll(in: modelContext)
                        }
                    }
                }
            }

            Section("Language") {
                Picker("Language", selection: $transcriptionLanguage) {
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
                    Text("Urdu").tag("ur")
                }
                Hint("Applies to the next recording. Pick a language only if auto-detect keeps guessing wrong.")
            }

            Section("Custom Vocabulary") {
                TextEditor(text: $customVocabulary)
                    .frame(height: 64)
                    .font(Theme.Typography.secondary)
                    .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.radius).strokeBorder(Theme.Colors.line))
                Hint("Names and jargon Whisper mis-hears — comma or line separated (e.g. LaunchEase, Uygar).")
            }
        }
        .modifier(AppleTranslationPrep(
            targetCode: recordingManager.translationStore.targetCode,
            enabled: AppleTranslationGate.shouldPrepPack))
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
        Form {
            Section("Live Call Copilot") {
                Toggle("Enable Copilot during recordings", isOn: $copilotEnabled)
                Hint("Suggests answers, flags blockers, and captures action items live — no button needed.")

                HStack(spacing: 6) {
                    Hint("What it says and watches for is set per call profile.")
                    Button("Open Profiles") { section = .profiles }
                        .buttonStyle(.link)
                        .font(Theme.Typography.secondary)
                }
            }

            // What each call costs, in the user's hands: how often the model is
            // asked, and how much conversation each request carries. Both apply
            // live, mid-call. Fast + Standard = the original behavior.
            Section("Pace") {
                Picker("How often Copilot asks the model", selection: $copilotPace) {
                    ForEach(CopilotPace.allCases) { pace in
                        Text(pace.label).tag(pace.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)
                Hint((CopilotPace(rawValue: copilotPace) ?? .fast).caption)

                Picker("Conversation sent per request", selection: $copilotWindow) {
                    ForEach(CopilotWindow.allCases) { window in
                        Text(window.label).tag(window.rawValue)
                    }
                }
                .pickerStyle(.menu)
                Hint("Only recent talk is sent — insight cards always go along, so Copilot still remembers the whole call. Smaller is cheaper and faster, especially on free or local models.")
            }

            Section("Model") {
                // Two jobs, two backends: live cards need speed and sharpness;
                // reports run after the call where a slow local model costs nothing.
                Picker("Live cards", selection: $copilotProvider) {
                    ForEach(CopilotProviderKind.allCases) { kind in
                        Text(kind.label).tag(kind.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)

                providerConfig(for: CopilotProviderKind(rawValue: copilotProvider) ?? .claude)

                Picker("Post-call reports", selection: $reportsProvider) {
                    Text("Same as live cards").tag("")
                    ForEach(CopilotProviderKind.allCases) { kind in
                        Text(kind.label).tag(kind.rawValue)
                    }
                }
                .pickerStyle(.menu)

                if let reportsKind = CopilotProviderKind(rawValue: reportsProvider),
                   reportsKind != (CopilotProviderKind(rawValue: copilotProvider) ?? .claude) {
                    providerConfig(for: reportsKind)
                }
                Hint("Reports generate after the call, so a local model keeps them free and private without slowing live cards. If the reports backend isn't set up, reports fall back to the live one.")
            }
        }
    }

    /// Per-backend configuration rows, shared by the live and reports pickers.
    @ViewBuilder
    private func providerConfig(for kind: CopilotProviderKind) -> some View {
                switch kind {
                case .claude:
                    HStack(spacing: 6) {
                        Hint("Best quality. Needs a key — transcript text is sent, audio never.")
                        Button("Open API Keys") { section = .apiKeys }
                            .buttonStyle(.link)
                            .font(Theme.Typography.secondary)
                    }
                case .ollama:
                    OllamaModelPicker(
                        model: $copilotOllamaModel,
                        hint: "Any model from ollama.com/library — prefer small instruct models; \"thinking\" models (qwen3, deepseek-r1) are too slow for live cards.")
                    Hint("Runs entirely on this Mac — free, private, no key, works offline. Expect live cards to arrive slower and read rougher than Claude's — reports are unaffected.")
                case .custom:
                    LabeledContent("Server URL") {
                        TextField("", text: $copilotCustomBaseURL, prompt: Text("https://api.openai.com/v1"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 280)
                    }
                    LabeledContent("Model") {
                        TextField("", text: $copilotCustomModel, prompt: Text("gpt-5-mini"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 220)
                    }
                    ProviderKeyField(
                        label: "API key",
                        account: "custom-llm-api-key",
                        placeholder: "optional — not needed for local servers",
                        hint: "Any OpenAI-compatible server: OpenAI, Gemini, Groq, OpenRouter, LM Studio… Costs aren't estimated for custom servers."
                    )
                }
    }

    private func modePicker(_ title: String, selection: Binding<String>, allowCloud: Bool, translation: Bool = false) -> some View {
        Picker(title, selection: selection) {
            Text(translation ? "Local — in-app model" : "Local — downloaded model only")
                .tag(ProcessingMode.local.rawValue)
            Text(translation ? "Hybrid — in-app, then Gemini" : "Hybrid — downloaded model, then cloud enhances")
                .tag(ProcessingMode.hybrid.rawValue)
                .disabled(!allowCloud)
            Text(translation ? "Cloud — Gemini only" : "Cloud — vendor only, no local model")
                .tag(ProcessingMode.cloud.rawValue)
                .disabled(!allowCloud)
        }
        .pickerStyle(.radioGroup)
    }

    /// Hybrid/Cloud speech needs Gemini or Groq with a key. Custom is text-only.
    private var cloudSpeechReady: Bool {
        let vendor = CloudVendor.resolved(cloudVendor)
        return vendor != .custom && vendor.speechKey() != nil
    }

    /// Translation Hybrid / Cloud always means Gemini, including the audio pass.
    private var translationCloudReady: Bool {
        CloudVendor.gemini.speechKey() != nil
    }

    // MARK: - API Keys

    private var apiKeysPage: some View {
        Form {
            Section("Claude — powers the copilot") {
                ProviderKeyField(
                    label: "Claude API key",
                    account: nil,
                    placeholder: "sk-ant-…",
                    hint: "Only transcript text is sent — audio never leaves your Mac. Keys: console.anthropic.com"
                )
            }

            Section("Groq — cloud transcription & polish") {
                ProviderKeyField(
                    label: "Groq API key",
                    account: TranscriptionBackend.groq.keychainAccount!,
                    placeholder: "gsk_…",
                    hint: "Used when the Groq engine or polish is on. Keys: console.groq.com"
                )
            }

            Section("Deepgram — streaming transcription") {
                ProviderKeyField(
                    label: "Deepgram API key",
                    account: TranscriptionBackend.deepgram.keychainAccount!,
                    placeholder: "40-character hex key",
                    hint: "Billed per audio track. New accounts include $200 credit. Keys: console.deepgram.com"
                )
            }

            Section("Gemini — live meetings, refine & post-call translation") {
                ProviderKeyField(
                    label: "Gemini API key",
                    account: CloudVendor.gemini.keychainAccount,
                    placeholder: "AIza…",
                    hint: "Powers Gemini Live during a call and Live Translate after Stop. Keys: aistudio.google.com/apikey"
                )
            }

            Section {
                Hint("All keys are stored in your macOS keychain, never in the app's files.")
            }
        }
    }

    // MARK: - Knowledge

    private var knowledgePage: some View {
        Form {
            Section("Documents") {
                Hint("The copilot grounds its answers in these and cites the source. Indexed on this Mac, never uploaded.")

                if recordingManager.knowledgeBase.documents.isEmpty {
                    Text("No documents yet")
                        .font(Theme.Typography.secondary)
                        .foregroundStyle(Theme.Colors.ink3)
                } else {
                    ForEach(recordingManager.knowledgeBase.documents) { document in
                        KBDocumentRow(document: document, knowledgeBase: recordingManager.knowledgeBase)
                    }
                }

                HStack {
                    Button("Add Documents…") {
                        showFileImporter = true
                    }

                    if recordingManager.knowledgeBase.isIndexing {
                        ProgressView()
                            .controlSize(.small)
                        Text("Indexing…")
                            .font(Theme.Typography.secondary)
                            .foregroundStyle(Theme.Colors.ink2)
                    }
                }

                if let error = recordingManager.knowledgeBase.lastError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(Theme.Typography.secondary)
                        .foregroundStyle(Theme.Colors.warn)
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

    @State private var note: String

    init(document: KBDocument, knowledgeBase: KnowledgeBaseService) {
        self.document = document
        self.knowledgeBase = knowledgeBase
        _note = State(initialValue: document.note)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: document.name.lowercased().hasSuffix(".pdf") ? "doc.richtext" : "doc.text")
                    .foregroundStyle(Theme.Colors.ink2)

                Text(document.name)
                    .font(Theme.Typography.sans(13, .medium))
                    .lineLimit(1)

                Text("\(document.chunkCount) chunks")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.ink3)

                Spacer()

                Button {
                    knowledgeBase.removeDocument(document)
                } label: {
                    Image(systemName: "trash")
                        .font(Theme.Typography.caption)
                }
                .buttonStyle(.plain)
                .help("Remove from knowledge base")
            }

            TextField(
                "When should the copilot use this? e.g. \"use for pricing questions\"",
                text: $note
            )
            .textFieldStyle(.roundedBorder)
            .font(Theme.Typography.secondary)
            .onSubmit {
                knowledgeBase.updateNote(note, for: document)
            }
        }
        .padding(.vertical, 2)
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
