import SwiftUI
import SwiftData

// MARK: - ProfilesSettingsView

struct ProfilesSettingsView: View {
    @Environment(ProfileStore.self) private var profileStore
    @Environment(RecordingManager.self) private var recordingManager
    @Environment(\.modelContext) private var context
    @Query(sort: \CallProfile.sortOrder) private var profiles: [CallProfile]
    @State private var selectedID: UUID?

    private var selectedProfile: CallProfile? {
        profiles.first { $0.id == selectedID }
    }

    var body: some View {
        HStack(spacing: 0) {
            // MARK: Master List
            VStack(spacing: 0) {
                List(profiles, selection: $selectedID) { profile in
                    ProfileRow(profile: profile)
                        .tag(profile.id)
                }
                // Plain list on the panel color — .sidebar here rendered the
                // translucent sidebar material, which tinted the whole column.
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Theme.Colors.panel)
                .frame(width: 220)

                Divider()

                HStack(spacing: 4) {
                    // Duplicate selected
                    Button {
                        if let p = selectedProfile {
                            let copy = profileStore.duplicate(p, in: context)
                            selectedID = copy.id
                        }
                    } label: {
                        Image(systemName: "plus.square.on.square")
                            .font(Theme.Typography.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(selectedProfile == nil)
                    .help("Duplicate selected profile")

                    // Delete selected (disabled for built-ins)
                    Button {
                        if let p = selectedProfile {
                            selectedID = profiles.first { $0.id != p.id }?.id
                            profileStore.delete(p, in: context)
                        }
                    } label: {
                        Image(systemName: "trash")
                            .font(Theme.Typography.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(selectedProfile == nil || selectedProfile?.isBuiltIn == true)
                    .help("Delete selected profile")

                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Theme.Colors.panel)
            }
            .frame(width: 220)

            Divider()

            // MARK: Detail
            if let profile = selectedProfile {
                ProfileDetailView(
                    profile: profile,
                    knowledgeBase: recordingManager.knowledgeBase,
                    context: context
                )
                // Fresh identity per profile: keeps editor @State from leaking
                // across selection and stops onChange(of: persona/counterpart)
                // from false-firing when the selection itself changes.
                .id(profile.id)
            } else {
                VStack {
                    Spacer()
                    Text("Select a profile to edit")
                        .foregroundStyle(Theme.Colors.ink2)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear {
            if selectedID == nil {
                selectedID = profiles.first?.id
            }
        }
    }
}

// MARK: - Field row (label above, full-width field, optional hint below)

struct FieldRow<Field: View>: View {
    let label: String
    var hint: String?
    @ViewBuilder let field: () -> Field

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(Theme.Typography.secondary)
                .foregroundStyle(Theme.Colors.ink2)
            // Grouped Forms render a TextField's title as a leading label with a
            // right-aligned value — hide it (the row label above does that job)
            // and keep the text left-aligned like a normal field.
            field()
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .multilineTextAlignment(.leading)
                .frame(maxWidth: 400)
            if let hint {
                Hint(hint)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Profile Master Row

private struct ProfileRow: View {
    let profile: CallProfile

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: profile.iconSystemName.isEmpty ? "person.crop.circle" : profile.iconSystemName)
                .foregroundStyle(Theme.Colors.ink2)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.name)
                    .font(Theme.Typography.body)
                    .lineLimit(1)
                if profile.isBuiltIn {
                    Text("Built-in")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.ink3)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Profile Detail Form

private struct ProfileDetailView: View {
    @Bindable var profile: CallProfile
    let knowledgeBase: KnowledgeBaseService
    let context: ModelContext

    var body: some View {
        Form {
            // MARK: Profile section
            // Labels sit ABOVE full-width fields (side labels squeezed the
            // fields and wrapped badly); hints go under the field at 12pt.
            Section("Profile") {
                FieldRow(label: "Name") {
                    TextField("", text: $profile.name, prompt: Text("Name"))
                }
                FieldRow(label: "Icon (SF Symbol)") {
                    TextField("", text: $profile.iconSystemName, prompt: Text("e.g. person.crop.circle"))
                }
                FieldRow(label: "Summary") {
                    TextField("", text: $profile.summary, prompt: Text("One-line description"))
                }
                FieldRow(label: "Call the other party",
                         hint: "What the copilot calls them in cards & notes.") {
                    TextField("", text: $profile.counterpart, prompt: Text("e.g. the prospect"))
                }
            }

            // MARK: Persona & Tone section
            Section("Persona & Tone") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Persona")
                        .font(Theme.Typography.secondary)
                        .foregroundStyle(Theme.Colors.ink2)
                    TextEditor(text: $profile.persona)
                        .font(Theme.Typography.body)
                        .frame(minHeight: 90)
                        .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.radius).strokeBorder(Theme.Colors.line))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Custom rules")
                        .font(Theme.Typography.secondary)
                        .foregroundStyle(Theme.Colors.ink2)
                    TextEditor(text: $profile.tone)
                        .font(Theme.Typography.body)
                        .frame(height: 80)
                        .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.radius).strokeBorder(Theme.Colors.line))
                    Hint("House rules the copilot follows on every call — one per line, e.g. \"Always confirm budget before timeline.\"")
                }

                Toggle("Answer from general knowledge when documents don't cover it",
                       isOn: $profile.allowGeneralKnowledge)
            }

            // MARK: Knowledge Documents section
            Section("Knowledge Documents") {
                if knowledgeBase.documents.isEmpty {
                    Hint("No documents yet — add them on the Knowledge page, then tag them here.")
                } else {
                    ForEach(knowledgeBase.documents) { doc in
                        DocTagToggle(doc: doc, profileID: profile.id, knowledgeBase: knowledgeBase)
                    }
                }
            }

            // MARK: Edit Advanced
            Section {
                DisclosureGroup("Advanced — card kinds & gauges") {
                    // Kinds subsection
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Call Kinds")
                            .font(Theme.Typography.sectionLabel)
                            .foregroundStyle(Theme.Colors.label)

                        ForEach(profile.kinds) { kind in
                            KindEditorRow(kind: kind) { updated in
                                updateKind(updated, in: profile)
                            } onDelete: {
                                removeKind(kind, from: profile)
                            }
                        }

                        Button("+ Add Kind") {
                            addKind(to: profile)
                        }
                        .font(Theme.Typography.secondary)
                    }
                    .padding(.top, 4)

                    Divider()
                        .padding(.vertical, 4)

                    // Gauges subsection
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Sentiment Gauges")
                            .font(Theme.Typography.sectionLabel)
                            .foregroundStyle(Theme.Colors.label)

                        ForEach(profile.gauges) { gauge in
                            GaugeEditorRow(gauge: gauge) { updated in
                                updateGauge(updated, in: profile)
                            } onDelete: {
                                removeGauge(gauge, from: profile)
                            }
                        }

                        Button("+ Add Gauge") {
                            addGauge(to: profile)
                        }
                        .font(Theme.Typography.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 4)
        // Editing AI-behavior fields marks the profile as user-tuned so the
        // built-in preset refresh never overwrites it (see ProfileStore).
        .onChange(of: profile.persona) { _, _ in profile.isUserModified = true }
        .onChange(of: profile.counterpart) { _, _ in profile.isUserModified = true }
    }

    // MARK: - Kind mutation helpers

    private func updateKind(_ updated: ProfileKind, in profile: CallProfile) {
        var ks = profile.kinds
        if let i = ks.firstIndex(where: { $0.id == updated.id }) {
            ks[i] = updated
            profile.kinds = ks
            profile.isUserModified = true
            try? context.save()
        }
    }

    private func addKind(to profile: CallProfile) {
        var ks = profile.kinds
        ks.append(ProfileKind(
            id: UUID(), key: "new_kind", label: "New Kind",
            colorHex: "4F6FB0", iconSystemName: "questionmark.circle",
            triggerDescription: "", isPinned: false, priority: ks.count))
        profile.kinds = ks
        profile.isUserModified = true
        try? context.save()
    }

    private func removeKind(_ kind: ProfileKind, from profile: CallProfile) {
        var ks = profile.kinds
        // Never allow zero kinds: the analysis schema's kind enum can't be empty
        // (the API rejects it), so a kind-less profile would 400 on every call.
        guard ks.count > 1 else { return }
        ks.removeAll { $0.id == kind.id }
        profile.kinds = ks
        profile.isUserModified = true
        try? context.save()
    }

    // MARK: - Gauge mutation helpers

    private func updateGauge(_ updated: SentimentGauge, in profile: CallProfile) {
        var gs = profile.gauges
        if let i = gs.firstIndex(where: { $0.id == updated.id }) {
            gs[i] = updated
            profile.gauges = gs
            profile.isUserModified = true
            try? context.save()
        }
    }

    private func addGauge(to profile: CallProfile) {
        var gs = profile.gauges
        gs.append(SentimentGauge(
            id: UUID(), key: "new_gauge", label: "New Gauge",
            lowLabel: "Low", highLabel: "High", colorHex: "4F6FB0"))
        profile.gauges = gs
        profile.isUserModified = true
        try? context.save()
    }

    private func removeGauge(_ gauge: SentimentGauge, from profile: CallProfile) {
        var gs = profile.gauges
        gs.removeAll { $0.id == gauge.id }
        profile.gauges = gs
        profile.isUserModified = true
        try? context.save()
    }
}

// MARK: - Doc Tag Toggle

private struct DocTagToggle: View {
    let doc: KBDocument
    let profileID: UUID
    let knowledgeBase: KnowledgeBaseService

    private var isTagged: Bool {
        doc.profileIDs.contains(profileID)
    }

    var body: some View {
        Toggle(isOn: Binding(
            get: { isTagged },
            set: { newValue in
                var ids = doc.profileIDs
                if newValue { ids.insert(profileID) } else { ids.remove(profileID) }
                knowledgeBase.setProfiles(ids, for: doc)
            }
        )) {
            VStack(alignment: .leading, spacing: 1) {
                Text(doc.name)
                    .font(Theme.Typography.body)
                    .lineLimit(1)
                Text("\(doc.chunkCount) chunks")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.ink3)
            }
        }
    }
}

// MARK: - Editor building blocks

/// Label-above text field for the kind/gauge editors: left-aligned, prompt as
/// example text, commits on Return (focus-loss commit lives on the row).
private struct EditorField: View {
    let label: String
    let prompt: String
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    var mono = false
    let commit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(Theme.Typography.secondary)
                .foregroundStyle(Theme.Colors.ink2)
            TextField("", text: $text, prompt: Text(prompt))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .multilineTextAlignment(.leading)
                .font(mono ? Theme.Typography.mono(12) : Theme.Typography.secondary)
                .focused(focused)
                .onSubmit(commit)
        }
    }
}

