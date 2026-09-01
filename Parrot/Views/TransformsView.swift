import SwiftUI

struct TransformsView: View {
    @Environment(RecordingManager.self) private var recordingManager
    @State private var items: [TransformItem] = TransformCatalog.all()
    @State private var selectedID: String = TransformKind.polish.rawValue
    @State private var draftName = ""
    @State private var draftInstruction = ""

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Transforms")
                        .font(Theme.Typography.title())
                    Spacer()
                    Button("Add") { addCustom() }
                }
                .padding(Theme.Metrics.pad)

                List(items, selection: $selectedID) { item in
                    HStack {
                        Text(item.name)
                            .font(Theme.Typography.sans(13, .medium))
                        if item.isBuiltIn {
                            Text("Built-in")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Colors.ink3)
                        }
                    }
                    .tag(item.id)
                }
                .listStyle(.plain)
            }
            .frame(minWidth: 220, idealWidth: 260)

            editor
                .padding(Theme.Metrics.pad)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Theme.Colors.canvas)
        .onAppear {
            items = TransformCatalog.all()
            selectedID = recordingManager.transforms.itemID
            loadDraft()
        }
        .onChange(of: selectedID) { _, id in
            recordingManager.transforms.itemID = id
            loadDraft()
        }
    }

    private var selected: TransformItem? { items.first { $0.id == selectedID } }

    @ViewBuilder
    private var editor: some View {
        if let item = selected {
            VStack(alignment: .leading, spacing: Theme.Metrics.sectionGap / 2) {
                Text(item.isBuiltIn ? item.name : "Custom")
                    .font(Theme.Typography.cardTitle)
                if !item.isBuiltIn {
                    TextField("Name", text: $draftName)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: draftName) { _, _ in saveDraft() }
                }
                Text("Instruction")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.ink2)
                TextEditor(text: $draftInstruction)
                    .font(Theme.Typography.body)
                    .frame(minHeight: 120)
                    .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.radius).strokeBorder(Theme.Colors.line))
                    .disabled(item.isBuiltIn)
                    .onChange(of: draftInstruction) { _, _ in
                        if !item.isBuiltIn { saveDraft() }
                    }
                HStack {
                    Button("Rewrite local") {
                        recordingManager.transforms.itemID = item.id
                        recordingManager.transforms.run(destination: .local)
                    }
                    Button("Rewrite cloud") {
                        recordingManager.transforms.itemID = item.id
                        recordingManager.transforms.run(destination: .cloud)
                    }
                    if !item.isBuiltIn {
                        Button("Delete", role: .destructive) { delete(item) }
                    }
                }
                Text(recordingManager.transforms.phase.hud)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.ink2)
                Text("Select text in another app, then rewrite. Local uses Ollama. Cloud uses the preferred vendor.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.ink3)
            }
        } else {
            Text("Select a transform")
                .font(Theme.Typography.secondary)
                .foregroundStyle(Theme.Colors.ink2)
        }
    }

    private func loadDraft() {
        draftName = selected?.name ?? ""
        draftInstruction = selected?.instruction ?? ""
    }

    private func saveDraft() {
        guard var item = selected, !item.isBuiltIn else { return }
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        item.name = name.isEmpty ? item.name : name
        item.instruction = draftInstruction
        TransformCatalog.updateCustom(item)
        items = TransformCatalog.all()
    }

    private func addCustom() {
        let item = TransformCatalog.addCustom(
            name: "Custom",
            instruction: "Rewrite the text. Keep the meaning. No preamble."
        )
        items = TransformCatalog.all()
        selectedID = item.id
        recordingManager.transforms.itemID = item.id
        loadDraft()
    }

    private func delete(_ item: TransformItem) {
        TransformCatalog.deleteCustom(id: item.id)
        items = TransformCatalog.all()
        selectedID = TransformKind.polish.rawValue
        recordingManager.transforms.itemID = selectedID
        loadDraft()
    }
}
