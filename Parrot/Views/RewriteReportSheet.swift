import SwiftData
import SwiftUI

/// Meeting page → Rewrite Report…: pick a profile (this meeting's first),
/// see what the report will have, rewrite. Local models can take minutes,
/// so the sheet shows the step and a timer, Stop keeps the old report, and
/// Keep working closes the sheet while the rewrite carries on.
struct RewriteReportSheet: View {
    let meeting: Meeting
    @Environment(RecordingManager.self) private var recordingManager
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \CallProfile.sortOrder) private var profiles: [CallProfile]
    @State private var profileID: UUID?

    private var chosen: CallProfile? { profiles.first { $0.id == (profileID ?? meeting.profile?.id) } ?? profiles.first }
    private var run: RewriteRun? { recordingManager.rewrites[meeting.id] }
    private var working: Bool { run?.task != nil }

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

            if let run, working {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    RewriteProgressText(run: run)
                        .font(Theme.Typography.secondary)
                        .foregroundStyle(Theme.Colors.ink2)
                }
                Hint("This can take a minute or more. Keep working, and the report updates on its own when it's done.")
            }
            if let failure = run?.failure {
                Text(failure)
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Colors.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                if working {
                    Button("Stop") { recordingManager.stopRewrite(meeting) }
                    Button("Keep working") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Rewrite") {
                        if let chosen { recordingManager.startRewrite(meeting, with: chosen) }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen == nil)
                }
            }
        }
        .padding(Theme.Metrics.pad)
        .frame(width: 460)
        // Done (or stopped): the meeting page shows the result.
        .onChange(of: run == nil) { _, gone in if gone { dismiss() } }
    }
}

/// "Writing the report (1 of 2) · 0:42", ticking every second.
struct RewriteProgressText: View {
    let run: RewriteRun

    var body: some View {
        TimelineView(.periodic(from: run.startedAt, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(run.startedAt)))
            Text("\(run.stepText) · \(seconds / 60):\(String(format: "%02d", seconds % 60))")
                .monospacedDigit()
        }
    }
}

/// On the meeting page after Keep working: the running step and timer with
/// Stop, or why it failed with OK.
struct RewritingBanner: View {
    let meeting: Meeting
    @Environment(RecordingManager.self) private var recordingManager

    var body: some View {
        if let run = recordingManager.rewrites[meeting.id] {
            HStack(spacing: 10) {
                if run.task != nil {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Rewriting with \(run.profileName)…")
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Colors.ink)
                        RewriteProgressText(run: run)
                            .font(Theme.Typography.secondary)
                            .foregroundStyle(Theme.Colors.ink2)
                    }
                } else {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(Theme.Colors.warn)
                    Text(run.failure ?? "Couldn't rewrite.")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(run.task != nil ? "Stop" : "OK") { recordingManager.stopRewrite(meeting) }
                    .controlSize(.small)
            }
            .rewriteBannerStyle()
        }
    }
}

private extension View {
    func rewriteBannerStyle() -> some View {
        padding(.horizontal, Theme.Metrics.popoverPad)
            .padding(.vertical, Theme.Metrics.bannerInsetV)
            .background(Theme.Colors.spotlight, in: RoundedRectangle(cornerRadius: Theme.Metrics.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.radius).strokeBorder(Theme.Colors.spotlightLine))
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
        .rewriteBannerStyle()
    }
}
