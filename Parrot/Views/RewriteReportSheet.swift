import SwiftData
import SwiftUI

/// Meeting page → Rewrite Report…: pick a profile (this meeting's first),
/// see what the report will have, rewrite. Local models can take minutes,
/// so the sheet shows progress and Cancel keeps the old report.
struct RewriteReportSheet: View {
    let meeting: Meeting
    @Environment(RecordingManager.self) private var recordingManager
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \CallProfile.sortOrder) private var profiles: [CallProfile]
    @State private var profileID: UUID?
    @State private var task: Task<Void, Never>?
    @State private var failure: String?

    private var chosen: CallProfile? { profiles.first { $0.id == (profileID ?? meeting.profile?.id) } ?? profiles.first }
    private var working: Bool { task != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rewrite this report")
                .font(Theme.Typography.title())
                .foregroundStyle(Theme.Colors.ink)
            Text("Parrot writes the report again from the transcript, using a profile's report. The current one is kept, so you can undo.")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.ink2)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Profile", selection: Binding(get: { chosen?.id }, set: { profileID = $0 })) {
                ForEach(profiles) { p in
                    Text(p.id == meeting.profile?.id ? "\(p.name) (this meeting's)" : p.name).tag(Optional(p.id))
                }
            }
            .disabled(working)

            if let chosen {
                VStack(alignment: .leading, spacing: 4) {
                    Text("This report will have")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.ink3)
                    Text(ProfileChanges.describe(chosen.reportTemplate).joined(separator: " · "))
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(Theme.Metrics.popoverPad)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.Colors.panel, in: RoundedRectangle(cornerRadius: Theme.Metrics.radius))

                if !CloudGate.mayLeaveMac(meeting) {
                    Hint("This meeting is on-device only, so the AI on this Mac writes it.")
                } else if chosen.onDeviceOnly {
                    Hint("\(chosen.name) is on-device only: the AI on this Mac writes it, and this meeting becomes on-device only too.")
                }
            }

            if working {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Rewriting… local models can take a few minutes.")
                        .font(Theme.Typography.secondary)
                        .foregroundStyle(Theme.Colors.ink2)
                }
            }
            if let failure {
                Text(failure)
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Colors.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    task?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Rewrite") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || chosen == nil)
            }
        }
        .padding(Theme.Metrics.pad)
        .frame(width: 460)
    }

    private func start() {
        guard let profile = chosen else { return }
        failure = nil
        task = Task {
            do {
                try await recordingManager.rewriteReport(meeting, with: profile)
                task = nil
                dismiss()
            } catch is CancellationError {
                task = nil
            } catch {
                failure = "Couldn't rewrite: \(error.localizedDescription)"
                task = nil
            }
        }
    }
}

/// Above a rewritten report: which profile wrote it, and the one-step undo.
struct RewrittenBanner: View {
    let meeting: Meeting
    @Environment(RecordingManager.self) private var recordingManager

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(Theme.Colors.accent)
            Text("Rewritten with \(meeting.profile?.name ?? "another profile").")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.ink)
            Spacer()
            Button("Undo Rewrite") { Task { await recordingManager.undoRewrite(meeting) } }
                .controlSize(.small)
        }
        .padding(.horizontal, Theme.Metrics.popoverPad)
        .padding(.vertical, Theme.Metrics.bannerInsetV)
        .background(Theme.Colors.spotlight, in: RoundedRectangle(cornerRadius: Theme.Metrics.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.radius).strokeBorder(Theme.Colors.spotlightLine))
    }
}
