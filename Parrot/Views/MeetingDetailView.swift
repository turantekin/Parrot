import SwiftUI
import AVFoundation

/// Which pane of the post-meeting report is showing.
enum ReportTab: String, CaseIterable, Identifiable {
    case report = "Report"
    case transcript = "Transcript"
    case insights = "Insights"
    case notes = "Notes"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .report: "doc.text"
        case .transcript: "text.bubble"
        case .insights: "sparkles"
        case .notes: "square.and.pencil"
        }
    }
}

struct MeetingDetailView: View {
    let meeting: Meeting
    @Environment(RecordingManager.self) private var recordingManager
    @Environment(\.modelContext) private var modelContext
    @AppStorage("rememberVoices") private var rememberVoices = false
    /// Parent clears the selection and performs the actual delete — this view
    /// must be gone before the model object is.
    var onDelete: (() -> Void)? = nil
    @State private var confirmingDelete = false
    @State private var editingTitle = false
    @State private var titleText = ""
    @State private var audioPlayer: AVAudioPlayer?      // system audio ("Them")
    @State private var micPlayer: AVAudioPlayer?        // mic audio ("Me")
    @State private var isPlaying = false
    @State private var playbackTime: TimeInterval = 0
    @State private var isScrubbing = false              // slider drag in progress
    @State private var playbackSpeed: Float = 1.0
    @State private var playbackTimer: Timer?
    @State private var activeSegmentID: UUID?
    @State private var tab: ReportTab = .report
    @State private var themNameText = ""
    @State private var showCostBreakdown = false
    @State private var cardNamingLabel: String?
    @State private var clipStopTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            meetingHeader

            if meeting.wasRecovered { recoveredBanner }

            Divider()

            // Audio player bar — persists above the tabs (drives transcript +
            // insight seeking). Needs a real audio file: a recovered call whose .caf
            // couldn't be finalized has its path cleared, so hide the dead control.
            if meeting.status == .done || meeting.status == .processing,
               meeting.systemAudioPath.nilIfEmpty != nil {
                audioPlayerBar
                Divider()
            }

            // Above the tabs on purpose: the app opens meetings on the Report
            // tab, and a confirm card hidden behind the Transcript tab was
            // simply never seen (first user test, 2026-08-04).
            if nameVoicesCardVisible {
                nameVoicesCard
                    .padding(.bottom, 4)
            }

