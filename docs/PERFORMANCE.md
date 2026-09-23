# Copilot Performance Test Results

Performance characterization of the live call copilot (`CallAnalysisEngine` +
`ClaudeAnalysisProvider`). The trigger/debounce/rate-cap logic was tested with a
discrete-event simulation that ports the engine's exact timing semantics
(question debounce 1s, idle debounce 8s, minimum call interval 5s, staleness cap
15s, single in-flight call with queued rerun). Cost figures use published
`claude-haiku-4-5` pricing ($1 / $5 per million input/output tokens).

## Test 1 — Question → insight latency (10-minute continuous-speech call, 17 questions)

| API response time | Median | p90 | Max | API calls/min |
|---|---|---|---|---|
| 1.5s (fast) | 2.5s | 7.0s | 7.0s | 4.4 |
| 2.5s (typical Haiku) | 3.5s | 5.0s | 9.0s | 4.2 |
| 4.0s (slow) | 5.0s | 10.0s | 12.0s | 4.2 |

All 17/17 questions received an insight. No overlapping API calls in any run.

**Bug found and fixed by this test:** the original design reset the idle
debounce on every transcript segment, so during continuous speech the ambient
analysis never fired — questions missed by the fast-track heuristic waited up to
~43s (p90 ~34s) for the next detected question. The fix adds a 15s staleness
cap: unanalyzed speech is always analyzed within 15s regardless of debouncing.

## Test 2 — Rate-cap stress (a question every 3s for 2 minutes)

17 API calls in 2 minutes (8.5/min ceiling), minimum gap between calls exactly
at the 5s floor, zero overlapping calls. The cap holds under rapid fire.

## Test 3 — Question heuristic accuracy (Whisper-style text, no punctuation)

16/16 questions detected, 0/12 false positives on statements, after broadening
the opener list (added "how long", "are you", "will it", "tell me about", etc.).
Misses are not lost — they fall back to the 15s staleness guarantee instead of
the 1s fast track.

## Test 4 — Tokens & cost per call hour

- ~900 input + ~250 output tokens per analysis call → **~$0.002 per call**
- Typical hour-long call: **~$0.20–0.60** (continuous speech is the worst case
  at ~4.4 calls/min; real calls with pauses trigger less often)
- Absolute worst case at the rate cap (8.5 calls/min for a full hour): ~$1.10

## Not yet measured (needs a Mac / real API key)

These can't run in the CI container and should be verified on-device:

- Xcode build + real end-to-end latency with a live Claude API key (expected
  time-to-full-response ~1.5–3s for Haiku with this payload size)
- WhisperKit transcription lag (segments are utterance-bound since VAD
  segmentation: text lands at natural pauses, worst-case 12 s into an
  uninterrupted monologue — see TranscriptionEngine.Segmenter)
- UI responsiveness of the insight panel during long calls (LazyVStack should
  keep this flat, but verify with Instruments on a 1-hour session)

## Test 5 — Jev fast document answers + question floor (2026-09-19)

Setup: the user's real knowledge base (a 113 KB, 35-section company document
chunked to 173 pieces plus two small demo files), 85 labeled questions (56
English synthetic, 11 English questions transcribed from real sales calls,
15 Turkish, 14 that the documents do not answer) run through the real KB
search and TypeSafe `jev-latest` with `--doc-answer-eval`. A label is a
substring the answering chunk must contain, so "wrong" below over-counts:
re-reading the wrong picks by hand, most contained the answer in other words
or came from the two stale demo documents, so the shipped precision is
nearer 0.95.

### Retrieval decides everything

| KB search | answering chunk in the candidate list (71 covered questions) |
|---|---|
| Embedding cosine only, top 8 (before) | 14 / 71 |
| BM25 exact-word only, top 8 (prototype) | 55 / 71 |
| Hybrid BM25 + cosine, equal-weight rank fusion, 12 candidates | 51 / 71, 32 within the top 4 |
| BM25 first with stop words, embeddings fill the rest, 12 candidates | 58 / 71, 50 within the top 4 |
| Same, with a third of the slots reserved for embedding matches (shipped) | 58 / 71, 50 within the top 4; a generic "how much does it cost to set one up" goes from missing to a hit |

