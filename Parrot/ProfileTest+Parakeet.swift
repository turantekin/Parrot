import Foundation

/// Parakeet and the language router (spec 2026-09-30).
extension ProfileTest {
    static func testLanguageRouter() {
        typealias R = LanguageRouter
        var auto = R(parakeet: true, pinned: nil)
        check("router: auto holds both sides", auto.isHolding && auto.route(.me) == .undecided && auto.route(.them) == .undecided)
        check("router: English, sure → Parakeet", auto.heard(.me, language: "en", confidence: 0.95) == .decided(.me, .parakeet(language: "en")))
        check("router: Turkish → Whisper", auto.heard(.them, language: "tr", confidence: 0.99) == .decided(.them, .whisper))
        let tamil = R(parakeet: true, pinned: "ta")
        check("router: Tamil picked by hand → Whisper, no hold", !tamil.isHolding && tamil.route(.me) == .whisper && tamil.route(.them) == .whisper)
        check("router: both decided → no hold", !auto.isHolding)

        var unsure = R(parakeet: true, pinned: nil)
        check("router: unsure once → one more look", unsure.heard(.me, language: "en", confidence: 0.5) == .retry(.me) && unsure.isHolding)
        check("router: unsure twice → Whisper", unsure.heard(.me, language: "en", confidence: 0.55) == .decided(.me, .whisper))
        check("router: no answer → Whisper, nothing to retry", unsure.heard(.them, language: nil, confidence: 0) == .decided(.them, .whisper))
        var second = R(parakeet: true, pinned: nil)
        _ = second.heard(.me, language: "en", confidence: 0.52)
        check("router: sure on the second look → Parakeet", second.heard(.me, language: "en", confidence: 0.95) == .decided(.me, .parakeet(language: "en")))
        var mic = R(parakeet: true, pinned: nil)
        _ = mic.heard(.them, language: "en", confidence: 0.96)
        check("router: an unsure mic that agrees with the other side follows it",
              mic.heard(.me, language: "en", confidence: 0.62) == .decided(.me, .parakeet(language: "en")) && !mic.isHolding)
        var disagree = R(parakeet: true, pinned: nil)
        _ = disagree.heard(.them, language: "en", confidence: 0.96)
        check("router: an unsure mic guessing another language still looks again",
              disagree.heard(.me, language: "tr", confidence: 0.62) == .retry(.me))
        check("dashboard: the engine a picked language gets",
              DashboardView.engineHint(model: "parakeet-v3", language: "de") == "Parakeet from the first word"
              && DashboardView.engineHint(model: "parakeet-v3", language: "tr")?.hasPrefix("Whisper from the first word") == true
              && DashboardView.engineHint(model: "large-v3-turbo", language: "tr") == nil)
        var turkish = R(parakeet: true, pinned: nil)
        check("router: sure Turkish needs no retry", turkish.heard(.them, language: "tr", confidence: 0.99) == .decided(.them, .whisper))

        let german = R(parakeet: true, pinned: "de")
        check("router: pinned German → Parakeet, no hold", german.route(.me) == .parakeet(language: "de") && !german.isHolding)
        check("router: pinned Turkish → Whisper", R(parakeet: true, pinned: "tr").route(.them) == .whisper)
        var pinnedEnglish = R(parakeet: true, pinned: "en")
        check("router: a pin isn't overruled (the banner offers the switch)",
              pinnedEnglish.heard(.them, language: "tr", confidence: 0.99) == nil && pinnedEnglish.route(.them) == .parakeet(language: "en"))
        check("router: a pin needs no rechecks", !pinnedEnglish.decoded(.them, seconds: 600))
        check("router: Whisper model → always Whisper", R(parakeet: false, pinned: nil).route(.me) == .whisper)

        var recheck = R(parakeet: true, pinned: nil)
        _ = recheck.heard(.them, language: "en", confidence: 0.99)
        check("recheck: not before 30 s of speech", !recheck.decoded(.them, seconds: 20))
        check("recheck: due at 30 s", recheck.decoded(.them, seconds: 12))
        check("recheck: still English → stays", recheck.heard(.them, language: "en", confidence: 0.97) == nil
              && recheck.route(.them) == .parakeet(language: "en"))
        check("recheck: counter restarts after a check", !recheck.decoded(.them, seconds: 20))
        check("recheck: Turkish now → switch", recheck.heard(.them, language: "tr", confidence: 0.9) == .switchedToWhisper(.them))
        check("recheck: unsure Turkish doesn't switch", {
            var r = R(parakeet: true, pinned: nil)
            _ = r.heard(.me, language: "en", confidence: 0.99)
            return r.heard(.me, language: "tr", confidence: 0.6) == nil
        }())
        check("router: no switching back", recheck.heard(.them, language: "en", confidence: 0.99) == nil && recheck.route(.them) == .whisper)
        check("router: Whisper tracks never recheck", !recheck.decoded(.them, seconds: 600))

        var banner = R(parakeet: true, pinned: "en")
        banner.switchLanguage(to: "tr")
        check("switch: to Turkish → both Whisper", banner.route(.me) == .whisper && banner.route(.them) == .whisper)
        var toGerman = R(parakeet: true, pinned: nil)
        toGerman.switchLanguage(to: "de")
        check("switch: to German decides held sides", toGerman.route(.me) == .parakeet(language: "de") && !toGerman.isHolding)
    }