/// Click-to-pick color swatches instead of typing hex codes. The palette is
/// exactly the set KindResolver maps to dark-mode-adaptive pairs, so every
/// pickable color is guaranteed to adapt. A custom hex from an older build
/// shows as an extra swatch so nothing silently changes.
private struct ColorSwatchRow: View {
    @Binding var hex: String

    private static let palette = ["4F6FB0", "2F7E96", "3F9168", "C29218",
                                  "E8943A", "C0563B", "7A5FB0", "5F6470"]

    private func normalized(_ h: String) -> String {
        (h.hasPrefix("#") ? String(h.dropFirst()) : h).uppercased()
    }

    var body: some View {
        let current = normalized(hex)
        let swatches = Self.palette.contains(current) || current.count != 6
            ? Self.palette
            : Self.palette + [current]
        HStack(spacing: 6) {
            ForEach(swatches, id: \.self) { swatch in
                Button {
                    hex = swatch
                } label: {
                    Circle()
                        .fill(KindResolver.adaptiveColor(forHex: swatch))
                        .frame(width: 18, height: 18)
                        .overlay(
                            Circle().strokeBorder(
                                normalized(swatch) == current ? Theme.Colors.ink : .clear,
                                lineWidth: 2)
                        )
                }
                .buttonStyle(.plain)
                .help("#\(swatch)")
            }
        }
    }
}

