import AppKit
import SwiftUI
import WebKit

/// Export PDF: the meeting's report as a page to share with a team. Header
/// (date, people, length), how the call went, then the report as cards. No
/// transcript, notes, costs or privacy ledger. `html` is pure and
/// harness-checked; `render` lets WebKit's print layout paginate it (cards
/// never split) and stamps the footer on every page.
enum ReportPDF {
    static func hasReport(_ meeting: Meeting) -> Bool {
        !(meeting.summary ?? "").isEmpty || !(meeting.coaching ?? "").isEmpty
    }

    @MainActor
    static func data(for meeting: Meeting) async throws -> Data {
        try await render(html: html(for: meeting), title: meeting.title)
    }

    // MARK: - HTML

    @MainActor
    static func html(for meeting: Meeting, fonts: String = fontFaces()) -> String {
        // Same moments as the Report tab: timing nudges replayed with today's rules.
        let spans = ToneTimeline.spans(meeting.sortedSegments)
        let nudges = ToneTimeline.reportNudges(saved: meeting.nudges,
                                               timing: ToneTimeline.timingNudges(spans, duration: meeting.duration))
        let model = ToneTimeline.model(duration: meeting.duration, spans: spans,
                                       nudges: nudges, timeline: meeting.moodTimeline, marks: meeting.bookmarks)
        let receipts = meeting.receiptIndex
        let template = meeting.reportTemplate

        var facts = [("Date", meeting.date.formatted(date: .abbreviated, time: .omitted)),
                     ("Time", meeting.date.formatted(date: .omitted, time: .shortened)),
                     ("Length", length(meeting.duration))]
        if let type = meeting.profile?.name { facts.append(("Call type", type)) }

        var body = """
        <header class="keep">
        <div class="brand">\(iconTag())<span>Parrot</span><em>Call report</em></div>
        <h1>\(esc(meeting.title))</h1>
        <div class="facts">\(facts.map { "<div><span>\($0.0)</span>\(esc($0.1))</div>" }.joined())</div>
        <div class="facts people"><div><span>Attended</span>\(esc(people(meeting).joined(separator: ", ")))</div></div>
        </header>
        """
        if !meeting.about.isEmpty { body += "<p class=\"about\">\(esc(meeting.about))</p>" }
        // A few moments read best under the chart; a long list waits until
        // after the report, so the report stays near the top.
        let early = (model?.moments.count ?? 0) <= 8
        if let model { body += tone(model) + (early ? moments(model, heading: "h3") : "") }
        for (title, text) in [("Report", meeting.summary), ("Coaching", meeting.coaching)] {
            guard let text, !text.isEmpty else { continue }
            body += report(text, heading: title, template: template, receipts: receipts)
        }
        if let model, !early { body += moments(model, heading: "h2") }
        return """
        <!doctype html><html><head><meta charset="utf-8"><title>\(esc(meeting.title))</title>
        <style>\(fonts)\(css)</style></head><body>\(body)</body></html>
        """
    }

    /// You, then the other voices by name, each once. Unnamed voices
    /// ("Speaker 2") read as "Them".
    static func people(_ meeting: Meeting) -> [String] {
        let names = meeting.speakerNames
        var seen = Set<String>()
        let others = meeting.otherSpeakerLabels.map { meeting.displayName(forSpeaker: $0, names: names) }
            .filter { !$0.hasPrefix("Speaker ") && seen.insert($0.lowercased()).inserted }
        return ["You"] + (others.isEmpty ? ["Them"] : others)
    }

    static func length(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if seconds < 60 { return "\(Int(seconds)) sec" }
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
    }

    private static func esc(_ s: String) -> String { WhatsNew.escape(s) }