            // Tabs — each gets the full pane with a single scroll, instead of the
            // old stack of fixed-height mini-scrollers.
            Picker("View", selection: $tab) {
                ForEach(ReportTab.allCases) { t in
                    Label(t.rawValue, systemImage: t.icon).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 380)
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            Group {
                switch tab {
                case .report: reportTab
                case .transcript: transcriptTab
                case .insights: insightsTab
                case .notes: notesTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.Colors.canvas)
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
                    Button("Export as TXT") { MeetingActions.exportTXT(meeting) }
                    Button("Export as SRT") { MeetingActions.exportSRT(meeting) }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }

                Button(role: .destructive) {
                    confirmingDelete = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .confirmationDialog("Delete this meeting?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { onDelete?() }
        } message: {
            Text("The recording, transcript, and insights will be permanently removed.")
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
                .font(Theme.Typography.title(20))
                .textFieldStyle(.plain)
            } else {
                Text(meeting.title)
                    .font(Theme.Typography.title(20))
                    .foregroundStyle(Theme.Colors.ink)
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
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.Colors.ink2)

            // What the AI cost for this call (estimated); old meetings have no data.
            if let usage = meeting.aiUsage {
                aiCostRow(usage)
            }

            // Name the other party so the transcript/report read naturally.
            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle")
                    .foregroundStyle(Theme.Colors.ink2)
                TextField("Name the other speaker (e.g. Sam)", text: $themNameText) {
                    meeting.themName = themNameText.trimmingCharacters(in: .whitespaces).nilIfEmpty
                }
                .textFieldStyle(.plain)
                .frame(maxWidth: 240)
            }
            .font(Theme.Typography.caption)
        }
        .padding(Theme.Metrics.pad)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One-line estimated AI cost; click for the per-line breakdown.
    private func aiCostRow(_ usage: AIUsage) -> some View {
        Button {
            showCostBreakdown.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "cpu")
                    .foregroundStyle(Theme.Colors.ink2)
                Text("AI cost ~\(AIUsage.formatUSD(usage.totalUSD))")
                    .fontWeight(.medium)
                    .foregroundStyle(Theme.Colors.ink)
                Text(usage.costBreakdown()
                    .map { "\($0.label) \(AIUsage.formatUSD($0.usd))" }
                    .joined(separator: " · "))
                    .foregroundStyle(Theme.Colors.ink2)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.Colors.ink2)
            }
            .font(Theme.Typography.caption)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showCostBreakdown, arrowEdge: .bottom) {
            costBreakdownPopover(usage)
        }
    }

    private func costBreakdownPopover(_ usage: AIUsage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("AI cost breakdown")
                .font(Theme.Typography.sectionLabel)
            ForEach(Array(usage.costBreakdown().enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.label)
                            .font(Theme.Typography.secondary)
                        Text(item.detail)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.ink2)
                    }
                    Spacer(minLength: 24)
                    Text(AIUsage.formatUSD(item.usd))
                        .font(Theme.Typography.mono(11))
                }
            }
            Divider()
            HStack {
                Text("Total").font(Theme.Typography.secondary.weight(.semibold))
                Spacer()
                Text(AIUsage.formatUSD(usage.totalUSD))
                    .font(Theme.Typography.mono(11, .semibold))
            }
            Text("Estimated from provider list prices — not a bill.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.ink2)
        }
        .padding(16)
        .frame(width: 320)
    }

    /// Honest heads-up on a salvaged call: its transcript is intact but the tail
    /// and audio playback may be gone.
    private var recoveredBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.clockwise.circle")
                .font(.appCallout)
            Text("Recovered from an interrupted recording — the last few seconds and audio playback may be missing.")
                .font(Theme.Typography.caption)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.Colors.ink2)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.chip, in: RoundedRectangle(cornerRadius: Theme.Metrics.radius))
        .padding(.horizontal, Theme.Metrics.pad)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch meeting.status {
        case .processing:
            Label("Processing", systemImage: "gearshape.2")
                .foregroundStyle(Theme.Colors.warn)
        case .failed:
            Label("Failed", systemImage: "xmark.circle")
                .foregroundStyle(Theme.Colors.stop)
        default:
            // A recovered call is otherwise `.done`; flag it so it doesn't read as
            // a clean recording.
            if meeting.wasRecovered {
                Label("Recovered", systemImage: "arrow.clockwise.circle")
                    .foregroundStyle(Theme.Colors.ink2)
            } else {
                EmptyView()
            }
        }
    }

    // MARK: - Audio Player

    private var audioPlayerBar: some View {
        HStack(spacing: 12) {
            Button {
                togglePlayback()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.appTitle3)
            }
            .buttonStyle(.plain)

            // Native scrubber — drag anywhere; the seek commits on release using
            // the same call the old tap-to-seek bar used.
            Slider(value: $playbackTime, in: 0...max(meeting.duration, 0.01)) { editing in
                isScrubbing = editing
                if !editing { seekTo(playbackTime) }
            }

            // Time display
            Text("\(formatTime(playbackTime)) / \(formatTime(meeting.duration))")
                .font(Theme.Typography.mono(11))
                .foregroundStyle(Theme.Colors.ink2)
                .frame(width: 100)

            // Speed selector — label hidden: outside a Form, macOS renders it as
            // a squeezed vertical "S p e e d" column; the segments self-describe.
            Picker("Speed", selection: $playbackSpeed) {
                Text("0.5x").tag(Float(0.5))
                Text("1x").tag(Float(1.0))
                Text("1.5x").tag(Float(1.5))
                Text("2x").tag(Float(2.0))
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Playback speed")
            .frame(width: 160)
            .onChange(of: playbackSpeed) { _, newValue in
                audioPlayer?.rate = newValue
                micPlayer?.rate = newValue
            }
        }
        .controlSize(.small)
        .padding(.horizontal, Theme.Metrics.pad)
        .padding(.vertical, 8)
    }

    // MARK: - Report tab (Summary + Coaching)

    private var reportTab: some View {
        ScrollView {
            Group {
                if meeting.summary == nil && meeting.coaching == nil {
                    if meeting.status == .processing {
                        reportGeneratingRow("Writing your report…")
                    } else {
                        emptyTabState("No report was generated for this meeting.")
                    }
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        ReportContentView(
                            summary: meeting.summary,
                            coaching: meeting.coaching,
                            talkPercentMe: talkPercentMe
                        )
                        // Summary is in; the coaching pass is still running.
                        if meeting.status == .processing, meeting.coaching == nil {
                            reportGeneratingRow("Analyzing your coaching report…")
                        }
                    }
                }
            }
            .padding(Theme.Metrics.pad)
            .frame(maxWidth: Theme.Metrics.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Spinner + honest expectation while a report pass runs in the background.
    private func reportGeneratingRow(_ title: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.ink)
                Text("Local models can take a few minutes — it appears here the moment it's ready.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.ink2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.canvas, in: RoundedRectangle(cornerRadius: Theme.Metrics.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.radius).strokeBorder(Theme.Colors.line))
    }

    /// Me's share of the words, for the talk-balance bar.
    private var talkPercentMe: Int? {
        let me = meeting.segments
            .filter { $0.speakerLabel == "Me" }
            .reduce(0) { $0 + $1.text.split(separator: " ").count }
        let total = meeting.segments.reduce(0) { $0 + $1.text.split(separator: " ").count }
        return total > 0 ? Int(Double(me) / Double(total) * 100) : nil
    }

    // MARK: - Transcript tab

    private var transcriptTab: some View {
        VStack(spacing: 0) {
            if meeting.status == .processing {
                processingView
                Divider()
            }
            if !nameVoicesCardVisible, meeting.status == .done,
               meeting.systemAudioPath.nilIfEmpty != nil {
                // Re-run on-device speaker detection — fixes old meetings
                // recorded before real diarization, and bad splits after
                // threshold tuning. Lives inside the card when it's shown.
                HStack {
                    Spacer()
                    detectSpeakersButton
                }
                .font(Theme.Typography.caption)
                .padding(.horizontal, Theme.Metrics.pad)
                .padding(.top, 8)
            }
            transcriptList
        }
    }

    // MARK: - Insights tab

    private var insightsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if meeting.insights.isEmpty {
                    emptyTabState("No copilot insights were captured on this call.")
                } else {
                    ForEach(meeting.sortedInsights) { insight in
                        StoredInsightRow(
                            insight: insight,
                            kindStyle: KindResolver.style(
                                forKey: insight.kindRaw,
                                profile: meeting.profile,
                                snapshot: meeting.snapshotKinds
                            )
                        ) {
                            seekTo(insight.callTime)
                        }
                    }
                }
            }
            .padding(Theme.Metrics.pad)
            .frame(maxWidth: Theme.Metrics.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Notes tab

    private var notesTab: some View {
        @Bindable var meeting = meeting
        return ZStack(alignment: .topLeading) {
            TextEditor(text: $meeting.notes)
                .font(Theme.Typography.body)
                .scrollContentBackground(.hidden)
                .padding(Theme.Metrics.pad)

            if meeting.notes.isEmpty {
                // Offsets track the editor inset plus TextEditor's intrinsic
                // text-container inset (~8pt top, ~6pt leading) so the
                // placeholder sits exactly where typed text starts.
                Text("Notes for this call — type anything worth keeping.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.ink3)
                    .padding(.top, Theme.Metrics.pad + 8)
                    .padding(.leading, Theme.Metrics.pad + 6)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: Theme.Metrics.contentMaxWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func emptyTabState(_ message: String) -> some View {
        Text(message)
            .font(Theme.Typography.body)
            .foregroundStyle(Theme.Colors.ink2)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 40)
    }

    // MARK: - Processing View

    private var processingView: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Identifying speakers...")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.ink2)
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
                        themName: meeting.themName,
                        meeting: meeting,
                        playClip: playClip,
                        onReassign: { segment.speakerLabel = $0 }
                    )
                    .onTapGesture {
                        seekTo(segment.startTime)
                    }
                }
            }
            .padding(Theme.Metrics.pad)
        }
    }

    /// The confirm-first step needs the user's action, so the card has to be
    /// unmissable: accent border + tint, and it stays until every voice is
    /// named (listing only the ones still unnamed) or it's dismissed.
    private var unnamedSpeakerLabels: [String] {
        meeting.otherSpeakerLabels.filter { meeting.speakerNames[$0] == nil }
    }

    private var nameVoicesCardVisible: Bool {
        meeting.status == .done && meeting.otherSpeakerLabels.count >= 2
            && !unnamedSpeakerLabels.isEmpty && !meeting.speakerPromptDismissed
    }

    private var detectSpeakersButton: some View {
        Button {
            Task { await recordingManager.redetectSpeakers(meeting: meeting) }
        } label: {
            Label(recordingManager.diarizationEngine.isProcessing
                  ? "Detecting speakers…" : "Detect speakers",
                  systemImage: "person.2.wave.2")
        }
        .disabled(recordingManager.diarizationEngine.isProcessing)
        .help("Figure out who said what, on this Mac. Downloads a 13 MB model on first use.")
    }

    private var nameVoicesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "person.wave.2.fill")
                    .foregroundStyle(Theme.Colors.accent)
                Text("Heard \(meeting.otherSpeakerLabels.count) people besides you — listen and name them")
                    .font(Theme.Typography.body)
                    .fontWeight(.semibold)
                Spacer()
                detectSpeakersButton
                    .font(Theme.Typography.caption)
                Button {
                    meeting.speakerPromptDismissed = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.Colors.ink2)
                }
                .buttonStyle(.plain)
                .help("Keep the neutral labels")
            }
            ForEach(unnamedSpeakerLabels, id: \.self) { label in
                HStack(spacing: 10) {
                    Circle()
                        .fill(TranscriptSegmentRow.speakerColors[label.stableHash % TranscriptSegmentRow.speakerColors.count])
                        .frame(width: 8, height: 8)
                    Text(label)
                        .font(Theme.Typography.caption)
                        .fontWeight(.medium)
                        .frame(width: 70, alignment: .leading)
                    if rememberVoices,
                       let embedding = meeting.speakerEmbeddings[label],
                       let match = SpeakerProfileStore.match(embedding, in: modelContext) {
                        Text("sounds like \(match.name)?")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.accent)
                    }
                    if let clip = meeting.longestSegments(for: label, count: 1).first {
                        Button {
                            playClip(start: clip.startTime, end: min(clip.endTime, clip.startTime + 8))
                        } label: {
                            Label("Play", systemImage: "play.fill")
                                .font(Theme.Typography.caption)
                        }
                    }
                    Button("Name…") { cardNamingLabel = label }
                        .font(Theme.Typography.caption)
                        .popover(isPresented: Binding(
                            get: { cardNamingLabel == label },
                            set: { if !$0 { cardNamingLabel = nil } }
                        ), arrowEdge: .bottom) {
                            SpeakerNamePopover(meeting: meeting, label: label, playClip: playClip)
                        }
                    Spacer()
                }
            }
        }
        .padding(12)
        .background(Theme.Colors.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.Metrics.radius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Metrics.radius)
                .strokeBorder(Theme.Colors.accent.opacity(0.4))
        )
        .padding(.horizontal, Theme.Metrics.pad)
        .padding(.top, 8)
    }

    /// Plays just this stretch of the recording — how the naming UI lets the
    /// user hear a voice before deciding who it is.
    private func playClip(start: TimeInterval, end: TimeInterval) {
        clipStopTask?.cancel()
        seekTo(start)
        if !isPlaying { togglePlayback() }
        clipStopTask = Task {
            try? await Task.sleep(for: .seconds(max(1, end - start)))
            guard !Task.isCancelled else { return }
            if isPlaying { togglePlayback() }
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
                // Don't fight the user's drag — the slider owns playbackTime
                // until the scrub commits.
                if isScrubbing { return }
                // AVAudioPlayer goes silent at end-of-track without a callback
                // here — detect it, or the timer runs forever and the button
                // stays stuck on pause.
                if audioPlayer?.isPlaying != true && micPlayer?.isPlaying != true {
                    stopPlayback()
                    playbackTime = 0
                    updateActiveSegment()
                    return
                }
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
        // Clamp the UI too: an insight callTime past the audio's end must not
        // draw a >100% progress bar.
        let duration = max(audioPlayer?.duration ?? 0, micPlayer?.duration ?? 0)
        playbackTime = duration > 0 ? min(time, duration) : time
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

}

/// The confirm-first naming popover: play short clips of the voice, then type
/// who it is. Renaming applies to every line from that voice; a wrong grouping
/// becomes audible the moment a clip plays.
struct SpeakerNamePopover: View {
    let meeting: Meeting
    let label: String
    /// Nil during a live recording: playing clips mid-call would bleed into
    /// the capture, and the user is hearing the voice anyway.
    var playClip: ((_ start: TimeInterval, _ end: TimeInterval) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @AppStorage("rememberVoices") private var rememberVoices = false
    @State private var name = ""

    /// "Sounds like X" from remembered voices — suggestion only, the click
    /// below is the confirmation (confirm-first rule).
    private var suggestion: (name: String, similarity: Float)? {
        guard rememberVoices, meeting.speakerNames[label] == nil,
              let embedding = meeting.speakerEmbeddings[label], !embedding.isEmpty
        else { return nil }
        return SpeakerProfileStore.match(embedding, in: modelContext)
    }

    private func assign(_ finalName: String) {
        var names = meeting.speakerNames
        names[label] = finalName.nilIfEmpty
        meeting.speakerNames = names
        if rememberVoices, let finalName = finalName.nilIfEmpty,
           let embedding = meeting.speakerEmbeddings[label] {
            SpeakerProfileStore.remember(name: finalName, embedding: embedding, in: modelContext)
        }
        dismiss()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Who is this?")
                .font(Theme.Typography.caption)
                .fontWeight(.semibold)
            Text(playClip != nil
                 ? "Listen to a couple of moments from this voice."
                 : "You're hearing them live — type who it is.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.ink2)

            if let suggestion {
                Button {
                    assign(suggestion.name)
                } label: {
                    Label("Sounds like \(suggestion.name) — confirm",
                          systemImage: "person.crop.circle.badge.checkmark")
                        .font(Theme.Typography.caption)
                        .fontWeight(.medium)
                }
                .tint(Theme.Colors.accent)
            }

            ForEach(playClip == nil ? [] : meeting.longestSegments(for: label), id: \.id) { clip in
                Button {
                    playClip?(clip.startTime, min(clip.endTime, clip.startTime + 8))
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                        Text("“\(String(clip.text.prefix(40)))…”")
                            .lineLimit(1)
                        Spacer()
                        Text("\(clip.formattedTimestamp) · \(Int(min(clip.endTime - clip.startTime, 8)))s")
                            .foregroundStyle(Theme.Colors.ink2)
                    }
                    .font(Theme.Typography.caption)
                }
                .buttonStyle(.plain)
                .padding(6)
                .background(Theme.Colors.chip.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            }

            TextField("Type a name — e.g. Gürkan", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    assign(name.trimmingCharacters(in: .whitespaces))
                }

            Text("Renames every line from this voice. A single wrong line can be moved from the line’s right-click menu.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(width: 300)
        .onAppear { name = meeting.speakerNames[label] ?? "" }
    }
}

// MARK: - Transcript Segment Row

struct TranscriptSegmentRow: View {
    let segment: TranscriptSegment
    let isActive: Bool
    var themName: String? = nil
    /// Set for finished meetings: resolves per-speaker names and enables the
    /// naming chip + reassign menu. Nil keeps the row read-only (snapshots).
    var meeting: Meeting? = nil
    var playClip: ((TimeInterval, TimeInterval) -> Void)? = nil
    var onReassign: ((String) -> Void)? = nil
    @State private var naming = false

    /// Muted adaptive palette for the other side of the call — "Me" is always
    /// the accent, so these stay deliberately quiet.
    static let speakerColors: [Color] = [
        Color(lightHex: 0x6A8CAF, darkHex: 0x7FA4C6),
        Color(lightHex: 0x7A9A7A, darkHex: 0x93B593),
        Color(lightHex: 0x9A7AA0, darkHex: 0xB694BC)
    ]

    /// Resolved speaker name; the meeting's per-speaker names win, otherwise
    /// legacy themName behavior.
    private var displayLabel: String? {
        guard let label = segment.speakerLabel else { return nil }
        if let meeting { return meeting.displayName(forSpeaker: label) }
        if label == "Me" { return "Me" }
        return themName ?? label
    }

    private var isMe: Bool { segment.speakerLabel == "Me" }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Timestamp
            Text(segment.formattedTimestamp)
                .font(Theme.Typography.mono(11))
                .foregroundStyle(Theme.Colors.ink2)
                .frame(width: 40, alignment: .trailing)

            // Speaker chip — click to hear this voice and name it. The popover
            // anchors to this chip, right where the user clicked.
            if let speaker = displayLabel {
                if let meeting, let playClip, !isMe {
                    Button { naming = true } label: {
                        Text(speaker)
                            .font(Theme.Typography.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(speakerColor(for: segment.speakerLabel ?? speaker))
                            .underline(segment.speakerLabel.map { meeting.speakerNames[$0] == nil } ?? false,
                                       pattern: .dot)
                            .frame(width: 70, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .help("Hear this voice and give it a name")
                    .popover(isPresented: $naming, arrowEdge: .bottom) {
                        if let label = segment.speakerLabel {
                            SpeakerNamePopover(meeting: meeting, label: label, playClip: playClip)
                        }
                    }
                } else {
                    Text(speaker)
                        .font(Theme.Typography.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(speakerColor(for: segment.speakerLabel ?? speaker))
                        .frame(width: 70, alignment: .leading)
                }
            }

            // Text
            Text(segment.text)
                .font(Theme.Typography.body)
                .textSelection(.enabled)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            isActive ? Theme.Colors.accent.opacity(0.12) : Color.clear,
            in: RoundedRectangle(cornerRadius: Theme.Metrics.radius)
        )
        .animation(.easeInOut(duration: 0.15), value: isActive)
        .contextMenu {
            // Fix a single misattributed line without touching the rest.
            if let meeting, let onReassign, !isMe {
                Menu("This line is") {
                    Button("Me") { onReassign("Me") }
                    ForEach(meeting.otherSpeakerLabels, id: \.self) { label in
                        if label != segment.speakerLabel {
                            Button(meeting.displayName(forSpeaker: label)) { onReassign(label) }
                        }
                    }
                }
            }
        }
    }

    private func speakerColor(for label: String) -> Color {
        label == "Me"
            ? Theme.Colors.accent
            : Self.speakerColors[label.stableHash % Self.speakerColors.count]
    }
}

// MARK: - Stored Insight Row

struct StoredInsightRow: View {
    let insight: CallInsight
    /// Resolved visual style — caller supplies via KindResolver so the row is profile-aware.
    let kindStyle: KindStyle
    let onSeek: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: onSeek) {
                Text(insight.formattedCallTime)
                    .font(Theme.Typography.mono(11))
                    .underline()
                    .foregroundStyle(Theme.Colors.ink2)
            }
            .buttonStyle(.plain)
            .help("Play from this moment")

            Image(systemName: kindStyle.iconSystemName)
                .font(.appCaption)
                .foregroundStyle(kindStyle.color)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(insight.title)
                        .font(Theme.Typography.cardTitle)

                    if kindStyle.isPinned {
                        Label(
                            insight.isHandled ? "Handled" : "Unresolved",
                            systemImage: insight.isHandled ? "checkmark" : "exclamationmark.circle"
                        )
                        .font(.appCaption2)
                        .foregroundStyle(insight.isHandled ? Theme.Colors.good : Theme.Colors.warn)
                    }
                }

                Text(insight.detail)
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Colors.ink2)
                    .textSelection(.enabled)

                if let reply = insight.reply {
                    (Text("Try: ") + Text("“\(reply)”"))
                        .font(Theme.Typography.secondary)
                        .foregroundStyle(Theme.Colors.action)
                        .textSelection(.enabled)
                }

                if let source = insight.source {
                    Label(source, systemImage: source == "general knowledge" ? "globe" : "doc.text")
                        .font(.appCaption2)
                        .foregroundStyle(Theme.Colors.ink3)
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

    /// Deterministic non-negative hash. `hashValue` is per-process seeded, so
    /// hash-derived UI colors would reshuffle on every launch (and abs(Int.min)
    /// traps). Used for stable speaker/sidebar colors.
    var stableHash: Int {
        unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7FFF_FFFF }
    }
}
