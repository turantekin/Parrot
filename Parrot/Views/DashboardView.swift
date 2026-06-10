import SwiftUI
import SwiftData

struct DashboardView: View {
    @Binding var selectedMeeting: Meeting?
    @Binding var showDashboard: Bool

    @Environment(RecordingManager.self) private var recordingManager
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Meeting.date, order: .reverse) private var meetings: [Meeting]

    @State private var errorMessage: String?
    @State private var showPermissionAlert = false
    @AppStorage("copilotEnabled") private var copilotEnabled = false

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                // Record button
                recordButton
                    .padding(.top, 40)

                // Model status
                modelStatus

                // Stats
                statsRow

                // Recent meetings
                if !recentMeetings.isEmpty {
                    recentMeetingsSection
                }

                Spacer()
            }
            .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert("Screen Recording Permission Required", isPresented: $showPermissionAlert) {
            Button("Open System Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Parrot needs Screen Recording permission to capture meeting audio.\n\nIn System Settings, click '+', find Parrot, and enable it. You may need to restart Parrot afterward.")
        }
        .alert("Recording Error", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            if let errorMessage {
                Text(errorMessage)
            }
        }
    }

    // MARK: - Record Button

    private var recordButton: some View {
        VStack(spacing: 12) {
            Button {
                Task {
                    do {
                        try await recordingManager.startRecording(modelContext: modelContext)
                    } catch CaptureError.screenRecordingDenied {
                        showPermissionAlert = true
                    } catch let error as NSError where error.localizedDescription.contains("TCC") || error.localizedDescription.contains("declined") {
                        showPermissionAlert = true
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            } label: {
                Image(systemName: "record.circle")
                    .font(.system(size: 64))
                    .foregroundStyle(.red)
                    .symbolEffect(.pulse, options: .repeating, isActive: recordingManager.isRecording)
            }
            .buttonStyle(.plain)
            .disabled(!recordingManager.transcriptionEngine.isReady)

            Text("Start Recording")
                .font(.headline)
                .foregroundStyle(.primary)

            Text("Captures system audio and microphone")
                .font(.caption)
                .foregroundStyle(.secondary)

            if copilotEnabled {
                callBriefField
            }
        }
    }

    /// Optional one-line context the copilot gets from second one of the call.
    private var callBriefField: some View {
        @Bindable var recordingManager = recordingManager
        return HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.caption)
                .foregroundStyle(.purple)

            TextField(
                "Brief the copilot (optional) — e.g. \"Call with Westfield PM about AC replacement\"",
                text: $recordingManager.nextCallBrief
            )
            .textFieldStyle(.roundedBorder)
            .font(.caption)
        }
        .frame(maxWidth: 420)
        .padding(.top, 4)
    }

    // MARK: - Model Status

    @ViewBuilder
    private var modelStatus: some View {
        switch recordingManager.transcriptionEngine.modelState {
        case .notLoaded:
            Label("Model not loaded", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .font(.caption)
        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading WhisperKit model...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .downloading(let progress):
            VStack(spacing: 4) {
                ProgressView(value: progress)
                    .frame(width: 200)
                Text("Downloading model... \(Int(progress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .ready:
            Label("Ready to record", systemImage: "checkmark.circle")
                .foregroundStyle(.green)
                .font(.caption)
        case .error(let message):
            Label(message, systemImage: "xmark.circle")
                .foregroundStyle(.red)
                .font(.caption)
        }
    }

    // MARK: - Stats Row

    private var statsRow: some View {
        HStack(spacing: 24) {
            StatCard(
                title: "Meetings",
                value: "\(meetings.count)",
                icon: "doc.text"
            )
            StatCard(
                title: "Hours Recorded",
                value: String(format: "%.1f", totalHours),
                icon: "clock"
            )
            StatCard(
                title: "Words Transcribed",
                value: formatNumber(totalWords),
                icon: "text.alignleft"
            )
        }
    }

    private var totalHours: Double {
        meetings.reduce(0) { $0 + $1.duration } / 3600
    }

    private var totalWords: Int {
        meetings.reduce(0) { total, meeting in
            total + meeting.segments.reduce(0) { $0 + $1.text.split(separator: " ").count }
        }
    }

    private func formatNumber(_ n: Int) -> String {
        if n >= 1000 {
            return String(format: "%.1fK", Double(n) / 1000)
        }
        return "\(n)"
    }

    // MARK: - Recent Meetings

    private var recentMeetings: [Meeting] {
        Array(meetings.prefix(5))
    }

    private var recentMeetingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent Meetings")
                .font(.title3)
                .fontWeight(.semibold)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(recentMeetings) { meeting in
                        RecentMeetingCard(meeting: meeting)
                            .onTapGesture {
                                selectedMeeting = meeting
                                showDashboard = false
                            }
                    }
                }
            }
        }
    }
}

// MARK: - Stat Card

struct StatCard: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title)
                .fontWeight(.bold)
                .monospacedDigit()
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(width: 120, height: 100)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Recent Meeting Card

struct RecentMeetingCard: View {
    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(meeting.title)
                .font(.headline)
                .lineLimit(2)

            HStack(spacing: 6) {
                Text(meeting.date, style: .date)
                Text(meeting.formattedDuration)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if meeting.speakerCount > 0 {
                Label("\(meeting.speakerCount) speakers", systemImage: "person.2")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: 180, height: 100, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
