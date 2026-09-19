# Jev fast document answers for the Copilot — design (draft)

Date: 2026-09-19. Status: **implemented on branch
`claude/jev-parrot-copilot-eval-5b7ca7`** (see §9 for what the eval changed).
Everything about Jev below was verified against docs.typesafe.ai on
2026-09-19; everything about Parrot against the tree at `f612b31`.

## 1. Problem

Question to card on Fast pace: median 3.5 s, p90 5 s (docs/PERFORMANCE.md).
Balanced and Relaxed are far worse, and there the wait is the cadence timers,
not Haiku: a question can sit through 3 s + 20 s or 10 s + 60 s before Haiku
is even called.

Where the time goes on Fast, after the other side stops talking:

| Step | Time | Addressable by a model choice? |
|---|---|---|
| Utterance close (600 ms silence) + WhisperKit decode | 1.6–3.1 s | No |
| Question debounce | 1 s | Yes, free |
| Floor since the last call | 0–5 s | Yes, free |
| Knowledge base cosine search | tens of ms | No |
| One Haiku pass writing the whole JSON, no streaming | 1.5–4 s, tail 9 s | Partly |

## 2. What Jev is, verified

- `POST https://api.typesafe.ai/v1/systemone`, `Authorization: Bearer`,
  body `{state, model: "jev-latest", questions: {id: {type, instructions,
  criteria}}}`. State may be a string, a JSON object, or an array; object
  keys can be referenced by name from question instructions.
- `noul` answers are `{type: "noul", noul: 0…1}` and carry **no confidence
  field**. `choice` answers carry `choice`, `probabilities`, `confidence`;
  confidence flattens when several options are plausible.
- Response carries `usage.input_tokens`. Errors 401 / 422 / 429 / 529, with
  "retry with exponential backoff" guidance. Limits: 64k tokens per request,
  32k for state plus the longest question; 1,200 requests per minute.
- $0.042 per million input tokens, output free.
- All questions in one request are answered in parallel; the cookbook shows
  13 questions in 0.27 s. Adding questions adds roughly no latency.
- Jev 1.13 jaggedness page: literal reading; cannot count; weak on numbers,
  dates and score interpolation; irrelevant detail in the state distracts;
  does **not** treat state as hostile (prompt injection is on us); no text
  generation; English best, other languages weaker.
- The `classifying_rag_passages` and `rerank_typesafe` cookbooks both put the
  query and **one** passage in the state and ask nouls about the pair. Rerank
  explicitly chose "one noul per candidate, sort by noul" over a choice
  across candidates. Thresholds in those cookbooks: 0.55 to include as
  evidence, 0.70 to act.
- Privacy policy: hosted in the United States; "will not train or fine tune
  … on your prompts or other Input"; retention "as long as reasonably
  necessary to provide … the Services"; zero data retention for enterprise
  customers only; privacy@typesafe.ai. No public subprocessor list.
- The Claude Code plugin teaches question authoring for agents. It has
  nothing for Swift or raw REST, so it was not installed; the docs were read
  directly.

## 3. Options, ranked

| # | Option | Saves | Works in | Churn | Verdict |
|---|---|---|---|---|---|
| 1 | **Per-pace question floor** (corrected 1a): a "Them" question waits a short question floor instead of the full floor. Fast 5→2 s, Balanced 20→5 s, Relaxed 60→15 s. Question debounce on Fast 1→0.3 s. | Up to 3 s on Fast; 15–45 s on Balanced/Relaxed | Every mode incl. Ollama | ~10 lines | **Do first, in the same PR** |
| 2 | **Jev "From your docs" card**: on a "Them" question, widen KB search to 8, ask Jev one noul per chunk, show the winning chunk as an excerpt card within ~0.5 s, hand the chunk to the next Haiku pass. | ~3 s on Fast, 20–60 s on slower paces, **only for doc-covered questions** | Claude mode + KB + TypeSafe key | ~250 lines | **MVP** |
| 3 | Reply-first Haiku split (1b): a second, small, unstructured streamed call that writes one reply. | 1–2 s on Fast | Claude / custom; **not Ollama** (a second local call competes with WhisperKit for the GPU) | Medium; doubles calls per question; dedup interplay | Defer until 1+2 are measured |
| 4 | Jev on live preview text before the utterance closes. | Up to the 600 ms close + part of the decode | Same as 2 | Preview text changes every second; needs fire-once logic | Phase 2, after 2 proves precision |
| 5 | Jev for dedup ("same underlying issue?") and resolved detection per open card. | Quality, not latency | Claude + key | Replaces two heuristics, keeps them for Ollama | Real win, **own PR**, own eval |
| 6 | Jev for the 0–100 score or gauges; anything offline. | — | — | — | Not recommended, agreed |

