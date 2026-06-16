import SwiftUI
import AVFoundation

struct MeetingDetailView: View {
    let meeting: Meeting
    @State private var editingTitle = false
    @State private var titleText = ""
    @State private var audioPlayer: AVAudioPlayer?      // system audio ("Them")
    @State private var micPlayer: AVAudioPlayer?        // mic audio ("Me")
    @State private var isPlaying = false
    @State private var playbackTime: TimeInterval = 0
    @State private var playbackSpeed: Float = 1.0
    @State private var playbackTimer: Timer?
    @State private var activeSegmentID: UUID?
    @State private var showInsights = true
    @State private var showSummary = true
    @State private var showCoaching = true
    @State private var themNameText = ""

    var body: some View {
        VStack(spacing: 0) {
            // Header
            meetingHeader

            Divider()

            // Audio player bar
            if meeting.status == .done || meeting.status == .processing {
                audioPlayerBar
                Divider()
            }

            // AI-generated post-call report
            if let summary = meeting.summary {
                summarySection(summary)
                Divider()
            }

            // AI coaching + follow-ups
            if let coaching = meeting.coaching {
                coachingSection(coaching)
                Divider()
            }

            // Copilot insights captured during the call
            if !meeting.insights.isEmpty {
                insightsSection
                Divider()
            }

            // Transcript or processing state
            if meeting.status == .processing {
                processingView
            }

            transcriptList
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            titleText = meeting.title
            themNameText = meeting.themName ?? ""
            prepareAudioPlayer()
        }
        .onDisappear {
            stopPlayback()
        }
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    Button("Export as TXT") { exportTXT() }
                    Button("Export as SRT") { exportSRT() }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }

                Button(role: .destructive) {
                    // Delete handled by parent
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    // MARK: - Header

    private var meetingHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            if editingTitle {
                TextField("Meeting title", text: $titleText, onCommit: {
                    meeting.title = titleText
                    editingTitle = false
                })
                .font(.title)
                .textFieldStyle(.plain)
            } else {
                Text(meeting.title)
                    .font(.title)
                    .fontWeight(.semibold)
                    .onTapGesture(count: 2) {
                        editingTitle = true
                    }
            }

            HStack(spacing: 12) {
                Label(meeting.date.formatted(date: .long, time: .shortened), systemImage: "calendar")
                Label(meeting.formattedDuration, systemImage: "clock")
                if meeting.speakerCount > 0 {
                    Label("\(meeting.speakerCount) speakers", systemImage: "person.2")
                }
                statusBadge
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            // Name the other party so the transcript/report read naturally.
            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle")
                    .foregroundStyle(.secondary)
                TextField("Name the other speaker (e.g. Kara)", text: $themNameText) {
                    meeting.themName = themNameText.trimmingCharacters(in: .whitespaces).nilIfEmpty
                }
                .textFieldStyle(.plain)
                .frame(maxWidth: 240)
            }
            .font(.caption)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch meeting.status {
        case .processing:
            Label("Processing", systemImage: "gearshape.2")
                .foregroundStyle(.orange)
        case .failed:
            Label("Failed", systemImage: "xmark.circle")
                .foregroundStyle(.red)
        default:
            EmptyView()
        }
    }

    // MARK: - Audio Player

