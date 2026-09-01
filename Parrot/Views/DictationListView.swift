import SwiftUI
import SwiftData

struct DictationListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \DictationNote.date, order: .reverse) private var notes: [DictationNote]
    @Binding var selected: DictationNote?

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Dictations")
                        .font(Theme.Typography.title())
                    Spacer()
                    Text("\(notes.count)")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.ink3)
                }
                .padding(Theme.Metrics.pad)

                if notes.isEmpty {
                    Text("Finished dictations land here, newest first.")
                        .font(Theme.Typography.secondary)
                        .foregroundStyle(Theme.Colors.ink2)
                        .padding(.horizontal, Theme.Metrics.pad)
                    Spacer()
                } else {
                    List(notes, selection: $selected) { note in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(note.title)
                                .font(Theme.Typography.sans(13, .medium))
                                .lineLimit(1)
                            Text(note.date, style: .relative)
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Colors.ink3)
                        }
                        .tag(note)
                        .contextMenu {
                            Button("Copy") { ClipboardOut.copy(note.text) }
                            Button("Delete", role: .destructive) { delete(note) }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .frame(minWidth: 220, idealWidth: 260)

            if let selected {
                VStack(alignment: .leading, spacing: Theme.Metrics.sectionGap / 2) {
                    HStack {
                        Text(selected.date, style: .date)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.ink2)
                        Text(selected.date, style: .time)
                            .font(Theme.Typography.mono(11))
                            .foregroundStyle(Theme.Colors.ink3)
                        Spacer()
                        Button("Copy") { ClipboardOut.copy(selected.text) }
                        Button("Delete", role: .destructive) { delete(selected) }
                    }
                    ScrollView {
                        Text(selected.text)
                            .font(Theme.Typography.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(Theme.Metrics.pad)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                Text("Select a dictation")
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Colors.ink2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.Colors.canvas)
    }

    private func delete(_ note: DictationNote) {
        if selected?.id == note.id { selected = nil }
        modelContext.delete(note)
        try? modelContext.save()
    }
}
