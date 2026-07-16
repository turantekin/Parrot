import SwiftUI
import SwiftData

struct SidebarView: View {
    @Binding var selectedMeeting: Meeting?
    @Binding var showDashboard: Bool
    /// Settings render in the main detail pane (the old sheet was a cramped
    /// 520pt popup that made the Profiles editor unusable).
    @Binding var showSettings: Bool
    @Binding var searchText: String

    @Environment(RecordingManager.self) private var recordingManager
    @Query(sort: \Meeting.date, order: .reverse) private var meetings: [Meeting]
    /// Edit → Find (⌘F) lands here.
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Search
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Colors.ink3)
                TextField("Search meetings", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(Theme.Typography.secondary)
                    .focused($searchFocused)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Theme.Colors.chip, in: RoundedRectangle(cornerRadius: Theme.Metrics.radius))
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 6)

            // Primary nav
            VStack(spacing: 2) {
                NavRow(title: "Dashboard", icon: "house", selected: showDashboard && !showSettings) {
                    showDashboard = true
                    selectedMeeting = nil
                    showSettings = false
                }
                NavRow(title: "New recording", icon: "mic.circle", selected: false) {
                    showDashboard = true
                    selectedMeeting = nil
                    showSettings = false
                }
            }
            .padding(.horizontal, 8)

            // Meetings, grouped by day
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    Text("Meetings")
                        .textCase(.uppercase)
                        .font(Theme.Typography.cap)
                        .foregroundStyle(Theme.Colors.ink3)
                        .padding(.horizontal, 8)
                        .padding(.top, 12)
                        .padding(.bottom, 2)

                    ForEach(orderedGroups, id: \.0) { key, group in
                        let rows = filtered(group)
                        if !rows.isEmpty {
                            Text(key)
                                .textCase(.uppercase)
                                .font(Theme.Typography.cap)
                                .foregroundStyle(Theme.Colors.ink3)
                                .padding(.horizontal, 8)
                                .padding(.top, 8)
                                .padding(.bottom, 2)
                            ForEach(rows) { meeting in
                                MeetingRow(meeting: meeting, selected: selectedMeeting?.id == meeting.id)
                                    .onTapGesture {
                                        selectedMeeting = meeting
                                        showDashboard = false
                                        showSettings = false
                                    }
                                    .meetingContextMenu(meeting, onDeleted: {
                                        if selectedMeeting?.id == meeting.id {
                                            selectedMeeting = nil
                                            showDashboard = true
                                        }
                                    })
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
            }

            // Footer: in-app Settings + account
            VStack(spacing: 2) {
                Divider().padding(.horizontal, 8).padding(.bottom, 4)
                NavRow(title: "Settings", icon: "gearshape", selected: showSettings) {
                    showSettings = true
                    showDashboard = false
                    selectedMeeting = nil
                }
                AccountChip()
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .background(Theme.Colors.panel)
        .onReceive(NotificationCenter.default.publisher(for: .parrotFocusSearch)) { _ in
            searchFocused = true
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
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .frame(width: 16)
                    .foregroundStyle(selected ? Theme.Colors.accent : Theme.Colors.ink2)
                Text(title)
                    .font(Theme.Typography.sans(13, .medium))
                    .foregroundStyle(Theme.Colors.ink)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(selected ? Theme.Colors.selection : Color.clear,
                        in: RoundedRectangle(cornerRadius: Theme.Metrics.radius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Meeting row

/// Two-line row: title + trailing time, then a dual-lane talk strip drawn from
/// the transcript — Me above the centerline, Them below. The strip replaces the
/// old colored status dot as the row's identity.
struct MeetingRow: View {
    let meeting: Meeting
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(meeting.title)
                    .font(Theme.Typography.sans(13, .medium))
                    .foregroundStyle(Theme.Colors.ink)
                    .lineLimit(1)
                Spacer(minLength: 4)
                trailing
            }
            TalkStripView(meeting: meeting, selected: selected)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(selected ? Theme.Colors.selection : Color.clear,
                    in: RoundedRectangle(cornerRadius: Theme.Metrics.radius))
        .contentShape(Rectangle())
    }

    @ViewBuilder private var trailing: some View {
        switch meeting.status {
        case .recording:
            HStack(spacing: 4) {
                Circle().fill(Theme.Colors.stop).frame(width: 5, height: 5)
                // Live elapsed time — .timer counts up from the meeting start.
                Text(meeting.date, style: .timer)
                    .font(Theme.Typography.mono(11, .semibold))
                    .foregroundStyle(Theme.Colors.stop)
            }
        case .processing:
            ProgressView().controlSize(.mini).frame(width: 10, height: 10)
        default:
            Text(meeting.date, style: .time)
                .font(Theme.Typography.mono(11))
                .foregroundStyle(Theme.Colors.ink2)
        }
    }
}

// MARK: - Talk strip

/// Dual-lane activity strip: the call is split into 48 time buckets; per bucket,
/// seconds spoken by "Me" draw as a bar growing up from the centerline and
/// everyone else grows down. Empty transcript → just the centerline.
struct TalkStripView: View {
    let meeting: Meeting
    let selected: Bool

    private static let bucketCount = 48
    private static let laneHeight: CGFloat = 6
    private static let barWidth: CGFloat = 1.5

    // ponytail: process-lifetime cache keyed by meeting.id — entries are 48
    // tuples so leftovers from deleted meetings are negligible. Keyed on
    // segments.count so a live recording invalidates itself as segments stream in.
    private static var cache: [UUID: (count: Int, buckets: [(me: Double, them: Double)])] = [:]

    var body: some View {
        // Reading meeting.segments here (not inside Canvas) both feeds the cache
        // and registers observation, so the strip grows live while recording.
        let buckets = Self.buckets(for: meeting)
        let peak = buckets.reduce(0.0) { max($0, max($1.me, $1.them)) }
        Canvas { context, size in
            let midY = size.height / 2
            context.fill(
                Path(CGRect(x: 0, y: midY - 0.5, width: size.width, height: 1)),
                with: .color(Theme.Colors.line)
            )
            guard peak > 0 else { return }
            let step = size.width / CGFloat(buckets.count)
            let meColor = selected ? Theme.Colors.accent : Theme.Colors.ink3
            for (index, bucket) in buckets.enumerated() {
                let x = (CGFloat(index) + 0.5) * step - Self.barWidth / 2
                if bucket.me > 0 {
                    let h = max(0.5, CGFloat(bucket.me / peak) * Self.laneHeight)
                    context.fill(
                        Path(CGRect(x: x, y: midY - h, width: Self.barWidth, height: h)),
                        with: .color(meColor)
                    )
                }
                if bucket.them > 0 {
                    let h = max(0.5, CGFloat(bucket.them / peak) * Self.laneHeight)
                    context.fill(
                        Path(CGRect(x: x, y: midY, width: Self.barWidth, height: h)),
                        with: .color(Theme.Colors.ink3)
                    )
                }
            }
        }
        .frame(height: 14)
        .overlay(alignment: .trailing) {
            Text(meeting.formattedDuration)
                .font(Theme.Typography.mono(10))
                .foregroundStyle(Theme.Colors.ink3)
                .padding(.leading, 4)
                // Match the row background (selection tint over panel) so the
                // label reads cleanly over the bars.
                .background(selected ? Theme.Colors.selection : Color.clear)
                .background(Theme.Colors.panel)
        }
    }

    /// Cached per-bucket (me, them) speaking seconds. Recomputed only when the
    /// segment count changes; the Canvas closure never touches segments.
    private static func buckets(for meeting: Meeting) -> [(me: Double, them: Double)] {
        let segments = meeting.segments
        if let cached = cache[meeting.id], cached.count == segments.count {
            return cached.buckets
        }
        let computed = compute(segments: segments, duration: meeting.duration)
        cache[meeting.id] = (segments.count, computed)
        return computed
    }

    private static func compute(
        segments: [TranscriptSegment],
        duration: TimeInterval
    ) -> [(me: Double, them: Double)] {
        guard !segments.isEmpty else { return [] }
        let total = max(duration, segments.map(\.endTime).max() ?? 0)
        guard total > 0 else { return [] }
        let bucketLength = total / Double(bucketCount)
        var buckets = [(me: Double, them: Double)](
            repeating: (0, 0), count: bucketCount
        )
        for segment in segments {
            let start = max(0, segment.startTime)
            let end = min(total, max(start, segment.endTime))
            let isMe = segment.speakerLabel == "Me"
            let first = min(bucketCount - 1, Int(start / bucketLength))
            let last = min(bucketCount - 1, Int(end / bucketLength))
            for index in first...last {
                let bucketStart = Double(index) * bucketLength
                let overlap = max(0, min(end, bucketStart + bucketLength) - max(start, bucketStart))
                if isMe {
                    buckets[index].me += overlap
                } else {
                    buckets[index].them += overlap
                }
            }
        }
        return buckets
    }
}

// MARK: - Account chip

private struct AccountChip: View {
    var body: some View {
        HStack(spacing: 8) {
            Text(initials)
                .font(Theme.Typography.sans(10, .semibold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Theme.Colors.accent, in: Circle())
            VStack(alignment: .leading, spacing: 0) {
                Text(name)
                    .font(Theme.Typography.sans(13, .medium))
                    .foregroundStyle(Theme.Colors.ink)
                    .lineLimit(1)
                Text("On-device · Private")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.ink2)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
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
