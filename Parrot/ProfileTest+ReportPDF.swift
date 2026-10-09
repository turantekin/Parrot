import Foundation

/// Export PDF: the HTML the PDF is printed from (the printing itself is
/// checked by `--report-pdf`, which needs a running app).
extension ProfileTest {
    @MainActor
    static func testReportPDF() {
        guard let ctx = phase4Context() else { check("pdf: container", false); return }
        let demo = ReportPDFHarness.demoMeeting(in: ctx)
        let html = ReportPDF.html(for: demo, fonts: "")
        check("pdf: header has length, call type and who attended",
              html.contains("32 min") && html.contains("Investor pitch") && html.contains("You, Dana Ruiz, Sam Lee"))
        check("pdf: how the call went, with the gauge at the end and a chart",
              html.contains("How the call went") && html.contains("Interest at the end") && html.contains("Leaning in")
                  && html.contains("<svg class=\"chart\""))
        let titles = ["Overview", "What they liked", "Their concerns", "What they asked for", "Fit", "Next steps",
                      "What went well", "What to improve", "Commitments &amp; follow-ups"]
        check("pdf: every report and coaching section is a card", titles.allSatisfy { html.contains("<h3>\($0)</h3>") })
        check("pdf: scorecard rows", html.contains("<b>4/5</b>") && html.contains("not enough evidence"))
        check("pdf: receipts become time chips", html.contains("<span class=\"cite\">01:35</span>") && !html.contains("[01:35]"))
        check("pdf: a promise with no receipt says so", html.contains("unverified"))
        check("pdf: no transcript, no notes", !html.contains("Filler line") && !html.contains("bridge round"))
        check("pdf: a few moments sit under the chart",
              (html.range(of: "Key moments</h3>")?.lowerBound).map { $0 < html.range(of: "<h2>Report</h2>")!.lowerBound } == true)

        demo.title = "<script>alert(1)</script>"
        demo.summary = "Key points:\n- Price <b>up</b> & **firm** [01:35]"
        demo.speakerNames = ["Speaker 1": "Dana Ruiz", "Speaker 2": "dana ruiz"]
        demo.nudges = (1...9).map { Nudge(kind: .speedingUp, time: TimeInterval($0 * 100), text: "Slow down") }
        let hostile = ReportPDF.html(for: demo, fonts: "")
        check("pdf: escapes < > & in the title and the report",
              !hostile.contains("<script>") && hostile.contains("&lt;script&gt;alert(1)&lt;/script&gt;")
                  && hostile.contains("Price &lt;b&gt;up&lt;/b&gt; &amp; ") && !hostile.contains("<b>up")
                  && hostile.contains("<strong>firm</strong>"))
        check("pdf: a name two voices share is listed once", ReportPDF.people(demo) == ["You", "Dana Ruiz"])
        check("pdf: a long list of moments waits until after the report",
              (hostile.range(of: "Key moments</h2>")?.lowerBound).map { $0 > hostile.range(of: "<h2>Coaching</h2>")!.lowerBound } == true)

        let plain = phase4Meeting(ctx)
        check("pdf: no names yet reads as Them", ReportPDF.people(plain) == ["You", "Them"])
        for seg in plain.segments { seg.speakerLabel = "Speaker 1" }
        check("pdf: imported audio (no You side) has no tone section",
              !ReportPDF.html(for: plain, fonts: "").contains("How the call went"))
        check("pdf: report present", ReportPDF.hasReport(plain))
        plain.summary = nil
        plain.coaching = ""
        check("pdf: no report, no PDF", !ReportPDF.hasReport(plain))
        check("pdf: lengths read plainly",
              ReportPDF.length(45) == "45 sec" && ReportPDF.length(1501) == "25 min" && ReportPDF.length(4380) == "1 h 13 min")
    }
}
