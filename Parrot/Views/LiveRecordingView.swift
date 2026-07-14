import SwiftUI
import SwiftData

/// Which pane the live side panel shows.
enum LiveSideTab: String {
    case transcript
    case notes
}

/// Live screen v2 — the copilot is the center stage (it's what the user follows
/// mid-call); the transcript lives on the right as a collapsible chat-bubble
/// panel that also hosts per-call Notes.
struct LiveRecordingView: View {
    @Environment(RecordingManager.self) private var recordingManager
    @State private var autoScroll = true
    @State private var showCopilot = true
    @State private var copilotJumpTarget: TimeInterval?
    /// Time-sorted segments for the live list, recomputed only when a new segment
    /// is committed (the count changes) — not on every interim transcript tick —
    /// so the streaming live text doesn't re-sort the whole transcript several
    /// times a second.
    @State private var displayedSegments: [TranscriptSegment] = []
    @AppStorage("copilotEnabled") private var copilotEnabled = false
    @AppStorage("liveSideTab") private var sideTabRaw = LiveSideTab.transcript.rawValue
    @AppStorage("liveSideCollapsed") private var sideCollapsed = false

    private var sideTab: LiveSideTab { LiveSideTab(rawValue: sideTabRaw) ?? .transcript }

    var body: some View {
        VStack(spacing: 0) {
            // Top bar
            recordingHeader

            Divider()

            // Audio waveform
            AudioWaveformView(level: recordingManager.audioCaptureManager.audioLevel)
                .frame(height: 40)
                .padding(.horizontal)

            deviceBar

            Divider()

            // Copilot center stage + collapsible side panel. Drag the divider to
            // resize; without the copilot the side panel takes the whole stage.
            HSplitView {
                if copilotEnabled && showCopilot {
                    CopilotPanelView(transcriptJumpTarget: $copilotJumpTarget)

                    if sideCollapsed {
                        collapsedRail
                    } else {
                        sidePanelBody
                            .frame(minWidth: 300, idealWidth: 380, maxWidth: 560)
                    }
                } else {
                    sidePanelBody
                        .frame(minWidth: 380, maxWidth: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Recording Header

    private var recordingHeader: some View {
        HStack {
            // Recording indicator
            HStack(spacing: 8) {
                Circle()
                    .fill(.red)
                    .frame(width: 10, height: 10)
                    .shadow(color: .red.opacity(0.5), radius: 4)

                Text("Recording")
                    .font(.appHeadline)
                    .foregroundStyle(.red)
            }

            Spacer()

            // Timer
            Text(recordingManager.formattedElapsedTime)
                .font(.appTitle2)
                .monospacedDigit()
                .fontWeight(.medium)

            Spacer()

            // Copilot panel toggle
            if copilotEnabled {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showCopilot.toggle()
                    }
                } label: {
                    Image(systemName: "sparkles")
                        .font(.appHeadline)
                        .foregroundStyle(showCopilot ? .purple : .secondary)
                }
                .buttonStyle(.plain)
                .help(showCopilot ? "Hide Copilot" : "Show Copilot")
                .padding(.trailing, 12)
            }

            // Stop button. Stop drains the transcription backlog (can take a few
            // seconds on a long call), so show that instead of looking hung.
            Button {
                Task {
                    await recordingManager.stopRecording()
                }
            } label: {
                Label(recordingManager.isStopping ? "Finalizing…" : "Stop",
                      systemImage: "stop.circle.fill")
                    .font(.appHeadline)
                    .foregroundStyle(recordingManager.isStopping ? Color.secondary : Color.red)
            }
            .buttonStyle(.plain)
            .disabled(recordingManager.isStopping)
        }
        .padding()
    }

    // MARK: - Device Bar

    /// Shows which input/output devices are in use and a live mic level, so the
    /// user can see whether their own voice is actually being picked up.
    private var deviceBar: some View {
        let cap = recordingManager.audioCaptureManager
        return HStack(spacing: 12) {
            Image(systemName: cap.micActive ? "mic.fill" : "mic.slash.fill")
                .foregroundStyle(cap.micActive ? .blue : .orange)
            Text(cap.inputDeviceName.isEmpty ? "No input" : cap.inputDeviceName)
                .font(.appCaption)
                .lineLimit(1)
            MicLevelView(level: cap.micLevel)
            if !cap.micActive || cap.micSeemsDead {
                Button {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                } label: {
                    Label("not hearing you — enable mic", systemImage: "exclamationmark.triangle.fill")
                        .font(.appCaption2)
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
                .help("Open Microphone privacy settings and enable Parrot")
            }

            if cap.echoCancellerStarved {
                Label("echo cancel inactive", systemImage: "waveform.slash")
                    .font(.appCaption2)
                    .foregroundStyle(.orange)
                    .help("System audio isn't in the expected format, so speaker bleed may transcribe as \"Me\". Headphones avoid this entirely.")
            }

            if let notice = recordingManager.transcriptionEngine.cloudNotice {
                Label(notice, systemImage: "icloud.slash")
                    .font(.appCaption2)
                    .foregroundStyle(.orange)
            }

            Spacer()

            Image(systemName: "speaker.wave.2.fill")
                .foregroundStyle(.secondary)
            Text(cap.outputDeviceName.isEmpty ? "Output" : cap.outputDeviceName)
                .font(.appCaption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal)
        .padding(.vertical, 5)
    }

    // MARK: - Side panel (Transcript | Notes)

    private var sidePanelBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("", selection: Binding(
                    get: { sideTab },
                    set: { sideTabRaw = $0.rawValue }
                )) {
                    Text("Transcript").tag(LiveSideTab.transcript)
                    Text("Notes").tag(LiveSideTab.notes)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { sideCollapsed = true }
                } label: {
                    Image(systemName: "sidebar.right")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Collapse this panel")
            }
            .padding(10)

            Divider()

            switch sideTab {
            case .transcript: transcriptArea
            case .notes: notesArea
            }
        }
        .background(Theme.Colors.panel)
    }

    /// Slim rail shown when the side panel is collapsed — one click reopens
    /// straight to the wanted tab.
    private var collapsedRail: some View {
        VStack(spacing: 16) {
            Button {
                sideTabRaw = LiveSideTab.transcript.rawValue
                withAnimation(.easeInOut(duration: 0.2)) { sideCollapsed = false }
            } label: {
                Image(systemName: "text.bubble")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Show transcript")

            Button {
                sideTabRaw = LiveSideTab.notes.rawValue
                withAnimation(.easeInOut(duration: 0.2)) { sideCollapsed = false }
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Show notes")

            Spacer()
        }
        .padding(.top, 14)
        .frame(width: 44)
        .frame(maxHeight: .infinity)
        .background(Theme.Colors.panel)
    }

    // MARK: - Notes (live)

    @ViewBuilder
    private var notesArea: some View {
        if let meeting = recordingManager.currentMeeting {
            @Bindable var meeting = meeting
            ZStack(alignment: .topLeading) {
                TextEditor(text: $meeting.notes)
                    .font(Theme.Typography.body)
                    .scrollContentBackground(.hidden)
                    .padding(10)

                if meeting.notes.isEmpty {
                    Text("Type notes — saved with this call.")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.ink3)
                        .padding(.top, 18)
                        .padding(.leading, 15)
                        .allowsHitTesting(false)
                }
            }
        } else {
            Spacer()
        }
    }

    // MARK: - Transcript (chat bubbles)

    private var transcriptArea: some View {
        GeometryReader { viewport in
        ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(displayedSegments.enumerated()), id: \.element.id) { index, segment in
                            ChatBubbleRow(
                                segment: segment,
                                isFirstOfGroup: index == 0
                                    || displayedSegments[index - 1].speakerLabel != segment.speakerLabel
                            )
                            .id(segment.id)
                        }

                        // The Granola-style "typing" bubble: shows while speech is
                        // landing — pulsing dots as soon as someone talks, interim
                        // text when the backend streams it (chunked backends like
                        // Groq have no interims, so dots carry the liveness).
                        if !recordingManager.transcriptionEngine.currentText.isEmpty
                            || recordingManager.transcriptionEngine.isHearingSpeech {
                            TypingBubble(text: recordingManager.transcriptionEngine.currentText)
                                .id("currentText")
                                .padding(.top, 8)
                        }

                        if recordingManager.currentMeeting?.segments.isEmpty == true
                            && recordingManager.transcriptionEngine.currentText.isEmpty
                            && !recordingManager.transcriptionEngine.isHearingSpeech {
                            Text("Parrot is listening...")
                                .font(Theme.Typography.body)
                                .foregroundStyle(.tertiary)
                                .italic()
                                .padding(.horizontal)
                                .padding(.top, 20)
                        }

                        // Live-edge sentinel: a stable scroll anchor that also
                        // measures how far below the fold the bottom is, so a
                        // manual scroll-up pauses auto-scroll instead of the view
                        // yanking back down mid-read (CopilotPanelView pattern).
                        Color.clear
                            .frame(height: 1)
                            .id("liveEdge")
                            .background(
                                GeometryReader { geo in
                                    Color.clear.preference(
                                        key: BottomDistancePreferenceKey.self,
                                        value: geo.frame(in: .named("liveTranscript")).minY
                                            - viewport.size.height
                                    )
                                }
                            )
                    }
                    .padding(12)
                }
                // Native chat-style behavior: content stays pinned to the live
                // edge while the user is at the bottom, and holds position when
                // they scroll up. Replaces the per-segment scrollTo, which
                // fought the user's own scrolling (and broke entirely when the
                // window was resized — "can't reach the latest lines").
                .defaultScrollAnchor(.bottom)
                .coordinateSpace(name: "liveTranscript")
                .onPreferenceChange(BottomDistancePreferenceKey.self) { distance in
                    // Drives only the "Resume live" pill now (with hysteresis so
                    // a freshly appended row doesn't flicker it).
                    if distance > 150 {
                        autoScroll = false
                    } else if distance < 60 {
                        autoScroll = true
                    }
                }

                // After jumping to a past moment, offer a way back to the live edge.
                if !autoScroll {
                    Button {
                        autoScroll = true
                        withAnimation(.easeOut(duration: 0.25)) {
                            proxy.scrollTo("liveEdge", anchor: .bottom)
                        }
                    } label: {
                        Label("Resume live", systemImage: "arrow.down.to.line")
                            .font(.appCaption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.ultraThinMaterial, in: Capsule())
                            .overlay(Capsule().strokeBorder(.secondary.opacity(0.3)))
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 10)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .onChange(of: recordingManager.currentMeeting?.segments.count) {
                // A new segment was committed — refresh the cached sorted list
                // (the only place the sort runs now). Scrolling is handled by
                // defaultScrollAnchor(.bottom); no programmatic scroll here.
                displayedSegments = recordingManager.currentMeeting?.sortedSegments ?? []
            }
            .task(id: recordingManager.currentMeeting?.id) {
                // Seed on appear and reseed if the meeting changes (e.g. navigating
                // back into a live recording).
                displayedSegments = recordingManager.currentMeeting?.sortedSegments ?? []
            }
            .onChange(of: copilotJumpTarget) { _, target in
                guard let target,
                      let meeting = recordingManager.currentMeeting else { return }
                // Jumping to the transcript implies wanting to SEE it.
                sideTabRaw = LiveSideTab.transcript.rawValue
                sideCollapsed = false
                // Nearest segment at or before the insight's moment.
                let segment = meeting.sortedSegments.last { $0.startTime <= target }
                    ?? meeting.sortedSegments.first
                if let segment {
                    autoScroll = false
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(segment.id, anchor: .center)
                    }
                }
                copilotJumpTarget = nil
            }
        }
        }
    }
}