Pushback on the recommendation as written:

- **1a as "bypass the floor" is wrong for Relaxed.** Relaxed exists so a
  free-tier model survives a meeting; a rapid-fire questioner would burst
  calls and hit the limit. A shorter per-pace question floor keeps the
  single-in-flight rule and a cap on calls per minute.
- **1b is not free in every mode.** On Ollama a second call per question
  shares the GPU with live transcription and makes both slower. On Claude it
  is a second billed call per question. Streaming a plain-text reply is the
  better shape if it is ever built.
- **Jev's win is bounded by knowledge base coverage.** It does nothing for a
  question the docs don't answer. The first number to measure is the share of
  "Them" questions on a real call that a loaded document answers. If that is
  under about 20 %, a third vendor is not worth it.
- **Use nouls, not a choice across chunks.** Two overlapping chunks from the
  same document both answer; a choice splits probability between them and
  confidence drops, a false negative. One noul per chunk has no such problem
  and is what both cookbooks do.
- **The separate "is this a question the docs answer" noul is redundant.**
  The maximum noul across candidates is that signal.
- **"Above a confidence threshold" must be a probability threshold.** Noul
  answers carry no confidence field.

## 4. MVP, scoped to one PR

### 4.1 Per-pace question floor

`CopilotPace.timing` gains a fifth value, `questionFloor`: Fast 2 s,
Balanced 5 s, Relaxed 15 s. `ingest` already knows `isUrgent`; it passes
that to `triggerAnalysis(urgent:)`, which uses `questionFloor` instead of
`minimumInterval` when urgent. A rerun queued behind an in-flight call
remembers urgency in a `pendingUrgent` flag so the question does not lose its
short floor. Question debounce on Fast drops to 0.3 s; utterances are already
silence-bound so a question is almost always one segment.

Worst case on Fast: single in-flight + ~2.5 s Haiku bounds calls at about 13
per minute, about $1.60 per hour under nonstop questions. Fast is labeled
"most requests, highest cost", so that is within the contract. The
continuous-speech replay (§5) must show calls per minute stay under 5.5
(today 4.2).

### 4.2 Fast document answer path

**Gate.** The path exists for a call only when all hold at `start()`:
live provider is Claude; a TypeSafe key is in the Keychain; the knowledge
base has documents tagged into the active profile. Any missing piece: the
engine's `fastPath` is nil and nothing else changes. Ollama and custom modes
never get it: a user who chose local chose local.

**Hook: `ingest`, not `triggerAnalysis`, not a sibling engine.** `ingest`
is the one place that sees "Them + looks like a question" first, and it must
not go through `triggerAnalysis` because that is the Haiku cadence gate.
Inside `ingest`, right after `isUrgent` is computed:

```
if isUrgent, let fastPath, let kb = knowledgeBase {
    fastTask?.cancel()
    fastTask = Task { await self.fastDocAnswer(question: text, at: time) }
}
```

`fastDocAnswer` (about 40 lines in the engine): query = previous "Them"
segment + this one; `kb.search(query:profileID:topK: 8)`; no candidates →
return; call the client with a 700 ms budget; take the best noul; below the
threshold → return; insert the card at index 0; remember it as pending for
the Haiku handoff.

