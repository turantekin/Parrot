import Foundation
import SwiftUI

/// Offscreen logic harness. Run: `.build/debug/Parrot --profile-test`
/// Prints PASS/FAIL per check and exits non-zero on any failure.
enum ProfileTest {
    private static var failures = 0

    private static func check(_ name: String, _ cond: @autoclosure () -> Bool) {
        if cond() { print("PASS \(name)") } else { print("FAIL \(name)"); failures += 1 }
    }

    @MainActor
    static func run() {
        testKindStyleFallback()
        testHexColor()
        testInsightKey()
        print(failures == 0 ? "ALL PASS" : "FAILURES: \(failures)")
        exit(failures == 0 ? 0 : 1)
    }

    static func testKindStyleFallback() {
        let blocker = KindResolver.fallbackStyle(forKey: "blocker")
        check("fallback blocker is pinned", blocker.isPinned == true)
        check("fallback blocker label", blocker.label == "Blocker")
        let unknown = KindResolver.fallbackStyle(forKey: "totally_made_up")
        check("fallback unknown not pinned", unknown.isPinned == false)
        check("fallback unknown has a label", !unknown.label.isEmpty)
    }

    static func testInsightKey() {
        let draft = InsightDraft(kindKey: "blocker", title: "Price too high", detail: "x", source: nil)
        check("draft carries kindKey", draft.kindKey == "blocker")
        let insight = Insight(kindKey: "buying_signal", title: "t", detail: "d", callTime: 0, source: nil)
        check("insight style resolves unknown key", insight.style.label == "Buying Signal")
        check("insight known key pinned", Insight(kindKey: "blocker", title: "t", detail: "d", callTime: 0, source: nil).style.isPinned)
    }

    static func testHexColor() {
        // Verify a 6-digit hex parses to the expected RGB components.
        let c = Color(hex: "2F7E96")
        let ns = NSColor(c).usingColorSpace(.sRGB)
        let epsilon = 2.0 / 255.0 // allow for rounding
        let redOK   = abs((ns?.redComponent   ?? -1) - (Double(0x2F) / 255.0)) < epsilon
        let greenOK = abs((ns?.greenComponent ?? -1) - (Double(0x7E) / 255.0)) < epsilon
        let blueOK  = abs((ns?.blueComponent  ?? -1) - (Double(0x96) / 255.0)) < epsilon
        check("hex 2F7E96 red component",   redOK)
        check("hex 2F7E96 green component", greenOK)
        check("hex 2F7E96 blue component",  blueOK)

        // Verify a malformed hex falls back to gray (not a crash).
        // SwiftUI's Color.gray resolves in sRGB to a neutral midtone (all channels ~0.5–0.7).
        let bad = Color(hex: "zzz")
        let nsBad = NSColor(bad).usingColorSpace(.sRGB)
        let r = nsBad?.redComponent ?? -1
        let g = nsBad?.greenComponent ?? -1
        let b = nsBad?.blueComponent ?? -1
        // All channels should be in the neutral midrange [0.4, 0.8] for a gray-like fallback.
        let grayOK = (0.4...0.8).contains(r) && (0.4...0.8).contains(g) && (0.4...0.8).contains(b)
        check("malformed hex falls back to gray", grayOK)
    }
}
