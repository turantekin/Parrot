import AppKit
import PDFKit
import SwiftData

/// `Parrot --report-pdf <out.pdf> [meeting] [--store path]`: writes a
/// meeting's Export PDF plus a PNG of every page beside it (out-1.png, …).
/// `meeting` is its id prefix or its row number in the store (167); no
/// meeting and no `--store` renders the demo call. A store is always copied
/// first: opening the real one could migrate the file the app uses.
/// `REPORT_PDF_PAPER=a4|letter` picks the paper (default: the Mac's).
@MainActor
enum ReportPDFHarness {
    static func run(args: [String]) {
        guard let out = args.first, out.hasSuffix(".pdf") else {
            print("usage: Parrot --report-pdf <out.pdf> [meeting-id-prefix | row] [--store path]")
            exit(2)
        }
        var rest = Array(args.dropFirst())
        var store: String?
        if let i = rest.firstIndex(of: "--store"), i + 1 < rest.count {
            store = rest[i + 1]
            rest.removeSubrange(i...(i + 1))
        }
        let schema = Schema([Meeting.self, TranscriptSegment.self, CallInsight.self, CallProfile.self, SpeakerProfile.self])
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("parrot-report-pdf-\(UUID().uuidString)", isDirectory: true)
        let container: ModelContainer
        let meeting: Meeting
        if store == nil && rest.isEmpty {
            guard let c = try? ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]) else {
                print("report-pdf: no in-memory store"); exit(1)
            }
            container = c
            meeting = demoMeeting(in: c.mainContext)
        } else {
            let source = URL(fileURLWithPath: store ?? fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Containers/com.uygar.parrot/Data/Library/Application Support/default.store").path)
            try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)
            let copy = scratch.appendingPathComponent(source.lastPathComponent)
            for suffix in ["", "-wal", "-shm"] where fm.fileExists(atPath: source.path + suffix) {
                try? fm.copyItem(atPath: source.path + suffix, toPath: copy.path + suffix)
            }
            guard let c = try? ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: copy)]) else {
                print("report-pdf: can't open a copy of \(source.path)"); exit(1)
            }
            container = c
            let all = (try? c.mainContext.fetch(FetchDescriptor<Meeting>(sortBy: [SortDescriptor(\.date, order: .reverse)]))) ?? []
            let pick = rest.first.flatMap { key in
                all.first { key.allSatisfy(\.isNumber) && "\($0.persistentModelID)".contains("/Meeting/p\(key)>") }
                    ?? all.first { $0.id.uuidString.lowercased().hasPrefix(key.lowercased()) }
            } ?? (rest.isEmpty ? all.first(where: ReportPDF.hasReport) : nil)
            guard let pick else { print("report-pdf: no matching meeting"); exit(1) }
            meeting = pick
        }
        let paper: NSSize = switch ProcessInfo.processInfo.environment["REPORT_PDF_PAPER"] {
        case "a4": NSSize(width: 595, height: 842)
        case "letter": NSSize(width: 612, height: 792)
        default: NSPrintInfo.shared.paperSize
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        // The bare binary has no bundle icon; the PDF's header draws the app icon.
        if let icon = NSImage(contentsOfFile: "Parrot/Assets.xcassets/AppIcon.appiconset/icon_128@2x.png") {
            app.applicationIconImage = icon
        }
        Task { @MainActor in
            defer { try? fm.removeItem(at: scratch) }
            do {
                let data = try await ReportPDF.render(html: ReportPDF.html(for: meeting), title: meeting.title, paper: paper)
                try data.write(to: URL(fileURLWithPath: out))
                let pages = PDFDocument(data: data)?.pageCount ?? 0
                for i in 0..<pages { writePNG(PDFDocument(data: data)?.page(at: i), to: "\(out.dropLast(4))-\(i + 1).png") }
                print("report-pdf: \(meeting.title) -> \(out), \(pages) page\(pages == 1 ? "" : "s"), \(Int(paper.width))x\(Int(paper.height))")
                _ = container
                try? fm.removeItem(at: scratch)
                exit(0)
            } catch {
                print("report-pdf: \(error.localizedDescription)")
                try? fm.removeItem(at: scratch)
                exit(1)
            }
        }
        app.run()
    }

    private static func writePNG(_ page: PDFPage?, to path: String) {
        guard let page else { return }
        let size = page.bounds(for: .mediaBox).size
        let image = page.thumbnail(of: NSSize(width: size.width * 2, height: size.height * 2), for: .mediaBox)
        guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }

    /// A 32-minute investor call with a scorecard, a mood line, nudges and a
    /// mark. Made-up people and numbers; safe to commit and to show.
    static func demoMeeting(in ctx: ModelContext) -> Meeting {
        let m = Meeting(title: "Northwind & Acme: seed round intro", date: Date(timeIntervalSince1970: 1_790_000_000))
        ctx.insert(m)
        m.duration = 1920
        if let profile = ProfilePresets.all().first(where: { $0.name == "Investor pitch" }) {
            ctx.insert(profile)
            m.profile = profile
            m.reportTemplateData = try? JSONEncoder().encode(profile.reportTemplate)
            if let gauge = ToneTimeline.mainGauge(profile.gauges) {
                let mood = [(0, 40), (240, 48), (480, 55), (720, 62), (780, 34), (900, 30), (1140, 41),
                            (1265, 63), (1500, 70), (1740, 74), (1920, 78)]
                m.moodTimeline = MoodTimeline(gauges: profile.gauges,
                                              snapshots: mood.map { MoodSnapshot(time: TimeInterval($0.0), values: [gauge.key: $0.1]) })
            }
        }
        m.speakerNames = ["Speaker 1": "Dana Ruiz", "Speaker 2": "Sam Lee"]
        m.notes = "Private: ask Sam about the bridge round"
        m.nudges = [
            Nudge(kind: .longMonologue, time: 250, text: "You've been talking for 2 minutes. Check in?"),
            Nudge(kind: .goneQuiet, time: 755, text: "They've gone quiet since you said \u{201C}we burn 90k a month\u{201D}"),
        ]
        m.bookmarks = [Bookmark(time: 1300, label: "pilot offer")]
        let cited: [(TimeInterval, String, String)] = [
            (95, "Speaker 1", "We like that you already have three paying pilots."),
            (330, "Speaker 1", "Our usual first check is between 500k and a million."),
            (755, "Me", "We burn about 90k a month right now."),
            (790, "Speaker 1", "That burn worries me for an 18 month runway."),
            (1020, "Speaker 1", "Can you send the cohort data by Friday?"),
            (1300, "Speaker 2", "We could join a pilot with one of our portfolio companies."),
            (1610, "Me", "I'll send the data room link and the cohort sheet tomorrow."),
            (1795, "Speaker 1", "I'll bring this to Monday's partner meeting."),
        ]
        var lines = cited
        var t: TimeInterval = 0
        while t < 1900 {
            if !cited.contains(where: { abs($0.0 - t) < 45 }) {
                lines.append((t, "Me", "Filler line from me."))
                lines.append((t + 22, t.truncatingRemainder(dividingBy: 180) == 0 ? "Speaker 2" : "Speaker 1",
                              "Filler line from them."))
            }
            t += 45
        }
        for (start, who, text) in lines {
            let seg = TranscriptSegment(startTime: start, endTime: start + 18, text: text, speakerLabel: who)
            ctx.insert(seg)
            seg.meeting = m
        }
        m.summary = """
        Overview:
        A first call with Northwind about the seed round. They liked the paid pilots, worried about burn, and want the cohort data before Monday's partner meeting.

        What they liked:
        - Three paying pilots already running [01:35]
        - The team's speed: two releases a month, R&D kept small

        Their concerns:
        - Burn of about 90k a month against an 18 month runway [12:35, 13:10]
        - Whether *enterprise* buyers will sign without SOC 2

        What they asked for:
        - Cohort data by Friday [17:00]
        - An intro to one pilot customer

        Fit:
        - Stage fit: 4/5 - They lead seed rounds and joined two this year [05:30]
        - Check size: not enough evidence

        Next steps:
        - You send the data room link and cohort sheet tomorrow [26:50]
        - Dana brings it to Monday's partner meeting [29:55]
        - Northwind sets up a pilot with a portfolio company
        """
        m.coaching = """
        Call snapshot: A warm first call. You spoke 46%, they spoke 54%.

        What went well:
        - You led with traction and kept the pilot numbers concrete [01:35]
        - You answered the burn question straight instead of dodging it [12:35]

        What to improve:
        - You talked for two minutes straight early on; check in sooner
        - Ask for the decision timeline before the call ends

        Commitments & follow-ups:
        - Send the data room link and cohort sheet tomorrow [26:50]
        """
        m.status = .done
        return m
    }
}
