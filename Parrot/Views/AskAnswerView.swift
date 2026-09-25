import SwiftUI

/// Parrot's face in Ask Parrot: the app icon in a circle with a small ✦
/// badge, so an answer reads as the app's AI.
struct ParrotAvatar: View {
    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: Theme.Metrics.avatar, height: Theme.Metrics.avatar)
            .clipShape(Circle())
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "sparkles")
                    .font(.system(size: Theme.Metrics.avatarBadge * 0.6, weight: .bold))
                    .foregroundStyle(Theme.Colors.canvas)
                    .frame(width: Theme.Metrics.avatarBadge, height: Theme.Metrics.avatarBadge)
                    .background(Theme.Colors.accent, in: Circle())
                    .overlay(Circle().stroke(Theme.Colors.canvas, lineWidth: 1.5))
                    .offset(x: 2, y: 2)
            }
            .accessibilityLabel("Parrot")
    }
}

/// One of Parrot's answers: checked lines with citation chips, an optional
/// note, and the meetings it came from.
struct AskAnswerView: View {
    let message: AskMessage
    /// Meetings that still exist; chips of deleted ones do nothing.
    let existing: Set<UUID>
    let open: (UUID, TimeInterval?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !message.answeredByAI, !message.lines.isEmpty {
                Text("Closest moments")
                    .font(Theme.Typography.sectionLabel)
                    .foregroundStyle(Theme.Colors.label)
            }
            ForEach(Array(message.lines.enumerated()), id: \.offset) { _, line in
                VStack(alignment: .leading, spacing: 4) {
                    Text(Self.styled(line.text))
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.ink)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if !line.citations.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(line.citations, id: \.self) { chip($0) }
                        }
                    }
                }
            }
            if let note = message.note {
                Label(note, systemImage: "info.circle")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if message.answeredByAI, !sourceRefs.isEmpty {
                HStack(spacing: 6) {
                    Text("From")
                        .font(Theme.Typography.sectionLabel)
                        .foregroundStyle(Theme.Colors.label)
                    ForEach(sourceRefs, id: \.meetingID) { ref in
                        Button(Self.name(ref)) { open(ref.meetingID, nil) }
                            .buttonStyle(.plain)
                            .font(Theme.Typography.secondary)
                            .foregroundStyle(existing.contains(ref.meetingID) ? Theme.Colors.accent : Theme.Colors.ink3)
                            .disabled(!existing.contains(ref.meetingID))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Only meetings the answer cites.
    private var sourceRefs: [AskEngine.MeetingRef] {
        let used = Set(message.lines.flatMap { $0.citations.map(\.meetingID) })
        return message.refs.filter { used.contains($0.meetingID) }
    }

    private func chip(_ cite: AskEngine.Citation) -> some View {
        let ref = message.refs.first { $0.meetingID == cite.meetingID }
        let alive = existing.contains(cite.meetingID)
        let name = alive ? (ref.map(Self.name) ?? "Meeting") : "deleted"
        // Stamp first: the chip truncates its tail.
        let label = cite.time.map { "\(Receipts.stamp($0)) · \(name)" } ?? name
        return Button { open(cite.meetingID, cite.time) } label: {
            Text(label)
                .font(Theme.Typography.receipt)
                .foregroundStyle(alive ? Theme.Colors.accent : Theme.Colors.ink3)
                .lineLimit(1)
                .padding(.horizontal, Theme.Metrics.chipInsetH)
                .padding(.vertical, Theme.Metrics.chipInsetV)
                .background((alive ? Theme.Colors.accent : Theme.Colors.ink3).opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!alive)
        .help(alive ? "Open \(ref?.title ?? "the meeting") at this moment" : "This meeting was deleted")
    }

    /// Auto titles all start "Meeting …": name those by when they happened.
    static func name(_ ref: AskEngine.MeetingRef) -> String {
        if ref.title == Meeting.defaultTitle(for: ref.date) {
            return "\(ref.date.formatted(.dateTime.day().month(.abbreviated))) \(ref.date.formatted(date: .omitted, time: .shortened))"
        }
        return ref.title.count > 22 ? String(ref.title.prefix(21)) + "…" : ref.title
    }

    static func styled(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}
