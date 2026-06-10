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
- WhisperKit transcription lag (segment cadence is ~2s chunks; adds up to ~2s
  ahead of the engine's numbers above)
- UI responsiveness of the insight panel during long calls (LazyVStack should
  keep this flat, but verify with Instruments on a 1-hour session)
