import SwiftUI
import AppKit
import SwiftData
import WhisperKit
import FluidAudio
import AVFoundation

/// Dev-only: transcribes a real audio file with the production decoding options to
/// verify the output is clean (no "<|...|>" tokens, no repetition loops) without
/// having to record live. Run with:
///   Parrot --transcribe-test <audio.caf> <modelFolder>
/// `--diarize-test <audio>`: run real diarization on a file and print the
/// clusters. Downloads models on first use (network); deliberately NOT part
/// of `make test`, which must stay offline.
enum DiarizeTest {
    static func run(audioPath: String) {
        let sem = DispatchSemaphore(value: 0)
        Task {
            do {
                let engine = DiarizationEngine()
                let output = try await engine.diarize(audioURL: URL(fileURLWithPath: audioPath))
                var totals: [String: TimeInterval] = [:]
                for segment in output.segments {
                    totals[segment.speakerLabel, default: 0] += segment.endTime - segment.startTime
                }
                for (label, seconds) in totals.sorted(by: { $0.value > $1.value }) {
                    print("\(label): \(Int(seconds))s speech, embedding \(output.embeddings[label]?.count ?? 0) dims")
                }
                print(totals.count >= 2
                      ? "DIARIZE OK — \(totals.count) speakers"
                      : "DIARIZE WEAK — \(totals.count) speaker(s)")
                exit(totals.isEmpty ? 1 : 0)
            } catch {
                print("DIARIZE FAIL: \(error)")
                exit(1)
            }
        }
        sem.wait()
    }
}

enum TranscribeTest {
    static func run(audioPath: String, modelFolder: String) {
        let sem = DispatchSemaphore(value: 0)
        Task {
            do {
                let config = WhisperKitConfig(
                    modelFolder: modelFolder.isEmpty ? nil : modelFolder,
                    verbose: false,
                    logLevel: .none,
                    load: true,
                    download: modelFolder.isEmpty
                )
                let whisperKit = try await WhisperKit(config)

                var opts = DecodingOptions(task: .transcribe, language: "en")
                opts.skipSpecialTokens = true
                opts.withoutTimestamps = true
                opts.compressionRatioThreshold = 2.4
                opts.logProbThreshold = -1.0
                opts.noSpeechThreshold = 0.6
                opts.temperatureFallbackCount = 3

                let results = try await whisperKit.transcribe(audioPath: audioPath, decodeOptions: opts)
                let text = results.map(\.text).joined(separator: " ")
                let hasTokens = text.contains("<|")
                print("=== transcribe-test ===")
                print("chars: \(text.count) | contains '<|' tokens: \(hasTokens)")
                print("---")
                print(String(text.prefix(1800)))
                print("---")
            } catch {
                print("transcribe-test error: \(error)")
            }
            sem.signal()
        }
        sem.wait()
        exit(0)
    }
}

/// `--capture-test [seconds]`: real end-to-end system-audio capture through the
/// production AudioCaptureManager (process tap on macOS 15+, ScreenCaptureKit on
/// 14.x / as rescue), while the caller plays audio through the speakers, e.g.:
///   (sleep 2; say "capture test") & dist/Parrot.app/Contents/MacOS/Parrot --capture-test 8
/// Prints backend, live buffer stats, and the finalized .caf's measured signal;
/// exits 0 iff real system audio landed in the file. Run it from the signed
/// .app bundle — TCC decides by bundle identity. Uses a pumped main run loop,
/// not the semaphore pattern: startCapture is @MainActor and the level/rescue
/// hops dispatch to main, so a blocked main thread would deadlock them.
enum CaptureTest {
    /// Cross-queue tallies from the onAudioBuffer callback (audio queues).
    private final class BufferCounter: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var systemBuffers = 0
        private(set) var micBuffers = 0
        private(set) var systemPeak: Float = 0
        private(set) var micPeak: Float = 0

