import SwiftUI

/// Copy shared by the dashboard's brief box and the live "Briefed" card.
enum BriefSummary {
    /// "Sales discovery · 2 documents in play". Without a profile, just the count.
    static func line(profile: String?, documentCount: Int) -> String {
        let docs: String
        switch documentCount {
        case 0: docs = "no documents in play"
        case 1: docs = "1 document in play"
        default: docs = "\(documentCount) documents in play"
        }
        guard let profile, !profile.isEmpty else {
            return docs.prefix(1).uppercased() + String(docs.dropFirst())
        }
        return "\(profile) · \(docs)"
    }
}

/// The documents the copilot can quote on this call, with a jump to Settings → Knowledge.
struct DocumentsInPlayRow: View {
    let names: [String]
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Documents in play")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.ink3)
                Spacer()
                // Plain + accent rather than .link: renders in the offscreen harnesses too.
                Button("Knowledge…") { SettingsView.open(.knowledge, with: openSettings) }
                    .buttonStyle(.plain)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.accent)
                    .help("Add documents, or tag them into this profile, in Settings → Knowledge")
            }
            if names.isEmpty {
                Text("None yet. Add a pricing sheet or an FAQ and the copilot can quote it.")
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Colors.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(names, id: \.self) { name in
                            Label(name, systemImage: "doc.text")
                                .font(Theme.Typography.secondary)
                                .lineLimit(1)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Theme.Colors.chip,
                                            in: RoundedRectangle(cornerRadius: Theme.Metrics.chipRadius))
                        }
                    }
                }
            }
        }
    }
}

/// What the copilot is working with on this call: profile, brief, documents.
/// Open until the first insight lands, then a one-line row that opens on click.
struct LiveBriefCard: View {
    @Environment(RecordingManager.self) private var recordingManager
    @State private var expandedOverride: Bool?
    @State private var editing = false
    @State private var draft = ""

    private var engine: CallAnalysisEngine { recordingManager.callAnalysisEngine }
    private var profile: CallProfile? { engine.activeProfile }
    private var docs: [String] { recordingManager.knowledgeBase.documentsInPlay(for: profile?.id) }
    private var expanded: Bool { expandedOverride ?? engine.insights.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                expandedOverride = !expanded
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: profile?.iconSystemName ?? "sparkles")
                        .font(.appCaption)
                        .foregroundStyle(Theme.Colors.accent)
                    Text("Briefed")
                        .font(Theme.Typography.cardTitle)
                        .foregroundStyle(Theme.Colors.ink)
                    Text(BriefSummary.line(profile: profile?.name, documentCount: docs.count))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.ink3)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.appCaption)
                        .foregroundStyle(Theme.Colors.ink3)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "Hide the brief" : "Show the brief, profile and documents for this call")

            if expanded {
                Text(engine.callBrief.isEmpty
                    ? "No brief for this call. Next time, type a line on the dashboard before you hit record, so the copilot knows who you're talking to."
                    : engine.callBrief)
                    .font(Theme.Typography.body)
                    .foregroundStyle(engine.callBrief.isEmpty ? Theme.Colors.ink3 : Theme.Colors.ink)
                    .fixedSize(horizontal: false, vertical: true)

                DocumentsInPlayRow(names: docs)

                Button(engine.callBrief.isEmpty ? "Add a brief…" : "Edit brief…") {
                    draft = engine.callBrief
                    editing = true
                }
                .buttonStyle(.plain)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.accent)
                .popover(isPresented: $editing, arrowEdge: .bottom) { briefEditor }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.canvas, in: RoundedRectangle(cornerRadius: Theme.Metrics.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.radius).strokeBorder(Theme.Colors.line))
        .animation(.easeOut(duration: 0.2), value: expanded)
    }

    private var briefEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Brief for this call")
                .font(Theme.Typography.cardTitle)
            TextField("Who's on the call and what it's about", text: $draft, axis: .vertical)
                .lineLimit(2...5)
                .font(Theme.Typography.body)
                .frame(width: 320)
            HStack {
                Spacer()
                Button("Cancel") { editing = false }
                    .keyboardShortcut(.cancelAction)
                Button("Update") {
                    recordingManager.updateBrief(draft)
                    editing = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
    }
}
