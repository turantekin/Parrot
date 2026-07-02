import SwiftUI
import SwiftData

struct SidebarView: View {
    @Binding var selectedMeeting: Meeting?
    @Binding var showDashboard: Bool
    @Binding var searchText: String

    @Environment(RecordingManager.self) private var recordingManager
    @Query(sort: \Meeting.date, order: .reverse) private var meetings: [Meeting]
    @State private var showSettings = false
    @State private var deleteTarget: Meeting?

    var body: some View {
        VStack(spacing: 0) {
            // Search
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Colors.ink3)
                TextField("Search meetings", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(Theme.Typography.secondary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 6)

            // Primary nav
            VStack(spacing: 2) {
                NavRow(title: "Dashboard", icon: "house", selected: showDashboard) {
                    showDashboard = true
                    selectedMeeting = nil
                }
                NavRow(title: "New recording", icon: "mic.circle", selected: false) {
                    showDashboard = true
                    selectedMeeting = nil
                }
            }
            .padding(.horizontal, 8)

            // Meetings, grouped by day
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    Text("Meetings")
                        .font(Theme.Typography.cap)
                        .foregroundStyle(Theme.Colors.ink3)
                        .padding(.horizontal, 10)
                        .padding(.top, 14)
                        .padding(.bottom, 2)

                    ForEach(orderedGroups, id: \.0) { key, group in
                        let rows = filtered(group)
                        if !rows.isEmpty {
                            Text(key)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.Colors.ink3)
                                .padding(.horizontal, 10)
                                .padding(.top, 9)
                                .padding(.bottom, 2)
                            ForEach(rows) { meeting in
                                MeetingRow(meeting: meeting, selected: selectedMeeting?.id == meeting.id)
                                    .onTapGesture {
                                        selectedMeeting = meeting
                                        showDashboard = false
                                    }
                                    .contextMenu {
                                        Button("Delete Meeting", role: .destructive) {
                                            deleteTarget = meeting
                                        }
                                        .disabled(recordingManager.isRecording
                                            && recordingManager.currentMeeting?.id == meeting.id)
                                    }
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
            }

            // Footer: in-app Settings + account
            VStack(spacing: 2) {
                Divider().padding(.horizontal, 8).padding(.bottom, 4)
                NavRow(title: "Settings", icon: "gearshape", selected: false) {
                    showSettings = true
                }
                AccountChip()
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .background(Theme.Colors.panel)
        .confirmationDialog(
            "Delete \"\(deleteTarget?.title ?? "meeting")\"?",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                guard let meeting = deleteTarget else { return }
                if selectedMeeting?.id == meeting.id {
                    selectedMeeting = nil
                    showDashboard = true
                }
                recordingManager.delete(meeting)
                deleteTarget = nil
            }
        } message: {
            Text("The recording, transcript, and insights will be permanently removed.")
        }
        .sheet(isPresented: $showSettings) {
            VStack(spacing: 0) {
                HStack {
                    Text("Settings").font(.headline)
                    Spacer()
                    Button("Done") { showSettings = false }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(12)
                Divider()
                SettingsView()
            }
        }
    }

    // Group by day label, ordered most-recent-first (meetings already sorted desc).
    private var orderedGroups: [(String, [Meeting])] {
        let groups = Dictionary(grouping: meetings) { dateGroupLabel(for: $0.date) }
        return groups.sorted {
            ($0.value.first?.date ?? .distantPast) > ($1.value.first?.date ?? .distantPast)
        }
    }

    private func filtered(_ list: [Meeting]) -> [Meeting] {
        guard !searchText.isEmpty else { return list }
        return list.filter { meeting in
            meeting.title.localizedCaseInsensitiveContains(searchText) ||
            meeting.segments.contains { $0.text.localizedCaseInsensitiveContains(searchText) }
        }
    }

    private func dateGroupLabel(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let weekAgo = calendar.date(byAdding: .day, value: -7, to: .now), date > weekAgo {
            return "This Week"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: date)
    }
}

// MARK: - Nav row

private struct NavRow: View {
    let title: String
    let icon: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .frame(width: 16)
                    .foregroundStyle(selected ? Theme.Colors.accent : Theme.Colors.ink2)
                Text(title)
                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                    .foregroundStyle(Theme.Colors.ink)
                Spacer()
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(selected ? Theme.Colors.selection : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Meeting row

private struct MeetingRow: View {
    let meeting: Meeting
    let selected: Bool

    private static let dots: [Color] = [
        Color(lightHex: 0x6A8CAF, darkHex: 0x7FA4C6),
        Color(lightHex: 0xB08A6A, darkHex: 0xC9A380),
        Color(lightHex: 0x7A9A7A, darkHex: 0x93B593),
        Color(lightHex: 0x9A7AA0, darkHex: 0xB694BC),
        Color(lightHex: 0xC4806A, darkHex: 0xD79A85),
    ]

    var body: some View {
        HStack(spacing: 9) {
            statusDot
            VStack(alignment: .leading, spacing: 1) {
                Text(meeting.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.Colors.ink)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Colors.ink2)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(meeting.date, style: .time)
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(Theme.Colors.ink3)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(selected ? Theme.Colors.selection : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        let who = meeting.themName?.nilIfEmpty
            ?? (meeting.speakerCount > 1 ? "\(meeting.speakerCount) people" : "Them")
        return "\(who) · \(meeting.formattedDuration)"
    }

    @ViewBuilder private var statusDot: some View {
        switch meeting.status {
        case .recording:
            Circle().fill(.red).frame(width: 7, height: 7)
        case .processing:
            ProgressView().controlSize(.mini).frame(width: 10, height: 10)
        default:
            Circle()
                .fill(Self.dots[meeting.id.uuidString.stableHash % Self.dots.count])
                .frame(width: 7, height: 7)
        }
    }
}

// MARK: - Account chip

private struct AccountChip: View {
    var body: some View {
        HStack(spacing: 9) {
            Text(initials)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Theme.Colors.accent, in: Circle())
            VStack(alignment: .leading, spacing: 0) {
                Text(name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.Colors.ink)
                    .lineLimit(1)
                Text("On-device · Private")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Colors.ink2)
            }
            Spacer()
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
    }

    private var name: String {
        NSFullUserName().nilIfEmpty ?? "You"
    }

    private var initials: String {
        let parts = name.split(separator: " ")
        let first = parts.first?.first.map(String.init) ?? "Y"
        let last = parts.count > 1 ? (parts.last?.first.map(String.init) ?? "") : ""
        return (first + last).uppercased()
    }
}