        func record(buffer: AVAudioPCMBuffer, source: AudioSource) {
            var peak: Float = 0
            if let ch = buffer.floatChannelData?[0] {
                for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(ch[i])) }
            }
            lock.lock()
            defer { lock.unlock() }
            if source == .them {
                systemBuffers += 1
                systemPeak = max(systemPeak, peak)
            } else {
                micBuffers += 1
                micPeak = max(micPeak, peak)
            }
        }

        func snapshot() -> (systemBuffers: Int, systemPeak: Float, micBuffers: Int, micPeak: Float) {
            lock.lock()
            defer { lock.unlock() }
            return (systemBuffers, systemPeak, micBuffers, micPeak)
        }
    }

    static func run(seconds: Double) {
        Task { @MainActor in
            await runCapture(seconds: seconds)
        }
        RunLoop.main.run()
    }

    @MainActor
    private static func runCapture(seconds: Double) async {
        print("=== capture-test — macOS \(ProcessInfo.processInfo.operatingSystemVersionString) ===")
        let manager = AudioCaptureManager()
        let counter = BufferCounter()
        manager.onAudioBuffer = { buffer, source in
            counter.record(buffer: buffer, source: source)
        }
        do {
            try await manager.startCapture()
        } catch {
            print("capture-test: startCapture FAILED — \(error.localizedDescription)")
            exit(2)
        }
        print("backend: \(manager.captureBackend.rawValue) | input: \(manager.inputDeviceName) | output: \(manager.outputDeviceName)")
        print("screen-recording preflight (SCK fallback available): \(CGPreflightScreenCaptureAccess())")

        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))

        let endBackend = manager.captureBackend  // stopCapture resets it
        let systemURL = manager.systemAudioURL
        let micURL = manager.micAudioURL
        await manager.stopCapture()

        let stats = counter.snapshot()
        print(String(format: "live buffers — system: %d (peak %.4f) | mic: %d (peak %.4f)",
                     stats.systemBuffers, stats.systemPeak, stats.micBuffers, stats.micPeak))
        print("backend at end: \(endBackend.rawValue) | tap grant proven: \(UserDefaults.standard.bool(forKey: PermissionFlow.tapProvenKey))")

        let systemStats = fileStats(systemURL)
        print("system .caf: \(systemStats.text)")
        print("mic .caf: \(fileStats(micURL).text)")

        let pass = systemStats.peak > 0.01
        print(pass ? "CAPTURE OK — real system audio in the file"
                   : "CAPTURE SILENT — no system audio landed (permission pending/denied, or nothing played)")
        exit(pass ? 0 : 1)
    }

    private static func fileStats(_ url: URL?) -> (text: String, peak: Float) {
        guard let url, let file = try? AVAudioFile(forReading: url) else { return ("missing", 0) }
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames),
              (try? file.read(into: buffer)) != nil,
              let ch = buffer.floatChannelData?[0] else { return ("unreadable", 0) }
        var peak: Float = 0
        var sumSquares: Double = 0
        for i in 0..<Int(buffer.frameLength) {
            let a = abs(ch[i])
            peak = max(peak, a)
            sumSquares += Double(a) * Double(a)
        }
        let rms = (sumSquares / Double(max(1, Int(buffer.frameLength)))).squareRoot()
        let text = String(format: "%.1f s @ %.0f Hz, peak %.4f, rms %.5f",
                          Double(file.length) / file.processingFormat.sampleRate,
                          file.processingFormat.sampleRate, peak, rms)
        return (text, peak)
    }
}

