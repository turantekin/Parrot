import AppKit
import ScreenCaptureKit
import SwiftData
import SwiftUI

/// `Parrot --nudge-replay [meeting-id-prefix] [--store path]`: replays saved calls (default:
/// the newest) through the live nudge rules second by second and prints every
/// nudge with its time and whether it would have shown. For tuning
/// `NudgeDetector.Tuning` on real calls. Works on a copy of the store: the
/// real one may be on an older schema, and migrating it here would change
/// the file the installed app opens. Unanswered
/// question and wrap-up can't replay (open cards and the wrap-up flag aren't
/// saved); mood shift replays from the saved mood line.
@MainActor
enum NudgeReplay {
    static func run(args: [String]) {
        let schema = Schema([Meeting.self, TranscriptSegment.self, CallInsight.self, CallProfile.self, SpeakerProfile.self])
        let fm = FileManager.default
        // The app is sandboxed: its store lives in its container, which macOS
        // may ask permission to read. `--store` points anywhere else.
        var rest = args
        var source = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.uygar.parrot/Data/Library/Application Support/default.store")
        if let i = rest.firstIndex(of: "--store"), i + 1 < rest.count {
            source = URL(fileURLWithPath: rest[i + 1])
            rest.removeSubrange(i...(i + 1))
        }
        let scratch = fm.temporaryDirectory.appendingPathComponent("parrot-nudge-replay", isDirectory: true)
        try? fm.removeItem(at: scratch)
        try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        let copy = scratch.appendingPathComponent(source.lastPathComponent)
        for suffix in ["", "-wal", "-shm"] {
            let from = URL(fileURLWithPath: source.path + suffix)
            if fm.fileExists(atPath: from.path) { try? fm.copyItem(at: from, to: URL(fileURLWithPath: copy.path + suffix)) }
        }
        guard let container = try? ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: copy)]) else {
            print("nudge-replay: can't open a copy of the store")
            exit(1)
        }
        let all = (try? ModelContext(container).fetch(FetchDescriptor<Meeting>(sortBy: [SortDescriptor(\.date, order: .reverse)]))) ?? []
        let picked = rest.first.map { prefix in
            all.filter { $0.id.uuidString.lowercased().hasPrefix(prefix.lowercased()) }
        } ?? Array(all.prefix(1))
        guard !picked.isEmpty else {
            try? fm.removeItem(at: scratch)
            print("nudge-replay: no matching meeting in \(source.path)")
            exit(1)
        }
        for meeting in picked {
            let lines = meeting.sortedSegments.map {
                NudgeDetector.Line(source: $0.speakerLabel == "Me" ? .me : .them,
                                   start: $0.startTime, end: $0.endTime, text: $0.text)
            }
            let nudges = replay(lines: lines, timeline: meeting.moodTimeline, duration: meeting.duration)
            print("\(meeting.title) (\(meeting.id.uuidString.prefix(8))) · \(Receipts.stamp(meeting.duration)) · \(lines.count) lines · \(nudges.count) nudges")
            for n in nudges {
                print("  [\(Receipts.stamp(n.time))] \(n.shown ? "shown" : "held ") \(n.kind.rawValue): \(n.text)")
            }
        }
        try? fm.removeItem(at: scratch)
        exit(0)
    }

    /// Lines arrive 1 s after they end (decode time); a track counts as heard
    /// while one of its lines is in progress.
    static func replay(lines: [NudgeDetector.Line], timeline: MoodTimeline?, duration: TimeInterval) -> [Nudge] {
        var detector = NudgeDetector(gauges: timeline?.gauges ?? [])
        var waiting = lines.sorted { $0.end < $1.end }
        var passes = timeline?.snapshots ?? []
        var heard: [AudioSource: TimeInterval] = [:]
        let end = max(duration, lines.map(\.end).max() ?? 0) + 30
        var t: TimeInterval = 0
        while t <= end {
            while let line = waiting.first, line.end + 1 <= t {
                detector.add(line)
                waiting.removeFirst()
            }
            while let pass = passes.first, pass.time <= t {
                detector.add(NudgeDetector.Pass(time: pass.time, values: pass.values))
                passes.removeFirst()
            }
            for line in lines where line.start <= t && line.end >= t - 1 {
                heard[line.source] = max(heard[line.source] ?? 0, min(t, line.end))
            }
            _ = detector.tick(now: t, lastHeard: heard)
            t += 1
        }
        return detector.all
    }
}

