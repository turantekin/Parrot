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
                        .fill(Theme.Colors.stop)
                        .frame(width: 8, height: 8)
                    Text("Recording")
                        .font(.appHeadline)
                    Spacer()
                    Text(recordingManager.formattedElapsedTime)
                        .font(Theme.Typography.mono(11))
                        .foregroundStyle(Theme.Colors.ink2)
                }

                Button(recordingManager.isStopping ? "Finalizing…" : "Stop Recording") {
                    Task { await recordingManager.stopRecording() }
                }
                .disabled(recordingManager.isStopping)
                .keyboardShortcut("s")
            } else {
                // Idle state
                Text("Parrot")
                    .font(.appHeadline)

                Text(recordingManager.transcriptionEngine.isReady ? "Ready to record" : "Loading model...")
                    .font(.appCaption)
                    .foregroundStyle(Theme.Colors.ink2)

                Text(profileStore.activeProfile?.name ?? "Default")
                    .font(.appCaption)
                    .foregroundStyle(Theme.Colors.ink2)

                Button("Start Recording") {
                    Task {
                        do {
                            // Same preflight as the dashboard button — without it
                            // this path silently failed when Screen Recording
                            // permission was missing.
                            try await recordingManager.preflightPermissionsAndStart(modelContext: modelContext)
                        } catch {
                            NSApp.activate(ignoringOtherApps: true)
                            let alert = NSAlert()
                            alert.messageText = "Couldn't start recording"
                            alert.informativeText = error.localizedDescription
                            alert.runModal()
                        }
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