/// Renders every screenshot the user guide needs, offscreen, into a directory:
///   Parrot --help-shots docs/help/img
/// Settings pages are Forms (scroll views), which ImageRenderer leaves empty —
/// these render inside a real, never-shown NSWindow so AppKit does a full
/// layout pass first.
enum HelpShots {
    @MainActor
    static func run(outputDir: String) {
        let dir = URL(fileURLWithPath: outputDir, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Shared world: in-memory store with the built-in profiles and a few
        // meetings, plus managers that look mid-flight.
        let schema = Schema([Meeting.self, TranscriptSegment.self, CallInsight.self, CallProfile.self, SpeakerProfile.self])
        guard let container = try? ModelContainer(
            for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        ) else { print("help-shots: container failed"); exit(1) }
        let context = container.mainContext

        let rm = RecordingManager()
        rm.profileStore.seedAndMigrateIfNeeded(context: context, knowledgeBase: rm.knowledgeBase)
        UserDefaults.standard.register(defaults: [
            "copilotEnabled": true,
            "copilotProvider": "claude",
            "whisperModel": "large-v3-turbo",
            // Onboarding renders whichever step this points at; the onboarding
            // shots below re-register it per step (1 permissions, 2 models).
            "onboardingStep": 2,
        ])

        // A live-looking meeting for the call screen.
        let meeting = Meeting(title: "Demo call with Acme")
        context.insert(meeting)
        let lines: [(TimeInterval, String, String)] = [
            (62, "Them", "So how would the migration from our current tool work in practice?"),
            (66, "Them", "We have about two years of call history in there."),
            (71, "Me", "We handle the full export and import for you, archive included."),
            (76, "Me", "Usually that's done within a week."),
            (81, "Them", "Okay. And what does the annual plan cost for a team of ten?"),
        ]
        for (start, speaker, text) in lines {
            let seg = TranscriptSegment(startTime: start, endTime: start + 4,
                                        text: text, speakerLabel: speaker, confidence: nil)
            context.insert(seg)
            seg.meeting = meeting
        }
        try? context.save()
        rm.seedForSnapshot(meeting: meeting, elapsed: 85, modelContext: context)
        rm.audioCaptureManager.seedForSnapshot(
            input: "MacBook Pro Microphone", output: "MacBook Pro Speakers",
            micLevel: 0.03, systemLevel: 0.12)

        let salesProfile = (try? context.fetch(FetchDescriptor<CallProfile>()))?
            .first { $0.name == "Sales discovery" }
        rm.callAnalysisEngine.seedForSnapshot(
            profile: salesProfile,
            insights: [
                Insight(kindKey: "unanswered_question",
                        title: "Annual pricing for 10 seats still open",
                        detail: "They asked what the annual plan costs for ten people and haven't had an answer yet.",
                        callTime: 81, source: "Them",
                        reply: "For ten seats the annual plan is $79 per seat per month, billed yearly."),
                Insight(kindKey: "buying_signal",
                        title: "Asking about migration logistics",
                        detail: "Questions about moving two years of history over usually mean they're picturing the switch.",
                        callTime: 66, source: "Them", reply: nil),
            ],
            sentiment: ["score": 72, "buying_temperature": 65],
            read: "engaged", coach: "Going well — answer the pricing question, then ask who signs off.",
            meCharacters: 620, themCharacters: 780)

        func settings(_ section: SettingsSection) -> some View {
            SettingsView(isEmbedded: false, initialSection: section)
                .environment(rm)
                .environment(rm.profileStore)
                .environment(AppSession())
                .modelContainer(container)
        }

        var made: [String] = []
        func shot(_ name: String, size: NSSize, _ view: some View) {
            let path = dir.appendingPathComponent(name).path
            if windowRender(view, size: size, to: path) { made.append(name) }
            else { print("help-shots: FAILED \(name)") }
        }

        shot("settings-general.png", size: .init(width: 780, height: 540), settings(.general))
        shot("settings-recording.png", size: .init(width: 780, height: 540), settings(.recording))
        shot("settings-transcription.png", size: .init(width: 780, height: 620), settings(.transcription))
        shot("settings-copilot.png", size: .init(width: 780, height: 700), settings(.copilot))
        shot("settings-knowledge.png", size: .init(width: 780, height: 540), settings(.knowledge))

        shot("settings-profiles.png", size: .init(width: 860, height: 640),
             ProfilesSettingsView()
                .environment(rm).environment(rm.profileStore).environment(AppSession())
                .modelContainer(container))
        // Tall on purpose: the Advanced kinds/gauges editors live far down the
        // form, and the window's viewport is what gets captured.
        shot("profiles-advanced.png", size: .init(width: 860, height: 2450),
             ProfilesSettingsView(advancedInitiallyOpen: true)
                .environment(rm).environment(rm.profileStore).environment(AppSession())
                .modelContainer(container))

        shot("live-screen.png", size: .init(width: 1160, height: 720),
             LiveRecordingView()
                .environment(rm).environment(rm.profileStore).environment(AppSession())
                .modelContainer(container))

        shot("dashboard.png", size: .init(width: 1000, height: 620),
             DashboardView(selectedMeeting: .constant(nil), showDashboard: .constant(true))
                .environment(rm).environment(rm.profileStore).environment(AppSession())
                .modelContainer(container))

        // Onboarding, real sheet geometry (500x600): if a step ever outgrows
        // it, these shots show the clipping before a user does. Repeated
        // register(defaults:) calls replace the key, picking the step.
        UserDefaults.standard.register(defaults: ["onboardingStep": 1])
        shot("onboarding-permissions.png", size: .init(width: 500, height: 600),
             OnboardingView(isPresented: .constant(true))
                .environment(rm).environment(rm.profileStore)
                .modelContainer(container))

        UserDefaults.standard.register(defaults: ["onboardingStep": 2])
        shot("onboarding-model.png", size: .init(width: 500, height: 600),
             OnboardingView(isPresented: .constant(true))
                .environment(rm).environment(rm.profileStore)
                .modelContainer(container))

        // Reuses the dashboard shot just written as the attached screenshot, so
        // the guide shows the sheet the way a user meets it.
        shot("bug-report.png", size: .init(width: 460, height: 470),
             BugReportSheet(screenshot: NSImage(contentsOf: dir.appendingPathComponent("dashboard.png"))))

        print("help-shots: wrote \(made.count) → \(dir.path)")
        exit(made.count >= 12 ? 0 : 1)
    }

    /// Real-window offscreen render: lay out, pump the runloop so SwiftUI
    /// settles (Forms, Lists, async images), then cache the bitmap.
    @MainActor
    private static func windowRender(_ view: some View, size: NSSize, to path: String) -> Bool {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.colorSpace = .sRGB
        window.appearance = NSAppearance(named: .aqua)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }
}

/// Drives the LIVE transcription loop (segmenter + decode + filters) end to
/// end from an audio file, the way capture feeds it. Run with:
///   Parrot --liveloop-test /path/audio.aiff [model]
/// Set LIVELOOP_REALTIME=1 to feed at recording pace (slow, but reproduces
/// live polling interleave); default feeds everything and drains.
/// Born from a real drop: the middle sentence of a three-sentence test never
/// reached the transcript while both neighbors did (2026-08-01).
enum LiveLoopTest {
    static func run(audioPath: String, model: String) {
        // dispatchMain(), not a semaphore: the engine's lifecycle funcs are
        // @MainActor, so the main thread must service the main queue rather
        // than block — a sem.wait() here deadlocks before the first print.
        Task { @MainActor in
            // LIVELOOP_VOCAB simulates the app's custom vocabulary (glossary
            // prompt) without touching persisted defaults — the same
            // register(defaults:) trick the snapshot harnesses use.
            if let vocab = ProcessInfo.processInfo.environment["LIVELOOP_VOCAB"] {
                UserDefaults.standard.register(defaults: ["customVocabulary": vocab])
            }
            let engine = TranscriptionEngine()
            await engine.loadModel(model.isEmpty ? "base" : model)
            guard engine.isReady else { print("liveloop-test: model failed to load"); exit(1) }

            var emitted: [(text: String, start: TimeInterval, end: TimeInterval)] = []
            engine.onSegment = { r in emitted.append((r.text, r.startTime, r.endTime)) }

            let samples: [Float]
            do { samples = try loadSamples16k(path: audioPath) } catch {
                print("liveloop-test: audio load failed — \(error)"); exit(1)
            }
            print("liveloop-test: \(samples.count) samples (\(String(format: "%.1f", Double(samples.count) / 16000))s)")

            engine.startTranscribing(meetingStartTime: .now)
            let realtime = ProcessInfo.processInfo.environment["LIVELOOP_REALTIME"] != nil
            let slice = 3200  // 200 ms, the ballpark capture delivers
            var i = 0
            while i < samples.count {
                let end = min(i + slice, samples.count)
                engine.appendAudio(pcmBuffer(Array(samples[i..<end])), source: .them)
                if realtime { try? await Task.sleep(for: .milliseconds(200)) }
                i = end
            }
            await engine.stopTranscribing()  // drain the tail
            try? await Task.sleep(for: .seconds(0.5))  // let queued onSegment hops land

            print("=== liveloop-test — \(emitted.count) segment(s) ===")
            for seg in emitted {
                print(String(format: "[%6.2f – %6.2f] %@", seg.start, seg.end, seg.text))
            }
            exit(0)
        }
        dispatchMain()
    }