    /// Escaped, with the report's **bold** and *italic* kept.
    private static func inline(_ s: String) -> String {
        esc(s).replacingOccurrences(of: #"\*\*(.+?)\*\*"#, with: "<strong>$1</strong>", options: .regularExpression)
            .replacingOccurrences(of: #"(?<![\*\w])\*(?=\S)(.+?)(?<=\S)\*(?![\*\w])"#, with: "<em>$1</em>", options: .regularExpression)
    }

    // MARK: How the call went

    private static func tone(_ model: ToneTimeline.Model) -> String {
        var tiles = [("You talked", model.talkPercentMe.map { "\($0)%" } ?? "–"),
                     ("Key moments", "\(model.moments.count)")]
        if let gauge = model.gauge, let end = model.endLevel { tiles.append(("\(gauge.label) at the end", end)) }
        var legend = [("me", "You"), ("them", "Them")]
        if let gauge = model.gauge, model.mood.count >= 2 { legend.append(("mood", gauge.label)) }
        return """
        <section class="keep"><h2>How the call went</h2>
        <div class="tiles">\(tiles.map { "<div><span>\(esc($0.0))</span><b>\(esc($0.1))</b></div>" }.joined())</div>
        <div class="legend">\(legend.map { "<span><i class=\"\($0.0)\"></i>\(esc($0.1))</span>" }.joined())</div>
        \(chart(model))</section>
        """
    }

    /// Numbered like the chart: title, time, what happened.
    private static func moments(_ model: ToneTimeline.Model, heading: String) -> String {
        let rows = model.moments.map { m in
            "<div class=\"moment\"><b class=\"\(kindClass(m.kind))\">\(m.number)</b><p><strong>\(esc(m.title))</strong>"
                + "<span class=\"cite\">\(Receipts.stamp(m.time))</span> \(esc(m.detail))</p></div>"
        }
        guard let first = rows.first else { return "" }
        // The heading travels with the first moment.
        return "<div class=\"keep\"><\(heading) class=\"moments\">Key moments</\(heading)>\(first)</div>" + rows.dropFirst().joined()
    }

    private static func kindClass(_ kind: ToneTimeline.Moment.Kind) -> String {
        switch kind {
        case .nudge: "nudge"
        case .turn: "turn"
        case .mark: "mark"
        }
    }

    /// The app's tone chart as SVG: talk bars per minute (you on top), the
    /// main gauge as a line, numbered moments, a time axis.
    static func chart(_ model: ToneTimeline.Model) -> String {
        let w = 487.0, left = 46.0, right = 6.0, barH = 30.0
        let hasMood = model.gauge != nil && model.mood.count >= 2
        let moodTop = 46.0, moodH = 64.0, rowsEnd = hasMood ? moodTop + moodH : barH
        let markY = rowsEnd + 18, h = (model.moments.isEmpty ? rowsEnd : markY + 14) + 20
        let width = w - left - right, duration = max(model.duration, 1)
        func x(_ t: TimeInterval) -> Double { left + min(max(t, 0), duration) / duration * width }
        func f(_ v: Double) -> String { String(format: "%.1f", v) }
        func label(_ text: String, _ y: Double) -> String {
            "<text x=\"0\" y=\"\(f(y))\" dominant-baseline=\"middle\">\(esc(text))</text>"
        }
        var svg = label("Talk", barH / 2)
        let slot = width / Double(max(model.minutes.count, 1))
        for (i, m) in model.minutes.enumerated() where m.me + m.them > 0 {
            let meH = barH * m.me / (m.me + m.them), bx = left + Double(i) * slot + 0.6, bw = max(0.8, slot - 1.2)
            svg += "<rect class=\"me\" x=\"\(f(bx))\" y=\"0\" width=\"\(f(bw))\" height=\"\(f(meH))\" rx=\"1.2\"/>"
            svg += "<rect class=\"them\" x=\"\(f(bx))\" y=\"\(f(meH))\" width=\"\(f(bw))\" height=\"\(f(barH - meH))\" rx=\"1.2\"/>"
        }
        if hasMood, let gauge = model.gauge {
            svg += label(gauge.highLabel, moodTop) + label(gauge.lowLabel, moodTop + moodH)
            svg += "<line class=\"mid\" x1=\"\(f(left))\" x2=\"\(f(left + width))\" y1=\"\(f(moodTop + moodH / 2))\" y2=\"\(f(moodTop + moodH / 2))\"/>"
            let points = model.mood.map { "\(f(x($0.time))),\(f(moodTop + moodH * (1 - Double($0.value) / 100)))" }
            svg += "<polyline class=\"mood\" points=\"\(points.joined(separator: " "))\"/>"
        }
        // Two moments at once sit side by side, as in the app. Where they
        // crowd, the rest are dots under the row (numbers in the list).
        var last = -Double.infinity
        for m in model.moments {
            let at = x(m.time), cx = max(at, last + 17), kind = kindClass(m.kind)
            guard cx - at <= 34, cx <= left + width else {
                svg += "<circle class=\"dot\" cx=\"\(f(at))\" cy=\"\(f(markY + 12))\" r=\"1.8\"/>"
                continue
            }
            last = cx
            svg += "<path class=\"tick\" d=\"M\(f(at)) \(f(barH)) L\(f(at)) \(f(markY - 12)) L\(f(cx)) \(f(markY - 8))\"/>"
            svg += "<circle class=\"\(kind)\" cx=\"\(f(cx))\" cy=\"\(f(markY))\" r=\"7.5\"/>"
            svg += "<text class=\"n \(kind)\" x=\"\(f(cx))\" y=\"\(f(markY))\" text-anchor=\"middle\" dominant-baseline=\"central\">\(m.number)</text>"
        }
        let step: TimeInterval = duration > 1800 ? 600 : duration > 600 ? 300 : 60
        var t: TimeInterval = 0
        while t <= duration {
            let anchor = x(t) > left + width - 14 ? "end" : "middle"
            svg += "<text x=\"\(f(x(t)))\" y=\"\(f(h - 3))\" text-anchor=\"\(anchor)\">\(Receipts.stamp(t))</text>"
            t += step
        }
        return "<svg class=\"chart\" viewBox=\"0 0 \(f(w)) \(f(h))\" width=\"100%\">\(svg)</svg>"
    }

    // MARK: Report sections

    private static func report(_ text: String, heading: String, template: ReportTemplate?, receipts: ReceiptIndex) -> String {
        let flagging = receipts.reportHasReceipts(text)
        let blocks = ReportProse.sections(from: text, template: template).map { section -> String in
            func row(_ block: ReportProse.Block) -> String {
                let c = ReportProse.checked(block, section: section.title, template: template,
                                            receipts: receipts, flagging: flagging)
                let text = tied(inline(c.text), c.unverified ? "<span class=\"unverified\">unverified</span>" : cite(c.lines))
                switch block {
                case .bullet(_, let level): return "<li class=\"l\(level)\">\(text)</li>"
                case .paragraph(_, let lede): return "<p\(lede ? " class=\"lede\"" : "")>\(text)</p>"
                }
            }
            func list(_ blocks: [ReportProse.Block]) -> String {
                // Runs of bullets become one list; paragraphs stand alone.
                var out = "", open = false
                for b in blocks {
                    if case .bullet = b { if !open { out += "<ul>"; open = true } } else if open { out += "</ul>"; open = false }
                    out += row(b)
                }
                return out + (open ? "</ul>" : "")
            }
            guard let title = section.title else { return "<div class=\"preamble\">\(list(section.blocks))</div>" }
            var content = list(section.blocks)
            if let card = template?.section(titled: title), card.type == "scorecard", let criteria = card.criteria, !criteria.isEmpty {
                let read = Scorecard.rows(from: section.blocks.map(\.raw), criteria: criteria, receipts: receipts)
                content = read.rows.map(score).joined() + list(read.rest.map { .bullet($0, level: 0) })
                    + "<p class=\"note\">Scores help you take notes. You make the call.</p>"
            }
            return "<div class=\"card\"><h3>\(esc(title))</h3>\(content)</div>"
        }
        guard let first = blocks.first else { return "" }
        // The heading travels with the first card: no heading alone at a page's foot.
        return "<div class=\"keep\"><h2>\(esc(heading))</h2>\(first)</div>" + blocks.dropFirst().joined()
    }

    private static func score(_ row: Scorecard.Row) -> String {
        guard let score = row.score else {
            return "<div class=\"score\"><h4>\(esc(row.label))<span class=\"none\">\(row.uncited ? "no moment cited" : "not enough evidence")</span></h4></div>"
        }
        let steps = (1...5).map { "<i\($0 <= score ? " class=\"on\"" : "")></i>" }.joined()
        return """
        <div class="score"><h4>\(esc(row.label))<span class="steps">\(steps)</span><b>\(score)/5</b></h4>\
        <p>\(tied(inline(row.evidence), cite(row.lines)))</p></div>
        """
    }

    /// The first `[mm:ss]` receipt that points at a real line, as a quiet
    /// time chip. One is enough on paper; the app shows them all.
    private static func cite(_ lines: [ReceiptIndex.Line]) -> String {
        lines.first.map { "<span class=\"cite\">\(Receipts.stamp($0.start))</span>" } ?? ""
    }

    /// Keeps a chip on the same line as the last word, never alone below.
    private static func tied(_ html: String, _ tail: String) -> String {
        guard !tail.isEmpty, let space = html.lastIndex(of: " ") else { return html + tail }
        return html[...space] + "<span class=\"nb\">\(html[html.index(after: space)...])\(tail)</span>"
    }

    // MARK: Look

    /// A Theme color as it looks in light mode: the PDF is always light,
    /// even when the Mac is in dark mode.
    private static func light(_ color: Color) -> NSColor {
        var out = NSColor.black
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            out = NSColor(color).usingColorSpace(.sRGB) ?? .black
        }
        return out
    }