    static func testLanguageProbe() {
        let t0 = Date(timeIntervalSince1970: 1000)
        let second = [Float](repeating: 0.1, count: 16000)
        var p = LanguageProbe()
        var ready: [Float]?
        for i in 0..<4 { ready = p.add(second, voiced: true, from: .them, at: t0.addingTimeInterval(Double(i)), holding: true) }
        check("probe: a held side isn't ready at 4 s", ready == nil)
        ready = p.add(second, voiced: true, from: .them, at: t0.addingTimeInterval(4), holding: true)
        check("probe: a held side's first look is at 5 s", ready?.count == LanguageProbe.quick)
        check("probe: once per track", p.add(second, voiced: true, from: .them, at: t0.addingTimeInterval(5), holding: true) == nil)
        p.rearm(.them)
        var again: [Float]?
        for i in 0..<9 { again = p.add(second, voiced: true, from: .them, at: t0.addingTimeInterval(Double(6 + i)), holding: true) }
        check("probe: the second look gathers the full 10 s", again == nil
              && p.add(second, voiced: true, from: .them, at: t0.addingTimeInterval(15), holding: true)?.count == LanguageProbe.full)
        var banner = LanguageProbe()
        var early: [Float]?
        for i in 0..<9 { early = banner.add(second, voiced: true, from: .me, at: t0.addingTimeInterval(Double(i)), holding: false) }
        check("probe: the banner check keeps 0.24.2's 10 s", early == nil
              && banner.add(second, voiced: true, from: .me, at: t0.addingTimeInterval(9), holding: false)?.count == LanguageProbe.full)
        check("probe: silence doesn't count", p.add(second, voiced: false, from: .me, at: t0, holding: true) == nil)
        _ = p.add(second, voiced: true, from: .me, at: t0, holding: true)
        check("probe: other track is separate", p.take(.me, at: t0.addingTimeInterval(5), force: false, holding: true) == nil)
        check("probe: 30 s wait while holding", p.take(.me, at: t0.addingTimeInterval(30), force: false, holding: true)?.count == 16000)
        var warn = LanguageProbe()
        _ = warn.add(second, voiced: true, from: .me, at: t0, holding: false)
        check("probe: no wait when not holding", warn.take(.me, at: t0.addingTimeInterval(60), force: false) == nil)
        check("probe: forced at stop takes what's there", warn.take(.me, at: t0, force: true)?.count == 16000)
        warn.rearm(.me)
        check("probe: rearm gathers again", warn.take(.me, at: t0, force: false) == nil
              && warn.add(Array(repeating: 0.1, count: LanguageProbe.full), voiced: true, from: .me, at: t0, holding: false) != nil)
        var later = LanguageProbe()
        _ = later.add(Array(repeating: 0.1, count: LanguageProbe.full), voiced: true, from: .them, at: t0, holding: false)
        later.rearm(.them, skipping: MismatchWatch.recheckAfter)
        var gathered = 0
        for _ in 0..<20 { if later.add(second, voiced: true, from: .them, at: t0, holding: false) != nil { gathered += 1 } }
        check("probe: 20 s of speech passes before gathering again", gathered == 0)
        var fired = false
        for _ in 0..<10 { if later.add(second, voiced: true, from: .them, at: t0, holding: false) != nil { fired = true } }
        check("probe: then the next 10 s is checked (30 s apart in all)", fired)
    }

    static func testMismatchWatch() {
        var pinned = MismatchWatch(setting: "en")
        check("watch: a side that matches waits 30 s of speech", pinned.heard(.them, mismatch: nil, confidence: 0.95) == (nil, MismatchWatch.recheckAfter))
        check("watch: Turkish later in the call is offered", pinned.heard(.them, mismatch: "tr", confidence: 0.99).offer == "tr")
        check("watch: the same offer isn't repeated", pinned.heard(.them, mismatch: "tr", confidence: 0.99).offer == nil)
        pinned.switched(to: "tr")
        check("watch: a bilingual call can't bounce back to English", pinned.heard(.me, mismatch: "en", confidence: 0.99).offer == nil)
        var quiet = MismatchWatch(setting: "en")
        check("watch: unsure looks again right away", quiet.heard(.me, mismatch: nil, confidence: 0.5).recheckAfter == 0
              && quiet.heard(.me, mismatch: nil, confidence: 0.5).recheckAfter == 0)
        check("watch: after a few unsure looks, wait 30 s", quiet.heard(.me, mismatch: nil, confidence: 0.5).recheckAfter == MismatchWatch.recheckAfter)
    }

