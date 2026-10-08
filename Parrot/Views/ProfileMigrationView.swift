import AppKit
import SwiftData
import SwiftUI

/// Shown once after the Profiles 2.0 update ("Reports can now match each
/// call type"): one row per profile, a switch for each built-in that has a
/// report of its own. Switches act at once, so closing it any way keeps
/// what's shown, and it never comes back (marked shown on appear).
struct ProfileMigrationView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ProfileStore.self) private var profileStore
    @Query(sort: \CallProfile.sortOrder) private var profiles: [CallProfile]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Reports can now match each call type")
                .font(Theme.Typography.title())
                .foregroundStyle(Theme.Colors.ink)
            Text("A sales call and an interview need different reports. Pick which profiles switch.")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.ink2)
                .padding(.top, 4)
                .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(profiles) { profile in
                        Divider()
                        ProfileMigrationRow(profile: profile)
                    }
                }
            }
            .frame(maxHeight: 460)

            Text("Your Assistant settings didn't change. A backup of every profile was saved. Past meetings keep their reports.")
                .font(Theme.Typography.secondary)
                .foregroundStyle(Theme.Colors.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(Theme.Metrics.popoverPad)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.Colors.panel, in: RoundedRectangle(cornerRadius: Theme.Metrics.radius))
                .padding(.top, 12)

            HStack {
                Button("Show backup in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([profileStore.backupFolder])
                }
                .buttonStyle(.link)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 12)
        }
        .padding(Theme.Metrics.pad)
        .frame(width: 560)
        .background(Theme.Colors.canvas)
        .onAppear { profileStore.markProfiles2ScreenShown() }
    }
}

private struct ProfileMigrationRow: View {
    @Bindable var profile: CallProfile

    /// The built-in's own report, when it differs from the classic one.
    private var newReport: ReportTemplate? {
        profile.presetReportTemplate.flatMap { $0.isStandard ? nil : $0 }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: profile.iconSystemName.isEmpty ? "person.crop.circle" : profile.iconSystemName)
                .foregroundStyle(Theme.Colors.ink2)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                    .font(Theme.Typography.cardTitle)
                    .foregroundStyle(Theme.Colors.ink)
                change
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Colors.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if newReport != nil {
                HStack(spacing: 6) {
                    Text("Use the new report")
                        .font(Theme.Typography.secondary)
                        .foregroundStyle(Theme.Colors.ink2)
                    Toggle("", isOn: Binding(get: { profile.reportChoice == .preset },
                                             set: { profile.useBuiltInReport($0) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 10)
    }

    @ViewBuilder private var change: some View {
        if let report = newReport {
            let after = report.titles.joined(separator: ", ") + (report.coachingEnabled ? "" : " (no coaching report)")
            if profile.versions.isEmpty {
                // Added by this update, so there's no "before".
                Text("New: \(profile.summary) Report: \(after).")
            } else if profile.isUserModified && profile.reportChoice != .preset {
                Text("You tuned this one, so it keeps the classic report for now.\n→ \(after)")
            } else {
                Text("\(Text(ReportTemplate.standard.titles.joined(separator: ", ")).strikethrough()) → \(after)")
            }
        } else if profile.isBuiltIn {
            Text("No change.")
        } else {
            Text("Keeps the classic report. Create a report template later in the profile's settings.")
        }
    }
}
