# Phase C — Call Profiles + Customizable Copilot + Tone

**Design doc.** Created 2026-06-20. Source of truth for Phase C of the Parrot
improvement roadmap (see `docs/IMPROVEMENT-ROADMAP.md`, Part 2 · Issue 5). This
spec is the input to the implementation plan; it does not itself contain task
breakdown.

---

## 1. Problem & goal

Today Parrot's copilot is **one global, sales-shaped lens** applied to every call.
The first real test (Meeting #48) was a parenting/ADHD coaching roleplay, yet the
copilot framed it in sales terms ("blocker", "objection") because the system
prompt's five insight kinds are hardcoded. Config is global and scattered:
`copilotInstructions`, `copilotGeneralFallback`, `copilotEnabled` in
`UserDefaults`; a single flat global knowledge base; and `nextCallBrief` that
isn't even persisted on the meeting. Tone exists only as a rare `feedback` card —
there is no at-a-glance read of how a call is going.

**Goal:** make the copilot a *per-call-type instrument*. Before a call you pick a
**profile** (Sales discovery, 1:1 coaching, Interview, Customer support,
Generic…). The profile reshapes what the copilot looks for (its own insight
kinds), how it talks (persona/tone), what it knows (profile-scoped knowledge), and
adds a persistent **sentiment strip** that reads the room continuously.

### Decisions locked during brainstorming

| # | Decision |
|---|---|
| 1 | **Fully reshapable lens (option C).** A profile owns its own set of insight *kinds* (key, label, color, icon, trigger description). The Claude JSON-schema enum is built per profile; the live panel styles cards from the profile. |
| 2 | **Tone = a dedicated always-on sentiment strip (option B),** not just another kind. Each analysis pass returns a structured sentiment object in addition to the insight array. Profiles configure what the strip watches. |
| 3 | **Curated presets, light editing (option A).** Data model is full-C. Ship ~5 strong built-in presets. UI edits the simple fields inline (name, persona/tone, scoped KB, fallback); kinds + gauges are edited via "duplicate → Edit advanced" (structured rows), not a polished visual builder yet. |
| 4 | **KB scoping = many-to-many doc tagging (option A).** `KBDocument` gains `profileIDs`; `search` gains a profile filter. Shared docs aren't re-indexed. |
| 5 | **Inline pre-call picker (option A)** on the dashboard, above the brief. Last-used profile is the default everywhere (dashboard + menu bar) so a quick start just works. The profile, a denormalized snapshot of its kinds/persona, and the brief all persist on `Meeting`. |
| 6 | **Storage = SwiftData `@Model CallProfile`** + Codable structs (kinds, gauges) JSON-encoded on the model; KB membership stays in the KB JSON store. Migration creates a built-in **"Default"** profile carrying today's exact behavior; existing meetings render with neutral fallback styling. |

### Non-goals (this phase)

- A polished visual kind/gauge builder (drag-reorder, color/icon pickers). Deferred
  — "Edit advanced" exposes structured rows instead.
- The "Ask Parrot" chat panel (already deferred in Phase B).
- Per-profile Whisper model / language / vocabulary. Those stay global for now.
- Sharing/exporting profiles between machines.

---

## 2. Data model

### 2.1 `CallProfile` (new SwiftData `@Model`)

```swift
@Model
final class CallProfile {
    var id: UUID
    var name: String                 // "Sales discovery"
    var iconSystemName: String       // SF Symbol, e.g. "dollarsign.circle"
    var summary: String              // one line shown in the picker
    var isBuiltIn: Bool              // preset shipped by the app
    var sortOrder: Int

    /// Persona/framing paragraph injected into the system prompt — the heart of
    /// "how this copilot thinks". Replaces the old global hardcoded framing.
    var persona: String

    /// User's standing tone/style guidance for this call type (was the global
    /// `copilotInstructions`). Layered on top of persona.
    var tone: String

    var allowGeneralKnowledge: Bool

    /// Reshapable lens. JSON-encoded Codable arrays (config, not queried entities).
    var kindsData: Data              // [ProfileKind]
    var gaugesData: Data             // [SentimentGauge]

    @Relationship(inverse: \Meeting.profile)
    var meetings: [Meeting]
}
```

`kindsData` / `gaugesData` are decoded through computed accessors
(`var kinds: [ProfileKind]`, `var gauges: [SentimentGauge]`) so call sites never
touch raw `Data`.

### 2.2 `ProfileKind` (Codable struct)

The unit that replaces the fixed `Insight.Kind` enum.

```swift
struct ProfileKind: Codable, Identifiable, Hashable {
    var id: UUID
    var key: String          // stable machine key, e.g. "objection", "reflection"
    var label: String        // "Objection", "Reflection"
    var colorHex: String     // card accent stripe color
    var iconSystemName: String
    var triggerDescription: String  // the line the model sees: when to emit this
    var isPinned: Bool       // pinned zone (like today's blocker) vs. scrolling feed
    var priority: Int        // ordering / fast-track weight
}
```

- The **Claude schema enum** for a pass = `profile.kinds.map(\.key)`.
- The **system prompt's kind list** is built by joining `"- \(key): \(triggerDescription)"`.
- The **live card style** (stripe color, icon, label, pinned vs. feed) is looked up
  from the profile's kind by `key`.

### 2.3 `SentimentGauge` (Codable struct)

```swift
struct SentimentGauge: Codable, Identifiable, Hashable {
    var id: UUID
    var key: String          // "buying_temperature", "client_openness", "my_dominance"
    var label: String        // "Buying temp", "Openness", "You're dominating"
    var lowLabel: String     // "Cold"
    var highLabel: String    // "Hot"
    var colorHex: String
}
```

The model returns, each pass, a value `0…100` per gauge key plus an optional
one-word `read`. The strip renders each gauge as a slim labeled meter.

### 2.4 `Meeting` additions

```swift
var profile: CallProfile?            // relationship; nil for pre-Phase-C meetings
var brief: String?                   // was ephemeral nextCallBrief — now persisted
var profileSnapshotData: Data?       // denormalized [ProfileKind] used at record time
```

`profileSnapshotData` means the report renders with the correct kind
labels/colors **even if the profile is later edited or deleted**. Resolution order
for styling a stored insight: live profile kind by key → meeting snapshot kind by
key → neutral fallback style.

### 2.5 `CallInsight` / live `Insight`

`CallInsight` already stores `kindRaw` (a string) — good, it already supports
arbitrary keys. We **stop** mapping through the fixed `Insight.Kind` enum for
display and instead resolve `kindRaw` against the profile/snapshot/fallback chain.
The fixed `Insight.Kind` enum is retained only as the **Default profile's** kind
set + the neutral fallback, not as the universal type.

> Open implementation note: `Insight.Kind` is currently a Swift enum used for
> typing across the engine and views. Phase C changes `kind` to a string `key`
> carried end-to-end (draft → live insight → stored). The enum becomes a set of
> known keys + styling for the Default profile. This is the largest mechanical
> refactor in the phase and must be done carefully so old stored insights
> (`feedback`, `blocker`, …) still resolve.

### 2.6 `KBDocument` addition

```swift
var profileIDs: Set<UUID>            // which profiles this doc is tagged into
```

Stored in the existing KB JSON store. Migration tags all current docs into the
Default profile's id.

---

## 3. The five built-in presets

Each ships with hand-tuned `persona`, `kinds`, and `gauges`. Sketch (final copy
tuned during implementation):

| Profile | Kinds (key → label) | Sentiment gauges |
|---|---|---|
| **Default** (= today) | `suggestion`, `question`, `blocker`→Objection (pinned), `action_item`, `feedback` | my_dominance |
| **Sales discovery** | `suggestion`, `objection` (pinned), `buying_signal`, `next_step`, `discovery_gap` | buying_temperature, my_dominance |
| **1:1 coaching** | `reflection`, `open_question`, `emotional_cue`, `commitment`, `coaching_moment` | client_openness, my_dominance |
| **Interview** (you interviewing) | `follow_up_question`, `red_flag` (pinned), `strong_signal`, `topic_to_cover`, `note` | candidate_confidence |
| **Customer support** | `answer`, `unresolved_issue` (pinned), `frustration_cue`, `follow_up`, `note` | customer_frustration |
| **Generic** | `suggestion`, `question`, `action_item`, `note` | engagement |

`my_dominance` reuses the existing talk-balance signal the engine already computes
(`userTalkPercent`) — the strip can show it without an extra model call, blending a
computed gauge with model-returned gauges.

---

## 4. Analysis pipeline changes

### 4.1 `AnalysisRequest` / `AnalysisProvider`

`AnalysisRequest` gains the active profile's reshaping inputs:

```swift
let persona: String
let kinds: [ProfileKind]          // drives prompt kind-list + schema enum
let gauges: [SentimentGauge]      // drives sentiment schema + prompt
// `instructions` is now the profile's `tone`; `callBrief` now sourced from meeting brief
```

`analyze(_:)` returns both insights and sentiment:

```swift
struct AnalysisResult {
    let insights: [InsightDraft]          // kind = profile key (validated against profile keys)
    let sentiment: [String: Int]          // gauge key → 0…100
    let read: String?                     // optional one-word room read
}
func analyze(_ request: AnalysisRequest) async throws -> AnalysisResult
```

### 4.2 `ClaudeAnalysisProvider`

- **System prompt** becomes a template: a fixed scaffold (you are a live call
  copilot, "Me"/"Them" convention, transcription caveats, grounding/source rules,
  "≤2 new insights, empty is fine" volume rules — all retained from today) **plus**
  the profile's `persona`, then the profile's kind list rendered from
  `kinds`, then the gauge list rendered from `gauges`.
- **Schema** built dynamically:
  - insight item `kind.enum` = profile kind keys (replaces the hardcoded enum).
  - a new top-level `sentiment` object: one integer property (0–100) per gauge key,
    plus optional `read` string.
- **Source validation** (`validatingSources`) unchanged — still drops invented
  provenance, still keyed off real KB doc names + "general knowledge".
- **Insight-kind validation** added: drop any draft whose `kind` key isn't in the
  active profile's kind set (mirrors the source backstop — the model can't invent a
  kind outside the lens).