// MARK: - Kind Editor Row

private struct KindEditorRow: View {
    /// Source-of-truth element passed from the parent ForEach.
    /// Stored as a `let` so `.onChange(of: element)` can detect external mutations.
    let element: ProfileKind
    @State private var draft: ProfileKind
    /// True while any text field in this row has focus; commit on loss —
    /// .onSubmit alone loses the draft when the user clicks elsewhere.
    @FocusState private var focused: Bool
    let onUpdate: (ProfileKind) -> Void
    let onDelete: () -> Void

    init(kind: ProfileKind, onUpdate: @escaping (ProfileKind) -> Void, onDelete: @escaping () -> Void) {
        self.element = kind
        _draft = State(initialValue: kind)
        self.onUpdate = onUpdate
        self.onDelete = onDelete
    }

    var body: some View {
        let color = KindResolver.adaptiveColor(forHex: draft.colorHex)
        VStack(alignment: .leading, spacing: 10) {
            // Live preview: this is exactly the chip the copilot card will show,
            // so color/icon/name edits give immediate feedback here.
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(color.opacity(0.14))
                    .frame(width: 24, height: 24)
                    .overlay(
                        Image(systemName: draft.iconSystemName.isEmpty ? "sparkle" : draft.iconSystemName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(color)
                    )
                Text(draft.label.isEmpty ? "New card" : draft.label)
                    .font(Theme.Typography.cardTitle)
                    .foregroundStyle(Theme.Colors.ink)
                if draft.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.Colors.warn)
                        .help("Stays on screen until handled")
                }
                Spacer()
                Button(role: .destructive) { onDelete() } label: {
                    Image(systemName: "trash")
                        .font(Theme.Typography.secondary)
                        .foregroundStyle(Theme.Colors.stop)
                }
                .buttonStyle(.plain)
                .help("Remove this card kind")
            }