    /// File → 16 kHz mono Float32, the engine's expected input format.
    private static func loadSamples16k(path: String) throws -> [Float] {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000,
                                   channels: 1, interleaved: false)!
        let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                     frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: inBuf)
        let converter = AVAudioConverter(from: file.processingFormat, to: target)!
        let outCap = AVAudioFrameCount(Double(file.length) * 16000 / file.processingFormat.sampleRate) + 1024
        let outBuf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCap)!
        var fed = false
        var convError: NSError?
        converter.convert(to: outBuf, error: &convError) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return inBuf
        }
        if let convError { throw convError }
        return Array(UnsafeBufferPointer(start: outBuf.floatChannelData![0],
                                         count: Int(outBuf.frameLength)))
    }

    private static func pcmBuffer(_ samples: [Float]) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000,
                                   channels: 1, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer {
            buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count)
        }
        return buf
    }
}

/// Offscreen renderer for the live copilot panel. Run with:
///   Parrot --copilot-snapshot /tmp/copilot.png
/// Renders the redesigned "glanceable" panel with seeded fake state (hero
/// suggestion, pinned blocker, history rows, sentiment chips) in light AND dark
/// (second file gets a "-dark" suffix), so the design can be eyeballed without
/// a live call. Dev-only; never reached in normal launches.
@MainActor
enum CopilotSnapshot {
    static func write(to path: String) {
        let rm = RecordingManager()
        let profile = ProfilePresets.all().first { $0.name == "Sales discovery" }

        // Newest first — index 0 becomes the hero. The unhandled objection is
        // filtered into the pinned zone regardless of position.
        let insights: [Insight] = [
            Insight(kindKey: "suggestion", title: "Answer the security question",
                    detail: "“All audio stays on your Mac — only transcript text goes to the API, and we can sign a DPA this week if that helps.”",
                    callTime: 754, source: "security-faq.pdf"),
            Insight(kindKey: "buying_signal", title: "Asked about onboarding timeline",
                    detail: "They want to know how fast the team could start — a strong intent signal.",
                    callTime: 698, source: nil),
            Insight(kindKey: "next_step", title: "Propose a pilot with the sales pod",
                    detail: "Offer a two-week pilot with the 5-person sales pod they mentioned.",
                    callTime: 645, source: nil),
            Insight(kindKey: "discovery_gap", title: "Budget owner still unknown",
                    detail: "Nobody has said who signs off — worth asking directly.",
                    callTime: 590, source: nil),
            Insight(kindKey: "objection", title: "Worried about switching costs",
                    detail: "They brought up migration effort from their current tool twice.",
                    callTime: 512, source: "onboarding-guide.pdf",
                    reply: "Our team handles the full migration in under a week — the onboarding guide has the exact checklist."),
        ]

        rm.callAnalysisEngine.seedForSnapshot(
            profile: profile,
            insights: insights,
            sentiment: ["buying_temperature": 62, "my_dominance": 55, "score": 68],
            read: "warming",
            coach: "Going well — stop listing features and ask who signs off on budget.",
            meCharacters: 1300, themCharacters: 900
        )

        let panel = CopilotPanelView(transcriptJumpTarget: .constant(nil))
            .environment(rm)
            .frame(width: 420, height: 700)

        let light = render(panel, dark: false, to: path)
        let dark = render(panel, dark: true, to: (path as NSString).deletingPathExtension + "-dark.png")

        // ImageRenderer can't lay out ScrollView contents, so the panel render
        // shows an empty history area — render the rows separately (one
        // expanded) so their design is still verifiable offscreen.
        func kindStyle(_ insight: Insight) -> KindStyle {
            KindResolver.style(forKey: insight.kindKey, profile: profile, snapshot: [])
        }
        let history = VStack(spacing: 6) {
            PinnedBlockerRow(insight: insights[4], startExpanded: true, onHandled: {}, onJump: {})
            InsightCard(insight: insights[1], kindStyle: kindStyle(insights[1]),
                        isCollapsed: true, onToggleCollapse: {}, onJump: {}, onDismiss: {})
            InsightCard(insight: insights[2], kindStyle: kindStyle(insights[2]),
                        isCollapsed: false, onToggleCollapse: {}, onJump: {}, onDismiss: {})
            InsightCard(insight: insights[3], kindStyle: kindStyle(insights[3]),
                        isCollapsed: true, onToggleCollapse: {}, onJump: {}, onDismiss: {})
        }
        .padding(12)
        .frame(width: 420)
        .background(Theme.Colors.panel)
        let rows = render(history, dark: false, to: (path as NSString).deletingPathExtension + "-history.png")

        let legendURL = render(legend(profile: profile), dark: false,
                               to: (path as NSString).deletingPathExtension + "-legend.png")

        // Chat-bubble transcript strip: two speaker groups + the typing bubble.
        let seg: (TimeInterval, String, String) -> TranscriptSegment = { start, speaker, text in
            TranscriptSegment(startTime: start, endTime: start + 4, text: text,
                              speakerLabel: speaker, confidence: nil)
        }
        let bubbleSegments = [
            seg(120, "Them", "So how would the migration from our current tool actually work?"),
            seg(124, "Them", "We have about two years of call history in there."),
            seg(129, "Me", "Great question — we handle the full export and import for you."),
            seg(134, "Me", "Usually it's done within a week, including the archive."),
        ]
        let bubbles = VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(bubbleSegments.enumerated()), id: \.offset) { index, segment in
                ChatBubbleRow(
                    segment: segment,
                    isFirstOfGroup: index == 0
                        || bubbleSegments[index - 1].speakerLabel != segment.speakerLabel
                )
            }
            TypingBubble(text: "That sounds reasonable, and what about")
                .padding(.top, 8)
        }
        .padding(12)
        .frame(width: 380)
        .background(Theme.Colors.panel)
        let bubblesURL = render(bubbles, dark: false,
                                to: (path as NSString).deletingPathExtension + "-bubbles.png")

        FileHandle.standardError.write(Data("copilot-snapshot: wrote \(light.path) + \(dark.path) + \(rows.path) + \(legendURL.path) + \(bubblesURL.path)\n".utf8))
        exit(0)
    }

    // MARK: - Card-system legend

    /// A one-image guide to the live panel: the four zones plus every card kind
    /// of the given profile, drawn with the app's real colors and icons.
    private static func legend(profile: CallProfile?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Parrot Copilot — what each card means")
                .font(Theme.Typography.title(20))
                .foregroundStyle(Theme.Colors.ink)

            Text("PANEL ZONES (top to bottom)")
                .font(Theme.Typography.cap)
                .foregroundStyle(Theme.Colors.ink3)

            legendRow(Theme.Colors.accent, "gauge.with.needle",
                      "Coach card — always on top",
                      "Live verdict: 0–100 call score, one sentence of what to do right now, mood chips, and how many blockers are open.")
            legendRow(Theme.Colors.subtle, "rectangle.inset.filled.top",
                      "Hero card — the big tinted one",
                      "The newest insight, at full size. Glows briefly when it lands. This is the one to glance at.")
            legendRow(Theme.Colors.warn, "exclamationmark.triangle.fill",
                      "Orange cards — unresolved",
                      "Objections and questions you haven't dealt with yet. Click to read all of it; ✓ marks it handled — or it clears itself when the call actually resolves it.")
            legendRow(Theme.Colors.ink3, "list.bullet",
                      "EARLIER — the quiet history",
                      "Everything older, one line each. Click any row to expand it.")

            Divider().overlay(Theme.Colors.line)

            Text("CARD KINDS IN THIS PROFILE (\(profile?.name ?? "Default"))")
                .font(Theme.Typography.cap)
                .foregroundStyle(Theme.Colors.ink3)

            ForEach(profile?.kinds ?? [], id: \.id) { kind in
                legendRow(KindResolver.adaptiveColor(forHex: kind.colorHex),
                          kind.iconSystemName, kind.label,
                          legendBlurb(for: kind.key))
            }
        }
        .padding(Theme.Metrics.pad)
        .frame(width: 480)
        .background(Theme.Colors.canvas)
    }

    private static func legendRow(_ color: Color, _ icon: String,
                                  _ title: String, _ blurb: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: Theme.Metrics.radius)
                .fill(color.opacity(0.16))
                .frame(width: 30, height: 30)
                .overlay(Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(color))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Typography.cardTitle)
                    .foregroundStyle(Theme.Colors.ink)
                Text(blurb)
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Colors.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Plain-language one-liner per sales-profile kind key (falls back to the
    /// kind's own trigger text for custom kinds).
    private static func legendBlurb(for key: String) -> String {
        switch key {
        case "suggestion": "A line you can literally say, right now. The Copy button puts it on your clipboard."
        case "objection": "They pushed back (price, timing, competitor) and it isn't settled yet. Stays orange until handled."
        case "unanswered_question": "They asked you something and the conversation moved on — circle back to it."
        case "opportunity": "They revealed a pain or goal your offer can solve — how to position it."
        case "buying_signal": "A sign they're interested — the moment to advance the deal."
        case "next_step": "A concrete step to propose or confirm (pilot, follow-up call, intro)."
        case "discovery_gap": "Something important you don't know yet — the card is the question to ask next."
        default: "Custom card defined in this profile's settings."
        }
    }

    private static func render(_ view: some View, dark: Bool, to path: String) -> URL {
        let renderer = ImageRenderer(
            content: AnyView(view.environment(\.colorScheme, dark ? .dark : .light)))
        renderer.scale = 2
        // Theme colors resolve through NSColor(name:) providers, which follow the
        // current *drawing* appearance — set it explicitly per render.
        var cg: CGImage?
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            cg = renderer.cgImage
        }
        guard let cg else {
            FileHandle.standardError.write(Data("copilot-snapshot: render failed\n".utf8))
            exit(1)
        }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
        return SnapshotIO.write(data, to: path)
    }
}

