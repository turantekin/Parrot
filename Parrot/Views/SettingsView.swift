import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(RecordingManager.self) private var recordingManager
    @AppStorage("whisperModel") private var selectedModel = "base"
    @AppStorage("appearance") private var appearance = Appearance.system
    @AppStorage("copilotEnabled") private var copilotEnabled = false
    @AppStorage("copilotInstructions") private var copilotInstructions = ""
    @AppStorage("copilotGeneralFallback") private var copilotGeneralFallback = true
    @State private var apiKey = APIKeyStore.load() ?? ""
    @State private var keySaved = false
    @State private var showFileImporter = false

    var body: some View {
        TabView {
            generalTab
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            audioTab
                .tabItem {
                    Label("Audio", systemImage: "waveform")
                }

            copilotTab
                .tabItem {
                    Label("Copilot", systemImage: "sparkles")
                }

            knowledgeTab
                .tabItem {
                    Label("Knowledge", systemImage: "books.vertical")
                }

            appearanceTab
                .tabItem {
                    Label("Appearance", systemImage: "paintbrush")
                }
        }
        .frame(width: 520, height: 440)
    }

    // MARK: - General Tab

    private var generalTab: some View {
        Form {
            Section("WhisperKit Model") {
                Picker("Model", selection: $selectedModel) {
                    Text("Tiny (~40MB) — Fastest, lower accuracy").tag("tiny")
                    Text("Base (~140MB) — Good balance").tag("base")
                    Text("Small (~460MB) — Better accuracy").tag("small")
                    Text("Large V3 Turbo (~1.5GB) — Best accuracy").tag("large-v3-turbo")
                }
                .pickerStyle(.radioGroup)

                modelStatusView

                Button("Download / Reload Model") {
                    Task {
                        await recordingManager.transcriptionEngine.loadModel(selectedModel)
                    }
                }
            }
        }
        .padding()
    }

    @ViewBuilder
    private var modelStatusView: some View {
        switch recordingManager.transcriptionEngine.modelState {
        case .ready:
            Label("Model loaded and ready", systemImage: "checkmark.circle")
                .foregroundStyle(.green)
                .font(.caption)
        case .loading:
            HStack {
                ProgressView().controlSize(.small)
                Text("Loading model...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .error(let msg):
            Label(msg, systemImage: "xmark.circle")
                .foregroundStyle(.red)
                .font(.caption)
        default:
            EmptyView()
        }
    }

    // MARK: - Audio Tab

    private var audioTab: some View {
        Form {
            Section("Input") {
                Text("System audio is always captured via ScreenCaptureKit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Microphone uses your default input device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Storage") {
                let path = AudioCaptureManager.storageDirectory().path
                LabeledContent("Audio files") {
                    Text(path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Button("Show in Finder") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
                }
            }
        }
        .padding()
    }

    // MARK: - Copilot Tab

    private var copilotTab: some View {
        Form {
            Section("Live Call Copilot") {
                Toggle("Enable Copilot during recordings", isOn: $copilotEnabled)

                Text("Watches the live transcript for the whole call and suggests answers, flags blockers, and captures action items in real time — no button needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Claude API Key") {
                SecureField("sk-ant-...", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: apiKey) {
                        keySaved = false
                    }

                HStack {
                    Button("Save Key") {
                        APIKeyStore.save(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
                        keySaved = true
                    }
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if keySaved {
                        Label("Saved", systemImage: "checkmark.circle")
                            .foregroundStyle(.green)
                            .font(.caption)
                    }
                }

                Text("Stored in your keychain. Copilot sends transcript text to Anthropic's API — your audio never leaves your Mac. Get a key at console.anthropic.com.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    // MARK: - Knowledge Tab

    private var knowledgeTab: some View {
        Form {
            Section("Documents") {
                Text("Drop in pricing sheets, FAQs, playbooks — the copilot grounds its suggested answers in them and cites the source. Everything is indexed on this Mac; documents are never uploaded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if recordingManager.knowledgeBase.documents.isEmpty {
                    Text("No documents yet")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
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
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let error = recordingManager.knowledgeBase.lastError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                }
            }

            Section("Coaching Instructions") {
                TextEditor(text: $copilotInstructions)
                    .font(.callout)
                    .frame(height: 70)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(.quaternary)
                    )

                Text("Standing guidance for every call — tone, style, behavior. E.g. \"Keep answers casual and short. Always offer Good/Better/Best when price comes up.\"")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Answer from general knowledge when my documents don't cover it", isOn: $copilotGeneralFallback)

                Text("Cards always show where an answer came from: your document's name, or \"general knowledge\".")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
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

    // MARK: - Appearance Tab

    private var appearanceTab: some View {
        Form {
            Section("Theme") {
                Picker("Appearance", selection: $appearance) {
                    Text("Follow System").tag(Appearance.system)
                    Text("Light").tag(Appearance.light)
                    Text("Dark").tag(Appearance.dark)
                }
                .pickerStyle(.radioGroup)
            }
        }
        .padding()
    }
}

enum Appearance: String, CaseIterable {
    case system, light, dark
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
                    .foregroundStyle(.secondary)

                Text(document.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)

                Text("\(document.chunkCount) chunks")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Spacer()

                Button {
                    knowledgeBase.removeDocument(document)
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("Remove from knowledge base")
            }

            TextField(
                "When should the copilot use this? e.g. \"use for pricing questions\"",
                text: $note
            )
            .textFieldStyle(.roundedBorder)
            .font(.caption)
            .onSubmit {
                knowledgeBase.updateNote(note, for: document)
            }
        }
        .padding(.vertical, 2)
    }
}
