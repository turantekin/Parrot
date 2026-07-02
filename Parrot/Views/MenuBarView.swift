import SwiftUI

struct MenuBarView: View {
    @Environment(RecordingManager.self) private var recordingManager
    @Environment(ProfileStore.self) private var profileStore
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        VStack(spacing: 12) {
            if recordingManager.isRecording {
                // Recording state
                HStack(spacing: 8) {
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)
                    Text("Recording")
                        .font(.headline)
                    Spacer()
                    Text(recordingManager.formattedElapsedTime)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                Button(recordingManager.isStopping ? "Finalizing…" : "Stop Recording") {
                    Task { await recordingManager.stopRecording() }
                }
                .disabled(recordingManager.isStopping)
                .keyboardShortcut("s")
            } else {
                // Idle state
                Text("Parrot")
                    .font(.headline)

                Text(recordingManager.transcriptionEngine.isReady ? "Ready to record" : "Loading model...")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(profileStore.activeProfile?.name ?? "Default")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Start Recording") {
                    Task {
                        try? await recordingManager.startRecording(modelContext: modelContext)
                    }
                }
                .disabled(!recordingManager.transcriptionEngine.isReady)
                .keyboardShortcut("r")
            }

            Divider()

            Button("Open Parrot") {
                NSApp.activate(ignoringOtherApps: true)
                if let window = NSApp.windows.first(where: { $0.title != "Item-0" }) {
                    window.makeKeyAndOrderFront(nil)
                }
            }

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding()
        .frame(width: 240)
    }
}
