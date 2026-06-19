# Parrot — Improvement Roadmap

**Living planning document.** Created 2026-06-19 after the first full ~50-minute
real test (Meeting #48, "Jun 19, 2026 at 10:16 am"). This file is the source of
truth for the post-test improvement effort. Update the status table as work lands.

> **How to resume in a new chat / workspace:** Tell the assistant *"continue the
> Parrot improvement roadmap"*. It will (1) load project memory (which points
> here) and (2) read this file. The status table below says what's done and
> what's next. This file is committed to git, so it travels with the repo across
> Conductor workspaces; the gitignored `.context/` does not.

---

## Status at a glance

| Phase | Item | Status | Notes |
|---|---|---|---|
| — | Analysis of Meeting #48 | ✅ done | See Part 1 |
| — | Root-cause trace of all 5 issues | ✅ done | See Part 2 |
| **A** | A1 · Streaming transcription (no more paragraph dumps) | 🟡 built | Chunk cap + interim callback; **compiles**, awaiting on-device test |
| **A** | A2 · CPU/perf quick wins | 🟡 partial | Sort-cache **done**; echo-canceller ring buffer + level throttle remain |
| **A** | A3 · Insight volume + `source` quality | ⬜ not started | Tames the firehose |
| **B** | B1 · Copilot panel redesign (resizable, readable) | ⬜ not started | |
| **B** | B2 · Post-meeting report redesign (tabs, structure) | ⬜ not started | |
| **C** | C1 · Call Profiles + customizable copilot + tone | ⬜ not started | Big feature |

Legend: ⬜ not started · 🟡 in progress · ✅ done · ⏸ paused

---

## Progress log

- **2026-06-19** — Phase A started. Landed A1 (transcription) + A2 sort-cache:
  - `TranscriptionEngine.swift`: per-pass chunk now capped at `maxChunkSamples`
    (one ~2 s window, remainder left for next pass) so a backlog drains as small
    segments instead of a paragraph; added a `TranscriptionCallback` that streams
    interim `progress.text` into the existing live line.
  - `LiveRecordingView.swift`: live list reads a cached `displayedSegments`
    refreshed only on segment-count change (+ `.task(id:)` seed), so interim text
    ticks no longer re-sort the whole transcript.
  - `Package.swift`: added the missing `CSpeexDSP` dependency so `swift build`
    works (was WhisperKit-only; `project.yml` already had it).
  - Verified with `swift build` (exit 0). On-device test still pending.

## Part 1 — Meeting #48 analysis (the test that started this)

Pulled from the local SwiftData store
(`~/Library/Containers/com.uygar.parrot/Data/Library/Application Support/default.store`).

- **What it was:** 49.9 min, parent ↔ NHS clinician (parenting/ADHD coaching
  roleplay). 740 transcript segments, 343 copilot insights, 2,513-char summary,
  3,011-char coaching report.
- **What's genuinely good (keep it):**
  - The **post-call summary is excellent** — captured the "regulation corner"
    reframe, the validation-vs-praise distinction, handout numbers (20–23), and
    even the GDPR tangent. Accurate and well-structured.
  - The **coaching report is strong** — real talk ratio (Me 29% / Them 71%),
    timestamped observations, objections tracked with "Handled" status, concrete
    commitments.
- **Problems found in the real data:**
  1. **Transcription paragraph-dumps are real & measurable.** Of 740 segments,
     **51 are >20 s long** and 32 carry **>50 words**; worst = **71 s / 181
     words**. Many have overlapping (negative-gap) timestamps. This is exactly
     the "nothing for a while, then a wall of text" symptom.
  2. **Insight firehose.** 343 insights / 50 min ≈ **one every ~8.7 s**. 115 are
     low-value `feedback`. No human reads that live — this is *the* reason the
     panel feels like an endless grey wall.
  3. **`source` field is noisy.** 288/343 blank; the rest are mostly
     *hallucinated* labels ("call transcript", "rolling transcript",
     "conversation with coach") instead of real document names. No KB was loaded,
     so everything ran on general knowledge but wasn't tagged consistently.

