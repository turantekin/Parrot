import SwiftUI

struct TranslateSetupView: View {
    @Environment(RecordingManager.self) private var recordingManager
    @Environment(\.modelContext) private var modelContext
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: Theme.Metrics.sectionGap) {
            VStack(spacing: 8) {
                Image(systemName: "globe")
                    .font(.system(size: 36))
                    .foregroundStyle(Theme.Colors.accent)
                Text("Translation recording")
                    .font(Theme.Typography.title())
                Text("Pick the language you want to read. Spoken language is detected; every line after a switch is translated into the language you choose.")
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Colors.ink2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            Picker("Translate into", selection: Binding(
                get: { recordingManager.translationStore.targetCode },
                set: { recordingManager.setTranslationTarget($0) }
            )) {
                ForEach(TranslationLanguage.allCases) { language in
                    Text(language.label).tag(language.rawValue)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 280)

            Button {
                Task { await start() }
            } label: {
                Label("Start translation recording", systemImage: "record.circle")
                    .font(Theme.Typography.cardTitle)
            }
            .disabled(!recordingManager.transcriptionEngine.isReady)
            .buttonStyle(.borderedProminent)

            if !recordingManager.transcriptionEngine.isReady {
                Text("Waiting for the Whisper model…")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.ink2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Metrics.pad)
        .background(Theme.Colors.canvas)
        .modifier(AppleTranslationPrep(
            targetCode: recordingManager.translationStore.targetCode,
            enabled: AppleTranslationGate.shouldPrepPack))
        .alert("Couldn't start", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            if let errorMessage { Text(errorMessage) }
        }
    }

    private func start() async {
        recordingManager.beginTranslationSession()
        do {
            try await recordingManager.preflightPermissionsAndStart(modelContext: modelContext)
            if !recordingManager.isRecording {
                recordingManager.cancelTranslationSession()
            }
        } catch {
            recordingManager.cancelTranslationSession()
            errorMessage = error.localizedDescription
        }
    }
}
