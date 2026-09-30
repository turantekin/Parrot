import SwiftData
import SwiftUI

/// The review screen, shared by imported files and AI apps' suggestions:
/// who it came from (and why), what would change, the privacy line, then
/// Apply / Save as new / Discard. Nothing changes before a button is pressed.
struct ProfileReviewView: View {
    let item: PendingProfile
    /// Called once the user decided (or closed a file that was refused).
    let done: () -> Void
    @Environment(ProfileStore.self) private var profileStore
    @Environment(RecordingManager.self) private var recordingManager
    @Environment(\.modelContext) private var context
    @Query(sort: \CallProfile.sortOrder) private var profiles: [CallProfile]

    private var decoded: Result<ProfileFile, ProfileFile.Refused> {
        do { return .success(try ProfileFile.decode(item.data)) } catch {
            return .failure(error as? ProfileFile.Refused ?? .init(reason: "This isn't a Parrot profile, or it's damaged."))
        }
    }

    private var isSuggestion: Bool { if case .suggestion = item.origin { true } else { false } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch decoded {
            case .failure(let refused): refusedView(refused.reason)
            case .success(let file): review(file, target: ProfileStore.target(for: file, in: profiles))
            }
        }
        .padding(Theme.Metrics.pad)
        .frame(width: 560)
        .frame(maxHeight: 680)
    }

    // MARK: Parts

    private func sourceLine(_ file: ProfileFile) -> String {
        switch item.origin {
        case .suggestion: return "Suggested by \(AIApps.appName(file.suggestion?.from))"
        case .file(let name): return "From a file: \(name)"
        }
    }

    private func refusedView(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Parrot can't use this profile")
                .font(Theme.Typography.title())
                .foregroundStyle(Theme.Colors.ink)
            Text(reason)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.ink2)
            HStack { Spacer(); Button("Close") { finish() }.keyboardShortcut(.defaultAction) }
        }
    }

    @ViewBuilder
    private func review(_ file: ProfileFile, target: CallProfile?) -> some View {
        let changes = ProfileChanges.between(target.map(ProfileFile.contents), currentlyPrivate: target?.onDeviceOnly ?? false, and: file)
        Text(sourceLine(file).uppercased())
            .font(Theme.Typography.cap)
            .foregroundStyle(Theme.Colors.ink3)
        Text(target.map { "Changes to \u{201C}\($0.name)\u{201D}" } ?? "New profile: \u{201C}\(file.profile.name)\u{201D}")
            .font(Theme.Typography.title())
            .foregroundStyle(Theme.Colors.ink)
        if let reason = file.suggestion?.reason, !reason.isEmpty {
            (Text("Why: ").bold() + Text(reason))
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(Theme.Metrics.popoverPad)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.Colors.panel, in: RoundedRectangle(cornerRadius: Theme.Metrics.radius))
        }

        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if target != nil && changes.isEmpty {
                    Hint("Nothing would change: this is the same as your profile.")
                }
                if let persona = changes.persona { group("Persona") { beforeAfter(persona, isNew: target == nil) } }
                if !(changes.kindsAdded + changes.kindsRemoved + changes.kindsChanged).isEmpty {
                    group("What to flag") {
                        tags(added: changes.kindsAdded, removed: changes.kindsRemoved, changed: changes.kindsChanged)
                    }
                }
                if let report = changes.report {
                    group("Report") {
                        if target != nil {
                            Text(report.before.joined(separator: " · ")).strikethrough()
                                .font(Theme.Typography.secondary).foregroundStyle(Theme.Colors.ink3)
                        }
                        Text(report.after.joined(separator: " · "))
                            .font(Theme.Typography.body).foregroundStyle(Theme.Colors.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !(changes.gaugesAdded + changes.gaugesRemoved + changes.gaugesChanged).isEmpty {
                    group("Mood meters") {
                        tags(added: changes.gaugesAdded, removed: changes.gaugesRemoved, changed: changes.gaugesChanged)
                    }
                }
                if !changes.other.isEmpty && target != nil {
                    group("Other") {
                        ForEach(changes.other, id: \.label) { line in
                            Text("\(line.label): \(line.before.isEmpty ? "(empty)" : line.before) → \(line.after.isEmpty ? "(empty)" : line.after)")
                                .font(Theme.Typography.secondary).foregroundStyle(Theme.Colors.ink2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        if changes.turnsOnDeviceOnly {
            Label("This turns on On-device only for this profile.", systemImage: "lock.fill")
                .font(Theme.Typography.secondary)
                .foregroundStyle(Theme.Colors.good)
        }
        if target == nil {
            Hint("Add your own documents after importing: a profile file never carries them.")
        }
        buttons(file, target: target, changes: changes)
    }

    private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Theme.Typography.cardTitle).foregroundStyle(Theme.Colors.ink)
            content()
        }
        .padding(Theme.Metrics.popoverPad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.radius).strokeBorder(Theme.Colors.line))
    }

    @ViewBuilder
    private func beforeAfter(_ line: ProfileChanges.Line, isNew: Bool) -> some View {
        if isNew {
            Text(line.after).font(Theme.Typography.secondary).foregroundStyle(Theme.Colors.ink)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            HStack(alignment: .top, spacing: 8) {
                Text(line.before).strikethrough().foregroundStyle(Theme.Colors.ink3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(line.after).foregroundStyle(Theme.Colors.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(Theme.Typography.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func tags(added: [String], removed: [String], changed: [String]) -> some View {
        FlowLayout(spacing: 4) {
            ForEach(added, id: \.self) { ChangeTag(text: "+ \($0)", tint: Theme.Colors.good) }
            ForEach(removed, id: \.self) { ChangeTag(text: "− \($0)", tint: Theme.Colors.stop) }
            ForEach(changed, id: \.self) { ChangeTag(text: "\($0): changed", tint: Theme.Colors.accent) }
        }
    }

    // MARK: Decisions

    @ViewBuilder
    private func buttons(_ file: ProfileFile, target: CallProfile?, changes: ProfileChanges) -> some View {
        // A profile in use on a live call waits: changing it mid-call would
        // change the Copilot under the user's feet.
        let live = recordingManager.isRecording && target != nil && profileStore.activeProfile?.id == target?.id
        let source = isSuggestion ? "claude" : "file"
        // A file that updates a profile the user changed: their words for it.
        let theirs = !isSuggestion && target?.isUserModified == true
        if live {
            Hint("\(target?.name ?? "This profile") is in use on the call right now. Apply it after the call ends.")
        }
        HStack(spacing: 8) {
            Button(theirs ? "Keep mine" : "Discard") { finish() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            if let target {
                Button(theirs ? "Keep both" : "Save as new profile") {
                    profileStore.add(file, source: source, freshIdentity: true, in: context)
                    finish()
                }
                Button(theirs ? "Use theirs" : "Apply") {
                    let label = isSuggestion ? "Before \(AIApps.appName(file.suggestion?.from))'s suggestion" : "Before importing a file"
                    profileStore.apply(file, to: target, label: label, in: context)
                    finish()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(live || changes.isEmpty)
            } else {
                Button("Add profile") {
                    profileStore.add(file, source: source, in: context)
                    finish()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    /// A suggestion's file goes once it's decided; an opened file is the user's own.
    private func finish() {
        if case .suggestion(let url) = item.origin { try? FileManager.default.removeItem(at: url) }
        done()
    }
}

/// Main window: "Claude suggested changes to 'Sales discovery'. Later / Review".
struct ProfileSuggestionBanner: View {
    let item: PendingProfile
    let profiles: [CallProfile]
    let review: () -> Void
    let later: () -> Void

    private var text: String {
        guard let file = try? ProfileFile.decode(item.data) else { return "An AI app sent a profile Parrot can't use." }
        let who = AIApps.appName(file.suggestion?.from)
        if let target = ProfileStore.target(for: file, in: profiles) { return "\(who) suggested changes to \u{201C}\(target.name)\u{201D}." }
        return "\(who) suggested a new profile: \u{201C}\(file.profile.name)\u{201D}."
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles").foregroundStyle(Theme.Colors.accent)
            Text(text).font(Theme.Typography.body).foregroundStyle(Theme.Colors.ink)
            Spacer(minLength: 12)
            Button("Later", action: later)
            Button("Review", action: review).buttonStyle(.borderedProminent)
        }
        .controlSize(.small)
        .padding(.horizontal, Theme.Metrics.popoverPad)
        .padding(.vertical, Theme.Metrics.bannerInsetV)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Metrics.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.radius).strokeBorder(Theme.Colors.spotlightLine))
        .frame(maxWidth: 640)
    }
}

/// "+ Decision-maker", "− Opportunity", "Objection: changed" in the review.
private struct ChangeTag: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(Theme.Typography.caption)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, Theme.Metrics.chipInsetH + 2)
            .padding(.vertical, Theme.Metrics.chipInsetV + 2)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: Theme.Metrics.chipRadius))
            .foregroundStyle(Theme.Colors.ink)
    }
}
