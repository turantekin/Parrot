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
                let url = URL(fileURLWithPath: audioPath)
                let t0 = Date()
                let output: DiarizationEngine.Output
                if let tail = ProcessInfo.processInfo.environment["TAIL"].flatMap(Double.init) {
                    output = try await engine.diarize(audioURL: url, lastSeconds: tail)
                } else {
                    output = try await engine.diarize(audioURL: url)
                }
                print("DIARIZE seconds", Date().timeIntervalSince(t0), "start", output.start)
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

extension TranscribeTest {
    /// `--language-test <audio> [modelFolder] [seconds]`: the live language check on a
    /// saved track. Gathers voiced buffers the way `appendAudio` does, then
    /// prints what Whisper hears and what the live bar would offer for an
    /// English pin and for Deepgram on auto.
    static func detectLanguage(audioPath: String, modelFolder: String, seconds: Int? = nil) {
        let sem = DispatchSemaphore(value: 0)
        Task {
            do {
                let whisperKit = try await WhisperKit(WhisperKitConfig(
                    modelFolder: modelFolder.isEmpty ? nil : modelFolder,
                    verbose: false, logLevel: .none, load: true, download: modelFolder.isEmpty))
                let audio = AudioProcessor.convertBufferToArray(
                    buffer: try AudioProcessor.loadAudio(fromPath: audioPath))
                var probe: [Float] = []
                let wanted = seconds.map { $0 * 16000 } ?? TranscriptionEngine.languageProbeSamples
                for start in stride(from: 0, to: audio.count, by: 1600) where probe.count < wanted {
                    let buffer = audio[start ..< min(start + 1600, audio.count)]
                    let energy = buffer.reduce(into: Float(0)) { $0 += abs($1) } / Float(buffer.count)
                    if energy > TranscriptionEngine.Segmenter.silenceFloor { probe.append(contentsOf: buffer) }
                }
                let result = try await whisperKit.detectLangauge(
                    audioArray: TranscriptionEngine.normalizedForDecode(probe))
                let confidence = exp(result.langProbs[result.language] ?? -.infinity)
                print("heard \(result.language) p=\(String(format: "%.2f", confidence)) from \(probe.count / 16000) s of speech")
                print("pinned en, local → \(TranscriptionEngine.languageMismatch(setting: "en", backend: .local, heard: result.language, confidence: confidence) ?? "quiet")")
                print("auto, deepgram   → \(TranscriptionEngine.languageMismatch(setting: nil, backend: .deepgram, heard: result.language, confidence: confidence) ?? "quiet")")
            } catch {
                print("language-test error: \(error)")
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
/// `--echo-replay <mic.caf> <system.caf> [lines.tsv]`: scores a recorded
/// call's Me lines with the loudness echo gate, to calibrate it on real
/// speaker calls. lines.tsv is one stored line per row: start, end, speaker
/// label, text (tab separated). Without it, prints only how far the mic
/// trails the system track. Recordings from before 0.24.0 started the tracks
/// seconds apart; that offset is measured and taken out first.
enum EchoReplay {
    static func run(micPath: String, systemPath: String, linesPath: String?) {
        typealias G = EchoGate
        guard let mic = load(micPath), let system = load(systemPath) else {
            print("echo-replay: can't read the audio files"); exit(1)
        }
        let micEnv = G.envelope(mic[...]), themEnv = G.envelope(system[...])
        // Whole-call delay within ±10 s, in log level like the gate.
        func level(_ x: Float) -> Float { log10(x + 1e-4) }
        let a = micEnv.map(level), b = themEnv.map(level)
        var bestLag = 0, bestR: Float = -1
        for lag in -500...500 {
            let lo = max(0, lag), hi = min(a.count, b.count + lag)
            guard hi - lo > 500 else { continue }
            let ma = a[lo..<hi].reduce(0, +) / Float(hi - lo), mb = b[(lo - lag)..<(hi - lag)].reduce(0, +) / Float(hi - lo)
            var ab: Float = 0, aa: Float = 0, bb: Float = 0
            for i in lo..<hi {
                let x = a[i] - ma, y = b[i - lag] - mb
                ab += x * y; aa += x * x; bb += y * y
            }
            let r = aa > 0 && bb > 0 ? ab / (aa * bb).squareRoot() : 0
            if r > bestR { bestR = r; bestLag = lag }
        }
        // ponytail: only old misaligned recordings with clear bleed get shifted;
        // new ones are scored as the live gate sees them. Without bleed (headphones)
        // the best lag is noise.
        let shift = bestR < 0.3 || (-G.maxLead...G.maxLag).contains(bestLag) ? 0 : bestLag
        print(String(format: "mic trails system by %d ms (whole-call r=%.2f)%@", bestLag * 20, bestR,
                     shift == 0 ? "" : " — old recording, shifting by that much"))
        guard let linesPath, let text = try? String(contentsOfFile: linesPath, encoding: .utf8) else { return }

        let lines = text.split(separator: "\n").compactMap { row -> (start: Double, end: Double, label: String, text: String)? in
            let f = row.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard f.count == 4, let s = Double(f[0]), let e = Double(f[1]) else { return nil }
            return (s, e, f[2], f[3])
        }
        // Both envelopes on the mic's clock, as they are live since 0.24.0.
        let theirs = shift >= 0 ? Array(repeating: 0, count: shift) + themEnv : Array(themEnv.dropFirst(-shift))
        var mine = 0, dropped = 0
        for line in lines where line.label == "Me" {
            let lo = max(0, Int(line.start * 16000)), hi = min(mic.count, Int(line.end * 16000))
            guard hi > lo else { continue }
            mine += 1
            let verdict = G.check(clip: Array(mic[lo..<hi]), mic: micEnv, them: theirs, at: lo / G.hop)
            if verdict.isEcho { dropped += 1 }
            let overlapping = lines.filter { $0.label != "Me" && $0.start < line.end && $0.end > line.start }
                .map(\.text).joined(separator: " / ")
            print(String(format: "%7.1f-%7.1f bleed=%5.2f whileTalking=%5.2f follows=%5.2f lag=%2d talk=%.2f %@ | %@  ‖ them: %@",
                         line.start, line.end, verdict.bleed.follows, verdict.talkBleed.follows, verdict.clip.follows, verdict.clip.lag,
                         verdict.clip.themTalking, verdict.isEcho ? "DROP" : "keep", line.text,
                         String(overlapping.prefix(90))))
        }
        print("Me lines: \(mine) | the gate drops \(dropped)")
    }

    private static func load(_ path: String) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)),
              file.processingFormat.sampleRate == 16000,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil,
              let ch = buffer.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: ch, count: Int(buffer.frameLength)))
    }
}

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
        // CAPTURE_TEST_STALL_MS=50 blocks every 20th system buffer that long,
        // like transcription holding its buffer lock: the tap must not lose
        // audio while its consumer is briefly stuck (issue #100).
        let stallMs = Int(ProcessInfo.processInfo.environment["CAPTURE_TEST_STALL_MS"] ?? "") ?? 0
        nonisolated(unsafe) var systemSeen = 0
        manager.onAudioBuffer = { buffer, source in
            counter.record(buffer: buffer, source: source)
            if stallMs > 0, source == .them {
                systemSeen += 1
                if systemSeen % 20 == 0 { usleep(useconds_t(stallMs * 1000)) }
            }
        }
        do {
            try await manager.startCapture()
        } catch {
            print("capture-test: startCapture FAILED — \(error.localizedDescription)")
            exit(2)
        }
        print("backend: \(manager.captureBackend.rawValue) | input: \(manager.inputDeviceName) | output: \(manager.outputDeviceName)")
        print("screen-recording preflight (SCK fallback available): \(CGPreflightScreenCaptureAccess())")

        // CAPTURE_TEST_MUTE=1: "Mute me" for the middle third (#96). The mic
        // file must keep its length with silence there, and the watchdog must
        // not mistake our silence for another app grabbing the mic.
        let muteTest = ProcessInfo.processInfo.environment["CAPTURE_TEST_MUTE"] != nil
        if muteTest {
            let third = UInt64(seconds / 3 * 1_000_000_000)
            try? await Task.sleep(nanoseconds: third)
            manager.setMicMuted(true)
            try? await Task.sleep(nanoseconds: third)
            print("while muted — mic signal lost: \(manager.micSignalLost) | not hearing you: \(manager.micSeemsDead)")
            manager.setMicMuted(false)
            try? await Task.sleep(nanoseconds: third)
        } else {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }

        let endBackend = manager.captureBackend  // stopCapture resets it
        let systemURL = manager.systemAudioURL
        let micURL = manager.micAudioURL
        await manager.stopCapture()

        let stats = counter.snapshot()
        print(String(format: "live buffers — system: %d (peak %.4f) | mic: %d (peak %.4f)",
                     stats.systemBuffers, stats.systemPeak, stats.micBuffers, stats.micPeak))
        print("backend at end: \(endBackend.rawValue) | tap grant proven: \(UserDefaults.standard.bool(forKey: PermissionFlow.tapProvenKey))")
        print(String(format: "system audio skipped by the tap: %.3f s%@", manager.systemLostSeconds,
                     stallMs > 0 ? " (stalling \(stallMs) ms every 20th buffer)" : ""))

        let systemStats = fileStats(systemURL)
        print("system .caf: \(systemStats.text)")
        print("mic .caf: \(fileStats(micURL).text)")
        if muteTest, let micURL, let file = try? AVAudioFile(forReading: micURL),
           let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
           (try? file.read(into: buffer)) != nil, let ch = buffer.floatChannelData?[0] {
            let n = Int(buffer.frameLength), third = n / 3
            // Skip 0.3 s at each edge of the muted third: the toggles land between buffers.
            let pad = Int(0.3 * file.processingFormat.sampleRate)
            func level(_ r: Range<Int>) -> Float { r.reduce(Float(0)) { $0 + abs(ch[$1]) } / Float(max(1, r.count)) }
            print(String(format: "mic level by third — before %.5f | muted %.5f | after %.5f",
                         level(0..<third), level((third + pad)..<(2 * third - pad)), level((2 * third)..<n)))
        }

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
        var firstSound = -1  // first sample above the harness's "real audio" bar
        for i in 0..<Int(buffer.frameLength) {
            let a = abs(ch[i])
            peak = max(peak, a)
            sumSquares += Double(a) * Double(a)
            if firstSound < 0, a > 0.01 { firstSound = i }
        }
        let rms = (sumSquares / Double(max(1, Int(buffer.frameLength)))).squareRoot()
        let rate = file.processingFormat.sampleRate
        let text = String(format: "%.1f s @ %.0f Hz, peak %.4f, rms %.5f, first sound at %.2f s",
                          Double(file.length) / rate, rate, peak, rms,
                          firstSound < 0 ? -1 : Double(firstSound) / rate)
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
        // The bare binary has no bundle icon; ParrotAvatar draws the app icon.
        if let icon = NSImage(contentsOfFile: "Parrot/Assets.xcassets/AppIcon.appiconset/icon_128@2x.png") {
            NSApplication.shared.applicationIconImage = icon
        }

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
            "onboardingStillFrame": true,
            // SpeechModelStep starts a real WhisperKit download on appear;
            // this keeps a screenshot from kicking one off.
            "onboardingNoAutoDownload": true,
            // Help shots never read the Keychain or call a cloud service.
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
            meSeconds: 41, themSeconds: 52,
            brief: "Renewal call with Acme. Legal wants to know where the data is stored.")

        // Folders, an own Use for, an off folder and an unused document, so
        // the Knowledge page shows every state.
        let vendorProfile = (try? context.fetch(FetchDescriptor<CallProfile>()))?
            .first { $0.name == "Vendor call" }
        let dealFolder = KBFolder(name: "Acme deal", scope: .only(Set([salesProfile?.id].compactMap { $0 })))
        let oldFolder = KBFolder(name: "Old deals", scope: .off)
        rm.knowledgeBase.seedForSnapshot(documents: [
            KBDocument(name: "security-faq.pdf", note: "Security and data answers for buyers",
                       chunkCount: 14, addedAt: .now, folderID: dealFolder.id),
            KBDocument(name: "pricing-2026.md", note: "Plans and discounts, 2026",
                       chunkCount: 9, addedAt: .now, folderID: dealFolder.id),
            KBDocument(name: "mutual-nda.md", note: "Signed NDA, Sept 2026", chunkCount: 4, addedAt: .now,
                       folderID: dealFolder.id, scope: .only(Set([vendorProfile?.id].compactMap { $0 }))),
            KBDocument(name: "northwind-proposal.md", chunkCount: 12, addedAt: .now, folderID: oldFolder.id),
            KBDocument(name: "roadmap.md", chunkCount: 20, addedAt: .now, scope: .off),
        ], folders: [dealFolder, oldFolder])

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

        shot("settings-general.png", size: .init(width: 780, height: 620), settings(.general))
        shot("settings-recording.png", size: .init(width: 780, height: 620), settings(.recording))
        shot("settings-transcription.png", size: .init(width: 780, height: 620), settings(.transcription))
        shot("settings-copilot.png", size: .init(width: 780, height: 620), settings(.copilot))
        shot("settings-knowledge.png", size: .init(width: 780, height: 620), settings(.knowledge))
        shot("whats-new-card.png", size: .init(width: 640, height: 260),
             WhatsNewCard(news: .sample) {}.padding(Theme.Metrics.pad).background(Theme.Colors.canvas))
        shot("settings-connections.png", size: .init(width: 780, height: 620), settings(.connections))
        shot("settings-privacy.png", size: .init(width: 780, height: 620), settings(.privacy))
        let acmeRef = AskEngine.MeetingRef(ref: "M1", meetingID: meeting.id, title: meeting.title,
                                           date: meeting.date, people: ["Sam"])
        var demo = AskChat(title: "What did Acme push back on?", scope: nil, scopeTitle: nil)
        demo.messages = [AskMessage(role: .me, text: "What did Acme push back on?")]
        var reply = AskMessage(role: .parrot, text: "")
        reply.lines = [AskEngine.Line(text: "The annual price for ten seats; they want it before they commit.",
                                      citations: [AskEngine.Citation(meetingID: meeting.id, time: 81)])]
        reply.refs = [acmeRef]
        reply.answeredByAI = true
        demo.messages.append(reply)
        rm.chats.seedForSnapshot([demo])
        shot("ask.png", size: .init(width: 1000, height: 620),
             AskPageView()
                .environment(rm).environment(AppSession()).modelContainer(container))

        // Connected-looking: the switch on, so the buttons aren't greyed out.
        UserDefaults.standard.register(defaults: [MCPServer.enabledKey: true])
        shot("ai-apps.png", size: .init(width: 900, height: 980),
             AIAppsPageView()
                .environment(rm).environment(AppSession()).modelContainer(container))

        shot("settings-profiles.png", size: .init(width: 860, height: 640),
             ProfilesSettingsView()
                .environment(rm).environment(rm.profileStore).environment(AppSession())
                .modelContainer(container))
        // Tall on purpose: the Advanced kinds/gauges editors live far down the
        // form, and the window's viewport is what gets captured.
        shot("profiles-advanced.png", size: .init(width: 860, height: 3500),
             ProfilesSettingsView(advancedInitiallyOpen: true)
                .environment(rm).environment(rm.profileStore).environment(AppSession())
                .modelContainer(container))

        shot("language-banner.png", size: .init(width: 1160, height: 64),
             LanguageMismatchBanner(heard: "tr", current: "en").background(Theme.Colors.canvas))
        shot("live-screen.png", size: .init(width: 1160, height: 720),
             LiveRecordingView()
                .environment(rm).environment(rm.profileStore).environment(AppSession())
                .modelContainer(container))

        shot("dashboard.png", size: .init(width: 1000, height: 620),
             DashboardView(selectedMeeting: .constant(nil), page: .constant(.dashboard))
                .environment(rm).environment(rm.profileStore).environment(AppSession())
                .modelContainer(container))

        // Onboarding, real sheet geometry (600x680): if a step ever outgrows
        // it, these shots show the clipping before a user does. Repeated
        // register(defaults:) calls replace the keys, picking step and path.
        func onboarding(_ file: String, _ step: OnboardingStep, path: CopilotPath? = nil) {
            UserDefaults.standard.register(defaults: [
                OnboardingMode.defaultsKey: OnboardingMode.full.rawValue,
                OnboardingFlow.stepKey: step.rawValue,
                CopilotPath.defaultsKey: path?.rawValue ?? "",
            ])
            shot(file, size: .init(width: 600, height: 680),
                 OnboardingView(isPresented: .constant(true))
                    .environment(rm).environment(rm.profileStore)
                    .modelContainer(container))
        }
        onboarding("onboarding-permissions.png", .permissions)
        onboarding("onboarding-meet-copilot.png", .meetCopilot)
        onboarding("onboarding-path.png", .copilotPath, path: .balanced)
        onboarding("onboarding-model.png", .speechModel, path: .balanced)
        onboarding("onboarding-setup-private.png", .copilotSetup, path: .private)
        onboarding("onboarding-setup-balanced.png", .copilotSetup, path: .balanced)
        onboarding("onboarding-setup-cloud.png", .copilotSetup, path: .cloud)
        onboarding("onboarding-automatic.png", .automatic)
        onboarding("onboarding-ai-apps.png", .aiApps, path: .balanced)
        onboarding("onboarding-ready.png", .ready, path: .balanced)

        // Reuses the dashboard shot just written as the attached screenshot, so
        // the guide shows the sheet the way a user meets it.
        shot("bug-report.png", size: .init(width: 460, height: 470),
             BugReportSheet(screenshot: NSImage(contentsOf: dir.appendingPathComponent("dashboard.png"))))

        // Home card as a new user who chose Decide later sees it. Last,
        // because it flips copilotEnabled off for everything after it.
        UserDefaults.standard.register(defaults: ["copilotEnabled": false, CopilotPath.defaultsKey: "later"])
        shot("home-copilot-card.png", size: .init(width: 600, height: 260),
             CopilotHomeCard().environment(rm).padding(Theme.Metrics.pad))

        // Profiles 2.0: the Report card, the offer, and the one-time screen.
        // Last, because they change the profiles for everything after them.
        let profiles = (try? context.fetch(FetchDescriptor<CallProfile>())) ?? []
        func editor(_ id: UUID?) -> some View {
            ProfilesSettingsView(initialSelection: id)
                .environment(rm).environment(rm.profileStore).environment(AppSession())
                .modelContainer(container)
        }
        shot("profiles-report.png", size: .init(width: 860, height: 1900), editor(salesProfile?.id))
        // As an update leaves them: restore points, a tuned 1:1 coaching with
        // its offer, and a profile the user made.
        for p in profiles where p.name != "Investor pitch" { p.saveVersion(label: ProfileStore.restorePointLabel) }
        if let coaching = profiles.first(where: { $0.name == "1:1 coaching" }) {
            coaching.isUserModified = true
            coaching.reportChoice = .classic
            coaching.reportOfferPending = true
        }
        let mine = CallProfile(name: "Northwind accounts", iconSystemName: "briefcase.fill", summary: "Account reviews",
                               isBuiltIn: false, sortOrder: 20, persona: "", tone: "", allowGeneralKnowledge: true,
                               kinds: [], gauges: [])
        mine.saveVersion(label: ProfileStore.restorePointLabel)
        context.insert(mine)
        try? context.save()
        shot("profiles-report-offer.png", size: .init(width: 860, height: 1500),
             editor(profiles.first { $0.name == "1:1 coaching" }?.id))
        shot("profiles2-screen.png", size: .init(width: 560, height: 760),
             ProfileMigrationView().environment(rm.profileStore).modelContainer(container))
        rm.profileStore.defaults.removeObject(forKey: ProfileStore.screenShownKey)

        // Profiles 2.0, part two: scorecards, rewrite, share, review.
        let interview = profiles.first { $0.name == "Interview" }
        shot("profiles-scorecard.png", size: .init(width: 860, height: 2300), editor(interview?.id))
        let scoreReport = """
        Overview:
        A first interview for the data role at Acme. The candidate walked through a pipeline rebuild.

        Scorecard:
        - Relevant experience: 4/5 - Rebuilt a nightly import, 3 hours down to 20 minutes [01:02]
        - Problem solving: 3/5 - Moved to small batches and added retries [01:06]
        - Communication: 4/5 [01:11]
        - Teamwork: not enough evidence

        Next steps:
        - You send the take-home task by Friday [01:16]
        """
        shot("report-scorecard.png", size: .init(width: 640, height: 560),
             ReportContentView(summary: scoreReport, coaching: nil, talkPercentMe: nil,
                               receipts: meeting.receiptIndex, template: interview?.reportTemplate)
                .padding(Theme.Metrics.pad).background(Theme.Colors.canvas))
        meeting.status = .done
        shot("rewrite-report.png", size: .init(width: 460, height: 330),
             RewriteReportSheet(meeting: meeting).environment(rm).modelContainer(container))
        if let salesProfile {
            shot("profile-export.png", size: .init(width: 480, height: 420),
                 ProfileExportSheet(profile: salesProfile))
            var suggested = (try? ProfileFile.decode(ProfileFile.encode(salesProfile)))!
            suggested.profile.persona = salesProfile.persona.replacingOccurrences(of: "authority", with: "who signs")
            suggested.profile.kinds.removeAll { $0.key == "opportunity" }
            suggested.profile.kinds.append(.init(key: "decision_maker", label: "Decision-maker", color: "3F9168",
                                                 icon: "person.fill", trigger: "Who signs the deal came up.", pinned: false, priority: 0))
            suggested.suggestion = .init(targetSharedID: salesProfile.id,
                                         reason: "In your last 10 sales calls, Opportunity cards were ignored 8 times, and the report never said who signs.",
                                         from: "claude-ai")
            let item = PendingProfile(data: suggested.data(), origin: .suggestion(URL(fileURLWithPath: "/dev/null")))
            shot("profile-review.png", size: .init(width: 560, height: 680),
                 ProfileReviewView(item: item) {}.environment(rm.profileStore).environment(rm).modelContainer(container))
            shot("profile-suggestion-banner.png", size: .init(width: 680, height: 70),
                 ProfileSuggestionBanner(item: item, profiles: profiles, review: {}, later: {}).padding(8))
        }

        print("help-shots: wrote \(made.count) → \(dir.path)")
        exit(made.count >= 12 ? 0 : 1)
    }

    /// Real-window offscreen render: lay out, pump the runloop so SwiftUI
    /// settles (Forms, Lists, async images), then cache the bitmap.
    @MainActor
    private static func windowRender(_ view: some View, size: NSSize, to path: String) -> Bool {
        // The sharpest screen sets the bitmap scale, so a 1x main monitor
        // doesn't halve the guide's pictures.
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false,
            screen: NSScreen.screens.max { $0.backingScaleFactor < $1.backingScaleFactor })
        window.colorSpace = .sRGB
        // `--dark` renders the same shots in dark mode, for checking a PR; the
        // user guide ships the light set.
        let dark = ProcessInfo.processInfo.arguments.contains("--dark")
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        // The bitmap cache skips the window's own background, so dark shots
        // paint it explicitly (light ones keep the white the guide ships with).
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .background(dark ? Theme.Colors.panel : .clear))
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
/// LIVELOOP_IMPORT=1 runs the audio-file import path instead. LIVELOOP_LANG=en
/// pins the language (with REALTIME: watch the mismatch switch fire). For idle-noise
/// work: PARROT_LOOP_TRACE=1 prints each clip's voice score, and
/// PARROT_VAD_THRESHOLD=0 turns the voice gate off for an A/B.
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
            // LIVELOOP_LANG=en pins the language, to watch the live mismatch
            // check fire and the switch take effect mid-feed (use REALTIME).
            if let lang = ProcessInfo.processInfo.environment["LIVELOOP_LANG"] {
                UserDefaults.standard.register(defaults: [TranscriptionLanguage.defaultsKey: lang])
            }
            let engine = TranscriptionEngine()
            await engine.loadModel(model.isEmpty ? "base" : model)
            guard engine.isReady else { print("liveloop-test: model failed to load"); exit(1) }
            await engine.loadSpeechDetector()  // the app loads it in the background

            // LIVELOOP_IMPORT=1: the audio-file import path instead of the live
            // loop (whole-file decode + the no-voice line filter).
            if ProcessInfo.processInfo.environment["LIVELOOP_IMPORT"] != nil {
                let results = (try? await engine.transcribeFile(url: URL(fileURLWithPath: audioPath))) ?? []
                print("=== import-test — \(results.count) segment(s) ===")
                for r in results { print(String(format: "[%6.2f – %6.2f] %@", r.startTime, r.endTime, r.text)) }
                exit(0)
            }

            var emitted: [(text: String, start: TimeInterval, end: TimeInterval, who: String)] = []
            engine.onSegment = { r in emitted.append((r.text, r.startTime, r.endTime, r.source.label)) }
            // A Parakeet rewind replaces lines, as RecordingManager does in the app.
            // ponytail: one side's rewind may drop the other side's lines in its range.
            engine.onReplace = { _, range, results in
                emitted.removeAll { range.contains($0.start) }
                emitted += results.map { ($0.text, $0.startTime, $0.endTime, $0.source.label) }
                emitted.sort { $0.start < $1.start }
            }

            let samples: [Float]
            do { samples = try loadSamples16k(path: audioPath) } catch {
                print("liveloop-test: audio load failed — \(error)"); exit(1)
            }
            print("liveloop-test: \(samples.count) samples (\(String(format: "%.1f", Double(samples.count) / 16000))s)")
            // LIVELOOP_MIC=<file> feeds a second track as Me, in step with the
            // first (Them): a recorded call's mic and system tracks, to see the
            // echo gate and the bleed dedupe work in the real loop.
            var mic: [Float] = []
            if let micPath = ProcessInfo.processInfo.environment["LIVELOOP_MIC"] {
                do { mic = try loadSamples16k(path: micPath) } catch {
                    print("liveloop-test: mic load failed — \(error)"); exit(1)
                }
            }

            engine.startTranscribing(meetingStartTime: .now)
            let realtime = ProcessInfo.processInfo.environment["LIVELOOP_REALTIME"] != nil
            let slice = 3200  // 200 ms, the ballpark capture delivers
            var i = 0
            while i < max(samples.count, mic.count) {
                let end = min(i + slice, samples.count)
                if i < end { engine.appendAudio(pcmBuffer(Array(samples[i..<end])), source: .them) }
                if i < mic.count { engine.appendAudio(pcmBuffer(Array(mic[i..<min(i + slice, mic.count)])), source: .me) }
                // LIVELOOP_NOSWITCH=1 leaves the banner unanswered (keeps a pin).
                if let heard = engine.languageMismatch, ProcessInfo.processInfo.environment["LIVELOOP_NOSWITCH"] == nil {
                    print(String(format: "liveloop-test: at %.1fs heard %@, switching", Double(end) / 16000, heard))
                    engine.switchLanguage(to: heard)
                }
                if realtime { try? await Task.sleep(for: .milliseconds(200)) }
                i += slice
            }
            await engine.stopTranscribing()  // drain the tail
            try? await Task.sleep(for: .seconds(0.5))  // let queued onSegment hops land

            print("=== liveloop-test — \(emitted.count) segment(s) ===")
            for seg in emitted {
                print(String(format: "[%6.2f – %6.2f] %@%@", seg.start, seg.end, mic.isEmpty ? "" : seg.who + ": ", seg.text))
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
            // The Jev fast path's excerpt card: shown within a second of the
            // question, replaced when Haiku's grounded card lands.
            Insight(kindKey: Insight.docExcerptKind, title: "\u{201C}How much is the express verification\u{201D}",
                    detail: "12.3 The Launchese paid route\nLaunchese Ltd, as ACSP AP020671, verifies identity and files the verification with Companies House. Standard: £50 per person, completed within one week of receiving all documents. Express: £99 per person, completed the same working day once all documents are in. One-off payments in pounds. Both include filing with Companies House. Nothing renews. No VAT is added.",
                    callTime: 761, source: "pricing.md"),
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
            meSeconds: 87, themSeconds: 60,
            brief: "Renewal call with Northwind. Legal wants to know where the data is stored."
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
            PinnedBlockerRow(insight: insights[5], startExpanded: true, onHandled: {}, onJump: {})
            InsightCard(insight: insights[1], kindStyle: kindStyle(insights[1]),
                        isCollapsed: false, onToggleCollapse: {}, onJump: {}, onDismiss: {})
            InsightCard(insight: insights[2], kindStyle: kindStyle(insights[2]),
                        isCollapsed: true, onToggleCollapse: {}, onJump: {}, onDismiss: {})
            InsightCard(insight: insights[3], kindStyle: kindStyle(insights[3]),
                        isCollapsed: false, onToggleCollapse: {}, onJump: {}, onDismiss: {})
            InsightCard(insight: insights[4], kindStyle: kindStyle(insights[4]),
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

        // The "Briefed" card open: what the panel shows before the first insight lands.
        rm.callAnalysisEngine.seedForSnapshot(
            profile: profile, insights: [], sentiment: [:], read: nil, coach: nil,
            meSeconds: 0, themSeconds: 0,
            brief: "Renewal call with Northwind. Legal wants to know where the data is stored.")
        let briefed = render(
            CopilotPanelView(transcriptJumpTarget: .constant(nil)).environment(rm).frame(width: 420, height: 460),
            dark: false, to: (path as NSString).deletingPathExtension + "-briefed.png")

        FileHandle.standardError.write(Data("copilot-snapshot: wrote \(light.path) + \(dark.path) + \(rows.path) + \(legendURL.path) + \(bubblesURL.path) + \(briefed.path)\n".utf8))
        exit(0)
    }

    // MARK: - Card-system legend

    /// A one-image guide to the live panel: the four zones plus every card kind
    /// of the given profile, drawn with the app's real colors and icons.
    private static func legend(profile: CallProfile?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Parrot Assistant: what each card means")
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
///   [ANALYZE_TRANSCRIPT=file] Parrot --analyze-test [claude|ollama|custom] [model]
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

        // ANALYZE_REPORT=all (or a profile name): write each built-in's report
        // instead of a live pass, to check a model can follow the templates.
        if let which = ProcessInfo.processInfo.environment["ANALYZE_REPORT"] {
            if let provider { UserDefaults.standard.register(defaults: ["reportsProvider": provider]) }
            exit(ReportEval.run(which))
        }

        let profile = ProfilePresets.all().first { $0.name == "Sales discovery" }
        // ANALYZE_TRANSCRIPT=<file> swaps in your own call (e.g. named speakers).
        let transcript = ProcessInfo.processInfo.environment["ANALYZE_TRANSCRIPT"]
            .flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? """
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

/// `ANALYZE_REPORT=all Parrot --analyze-test ollama gemma3:4b`: every
/// built-in writes its report (and coaching, when on) for a short made-up
/// call. Prints each report, then whether every section title came back,
/// the promises found, and how many bullets carry a real receipt.
/// Exits non-zero when a template's sections don't all come back.
enum ReportEval {
    static let calls: [String: String] = [
        "Sales discovery": """
        [00:05] Me: Thanks for making time. What made you look at new tools this quarter?
        [00:14] Them: Our reps spend hours logging calls by hand, and half the notes never reach the CRM.
        [00:32] Me: How much time are we talking about per rep?
        [00:40] Them: Maybe five hours a week each, and we have twelve reps.
        [01:02] Me: Is there budget set aside for this?
        [01:10] Them: We have about twenty thousand for the year, but finance wants to see a payback case first.
        [01:35] Me: Who else weighs in on the decision?
        [01:42] Them: Our VP of Sales, Dana, signs off, and IT has to approve anything that touches customer data.
        [02:05] Them: Honestly your price looks high next to the tool we use now.
        [02:20] Me: Fair. Most teams earn it back in two months from saved rep time. I can show you the numbers.
        [02:40] Them: We'd want something live before the new quarter starts in January.
        [03:01] Me: I'll send you a payback sheet by Friday and set up a call with Dana next week.
        [03:12] Them: Great, and I'll ask IT for their security checklist.
        """,
        "Interview": """
        [00:02] Me: Today I want to cover your pipeline work, teamwork, streaming, and on-call.
        [00:08] Me: Thanks for coming in, Jordan. Tell me about a data pipeline you built.
        [00:15] Them: At Acme I rebuilt our nightly import so it ran in twenty minutes instead of three hours.
        [00:40] Me: What did you change?
        [00:46] Them: We moved from one big job to small batches and added retries, and I wrote the monitoring myself.
        [01:20] Me: How do you handle a disagreement with a teammate on design?
        [01:28] Them: I write down both options with the tradeoffs and we pick together. Sometimes I'm too quick to defend my own idea, though.
        [02:05] Me: Have you worked with streaming systems?
        [02:12] Them: Not in production, only side projects.
        [02:40] Me: We'll get back to you by Wednesday with next steps.
        [02:48] Them: Thanks. I'll send over the code sample you asked for tonight.
        """,
        "Customer support": """
        [00:03] Me: Hi, thanks for calling Acme support. What's going on?
        [00:08] Them: Our invoices stopped syncing to the accounting system since Monday.
        [00:20] Me: Sorry about that. Did anything change on your side on Monday?
        [00:27] Them: We rotated our API keys. Could that be it?
        [00:35] Me: That's likely. The sync still uses the old key. Yes, it's failing with an auth error.
        [01:02] Me: I've updated the connection with your new key. Can you check the last invoice?
        [01:15] Them: It's there now. But the invoices from Monday and Tuesday are still missing.
        [01:30] Me: I'll run a backfill for those two days tonight and email you when it's done.
        [01:42] Them: Okay. I was pretty annoyed this morning, but this helps a lot. Thanks.
        """,
        "1:1 coaching": """
        [00:05] Me: How has the week been?
        [00:09] Them: Good overall. I shipped the onboarding redesign and the numbers look better already.
        [00:25] Me: That's great. What's been harder?
        [00:30] Them: The Northwind integration is stuck. I'm waiting on their team for API access and it's been two weeks.
        [00:55] Them: I'm also a bit worried about the reorg and what it means for my team.
        [01:20] Me: I'll ask Alex about the reorg timeline and tell you what I learn by Thursday.
        [01:35] Them: Thanks. I'll email Northwind's lead directly today to push for access.
        [01:50] Me: And let's talk about your conference talk next time.
        """,
        "Vendor call": """
        [00:04] Them: Thanks for considering Acme Payments. Our standard rate is 1.4 percent plus 20 cents per card payment.
        [00:18] Me: Are there monthly fees on top?
        [00:23] Them: There's a 25 dollar monthly platform fee, waived for the first three months.
        [00:40] Me: How fast do payouts reach our bank?
        [00:45] Them: Two business days, but new accounts have a 7 day rolling reserve for the first 90 days.
        [01:05] Me: What happens if we want to leave?
        [01:10] Them: The contract is 12 months, and there's an early exit fee. I'd have to check the exact amount.
        [01:30] Me: Do you support refunds in euros?
        [01:36] Them: Good question, let me come back to you on that.
        [01:50] Them: I'll send the contract draft and our security documents by Monday.
        [02:00] Me: Great, I'll review it with our finance lead, Mara, next week.
        """,
        "Investor pitch": """
        [00:05] Me: We help small clinics cut no-shows with automatic reminders. We're at 40 thousand in monthly revenue, growing 12 percent a month.
        [00:25] Them: I like that growth. What does churn look like?
        [00:32] Me: About 2 percent monthly, mostly very small clinics.
        [00:45] Them: My worry is the market. Isn't this a feature the big practice software will just add?
        [01:05] Me: They've had years to do it. Our edge is the integrations with 30 booking systems.
        [01:25] Them: What are you raising?
        [01:30] Me: Two million, and we have a lead for half of it.
        [01:40] Them: We usually write checks of 500 thousand at seed, so that could fit.
        [01:55] Them: Can you send me your cohort data and an intro to two customers?
        [02:10] Me: Yes, I'll send both by Wednesday.
        [02:18] Them: Then I'll bring it to our partner meeting on Monday.
        """,
    ]

    /// The receipts index for a fixture: each line runs until the next.
    static func index(_ transcript: String) -> ReceiptIndex {
        let rows = transcript.components(separatedBy: "\n").compactMap { line -> (TimeInterval, String, String)? in
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]"),
                  let t = Receipts.parseStamp(String(line[line.index(after: line.startIndex)..<close])) else { return nil }
            let rest = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
            let parts = rest.split(separator: ":", maxSplits: 1).map(String.init)
            return (t, parts.first ?? "", parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : "")
        }
        return ReceiptIndex(lines: rows.enumerated().map { i, r in
            .init(start: r.0, end: i + 1 < rows.count ? rows[i + 1].0 : r.0 + 5, speaker: r.1, text: r.2)
        })
    }

    static func run(_ which: String) -> Int32 {
        let profiles = ProfilePresets.all().filter { which == "all" || $0.name == which }
        guard !profiles.isEmpty else { print("report-eval: no built-in named \(which)"); return 1 }
        var failed = 0
        var done = false
        // Parsing is main-actor work, so spin the main run loop, don't block it.
        Task { @MainActor in
            let provider = SwitchingAnalysisProvider()
            for p in profiles {
                let template = p.reportTemplate
                let transcript = calls[p.name] ?? calls["Sales discovery"]!
                let idx = index(transcript)
                print("\n=== \(p.name) · \(CopilotProviderKind.modelName(for: SwitchingAnalysisProvider.reportsKind))")
                let start = Date()
                do {
                    let summary = try await provider.summarize(transcript: transcript, insightTitles: [], bookmarks: [],
                                                               instructions: p.tone, counterpart: p.counterpart, template: template)
                    var coaching: String?
                    if template.coachingEnabled {
                        coaching = try await provider.coachingReport(transcript: transcript, talkPercentMe: 45, instructions: p.tone,
                                                                     counterpart: p.counterpart, template: template)
                    }
                    print(summary)
                    if let coaching { print("--- coaching\n\(coaching)") }
                    let got = ReportProse.sections(from: summary, template: template).compactMap(\.title)
                    let want = template.isStandard ? ["Pain points", "Key points"] : template.titles
                    let missing = want.filter { w in !got.contains { $0.caseInsensitiveCompare(w) == .orderedSame } }
                    let bullets = ReportProse.sections(from: summary, template: template).flatMap(\.blocks).compactMap { b -> String? in
                        if case .bullet(let t, _) = b { return t } else { return nil }
                    }.filter { !Receipts.isPlaceholder(Receipts.extract($0).text) }
                    let cited = bullets.filter { !idx.verified(Receipts.extract($0).times).isEmpty }.count
                    let promises = LastCallBrief.openItems(summary: summary, coaching: coaching, template: template, limit: 20)
                    let parsed = ReportProse.sections(from: summary, template: template)
                    let scores = template.sections.filter { $0.type == "scorecard" }.map { card -> String in
                        let blocks = parsed.first { $0.title.map { template.section(titled: $0)?.key == card.key } == true }?.blocks ?? []
                        let rows = Scorecard.rows(from: blocks.map(\.raw), criteria: card.criteria ?? [], receipts: idx).rows
                        return ", scores \(rows.filter { $0.score != nil }.count)/\(rows.count)"
                    }.joined()
                    let coachOK = coaching.map { $0.lowercased().contains("what went well") } ?? true
                    let secs = String(format: "%.0f", Date().timeIntervalSince(start))
                    print("--- \(missing.isEmpty && coachOK ? "OK" : "MISS") \(p.name): sections \(want.count - missing.count)/\(want.count)"
                          + (missing.isEmpty ? "" : " missing \(missing)") + ", receipts \(cited)/\(bullets.count)"
                          + ", promises \(promises.count)\(scores), coaching \(template.coachingEnabled ? (coachOK ? "ok" : "BAD") : "off"), \(secs)s")
                    if !missing.isEmpty || !coachOK { failed += 1 }
                } catch {
                    print("--- FAILED \(p.name): \(error.localizedDescription)")
                    failed += 1
                }
            }
            done = true
        }
        while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
        print("\nreport-eval: \(profiles.count - failed)/\(profiles.count) templates followed")
        return failed == 0 ? 0 : 1
    }
}

/// `Parrot --store-upgrade-test <file.store>`: opens a store written by an
/// older Parrot (a copy, never the live one) the way this version would.
/// First read-only, like the MCP server before the app has run; then
/// read-write with the Profiles 2.0 migration, using throwaway settings and
/// a throwaway backup folder. Prints PASS/FAIL; exits non-zero on a FAIL.
enum StoreUpgradeTest {
    @MainActor
    static func run(path: String) {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: path)
        var failures = 0
        func check(_ name: String, _ ok: Bool) { print((ok ? "PASS " : "FAIL ") + name); if !ok { failures += 1 } }
        let schema = Schema([Meeting.self, TranscriptSegment.self, CallInsight.self, CallProfile.self, SpeakerProfile.self])

        // 1. Read-only, on a copy (SQLite keeps -wal/-shm beside the file).
        let ro = url.deletingLastPathComponent().appendingPathComponent("readonly-" + url.lastPathComponent)
        for suffix in ["", "-wal", "-shm"] {
            let from = URL(fileURLWithPath: path + suffix), to = URL(fileURLWithPath: ro.path + suffix)
            try? fm.removeItem(at: to)
            if fm.fileExists(atPath: from.path) { try? fm.copyItem(at: from, to: to) }
        }
        let readOnly = try? ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: ro, allowsSave: false)])
        let roMeetings = readOnly.flatMap { try? ModelContext($0).fetch(FetchDescriptor<Meeting>()) }
        print("read-only open (MCP before the app runs): \(readOnly == nil ? "fails" : "opens"), meetings \(roMeetings?.count ?? -1)")

        // 2. The app: read-write, then the migration.
        guard let container = try? ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url)]) else {
            check("store opens with the new schema", false); exit(1)
        }
        check("store opens with the new schema", true)
        let ctx = ModelContext(container)
        let before = (try? ctx.fetch(FetchDescriptor<CallProfile>())) ?? []
        let meetingsBefore = (try? ctx.fetch(FetchDescriptor<Meeting>())) ?? []
        let copilot = Dictionary(uniqueKeysWithValues: before.map { ($0.id, [$0.persona, $0.tone, $0.counterpart]
            + [$0.kindsData.base64EncodedString(), $0.gaugesData.base64EncodedString(), "\($0.onDeviceOnly)"]) })
        let summaries = Dictionary(uniqueKeysWithValues: meetingsBefore.map { ($0.id, $0.summary ?? "") })
        check("old rows read with the new fields defaulted",
              before.allSatisfy { $0.reportChoice == .classic && $0.sharedID == nil && $0.versions.isEmpty })

        let suite = "parrot.test.store-upgrade"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let backups = fm.temporaryDirectory.appendingPathComponent("parrot-upgrade-\(UUID().uuidString)")
        defer { defaults.removePersistentDomain(forName: suite); try? fm.removeItem(at: backups) }
        let store = ProfileStore()
        store.defaults = defaults
        store.backupFolder = backups
        store.seedAndMigrateIfNeeded(context: ctx, knowledgeBase: KnowledgeBaseService(persistent: false))

        let after = (try? ctx.fetch(FetchDescriptor<CallProfile>())) ?? []
        check("migration ran and the screen is due", defaults.bool(forKey: ProfileStore.migrationDoneKey) && store.showProfiles2Screen)
        check("a backup per profile", ((try? fm.contentsOfDirectory(atPath: backups.path))?.count ?? 0) == before.count)
        check("Copilot fields unchanged on every old profile", before.allSatisfy { p in
            let now = [p.persona, p.tone, p.counterpart, p.kindsData.base64EncodedString(), p.gaugesData.base64EncodedString(), "\(p.onDeviceOnly)"]
            return copilot[p.id] == now || (p.isBuiltIn && !p.isUserModified) })
        check("tuned built-ins keep their Copilot settings exactly",
              before.filter { $0.isBuiltIn && $0.isUserModified }.allSatisfy { p in
                  copilot[p.id] == [p.persona, p.tone, p.counterpart, p.kindsData.base64EncodedString(),
                                    p.gaugesData.base64EncodedString(), "\(p.onDeviceOnly)"] })
        check("new built-ins added", after.count >= before.count && after.contains { $0.name == "Investor pitch" })
        check("meetings untouched", ((try? ctx.fetch(FetchDescriptor<Meeting>())) ?? []).allSatisfy {
            summaries[$0.id] == ($0.summary ?? "") && $0.reportTemplateData == nil })
        for p in after.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            print("  \(p.name) | \(p.isBuiltIn ? "built-in" : "yours")\(p.isUserModified ? ", tuned" : "") | report \(p.reportChoiceRaw)"
                  + (p.reportOfferPending ? " + offer" : "") + " | versions \(p.versions.count)")
        }

        // 3. It stuck: a fresh container on the same file sees the new state.
        let choices = Dictionary(uniqueKeysWithValues: after.map { ($0.id, $0.reportChoiceRaw) })
        let reopened = (try? ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url)]))
            .flatMap { try? ModelContext($0).fetch(FetchDescriptor<CallProfile>()) } ?? []
        check("the migration is saved to disk", !reopened.isEmpty
              && reopened.allSatisfy { choices[$0.id] == $0.reportChoiceRaw && $0.sharedID != nil })
        print(failures == 0 ? "ALL PASS" : "FAILURES: \(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}

/// Dev only: Ask Parrot against the user's REAL meetings, read-only, for
/// testing answer quality. Run from the signed bundle (the sandbox gives it
/// the container): questions come from a file, one per line; a blank line
/// starts a new chat; "@scope: <title words>" limits the next chat to the
/// first meeting whose title contains those words. Chats are not saved.
///   dist/Parrot.app/Contents/MacOS/Parrot --ask-real <claude|ollama> <questions-file> [model]
@MainActor
enum AskRealTest {
    static func run(provider: String, path: String, model: String?) {
        // The argument domain beats the app's saved settings (register(defaults:)
        // would lose to an Ask AI the user picked in the app), and is never saved.
        var overrides: [String: Any] = ["askProvider": provider]
        if let model { overrides["copilotOllamaModel"] = model }
        UserDefaults.standard.setVolatileDomain(overrides, forName: UserDefaults.argumentDomain)
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            print("ask-real: cannot read \(path)"); exit(1)
        }
        let schema = Schema([Meeting.self, TranscriptSegment.self, CallInsight.self, CallProfile.self, SpeakerProfile.self])
        guard let container = try? ModelContainer(
            for: schema, configurations: [ModelConfiguration(schema: schema, allowsSave: false)]
        ) else { print("ask-real: store failed (open Parrot once so it migrates)"); exit(1) }
        let context = container.mainContext
        let rm = RecordingManager(chats: AskChatStore(directory: nil))
        rm.attachForHarness(modelContext: context)
        let meetings = (try? context.fetch(FetchDescriptor<Meeting>())) ?? []

        // Chats: split on blank lines; "@scope:" picks a meeting.
        var chats: [(scope: Meeting?, questions: [String])] = [(nil, [])]
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if !(chats.last?.questions.isEmpty ?? true) { chats.append((nil, [])) }
            } else if line.lowercased().hasPrefix("@scope:") {
                let words = line.dropFirst(7).trimmingCharacters(in: .whitespaces).lowercased()
                chats[chats.count - 1].scope = meetings.first { $0.title.lowercased().contains(words) }
            } else {
                chats[chats.count - 1].questions.append(line)
            }
        }

        Task { @MainActor in
            print("ask-real: \(meetings.count) meetings, AI = \(provider)\(model.map { " " + $0 } ?? "")")
            for (n, spec) in chats.enumerated() where !spec.questions.isEmpty {
                var chat = AskChat(title: "real \(n + 1)", scope: spec.scope?.id, scopeTitle: spec.scope?.title)
                print("\n=== CHAT \(n + 1)\(spec.scope.map { " (scope: \($0.title))" } ?? "")")
                for q in spec.questions {
                    let started = Date()
                    let result = await rm.ask(q, in: chat)
                    let secs = String(format: "%.1f", Date().timeIntervalSince(started))
                    print("\nQ: \(q)   [\(secs)s · \(result.model ?? "no AI") · private=\(result.usedPrivate)]")
                    if let s = result.searchedFor { print("   searched: \(s)") }
                    let titles = Dictionary(meetings.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
                    if !result.sources.isEmpty {
                        var seen: [String] = []
                        for c in result.sources { let t = String((titles[c.meetingID] ?? "?").prefix(24)); if !seen.contains(t) { seen.append(t) } }
                        print("   passages from: \(seen.joined(separator: " | "))")
                    }
                    let names = Dictionary(result.refs.map { ($0.meetingID, $0.title) }, uniquingKeysWith: { a, _ in a })
                    for line in result.lines {
                        let cites = line.citations.map { c in
                            String((names[c.meetingID] ?? "?").prefix(28)) + (c.time.map { " @" + Receipts.stamp($0) } ?? "")
                        }
                        print("   A: \(line.text)" + (cites.isEmpty ? "" : "  \(cites)"))
                    }
                    if let note = result.note { print("   note: \(note)") }
                    chat.messages.append(AskMessage(role: .me, text: q))
                    chat.messages.append(AskMessage(answer: result))
                }
            }
            exit(0)
        }
        RunLoop.main.run()
    }
}


/// Ask Parrot end to end on a real AI: two made-up meetings, a question,
/// then a follow-up that only makes sense with the first. Prints what was
/// searched, the answers and their citations. Nothing is saved.
///   Parrot --ask-chat-test [claude|ollama] [model]
@MainActor
enum AskChatTest {
    static func run(provider: String?, model: String?) {
        if let provider {
            UserDefaults.standard.register(defaults: ["askProvider": provider, "copilotProvider": provider])
        }
        if let model {
            UserDefaults.standard.register(defaults: ["copilotOllamaModel": model, "copilotCustomModel": model])
        }
        let schema = Schema([Meeting.self, TranscriptSegment.self, CallInsight.self, CallProfile.self, SpeakerProfile.self])
        guard let container = try? ModelContainer(
            for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        ) else { print("ask-chat-test: container failed"); exit(1) }
        let context = container.mainContext
        // Fabricated meetings must never land in the real Application
        // Support memory/chats store — use a scratch directory, wiped
        // wholesale at the end so an interrupt or crash can't leave junk
        // behind (unlike per-meeting removal, which a crash could skip).
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("ask-chat-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let rm = RecordingManager(memory: MeetingMemory(directory: scratch), chats: AskChatStore(directory: nil))
        rm.attachForHarness(modelContext: context)

        func meeting(_ title: String, daysAgo: Double, _ lines: [(TimeInterval, String, String)], summary: String) -> Meeting {
            let m = Meeting(title: title, date: Date.now.addingTimeInterval(-daysAgo * 86_400))
            context.insert(m)
            for (start, speaker, text) in lines {
                let seg = TranscriptSegment(startTime: start, endTime: start + 5, text: text, speakerLabel: speaker, confidence: nil)
                context.insert(seg)
                seg.meeting = m
            }
            m.status = .done
            m.summary = summary
            return m
        }
        let acme = meeting("Acme renewal", daysAgo: 2, [
            (12, "Sam", "Our main worry is pricing. The Enterprise plan went up twenty percent."),
            (20, "Me", "If you sign for two years, we can hold this year's price."),
            (30, "Sam", "Can you put that in writing?"),
            (36, "Me", "Yes, I'll send the revised contract by Friday."),
        ], summary: "Acme pushed back on the 20% Enterprise price rise. We offered a two-year price lock.")
        let globex = meeting("Globex hiring sync", daysAgo: 1, [
            (8, "Ana", "We need two backend engineers before March."),
            (15, "Me", "I'll share the job description on Monday."),
        ], summary: "Globex needs two backend engineers by March.")
        try? context.save()

        Task { @MainActor in
            for m in [acme, globex] { await rm.memory.index(m) }
            var chat = AskChat(title: "Harness", scope: nil, scopeTitle: nil)
            for q in ["What did Acme push back on?", "And what did we offer them?", "What did I promise this week?",
                      "How many meetings did I have this week?"] {
                let started = Date()
                let result = await rm.ask(q, in: chat)
                let secs = String(format: "%.1f", Date().timeIntervalSince(started))
                print("\nQ: \(q)  [\(secs)s · \(result.model ?? "no AI")]")
                if let s = result.searchedFor { print("   searched: \(s)") }
                for line in result.lines {
                    let cites = line.citations.map { c in
                        (c.meetingID == acme.id ? "Acme" : "Globex") + (c.time.map { " " + Receipts.stamp($0) } ?? "")
                    }
                    print("   A: \(line.text)  \(cites)")
                }
                if let note = result.note { print("   note: \(note)") }
                chat.messages.append(AskMessage(role: .me, text: q))
                chat.messages.append(AskMessage(answer: result))
            }
            try? FileManager.default.removeItem(at: scratch)
            exit(0)
        }
        RunLoop.main.run()
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

            ReportContentView(summary: sampleSummary, coaching: sampleCoaching, talkPercentMe: 29,
                              receipts: sampleReceipts, template: nil)
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
    - Timeout reframed as a 12-minute "regulation corner" (not punishment) [08:12]
    - Parent struggles with emotion-naming; clinician modelled how to validate Alex's feelings during disappointment
    - Selective ignoring introduced for attention-seeking behaviours like monster sounds (10–15 minutes max) [27:40, 29:05]

    Next steps:
    - Review handouts 20–23 and create a calm-down menu with Alex [44:18]
    - Practise emotion-naming in calm, positive moments first
    - Confirm online vs in-person for next week before end of workday [47:02]
    """

    /// Transcript lines the sample stamps point at. "[47:02]" and "[52:40]"
    /// deliberately have no line, so the render shows an unverified promise
    /// and an invented stamp dropped.
    static let sampleReceipts = ReceiptIndex(lines: [
        .init(start: 492, end: 500, speaker: "NHS Advisor", text: "Let's call it a regulation corner, twelve minutes, not a punishment."),
        .init(start: 1155, end: 1163, speaker: "Me", text: "Honestly I feel awful when I raise my voice at him."),
        .init(start: 1660, end: 1668, speaker: "NHS Advisor", text: "Ignore the monster sounds, ten to fifteen minutes at most."),
        .init(start: 1745, end: 1750, speaker: "NHS Advisor", text: "If it escalates, step in calmly."),
        .init(start: 2658, end: 2665, speaker: "Me", text: "I'll read handouts twenty to twenty-three and make the menu with Alex."),
    ])

    static let sampleCoaching = """
    Call snapshot: Parenting coaching session on managing a child's behaviour — Me spoke 29%, Them 71%. Heavy teaching call with good engagement.

    What went well:
    - Acknowledged gaps in his own skills directly and asked for examples instead of deflecting
    - Strong vulnerability when sharing guilt over raising his voice, which built trust [19:15]
    - Took notes on handouts and committed to specific follow-ups

    What to improve:
    - Didn't fully grasp praising effort vs naming emotion — could have asked a clarifying question earlier
    - Drifted into a 3-minute tech tangent near the end when time was tight

    Commitments & follow-ups:
    - Read handouts 20, 21, 22, 23 before the next meeting [44:18]
    - Create a calm-down menu and report back on which skills Alex likes [52:40]
    """
}
