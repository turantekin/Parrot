import SwiftUI
import UniformTypeIdentifiers

/// Settings pages, System Settings-style: topics on the left, ONE topic per
/// page on the right. Content rules: controls at body size, hints one line at
/// secondary size — long explanations live in the control's own label instead.
enum SettingsSection: String, CaseIterable, Identifiable {
    case general, recording, transcription, copilot, apiKeys, knowledge, profiles

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
        }
    }
}

struct SettingsView: View {
    /// True when rendered inside the main window's detail pane (wide, fills the
    /// space); false for the standalone Cmd-, Settings window, which needs a
    /// fixed sane size.
    var isEmbedded = false

    @Environment(RecordingManager.self) private var recordingManager
    @AppStorage("whisperModel") private var selectedModel = "base"
    @AppStorage("appearance") private var appearance = Appearance.system
    @AppStorage("copilotEnabled") private var copilotEnabled = false
    @AppStorage("copilotProvider") private var copilotProvider = CopilotProviderKind.claude.rawValue
    @AppStorage("copilotOllamaModel") private var copilotOllamaModel = "llama3.2:3b"
    @AppStorage("copilotCustomBaseURL") private var copilotCustomBaseURL = ""
    @AppStorage("copilotCustomModel") private var copilotCustomModel = ""
    @AppStorage("transcriptionLanguage") private var transcriptionLanguage = "auto"
    @AppStorage("customVocabulary") private var customVocabulary = ""
    @AppStorage("echoCancellationEnabled") private var echoCancellation = true
    @AppStorage(TranscriptionBackend.defaultsKey) private var transcriptionBackend = TranscriptionBackend.local.rawValue
    @AppStorage("polishAfterCall") private var polishAfterCall = false
    @State private var section: SettingsSection = .general
    @State private var showFileImporter = false
    /// There's no Save button — @AppStorage persists on every change. This
    /// drives a small transient "Saved" chip so that's visible, debounced so
    /// typing in a field shows one toast when the user pauses, not per key.
    @State private var showSavedToast = false
    @State private var savedToastTask: Task<Void, Never>?

    /// One Equatable snapshot of every auto-saved setting on this screen —
    /// a single onChange instead of one per field.
    private var settingsFingerprint: String {
        "\(selectedModel)|\(appearance)|\(copilotEnabled)|\(transcriptionLanguage)|"
            + "\(customVocabulary)|\(echoCancellation)|\(transcriptionBackend)|\(polishAfterCall)"
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
                    SettingsNavRow(section: item, selected: section == item) {
                        section = item
                    }
                }
                Spacer()
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
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .formStyle(.grouped)
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

    // MARK: - Transcription

    private var transcriptionPage: some View {
        Form {
            Section("Engine") {
                Picker("Engine", selection: $transcriptionBackend) {
                    Text("On-device Whisper — private, free").tag(TranscriptionBackend.local.rawValue)
                    Text("Groq cloud — big-model accuracy, ~$0.04/hr").tag(TranscriptionBackend.groq.rawValue)
                    Text("Deepgram cloud — word-by-word streaming, ~$1/hr").tag(TranscriptionBackend.deepgram.rawValue)
                }
                .pickerStyle(.radioGroup)

                if transcriptionBackend == TranscriptionBackend.local.rawValue {
                    Hint("Every second of audio stays on this Mac.")
                } else {
                    HStack(spacing: 6) {
                        Hint("Cloud engines need a key, and fall back to on-device if it's missing.")
                        Button("Open API Keys") { section = .apiKeys }
                            .buttonStyle(.link)
                            .font(Theme.Typography.secondary)
                    }
                }

                Divider()

                Toggle("Polish transcript after each call", isOn: $polishAfterCall)
                Hint("Re-transcribes the saved audio with a large Groq model (~$0.04/hr) and regenerates the report.")
            }

            Section("On-Device Model") {
                Picker("Model", selection: $selectedModel) {
                    Text("Tiny — 40 MB, fastest").tag("tiny")
                    Text("Base — 140 MB, good balance").tag("base")
                    Text("Small — 460 MB, better accuracy").tag("small")
                    Text("Large V3 Turbo — 1.5 GB, best accuracy").tag("large-v3-turbo")
                }
                .pickerStyle(.radioGroup)

                modelStatusView

                Button("Download / Reload Model") {
                    Task {
                        await recordingManager.transcriptionEngine.loadModel(selectedModel)
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
    }

    @ViewBuilder
    private var modelStatusView: some View {
        switch recordingManager.transcriptionEngine.modelState {
        case .ready:
            Label("Model loaded and ready", systemImage: "checkmark.circle")
                .foregroundStyle(Theme.Colors.good)
                .font(Theme.Typography.secondary)
        case .loading:
            HStack {
                ProgressView().controlSize(.small)
                Text("Loading model...")
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Colors.ink2)
            }
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

            Section("Model") {
                Picker("Provider", selection: $copilotProvider) {
                    ForEach(CopilotProviderKind.allCases) { kind in
                        Text(kind.label).tag(kind.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)

                switch CopilotProviderKind(rawValue: copilotProvider) ?? .claude {
                case .claude:
                    HStack(spacing: 6) {
                        Hint("Best quality. Needs a key — transcript text is sent, audio never.")
                        Button("Open API Keys") { section = .apiKeys }
                            .buttonStyle(.link)
                            .font(Theme.Typography.secondary)
                    }
                case .ollama:
                    LabeledContent("Model") {
                        TextField("llama3.2:3b", text: $copilotOllamaModel)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 220)
                    }
                    Hint("Runs entirely on this Mac — free, private, no key, works offline. Needs Ollama (ollama.com), then: ollama pull \(copilotOllamaModel.nilIfEmpty ?? "llama3.2:3b"). Expect live cards to arrive slower and read rougher than Claude's — reports are unaffected.")
                case .custom:
                    LabeledContent("Server URL") {
                        TextField("https://api.openai.com/v1", text: $copilotCustomBaseURL)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 280)
                    }
                    LabeledContent("Model") {
                        TextField("gpt-5-mini", text: $copilotCustomModel)
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
        }
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

private struct SettingsNavRow: View {
    let section: SettingsSection
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: section.icon)
                    .font(.system(size: 13))
                    .frame(width: 18)
                    .foregroundStyle(selected ? Theme.Colors.accent : Theme.Colors.ink2)
                Text(section.title)
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
