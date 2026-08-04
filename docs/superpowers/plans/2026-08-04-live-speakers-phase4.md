# Live Speaker Labels Phase 4 Implementation Plan (internal test)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** During a recording, non-Me bubbles upgrade from "Them" to stable "Speaker 1/2/…" labels every ~30 seconds — using the already-shipped engine, behind an experimental default-off toggle. Internal test only: branch stays unmerged, no release.

**Architecture:** The spec's favored route — **periodic re-runs, not streaming models**. A sweep task re-diarizes the growing system-audio `.caf` every 30 s (the engine runs at ~380× realtime, so each sweep costs single-digit seconds) and relabels existing segments in place. A pure "stable mapping" function matches each run's clusters to the previous run's embeddings so Speaker 1 never flips identity mid-call; the final post-call pass maps through the same anchors for continuity. Live UI and Copilot prompts need zero changes — they already render `speakerLabel`.

**Tech Stack:** existing `DiarizationEngine` (chunked pipeline), `SpeakerProfileStore.cosine`, one repeating Task in `RecordingManager`.

## Global Constraints

- Spec phase-4 section (periodic re-runs favored; live labels provisional, final pass authoritative).
- **Default OFF**, Settings toggle marked experimental; zero behavior change when off (all new code behind the flag except the pure mapping function, which postProcess uses with empty anchors = identity).
- Sweeps must never fight the writer or themselves: skip a cycle when the engine `isProcessing`, when elapsed < 45 s, or when the file read throws (the `.caf` is mid-write; CAF tolerates readers, but any error just waits for the next cycle).
- Anchor-match threshold reuses the calibrated 0.7 (same voice across runs ≈ 0.96 measured).
- Segments arriving between sweeps stay "Them" until the next sweep — accepted for v1.
- No release: PR opens as **draft**; internal testing from this branch's `dist` build.

---

### Task 1: stable mapping function (TDD)

**Files:**
- Modify: `Parrot/Services/RecordingManager.swift`
- Test: `Parrot/ProfileTest.swift` (`testLiveLabelStability()` registered after `testVoiceProfiles()`)

**Interfaces (produced):**

```swift
/// Maps a diarization run's labels onto the previous run's identities.
/// Greedy in "Speaker 1" order: best unused anchor with cosine ≥ 0.7 wins
/// that anchor's label; unmatched clusters get the next unused index.
/// Empty anchors → identity.
nonisolated static func stableMapping(
    newEmbeddings: [String: [Float]],
    anchors: [String: [Float]]
) -> [String: String]
```

- [ ] **Step 1: failing checks**:

```swift
static func testLiveLabelStability() {
    typealias M = RecordingManager
    let anchors: [String: [Float]] = ["Speaker 1": [1, 0, 0], "Speaker 2": [0, 1, 0]]
    check("identity when no anchors",
          M.stableMapping(newEmbeddings: ["Speaker 1": [1, 0, 0]], anchors: [:]) == ["Speaker 1": "Speaker 1"])
    let flipped = M.stableMapping(
        newEmbeddings: ["Speaker 1": [0, 0.99, 0.1], "Speaker 2": [0.99, 0, 0.1]],
        anchors: anchors)
    check("talk-order flip keeps identities",
          flipped == ["Speaker 1": "Speaker 2", "Speaker 2": "Speaker 1"])
    let grown = M.stableMapping(
        newEmbeddings: ["Speaker 1": [1, 0, 0], "Speaker 2": [0, 0, 1]],
        anchors: ["Speaker 1": [1, 0, 0]])
    check("new voice gets fresh label", grown == ["Speaker 1": "Speaker 1", "Speaker 2": "Speaker 2"])
    let taken = M.stableMapping(
        newEmbeddings: ["Speaker 1": [0, 0, 1]],
        anchors: anchors)
    check("unmatched avoids anchor labels", taken == ["Speaker 1": "Speaker 3"])
}
```

- [ ] **Step 2:** build → fails. **Step 3:** implement (uses `SpeakerProfileStore.cosine`; fresh labels = "Speaker N" for the smallest N unused by anchors and prior assignments). **Step 4:** ALL PASS. **Step 5:** commit.

---