/// Shared PNG writer for the snapshot harnesses. The app is sandboxed, so an
/// arbitrary path like /tmp fails — silently, when written with try?. Write,
/// and on denial fall back to the container's temp dir, always returning the
/// URL that actually holds the file.
enum SnapshotIO {
    static func write(_ data: Data, to path: String) -> URL {
        let requested = URL(fileURLWithPath: path)
        do {
            try data.write(to: requested)
            return requested
        } catch {
            let fallback = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent(requested.lastPathComponent)
            do {
                try data.write(to: fallback)
                return fallback
            } catch {
                FileHandle.standardError.write(Data("snapshot: write failed — \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
    }
}

/// Dev-only: one real analysis pass through the selected copilot provider.
///   Parrot --analyze-test [claude|ollama|custom] [model]
/// Fixture sales transcript + the Sales discovery preset profile; prints the
/// parsed cards, sentiment, and token usage so structured-output quality of a
/// backend can be judged without a live call. Exits non-zero on failure.
enum AnalyzeTest {
    static func run(provider: String?, model: String?) {
        // register(defaults:) supplies values without persisting anything —
        // the app's real settings are untouched.
        if let provider {
            UserDefaults.standard.register(defaults: ["copilotProvider": provider])
        }
        if let model {
            UserDefaults.standard.register(defaults: [
                "copilotOllamaModel": model,
                "copilotCustomModel": model,
            ])
        }

        let profile = ProfilePresets.all().first { $0.name == "Sales discovery" }
        let transcript = """
        [00:12] Them: So walk me through how the migration from our current tool would work.
        [00:31] Me: Great question — we handle the export and import for you, usually within a week.
        [01:02] Them: Okay. And honestly the price feels steep compared to what we pay now.
        [01:18] Me: Understood — can I ask what you're comparing against?
        [01:25] Them: We pay about half of your quote today. Also, is the data stored in the EU?
        [01:40] Me: Let me get back to you on hosting regions.
        [02:05] Them: Alright. We'd want to start with the five-person sales pod if we do this.
        """
        let request = AnalysisRequest(
            transcript: transcript,
            // The price objection at 01:02 is ALREADY covered by this shown
            // card, so a well-behaved model must not re-flag it (or must mark
            // the re-flag via "supersedes" — printed below to judge dedup).
            knownInsightTitles: ["Price pushback: quote is roughly double their current spend"],
            references: [],
            instructions: "",
            callBrief: "",
            allowGeneralKnowledge: true,
            knownDocumentNames: [],
            persona: profile?.persona ?? "You assist a sales professional during live calls.",
            counterpart: "the prospect",
            kinds: profile?.kinds ?? [],
            gauges: profile?.gauges ?? []
        )

        var exitCode: Int32 = 1
        let sem = DispatchSemaphore(value: 0)
        Task {
            let analysisProvider = SwitchingAnalysisProvider()
            let start = Date()
            do {
                let result = try await analysisProvider.analyze(request)
                let secs = String(format: "%.1f", Date().timeIntervalSince(start))
                print("=== analyze-test (\(CopilotProviderKind.selected.rawValue) · \(CopilotProviderKind.activeModelName)) — \(secs)s")
                print("coach: \(result.coach ?? "-")")
                print("score: \(result.sentiment["score"].map(String.init) ?? "MISSING") · read: \(result.read ?? "-")")
                print("gauges: \(result.sentiment.filter { $0.key != "score" })")
                for insight in result.insights {
                    var line = "- [\(insight.kindKey)] \(insight.title) — \(insight.detail)"
                    if let reply = insight.reply { line += " | say: \(reply)" }
                    if let source = insight.source { line += " | src: \(source)" }
                    if let supersedes = insight.supersedes { line += " | SUPERSEDES: \(supersedes)" }
                    print(line)
                }
                let usage = analysisProvider.usageTotals
                print("usage: \(usage.calls) call(s), \(usage.inputTokens) in / \(usage.outputTokens) out")
                // Schema honored = the always-required sentiment.score came back.
                exitCode = result.sentiment["score"] != nil ? 0 : 1
            } catch {
                print("analyze-test FAILED: \(error.localizedDescription)")
            }
            sem.signal()
        }
        sem.wait()
        exit(exitCode)
    }
}

/// Offscreen renderer for the sidebar's waveform meeting rows. Run with:
///   Parrot --sidebar-snapshot /tmp/sidebar.png
/// Seeds an in-memory store with meetings whose transcripts have distinct talk
/// balances (even, me-heavy, live-recording, empty) so the dual-lane strips can
/// be eyeballed in light AND dark ("-dark" suffix). Dev-only.
@MainActor
enum SidebarSnapshot {
    static func write(to path: String) {
        let schema = Schema([Meeting.self, TranscriptSegment.self, CallInsight.self, CallProfile.self, SpeakerProfile.self])
        guard let container = try? ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        ) else {
            FileHandle.standardError.write(Data("sidebar-snapshot: container failed\n".utf8))
            exit(1)
        }
        let context = container.mainContext

        // Alternating two-sided call — balanced strip.
        let balanced = seed(context, "Sales discovery — Acme", minutes: 45,
                            pattern: [("Me", 20), ("Them", 40), ("Me", 30), ("Them", 25)])
        // The user monologues the middle third — lopsided top lane.
        let meHeavy = seed(context, "1:1 coaching — Deniz", minutes: 30,
                           pattern: [("Them", 15), ("Me", 90), ("Them", 20), ("Me", 15)])
        // Live recording, few segments so the strip is sparse.
        let live = seed(context, "Weekly review", minutes: 4,
                        pattern: [("Me", 12), ("Them", 8)])
        live.status = .recording
        // No transcript at all — centerline only.
        let empty = seed(context, "Imported audio", minutes: 0, pattern: [])

        let rows = VStack(spacing: 1) {
            MeetingRow(meeting: live, selected: false)
            MeetingRow(meeting: balanced, selected: true)
            MeetingRow(meeting: meHeavy, selected: false)
            MeetingRow(meeting: empty, selected: false)
        }
        .padding(8)
        .frame(width: 240)
        .background(Theme.Colors.panel)

        let light = render(rows, dark: false, to: path)
        let dark = render(rows, dark: true, to: (path as NSString).deletingPathExtension + "-dark.png")
        FileHandle.standardError.write(Data("sidebar-snapshot: wrote \(light.path) + \(dark.path)\n".utf8))
        exit(0)
    }

    /// Repeats `pattern` (speaker, seconds) turns until the duration is filled.
    private static func seed(_ context: ModelContext, _ title: String,
                             minutes: Double, pattern: [(String, Double)]) -> Meeting {
        let meeting = Meeting(title: title)
        meeting.duration = minutes * 60
        meeting.status = .done
        context.insert(meeting)
        guard !pattern.isEmpty else { return meeting }
        var t: TimeInterval = 0
        var i = 0
        while t < meeting.duration {
            let (speaker, secs) = pattern[i % pattern.count]
            let seg = TranscriptSegment(startTime: t, endTime: min(t + secs, meeting.duration),
                                        text: "…", speakerLabel: speaker)
            seg.meeting = meeting
            context.insert(seg)
            t += secs + 4  // small silence gap between turns
            i += 1
        }
        return meeting
    }

    private static func render(_ view: some View, dark: Bool, to path: String) -> URL {
        let renderer = ImageRenderer(
            content: AnyView(view.environment(\.colorScheme, dark ? .dark : .light)))
        renderer.scale = 2
        var cg: CGImage?
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            cg = renderer.cgImage
        }
        guard let cg else {
            FileHandle.standardError.write(Data("sidebar-snapshot: render failed\n".utf8))
            exit(1)
        }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
        return SnapshotIO.write(data, to: path)
    }
}

/// Offscreen renderer for design verification. Run with:
///   Parrot --snapshot /tmp/report.png
/// It renders the post-meeting report exactly as the app does (same views + theme)
/// to a PNG, so the SwiftUI output can be checked against the design mockup without
/// driving the GUI. Dev-only; never reached in normal launches.
@MainActor
enum ReportSnapshot {
    static func write(to path: String) {
        // A faithful slice of the report screen: title + meta + the styled
        // report content (the part that was previously a raw-text dump).
        let view = VStack(alignment: .leading, spacing: 0) {
            Text("Parenting coaching session")
                .font(Theme.Typography.title(20))
                .foregroundStyle(Theme.Colors.ink)
            HStack(spacing: 8) {
                metaPill("calendar", "Jun 19, 2026")
                metaPill("clock", "49 min")
                metaPill("person", "NHS Advisor")
            }
            .padding(.top, 12)

            Divider().overlay(Theme.Colors.line).padding(.vertical, 16)

            ReportContentView(summary: sampleSummary, coaching: sampleCoaching, talkPercentMe: 29)
        }
        .frame(width: 600, alignment: .leading)
        .padding(Theme.Metrics.pad)
        .background(Theme.Colors.canvas)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let cg = renderer.cgImage else {
            FileHandle.standardError.write(Data("snapshot: render failed\n".utf8))
            exit(1)
        }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
        let written = SnapshotIO.write(data, to: path)
        FileHandle.standardError.write(Data("snapshot: wrote \(written.path)\n".utf8))
        exit(0)
    }

    private static func metaPill(_ icon: String, _ text: String) -> some View {
        Label(text, systemImage: icon)
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.Colors.ink2)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Theme.Colors.chip, in: RoundedRectangle(cornerRadius: Theme.Metrics.radius))
    }