            EditorField(label: "Card name", prompt: "e.g. Suggested answer",
                        text: $draft.label, focused: $focused) { onUpdate(draft) }
                .frame(maxWidth: 400)

            EditorField(label: "Show this card when…",
                        prompt: "e.g. They asked something that hasn't been answered yet",
                        text: $draft.triggerDescription, focused: $focused) { onUpdate(draft) }

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Color")
                        .font(Theme.Typography.secondary)
                        .foregroundStyle(Theme.Colors.ink2)
                    ColorSwatchRow(hex: $draft.colorHex)
                }
                EditorField(label: "Icon (SF Symbol)", prompt: "e.g. lightbulb.fill",
                            text: $draft.iconSystemName, focused: $focused, mono: true) { onUpdate(draft) }
                    .frame(width: 180)
                EditorField(label: "Internal key", prompt: "e.g. suggestion",
                            text: $draft.key, focused: $focused, mono: true) { onUpdate(draft) }
                    .frame(width: 150)
            }

            HStack(spacing: 16) {
                Toggle("Keep on screen until handled", isOn: $draft.isPinned)
                    .font(Theme.Typography.secondary)
                Spacer()
                Stepper("Priority: \(draft.priority)", value: $draft.priority, in: 0...99)
                    .font(Theme.Typography.secondary)
                    .help("Higher-priority cards win when space is tight")
            }
        }
        .padding(12)
        .background(Theme.Colors.canvas, in: RoundedRectangle(cornerRadius: Theme.Metrics.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.radius).strokeBorder(Theme.Colors.line))
        // Non-text controls commit immediately; onChange sees the fresh draft.
        .onChange(of: draft.isPinned) { onUpdate(draft) }
        .onChange(of: draft.priority) { onUpdate(draft) }
        .onChange(of: draft.colorHex) { onUpdate(draft) }
        // Commit on focus loss, not just Return — otherwise clicking another
        // control (or closing Settings) reverts the draft via the resync below.
        .onChange(of: focused) { _, isFocused in
            if !isFocused { onUpdate(draft) }
        }
        // Re-sync draft when the element is externally mutated.
        .onChange(of: element) { _, newElement in
            draft = newElement
        }
    }
}