/// Distance (pt) between the transcript's live edge and the bottom of the
/// visible viewport. 0-ish = pinned to live.
private struct BottomDistancePreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Chat Bubble Row

/// One transcript segment as an iMessage-style bubble: Them on the left in
/// chip gray, Me on the right in the accent tint. Consecutive same-speaker
/// bubbles group; the label + timestamp show only on the first of a group.
struct ChatBubbleRow: View {
    let segment: TranscriptSegment
    let isFirstOfGroup: Bool

    private var isMe: Bool { segment.speakerLabel == "Me" }

    var body: some View {
        VStack(alignment: isMe ? .trailing : .leading, spacing: 3) {
            if isFirstOfGroup {
                HStack(spacing: 6) {
                    Text(segment.speakerLabel ?? "Speaker")
                        .font(.appCaption.weight(.medium))
                        .foregroundStyle(isMe ? Theme.Colors.accent : Theme.Colors.ink2)
                    Text(segment.formattedTimestamp)
                        .font(.appCaption2)
                        .monospacedDigit()
                        .foregroundStyle(Theme.Colors.ink3)
                }
                .padding(.top, 8)
                .padding(isMe ? .trailing : .leading, 6)
            }

            Text(segment.text)
                .font(Theme.Typography.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(
                    isMe ? Theme.Colors.accent.opacity(0.15) : Theme.Colors.chip,
                    in: RoundedRectangle(cornerRadius: 14)
                )
        }
        .frame(maxWidth: .infinity, alignment: isMe ? .trailing : .leading)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}

// MARK: - Typing Bubble

/// The in-progress transcription: interim text in a soft bubble with three
/// pulsing dots — speech is landing right now.
struct TypingBubble: View {
    let text: String

    var body: some View {
        HStack(alignment: .bottom, spacing: 7) {
            if !text.isEmpty {
                Text(text)
                    .font(Theme.Typography.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TypingDots()
                .padding(.bottom, 4)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(Theme.Colors.chip.opacity(0.7), in: RoundedRectangle(cornerRadius: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Three dots pulsing in a staggered wave.
struct TypingDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Theme.Colors.ink3)
                        .frame(width: 5, height: 5)
                        .opacity(0.3 + 0.7 * (sin(t * 4.2 - Double(i) * 0.9) + 1) / 2)
                }
            }
        }
    }
}

// MARK: - Mic Level Meter

struct MicLevelView: View {
    let level: Float
    private let bars = 10

    var body: some View {
        let active = Int(min(max(level * 25, 0), 1) * Float(bars))
        return HStack(spacing: 2) {
            ForEach(0..<bars, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i < active ? Color.blue : Color.secondary.opacity(0.25))
                    .frame(width: 3, height: 12)
            }
        }
        .animation(.linear(duration: 0.08), value: level)
    }
}

// MARK: - Audio Waveform

struct AudioWaveformView: View {
    let level: Float
    @State private var levels: [Float] = Array(repeating: 0, count: 50)

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<levels.count, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.accentColor.opacity(0.6))
                    .frame(width: 3, height: max(2, CGFloat(levels[index]) * 60))
            }
        }
        .frame(maxWidth: .infinity)
        .onChange(of: level) { _, newValue in
            levels.removeFirst()
            levels.append(newValue)
        }
        .animation(.linear(duration: 0.1), value: levels)
    }
}