### Task 2: sweep loop + continuity into the final pass

**Files:**
- Modify: `Parrot/Services/RecordingManager.swift`

- [ ] **Step 1: state + lifecycle** — add `private var liveSweepTask: Task<Void, Never>?` and `private var liveAnchors: [String: [Float]] = [:]`. In `startRecording` (after `isRecording = true`): `liveAnchors = [:]`, and when `UserDefaults.standard.bool(forKey: "liveSpeakerLabels")`, start:

```swift
liveSweepTask = Task { [weak self] in
    while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(30))
        await self?.runLiveSweep()
    }
}
```

In `stopRecording` (right after the timer invalidation): `liveSweepTask?.cancel(); liveSweepTask = nil`.
- [ ] **Step 2: the sweep**:

```swift
/// One live pass: re-diarize the call so far and relabel in place. Labels
/// stay identity-stable via `stableMapping`; failures just wait for the
/// next cycle (the .caf is mid-write).
private func runLiveSweep() async {
    guard isRecording, elapsedTime >= 45, !diarizationEngine.isProcessing,
          let meeting = currentMeeting,
          let path = meeting.systemAudioPath.nilIfEmpty else { return }
    do {
        let output = try await diarizationEngine.diarize(audioURL: URL(fileURLWithPath: path))
        let mapping = Self.stableMapping(newEmbeddings: output.embeddings, anchors: liveAnchors)
        let turns = output.segments.map {
            DiarizationEngine.SpeakerSegmentResult(
                speakerLabel: mapping[$0.speakerLabel] ?? $0.speakerLabel,
                startTime: $0.startTime, endTime: $0.endTime)
        }
        for segment in meeting.segments where segment.speakerLabel != "Me" {
            if let label = Self.diarizedLabel(for: (segment.startTime, segment.endTime), turns: turns) {
                segment.speakerLabel = label
            }
        }
        liveAnchors = Dictionary(uniqueKeysWithValues: output.embeddings.map { (mapping[$0.key] ?? $0.key, $0.value) })
        try? modelContext?.save()
    } catch {
        NSLog("Parrot: live speaker sweep skipped — \(error.localizedDescription)")
    }
}
```

- [ ] **Step 3: continuity in postProcess** — after `diarize` returns, insert the same mapping step (`let mapping = Self.stableMapping(newEmbeddings: output.embeddings, anchors: liveAnchors)`), remap turns + embeddings before assignment/persist, then `liveAnchors = [:]`. With empty anchors the mapping is identity, so non-live meetings and redetect are untouched.
- [ ] **Step 4:** build + ALL PASS; commit.

---

### Task 3: experimental toggle + validation

**Files:**
- Modify: `Parrot/Views/SettingsView.swift` (Speaker Detection section)

- [ ] **Step 1:** `Toggle("Live speaker labels", isOn: $liveSpeakerLabels)` (`@AppStorage("liveSpeakerLabels") = false`) + caption: "Experimental. During a call, tells the other people apart every 30 seconds instead of waiting for the end. The final pass when the call ends is still the accurate one."
- [ ] **Step 2:** `make test` ALL PASS; `make`; relaunch dist.
- [ ] **Step 3: live validation** — enable the toggle; start a recording; `afplay` a 2–3 min excerpt of the Aug 3 system track (both voices present) so system-audio capture hears two real speakers; watch the live transcript: "Them" bubbles should upgrade to Speaker 1/2 after the first sweep (~45–60 s in) and labels must not flip identities on later sweeps; stop the call and confirm the final pass + naming flow still work. Screenshot the live view mid-call.
- [ ] **Step 4:** push branch, **draft** PR titled as internal; do NOT merge or release.

## Self-review notes

- Zero-change-when-off audit: sweep task only starts behind the flag; `stableMapping` with `[:]` anchors is identity in postProcess; Settings adds one default-off row.
- The engine serializes itself via the `isProcessing` guard (sweep skips while the final pass or another sweep runs; `stopRecording` cancels the loop before postProcess starts, and postProcess runs after capture stop finalizes the .caf).
- Cost: one ~1–6 s ANE burst per 30 s alongside Whisper — battery/thermals are an explicit internal-test observation item.