// MARK: - Gauge Editor Row

private struct GaugeEditorRow: View {
    /// Source-of-truth element passed from the parent ForEach.
    /// Stored as a `let` so `.onChange(of: element)` can detect external mutations.
    let element: SentimentGauge
    @State private var draft: SentimentGauge
    /// True while any text field in this row has focus; commit on loss —
    /// .onSubmit alone loses the draft when the user clicks elsewhere.
    @FocusState private var focused: Bool
    let onUpdate: (SentimentGauge) -> Void
    let onDelete: () -> Void

    init(gauge: SentimentGauge, onUpdate: @escaping (SentimentGauge) -> Void, onDelete: @escaping () -> Void) {
        self.element = gauge
        _draft = State(initialValue: gauge)
        self.onUpdate = onUpdate
        self.onDelete = onDelete
    }

    var body: some View {
        let color = KindResolver.adaptiveColor(forHex: draft.colorHex)
        VStack(alignment: .leading, spacing: 10) {
            // Live preview mirrors the sentiment strip: dot + name + meter.
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(draft.label.isEmpty ? "New gauge" : draft.label)
                    .font(Theme.Typography.cardTitle)
                    .foregroundStyle(Theme.Colors.ink)
                Capsule().fill(color).frame(width: 36, height: 4)
                Spacer()
                Button(role: .destructive) { onDelete() } label: {
                    Image(systemName: "trash")
                        .font(Theme.Typography.secondary)
                        .foregroundStyle(Theme.Colors.stop)
                }
                .buttonStyle(.plain)
                .help("Remove this gauge")
            }

            EditorField(label: "Gauge name", prompt: "e.g. Buying temperature",
                        text: $draft.label, focused: $focused) { onUpdate(draft) }
                .frame(maxWidth: 400)

            HStack(spacing: 16) {
                EditorField(label: "Low end means…", prompt: "e.g. Cold",
                            text: $draft.lowLabel, focused: $focused) { onUpdate(draft) }
                EditorField(label: "High end means…", prompt: "e.g. Ready to buy",
                            text: $draft.highLabel, focused: $focused) { onUpdate(draft) }
            }

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Color")
                        .font(Theme.Typography.secondary)
                        .foregroundStyle(Theme.Colors.ink2)
                    ColorSwatchRow(hex: $draft.colorHex)
                }
                EditorField(label: "Internal key", prompt: "e.g. buying_temperature",
                            text: $draft.key, focused: $focused, mono: true) { onUpdate(draft) }
                    .frame(width: 180)
            }
        }
        .padding(12)
        .background(Theme.Colors.canvas, in: RoundedRectangle(cornerRadius: Theme.Metrics.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.radius).strokeBorder(Theme.Colors.line))
        .onChange(of: draft.colorHex) { onUpdate(draft) }
        // Commit on focus loss, not just Return — otherwise clicking another
        // control (or closing Settings) reverts the draft via the resync below.
        .onChange(of: focused) { _, isFocused in
            if !isFocused { onUpdate(draft) }
        }
        // Re-sync draft when the element is externally mutated.
        .onChange(of: element) { _, newElement in
            draft = newElement
        }
    }
}