    static let sampleSummary = """
    # Post-Call Report

    This was a one-on-one session between a parent and a clinician focused on Alex's ADHD management — emotion recognition, a 12-minute "regulation corner", and selectively ignoring attention-seeking behaviour. The call was productive; the parent committed to several new strategies before the next session on July 10th.

    Key points:
    - Alex's week was generally positive with mild arguments; morning routine improved despite late-night World Cup watching
    - Timeout reframed as a 12-minute "regulation corner" (not punishment)
    - Parent struggles with emotion-naming; clinician modelled how to validate Alex's feelings during disappointment
    - Selective ignoring introduced for attention-seeking behaviours like monster sounds (10–15 minutes max)

    Next steps:
    - Review handouts 20–23 and create a calm-down menu with Alex
    - Practise emotion-naming in calm, positive moments first
    - Confirm online vs in-person for next week before end of workday
    """

    static let sampleCoaching = """
    Call snapshot: Parenting coaching session on managing a child's behaviour — Me spoke 29%, Them 71%. Heavy teaching call with good engagement.

    What went well:
    - Acknowledged gaps in his own skills directly and asked for examples instead of deflecting
    - Strong vulnerability at 19:15 when sharing guilt over raising his voice, which built trust
    - Took notes on handouts and committed to specific follow-ups

    What to improve:
    - Didn't fully grasp praising effort vs naming emotion — could have asked a clarifying question earlier
    - Drifted into a 3-minute tech tangent near the end when time was tight

    Commitments & follow-ups:
    - Read handouts 20, 21, 22, 23 before the next meeting
    - Create a calm-down menu and report back on which skills Alex likes
    """
}
