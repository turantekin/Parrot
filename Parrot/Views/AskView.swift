import SwiftUI

/// Ask Parrot: one question across every past call (or one meeting), an
/// answer whose every claim opens the moment it came from.
struct AskView: View {
    let request: AppSession.AskRequest
    @Environment(RecordingManager.self) private var recordingManager
    @Environment(AppSession.self) private var appSession
    @Environment(\.dismiss) private var dismiss

    @State private var question = ""
    @State private var result: AskEngine.Result?
    @State private var asking = false
    @State private var searchAll = false
    @FocusState private var focused: Bool

    private var scope: UUID? { searchAll ? nil : request.scope }

    static let examples = [
        "What did I promise to send, and to whom?",
        "What objections came up about pricing?",
        "What did we decide about the timeline?",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(Theme.Colors.accent)
                Text("Ask Parrot")
                    .font(Theme.Typography.title(18))
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            if let title = request.scopeTitle {
                Picker("", selection: $searchAll) {
                    Text("This meeting: \(title)").tag(false)
                    Text("All meetings").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            HStack(spacing: 8) {
                TextField(request.scope == nil || searchAll
                          ? "What did I promise Acme?" : "What did they say about pricing?",
                          text: $question)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.Typography.body)
                    .focused($focused)
                    .onSubmit(run)
                Button("Ask", action: run)
                    .buttonStyle(.borderedProminent)
                    .disabled(asking || question.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if asking {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Searching your meetings…")
                                .font(Theme.Typography.secondary)
                                .foregroundStyle(Theme.Colors.ink2)
                        }
                    } else if let result {
                        answer(result)
                    } else {
                        examplesList
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text(privacyLine)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Metrics.pad)
        .frame(width: 580, height: 540)
        .onAppear { focused = true }
    }

    // MARK: Answer

    @ViewBuilder
    private func answer(_ result: AskEngine.Result) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ParrotAvatar()
            VStack(alignment: .leading, spacing: 8) {
                if !result.answeredByAI, !result.sources.isEmpty {
                    Text("Closest moments")
                        .font(Theme.Typography.sectionLabel)
                        .foregroundStyle(Theme.Colors.label)
                }
                ForEach(Array(result.lines.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .top, spacing: 8) {
                        Text(Self.styled(line.text))
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Colors.ink)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: 4) {
                            ForEach(line.citations, id: \.self) { cite in
                                citationChip(cite, refs: result.refs)
                            }
                        }
                    }
                }
                if let note = result.note {
                    Label(note, systemImage: "info.circle")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }

        if result.answeredByAI, !sourceMeetings(result).isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("From")
                    .font(Theme.Typography.sectionLabel)
                    .foregroundStyle(Theme.Colors.label)
                ForEach(sourceMeetings(result), id: \.meetingID) { ref in
                    Button {
                        open(ref.meetingID, at: nil)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.text")
                            Text(ref.title).lineLimit(1)
                            Text(ref.date.formatted(date: .abbreviated, time: .omitted))
                                .foregroundStyle(Theme.Colors.ink3)
                        }
                        .font(Theme.Typography.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, Theme.Metrics.chipInsetH)
        }
    }

    private func citationChip(_ cite: AskEngine.Citation, refs: [AskEngine.MeetingRef]) -> some View {
        let ref = refs.first { $0.meetingID == cite.meetingID }
        let title = ref?.title ?? "Meeting"
        // Auto titles all start "Meeting …": name those by when they happened.
        let name = ref.map { $0.title == Meeting.defaultTitle(for: $0.date)
            ? "\($0.date.formatted(.dateTime.day().month(.abbreviated))) \($0.date.formatted(date: .omitted, time: .shortened))"
            : Self.short($0.title) } ?? title
        // Stamp first: the chip truncates its tail.
        let label = cite.time.map { "\(Receipts.stamp($0)) · \(name)" } ?? name
        return Button {
            open(cite.meetingID, at: cite.time)
        } label: {
            Text(label)
                .font(Theme.Typography.receipt)
                .foregroundStyle(Theme.Colors.accent)
                .lineLimit(1)
                .padding(.horizontal, Theme.Metrics.chipInsetH)
                .padding(.vertical, Theme.Metrics.chipInsetV)
                .background(Theme.Colors.accent.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .help(cite.time == nil ? "Open \(title)" : "Open \(title) at this moment")
    }

    private var examplesList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Try")
                .font(Theme.Typography.sectionLabel)
                .foregroundStyle(Theme.Colors.label)
            ForEach(Self.examples, id: \.self) { example in
                Button(example) {
                    question = example
                    run()
                }
                .buttonStyle(.plain)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.accent)
            }
        }
    }

    // MARK: Actions

    private func run() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !asking else { return }
        asking = true
        Task {
            result = await recordingManager.ask(q, scope: scope)
            asking = false
        }
    }

    private func open(_ meetingID: UUID, at time: TimeInterval?) {
        appSession.pendingJump = AppSession.Jump(meetingID: meetingID, time: time)
        dismiss()
    }

    private func sourceMeetings(_ result: AskEngine.Result) -> [AskEngine.MeetingRef] {
        let used = Set(result.lines.flatMap { $0.citations.map(\.meetingID) })
        // Only meetings the answer cites: a "couldn't find it" answer used none.
        return result.refs.filter { used.contains($0.meetingID) }
    }

    private var privacyLine: String {
        let switching = recordingManager.callAnalysisEngine.provider as? SwitchingAnalysisProvider
        guard switching?.askConfigured == true else {
            return "Search runs on this Mac. Nothing is sent anywhere."
        }
        if switching?.askRunsLocally == true {
            return "Search runs on this Mac, and your local model writes the answer. Nothing leaves your Mac."
        }
        return "Search runs on this Mac. The few best excerpts (not whole meetings, never audio) go to your Copilot AI to write the answer."
    }

    static func short(_ title: String) -> String {
        title.count > 22 ? String(title.prefix(21)) + "…" : title
    }

    private static func styled(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}