    private var audioPlayerBar: some View {
        HStack(spacing: 12) {
            Button {
                togglePlayback()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
            }
            .buttonStyle(.plain)

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.secondary.opacity(0.2))
                        .frame(height: 4)

                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.accentColor)
                        .frame(
                            width: meeting.duration > 0
                                ? geo.size.width * (playbackTime / meeting.duration)
                                : 0,
                            height: 4
                        )
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { location in
                    let fraction = location.x / geo.size.width
                    seekTo(fraction * meeting.duration)
                }
            }
            .frame(height: 20)

            // Time display
            Text("\(formatTime(playbackTime)) / \(formatTime(meeting.duration))")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 100)

            // Speed selector
            Picker("Speed", selection: $playbackSpeed) {
                Text("0.5x").tag(Float(0.5))
                Text("1x").tag(Float(1.0))
                Text("1.5x").tag(Float(1.5))
                Text("2x").tag(Float(2.0))
            }
            .pickerStyle(.segmented)
            .frame(width: 160)
            .onChange(of: playbackSpeed) { _, newValue in
                audioPlayer?.rate = newValue
                micPlayer?.rate = newValue
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - Summary

    private func summarySection(_ summary: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showSummary.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "text.badge.checkmark")
                        .foregroundStyle(.purple)

                    Text("Summary")
                        .font(.headline)

                    Spacer()

                    Image(systemName: showSummary ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showSummary {
                ScrollView {
                    Text(summary)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - Coaching & Follow-ups

    private func coachingSection(_ coaching: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showCoaching.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chart.bar.doc.horizontal")
                        .foregroundStyle(.pink)
                    Text("Coaching & Follow-ups")
                        .font(.headline)
                    Spacer()
                    Image(systemName: showCoaching ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showCoaching {
                ScrollView {
                    Text(coaching)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - Copilot Insights

    private var unresolvedBlockerCount: Int {
        meeting.insights.filter { $0.kind == .blocker && !$0.isHandled }.count
    }

    private var insightsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showInsights.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.purple)

                    Text("Copilot Insights")
                        .font(.headline)

                    Text("\(meeting.insights.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if unresolvedBlockerCount > 0 {
                        Label("\(unresolvedBlockerCount) unresolved", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    Spacer()

                    Image(systemName: showInsights ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showInsights {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(meeting.sortedInsights) { insight in
                            StoredInsightRow(insight: insight) {
                                seekTo(insight.callTime)
                            }
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - Processing View

    private var processingView: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Identifying speakers...")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }

    // MARK: - Transcript List

    private var transcriptList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(meeting.sortedSegments) { segment in
                    TranscriptSegmentRow(
                        segment: segment,
                        isActive: segment.id == activeSegmentID,
                        themName: meeting.themName
                    )
                    .onTapGesture {
                        seekTo(segment.startTime)
                    }
                }
            }
            .padding()
        }
    }

    // MARK: - Audio Playback

    private func prepareAudioPlayer() {
        // Two separate tracks were recorded: system audio ("Them") and the mic
        // ("Me"). Load both so playback contains the full conversation, not just
        // the other side.
        if let path = meeting.systemAudioPath.nilIfEmpty,
           FileManager.default.fileExists(atPath: path) {
            audioPlayer = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
            audioPlayer?.enableRate = true
            audioPlayer?.prepareToPlay()
        }
        if let micPath = meeting.micAudioPath?.nilIfEmpty,
           FileManager.default.fileExists(atPath: micPath) {
            micPlayer = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: micPath))
            micPlayer?.enableRate = true
            micPlayer?.prepareToPlay()
        }
    }

    /// Starts both tracks at the same device-clock instant so they stay in sync.
    private func startSynced() {
        audioPlayer?.rate = playbackSpeed
        micPlayer?.rate = playbackSpeed
        let clock = audioPlayer?.deviceCurrentTime ?? micPlayer?.deviceCurrentTime ?? 0
        let startAt = clock + 0.08
        audioPlayer?.play(atTime: startAt)
        micPlayer?.play(atTime: startAt)
    }

    private func togglePlayback() {
        if isPlaying {
            audioPlayer?.pause()
            micPlayer?.pause()
            playbackTimer?.invalidate()
        } else {
            startSynced()
            playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                playbackTime = audioPlayer?.currentTime ?? micPlayer?.currentTime ?? 0
                updateActiveSegment()
            }
        }
        isPlaying.toggle()
    }

    private func stopPlayback() {
        audioPlayer?.stop()
        micPlayer?.stop()
        playbackTimer?.invalidate()
        isPlaying = false
    }

    private func seekTo(_ time: TimeInterval) {
        let wasPlaying = isPlaying
        audioPlayer?.pause()
        micPlayer?.pause()
        audioPlayer?.currentTime = min(time, audioPlayer?.duration ?? time)
        micPlayer?.currentTime = min(time, micPlayer?.duration ?? time)
        playbackTime = time
        updateActiveSegment()
        if wasPlaying { startSynced() }
    }

    private func updateActiveSegment() {
        activeSegmentID = meeting.sortedSegments.last { $0.startTime <= playbackTime }?.id
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%02d:%02d", m, s)
    }

    // MARK: - Export

    private func exportTXT() {
        let content = ExportService.exportToTXT(meeting: meeting)
        let filename = meeting.title.replacingOccurrences(of: " ", with: "_")
        if let url = try? ExportService.save(content: content, filename: filename, extension: "txt") {
            NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
        }
    }

    private func exportSRT() {
        let content = ExportService.exportToSRT(meeting: meeting)
        let filename = meeting.title.replacingOccurrences(of: " ", with: "_")
        if let url = try? ExportService.save(content: content, filename: filename, extension: "srt") {
            NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
        }
    }
}

// MARK: - Transcript Segment Row

struct TranscriptSegmentRow: View {
    let segment: TranscriptSegment
    let isActive: Bool
    var themName: String? = nil

    private static let speakerColors: [Color] = [
        .blue, .green, .orange, .purple, .pink, .teal, .indigo, .mint
    ]

    /// Resolved speaker name: "Me" stays "Me"; everyone else shows the user's
    /// assigned name (e.g. "Kara") if set, otherwise the raw label.
    private var displayLabel: String? {
        guard let label = segment.speakerLabel else { return nil }
        if label == "Me" { return "Me" }
        return themName ?? label
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Timestamp
            Text(segment.formattedTimestamp)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 40, alignment: .trailing)

            // Speaker label
            if let speaker = displayLabel {
                Text(speaker)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(speakerColor(for: speaker))
                    .frame(width: 70, alignment: .leading)
            }

            // Text
            Text(segment.text)
                .font(.body)
                .textSelection(.enabled)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            isActive ? Color.accentColor.opacity(0.1) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .animation(.easeInOut(duration: 0.15), value: isActive)
    }

    private func speakerColor(for label: String) -> Color {
        let hash = abs(label.hashValue)
        return Self.speakerColors[hash % Self.speakerColors.count]
    }
}

// MARK: - Stored Insight Row

struct StoredInsightRow: View {
    let insight: CallInsight
    let onSeek: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: onSeek) {
                Text(insight.formattedCallTime)
                    .font(.caption)
                    .monospacedDigit()
                    .underline()
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Play from this moment")

            Image(systemName: insight.kind.icon)
                .font(.caption)
                .foregroundStyle(insight.kind.color)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(insight.title)
                        .font(.callout.weight(.medium))

                    if insight.kind == .blocker {
                        Label(
                            insight.isHandled ? "Handled" : "Unresolved",
                            systemImage: insight.isHandled ? "checkmark" : "exclamationmark.circle"
                        )
                        .font(.caption2)
                        .foregroundStyle(insight.isHandled ? Color.green : .orange)
                    }
                }

                Text(insight.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                if let source = insight.source {
                    Label(source, systemImage: source == "general knowledge" ? "globe" : "doc.text")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

// MARK: - String Extension

extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