**Client: a new file `Services/JevDocMatcher.swift`, no protocol.** A
`final class` with `isConfigured`, one method
`score(asked:before:candidates:) async throws -> [Double]`, and static pure
helpers `buildBody` and `parse` so `--profile-test` covers the request and
response shape without a network. Usage metering copies the lock-and-totals
pattern from `ClaudeAnalysisProvider`. It is **not** added to
`AnalysisProvider`: that protocol means "turn a transcript window into
insights", and Ollama/custom would need stubs. It is not a second protocol
either. The day a second matcher exists (a local CoreML cross-encoder would
be the natural one, and the offline answer), extract the protocol then.

**Request shape.** One HTTP request, JSON state with named parts, one noul
per candidate:

```json
{
  "model": "jev-latest",
  "state": {
    "asked":  "<this Them utterance>",
    "before": "<previous 1–2 lines, speaker-tagged, ≤ 300 chars>",
    "c0": "<chunk text>", "c1": "…", "c7": "…"
  },
  "questions": {
    "c0": {
      "type": "noul",
      "instructions": "Does the text in `c0` state the information needed to directly answer the question in `asked`? Use `before` only to understand what `asked` refers to. Judge `c0` on its own; ignore the other c* texts.",
      "criteria": {
        "true":  "`c0` explicitly states the fact, number, policy, date, or procedure that `asked` is asking for.",
        "false": "`c0` is only on a related topic, answers a different question, or gives no usable specifics."
      }
    }
  }
}
```

About 3k input tokens per question, about $0.00013. The cookbooks use one
request per passage; the jaggedness page warns that unrelated detail
distracts. The offline eval (§5, step A) runs both shapes on the same
labeled set. The code difference is a task group around the same builder;
ship whichever wins. Default assumption: the single request.

**Threshold.** Show when the best noul ≥ 0.75; the eval sets the final
value, never below 0.60. Precision first: a wrong excerpt shown with
conviction is worse than nothing. No "partial" tier in the MVP; the
mid-band is left to Haiku.

**Card.** A plain `Insight` with the reserved kind key `doc_excerpt`:
title is the question as transcribed, in quotes; detail is the chunk text;
`source` is the document name; no `reply`. `KindResolver.fallbackStyle`
gains one case: label **"From your docs"**, icon
`doc.text.magnifyingglass`, `Theme.Colors.ink2`, not pinned. The hero card
clamps detail to 6 lines for this kind with the existing show-more
behavior. It never gets the Copy pill: a chunk is not a line to say. Nothing
about the card claims to be an answer; it is labeled as an excerpt.

The card lives in the same `insights` array so the panel renders it in
order, but three sites filter `doc_excerpt` out: the `knownInsightTitles`
sent to Haiku (otherwise Haiku sees the question as "already shown" and
skips answering it), the `openInsights` dedup set, and persistence at stop
(`RecordingManager` line ~277). It is ephemeral: it does not reach the
report.

**Handoff to Haiku, and what happens when Haiku disagrees.** The engine
keeps `pendingFastCard = (id, chunk, questionText)`. In `runAnalysis`, if
pending, the chunk is prepended to `references` when not already there, so
Haiku reasons over the same evidence Jev picked (today Haiku only sees the
top 4; Jev looked at 8). After the result: if any admitted insight has
`source == chunk.documentName` or shares a topic stem with the question
(`sharesTopicStem` exists), Haiku's card supersedes and the fast card is
removed. Otherwise the fast card stays: Haiku produced nothing for that
question, and the excerpt is still true. If Haiku's reply says the docs do
not cover it, that card stands next to the excerpt for the user to weigh.
Never remove within 2 s of showing; replace in place rather than
remove-then-insert so the panel does not flicker. The user can dismiss it
like any card.

**Failure handling.** 700 ms budget end to end; on timeout, 429, 529, or
any parse error: skip silently, no retry (a retry would land after Haiku
anyway). Three consecutive failures disable the path for the rest of the
call. The engine's `status` is never touched by the fast path.

**Key and settings.** Keychain account `typesafe-api-key` via the existing
`APIKeyStore`. Settings → API Keys gets a fourth `KeyField` with the hint:
"Instant answers from your documents. Sends the other side's question, a few
lines of context, and the matching snippets of your documents to TypeSafe AI
in the US. Audio never." Settings → Copilot, under the Claude provider
config, one hint line with the "Open API Keys" link. Key present = on; no
extra toggle. Entering the key is the opt-in, the same contract Claude,
Groq and Deepgram use today.