### Evidence queries (reproducible)

```sql
-- segment duration buckets
SELECT CASE WHEN (ZENDTIME-ZSTARTTIME)<3 THEN '<3s' WHEN (ZENDTIME-ZSTARTTIME)<6 THEN '3-6s'
            WHEN (ZENDTIME-ZSTARTTIME)<10 THEN '6-10s' WHEN (ZENDTIME-ZSTARTTIME)<20 THEN '10-20s'
            ELSE '>20s' END b, COUNT(*) FROM ZTRANSCRIPTSEGMENT WHERE ZMEETING=48 GROUP BY b;
-- → <3s:406, 3-6s:195, 6-10s:44, 10-20s:44, >20s:51
SELECT ZKINDRAW, COUNT(*) FROM ZCALLINSIGHT WHERE ZMEETING=48 GROUP BY ZKINDRAW;
-- → feedback:115, suggestion:102, action_item:61, question:56, blocker:9
```

---

## Part 2 — The five issues and their root causes

### Issue 1 — "Silent for minutes, then a huge paragraph" (transcription)
**File:** `Parrot/Services/TranscriptionEngine.swift`
**Root cause:** producer/consumer backpressure with no chunk cap. The loop
(`startTranscribing`, lines 128–192) sleeps 500 ms, then **drains the *entire*
buffered audio** for each stream in one locked step (lines 145–150:
`self.audioBuffers[source] = []; return buffered`) and feeds it to WhisperKit as
a single `transcribe` call (line 167). When WhisperKit falls behind (CPU
contention or a slow model), the buffer balloons to 30–70 s and gets transcribed
as one block → giant segment. There is **no upper bound on chunk size** and **no
interim/partial text** — nothing is shown until a whole chunk finishes
(`currentText` is only set on completion, line 177). Gates: `buffered.count >=
32000` (~2 s, line 147) and `energy > 0.001` (line 163).
**Causally linked to Issue 2:** high CPU → slow Whisper → bigger backlog → bigger
chunks → slower still.

### Issue 2 — CPU > 100% / app feels heavy
Ranked culprits (from code review; confirm with Instruments on device):
1. **WhisperKit re-processing oversized drained chunks** (see Issue 1) — wasted
   compute + the model variant (`"base"`, `loadModel` default,
   TranscriptionEngine.swift:58).
2. **`Meeting.sortedSegments` re-sorts the whole array on every render**
   (`Parrot/Models/Meeting.swift:64-66`), read by the live list each update
   (`Parrot/Views/LiveRecordingView.swift:142`). O(n log n) × hundreds of times.
3. **Whole-array `@Published` mutations** re-render the entire transcript and the
   343-card insight `ForEach` (`CopilotPanelView.swift:255-268`, with
   `.animation(..., value: engine.insights)` at ~281-288).
4. **Echo canceller does O(n) `removeFirst` on ring buffers every audio frame**
   plus Float↔Int16 conversions each call (`Parrot/Services/EchoCanceller.swift`
   ~53-106).
5. **Mic/system level updates dispatched to main thread every ~20 ms**
   (`AudioCaptureManager.swift:285-305`) driving waveform re-renders.
6. **343 analysis passes** over the call (`CallAnalysisEngine`); see also
   `docs/PERFORMANCE.md`.

### Issue 3 — Copilot panel: grey, tiny, not resizable
**File:** `Parrot/Views/CopilotPanelView.swift`
- **"Grey overlay"** = deliberate **auto-collapse after 120 s** (`collapseAge`,
  line ~23; `isCollapsed`, ~316-321): old insights dim to a one-liner with
  `.quaternary.opacity(0.4)` background (line ~444) + `.secondary`/`.tertiary`
  text on an `underPageBackgroundColor` grey panel (line ~59). Combined with the
  firehose, after 2 min almost everything is greyed.
- **Not resizable** = hard `.frame(minWidth:260, idealWidth:300, maxWidth:360)`
  (line ~58) inside a plain `HStack` in `LiveRecordingView.swift` (~28-35). No
  `HSplitView`, no drag gesture.

