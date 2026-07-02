import SwiftUI
import SwiftData
import CoreGraphics
import AVFoundation

struct DashboardView: View {
    @Binding var selectedMeeting: Meeting?
    @Binding var showDashboard: Bool

    @Environment(RecordingManager.self) private var recordingManager
    @Environment(ProfileStore.self) private var profileStore
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Meeting.date, order: .reverse) private var meetings: [Meeting]
    @Query(sort: \CallProfile.sortOrder) private var allProfiles: [CallProfile]

    @State private var errorMessage: String?
    @AppStorage("copilotEnabled") private var copilotEnabled = false

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                recordButton
                    .padding(.top, 44)

                modelStatus

                statsRow

                if !recentMeetings.isEmpty {
                    recentMeetingsSection
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Colors.canvas)
        // A real binding, not .constant: SwiftUI writes false into it on any
        // system-initiated dismissal, which a constant silently drops.
        .alert("Recording Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
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
                        // Shared permission preflight + start (also used by the
                        // menu bar) — see RecordingManager for the rationale.
                        try await recordingManager.preflightPermissionsAndStart(modelContext: modelContext)
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

            Text("Start recording")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.Colors.ink)

            Text("Captures system audio + your mic, transcribed on-device.")
                .font(Theme.Typography.secondary)
                .foregroundStyle(Theme.Colors.ink2)

            if copilotEnabled {
                profilePicker
                callBriefField
            }
        }
    }

    private var profilePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(allProfiles.sorted { $0.sortOrder < $1.sortOrder }) { profile in
                    let isActive = profileStore.activeProfile?.id == profile.id
                    Button { profileStore.setActive(profile) } label: {
                        HStack(spacing: 5) {
                            Image(systemName: profile.iconSystemName).font(.caption)
                            Text(profile.name).font(.system(size: 12.5, weight: .medium))
                        }
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .background(isActive ? Theme.Colors.accent : Theme.Colors.chip,
                                    in: Capsule())
                        .foregroundStyle(isActive ? .white : Theme.Colors.ink)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(maxWidth: 460)
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
        HStack(spacing: 12) {
            StatTile(value: "\(meetings.count)", label: "Meetings")
            StatTile(value: String(format: "%.1f", totalHours), label: "Hours")
            StatTile(value: formatNumber(totalWords), label: "Words")
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
        VStack(alignment: .leading, spacing: 4) {
            Text("Recent meetings")
                .font(Theme.Typography.cap)
                .foregroundStyle(Theme.Colors.ink3)
                .padding(.horizontal, 4)
                .padding(.bottom, 2)

            ForEach(recentMeetings) { meeting in
                Button {
                    selectedMeeting = meeting
                    showDashboard = false
                } label: {
                    DashboardMeetingRow(meeting: meeting)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Stat Card

struct StatTile: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(Theme.Typography.title(22))
                .foregroundStyle(Theme.Colors.ink)
                .monospacedDigit()
            Text(label)
                .font(Theme.Typography.secondary)
                .foregroundStyle(Theme.Colors.ink2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.Colors.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.Colors.line))
    }
}

// MARK: - Recent Meeting Card

struct DashboardMeetingRow: View {
    let meeting: Meeting

    var body: some View {
        HStack(spacing: 11) {
            Circle()
                .fill(Theme.Colors.accent.opacity(0.8))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(meeting.title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Theme.Colors.ink)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Colors.ink2)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Colors.ink3)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        let who = meeting.themName?.nilIfEmpty
            ?? (meeting.speakerCount > 1 ? "\(meeting.speakerCount) people" : "Them")
        return "\(meeting.date.formatted(date: .abbreviated, time: .shortened)) · \(who) · \(meeting.formattedDuration)"
    }
}
