import SwiftUI
import SwiftData

/// Which pane the live side panel shows.
enum LiveSideTab: String {
    case transcript
    case translation
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
    @AppStorage(FeatureProcessing.translationEnabledKey) private var translationEnabled = false

    private var translationActive: Bool {
        recordingManager.translationSession || translationEnabled
    }

    private var sideTab: LiveSideTab {
        let tab = LiveSideTab(rawValue: sideTabRaw) ?? .transcript
        if tab == .translation && !translationActive { return .transcript }
        return tab
    }

    private var translationToggleVisible: Bool { true }

    var body: some View {
        VStack(spacing: 0) {
            // Top bar
            recordingHeader

            Divider()

            // Audio waveform
            AudioWaveformView(level: recordingManager.audioCaptureManager.audioLevel)
                .frame(height: 40)
                .padding(.horizontal, Theme.Metrics.pad)

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
        .onChange(of: recordingManager.currentMeeting?.segments.count) {
            displayedSegments = recordingManager.currentMeeting?.sortedSegments ?? []
        }
        .task(id: recordingManager.currentMeeting?.id) {
            displayedSegments = recordingManager.currentMeeting?.sortedSegments ?? []
        }
        .onChange(of: recordingManager.translationSession) { _, session in
            if session { sideTabRaw = LiveSideTab.translation.rawValue }
        }
    }

    // MARK: - Recording Header

    private var recordingHeader: some View {
        HStack {
            // Recording indicator
            HStack(spacing: 8) {
                Circle()
                    .fill(Theme.Colors.stop)
                    .frame(width: 10, height: 10)

                Text(recordingManager.translationSession ? "Translating" : "Recording")
                    .font(.appHeadline)
                    .foregroundStyle(Theme.Colors.stop)
            }

            Spacer()

            // Timer
            Text(recordingManager.formattedElapsedTime)
                .font(Theme.Typography.mono(15, .medium))

            Spacer()

            // Copilot panel toggle
            if translationActive {
                Picker("Into", selection: Binding(
                    get: { recordingManager.translationStore.targetCode },
                    set: { recordingManager.setTranslationTarget($0, segments: displayedSegments) }
                )) {
                    ForEach(TranslationLanguage.allCases) { language in
                        Text(language.label).tag(language.rawValue)
                    }
                }
                .labelsHidden()
                .frame(width: 120)
                .help("The Translation tab shows every line in this language.")
            }

            if translationToggleVisible && !recordingManager.translationSession {
                Toggle("Translate", isOn: Binding(
                    get: { translationEnabled },
                    set: { on in
                        translationEnabled = on
                        if on {
                            sideTabRaw = LiveSideTab.translation.rawValue
                        } else if sideTabRaw == LiveSideTab.translation.rawValue {
                            sideTabRaw = LiveSideTab.transcript.rawValue
                        }
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help("Open a Translation tab next to Transcript. Spoken lines stay on Transcript.")
            }

            if copilotEnabled {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showCopilot.toggle()
                    }
                } label: {
                    Image(systemName: "sparkles")
                        .font(.appHeadline)
                        .foregroundStyle(showCopilot ? Theme.Colors.accent : Theme.Colors.ink2)
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
                    .foregroundStyle(recordingManager.isStopping ? Theme.Colors.ink2 : Theme.Colors.stop)
            }
            .buttonStyle(.plain)
            .disabled(recordingManager.isStopping)
        }
        .padding(.horizontal, Theme.Metrics.pad)
        .padding(.vertical, 12)
        .modifier(LiveTranslationHost(
            store: recordingManager.translationStore,
            segments: displayedSegments,
            active: translationActive))
    }

    // MARK: - Device Bar

    /// Shows which input/output devices are in use and a live mic level, so the
    /// user can see whether their own voice is actually being picked up.
    private var deviceBar: some View {
        let cap = recordingManager.audioCaptureManager
        return HStack(spacing: 12) {
            Image(systemName: cap.micActive ? "mic.fill" : "mic.slash.fill")
                .foregroundStyle(cap.micActive ? Theme.Colors.good : Theme.Colors.warn)
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
                        .foregroundStyle(Theme.Colors.warn)
                }
                .buttonStyle(.plain)
                .help("Open Microphone privacy settings and enable Parrot")
            }

            if cap.micVeryQuiet {
                Button {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!)
                } label: {
                    Label("mic is very quiet — raise input volume", systemImage: "mic.and.signal.meter")
                        .font(.appCaption2)
                        .foregroundStyle(Theme.Colors.warn)
                }
                .buttonStyle(.plain)
                .help("Your voice reaches Parrot far below normal speech level — usually a low input volume in System Settings → Sound. Transcription still works, but accuracy improves with more signal.")
            }

            if cap.micSignalLost {
                Label("mic muted by another app — reclaiming", systemImage: "mic.slash.circle.fill")
                    .font(.appCaption2)
                    .foregroundStyle(Theme.Colors.warn)
                    .help("macOS is delivering pure silence from the microphone — usually a call app (browser meeting, Zoom) holding it. Parrot retries automatically and recovers the moment the mic frees up. Everyone else's audio keeps recording meanwhile.")
            }

            if cap.echoCancellerStarved {
                Label("echo cancel inactive", systemImage: "waveform.slash")
                    .font(.appCaption2)
                    .foregroundStyle(Theme.Colors.warn)
                    .help("System audio isn't in the expected format, so speaker bleed may transcribe as \"Me\". Headphones avoid this entirely.")
            }

            if let notice = recordingManager.transcriptionEngine.cloudNotice {
                Label(notice, systemImage: "icloud.slash")
                    .font(.appCaption2)
                    .foregroundStyle(Theme.Colors.warn)
            }
            if let notice = recordingManager.translationStore.notice {
                Label(notice, systemImage: "globe")
                    .font(.appCaption2)
                    .foregroundStyle(Theme.Colors.warn)
            }
            if let notice = recordingManager.hybridRefiner.notice {
                Label(notice, systemImage: "sparkles")
                    .font(.appCaption2)
                    .foregroundStyle(Theme.Colors.warn)
            }
            if let notice = recordingManager.persistenceNotice {
                Label(notice, systemImage: "externaldrive.badge.xmark")
                    .font(.appCaption2)
                    .foregroundStyle(Theme.Colors.warn)
            }

            Spacer()

            Image(systemName: "speaker.wave.2.fill")
                .foregroundStyle(Theme.Colors.ink2)
            Text(cap.outputDeviceName.isEmpty ? "Output" : cap.outputDeviceName)
                .font(.appCaption)
                .foregroundStyle(Theme.Colors.ink2)
                .lineLimit(1)
        }
        .padding(.horizontal, Theme.Metrics.pad)
        .padding(.vertical, 4)
    }

