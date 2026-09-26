import SwiftUI

/// Gets Copilot running for the chosen path. The Copilot card on top holds
/// the switch; the rows below differ per path.
struct CopilotSetupStep: View {
    @Environment(OnboardingModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 14) {
            StepHeader(title: "Set up Copilot")
            CopilotHeroCard(title: "Copilot", subtitle: heroLine) {
                Toggle("Copilot", isOn: $model.copilotOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            switch model.path {
            case .private?:
                OllamaSetupRows()
            case .balanced?:
                KeyCheckField(service: .claude, label: "Claude API key", placeholder: "sk-ant-…",
                              hint: "Get a key at console.anthropic.com. Saved in your macOS keychain.",
                              result: $model.claudeCheck)
                Text("Claude also writes your after-call reports.")
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Colors.ink2)
            case .cloud?:
                KeyCheckField(service: .claude, label: "Claude API key", placeholder: "sk-ant-…",
                              hint: "Get a key at console.anthropic.com.", result: $model.claudeCheck)
                KeyCheckField(service: .deepgram, label: "Deepgram API key", placeholder: "40-character key",
                              hint: "New accounts get $200 free credit. console.deepgram.com",
                              optional: true, result: $model.deepgramCheck)
                if model.mode == .full { SpeechDownloadRow(backup: true) }
            case .later?, nil:
                EmptyView()  // routing never shows this step without a path
            }
        }
        .frame(maxWidth: 480)
        .padding(Theme.Metrics.pad)
    }

    private var heroLine: String {
        switch model.path {
        case .private?: "Runs on this Mac with Ollama. Private and free."
        case .balanced?: "Uses Claude. Only text is sent, audio never leaves this Mac."
        case .cloud?: "Claude gives answers. Deepgram writes the words live."
        case .later?, nil: ""
        }
    }
}

/// Install Ollama → open it → download the model. Each row turns green on
/// its own: the step polls the server every 1.5 s, like the permission rows.
private struct OllamaSetupRows: View {
    @Environment(OnboardingModel.self) private var model
    @Environment(RecordingManager.self) private var recordingManager

    var body: some View {
        @Bindable var model = model
        let ollama = recordingManager.ollama
        let installer = recordingManager.ollamaInstaller
        let serverUp = ollama.isServerUp
        let appURL = OllamaInstaller.installedAppURL()
        let installed = serverUp || appURL != nil
        VStack(spacing: 8) {
            installRow(installer, installed: installed)
            if serverUp {
                done("Ollama is running")
            } else if installed {
                PermissionRow(icon: "play.fill", askTitle: "Open Ollama", grantedTitle: "",
                              subtitle: "Installed. Open it once so Parrot can find it.") {
                    Task { await installer.openInstalled() }
                }
            } else {
                PendingRow(title: "Open Ollama")
            }
            modelRow(ollama, serverUp: serverUp)
            if let appURL, appURL.path.contains("/Downloads/") {
                HStack {
                    Text("Move Ollama to Applications so it stays put.")
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([appURL]) }
                        .buttonStyle(.link)
                }
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.ink2)
            }
            if case .failed(let why) = installer.state {
                Text(why)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.stop)
                Link("Get it from ollama.com", destination: OllamaInstaller.websiteURL)
                    .font(Theme.Typography.caption)
            } else if !installed {
                Link("Or download it from ollama.com", destination: OllamaInstaller.websiteURL)
                    .font(Theme.Typography.caption)
            }
            if !ollama.isPulling, ollama.status(for: model.ollamaModel) != .ready {
                Picker("Model", selection: $model.ollamaModel) {
                    ForEach(OllamaCatalog.models, id: \.id) { Text($0.label).tag($0.id) }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 360)
            }
        }
        .task(id: model.ollamaModel) {
            while !Task.isCancelled {
                await ollama.refresh(model: model.ollamaModel)
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
        // Live, not per poll: Continue right after the download lands must
        // already count the model as ready.
        .onChange(of: ollama.status(for: model.ollamaModel), initial: true) { _, status in
            model.ollamaModelReady = status == .ready
        }
    }

    @ViewBuilder
    private func installRow(_ installer: OllamaInstaller, installed: Bool) -> some View {
        if installed {
            done("Ollama installed")
        } else {
            switch installer.state {
            case .downloading(let progress):
                DownloadRow(title: "Downloading Ollama", progress: progress, note: "About 200 MB.")
            case .unpacking, .verifying:
                DownloadRow(title: "Checking the download", progress: nil,
                            note: "Making sure it really comes from Ollama.")
            case .opening, .opened:
                DownloadRow(title: "Opening Ollama", progress: nil, note: "If macOS asks, click Open.")
            case .idle, .failed:
                PermissionRow(icon: "arrow.down.circle", askTitle: "Install Ollama", grantedTitle: "",
                              subtitle: "Free, 200 MB. macOS will ask you to confirm once.") {
                    Task { await installer.install() }
                }
            }
        }
    }

    @ViewBuilder
    private func modelRow(_ ollama: OllamaService, serverUp: Bool) -> some View {
        let name = model.ollamaModel
        let size = OllamaCatalog.sizeLabel(for: name) ?? "size varies"
        let status = ollama.status(for: name)
        if case .pulling(let progress) = status {
            DownloadRow(title: "Downloading \(name)", progress: progress,
                        note: "Keep going. Copilot turns on by itself when it's done.")
        } else if status == .ready {
            done("\(name) is ready")
        } else if serverUp, !ollama.isPulling {
            PermissionRow(icon: "arrow.down.circle", askTitle: "Download \(name)", grantedTitle: "",
                          subtitle: "\(size). Runs Copilot on this Mac.") {
                ollama.pull(name)
            }
        } else {
            PendingRow(title: "Download \(name)")
        }
        if case .failed(let why) = status {
            Text(why)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.stop)
        }
    }

    private func done(_ title: String) -> some View {
        PermissionRow(icon: "checkmark", askTitle: "", grantedTitle: title, subtitle: "", isGranted: true, action: {})
    }
}