    private static func cssColor(_ color: Color) -> String {
        let c = light(color)
        return String(format: "rgba(%.0f,%.0f,%.0f,%.3f)", c.redComponent * 255, c.greenComponent * 255,
                      c.blueComponent * 255, c.alphaComponent)
    }

    private static var css: String {
        let c = Theme.Colors.self
        let vars = [("ink", c.ink), ("ink2", c.ink2), ("ink3", c.ink3), ("line", c.line), ("chip", c.chip),
                    ("accent", c.accent), ("soft", c.accent.opacity(0.1)), ("me", c.meLane), ("them", c.themLane),
                    ("mood", c.moodLine), ("warn", c.warn)]
            .map { "--\($0.0):\(cssColor($0.1));" }.joined()
        return ":root{\(vars)}" + #"""
        *{box-sizing:border-box;-webkit-print-color-adjust:exact;print-color-adjust:exact}
        body{margin:0;font:10.5px/1.5 -apple-system,"Helvetica Neue",sans-serif;color:var(--ink);background:#fff}
        h1,h2,h3,.brand span,.tiles b{font-family:"Outfit",-apple-system,sans-serif;font-weight:600}
        .keep,.card,.moment,.score,.tiles,.chart,header{break-inside:avoid;page-break-inside:avoid}
        .brand{display:flex;align-items:center;gap:6px;font-size:11px}
        .brand img{width:16px;height:16px}
        .brand span{color:var(--accent)}
        .brand em{font-style:normal;color:var(--ink2);padding-left:6px;margin-left:2px;border-left:1px solid var(--line)}
        h1{font-size:23px;line-height:1.2;margin:14px 0 14px;letter-spacing:-.01em}
        .facts{display:flex;flex-wrap:wrap;gap:6px 28px;padding:10px 0;border-top:1px solid var(--line)}
        .facts.people{border-bottom:1px solid var(--line)}
        .facts div{font-size:11px}
        .facts span,.tiles span{display:block;font-size:8px;font-weight:600;letter-spacing:.08em;text-transform:uppercase;color:var(--ink2);margin-bottom:1px}
        .about{font-size:12px;line-height:1.55;margin:14px 0 0}
        h2{font-size:15px;margin:26px 0 10px}
        h3{font-size:12.5px;margin:0 0 6px;display:flex;align-items:center;gap:7px}
        .card h3::before{content:"";width:6px;height:6px;border-radius:2px;background:var(--accent)}
        .tiles{display:flex;gap:8px;margin-bottom:12px}
        .tiles div{flex:1;background:var(--soft);border-radius:8px;padding:8px 10px}
        .tiles b{font-size:17px}
        .legend{display:flex;gap:14px;font-size:9px;color:var(--ink2);margin-bottom:6px}
        .legend i{display:inline-block;width:8px;height:8px;border-radius:2px;margin-right:5px;vertical-align:-1px}
        .legend .me,.chart .me{background:var(--me);fill:var(--me)}
        .legend .them,.chart .them{background:var(--them);fill:var(--them)}
        .legend .mood{background:var(--mood)}
        .chart{display:block;margin-top:4px;overflow:visible}
        .chart text{font-size:8px;fill:var(--ink2)}
        .chart .mid{stroke:var(--line);stroke-width:.6;stroke-dasharray:3 3}
        .chart .mood{fill:none;stroke:var(--mood);stroke-width:1.8;stroke-linejoin:round}
        .chart .tick{fill:none;stroke:var(--line);stroke-width:.6;stroke-dasharray:2 3}
        .chart circle.nudge,.moment b.nudge,.chart circle.turn,.moment b.turn{fill:var(--soft);background:var(--soft)}
        .chart circle.mark,.moment b.mark{fill:var(--chip);background:var(--chip)}
        .chart text.n{font-size:8px;font-weight:600;fill:var(--accent)}
        .chart text.n.mark{fill:var(--ink2)}
        .moments{margin:18px 0 6px}
        .moment{display:flex;gap:9px;padding:3px 0}
        .moment b{flex:none;width:15px;height:15px;border-radius:50%;font-size:7.5px;line-height:15px;text-align:center;color:var(--accent);margin-top:.5px}
        .moment b.mark{color:var(--ink2)}
        .moment p{margin:0;color:var(--ink2)}
        .moment strong{color:var(--ink);font-weight:600}
        .chart circle.dot{fill:var(--them)}
        h4{font-size:10.5px;font-weight:600;margin:0;display:flex;align-items:center;gap:6px}
        .nb{white-space:nowrap}
        .card{border:1px solid var(--line);border-radius:10px;padding:12px 14px;margin-bottom:10px}
        .card li:last-child,.card p:last-child{margin-bottom:0}
        .preamble{margin-bottom:12px}
        p{margin:0 0 6px}
        .lede{font-size:11.5px;line-height:1.55}
        ul{list-style:none;margin:0;padding:0}
        li{position:relative;padding-left:13px;margin-bottom:5px}
        li::before{content:"";position:absolute;left:2px;top:.62em;width:4px;height:4px;border-radius:50%;background:var(--ink3)}
        li.l1{margin-left:14px;color:var(--ink2)}
        .cite{display:inline-block;font:500 7.5px/1.6 ui-monospace,Menlo,monospace;color:var(--ink2);background:var(--chip);border-radius:4px;padding:0 4px;margin-left:4px;vertical-align:1px;white-space:nowrap}
        .unverified{font-size:8.5px;color:var(--warn);margin-left:6px;white-space:nowrap}
        .score{padding:6px 0;border-top:1px solid var(--line)}
        .score:first-of-type{border-top:0;padding-top:0}
        .score h4 b{font:600 9.5px ui-monospace,Menlo,monospace}
        .steps{display:inline-flex;gap:2px;margin-left:auto}
        .steps i{width:13px;height:5px;border-radius:3px;background:var(--chip)}
        .steps i.on{background:var(--accent)}
        .score .none{margin-left:auto;font-weight:400;font-size:9px;color:var(--ink2)}
        .score p{margin:2px 0 0;color:var(--ink2)}
        .note{font-size:8.5px;color:var(--ink2);margin:6px 0 0}
        """#
    }

    /// Outfit (the brand face) for headings, inlined so the web view can
    /// use it; the system font when the file isn't there.
    static func fontFaces() -> String {
        // The app bundle's copy, or the repo's when a harness runs the bare binary.
        let url = Bundle.main.url(forResource: "Outfit-SemiBold", withExtension: "otf")
            ?? URL(fileURLWithPath: "Parrot/Fonts/Outfit-SemiBold.otf")
        guard let data = try? Data(contentsOf: url) else { return "" }
        return "@font-face{font-family:\"Outfit\";font-weight:600;src:url(data:font/otf;base64,\(data.base64EncodedString())) format(\"opentype\")}"
    }

    /// The app icon, drawn at 64 px so the PDF doesn't carry the 1024 px one.
    @MainActor
    private static func iconTag() -> String {
        guard let icon = NSApp?.applicationIconImage,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return "" }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        icon.draw(in: NSRect(x: 0, y: 0, width: 64, height: 64))
        NSGraphicsContext.restoreGraphicsState()
        let png = rep.representation(using: .png, properties: [:])
        return png.map { "<img src=\"data:image/png;base64,\($0.base64EncodedString())\" alt=\"\">" } ?? ""
    }

    // MARK: - PDF

    enum RenderError: LocalizedError {
        case failed
        var errorDescription: String? { "Couldn't make the PDF. Try again." }
    }

    /// Margins sized so A4 and US Letter both fit; the footer sits in the bottom one.
    static let margins = NSEdgeInsets(top: 46, left: 54, bottom: 60, right: 54)

    /// Lays `html` out on pages of `paper` (the Mac's default paper, A4 or
    /// Letter) with WebKit's print engine, offscreen, then adds the footer.
    @MainActor
    static func render(html: String, title: String, paper: NSSize = NSPrintInfo.shared.paperSize) async throws -> Data {
        let config = WKWebViewConfiguration()
        config.preferences.shouldPrintBackgrounds = true
        let web = WKWebView(frame: NSRect(origin: .zero, size: paper), configuration: config)
        web.appearance = NSAppearance(named: .aqua)
        // Printing needs a window; this one is never shown.
        let window = NSWindow(contentRect: web.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = web
        let loader = Loader()
        web.navigationDelegate = loader
        web.loadHTMLString(html, baseURL: nil)
        guard await loader.loaded() else { throw RenderError.failed }
        _ = try? await web.callAsyncJavaScript("await document.fonts.ready; return true", contentWorld: .page)

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("parrot-report-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: file) }
        let info = NSPrintInfo()
        info.paperSize = paper
        info.topMargin = margins.top
        info.bottomMargin = margins.bottom
        info.leftMargin = margins.left
        info.rightMargin = margins.right
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = file
        let op = web.printOperation(with: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        op.view?.frame = web.bounds
        // `run()` prints WebKit's pages blank; the modal run lets it draw.
        let printed = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            let delegate = PrintDone(done)
            op.runModal(for: window, delegate: delegate,
                        didRun: #selector(PrintDone.printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
        }
        guard printed, let doc = CGPDFDocument(file as CFURL), doc.numberOfPages > 0 else { throw RenderError.failed }
        return footed(doc, title: title)
    }

    /// Every page again, with "Made with Parrot · openparrot.app" and its number.
    private static func footed(_ doc: CGPDFDocument, title: String) -> Data {
        let out = NSMutableData()
        var box = doc.page(at: 1)?.getBoxRect(.mediaBox) ?? .zero
        let meta = [kCGPDFContextTitle: title, kCGPDFContextCreator: "Parrot"] as CFDictionary
        guard let consumer = CGDataConsumer(data: out),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, meta) else { return Data() }
        let font = NSFont.systemFont(ofSize: 7.5)
        let gray = light(Theme.Colors.ink2)
        for n in 1...doc.numberOfPages {
            guard let page = doc.page(at: n) else { continue }
            var media = page.getBoxRect(.mediaBox)
            ctx.beginPDFPage([kCGPDFContextMediaBox: Data(bytes: &media, count: MemoryLayout<CGRect>.size)] as CFDictionary)
            ctx.drawPDFPage(page)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: gray]
            let y = media.minY + 26
            let made = NSAttributedString(string: "Made with Parrot · openparrot.app", attributes: attrs)
            made.draw(at: NSPoint(x: media.minX + margins.left, y: y))
            ctx.setURL(URL(string: MeetingActions.websiteURL)! as CFURL,
                       for: CGRect(x: media.minX + margins.left, y: y, width: made.size().width, height: made.size().height))
            let number = NSAttributedString(string: "\(n) of \(doc.numberOfPages)", attributes: attrs)
            number.draw(at: NSPoint(x: media.maxX - margins.right - number.size().width, y: y))
            NSGraphicsContext.restoreGraphicsState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return out as Data
    }

    @MainActor private final class Loader: NSObject, WKNavigationDelegate {
        private var done: CheckedContinuation<Bool, Never>?
        private var result: Bool?

        func loaded() async -> Bool {
            if let result { return result }
            return await withCheckedContinuation { done = $0 }
        }

        private func finish(_ ok: Bool) {
            guard result == nil else { return }
            result = ok
            done?.resume(returning: ok)
            done = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(true) }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(false) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            finish(false)
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(false) }
    }

    /// Holds itself until AppKit reports back (the print operation doesn't retain its delegate).
    @MainActor private final class PrintDone: NSObject {
        private var done: CheckedContinuation<Bool, Never>?
        private var me: PrintDone?

        init(_ done: CheckedContinuation<Bool, Never>) {
            self.done = done
            super.init()
            me = self
        }

        @objc func printOperationDidRun(_ op: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
            done?.resume(returning: success)
            done = nil
            me = nil
        }
    }
}