    // MARK: - Side panel (Transcript | Translation | Notes)

    private var sidePanelBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("", selection: Binding(
                    get: { sideTab },
                    set: { sideTabRaw = $0.rawValue }
                )) {
                    Text("Transcript").tag(LiveSideTab.transcript)
                    if translationActive {
                        Text("Translation").tag(LiveSideTab.translation)
                    }
                    Text("Notes").tag(LiveSideTab.notes)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { sideCollapsed = true }
                } label: {
                    Image(systemName: "sidebar.right")
                        .foregroundStyle(Theme.Colors.ink2)
                }
                .buttonStyle(.plain)
                .help("Collapse this panel")
            }
            .padding(8)

            Divider()

            switch sideTab {
            case .transcript: bubbleArea(mode: .spoken)
            case .translation: bubbleArea(mode: .translated)
            case .notes: notesArea
            }
        }
        .background(Theme.Colors.panel)
        .onChange(of: copilotJumpTarget) { _, target in
            guard target != nil else { return }
            sideTabRaw = LiveSideTab.transcript.rawValue
            sideCollapsed = false
        }
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
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.Colors.ink2)
            }
            .buttonStyle(.plain)
            .help("Show transcript")

            if translationActive {
                Button {
                    sideTabRaw = LiveSideTab.translation.rawValue
                    withAnimation(.easeInOut(duration: 0.2)) { sideCollapsed = false }
                } label: {
                    Image(systemName: "globe")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.Colors.ink2)
                }
                .buttonStyle(.plain)
                .help("Show translation")
            }

            Button {
                sideTabRaw = LiveSideTab.notes.rawValue
                withAnimation(.easeInOut(duration: 0.2)) { sideCollapsed = false }
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.Colors.ink2)
            }
            .buttonStyle(.plain)
            .help("Show notes")

            Spacer()
        }
        .padding(.top, 12)
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
                    .padding(12)

                if meeting.notes.isEmpty {
                    Text("Type notes — saved with this call.")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.ink3)
                        .padding(.top, 20)
                        .padding(.leading, 16)
                        .allowsHitTesting(false)
                }
            }
        } else {
            Spacer()
        }
    }

    // MARK: - Transcript / Translation (chat bubbles)

    private enum LiveBubbleMode {
        case spoken
        case translated
    }

    private func bubbleArea(mode: LiveBubbleMode) -> some View {
        GeometryReader { viewport in
        ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(displayedSegments.enumerated()), id: \.element.id) { index, segment in
                            ChatBubbleRow(
                                segment: segment,
                                isFirstOfGroup: index == 0
                                    || displayedSegments[index - 1].speakerLabel != segment.speakerLabel,
                                translation: mode == .translated
                                    ? recordingManager.translationStore.lines[segment.id]
                                    : nil,
                                showTranslation: mode == .translated
                            )
                            .id(segment.id)
                        }

                        // Spoken tab: interim text + dots. Translation tab: dots
                        // only — interims are not translated until the line commits.
                        if recordingManager.transcriptionEngine.isHearingSpeech
                            || (mode == .spoken
                                && !recordingManager.transcriptionEngine.currentText.isEmpty) {
                            TypingBubble(
                                text: mode == .spoken
                                    ? recordingManager.transcriptionEngine.currentText
                                    : "",
                                speaker: recordingManager.transcriptionEngine.currentSpeaker)
                                .id("currentText")
                                .padding(.top, 8)
                        }

                        if displayedSegments.isEmpty
                            && recordingManager.transcriptionEngine.currentText.isEmpty
                            && !recordingManager.transcriptionEngine.isHearingSpeech {
                            Text(mode == .translated
                                 ? "Translations appear as speech is committed."
                                 : "Parrot is listening...")
                                .font(Theme.Typography.body)
                                .foregroundStyle(Theme.Colors.ink3)
                                .italic()
                                .padding(.horizontal)
                                .padding(.top, 20)
                        }

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
                .defaultScrollAnchor(.bottom)
                .coordinateSpace(name: "liveTranscript")
                .onPreferenceChange(BottomDistancePreferenceKey.self) { distance in
                    if distance > 150 {
                        autoScroll = false
                    } else if distance < 60 {
                        autoScroll = true
                    }
                }

                if !autoScroll {
                    Button {
                        autoScroll = true
                        withAnimation(.easeOut(duration: 0.25)) {
                            proxy.scrollTo("liveEdge", anchor: .bottom)
                        }
                    } label: {
                        Label("Resume live", systemImage: "arrow.down.to.line")
                            .font(Theme.Typography.caption.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                            .background(.ultraThinMaterial, in: Capsule())
                            .overlay(Capsule().strokeBorder(Theme.Colors.line))
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .onAppear { jumpIfNeeded(proxy: proxy, mode: mode) }
            .onChange(of: copilotJumpTarget) { _, _ in
                jumpIfNeeded(proxy: proxy, mode: mode)
            }
        }
        }
    }

    private func jumpIfNeeded(proxy: ScrollViewProxy, mode: LiveBubbleMode) {
        guard mode == .spoken,
              let target = copilotJumpTarget,
              let meeting = recordingManager.currentMeeting else { return }
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
    var translation: String? = nil
    var showTranslation: Bool = false

    private var isMe: Bool { segment.speakerLabel == "Me" }

    var body: some View {
        VStack(alignment: isMe ? .trailing : .leading, spacing: 3) {
            if isFirstOfGroup {
                HStack(spacing: 6) {
                    Text(segment.speakerLabel ?? "Speaker")
                        .font(.appCaption.weight(.medium))
                        .foregroundStyle(isMe ? Theme.Colors.accent : Theme.Colors.ink2)
                    Text(segment.formattedTimestamp)
                        .font(Theme.Typography.mono(11))
                        .foregroundStyle(Theme.Colors.ink3)
                }
                .padding(.top, 8)
                .padding(isMe ? .trailing : .leading, 6)
            }

            VStack(alignment: isMe ? .trailing : .leading, spacing: 4) {
                if showTranslation {
                    if let translation, !translation.isEmpty {
                        Text(translation)
                            .font(Theme.Typography.body)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Translating…")
                            .font(Theme.Typography.body)
                            .italic()
                            .foregroundStyle(Theme.Colors.ink3)
                    }
                } else {
                    Text(segment.text)
                        .font(Theme.Typography.body)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                isMe ? Theme.Colors.accent.opacity(0.12) : Theme.Colors.chip,
                in: RoundedRectangle(cornerRadius: Theme.Metrics.radius)
            )
        }
        .frame(maxWidth: .infinity, alignment: isMe ? .trailing : .leading)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}

// MARK: - Typing Bubble

/// The in-progress transcription: interim text in a soft bubble with three
/// pulsing dots — speech is landing right now. Hangs under whichever speaker
/// the preview came from (Me right in a faint accent wash, Them left in
/// dimmed chip gray — the committed bubbles' sides, at lower opacity), and is
/// replaced by the real bubble when the segment commits.
struct TypingBubble: View {
    let text: String
    var speaker: AudioSource?

    private var isMe: Bool { speaker == .me }

    var body: some View {
        HStack(alignment: .bottom, spacing: 7) {
            if !text.isEmpty {
                Text(text)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TypingDots()
                .padding(.bottom, 4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            isMe ? Theme.Colors.accent.opacity(0.07) : Theme.Colors.chip.opacity(0.7),
            in: RoundedRectangle(cornerRadius: Theme.Metrics.radius)
        )
        .frame(maxWidth: .infinity, alignment: isMe ? .trailing : .leading)
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
                    .fill(i < active ? Theme.Colors.accent : Theme.Colors.chip)
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
                    .fill(Theme.Colors.accent.opacity(0.6))
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