- `summarize` / `coachingReport` gain the profile `persona`/`tone` so the post-call
  reports speak in the same frame (a coaching report shouldn't talk "objections
  handled" — it should reflect the coaching kinds). The coaching report's section
  structure can stay generic but is told the profile's framing.

### 4.3 `CallAnalysisEngine`

- Holds the **active `CallProfile`** (set by `RecordingManager` at
  `start(profile:brief:)`).
- Builds `AnalysisRequest` from the profile instead of reading global
  `UserDefaults` for instructions/fallback.
- Stores the latest **sentiment** (`var sentiment: [String: Int]`, `var read: String?`)
  as observable state for the strip; updates it every successful pass.
- `userTalkPercent` continues to feed any `*_dominance` gauge directly.
- Volume/debounce machinery (idle/question/staleness timing) is **unchanged** — the
  firehose fix from Phase A stays. Per-profile cadence tuning is a non-goal.
- KB retrieval call passes the active `profileID` so `search` filters to tagged docs.

### 4.4 `KnowledgeBaseService.search`

Add `profileID:` param; filter `chunks` to those whose document is tagged into the
profile before scoring. Empty tag set for a profile → no references (and the
general-knowledge fallback governs whether the model may still answer).

---

## 5. UI surfaces

### 5.1 Pre-call picker (`DashboardView`)

- Above the existing brief field (shown when copilot is enabled): an inline profile
  selector — a horizontal row of pill chips (icon + name) with the active one
  highlighted in the accent color, plus a trailing "Manage…" affordance opening the
  profile editor. Reuses Phase B `Theme` tokens (accent `#2F7E96`, chips, serif).
- Selecting a chip sets `recordingManager.activeProfile` and persists the choice as
  `lastUsedProfileID` (AppStorage). The brief field semantics are unchanged
  (free text for *this* call).
- `MenuBarView` start path uses `lastUsedProfileID` silently (no chip row needed
  there); optionally a compact current-profile label.

### 5.2 Live sentiment strip (`LiveRecordingView` / `CopilotPanelView`)

- A slim persistent strip at the top of the copilot panel (above the card feed):
  one row per gauge — label + a thin meter (low/high end labels, accent fill),
  plus the one-word `read` if present. Updates each pass; animates value changes
  subtly. Never scrolls away (unlike cards).
- Cards: stripe color / icon / label / pinned-vs-feed all resolved from the active
  profile's kind for the insight's `kindRaw`. The Phase B "no grey-out, accent
  stripe" card design is retained; only the color/label *source* changes.

### 5.3 Profile editor (`SettingsView` → new "Profiles" tab, replaces/absorbs parts of Copilot + Knowledge tabs)

- **List** of profiles (built-in + custom), with add / duplicate / delete
  (built-ins can be duplicated, not deleted).
- **Per-profile light editing:** name, icon, summary, persona, tone, general-
  knowledge toggle, and **scoped KB docs** (checkbox list against the shared doc
  library — this is where doc tagging lives).
- **"Edit advanced"** (per profile): structured rows for kinds (key, label, color
  hex, icon name, trigger text, pinned, priority) and gauges (key, label,
  low/high labels, color). Plain rows + text fields — not a visual builder.
- The existing **Knowledge tab** keeps the shared document library (add/remove/
  index/notes); membership is set per-profile in the Profiles tab.
- Global **API key** + **enable copilot** toggle stay where they are (Copilot tab).

---

## 6. Migration

On first launch after Phase C ships (detected by "no `CallProfile` rows exist"):

1. Create built-in presets (Default, Sales, Coaching, Interview, Support, Generic)
   with stable well-known UUIDs so re-runs are idempotent.
2. **Default** profile absorbs today's behavior: current five `Insight.Kind` cases
   as its kinds (same colors/labels as today), the global `copilotInstructions`
   string as its `tone`, `copilotGeneralFallback` as its toggle.
3. Tag **all existing KB docs** into the Default profile (`profileIDs`).
4. Set `lastUsedProfileID` = Default.
5. Existing meetings keep `profile == nil` and `profileSnapshotData == nil` → their
   stored insights resolve via the neutral fallback styling (visually identical to
   today's colors for the known keys).

Global `copilotInstructions` / `copilotGeneralFallback` keys are read once for
migration, then superseded by the Default profile (left in `UserDefaults`
harmlessly; not deleted, in case migration needs re-running).

---

## 7. Acceptance criteria

- Recording under the **Coaching** preset on a coaching-style conversation produces
  cards labeled with coaching kinds (reflection / open-question / emotional-cue),
  **zero** "objection/blocker" framing, and the sentiment strip shows
  client-openness updating over the call.
- Recording under **Sales** on the same audio produces sales kinds + buying-temp
  gauge — i.e. the lens demonstrably changes with the profile, same transcript.
- The Claude request's schema enum equals the active profile's kind keys (verifiable
  by logging the request body); drafts with out-of-lens kinds are dropped.
- Switching the inline picker and starting a recording records under that profile;
  `Meeting.profile`, `Meeting.brief`, and `Meeting.profileSnapshotData` are all set.
- A pre-Phase-C meeting opened after migration renders identically to before
  (fallback styling), no crash, no blank kinds.
- KB retrieval under a profile only returns chunks from docs tagged into that
  profile (a doc tagged only into Sales never surfaces on a Coaching call).
- Editing a profile's kind color in "Edit advanced" changes live card color on the
  next recording; deleting a profile leaves its past meetings renderable via
  snapshot.
- `swift build` clean; offscreen `--snapshot` still renders a report; the Default
  profile path reproduces today's behavior on a re-run of the `--transcribe-test`
  /existing flows.

---

## 8. Risk & sequencing notes

- **Biggest risk: the `Insight.Kind` enum → string-key refactor** (§2.5). It
  touches the engine, the live panel, the stored model, and the report renderer.
  Sequence it first behind the Default profile (behavior-preserving), verify parity,
  *then* layer presets/picker/strip on top.
- **Schema correctness:** dynamic enum + sentiment object must stay valid JSON
  schema; bad profiles (empty kinds) must degrade gracefully (fall back to Generic
  kinds) rather than send an invalid request.
- **Token/latency:** persona + kind list + gauges enlarge the system prompt
  modestly; sentiment adds a small structured field. Net effect on Haiku latency
  expected negligible; watch in the live test.
- Build/install + on-device verification follow the same recipe as Phases A/B
  (`docs/IMPROVEMENT-ROADMAP.md` Build notes).

---

## 9. Key files touched

| Concern | File |
|---|---|
| Profile model + Codable structs | `Parrot/Models/CallProfile.swift` (new), `ProfileKind`/`SentimentGauge` |
| Meeting fields | `Parrot/Models/Meeting.swift` |
| Insight kind → string key | `Parrot/Models/Insight.swift`, `CallInsight` |
| Prompt + schema (dynamic) | `Parrot/Services/AnalysisProvider.swift` |
| Engine wiring + sentiment state | `Parrot/Services/CallAnalysisEngine.swift` |
| Profile at record time + persist brief/snapshot | `Parrot/Services/RecordingManager.swift` |
| KB profile filter + doc tags | `Parrot/Services/KnowledgeBaseService.swift`, `KBDocument` |
| Preset seeding + migration | new `Parrot/Services/ProfileStore.swift` (or in RecordingManager.prepare) |
| Inline picker | `Parrot/Views/DashboardView.swift`, `MenuBarView.swift` |
| Sentiment strip + profile-driven cards | `Parrot/Views/LiveRecordingView.swift`, `CopilotPanelView.swift` |
| Profile editor | `Parrot/Views/SettingsView.swift` (+ new ProfileEditorView) |
| Report renders snapshot kinds | `Parrot/Views/MeetingDetailView.swift` |
