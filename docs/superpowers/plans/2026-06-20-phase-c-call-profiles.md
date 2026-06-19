# Phase C — Call Profiles + Customizable Copilot + Tone — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the copilot a per-call-type instrument — pick a profile before a call and it reshapes the insight kinds, persona/tone, scoped knowledge, and adds an always-on sentiment strip.

**Architecture:** A new SwiftData `CallProfile` model owns a reshapable set of insight *kinds* and *sentiment gauges* (Codable structs JSON-encoded on the model). The Claude prompt + JSON schema are built per profile; the live panel styles cards and renders a sentiment strip from the profile. Insight `kind` becomes a string *key* carried end-to-end, resolved for styling against active-profile → meeting-snapshot → a neutral fallback table. KB documents are tagged many-to-many into profiles; retrieval filters by the active profile.

**Tech Stack:** Swift 5.10, SwiftUI, SwiftData, macOS 14+, WhisperKit (unchanged), Claude Haiku via REST (`ClaudeAnalysisProvider`).

## Global Constraints

- **Verification idiom (no XCTest target exists):** logic is tested by an offscreen harness mode `--profile-test` wired in `ParrotMain.main()` (mirrors the existing `--transcribe-test`), which runs assertions and prints `PASS`/`FAIL` lines and exits non-zero on any failure. UI is verified by `swift build` + the existing `--snapshot` report harness + manual on-device eyeball (the Phase A/B pattern). **Never** invent a `pytest`/`XCTest` command — there is none.
- **Build commands:** debug compile-check `swift build` (exit 0 required). Release/install via the recipe in `docs/IMPROVEMENT-ROADMAP.md` (Build notes) — used only for on-device eyeball tasks, not per-step.
- **DerivedData caveat:** if `swift build` fails with `OrderedCollections`/`_DarwinFoundation2.pcm` module errors, that's the known Xcode-26.5 explicit-modules bug — `swift build` (SwiftPM) is the reliable path; do not switch to `xcodebuild`.
- **SwiftData model registration:** every new `@Model` type MUST be added to the `Schema([...])` in `Parrot/ParrotApp.swift:28` AND to the `SnapshotTool`/`TranscribeTest` in-memory containers if they build one, or the app crashes at launch (`fatalError("Could not create ModelContainer")`).
- **SwiftData insert order rule (existing, load-bearing):** always `modelContext.insert(obj)` BEFORE assigning a relationship (`obj.meeting = meeting`). See `RecordingManager.addSegment` comment. Apply the same for `CallProfile`.
- **Theme tokens:** all new UI uses `Theme.Colors` / `Theme.Typography` (`Parrot/Views/Theme.swift`). Accent is `Theme.Colors.accent`. No hardcoded colors except `ProfileKind.colorHex` / `SentimentGauge.colorHex` which are profile data (parse via a `Color(hex:)` helper, Task 1).
- **Behavior-preservation gate:** after Task 8 (migration wired), running the app with only the **Default** profile MUST reproduce today's behavior (same five kinds, same card colors/labels, same prompt intent). This is the parity checkpoint before presets/UI layer on top.
- **Source-validation backstop (existing, keep):** `ClaudeAnalysisProvider.validatingSources` must stay — it drops invented provenance. Task 5 adds a sibling kind-validation backstop.

---

## File structure

**New files:**
- `Parrot/Models/CallProfile.swift` — `@Model CallProfile` + `ProfileKind` + `SentimentGauge` Codable structs + computed accessors.
- `Parrot/Models/KindStyle.swift` — `KindStyle` value type + `KindResolver` (resolution chain) + the neutral fallback table + `Color(hex:)` helper.
- `Parrot/Services/ProfilePresets.swift` — the six built-in preset definitions (Default, Sales, Coaching, Interview, Support, Generic) as pure data.
- `Parrot/Services/ProfileStore.swift` — `@Observable` service: seeding/migration, `activeProfile`, `lastUsedProfileID`, fetch/create/duplicate/delete.
- `Parrot/Views/SentimentStripView.swift` — the always-on gauge strip.
- `Parrot/Views/ProfilesSettingsView.swift` — Profiles tab (list + light editor + "Edit advanced" rows + doc tagging).
- `Parrot/ProfileTest.swift` — the `--profile-test` offscreen harness (assertions).

**Modified files:**
- `Parrot/Models/Insight.swift` — `Insight.kind` enum → `kindKey: String`; `CallInsight.kindRaw` stays; drop enum-typed accessors.
- `Parrot/Models/Meeting.swift` — add `profile`, `brief`, `profileSnapshotData`.
- `Parrot/Services/AnalysisProvider.swift` — `AnalysisRequest` profile inputs; `AnalysisResult`; dynamic prompt + schema; kind validation.
- `Parrot/Services/CallAnalysisEngine.swift` — active profile, sentiment state, KB profile filter, key-based drafts.
- `Parrot/Services/KnowledgeBaseService.swift` — `KBDocument.profileIDs`; `search(query:profileID:topK:)`.
- `Parrot/Services/RecordingManager.swift` — `start(profile:brief:)`; persist `profile`/`brief`/snapshot; pass profile to summary/coaching.
- `Parrot/Services/ExportService.swift` — replace `insight.kind == .blocker` / `insight.kind.label` with key+resolver.
- `Parrot/ParrotApp.swift` — register `CallProfile` in `Schema`; seed/migrate at launch; inject `ProfileStore`.
- `Parrot/ParrotApp.swift` (`ParrotMain.main`) — dispatch `--profile-test`.
- `Parrot/Views/DashboardView.swift` — inline profile picker chips above the brief.
- `Parrot/Views/MenuBarView.swift` — start under last-used profile; show current profile label.
- `Parrot/Views/CopilotPanelView.swift` — key+resolver styling; pinned-by-kind zone; sentiment strip mount.
- `Parrot/Views/LiveRecordingView.swift` — pass profile/sentiment into the panel.
- `Parrot/Views/MeetingDetailView.swift` — resolve stored insight styling via snapshot/fallback.
- `Parrot/Views/SettingsView.swift` — add Profiles tab; Knowledge tab keeps shared library only.

---

## Task ordering rationale

Follows the spec's risk sequencing (§8): the `Insight.Kind`→key refactor lands **first**, behavior-preserving, verified for parity before anything reshapes the lens. Then model → presets/migration → KB scoping → provider → engine → recording → app-wiring/parity-gate → UI (picker, strip, editor, report). Logic tasks (1–9) each extend the `--profile-test` harness. UI tasks (10–14) verify by build + snapshot + manual.

---

### Task 1: `KindStyle` + resolver + hex color, and the `--profile-test` harness skeleton

Introduces the styling-resolution layer and the test harness both later tasks depend on. No behavior change yet.

**Files:**
- Create: `Parrot/Models/KindStyle.swift`
- Create: `Parrot/ProfileTest.swift`
- Modify: `Parrot/ParrotApp.swift` (`ParrotMain.main`, after the `--transcribe-test` block ~line 17)