    static func testEngineRecommendation() {
        typealias E = EngineRecommendation
        check("recommend: English and German Mac → Parakeet",
              E.recommend(preferredLanguages: ["en-GB", "de-DE"], pastCallLanguages: [], memoryGB: 16) == ParakeetTranscriber.modelID)
        check("recommend: Turkish anywhere in the list → Whisper",
              E.recommend(preferredLanguages: ["en-GB", "tr-TR"], pastCallLanguages: [], memoryGB: 16) == "large-v3-turbo")
        check("recommend: a past Turkish call → Whisper",
              E.recommend(preferredLanguages: ["en-US"], pastCallLanguages: ["en", "tr"], memoryGB: 8) == "base")
        check("recommend: script subtags don't confuse it",
              E.recommend(preferredLanguages: ["sr-Latn-RS"], pastCallLanguages: [], memoryGB: 16) == "large-v3-turbo")
        check("recommend: no languages at all → Whisper",
              E.recommend(preferredLanguages: [], pastCallLanguages: [], memoryGB: 16) == "large-v3-turbo")
        let langs = E.pastCallLanguages(["Merhaba, bugün fiyatları konuşalım mı? Teklifinizi aldık, çok teşekkür ederiz.",
                                         "Thanks for joining, let's go through the pricing today."])
        check("recommend: reads past call languages", Set(langs) == ["tr", "en"])
        check("parakeet: model id is recognised", TranscriptionEngine.isParakeet("parakeet-v3") && !TranscriptionEngine.isParakeet("base"))
        check("parakeet: display name", TranscriptionEngine.displayName(for: "parakeet-v3") == "Parakeet v3")
    }

    static func testParakeetDoubt() {
        typealias T = TranscriptionEngine
        check("doubt: a sure English line asks nothing", !T.parakeetDoubts(0.98, seconds: 4))
        check("doubt: a Turkish-looking line asks for a check", T.parakeetDoubts(0.55, seconds: 4))
        check("doubt: a one-word line is too short to judge", !T.parakeetDoubts(0.3, seconds: 0.8))
    }

    static func testRouteNotices() {
        typealias T = TranscriptionEngine
        check("notice: Turkish on their side", T.noticeFor(.decided(.them, .whisper), heard: "tr") == "Turkish heard: using Whisper for them")
        check("notice: unsure on your side", T.noticeFor(.decided(.me, .whisper), heard: nil) == "Language unclear: using Whisper for you")
        check("notice: Parakeet decided → none", T.noticeFor(.decided(.me, .parakeet(language: "en")), heard: "en") == nil)
        check("notice: mid-call switch", T.noticeFor(.switchedToWhisper(.them), heard: "tr") == "Turkish heard: using Whisper for them from here")
    }

    static func testRewindRange() {
        let m = Meeting(title: "rewind")
        let lines = [(10.0, "Them"), (40.0, "Them"), (40.0, "Me"), (95.0, "Them")].map { t, label in
            TranscriptSegment(startTime: t, endTime: t + 3, text: "x", speakerLabel: label)
        }
        m.segments = lines
        check("rewind: only that side, only that stretch", Set(m.segmentIDs(label: "Them", in: 30...90)) == [lines[1].id])
        let clips: [[Float]] = [Array(repeating: 1, count: 16000 * 6), Array(repeating: 2, count: 16000 * 6)]
        let audio = TranscriptionEngine.recheckAudio(clips, seconds: 10)
        check("rewind: recheck uses the latest 10 s", audio.count == 16000 * 10 && audio.last == 2 && audio.first == 1)
    }

    static func testImportRoute() {
        typealias T = TranscriptionEngine
        check("import: three windows", T.importWindows(sampleCount: 16000 * 600).count == 3)
        check("import: a short file is one window", T.importWindows(sampleCount: 16000 * 20).count == 1)
        check("import: all English → Parakeet", T.importUsesParakeet([("en", 0.99), ("en", 0.95), ("en", 0.97)]))
        check("import: any Turkish → Whisper", !T.importUsesParakeet([("en", 0.99), ("tr", 0.99), ("en", 0.97)]))
        check("import: any unsure → Whisper", !T.importUsesParakeet([("en", 0.99), ("en", 0.5)]))
        check("import: nothing heard → Whisper", !T.importUsesParakeet([]))
        let frame = T.Segmenter.frame
        func speech(_ n: Int) -> [Float] { Array(repeating: 0.02, count: n * frame) }
        func silence(_ n: Int) -> [Float] { Array(repeating: 0.0001, count: n * frame) }
        let pieces = T.utterances(in: speech(10) + silence(10) + speech(10) + silence(10))
        check("import: the live cutter finds both lines", pieces.count == 2)
        check("import: the second line starts where it was spoken", pieces.count == 2 && abs(pieces[1].start - 20 * frame) <= frame)
        let long = T.utterances(in: speech(600))
        check("import: a minute without a pause is cut at the cap, all kept",
              long.count >= 5 && long.reduce(0) { $0 + $1.audio.count } == 600 * frame)
    }
}