/// `Parrot --tone-snapshot /tmp/tone.png`: renders the report card (with and
/// without a mood line), the pill and the banner, light and dark ("-dark").
@MainActor
enum ToneSnapshot {
    static func write(to path: String) {
        let gauge = SentimentGauge(id: UUID(), key: "buying_temperature", label: "Buying temp",
                                   lowLabel: "Cold", highLabel: "Hot", colorHex: "E8943A")
        var spans: [ToneTimeline.Span] = []
        var t: TimeInterval = 0
        while t < 1920 {
            spans.append(.init(isMe: true, start: t, end: t + 20, text: "you talk here"))
            spans.append(.init(isMe: false, start: t + 22, end: t + 40, text: "they answer here"))
            t += 45
        }
        spans.append(.init(isMe: true, start: 755, end: 762, text: "the price goes up in January"))
        let mood = [(0, 50), (240, 55), (480, 60), (720, 62), (780, 36), (900, 30), (1140, 38),
                    (1265, 62), (1500, 70), (1740, 66), (1920, 75)]
            .map { MoodSnapshot(time: TimeInterval($0.0), values: [gauge.key: $0.1]) }
        let nudges = [
            Nudge(kind: .longMonologue, time: 250, text: "You've been talking for 2 minutes. Check in?"),
            Nudge(kind: .goneQuiet, time: 755,
                  text: "They've gone quiet since you said \u{201C}the price goes up in January\u{201D}"),
            Nudge(kind: .talkingOver, time: 1590, text: "You've talked over them 3 times. Let them finish", shown: false),
        ]
        guard let withMood = ToneTimeline.model(duration: 1920, spans: spans, nudges: nudges,
                                                timeline: MoodTimeline(gauges: [gauge], snapshots: mood), marks: []),
              let plain = ToneTimeline.model(duration: 1920, spans: spans, nudges: Array(nudges.prefix(2)), timeline: nil,
                                             marks: [Bookmark(time: 1300, label: "pilot offer")]) else {
            FileHandle.standardError.write(Data("tone-snapshot: no model\n".utf8))
            exit(1)
        }
        let view = VStack(alignment: .leading, spacing: 16) {
            NudgePillView(nudge: nudges[1])
            NudgeBanner(nudge: nudges[1], onDismiss: {}).frame(width: 420)
            ToneTimelineCard(model: withMood, play: { _ in })
            ToneTimelineCard(model: plain, play: nil)
        }
        .padding(20)
        .frame(width: 720)
        .background(Theme.Colors.panel)
        let light = render(view, dark: false, to: path)
        let dark = render(view, dark: true, to: (path as NSString).deletingPathExtension + "-dark.png")
        FileHandle.standardError.write(Data("tone-snapshot: wrote \(light.path) + \(dark.path)\n".utf8))
        exit(0)
    }

    private static func render(_ view: some View, dark: Bool, to path: String) -> URL {
        let renderer = ImageRenderer(content: AnyView(view.environment(\.colorScheme, dark ? .dark : .light)))
        renderer.scale = 2
        var cg: CGImage?
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance { cg = renderer.cgImage }
        guard let cg, let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("tone-snapshot: render failed\n".utf8))
            exit(1)
        }
        return SnapshotIO.write(data, to: path)
    }
}

/// `Parrot --pill-test [out.png]`: shows a real nudge pill (the app's own
/// floating panel), then captures the top of the main display through
/// ScreenCaptureKit, the way Zoom and Meet share a screen, and saves that
/// strip. The pill has `sharingType = .none`, so it must not be in it. Run
/// from the signed app (`open -n -W dist/Parrot.app --args --pill-test out.png`)
/// so the capture uses Parrot's Screen Recording permission. The app is
/// sandboxed: a relative path lands in ~/Library/Containers/com.uygar.parrot/Data.
/// Proof is in the PNG: no pill here, a pill with PILL_TEST_SHARED=1.
@MainActor
enum PillTest {
    static func run(out: String?) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        NudgePillController.shared.show(Nudge(kind: .goneQuiet, time: 0,
            text: "PILL TEST: They've gone quiet since you said \u{201C}the price goes up in January\u{201D}"))
        // PILL_TEST_SHARED=1: the control run, pill made capturable on purpose.
        if ProcessInfo.processInfo.environment["PILL_TEST_SHARED"] != nil {
            for window in app.windows where window is NSPanel { window.sharingType = .readOnly }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if let out { await capture(to: out) }
            try? await Task.sleep(for: .seconds(out == nil ? 13 : 1))
            exit(0)
        }
        app.run()
    }

    private static func capture(to path: String) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
                print("pill-test: no display"); return
            }
            let config = SCStreamConfiguration()
            config.width = display.width * 2
            config.height = display.height * 2
            config.sourceRect = CGRect(x: 0, y: 0, width: display.width, height: 130)
            config.width = display.width * 2
            config.height = 260
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(display: display, excludingWindows: []), configuration: config)
            let rep = NSBitmapImageRep(cgImage: image)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            print("pill-test: captured \(path)")
        } catch {
            print("pill-test: capture failed: \(error.localizedDescription)")
        }
    }
}
