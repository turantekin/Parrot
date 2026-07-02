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
                .listStyle(.sidebar)
                .frame(width: 200)

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
                            .font(.caption)
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
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .disabled(selectedProfile == nil || selectedProfile?.isBuiltIn == true)
                    .help("Delete selected profile")

                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(.windowBackground)
            }
            .frame(width: 200)

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
                        .foregroundStyle(.secondary)
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

// MARK: - Profile Master Row

private struct ProfileRow: View {
    let profile: CallProfile

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: profile.iconSystemName.isEmpty ? "person.crop.circle" : profile.iconSystemName)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.name)
                    .font(.callout)
                    .lineLimit(1)
                if profile.isBuiltIn {
                    Text("Built-in")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
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
            Section("Profile") {
                LabeledContent("Name") {
                    TextField("Name", text: $profile.name)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 240)
                }
                LabeledContent("Icon (SF Symbol)") {
                    TextField("e.g. person.crop.circle", text: $profile.iconSystemName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 240)
                }
                LabeledContent("Summary") {
                    TextField("One-line description", text: $profile.summary)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 240)
                }
                LabeledContent("Call the other party") {
                    VStack(alignment: .trailing, spacing: 2) {
                        TextField("e.g. the prospect", text: $profile.counterpart)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 240)
                        Text("What the copilot calls them in cards & notes.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // MARK: Persona & Tone section
            Section("Persona & Tone") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Persona")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $profile.persona)
                        .font(.callout)
                        .frame(minHeight: 90)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.quaternary))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Custom rules")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $profile.tone)
                        .font(.callout)
                        .frame(height: 80)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.quaternary))
                    Text("Standing house rules the copilot follows on every call with this profile — one per line. "
                        + "e.g. \"Alert me if I leave a question unanswered.\" · "
                        + "\"If they mention a pain point, suggest how we can solve it.\" · "
                        + "\"Always confirm budget before discussing timeline.\"")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle("Answer from general knowledge when documents don't cover it",
                       isOn: $profile.allowGeneralKnowledge)
            }

            // MARK: Knowledge Documents section
            Section("Knowledge Documents") {
                if knowledgeBase.documents.isEmpty {
                    Text("No documents yet — add them in the Knowledge tab, then tag them here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(knowledgeBase.documents) { doc in
                        DocTagToggle(doc: doc, profileID: profile.id, knowledgeBase: knowledgeBase)
                    }
                }
            }

            // MARK: Edit Advanced
            Section {
                DisclosureGroup("Edit Advanced") {
                    // Kinds subsection
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Call Kinds")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

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
                        .font(.caption)
                    }
                    .padding(.top, 4)

                    Divider()
                        .padding(.vertical, 4)

                    // Gauges subsection
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Sentiment Gauges")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

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
                        .font(.caption)
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
            colorHex: "#888888", iconSystemName: "questionmark.circle",
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
            lowLabel: "Low", highLabel: "High", colorHex: "#888888"))
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
                    .font(.callout)
                    .lineLimit(1)
                Text("\(doc.chunkCount) chunks")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
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
        VStack(alignment: .leading, spacing: 4) {
            // Row 1: Key + Label
            HStack(spacing: 6) {
                TextField("Key", text: $draft.key)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .focused($focused)
                    .onSubmit { onUpdate(draft) }

                TextField("Label", text: $draft.label)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .focused($focused)
                    .onSubmit { onUpdate(draft) }
            }

            // Row 2: Color + Icon
            HStack(spacing: 6) {
                TextField("#hex", text: $draft.colorHex)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .frame(maxWidth: 80)
                    .focused($focused)
                    .onSubmit { onUpdate(draft) }

                TextField("SF Symbol", text: $draft.iconSystemName)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .focused($focused)
                    .onSubmit { onUpdate(draft) }
            }

            // Row 3: Trigger description
            TextField("Trigger description", text: $draft.triggerDescription)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .focused($focused)
                .onSubmit { onUpdate(draft) }

            // Row 4: Pinned toggle + Priority stepper + Remove button
            HStack(spacing: 8) {
                Toggle("Pinned", isOn: $draft.isPinned)
                    .font(.caption)
                    .onChange(of: draft.isPinned) { onUpdate(draft) }

                Stepper("Priority: \(draft.priority)", value: $draft.priority, in: 0...99)
                    .font(.caption)
                    .onChange(of: draft.priority) { onUpdate(draft) }

                Spacer()

                Button(role: .destructive) { onDelete() } label: {
                    Label("Remove", systemImage: "minus.circle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
        // Commit on focus loss, not just Return — otherwise clicking another
        // control (or closing Settings) reverts the draft via the resync below.
        .onChange(of: focused) { _, isFocused in
            if !isFocused { onUpdate(draft) }
        }
        // Fix 2: re-sync draft when the element is externally mutated
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
        VStack(alignment: .leading, spacing: 4) {
            // Row 1: Key + Label
            HStack(spacing: 6) {
                TextField("Key", text: $draft.key)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .focused($focused)
                    .onSubmit { onUpdate(draft) }

                TextField("Label", text: $draft.label)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .focused($focused)
                    .onSubmit { onUpdate(draft) }
            }

            // Row 2: Low label + High label + Color hex + Remove button
            HStack(spacing: 6) {
                TextField("Low label", text: $draft.lowLabel)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .focused($focused)
                    .onSubmit { onUpdate(draft) }

                TextField("High label", text: $draft.highLabel)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .focused($focused)
                    .onSubmit { onUpdate(draft) }

                TextField("#hex", text: $draft.colorHex)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .frame(maxWidth: 80)
                    .focused($focused)
                    .onSubmit { onUpdate(draft) }

                Button(role: .destructive) { onDelete() } label: {
                    Image(systemName: "minus.circle")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
        // Commit on focus loss, not just Return — otherwise clicking another
        // control (or closing Settings) reverts the draft via the resync below.
        .onChange(of: focused) { _, isFocused in
            if !isFocused { onUpdate(draft) }
        }
        // Fix 2: re-sync draft when the element is externally mutated
        .onChange(of: element) { _, newElement in
            draft = newElement
        }
    }
}