### Issue 4 — Post-meeting report: cramped, endless scroll
**File:** `Parrot/Views/MeetingDetailView.swift`
One vertical `VStack` (lines ~20-57) where Summary / Coaching / Insights each sit
in a **nested 180–220 px max-height `ScrollView`** (scroll-within-scroll), and the
**full transcript is always rendered below, non-collapsible**. No tabs/columns.
Content column is squeezed by the `NavigationSplitView` sidebar (`ContentView.swift`
sidebar `min:200 ideal:240 max:300`). Coaching is one plain-text blob, not
structured.

### Issue 5 — Profiles / customizable copilot (new feature)
Today: one **global system prompt** (`AnalysisProvider.swift:59-88`), one
free-text `copilotInstructions` (AppStorage), an **ephemeral** pre-call brief
(`RecordingManager.nextCallBrief`, not persisted on `Meeting`), a **global,
non-scoped** knowledge base (`KnowledgeBaseService`, on-device `NLEmbedding`,
cosine ≥ 0.3, top-4), a general-knowledge fallback toggle, and tone only as a
`feedback` insight kind. **No profile concept**, no per-meeting type, no
profile-scoped documents, no structured sentiment. `Meeting` has no
profile/type/config field.

---

## Part 3 — Phased roadmap

Three independent workstreams, sequenced so linked items are fixed together and
each phase ships a felt improvement.

- **Phase A — Trust the live experience** (highest pain, core value): A1 + A2 +
  A3 below. Small surface, big felt gain. **← starting here.**
- **Phase B — UI polish** (parallelizable): B1 Copilot panel redesign; B2
  Post-meeting report redesign.
- **Phase C — Call Profiles** (biggest design effort): profile model, pre-call
  picker, profile-scoped RAG, real-time tone/sentiment, per-profile persona.

---

## Phase A — detailed design (what we build first)

### A1 · Streaming transcription — never dump a paragraph again
**Goal:** text appears within ~1–2 s continuously, even during a long monologue;
no segment is a 30–70 s block.

**Key WhisperKit capabilities confirmed in the vendored checkout:**
- `transcribe(audioArray:decodeOptions:callback:)` takes a
  `TranscriptionCallback = ((TranscriptionProgress) -> Bool?)` — gives **interim
  `progress.text`** during a single decode pass.
- `AudioStreamTranscriber` actor maintains a `confirmed` vs `unconfirmed` segment
  model (`State.confirmedSegments`, `unconfirmedSegments`, `currentText`).

**Approach — Option 1 (recommended): evolve the current dual-stream loop.**
Keeps the app's "Me/Them without a diarization model" differentiator.
1. **Cap chunk size.** Replace the full-buffer drain (lines 145–150) with: take
   at most a bounded window (e.g. ≤ ~10–15 s of samples), leave the remainder for
   the next pass. No more 70 s blocks. If a backlog exists, process bounded
   windows back-to-back so we catch up without one giant segment.
2. **Show interim text live.** Pass a `callback` to `transcribe` and surface
   `progress.text` as greyed "in-progress" text per stream; commit the segment
   when the pass finalizes. So even mid-monologue, words stream in.
3. **(Optional) confirmed/unconfirmed tail.** Borrow the AudioStreamTranscriber
   pattern: show the unconfirmed tail as interim, commit the stable prefix.
4. Keep the energy gate but make sure it can't starve a long utterance.

**Alternative — Option 2:** adopt `AudioStreamTranscriber` wholesale. More
"correct" streaming, but it owns its own audio source and is single-stream;
integrating dual capture (ScreenCaptureKit + mic + echo cancel) is invasive.
Recommendation: **Option 1.**

**Acceptance:** in a continuous-speech test, max segment duration ≤ ~15 s; live
text updates at least every ~2 s; re-run the segment-duration query → no `>20s`
bucket.

### A2 · CPU/perf quick wins (no-regret, reinforce A1)
1. **Cache `sortedSegments`** — keep segments ordered on insert or memoize;
   don't re-sort every render (`Meeting.swift:64`, `LiveRecordingView.swift:142`).
