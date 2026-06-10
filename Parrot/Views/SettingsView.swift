import SwiftUI

struct SettingsView: View {
    @Environment(RecordingManager.self) private var recordingManager
    @AppStorage("whisperModel") private var selectedModel = "base"
    @AppStorage("appearance") private var appearance = Appearance.system
    @AppStorage("copilotEnabled") private var copilotEnabled = false
    @State private var apiKey = APIKeyStore.load() ?? ""
    @State private var keySaved = false

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

            appearanceTab
                .tabItem {
                    Label("Appearance", systemImage: "paintbrush")
                }
        }
        .frame(width: 480, height: 360)
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