**Interfaces:**
- Produces:
  - `struct KindStyle { let label: String; let color: Color; let iconSystemName: String; let isPinned: Bool }`
  - `enum KindResolver { static func fallbackStyle(forKey key: String) -> KindStyle }` (the neutral table covering today's five keys + a generic default for unknown keys)
  - `extension Color { init(hex: String) }`
  - `enum ProfileTest { static func run() }` printing `PASS`/`FAIL`, calling `exit(failures == 0 ? 0 : 1)`.

- [ ] **Step 1: Write the failing test (harness)**

Create `Parrot/ProfileTest.swift`:

```swift
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

    static func testHexColor() {
        // Smoke: a 6-digit hex parses without crashing and isn't the clear default.
        let c = Color(hex: "2F7E96")
        check("hex parses to a color", String(describing: c).isEmpty == false)
    }
}
```

- [ ] **Step 2: Wire `--profile-test` and run to verify it fails to build**

In `Parrot/ParrotApp.swift`, inside `ParrotMain.main()`, after the `--transcribe-test` block:

```swift
        if args.contains("--profile-test") {
            MainActor.assumeIsolated { ProfileTest.run() }
            return
        }
```

Run: `swift build 2>&1 | tail -5`
Expected: FAIL — `cannot find 'KindResolver'` / `cannot find 'Color(hex:)'`.

- [ ] **Step 3: Implement `KindStyle.swift`**

Create `Parrot/Models/KindStyle.swift`:

```swift
import SwiftUI

/// Resolved visual style for an insight kind key. The card never reads a profile
/// directly — it asks the resolver, which walks active-profile → meeting-snapshot
/// → this neutral fallback table.
struct KindStyle: Equatable {
    let label: String
    let color: Color
    let iconSystemName: String
    let isPinned: Bool
}

enum KindResolver {
    /// Neutral fallback covering today's five keys (so pre-Phase-C meetings render
    /// identically) plus a generic style for any unknown key.
    static func fallbackStyle(forKey key: String) -> KindStyle {
        switch key {
        case "suggestion":
            return KindStyle(label: "Suggested answer", color: Theme.Colors.subtle, iconSystemName: "lightbulb.fill", isPinned: false)
        case "question":
            return KindStyle(label: "Open question", color: Theme.Colors.accent, iconSystemName: "questionmark.circle.fill", isPinned: false)
        case "blocker":
            return KindStyle(label: "Blocker", color: Theme.Colors.blocker, iconSystemName: "exclamationmark.triangle.fill", isPinned: true)
        case "action_item":
            return KindStyle(label: "Action item", color: Theme.Colors.action, iconSystemName: "checkmark.circle.fill", isPinned: false)
        case "feedback":
            return KindStyle(label: "Feedback", color: Theme.Colors.ink2, iconSystemName: "chart.line.uptrend.xyaxis", isPinned: false)
        default:
            // Title-case the key as a last resort: "buying_signal" → "Buying Signal".
            let label = key.split(separator: "_").map { $0.capitalized }.joined(separator: " ")
            return KindStyle(label: label.isEmpty ? "Insight" : label,
                             color: Theme.Colors.ink2, iconSystemName: "sparkle", isPinned: false)
        }
    }
}

extension Color {
    /// Parses "RRGGBB" or "#RRGGBB". Falls back to gray on malformed input so a
    /// bad profile color can never crash the UI.
    init(hex: String) {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard s.count == 6, let v = UInt32(s, radix: 16) else { self = .gray; return }
        self = Color(
            red: Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255
        )
    }
}
```

- [ ] **Step 4: Build and run the harness — verify PASS**

Run: `swift build && .build/debug/Parrot --profile-test`
Expected: `PASS fallback blocker is pinned` … `ALL PASS`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add Parrot/Models/KindStyle.swift Parrot/ProfileTest.swift Parrot/ParrotApp.swift
git commit -m "Phase C: KindStyle resolver + hex color + --profile-test harness"
```

---

### Task 2: Refactor `Insight.kind` enum → `kindKey: String` (behavior-preserving)

The risky mechanical refactor, isolated. Carries a string key end-to-end; all styling now goes through `KindResolver.fallbackStyle` (Task 10 will prepend profile lookups). No new feature — today's five keys produce today's look.

**Files:**
- Modify: `Parrot/Models/Insight.swift`
- Modify: `Parrot/Services/AnalysisProvider.swift` (`InsightDraft`, `parseInsights`, `validatingSources`)
- Modify: `Parrot/Services/CallAnalysisEngine.swift:189` (draft→Insight mapping)
- Modify: `Parrot/Services/RecordingManager.swift:197` (`$0.kind.label`)
- Modify: `Parrot/Services/ExportService.swift:40-41`
- Modify: `Parrot/Views/CopilotPanelView.swift` (all `insight.kind == .X`, the `Insight.Kind` extension ~538-565)
- Modify: `Parrot/Views/MeetingDetailView.swift:494-504`
- Modify: `Parrot/ProfileTest.swift` (add assertions)

**Interfaces:**
- Produces:
  - `struct Insight { let kindKey: String; … }` (was `kind: Kind`)
  - `struct InsightDraft { let kindKey: String; … }`
  - `CallInsight.kindRaw` unchanged (already a String); remove `CallInsight.kind` enum accessor.
  - Helper on both: `var style: KindStyle { KindResolver.fallbackStyle(forKey: kindKey) }` (Task 10 swaps the resolver for a profile-aware one via an injected closure — but the property name stays `style`).
- Consumes: `KindResolver` (Task 1).

- [ ] **Step 1: Add failing assertions to the harness**

In `Parrot/ProfileTest.swift`, add to `run()` before the print: `testInsightKey()`, and add:

```swift
    static func testInsightKey() {
        let draft = InsightDraft(kindKey: "blocker", title: "Price too high", detail: "x", source: nil)
        check("draft carries kindKey", draft.kindKey == "blocker")
        let insight = Insight(kindKey: "buying_signal", title: "t", detail: "d", callTime: 0, source: nil)
        check("insight style resolves unknown key", insight.style.label == "Buying Signal")
        check("insight known key pinned", Insight(kindKey: "blocker", title: "t", detail: "d", callTime: 0, source: nil).style.isPinned)
    }
```

- [ ] **Step 2: Run to verify it fails to build**

Run: `swift build 2>&1 | tail -5`
Expected: FAIL — `InsightDraft has no member 'kindKey'` (and others).

- [ ] **Step 3: Rewrite `Insight.swift`**

Replace the `enum Kind` and `kind` usages. New `Parrot/Models/Insight.swift`:

```swift
import Foundation
import SwiftData

/// A single piece of live call intelligence produced by the CallAnalysisEngine.
struct Insight: Identifiable, Equatable {
    let id = UUID()
    /// Stable kind key from the active profile (e.g. "suggestion", "objection",
    /// "reflection"). Styling is resolved from this key, never hardcoded.
    let kindKey: String
    let title: String
    let detail: String
    let callTime: TimeInterval
    let source: String?
    let createdAt = Date()
    var isHandled = false

    var style: KindStyle { KindResolver.fallbackStyle(forKey: kindKey) }

    var formattedCallTime: String {
        let minutes = Int(callTime) / 60
        let seconds = Int(callTime) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

@Model
final class CallInsight {
    var id: UUID
    var meeting: Meeting?
    var kindRaw: String
    var title: String
    var detail: String
    var callTime: TimeInterval
    var source: String?
    var isHandled: Bool

    init(from insight: Insight) {
        self.id = insight.id
        self.kindRaw = insight.kindKey
        self.title = insight.title
        self.detail = insight.detail
        self.callTime = insight.callTime
        self.source = insight.source
        self.isHandled = insight.isHandled
    }

    var style: KindStyle { KindResolver.fallbackStyle(forKey: kindRaw) }

    var formattedCallTime: String {
        let minutes = Int(callTime) / 60
        let seconds = Int(callTime) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
```

- [ ] **Step 4: Update `AnalysisProvider.swift`**

`InsightDraft` (top of file):

```swift
struct InsightDraft {
    let kindKey: String
    let title: String
    let detail: String
    let source: String?
}
```

`parseInsights` (~329): drop the `Insight.Kind(rawValue:)` guard; map directly:

```swift
        return payload.insights.map { item in
            InsightDraft(kindKey: item.kind, title: item.title, detail: item.detail, source: item.source?.nilIfEmpty)
        }
```

`validatingSources` (~325): build with `kindKey`:

```swift
            return InsightDraft(kindKey: draft.kindKey, title: draft.title, detail: draft.detail, source: nil)
```

- [ ] **Step 5: Update `CallAnalysisEngine.swift` (~187)**

```swift
                    Insight(
                        kindKey: $0.kindKey,
                        title: $0.title,
                        detail: $0.detail,
                        callTime: anchorTime,
                        source: $0.source
                    )
```

- [ ] **Step 6: Update `RecordingManager.swift:197` and `ExportService.swift:40-41`**

`RecordingManager` line 197:

```swift
        let insightTitles = meeting.sortedInsights.map { "\($0.style.label): \($0.title)" }
```

`ExportService` lines 40–41:

```swift
                var line = "[\(insight.formattedCallTime)] \(insight.style.label): \(insight.title)"
                if insight.kindRaw == "blocker" {
```

- [ ] **Step 7: Update views to use `.style` and `kindKey`/`kindRaw`**

In `Parrot/Views/MeetingDetailView.swift` (~494-504) replace `insight.kind.icon`→`insight.style.iconSystemName`, `insight.kind.color`→`insight.style.color`, `insight.kind == .blocker`→`insight.kindRaw == "blocker"`.

In `Parrot/Views/CopilotPanelView.swift`:
- Delete the `extension Insight.Kind { … }` block (~538-565) — replaced by `KindStyle`.
- Replace every `insight.kind.icon`/`.color`/`.label` with `insight.style.iconSystemName`/`.color`/`.label`.
- Replace `insight.kind == .blocker` → `insight.style.isPinned` (the pinned-zone concept is now "isPinned", not "is blocker"); `insight.kind == .suggestion` → `insight.kindKey == "suggestion"`; `insight.kind == .actionItem` → `insight.kindKey == "action_item"`.
- The tab filter enum (`.suggestions/.blockers/.actions` ~34-45) — for this task keep it compiling by mapping: `.blockers` → `insight.style.isPinned`; `.actions` → `insight.kindKey == "action_item"`; `.suggestions` → everything else. (Task 10 replaces this with a profile-driven pinned-zone + single feed.)

- [ ] **Step 8: Build, run harness + snapshot — verify parity**

Run: `swift build && .build/debug/Parrot --profile-test`
Expected: `ALL PASS`.
Run: `.build/debug/Parrot --snapshot /tmp/report.png` and open it.
Expected: report renders, insight icons/colors identical to before the refactor.

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "Phase C: carry insight kind as string key end-to-end (behavior-preserving)"
```

---

### Task 3: `CallProfile` model + `ProfileKind` / `SentimentGauge` structs

**Files:**
- Create: `Parrot/Models/CallProfile.swift`
- Modify: `Parrot/ProfileTest.swift`

**Interfaces:**
- Produces:
  - `struct ProfileKind: Codable, Identifiable, Hashable { var id: UUID; var key: String; var label: String; var colorHex: String; var iconSystemName: String; var triggerDescription: String; var isPinned: Bool; var priority: Int }`
  - `struct SentimentGauge: Codable, Identifiable, Hashable { var id: UUID; var key: String; var label: String; var lowLabel: String; var highLabel: String; var colorHex: String }`
  - `@Model final class CallProfile` with stored `kindsData: Data`, `gaugesData: Data`, and computed `var kinds: [ProfileKind]` / `var gauges: [SentimentGauge]` (get decodes, set encodes), plus `style(forKey:) -> KindStyle?`.

- [ ] **Step 1: Add failing assertions**

In `ProfileTest.run()` add `testCallProfile()`:

```swift
    static func testCallProfile() {
        let kind = ProfileKind(id: UUID(), key: "objection", label: "Objection",
            colorHex: "E8943A", iconSystemName: "hand.raised.fill",
            triggerDescription: "Them raised a concern", isPinned: true, priority: 10)
        let p = CallProfile(name: "Sales", iconSystemName: "dollarsign.circle",
            summary: "x", isBuiltIn: true, sortOrder: 0, persona: "p", tone: "t",
            allowGeneralKnowledge: true, kinds: [kind], gauges: [])
        check("profile round-trips kinds", p.kinds.first?.key == "objection")
        let style = p.style(forKey: "objection")
        check("profile style label", style?.label == "Objection")
        check("profile style pinned", style?.isPinned == true)
        check("profile unknown key nil", p.style(forKey: "nope") == nil)
    }
```

- [ ] **Step 2: Run, verify fail-to-build**

Run: `swift build 2>&1 | tail -5`
Expected: FAIL — `cannot find 'CallProfile'`.

- [ ] **Step 3: Implement `CallProfile.swift`**

```swift
import Foundation
import SwiftData

struct ProfileKind: Codable, Identifiable, Hashable {
    var id: UUID
    var key: String
    var label: String
    var colorHex: String
    var iconSystemName: String
    var triggerDescription: String
    var isPinned: Bool
    var priority: Int
}

struct SentimentGauge: Codable, Identifiable, Hashable {
    var id: UUID
    var key: String
    var label: String
    var lowLabel: String
    var highLabel: String
    var colorHex: String
}

@Model
final class CallProfile {
    var id: UUID
    var name: String
    var iconSystemName: String
    var summary: String
    var isBuiltIn: Bool
    var sortOrder: Int
    var persona: String
    var tone: String
    var allowGeneralKnowledge: Bool
    /// JSON-encoded [ProfileKind] / [SentimentGauge] — config, not queried entities.
    var kindsData: Data
    var gaugesData: Data

    @Relationship(inverse: \Meeting.profile)
    var meetings: [Meeting] = []

    init(id: UUID = UUID(), name: String, iconSystemName: String, summary: String,
         isBuiltIn: Bool, sortOrder: Int, persona: String, tone: String,
         allowGeneralKnowledge: Bool, kinds: [ProfileKind], gauges: [SentimentGauge]) {
        self.id = id
        self.name = name
        self.iconSystemName = iconSystemName
        self.summary = summary
        self.isBuiltIn = isBuiltIn
        self.sortOrder = sortOrder
        self.persona = persona
        self.tone = tone
        self.allowGeneralKnowledge = allowGeneralKnowledge
        self.kindsData = (try? JSONEncoder().encode(kinds)) ?? Data()
        self.gaugesData = (try? JSONEncoder().encode(gauges)) ?? Data()
    }

    var kinds: [ProfileKind] {
        get { (try? JSONDecoder().decode([ProfileKind].self, from: kindsData)) ?? [] }
        set { kindsData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    var gauges: [SentimentGauge] {
        get { (try? JSONDecoder().decode([SentimentGauge].self, from: gaugesData)) ?? [] }
        set { gaugesData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    /// Profile-defined style for a key, or nil if this profile doesn't define it.
    func style(forKey key: String) -> KindStyle? {
        guard let k = kinds.first(where: { $0.key == key }) else { return nil }
        return KindStyle(label: k.label, color: Color(hex: k.colorHex),
                         iconSystemName: k.iconSystemName, isPinned: k.isPinned)
    }
}
```

Note: `style(forKey:)` returns `KindStyle` which uses SwiftUI `Color` — add `import SwiftUI` to the file (replace `import Foundation` line with both `import Foundation` and `import SwiftUI`).

- [ ] **Step 4: Build + run harness — verify PASS**

Run: `swift build && .build/debug/Parrot --profile-test`
Expected: `ALL PASS`.

- [ ] **Step 5: Commit**

```bash
git add Parrot/Models/CallProfile.swift Parrot/ProfileTest.swift
git commit -m "Phase C: CallProfile model + ProfileKind/SentimentGauge structs"
```

---

### Task 4: Built-in preset definitions (`ProfilePresets`)

Pure data — the six presets from the spec §3. No wiring yet.

**Files:**
- Create: `Parrot/Services/ProfilePresets.swift`
- Modify: `Parrot/ProfileTest.swift`

**Interfaces:**
- Produces:
  - `enum ProfilePresets { static let defaultProfileID: UUID; static func all() -> [CallProfile]; static func makeDefault(persona: String, tone: String, allowGeneralKnowledge: Bool) -> CallProfile }`
  - Each preset uses a **stable hardcoded UUID** (so seeding is idempotent). Default's id == `defaultProfileID`.

- [ ] **Step 1: Add failing assertions**

In `ProfileTest.run()` add `testPresets()`:

```swift
    static func testPresets() {
        let all = ProfilePresets.all()
        check("six presets", all.count == 6)
        check("default first by sortOrder", all.sorted { $0.sortOrder < $1.sortOrder }.first?.id == ProfilePresets.defaultProfileID)
        let coaching = all.first { $0.name == "1:1 coaching" }
        check("coaching has reflection kind", coaching?.kinds.contains { $0.key == "reflection" } == true)
        check("coaching has NO blocker kind", coaching?.kinds.contains { $0.key == "blocker" } == false)
        check("sales has buying_temperature gauge", all.first { $0.name == "Sales discovery" }?.gauges.contains { $0.key == "buying_temperature" } == true)
        let def = all.first { $0.id == ProfilePresets.defaultProfileID }
        check("default has today's five keys", Set(def?.kinds.map(\.key) ?? []) == ["suggestion", "question", "blocker", "action_item", "feedback"])
    }
```

- [ ] **Step 2: Run, verify fail-to-build**

Run: `swift build 2>&1 | tail -5`
Expected: FAIL — `cannot find 'ProfilePresets'`.

- [ ] **Step 3: Implement `ProfilePresets.swift`**

Define stable UUIDs and the six profiles. Use the spec §3 table for kinds/gauges. (Colors: reuse Theme hexes — accent `2F7E96`, action `3F9168`, blocker `E8943A`, subtle/indigo `4F6FB0`, ink2 `5F6470`.) Full file:

```swift
import Foundation

enum ProfilePresets {
    static let defaultProfileID = UUID(uuidString: "00000000-0000-0000-0000-0000000000D1")!
    private static let salesID    = UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!
    private static let coachingID = UUID(uuidString: "00000000-0000-0000-0000-0000000000C2")!
    private static let interviewID = UUID(uuidString: "00000000-0000-0000-0000-0000000000C3")!
    private static let supportID  = UUID(uuidString: "00000000-0000-0000-0000-0000000000C4")!
    private static let genericID  = UUID(uuidString: "00000000-0000-0000-0000-0000000000C5")!

    private static func kind(_ key: String, _ label: String, _ hex: String, _ icon: String,
                             _ trigger: String, pinned: Bool = false, priority: Int = 0) -> ProfileKind {
        ProfileKind(id: UUID(), key: key, label: label, colorHex: hex, iconSystemName: icon,
                    triggerDescription: trigger, isPinned: pinned, priority: priority)
    }
    private static func gauge(_ key: String, _ label: String, _ low: String, _ high: String, _ hex: String) -> SentimentGauge {
        SentimentGauge(id: UUID(), key: key, label: label, lowLabel: low, highLabel: high, colorHex: hex)
    }

    /// Default = today's exact behavior. persona/tone/fallback injected from migration.
    static func makeDefault(persona: String, tone: String, allowGeneralKnowledge: Bool) -> CallProfile {
        CallProfile(
            id: defaultProfileID, name: "Default", iconSystemName: "person.wave.2",
            summary: "General-purpose copilot (your current setup).",
            isBuiltIn: true, sortOrder: 0, persona: persona, tone: tone,
            allowGeneralKnowledge: allowGeneralKnowledge,
            kinds: [
                kind("suggestion", "Suggested answer", "4F6FB0", "lightbulb.fill", "Them asked something or raised a topic — draft a short, concrete answer Me can say now."),
                kind("question", "Open question", "2F7E96", "questionmark.circle.fill", "Them asked a direct question Me has NOT answered yet — surface it briefly."),
                kind("blocker", "Blocker", "E8943A", "exclamationmark.triangle.fill", "Them raised an objection or obstacle (price, timing, decision maker, competitor) Me hasn't resolved.", pinned: true, priority: 10),
                kind("action_item", "Action item", "3F9168", "checkmark.circle.fill", "Me committed to do something after the call; include any time/date mentioned."),
                kind("feedback", "Feedback", "5F6470", "chart.line.uptrend.xyaxis", "A brief read on a SIGNIFICANT shift only — sparingly."),
            ],
            gauges: [gauge("my_dominance", "You're talking", "Balanced", "Dominating", "5F6470")]
        )
    }

    static func all() -> [CallProfile] {
        [
            makeDefault(persona: defaultPersona, tone: "", allowGeneralKnowledge: true),
            CallProfile(id: salesID, name: "Sales discovery", iconSystemName: "dollarsign.circle",
                summary: "Discovery & objection handling for sales calls.",
                isBuiltIn: true, sortOrder: 1,
                persona: "You are a sharp B2B sales copilot helping Me run a discovery call. Favor curiosity and qualification over pitching; help Me uncover pain, budget, and decision process.",
                tone: "", allowGeneralKnowledge: true,
                kinds: [
                    kind("suggestion", "Suggested answer", "4F6FB0", "lightbulb.fill", "Them asked something — draft a short concrete answer Me can say now."),
                    kind("objection", "Objection", "E8943A", "hand.raised.fill", "Them raised a concern (price, timing, competitor, authority) Me hasn't resolved.", pinned: true, priority: 10),
                    kind("buying_signal", "Buying signal", "3F9168", "arrow.up.right.circle.fill", "Them showed interest or intent — note it so Me can advance."),
                    kind("next_step", "Next step", "2F7E96", "calendar.badge.plus", "A concrete next step or commitment to propose or confirm."),
                    kind("discovery_gap", "Discovery gap", "5F6470", "magnifyingglass", "An important unknown (budget, timeline, decision maker) Me hasn't asked about."),
                ],
                gauges: [gauge("buying_temperature", "Buying temp", "Cold", "Hot", "E8943A"),
                         gauge("my_dominance", "You're talking", "Balanced", "Dominating", "5F6470")]),
            CallProfile(id: coachingID, name: "1:1 coaching", iconSystemName: "heart.text.square",
                summary: "Supportive listening for coaching / 1:1s.",
                isBuiltIn: true, sortOrder: 2,
                persona: "You are a warm, non-judgmental coaching copilot. Help Me listen deeply, reflect back, and ask open questions. Never frame the other person as an objection or obstacle.",
                tone: "", allowGeneralKnowledge: true,
                kinds: [
                    kind("reflection", "Reflection", "4F6FB0", "quote.bubble.fill", "Offer a brief reflective statement Me could mirror back to show understanding."),
                    kind("open_question", "Open question", "2F7E96", "questionmark.circle.fill", "A non-leading open question Me could ask to deepen the conversation."),
                    kind("emotional_cue", "Emotional cue", "E8943A", "waveform.path.ecg", "Them expressed a notable emotion (frustration, relief, worry) worth acknowledging.", pinned: false, priority: 5),
                    kind("commitment", "Commitment", "3F9168", "checkmark.circle.fill", "Either side committed to a concrete next step; include any timing."),
                    kind("coaching_moment", "Coaching moment", "5F6470", "lightbulb.fill", "An opening for Me to offer guidance or a useful reframe."),
                ],
                gauges: [gauge("client_openness", "Openness", "Guarded", "Open", "2F7E96"),
                         gauge("my_dominance", "You're talking", "Balanced", "Dominating", "5F6470")]),
            CallProfile(id: interviewID, name: "Interview", iconSystemName: "person.crop.rectangle.stack",
                summary: "For when you're interviewing a candidate.",
                isBuiltIn: true, sortOrder: 3,
                persona: "You are an interview copilot helping Me assess a candidate fairly. Surface follow-ups, signals, and red flags; help Me cover the ground I planned.",
                tone: "", allowGeneralKnowledge: true,
                kinds: [
                    kind("follow_up_question", "Follow-up", "2F7E96", "questionmark.circle.fill", "A sharp follow-up question to probe the candidate's last answer."),
                    kind("red_flag", "Red flag", "E8943A", "flag.fill", "Something concerning in the candidate's answer worth noting.", pinned: true, priority: 10),
                    kind("strong_signal", "Strong signal", "3F9168", "star.fill", "A strong positive signal worth recording."),
                    kind("topic_to_cover", "Topic to cover", "4F6FB0", "list.bullet", "A planned topic Me hasn't covered yet."),
                    kind("note", "Note", "5F6470", "note.text", "A neutral observation worth capturing."),
                ],
                gauges: [gauge("candidate_confidence", "Confidence", "Hesitant", "Confident", "3F9168")]),
            CallProfile(id: supportID, name: "Customer support", iconSystemName: "lifepreserver",
                summary: "Resolve issues and keep customers calm.",
                isBuiltIn: true, sortOrder: 4,
                persona: "You are a calm, helpful support copilot. Help Me resolve the customer's issue clearly and keep them reassured.",
                tone: "", allowGeneralKnowledge: true,
                kinds: [
                    kind("answer", "Answer", "4F6FB0", "lightbulb.fill", "Them asked something — draft a clear, accurate answer Me can give."),
                    kind("unresolved_issue", "Unresolved issue", "E8943A", "exclamationmark.triangle.fill", "An issue Them raised that Me hasn't resolved.", pinned: true, priority: 10),
                    kind("frustration_cue", "Frustration cue", "E8943A", "waveform.path.ecg", "Them is getting frustrated — note it so Me can de-escalate."),
                    kind("follow_up", "Follow-up", "3F9168", "arrow.uturn.right", "A follow-up action Me should take or promise."),
                    kind("note", "Note", "5F6470", "note.text", "A neutral observation worth capturing."),
                ],
                gauges: [gauge("customer_frustration", "Frustration", "Calm", "Upset", "E8943A")]),
            CallProfile(id: genericID, name: "Generic", iconSystemName: "bubble.left.and.bubble.right",
                summary: "Minimal, neutral copilot for any call.",
                isBuiltIn: true, sortOrder: 5,
                persona: "You are a neutral meeting copilot. Surface useful suggestions, open questions, and action items without assuming the call's purpose.",
                tone: "", allowGeneralKnowledge: true,
                kinds: [
                    kind("suggestion", "Suggestion", "4F6FB0", "lightbulb.fill", "A useful thing Me could say in response to the recent conversation."),
                    kind("question", "Open question", "2F7E96", "questionmark.circle.fill", "A direct question Them asked that Me hasn't answered."),
                    kind("action_item", "Action item", "3F9168", "checkmark.circle.fill", "Something Me committed to; include any timing."),
                    kind("note", "Note", "5F6470", "note.text", "A neutral observation worth capturing."),
                ],
                gauges: [gauge("engagement", "Engagement", "Flat", "Engaged", "2F7E96")]),
        ]
    }

    /// The framing scaffold the Default profile uses (mirrors today's hardcoded prompt intent).
    private static let defaultPersona = "You are a live call copilot helping Me on a call. Draft short, concrete things Me can say, flag obstacles, and capture commitments."
}
```

- [ ] **Step 4: Build + run harness — verify PASS**

Run: `swift build && .build/debug/Parrot --profile-test`
Expected: `ALL PASS`.

- [ ] **Step 5: Commit**

```bash
git add Parrot/Services/ProfilePresets.swift Parrot/ProfileTest.swift
git commit -m "Phase C: six built-in profile presets (pure data)"
```

---

### Task 5: `Meeting` profile fields + `ProfileStore` (seeding/migration/active profile)

**Files:**
- Modify: `Parrot/Models/Meeting.swift` (add fields)
- Create: `Parrot/Services/ProfileStore.swift`
- Modify: `Parrot/ProfileTest.swift`

**Interfaces:**
- Produces:
  - `Meeting.profile: CallProfile?`, `Meeting.brief: String?`, `Meeting.profileSnapshotData: Data?` + computed `var snapshotKinds: [ProfileKind]` (decode).
  - `@MainActor @Observable final class ProfileStore { var activeProfile: CallProfile?; func seedAndMigrateIfNeeded(context: ModelContext, knowledgeBase: KnowledgeBaseService); func profiles(in:) -> [CallProfile]; func duplicate(_:in:) -> CallProfile; func delete(_:in:) }`
  - `lastUsedProfileID` persisted via `UserDefaults` (`"lastUsedProfileID"`).
- Consumes: `ProfilePresets`, `CallProfile`, `KnowledgeBaseService` (Task 6 adds `profileIDs`; for migration, this task references `knowledgeBase.tagAllDocuments(into:)` — define that stub in Task 6; to keep Task 5 self-contained, gate the KB tagging behind `#if` is NOT allowed — instead Task 5 adds the `tagAllDocuments` call and Task 6 implements it. Order: do Task 6 KB changes BEFORE this task's KB call compiles. **Reorder note:** implement Task 6 first if doing strict TDD; this plan lists Task 6 right after.)

> Sequencing fix: do **Task 6 (KB)** before Task 5's migration step that calls KB. The two are presented adjacent; the executor should implement Task 6's `KBDocument.profileIDs` + `tagAllDocuments(into:)` first, then Task 5's `seedAndMigrateIfNeeded`. Steps below assume that.

- [ ] **Step 1: Add failing assertions**

In `ProfileTest.run()` add `testMigration()` (uses an in-memory container):

```swift
    static func testMigration() {
        let schema = Schema([Meeting.self, TranscriptSegment.self, CallInsight.self, CallProfile.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        guard let container = try? ModelContainer(for: schema, configurations: [config]) else {
            check("migration container builds", false); return
        }
        let ctx = ModelContext(container)
        let kb = KnowledgeBaseService()
        let store = ProfileStore()
        UserDefaults.standard.set("be concise", forKey: "copilotInstructions")
        store.seedAndMigrateIfNeeded(context: ctx, knowledgeBase: kb)
        let profiles = (try? ctx.fetch(FetchDescriptor<CallProfile>())) ?? []
        check("seeded six profiles", profiles.count == 6)
        let def = profiles.first { $0.id == ProfilePresets.defaultProfileID }
        check("default absorbed instructions as tone", def?.tone == "be concise")
        // Idempotent: second run doesn't duplicate.
        store.seedAndMigrateIfNeeded(context: ctx, knowledgeBase: kb)
        check("seeding idempotent", ((try? ctx.fetch(FetchDescriptor<CallProfile>()))?.count ?? 0) == 6)
    }
```

- [ ] **Step 2: Run, verify fail-to-build**

Run: `swift build 2>&1 | tail -5`
Expected: FAIL — `cannot find 'ProfileStore'` / `Meeting has no member 'profile'`.

- [ ] **Step 3: Add `Meeting` fields**

In `Parrot/Models/Meeting.swift`, after `themName` (line 27):

```swift
    /// Profile recorded under (nil for pre-Phase-C meetings).
    var profile: CallProfile?
    /// One-line brief for this specific call (was ephemeral nextCallBrief).
    var brief: String?
    /// Denormalized [ProfileKind] used at record time, so the report renders with
    /// the right kind labels/colors even if the profile is later edited/deleted.
    var profileSnapshotData: Data?
```

And a computed accessor at the bottom of the class:

```swift
    var snapshotKinds: [ProfileKind] {
        guard let data = profileSnapshotData else { return [] }
        return (try? JSONDecoder().decode([ProfileKind].self, from: data)) ?? []
    }
```

(Leave `init` as-is; new fields default to nil.)

- [ ] **Step 4: Implement `ProfileStore.swift`**

```swift
import Foundation
import SwiftData
import Observation

@MainActor
@Observable
final class ProfileStore {
    var activeProfile: CallProfile?

    private let lastUsedKey = "lastUsedProfileID"

    func seedAndMigrateIfNeeded(context: ModelContext, knowledgeBase: KnowledgeBaseService) {
        let existing = (try? context.fetch(FetchDescriptor<CallProfile>())) ?? []
        guard existing.isEmpty else {
            setActiveFromLastUsed(existing)
            return
        }
        // First run: seed presets. Default absorbs today's global settings.
        let instructions = UserDefaults.standard.string(forKey: "copilotInstructions") ?? ""
        let fallback = UserDefaults.standard.object(forKey: "copilotGeneralFallback") as? Bool ?? true
        var presets = ProfilePresets.all()
        if let defIndex = presets.firstIndex(where: { $0.id == ProfilePresets.defaultProfileID }) {
            presets[defIndex] = ProfilePresets.makeDefault(
                persona: presets[defIndex].persona, tone: instructions, allowGeneralKnowledge: fallback)
        }
        for p in presets { context.insert(p) }
        try? context.save()
        // Tag all existing KB docs into Default so today's knowledge keeps working.
        knowledgeBase.tagAllDocuments(into: ProfilePresets.defaultProfileID)
        setActiveFromLastUsed(presets)
    }

    func profiles(in context: ModelContext) -> [CallProfile] {
        let all = (try? context.fetch(FetchDescriptor<CallProfile>())) ?? []
        return all.sorted { $0.sortOrder < $1.sortOrder }
    }

    func setActive(_ profile: CallProfile) {
        activeProfile = profile
        UserDefaults.standard.set(profile.id.uuidString, forKey: lastUsedKey)
    }

    private func setActiveFromLastUsed(_ profiles: [CallProfile]) {
        let sorted = profiles.sorted { $0.sortOrder < $1.sortOrder }
        if let raw = UserDefaults.standard.string(forKey: lastUsedKey),
           let id = UUID(uuidString: raw),
           let match = sorted.first(where: { $0.id == id }) {
            activeProfile = match
        } else {
            activeProfile = sorted.first
        }
    }

    @discardableResult
    func duplicate(_ profile: CallProfile, in context: ModelContext) -> CallProfile {
        let maxOrder = profiles(in: context).map(\.sortOrder).max() ?? 0
        let copy = CallProfile(
            name: profile.name + " copy", iconSystemName: profile.iconSystemName,
            summary: profile.summary, isBuiltIn: false, sortOrder: maxOrder + 1,
            persona: profile.persona, tone: profile.tone,
            allowGeneralKnowledge: profile.allowGeneralKnowledge,
            kinds: profile.kinds, gauges: profile.gauges)
        context.insert(copy)
        try? context.save()
        return copy
    }

    func delete(_ profile: CallProfile, in context: ModelContext) {
        guard !profile.isBuiltIn else { return }
        context.delete(profile)
        try? context.save()
    }
}
```

- [ ] **Step 5: Build + run harness — verify PASS**

Run: `swift build && .build/debug/Parrot --profile-test`
Expected: `ALL PASS` (requires Task 6 already done so `tagAllDocuments` exists).

- [ ] **Step 6: Commit**

```bash
git add Parrot/Models/Meeting.swift Parrot/Services/ProfileStore.swift Parrot/ProfileTest.swift
git commit -m "Phase C: Meeting profile fields + ProfileStore seeding/migration"
```

---

### Task 6: KB profile tagging + scoped retrieval

> Implement this BEFORE Task 5's migration step compiles (see Task 5 sequencing note).

**Files:**
- Modify: `Parrot/Models/KnowledgeBase.swift` (the `KBDocument` struct — find it: `rg -n "struct KBDocument" Parrot`)
- Modify: `Parrot/Services/KnowledgeBaseService.swift`
- Modify: `Parrot/ProfileTest.swift`

**Interfaces:**
- Produces:
  - `KBDocument.profileIDs: Set<UUID>` (Codable; default `[]`).
  - `KnowledgeBaseService.search(query:profileID:topK:)` — filters chunks to docs tagged into `profileID`; `profileID == nil` searches all (back-compat).
  - `KnowledgeBaseService.tagAllDocuments(into id: UUID)`, `func setProfiles(_ ids: Set<UUID>, for: KBDocument)`, `func documentNames(for profileID: UUID) -> [String]`.

- [ ] **Step 1: Add failing assertions**

In `ProfileTest.run()` add `testKBScoping()`:

```swift
    static func testKBScoping() {
        let kb = KnowledgeBaseService()
        // With no docs, scoped search returns empty and doesn't crash.
        Task { @MainActor in
            let r = await kb.search(query: "anything", profileID: ProfilePresets.defaultProfileID)
            check("scoped search on empty KB is empty", r.isEmpty)
        }
        check("documentNames empty for unknown profile", kb.documentNames(for: UUID()).isEmpty)
    }
```

(Note: the async portion is best-effort smoke; the synchronous checks are the gate.)

- [ ] **Step 2: Run, verify fail-to-build**

Run: `swift build 2>&1 | tail -5`
Expected: FAIL — `search(query:profileID:)` / `documentNames` / `tagAllDocuments` not found.

- [ ] **Step 3: Add `profileIDs` to `KBDocument`**

In `Parrot/Models/KnowledgeBase.swift`, add to `KBDocument` (keep `Codable`):

```swift
    var profileIDs: Set<UUID> = []
```

If `KBDocument` has a memberwise `init`, add `profileIDs: Set<UUID> = []` param defaulting to empty so existing call sites compile. Ensure the decoder tolerates old JSON missing the key (a `Set<UUID>` with a default works because of synthesized `Codable` only if the property has a default AND you implement `init(from:)` leniently — simplest: make it `var profileIDs: Set<UUID> = []` and add a custom `init(from:)` that `decodeIfPresent`s it). Add:

```swift
    enum CodingKeys: String, CodingKey { case id, name, note, chunkCount, addedAt, profileIDs }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        note = try c.decode(String.self, forKey: .note)
        chunkCount = try c.decode(Int.self, forKey: .chunkCount)
        addedAt = try c.decode(Date.self, forKey: .addedAt)
        profileIDs = try c.decodeIfPresent(Set<UUID>.self, forKey: .profileIDs) ?? []
    }
```

(Adjust field names to the actual `KBDocument` definition.)

- [ ] **Step 4: Add scoping methods + filter to `KnowledgeBaseService`**

Add methods:

```swift
    func tagAllDocuments(into id: UUID) {
        for i in documents.indices { documents[i].profileIDs.insert(id) }
        save()
    }

    func setProfiles(_ ids: Set<UUID>, for document: KBDocument) {
        guard let i = documents.firstIndex(where: { $0.id == document.id }) else { return }
        documents[i].profileIDs = ids
        save()
    }

    func documentNames(for profileID: UUID) -> [String] {
        documents.filter { $0.profileIDs.contains(profileID) }.map(\.name)
    }
```

Change `search` signature and add the filter. Replace `func search(query: String, topK: Int = 4) async -> [KBReference]` with:

```swift
    func search(query: String, profileID: UUID? = nil, topK: Int = 4) async -> [KBReference] {
        guard !chunks.isEmpty, !query.isEmpty else { return [] }

        // Restrict to documents tagged into this profile (nil = all, back-compat).
        let allowedNames: Set<String>? = profileID.map { id in
            Set(documents.filter { $0.profileIDs.contains(id) }.map(\.name))
        }
        let snapshot = allowedNames.map { names in chunks.filter { names.contains($0.documentName) } } ?? chunks
        guard !snapshot.isEmpty else { return [] }
        // … rest of the existing body, but using `snapshot` (already named that) …
```

The existing body already binds `let snapshot = chunks` — replace that line with the two lines above (compute `allowedNames` then `snapshot`), keeping the remainder unchanged.

- [ ] **Step 5: Build + run harness — verify PASS**

Run: `swift build && .build/debug/Parrot --profile-test`
Expected: `ALL PASS`.

- [ ] **Step 6: Commit**

```bash
git add Parrot/Models/KnowledgeBase.swift Parrot/Services/KnowledgeBaseService.swift Parrot/ProfileTest.swift
git commit -m "Phase C: KB profile tagging + scoped retrieval"
```

---

### Task 7: Dynamic prompt + schema + `AnalysisResult` in `ClaudeAnalysisProvider`

**Files:**
- Modify: `Parrot/Services/AnalysisProvider.swift`
- Modify: `Parrot/ProfileTest.swift`

**Interfaces:**
- Produces:
  - `AnalysisRequest` gains `let persona: String`, `let kinds: [ProfileKind]`, `let gauges: [SentimentGauge]` (and `instructions` now carries the profile `tone`).
  - `struct AnalysisResult { let insights: [InsightDraft]; let sentiment: [String: Int]; let read: String? }`
  - `func analyze(_:) async throws -> AnalysisResult` (signature change across the `AnalysisProvider` protocol).
  - Two pure static helpers (testable without network): `static func buildKindList(_ kinds: [ProfileKind]) -> String`, `static func systemPrompt(persona: String, kinds: [ProfileKind], gauges: [SentimentGauge]) -> String`, `static func schema(kinds: [ProfileKind], gauges: [SentimentGauge]) -> [String: Any]`, and `static func validatingKinds(_ drafts: [InsightDraft], allowed: Set<String>) -> [InsightDraft]`.
- Consumes: `ProfileKind`, `SentimentGauge`.

- [ ] **Step 1: Add failing assertions**

In `ProfileTest.run()` add `testPromptAndSchema()`:

```swift
    static func testPromptAndSchema() {
        let kinds = ProfilePresets.all().first { $0.name == "1:1 coaching" }!.kinds
        let prompt = ClaudeAnalysisProvider.systemPrompt(persona: "P", kinds: kinds, gauges: [])
        check("prompt includes persona", prompt.contains("P"))
        check("prompt lists reflection key", prompt.contains("reflection"))
        check("prompt has no hardcoded 'objection'", !prompt.lowercased().contains("objection"))
        let schema = ClaudeAnalysisProvider.schema(kinds: kinds, gauges: [SentimentGauge(id: UUID(), key: "client_openness", label: "x", lowLabel: "a", highLabel: "b", colorHex: "2F7E96")])
        // enum equals the profile's keys
        let insightsProp = ((schema["properties"] as? [String: Any])?["insights"] as? [String: Any])
        let items = insightsProp?["items"] as? [String: Any]
        let kindEnum = ((items?["properties"] as? [String: Any])?["kind"] as? [String: Any])?["enum"] as? [String]
        check("schema enum == profile keys", Set(kindEnum ?? []) == Set(kinds.map(\.key)))
        check("schema has sentiment object", (schema["properties"] as? [String: Any])?["sentiment"] != nil)
        let valid = ClaudeAnalysisProvider.validatingKinds(
            [InsightDraft(kindKey: "reflection", title: "t", detail: "d", source: nil),
             InsightDraft(kindKey: "objection", title: "t", detail: "d", source: nil)],
            allowed: Set(kinds.map(\.key)))
        check("validatingKinds drops out-of-lens", valid.count == 1 && valid.first?.kindKey == "reflection")
    }
```

- [ ] **Step 2: Run, verify fail-to-build**

Run: `swift build 2>&1 | tail -5`
Expected: FAIL — `systemPrompt`/`schema`/`validatingKinds` not found; `AnalysisResult` not found.

- [ ] **Step 3: Update `AnalysisRequest` + add `AnalysisResult`**

In `AnalysisProvider.swift`, extend `AnalysisRequest`:

```swift
    /// Profile persona/framing paragraph.
    let persona: String
    /// Reshapable insight kinds — drive the prompt's kind list and the schema enum.
    let kinds: [ProfileKind]
    /// Sentiment gauges to read each pass.
    let gauges: [SentimentGauge]
```

Add near `InsightDraft`:

```swift
struct AnalysisResult {
    let insights: [InsightDraft]
    let sentiment: [String: Int]
    let read: String?
}
```

Change the protocol method: `func analyze(_ request: AnalysisRequest) async throws -> AnalysisResult`.

- [ ] **Step 4: Implement the pure helpers**

Add to `ClaudeAnalysisProvider`:

```swift
    static func buildKindList(_ kinds: [ProfileKind]) -> String {
        kinds.sorted { $0.priority > $1.priority }
            .map { "- \($0.key): \($0.triggerDescription)" }
            .joined(separator: "\n")
    }

    static func systemPrompt(persona: String, kinds: [ProfileKind], gauges: [SentimentGauge]) -> String {
        var p = """
        You are a live call copilot. You receive a rolling transcript of an ongoing call. \
        Transcription is automatic, so expect minor errors and chopped sentences. Each line \
        is prefixed with the speaker: "Me" is the user you assist; "Them" is everyone else.

        \(persona)

        Produce only NEW, high-value insights about the most recent part of the conversation. \
        Each insight has a "kind" — use exactly one of these and follow its rule:
        \(buildKindList(kinds))

        Grounding: when knowledge-base reference material is provided and covers a question, \
        base the answer on it and set "source" to that document's EXACT name. Never invent \
        specifics the references don't state. The "source" field is only a provenance tag: set \
        it to exactly the name of a provided document, or the literal "general knowledge" (only \
        when allowed), otherwise OMIT it. Never describe the conversation in it.

        Rules: never repeat an insight whose title already exists. Return at most the 2 most \
        valuable NEW insights per response — prefer fewer; an empty list is common and fine. \
        Keep titles under 8 words and details under 2 sentences. Same language as the call.
        """
        if !gauges.isEmpty {
            let list = gauges.map { "- \($0.key): 0 = \($0.lowLabel), 100 = \($0.highLabel) (\($0.label))" }.joined(separator: "\n")
            p += """


            Also return a "sentiment" object reading the room right now, as an integer 0–100 for \
            each gauge, plus a one-word "read":
            \(list)
            """
        }
        return p
    }

    static func schema(kinds: [ProfileKind], gauges: [SentimentGauge]) -> [String: Any] {
        let itemSchema: [String: Any] = [
            "type": "object",
            "properties": [
                "kind": ["type": "string", "enum": kinds.map(\.key)],
                "title": ["type": "string"],
                "detail": ["type": "string"],
                "source": ["type": "string", "description": "Exact KB document name, or 'general knowledge'. Omit otherwise."],
            ],
            "required": ["kind", "title", "detail"],
            "additionalProperties": false,
        ]
        var properties: [String: Any] = ["insights": ["type": "array", "items": itemSchema]]
        var required = ["insights"]
        if !gauges.isEmpty {
            var sentProps: [String: Any] = [:]
            for g in gauges { sentProps[g.key] = ["type": "integer", "minimum": 0, "maximum": 100] }
            sentProps["read"] = ["type": "string"]
            properties["sentiment"] = ["type": "object", "properties": sentProps, "additionalProperties": false]
            required.append("sentiment")
        }
        return ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
    }

    static func validatingKinds(_ drafts: [InsightDraft], allowed: Set<String>) -> [InsightDraft] {
        drafts.filter { allowed.contains($0.kindKey) }
    }
```

- [ ] **Step 5: Rewire `analyze` to use the helpers and return `AnalysisResult`**

In `analyze`, replace the hardcoded `systemPrompt`, `itemSchema`/`schema`, and the `system` body field with the dynamic versions; parse sentiment. Key changes:
- `let sys = Self.systemPrompt(persona: request.persona, kinds: request.kinds, gauges: request.gauges)` and use it for `"system"`.
- Replace the instructions section text source: `request.instructions` already holds the tone — keep the existing `if !request.instructions.isEmpty { sections.append("Tone/style from the user:\n\(request.instructions)") }`.
- `let schema = Self.schema(kinds: request.kinds, gauges: request.gauges)`.
- After `parseInsights`, apply BOTH backstops:

```swift
        let parsed = try Self.parseResult(from: data)   // new combined parser
        let sourceValidated = Self.validatingSources(parsed.insights, knownDocuments: request.knownDocumentNames)
        let kindValidated = Self.validatingKinds(sourceValidated, allowed: Set(request.kinds.map(\.key)))
        return AnalysisResult(insights: kindValidated, sentiment: parsed.sentiment, read: parsed.read)
```

Add `parseResult` (extends `parseInsights` to also read `sentiment`):

```swift
    private static func parseResult(from data: Data) throws -> (insights: [InsightDraft], sentiment: [String: Int], read: String?) {
        let response = try JSONDecoder().decode(MessagesResponse.self, from: data)
        guard let text = response.content.first(where: { $0.type == "text" })?.text,
              let jsonData = text.data(using: .utf8) else {
            throw AnalysisError.badResponse("Empty model response")
        }
        let obj = (try? JSONSerialization.jsonObject(with: jsonData)) as? [String: Any] ?? [:]
        let items = (obj["insights"] as? [[String: Any]]) ?? []
        let drafts = items.compactMap { item -> InsightDraft? in
            guard let kind = item["kind"] as? String, let title = item["title"] as? String,
                  let detail = item["detail"] as? String else { return nil }
            return InsightDraft(kindKey: kind, title: title, detail: detail, source: (item["source"] as? String)?.nilIfEmpty)
        }
        var sentiment: [String: Int] = [:]
        var read: String? = nil
        if let s = obj["sentiment"] as? [String: Any] {
            for (k, v) in s {
                if k == "read" { read = v as? String }
                else if let i = v as? Int { sentiment[k] = i }
                else if let d = v as? Double { sentiment[k] = Int(d) }
            }
        }
        return (drafts, sentiment, read)
    }
```

(Keep `parseInsights`/`InsightsPayload` only if still referenced; otherwise remove.)

- [ ] **Step 6: Build + run harness — verify PASS**

Run: `swift build 2>&1 | tail -20`
Expected: build fails first in `CallAnalysisEngine` (it calls `analyze` expecting `[InsightDraft]`). That's Task 8. To verify THIS task in isolation, temporarily it's acceptable that the engine call site is updated in Task 8; but the harness for the pure helpers must pass. Since the engine won't compile yet, fold Task 8's engine call-site change into this commit if doing strictly sequential builds — OR implement Task 8 immediately. **Do Task 8 now**, then run: `swift build && .build/debug/Parrot --profile-test` → `ALL PASS`.

- [ ] **Step 7: Commit** (after Task 8 compiles)

```bash
git add Parrot/Services/AnalysisProvider.swift Parrot/ProfileTest.swift
git commit -m "Phase C: dynamic per-profile prompt + schema + sentiment + kind validation"
```

---

### Task 8: `CallAnalysisEngine` — active profile, sentiment state, scoped KB

**Files:**
- Modify: `Parrot/Services/CallAnalysisEngine.swift`

**Interfaces:**
- Consumes: `AnalysisResult`, `CallProfile`, `KnowledgeBaseService.search(query:profileID:)`.
- Produces:
  - `CallAnalysisEngine.activeProfile: CallProfile?` (set in `start`).
  - `start(profile: CallProfile?, brief: String)` (replaces `start(brief:)`).
  - `var sentiment: [String: Int]` and `var sentimentRead: String?` (observable, for the strip).

- [ ] **Step 1: Change `start` signature + store profile**

```swift
    private(set) var sentiment: [String: Int] = [:]
    private(set) var sentimentRead: String?
    private(set) var activeProfile: CallProfile?

    func start(profile: CallProfile?, brief: String = "") {
        guard isEnabled else { status = .off; return }
        insights = []; segments = []; lastAnalyzedCount = 0
        rerunRequested = false; oldestPendingSince = nil
        meCharacters = 0; themCharacters = 0
        sentiment = [:]; sentimentRead = nil
        activeProfile = profile
        callBrief = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        isActive = true
        status = provider.isConfigured ? .listening : .needsAPIKey
    }
```

- [ ] **Step 2: Build the request from the profile, scope KB, handle `AnalysisResult`**

In `runAnalysis`, replace the `AnalysisRequest(...)` construction and the `provider.analyze` handling:

```swift
        let profile = activeProfile
        let references = await knowledgeBase?.search(query: query, profileID: profile?.id) ?? []

        let request = AnalysisRequest(
            transcript: transcript,
            knownInsightTitles: Array(knownTitles),
            references: references,
            instructions: profile?.tone ?? "",
            callBrief: callBrief,
            allowGeneralKnowledge: profile?.allowGeneralKnowledge ?? true,
            knownDocumentNames: profile.map { knowledgeBase?.documentNames(for: $0.id) ?? [] } ?? (knowledgeBase?.documents.map(\.name) ?? []),
            persona: profile?.persona ?? "",
            kinds: profile?.kinds ?? [],
            gauges: profile?.gauges ?? []
        )

        do {
            let result = try await provider.analyze(request)
            guard isActive else { analysisTask = nil; return }
            // Merge model sentiment; overlay the computed talk-balance gauge if present.
            var merged = result.sentiment
            if let pct = userTalkPercent, (profile?.gauges.contains { $0.key == "my_dominance" } ?? false) {
                merged["my_dominance"] = pct
            }
            sentiment = merged
            sentimentRead = result.read
            let existingTitles = Set(insights.map { $0.title.lowercased() })
            let unique = result.insights
                .filter { !existingTitles.contains($0.title.lowercased()) }
                .map { Insight(kindKey: $0.kindKey, title: $0.title, detail: $0.detail, callTime: anchorTime, source: $0.source) }
            insights.insert(contentsOf: unique, at: 0)
            status = .listening
        } catch let error as AnalysisError {
            …unchanged…
```

(The `catch` blocks stay as they are.)

- [ ] **Step 3: Build + run harness — verify PASS**

Run: `swift build && .build/debug/Parrot --profile-test`
Expected: `ALL PASS`.

- [ ] **Step 4: Commit** (joint with Task 7 per Task 7 Step 7, or separately)

```bash
git add Parrot/Services/CallAnalysisEngine.swift
git commit -m "Phase C: engine drives analysis from active profile + tracks sentiment"
```

---

### Task 9: `RecordingManager` + `ParrotApp` wiring + migration at launch (PARITY GATE)

After this task the app runs end-to-end on the **Default** profile and must behave like today.

**Files:**
- Modify: `Parrot/Services/RecordingManager.swift`
- Modify: `Parrot/ParrotApp.swift`
- Modify: `Parrot/ProfileTest.swift` (snapshot persistence assertion)

**Interfaces:**
- Produces:
  - `RecordingManager.profileStore: ProfileStore` (owned, like `knowledgeBase`).
  - `startRecording` persists `meeting.profile`, `meeting.brief`, `meeting.profileSnapshotData` and calls `callAnalysisEngine.start(profile:brief:)`.
  - `summarize`/`coaching` pass the profile's persona/tone (via existing `instructions` param sourced from `profile.tone`).
- Consumes: `ProfileStore`, `ProfilePresets`.

- [ ] **Step 1: Register `CallProfile` in the app schema**

In `Parrot/ParrotApp.swift:28`:

```swift
        let schema = Schema([Meeting.self, TranscriptSegment.self, CallInsight.self, CallProfile.self])
```

- [ ] **Step 2: Own a `ProfileStore`, seed at launch, inject into the environment**

In `RecordingManager`, add `let profileStore = ProfileStore()`. In `prepare(modelContext:)`, after `reconcileOrphanedRecordings`:

```swift
        profileStore.seedAndMigrateIfNeeded(context: modelContext, knowledgeBase: knowledgeBase)
```

In `ParrotApp` scenes, add `.environment(recordingManager.profileStore)` alongside the existing `.environment(recordingManager)` on `ContentView` and `MenuBarView` (and `SettingsView`).

- [ ] **Step 3: Persist profile/brief/snapshot in `startRecording`**

In `RecordingManager.startRecording`, after `let meeting = Meeting()` and `modelContext.insert(meeting)`:

```swift
        let profile = profileStore.activeProfile
        meeting.profile = profile
        meeting.brief = nextCallBrief.nilIfEmpty
        meeting.profileSnapshotData = profile.map { try? JSONEncoder().encode($0.kinds) } ?? nil
```

Change the engine start call (line ~100):

```swift
        callAnalysisEngine.start(profile: profile, brief: nextCallBrief)
```

- [ ] **Step 4: Pass profile tone to summary/coaching**

In `generateSummary`, source instructions from the meeting's profile instead of global UserDefaults:

```swift
        let instructions = meeting.profile?.tone ?? (UserDefaults.standard.string(forKey: "copilotInstructions") ?? "")
```

(Both `summarize` and `coachingReport` already take `instructions:` — no signature change needed.)

- [ ] **Step 5: Add snapshot-persistence assertion**

In `ProfileTest.run()` add `testSnapshotPersistence()`:

```swift
    static func testSnapshotPersistence() {
        let kinds = ProfilePresets.all().first!.kinds
        let data = try? JSONEncoder().encode(kinds)
        let m = Meeting()
        m.profileSnapshotData = data
        check("snapshot decodes back", m.snapshotKinds.count == kinds.count)
        check("snapshot preserves first key", m.snapshotKinds.first?.key == kinds.first?.key)
    }
```

- [ ] **Step 6: Build, harness, AND parity eyeball**

Run: `swift build && .build/debug/Parrot --profile-test` → `ALL PASS`.
Run: `.build/debug/Parrot --snapshot /tmp/report.png` → report renders unchanged.
**Parity gate (manual):** build+install the release app (roadmap recipe), record a short call. Confirm: copilot still produces suggestion/blocker/action cards with today's colors; no crash on first launch (migration seeded six profiles); existing meetings open fine.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "Phase C: wire ProfileStore + persist profile/brief/snapshot (Default parity gate)"
```

---

### Task 10: Inline profile picker (Dashboard + MenuBar default)

**Files:**
- Modify: `Parrot/Views/DashboardView.swift`
- Modify: `Parrot/Views/MenuBarView.swift`

**Interfaces:**
- Consumes: `ProfileStore` (from environment), `CallProfile`.

- [ ] **Step 1: Add the picker chips above the brief**

In `DashboardView`, add `@Environment(ProfileStore.self) private var profileStore` and `@Query private var allProfiles: [CallProfile]` (sorted by `sortOrder`). Insert above `callBriefField` (gated by `copilotEnabled`) a horizontal chip row:

```swift
    private var profilePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(allProfiles.sorted { $0.sortOrder < $1.sortOrder }) { profile in
                    let isActive = profileStore.activeProfile?.id == profile.id
                    Button { profileStore.setActive(profile) } label: {
                        HStack(spacing: 5) {
                            Image(systemName: profile.iconSystemName).font(.caption)
                            Text(profile.name).font(.system(size: 12.5, weight: .medium))
                        }
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .background(isActive ? Theme.Colors.accent : Theme.Colors.chip,
                                    in: Capsule())
                        .foregroundStyle(isActive ? .white : Theme.Colors.ink)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(maxWidth: 460)
    }
```

Add `profilePicker` into the `if copilotEnabled` block, above `callBriefField`. (Use `@Query(sort: \CallProfile.sortOrder) private var allProfiles: [CallProfile]`.)

- [ ] **Step 2: MenuBar uses last-used silently + shows label**

In `MenuBarView`, add `@Environment(ProfileStore.self) private var profileStore`. Where it triggers `startRecording`, no change is needed (the engine reads `profileStore.activeProfile` via `RecordingManager`). Add a small label near the record control: `Text(profileStore.activeProfile?.name ?? "Default").font(.caption).foregroundStyle(.secondary)`.

- [ ] **Step 3: Build + manual eyeball**

Run: `swift build` → exit 0.
Manual: dashboard shows chips; selecting one persists (relaunch keeps it); menu bar shows the active profile name.

- [ ] **Step 4: Commit**

```bash
git add Parrot/Views/DashboardView.swift Parrot/Views/MenuBarView.swift
git commit -m "Phase C: inline profile picker on dashboard + menu-bar default"
```

---

### Task 11: Sentiment strip + profile-driven card styling

**Files:**
- Create: `Parrot/Views/SentimentStripView.swift`
- Modify: `Parrot/Views/CopilotPanelView.swift`
- Modify: `Parrot/Views/LiveRecordingView.swift`
- Modify: `Parrot/Models/KindStyle.swift` (add a profile-aware resolver entry point)

**Interfaces:**
- Produces:
  - `KindResolver.style(forKey:profile:snapshot:)` — walks profile → snapshot → fallback. The `Insight.style` / `CallInsight.style` computed props gain an optional resolving profile via a lightweight approach (below).
  - `struct SentimentStripView: View` taking `gauges: [SentimentGauge]`, `values: [String: Int]`, `read: String?`.

- [ ] **Step 1: Add the profile-aware resolver**

In `KindStyle.swift`:

```swift
extension KindResolver {
    static func style(forKey key: String, profile: CallProfile?, snapshot: [ProfileKind]) -> KindStyle {
        if let s = profile?.style(forKey: key) { return s }
        if let k = snapshot.first(where: { $0.key == key }) {
            return KindStyle(label: k.label, color: Color(hex: k.colorHex), iconSystemName: k.iconSystemName, isPinned: k.isPinned)
        }
        return fallbackStyle(forKey: key)
    }
}
```

Live cards resolve against the engine's `activeProfile` (no snapshot needed live). Report cards resolve against `meeting.profile` then `meeting.snapshotKinds`. Update the call sites in `CopilotPanelView` to use `KindResolver.style(forKey: insight.kindKey, profile: engine.activeProfile, snapshot: [])` and in `MeetingDetailView` to use `KindResolver.style(forKey: insight.kindRaw, profile: meeting.profile, snapshot: meeting.snapshotKinds)`. (Replace the `insight.style` uses added in Task 2 at these live/report sites.)

- [ ] **Step 2: Implement `SentimentStripView`**

```swift
import SwiftUI

struct SentimentStripView: View {
    let gauges: [SentimentGauge]
    let values: [String: Int]
    let read: String?

    var body: some View {
        if gauges.isEmpty { EmptyView() } else {
            VStack(alignment: .leading, spacing: 8) {
                if let read, !read.isEmpty {
                    Text(read.capitalized)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.Colors.ink2)
                }
                ForEach(gauges) { gauge in
                    let v = values[gauge.key]
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(gauge.label).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.Colors.ink2)
                            Spacer()
                            Text(v.map { "\($0)" } ?? "—").font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.Colors.ink3)
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Theme.Colors.line).frame(height: 5)
                                Capsule().fill(Color(hex: gauge.colorHex))
                                    .frame(width: geo.size.width * CGFloat(v ?? 0) / 100, height: 5)
                                    .animation(.easeOut(duration: 0.4), value: v)
                            }
                        }.frame(height: 5)
                        HStack {
                            Text(gauge.lowLabel).font(.system(size: 9)).foregroundStyle(Theme.Colors.ink3)
                            Spacer()
                            Text(gauge.highLabel).font(.system(size: 9)).foregroundStyle(Theme.Colors.ink3)
                        }
                    }
                }
            }
            .padding(12)
            .background(Theme.Colors.panel, in: RoundedRectangle(cornerRadius: 10))
        }
    }
}
```

- [ ] **Step 3: Mount the strip at the top of the copilot panel**

In `CopilotPanelView` (or `LiveRecordingView` where the panel is composed), above the card feed:

```swift
                SentimentStripView(
                    gauges: engine.activeProfile?.gauges ?? [],
                    values: engine.sentiment,
                    read: engine.sentimentRead
                )
                .padding(.horizontal, 12).padding(.top, 8)
```

Also replace the 3-tab filter (suggestions/blockers/actions) with a profile-driven layout: a **pinned zone** = `engine.insights.filter { KindResolver.style(forKey: $0.kindKey, profile: engine.activeProfile, snapshot: []).isPinned && !$0.isHandled }` and a single scrolling **feed** = the rest. Keep the existing card view; only the grouping logic changes. (Remove the now-unused `Tab` enum cases tied to fixed kinds.)

- [ ] **Step 4: Build + snapshot + manual**

Run: `swift build` → exit 0.
Manual: record under Sales then Coaching — cards show profile kinds/colors; the strip shows the profile's gauges updating across passes.

- [ ] **Step 5: Commit**

```bash
git add Parrot/Views/SentimentStripView.swift Parrot/Views/CopilotPanelView.swift Parrot/Views/LiveRecordingView.swift Parrot/Models/KindStyle.swift
git commit -m "Phase C: always-on sentiment strip + profile-driven card styling"
```

---

### Task 12: Report renders snapshot kinds

**Files:**
- Modify: `Parrot/Views/MeetingDetailView.swift`

- [ ] **Step 1: Resolve stored-insight styling via profile→snapshot→fallback**

At the insight rows (~494-504), replace the `insight.style` calls with:

```swift
            let style = KindResolver.style(forKey: insight.kindRaw, profile: meeting.profile, snapshot: meeting.snapshotKinds)
            Image(systemName: style.iconSystemName)
                …
                .foregroundStyle(style.color)
            …
            if style.isPinned { … }   // replaces `insight.kindRaw == "blocker"`
```

- [ ] **Step 2: Build + snapshot**

Run: `swift build && .build/debug/Parrot --snapshot /tmp/report.png` → renders.
Manual: open a NEW meeting recorded under Coaching → its insights show coaching labels/colors; open a PRE-Phase-C meeting → renders with fallback styling, no crash.

- [ ] **Step 3: Commit**

```bash
git add Parrot/Views/MeetingDetailView.swift
git commit -m "Phase C: report resolves insight styling from profile snapshot"
```

---

### Task 13: Profiles settings tab (light editor + doc tagging + Edit advanced)

**Files:**
- Create: `Parrot/Views/ProfilesSettingsView.swift`
- Modify: `Parrot/Views/SettingsView.swift`

**Interfaces:**
- Consumes: `ProfileStore`, `CallProfile`, `KnowledgeBaseService` (doc tagging via `setProfiles(_:for:)`).

- [ ] **Step 1: Add a Profiles tab to `SettingsView`**

In `SettingsView.body`'s `TabView`, add before the Knowledge tab:

```swift
            ProfilesSettingsView()
                .tabItem { Label("Profiles", systemImage: "person.2.badge.gearshape") }
```

The Knowledge tab keeps the shared document library + add/remove/notes, but its **"Coaching Instructions"** section moves into per-profile `tone` editing (remove that section + the general-knowledge toggle from Knowledge; they live per-profile now).

- [ ] **Step 2: Implement `ProfilesSettingsView`**

A master-detail: list of profiles (sorted by `sortOrder`) with select + duplicate + delete (delete disabled for built-ins); detail edits name, icon, summary, persona, tone, `allowGeneralKnowledge`, and a checkbox list of KB docs tagged into this profile (`knowledgeBase.documents`, toggling `setProfiles`). An "Edit advanced" `DisclosureGroup` shows editable rows for `kinds` (key/label/colorHex/icon/trigger/isPinned/priority) and `gauges`. Use `@Bindable` on the selected `CallProfile`; mutate `profile.kinds`/`profile.gauges` arrays and `try? context.save()` on change. (Full view ~150 lines of standard SwiftUI `Form` rows — follow the existing `SettingsView`/`KBDocumentRow` patterns for styling; bind text fields to a local `@State` copy and write back on submit, exactly like `KBDocumentRow` does for notes.)

Key save pattern for advanced rows (avoid mutating decoded arrays in place):

```swift
    private func updateKind(_ updated: ProfileKind, in profile: CallProfile) {
        var ks = profile.kinds
        if let i = ks.firstIndex(where: { $0.id == updated.id }) { ks[i] = updated; profile.kinds = ks; try? context.save() }
    }
```

- [ ] **Step 3: Build + manual**

Run: `swift build` → exit 0.
Manual: edit Coaching's persona + a kind color → next recording reflects it; duplicate a preset → "Edit advanced" lets you add a kind; tag a doc into only Sales → it doesn't surface on a Coaching call (verify with a KB doc + a matching question).

- [ ] **Step 4: Commit**

```bash
git add Parrot/Views/ProfilesSettingsView.swift Parrot/Views/SettingsView.swift
git commit -m "Phase C: Profiles settings tab — light editor, doc tagging, Edit advanced"
```

---

### Task 14: Roadmap status update + final verification sweep

**Files:**
- Modify: `docs/IMPROVEMENT-ROADMAP.md`

- [ ] **Step 1: Full harness + build sweep**

Run: `swift build && .build/debug/Parrot --profile-test && .build/debug/Parrot --snapshot /tmp/report.png`
Expected: `ALL PASS`, report renders.

- [ ] **Step 2: Walk the spec acceptance criteria (§7)**

Manually confirm each bullet in spec §7 (Sales vs Coaching lens on same audio, schema enum logging, picker persistence, pre-Phase-C meeting parity, KB scoping, advanced-edit color change, snapshot survival after profile delete). Note any gaps as follow-up TODOs in the roadmap rather than silently skipping.

- [ ] **Step 3: Update the roadmap status table + progress log**

Set the C1 row to `🟡 built` with a one-line note; add a progress-log entry dated 2026-06-20 summarizing what landed and what needs the on-device eyeball.

- [ ] **Step 4: Commit**

```bash
git add docs/IMPROVEMENT-ROADMAP.md
git commit -m "Phase C: mark Call Profiles built; roadmap status + log"
```

---

## Self-review notes (author)

- **Spec coverage:** §2 model → Tasks 2,3,5,6; §3 presets → Task 4; §4 pipeline → Tasks 7,8; §5.1 picker → Task 10; §5.2 strip+cards → Task 11; §5.3 editor → Task 13; §6 migration → Tasks 5,9; §7 acceptance → Task 14; §8 risk sequencing → Task ordering (enum refactor first, parity gate Task 9). All sections mapped.
- **Sequencing caveat (intentional):** Task 6 (KB) must be implemented before Task 5's migration call compiles, and Tasks 7+8 share a compile boundary (the `analyze` return-type change). These are flagged inline so the executor builds them as a pair rather than expecting each to compile alone. If using subagent-driven execution, brief the agent that Tasks 5+6 and 7+8 are compile-coupled.
- **Type consistency:** `kindKey` (live `Insight`/`InsightDraft`) vs `kindRaw` (stored `CallInsight`) used consistently; `AnalysisResult` returned by `analyze` everywhere; `KindResolver.style(forKey:profile:snapshot:)` signature consistent across live (snapshot `[]`) and report (real snapshot) call sites; `start(profile:brief:)` updated at its one caller (`RecordingManager`).
- **Known soft spots:** Task 13's editor view is described structurally rather than line-complete (it's large, standard `Form` SwiftUI following existing `KBDocumentRow` patterns) — acceptable per "follow established patterns"; the executor should mirror `SettingsView`. Task 11 changes the panel's tab model — eyeball required.