**Cost row.** `AIPricing.typesafeInputUSDPerMTok = 0.042`. `AIUsage`
gains `docAnswers: AITokenTotals?` and `docAnswerModel: String?` (nil on
older meetings). `costBreakdown()` adds one line, "Doc answers jev-latest ·
N calls · Xk in", only when calls > 0. `writeAIUsage` reads the matcher's
totals. One `--profile-test` check prices it.

**Help and privacy text.** `docs/help/privacy.html`, "Sent out only if you
set it up", one bullet: "Instant document answers (TypeSafe AI): when the
other side asks a question, that question, the last few lines of the call,
and the matching snippets of your documents go to TypeSafe AI, hosted in
the US. Audio never goes. They state they do not train on it and keep it
only as long as needed to run the service." `docs/help/copilot-setup.html`
gets a short paragraph under Claude. README's vendor mention, if any, gains
TypeSafe. The "fresh install sends nothing" promise stays true.

**Files touched.** `CallAnalysisEngine.swift` (question floor, hook,
handoff, three filters), new `JevDocMatcher.swift`, `KindStyle.swift` (one
case), `CopilotPanelView.swift` (6-line clamp, no Copy pill for the kind),
`AIUsage.swift`, `RecordingManager.swift` (usage + persistence filter),
`SettingsView.swift` (key field + hint), `SnapshotTool.swift` (two
harnesses, §5), `ProfileTest.swift`, two help pages, FILEMAP.md.

## 5. Measurement plan and merge bar

The simulation PERFORMANCE.md cites was never committed (e294a97 changed
only the engine and the doc), `--copilot-snapshot` renders seeded state,
and imports never run the live engine. So both harnesses below are new.
They are the first commits of the PR; the engine hook and UI land only if
step A clears the bar.

**A. Offline precision eval, `--doc-answer-eval labels.json`.** Input: a
list of `{asked, before, answeringDocument | null}` built from one real call
whose documents are in the knowledge base (the 2026-07-17 call is the
candidate). The harness runs the real `KnowledgeBaseService.search` on the
real index, calls Jev in both request shapes, and prints per item the top
chunk and its noul, then precision, recall and p50/p90 round trip at
thresholds 0.50…0.90. About 40 labeled questions; ideally 15 of them from a
Turkish call so the language gate (§6) is decided by data.

**B. Latency replay, `--copilot-replay export.txt [--haiku-ms 2500]`.**
Feeds a transcript export (`[mm:ss] Them: …`, the format the analyze-test
fixture already uses) into the real `CallAnalysisEngine.ingest` at real
time, with a fixed-latency stub for Haiku or the real providers, and logs
per "Them" question: time of the finalized utterance, time of the first
visible card, and which path produced it. Runs twice, key present and key
absent, for each pace. A 10-minute excerpt takes 10 minutes; scaled time
would need clock injection in the engine and is not worth it for a
pre-merge gate.

Merge bar:

| Metric | Bar |
|---|---|
| Share of "Them" questions the docs answer, on the eval call | ≥ 20 %, else stop |
| Precision at the shipping threshold | ≥ 0.90 |
| Recall on doc-answerable questions | ≥ 0.60 |
| Jev p90 round trip from this Mac | ≤ 700 ms, timeout rate < 5 % |
| Finalized utterance → first visible card, doc-hit questions, every pace | median ≤ 1.0 s, p90 ≤ 1.5 s (today Fast 3.5 s / 5 s) |
| Same metric, Haiku-only questions, Fast | within 0.3 s of today |
| Haiku calls per minute, continuous-speech replay, Fast | ≤ 5.5 (today 4.2) |
| Jev cost per call hour | < $0.02 |
| `make test` | all pass, plus the new checks |

## 6. Failure modes