2. **Throttle level updates** to ~10/s instead of every buffer
   (`AudioCaptureManager.swift:285-305`).
3. **Fix echo-canceller ring buffers** — use a ring index instead of O(n)
   `removeFirst`; convert Int16 once (`EchoCanceller.swift`).
4. **Consider Whisper model variant** (tune `base` vs `small`/`tiny`) — measure.
**Acceptance:** sustained CPU during a long call noticeably lower; no main-thread
hitches in the transcript list (verify with Instruments).

### A3 · Insight volume + `source` quality (tame the firehose)
1. **Cut volume:** de-prioritize/great-throttle `feedback`; raise the effective
   non-urgent cadence so the panel is readable (keep questions fast-tracked).
   Target: roughly halve insights/min without losing suggestions/blockers/actions.
2. **Fix `source`:** tighten prompt + schema so `source` is set **only** to a
   real KB document name or the literal `"general knowledge"` — otherwise null.
   No more "rolling transcript"/"conversation with coach" junk
   (`AnalysisProvider.swift:59-88` and the output schema ~133-151).
**Acceptance:** re-run on a comparable call → far fewer, higher-signal insights;
`source` values are only real doc names or "general knowledge".

---

## Build & verification notes

- CLI builds in the Conductor worktree hit two **Xcode 26.5 explicit-modules**
  bugs in WhisperKit's transitive deps (not our code):
  - `swift-jinja` → "unable to resolve module dependency: 'OrderedCollections'"
    — fixed by deleting this worktree's DerivedData
    (`~/Library/Developer/Xcode/DerivedData/Parrot-<hash>`, the one whose
    `info.plist` `WorkspacePath` points at this worktree) and rebuilding.
  - `yyjson` → explicit precompiled module `_DarwinFoundation2-*.pcm` "not found"
    — worked around with `SWIFT_ENABLE_EXPLICIT_MODULES=NO` (and/or building in
    Xcode directly, which the author does successfully).
- There is **no shared scheme** and `.xcodeproj` is git-tracked (xcodegen source
  is `project.yml`). CLI builds use `-target Parrot` (so `-derivedDataPath`,
  which requires `-scheme`, can't be used). Sign-less check:
  `xcodebuild -project Parrot.xcodeproj -target Parrot -configuration Debug build
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO`.
- A1's real verification is **on-device**: record a continuous-speech session,
  then re-run the segment-duration query from Part 1 — the `>20s` bucket should
  be gone and live text should update within ~1–2 s.

## Key file reference map

| Concern | File | Anchor |
|---|---|---|
| Transcription loop / buffering | `Parrot/Services/TranscriptionEngine.swift` | `startTranscribing` 128-192; drain 145-150; transcribe 167 |
| Audio capture / levels / echo push | `Parrot/Services/AudioCaptureManager.swift` | mic tap ~205-241; levels 285-305 |
| Echo cancellation | `Parrot/Services/EchoCanceller.swift` | ring buffers ~53-106 |
| Analysis loop / triggers | `Parrot/Services/CallAnalysisEngine.swift` | ingest 92-123; runAnalysis 146-216; timings 40-48 |
| Claude prompt + schema | `Parrot/Services/AnalysisProvider.swift` | system prompt 59-88; schema 133-151 |
| Knowledge base / RAG | `Parrot/Services/KnowledgeBaseService.swift` | search 93-127; chunk 141-161 |
| Live recording layout | `Parrot/Views/LiveRecordingView.swift` | panel HStack 28-35; transcript list 142 |
| Copilot panel | `Parrot/Views/CopilotPanelView.swift` | width 58; collapse 23,316-321; greys 444 |
| Post-meeting report | `Parrot/Views/MeetingDetailView.swift` | section VStack 20-57 |
| Models | `Parrot/Models/{Meeting,Insight,TranscriptSegment,KnowledgeBase}.swift` | `Meeting` has no profile field |
| Copilot perf notes | `docs/PERFORMANCE.md` | timing/cost characterization |

Note: line numbers are approximate and drift as code changes — use them as
starting anchors, not exact addresses.