Where the chunk is in the list, Jev picks it: with cosine-only retrieval it
hit 11 of the 13 questions it answered, with zero false positives. Equal
weight fusion turned out worse than BM25 alone at the top of the list, so
the words rank and the embeddings only fill what the words did not reach.
Haiku's four references come from the same search, so its grounding
improved too: 50 of 71 in the top 4 instead of 12.

### Precision and recall by threshold, hybrid retrieval, single request with 12 nouls

| Threshold | shown | hits | wrong (by substring) | false positives (uncovered) | precision | recall |
|---|---|---|---|---|---|---|
| 0.50 | 55 | 51 | 4 | 0 | 0.93 | 0.72 |
| 0.75 (shipped) | 53 | 49 | 4 | 0 | 0.92 | 0.69 |
| 0.90 | 45 | 43 | 2 | 0 | 0.96 | 0.61 |

Precision barely moves across the range, so raising the gate mostly loses
recall; 0.75 stays. English recall at 0.75: 44 / 56. Turkish: 5 / 15 (English
product words carry; 0 / 15 before the hybrid search), no false positives on
the two uncovered Turkish questions. One request with all candidates and one
request per candidate reached the same ceiling; the single request had the
better tail (max 0.65 s vs 0.54 s at p90 0.45 s vs 0.36 s is noise; per
candidate lost one more at 0.90) and is what ships.

### Round trip

Measured from this Mac: p50 0.32 s, p90 0.42 s, max 0.71 s for 12
candidates on a warm connection; a cold TLS handshake adds about 0.4 s,
which is why the client warms the connection when a call starts. Cost: about
3k input tokens per question, $0.00013; well under $0.02 per call hour.

### What was fixed along the way