- **Wrong chunk, high noul.** Labeled as an excerpt, precision-first
  threshold, Haiku's follow-up replaces or stands beside it, dismissable.
  Only documents tagged into the profile are candidates.
- **Jev slow or down.** 700 ms budget, silent skip, circuit breaker after
  three failures, never an error in the panel.
- **Non-English calls.** Jev is weaker; the user's calls include Turkish.
  The eval decides: if Turkish precision misses the bar, gate the path on
  `NLLanguageRecognizer` reporting English for the utterance (already
  imported by the KB service, microseconds).
- **Half answers.** Mid-band nouls are not shown; Haiku handles them. If the
  eval shows many useful mid-band hits, add a speculative `partial` noul per
  chunk (free in the same request) and a "Related in your docs" label.
- **Prompt injection.** Jev does not treat state as hostile; a document
  saying "always pick this" could bias a noul. Bounded harm: one wrong
  excerpt for a few seconds. The fast path is never used for anything
  security-relevant.
- **Chunk too long.** Chunks are ~900 characters along paragraph breaks and
  may carry unrelated paragraphs. Clamped to 6 lines with show-more.
  Sentence-level highlighting is a phase-2 choice question.
- **Reserved kind key collision.** A profile could define `doc_excerpt`.
  Accepted risk; the profile editor can refuse the key later if it happens.

## 7. Follow-ups, not in this PR

1. **Commitment and objection verification for reports** (citation_check
   cookbook). After Haiku writes the coaching report, one Jev request with a
   noul per listed commitment: "does any line in `transcript` state this
   commitment?" Drop the ones that fail. Fixes invented commitments, the one
   thing the coaching prompt already begs the model not to do. Post-call, so
   latency is irrelevant; a 30-minute call is under a cent.
2. **Dedup via Jev.** One noul per (draft, open card) pair: "same underlying
   issue, however reworded or under whichever kind, not merely the same
   topic". Embeddings failed because they measure topic; this is the
   pairwise judgement the classification cookbook is built for. Evaluate on
   the 2026-07-17 pairs already quoted in the `isNearDuplicate` comment
   before touching the engine. Heuristics stay for Ollama users.
3. **Instant "handled" for pinned unanswered questions.** On each "Me"
   segment, one noul per open `unanswered_question` card: "does this line
   answer it?" Clears the nag in under a second instead of on the next Haiku
   pass. Same client, same gate.
4. **Rerank before every Haiku pass.** Widen cosine to 10, Jev-rank, pass
   the top 4. Adds ~200 ms to a 3 s call for better grounding. Only if
   "general knowledge" answers to doc-covered questions are observed.
5. **Sentence highlight in the excerpt card.** A choice over the chunk's
   sentences, "which one most directly answers `asked`". Bolds the line.
6. **Preview-text speculation.** Fire once when the "Them" preview looks like
   a question with ≥ 6 words, again on finalization only if the text changed
   materially.

## 8. Open questions

1. Which real call, with which documents loaded, is the eval set? Can you
   label about 40 "Them" questions as "this doc / none"? The 2026-07-17
   call is my candidate.
2. What share of your calls are Turkish or otherwise non-English? Should
   the path be English-only from day one, or let the eval decide?
3. Strictly Claude mode, or also custom-server mode when the server is a
   cloud gateway?
4. Threshold posture: precision-first at 0.75 as proposed, or recall-first?
5. Card handoff: remove the excerpt when Haiku's grounded card arrives, as
   proposed, or keep both?
6. Is a 15 s question floor acceptable on Relaxed for free-tier users, or
   should Relaxed keep its 60 s floor for questions too?
7. Do you already have a TypeSafe key? One curl from your Mac gives the real
   round trip before anything is built.
8. Privacy posture: is a US-hosted vendor with standard retention acceptable
   for your own calls and for what the help page promises?
9. Ephemeral card, or persist it into the meeting's insights?

## 9. What the eval changed (2026-09-19, implementation notes)

The open questions in §8 were answered by the user's instruction to build
and test autonomously with the Launchese knowledge base (113 KB, 35
sections) as the document under test. Decisions taken and what the numbers
said:

- **Retrieval was the bottleneck, not Jev.** With the original cosine search
  the answering chunk reached the 8 candidates for 14 of 71 covered
  questions; where it did, Jev picked it 11 times out of 13 with zero false
  positives. A BM25 exact-word ranking put it in the top 8 for 55 of 71, so
  `KnowledgeBaseService.search` is now a hybrid: BM25 and embedding rankings
  fused by reciprocal rank fusion. Haiku's four references come from the same
  ranking, so its grounding improved as a side effect.
- **Twelve candidates, not eight.** Top 8 covered 77 % of questions, top 16
  87 %; twelve chunks are still about 3k tokens and cost no latency.
- **Single request wins.** One request with twelve named chunks and twelve
  nouls scored the same retrieval ceiling as one request per chunk, with
  slightly better precision at 0.90 and lower latency (p50 0.33 s vs 0.30 s
  is within noise; per-candidate's max was 0.54 s).
- **Threshold stays 0.75.** Precision is flat from 0.50 to 0.90 (0.81 to
  0.83 by substring label, about 0.90 after re-reading the "wrong" picks by
  hand: five of nine contained the answer in other words). Raising the gate
  only lost recall. The uncovered questions never crossed 0.50.
- **Heading-only chunks.** The paragraph chunker left bare headings ("## 17.
  How Launchese works") as their own chunks, and Jev rated one at 0.66 for a
  price question. Headings are now glued onto the paragraph that follows,
  separators dropped, and oversized tables or lists split by line with the
  section heading carried on every piece.
- **Turkish.** Recall at 0.75 went from 0 of 15 to 5 of 15 with the hybrid
  search (English product words carry), with no false positives on the two
  uncovered Turkish questions. No language gate: the path stays precise and
  merely fires less often.
- **Stale demo documents.** The user's knowledge base still holds
  `01-company-formation.md` and `northwind-demo-faq.md`; one answered "a few
  hundred quid for formation" with "from GBP 49". Flagged for removal in
  Settings → Knowledge; not deleted by the tooling.
- **Question debounce.** Shortened on every pace (Fast 0.3 s, Balanced 1 s,
  Relaxed 3 s), not only Fast: utterances are silence-bound, so the debounce
  never coalesced a question anyway.
- **Build environment.** Xcode 27's license is unaccepted on this Mac, so
  every `/usr/bin` developer shim refuses to run; the work was built by
  calling the toolchain directly with `swift build --product Parrot`, which
  also sidesteps a dependency plugin that fails to compile under a macOS 12
  host target. `sudo xcodebuild -license accept` restores plain `make`.
- **Fusion reversed, stop words added (later the same day).** Equal-weight
  rank fusion of BM25 and embeddings scored worse than BM25 alone at the top
  of the list. Now BM25 ranks and embeddings only fill the slots the words
  did not reach, with English function words dropped from the tokens:
  answer in the top 4 for 50 of 71 questions (was 32), precision 0.91 and
  recall 0.70 at the 0.75 gate. Spoken compound questions ("what is this
  verification and how much is express") went from missing to a 0.94 hit.
- **Live run.** A two-voice synthetic call through the speakers measured
  1.8 to 2.5 s from the prospect's last word to the excerpt and 6 to 9 s to
  Claude's card; see docs/PERFORMANCE.md.
- **Reserved embedding slots, question-first Haiku references.** A generic
  "how much does it cost to set one up" shares no words with the pricing
  chunks; a third of the candidate slots now go to the top embedding matches
  and the chunk reaches Jev (0.98) and Haiku. Haiku's references lead with
  the latest question from the other side rather than the 8-line window,
  which mic-bleed small talk had polluted in the live run. Precision at the
  gate 0.92, zero false positives, top-4 retrieval unchanged at 50 of 71.
- **Deepgram.** Its "Them" socket died about 15 s in on quiet system audio
  (10 s no-audio close); a KeepAlive every 5 s fixed it, the close reason is
  now logged publicly, and our own teardown is no longer reported as a
  failure. With Deepgram streaming the transcript lands before the prospect
  finishes and the excerpt was on screen 0.2 s before the audio ended.