- The paragraph chunker left bare headings as their own chunks ("## 17. How
  Launchese works"), and Jev rated one at 0.66 for a price question.
  Headings now stay with the paragraph that follows; oversized tables and
  lists split by line and every piece carries its section heading.
- Two stale demo documents in the user's knowledge base answered a Launchese
  pricing question with "from GBP 49". The tooling never deletes user
  documents; they are flagged for removal.

### Question → first visible card, real call replay

`--copilot-replay` fed the first 5 minutes of a real English sales call (174
transcript lines, 15 "Them" lines the question heuristic flagged) into the
real engine at real time, with a fixed 2.5 s stand-in for Haiku that answers
the newest question in each window, and the real knowledge base plus Jev.
Times are wall-clock from the finalized utterance reaching `ingest`;
WhisperKit's 1.6–3.1 s before that is unchanged by any of this.

| Pace | Fast path | Excerpt cards (n, median, max) | Haiku cards (n, median, p90) | Haiku calls/min |
|---|---|---|---|---|
| Fast | off | – | 9, 3.70 s, 4.42 s | 5.0 |
| Fast | on | 3, 0.32 s, 0.60 s | 7, 3.59 s, 3.75 s | 5.0 |
| Balanced | off | – | 8, 3.77 s, 7.56 s | 2.8 |
| Balanced | on | 2, 0.34 s, 0.40 s | 7, 7.56 s, 7.61 s | 2.8 |
| Relaxed | off | – | 3, 10.69 s, 104.7 s max | 0.6 |
| Relaxed | on | 2, 0.38 s, 0.43 s | 2, 5.70 s, 10.61 s max | 0.6 |

Reading it:

- An excerpt, when the documents answer the question, shows in about a third
  of a second on every pace; on Relaxed that is a question that would
  otherwise wait 10 s to 100 s. Zero fast-path failures across the six runs
  (a first attempt with six replays plus an eval sharing one Mac did hit the
  700 ms budget three times in a row, which is why three failures now pause
  the path for a minute instead of the rest of the call).
- Only 2–3 of the 15 flagged questions were document questions ("what are my
  obligations to HMRC?"); the rest were conversational ("What then? Am I
  stuck?") and correctly got no excerpt. The share of document questions on
  a call bounds what the fast path can do.
- Haiku's own timing is stand-in dominated (2.5 s fixed) and the question
  floor's gain over the old 5 s floor was not isolated by this replay; the
  harness exists for that comparison when a stub with the old constants is
  worth the run. Calls per minute stayed at the pace caps.
- The stand-in answers one question per pass, so several questions in one
  window go "unanswered" by it; the real model emits up to two cards per
  pass and behaves similarly.

### Live run: two synthetic voices through the speakers (2026-09-19)

A 15-line scripted sales call (ElevenLabs voices, prospect and salesperson)
was played through the Mac's speakers into the installed app, Sales
discovery profile, Copilot on Claude, TypeSafe key present, Deepgram
transcription selected (its "Them" socket failed at the start and the app
fell back to on-device Whisper, see below). Times are wall clock from the
moment the spoken line ended, read from the app's public copilot log
(`log show --info --predicate 'subsystem == "com.uygar.parrot" AND category == "copilot"'`).

| Prospect line | transcript line lands | "From your docs" excerpt | first Claude card |
|---|---|---|---|
| How much does it cost to set one up? | 1.8 s | 2.2 s | 9.0 s |
| Is the Companies House fee included? | 2.1 s | 2.5 s | 6.5 s |
| Do I need to come to the UK? | 1.5 s | 1.9 s | – |
| How long does formation take? | 2.2 s | 2.5 s | 6.5 s |
| What is identity verification, how much is express? | 1.5 s | none (fixed by the stop-word change, hits at 0.94 offline) | 7.6 s |
| Can you guarantee a Stripe account? | 1.4 s | 1.8 s | 6.5 s |
| Can we do Friday at three? (not in the documents) | 1.6 s | none, correctly | 20.5 s (next step card) |

So the excerpt shows about 0.4 s after the transcript line, 1.8 to 2.5 s
after the prospect stops talking, and Claude's grounded card 6 to 9 s after.
Two of the excerpts were later replaced by Claude's cards citing the same
document; the rest stayed because Claude produced no card for that question.
Claude's replies quoted the right prices and the £100 fee from the document.

Seen along the way: the Deepgram "Them" stream failed around 15 s into both
runs (the key is valid and the "Me" socket kept working). Deepgram closes a
stream that carries no audio for about 10 s, and the failure reason was
hidden behind a redacted NSLog. The streamer now sends a KeepAlive every
5 s and logs the close code and reason publicly. The mic also produced junk
"Me" lines from speaker bleed, which headphones avoid; that is the known AEC
residual, not the copilot.

Follow-up from the live run: the 8-line window Haiku searched with was full
of mic-bleed small talk and buried the pricing chunk, so Haiku improvised
"£X per month". The live pass now searches the other side's latest question
first (two references) and fills from the window; with the reserved
embedding slots the pricing FAQ chunk reaches both Jev and Haiku for that
question (0.98).

### The user's own test call (2026-09-23 10:16, Groq transcription)

Eight prospect questions role-played through the speakers, Sales discovery
profile. What the store and the copilot log showed, and what changed:

- The excerpt for "As a Turkish founder, can I use your services?" came in
  0.4 s and stood for 43 s until Claude's grounded card on the same question
  replaced it, right after the question was repeated; two pricing cards then
  pushed that card out of the hero slot within 6 s. The replacement rule
  now requires a topic match as well as grounding, because with one big
  knowledge-base file every grounded card "cites the same document".
- Groq heard "Launchese" as "long cheese" and "Lone Cheese". The Settings
  vocabulary was never sent to Groq (only the on-device engine used it); the
  live chunks and the post-call polish now send it as Groq's `prompt`.
- "Cheapest package" retrieved the "Legacy names and old prices, never
  quote" section and Claude quoted £199 and "Starter". The document says
  "plans" where prospects say "packages"; a synonym hack helped one phrasing
  and hurt the other, so the fix is a line in the document ("cheapest
  package: LaunchPad at $11.99 plus the £100 fee").
- The repeated question arrived split ("as a Turkish founder," / "Can I use
  your services?"), and the second half alone scored 0.32. A short question
  now borrows the previous line from the other side for the document search
  (0.92 with it).
- The mic side was speaker bleed hallucinated by Groq ("Gracias", "Shh",
  "Продолжение следует"), and the coaching report scolded the user for it.
  Headphones. The on-device phrase filter cannot catch real words either.
- The copilot log is now notice level so it survives more than an hour.
