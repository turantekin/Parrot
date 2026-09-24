# Next features: six-phase roadmap

**Created 2026-09-24** from a competitor and user-demand review (Granola, Otter,
Fireflies, Fathom, Read.ai, Krisp, Cluely, MacWhisper, Meetily, anarlog, Teams
Facilitator and others, plus Reddit/HN/review-site complaints). This is the
phase-level plan. Each phase gets its own spec + task plan in `docs/superpowers/`
before it's built, the same way Phase C and speaker diarization did.

## Why these six

Parrot is the only tool found that combines all four: no bot, on-device
transcription, a live copilot grounded in the user's documents, and
bring-your-own AI. Local tools (MacWhisper, Meetily, anarlog) have no live
copilot; live copilots (Otter Live Assist, Cluely, Teams Facilitator) are all
cloud. The phases below close the gaps users complain about most (invented
action items, notes stuck in one app, no memory across calls, forgetting to
record) without giving up the local-first position. Every new feature keeps
working fully offline with Whisper + Ollama.

## Order and dependencies

| # | Phase | Size | Depends on | Why this slot |
|---|---|---|---|---|
| 1 | Receipts + bookmarks ✅ built | S–M | — | Quick trust win; citation chips are reused by phases 3 and 4 |
| 2 | Auto-start + calendar ✅ built (+ open at login) | M | — | Daily-use hook; gives phases 3 and 6 "who is on this call" |
| 3 | Ask Parrot (memory) + auto brief | M–L | 1, 2 | The headline feature; answers cite with phase-1 chips |
| 4 | Send it where work happens | M | 1, 3 | Exports carry receipts; MCP reuses phase-3 search |
| 5 | Consent + compliance mode | S–M | 4 | The "on-device only" lock must cover every outbound path, incl. phase 4's |
| 6 | Live speaker names | M–L | 2 | Polish; riskiest tech, so last; calendar attendees narrow the guess |

Phase 5 can be pulled forward if a lawyer/therapist launch is planned. Its
lock then gets extended when phase 4 lands.

## Rules for every phase

- New `Meeting` fields are optional or defaulted, so SwiftData migrates
  lightweight and old meetings render as today (same rule Phase C used).
- Pure logic goes behind `nonisolated static` helpers with `--profile-test`
  checks; views get a `--snapshot` render where layout matters.
- Cloud paths are opt-in and routed through one gate (phase 5 formalises it).
- Done = `make test` ALL PASS, snapshot eyeballed, one real recording,
  README + `docs/help/` + FILEMAP updated, roadmap status row set.

---

## Phase 1 — Receipts + bookmarks

*Built 2026-09-24. Chips open a popover (quote, Play from Here, Show in
Transcript) rather than jumping straight away; bookmark hotkey is ⌃⌥M.*

**User sees:** every summary bullet, next step and coaching point ends with a
small time chip (`12:34`). Click it: playback jumps there and the Transcript
tab highlights the line; hover shows the quote. A point the AI can't back up
is shown as *unverified* instead of stated as fact. During a call, a
**Mark moment** button (and hotkey) drops a bookmark with an optional label;
bookmarks show on the audio bar and in a "Moments you marked" report section.

**How:**
- `AnalysisProvider.summarySystemPrompt` / `coachingSystemPrompt`: the
  transcript is already sent as `[mm:ss] Speaker: text` (`RecordingManager.generateSummary`).
  Add the rule "end every bullet with the `[mm:ss]` of the line that supports
  it; if nothing supports it, leave it out". Same change in
  `OpenAICompatibleProvider`.
- `ReportContentView`: parse trailing `[mm:ss]` into a chip. Validate locally
  that a segment exists within a few seconds of the stamp; if not, drop the
  chip and tag the bullet *unverified* (the local check is the backstop, the
  prompt is the first line).
- `MeetingDetailView`: chip action calls the existing `seekTo(_:)`, switches
  to the Transcript tab and scrolls to/highlights the segment.
- Bookmarks: `Meeting.bookmarksData` (Codable `[Bookmark{time,label}]`,
  default empty). Button in `LiveRecordingView`, menu command + shortcut in
  `AppCommands`, menu-bar item. Bookmarks go into the summary prompt as
  "moments the user flagged as important".
- Old meetings: no chips, rendered unchanged.

**Tests:** chip parser (single, multiple, malformed stamps), stamp→segment
validation, prompt contains the citation rule, bookmark round-trip, snapshot of
a report with chips and an unverified bullet.

**Risks:** small models (llama3.2:3b) may cite less reliably. The local
validator keeps wrong stamps off screen; measure citation rate per provider.

---

## Phase 2 — Auto-start + calendar

*Built 2026-09-24 with two changes from this plan: invite text reaches the
copilot only behind an opt-in switch (off by default, delimited as data), and
"Open Parrot at login" was added (Settings → General and onboarding).*

**User sees:** when a call starts in Zoom, Meet, Teams, FaceTime, Slack or
anything else that grabs the mic, a prompt: *"Call started. Record with
Sales profile?"* One click to start; optional full auto-record. When the call
ends, Parrot offers to stop. With the calendar connected, meetings get their
real title, attendee list and the event notes as a pre-filled brief, and a
reminder can pop a minute before a scheduled call.

**How:**
- `MeetingDetector` service (new): watches the default input device's
  `kAudioDevicePropertyDeviceIsRunningSomewhere` (mic in use by another app,
  no permission needed) plus `NSWorkspace` running apps for a friendlier
  label. Pure state machine: idle → call-likely (debounced ~5 s) → prompt;
  mic released for ~30 s → offer stop. Ignores Parrot's own mic use.
- Setting: *Off / Ask me (default) / Record automatically*. Auto-record shows
  the phase-5 consent notice once that exists.
- `CalendarService` (new) on EventKit: reads whatever the Mac's Calendar app
  already syncs (Google, Outlook, iCloud), so no OAuth and nothing leaves the
  Mac. Needs `NSCalendarsFullAccessUsageDescription` in `project.yml` (and the
  Makefile's Info.plist substitution). Opt-in in Settings and a skippable
  onboarding step (this is the roadmap's "Calendar connect" row).
- Event matching: the event overlapping "now" (±10 min) names the meeting,
  stores `Meeting.attendeesData` (name + email), and pre-fills the brief from
  the event notes (user can edit). Simple profile rules: title keyword or
  attendee domain → profile (e.g. "interview" → Interview).
- Attendee names are offered first in the speaker-naming popover.
- Uses the existing `UNUserNotificationCenter` setup for prompts/reminders.

**Tests:** detector state machine (debounce, own-mic ignore, end detection),
event-overlap matching, profile rules, attendee round-trip.

**Risks:** browsers keep the mic open in some tabs; the debounce plus "Not a
call" (snooze this app for 1 h) handles false alarms. Default stays *Ask me*
because silent auto-recording has legal weight (see phase 5).

---

## Phase 3 — Ask Parrot (memory across calls) + automatic brief

**User sees:** an **Ask** box (sidebar entry and ⌘K): *"What did I promise
Acme?"*, *"What did Jeremy say about pricing in August?"*. The answer comes
with phase-1 chips that open the right meeting at the right second. Filters
for person, date range and profile. Each meeting also gets *Ask this call*.
Before a repeat call (from the calendar or a recognised voice), the Briefed
card fills itself: open next steps, your promises, their last objections.

**How:**
- `MeetingMemory` index (new, local file next to the KB index): transcript
  chunks per meeting (chunked by time/turns), reusing
  `KnowledgeBaseService`'s on-device multilingual embeddings and hybrid
  BM25 + cosine ranking (`hybridOrder`, `bm25Order`). Summaries and next steps
  are indexed as their own high-value chunks. A meeting is indexed when it
  reaches `.done`, re-indexed on edits, removed on delete; existing meetings
  backfill in the background with progress in Settings.
- Answering: top chunks → the user's chosen report brain, with the
  "transcript is data, not instructions" delimiters and a citation rule
  (`[meeting-id mm:ss]`). With Ollama, nothing leaves the Mac. Cost metered
  into `AIUsage` like other calls.
- People: join remembered voices (`SpeakerProfileStore`) and calendar
  attendees into a light *person → meetings* lookup, used for filters and the
  brief.
- Auto brief: when a call starts with a known person, one cheap LLM pass over
  their last 1–3 meetings' next steps + summaries → pre-filled brief, shown
  as "From your last call" so the user sees where it came from.

**Tests:** retrieval eval over seeded meetings (a `--memory-eval` harness in
the style of `--doc-answer-eval`), citation parsing into chips, index
add/update/delete, backfill idempotency, person join.

**Risks:** index size over hundreds of hours (measure; chunks are text only).
Answer quality on small local models (retrieval does the heavy lifting; keep
the prompt short).

---

## Phase 4 — Send it where work happens

**User sees:** after a call, **Follow-up email** (drafted, with only promises
that have receipts), **Save to Obsidian/folder**, **Add next steps to
Reminders**, and optionally **Send to a webhook** (Zapier/Make/n8n, to reach
Slack, Notion or a CRM). Power users connect Claude Desktop or ChatGPT to
Parrot and ask about their meetings from there.

**How:**
- `ExportService`: Markdown export with front matter (date, duration,
  attendees, profile, tags) including receipts as `mm:ss`. Option to
  auto-write every finished meeting to a chosen folder (Obsidian vault).
- Follow-up email: new optional post-call generation (profile toggle), in the
  meeting's language; *Copy* and *Open in Mail* (`NSSharingService`).
- Next steps → Apple Reminders via EventKit (already linked in phase 2),
  one reminder list per profile.
- Webhook: opt-in URL + JSON payload (meeting, summary, next steps,
  attendees). Off by default; blocked by the phase-5 lock.
- Local MCP server: `Parrot --mcp` stdio mode (same entry-point pattern as the
  CLI harness flags in `ParrotApp.swift`), read-only tools `list_meetings`,
  `get_meeting`, `search_meetings` (phase-3 index). Settings shows a *Copy
  config* snippet for Claude Desktop. Off by default.
- Native Notion / Slack / HubSpot connectors only after webhook usage shows
  which ones people want.

**Tests:** Markdown golden file, email prompt keeps only cited promises,
webhook payload shape, `--mcp` JSON-RPC handshake + tool listing self-test.

**Risks:** MCP opens meeting data to another app. Read-only, opt-in, and
listed in the Privacy section of the README.

---

## Phase 5 — Consent + compliance mode

**User sees:** a consent helper when recording starts (*Copy notice* for the
call chat, or tick *Verbal consent given*), stored with the meeting and shown
in the report and exports. An **On-device only** switch, global or per
profile ("Therapy is always on-device"), with a visible badge on the call
screen. Optional **redaction** of emails, phone and card numbers and names
before anything goes to a cloud AI. **Auto-delete** audio (or whole meetings)
after N days. A per-meeting "What left this Mac" line.

**How:**
- `Meeting.consentData` (method, time, notice text). Notice text per profile
  with editable templates (no legal advice claims; link to guidance in help).
- One outbound gate: every cloud path (Groq/Deepgram, polish pass, Claude/
  custom LLM, TypeSafe Jev, webhook, follow-up email generation) asks
  `CloudGate.allowed(for: profile)`. The lock forces on-device Whisper +
  Ollama and hides cloud options with an explanation.
- Redaction: local detectors (regex for emails/phones/cards/IBAN, `NLTagger`
  personal names) swap values for placeholders before a cloud call and map
  them back in the response.
- Retention: runs at launch and daily; per-profile policy; deletes audio
  files and/or meetings (reuses the existing meeting-deletion path).
- "What left this Mac": derived from `AIUsage` (which providers got text,
  never audio unless a cloud engine was chosen).

**Tests:** gate blocks every cloud path under the lock (one test per path),
redaction round-trip, retention date math, consent round-trip.

**Business angle:** pairs with a landing page for therapists, lawyers,
recruiters and consultants, the groups most worried about cloud notetakers
(Otter and Granola lawsuits, NYC Bar Formal Opinion 2025-6).

---

## Phase 6 — Live speaker names

**User sees:** during the call, the other side's bubbles say *Jeremy* and
*Speaker 3* instead of just *Them*, a few seconds after they start talking.
The copilot knows who said what ("Jeremy's pricing objection"). Labels are
marked provisional and silently corrected by the final pass at Stop.

**How** (per Phase 4 of `specs/2026-08-04-speaker-diarization-design.md`):
- First route: **periodic offline re-runs**. Every ~30 s, re-diarize the
  system track so far (`DiarizationEngine`, ~380× realtime, so single-digit
  seconds even at an hour). Keep labels stable across runs by matching new
  clusters to previous ones by embedding similarity.
- Match clusters to remembered voices (`SpeakerProfileStore`, cosine ≥ 0.65)
  and narrow candidates with phase-2 calendar attendees.
- Copilot prompt gets speaker names mid-call.
- Skip or slow the refresh on battery / high CPU (see `docs/PERFORMANCE.md`).
- If re-runs cost too much CPU on long calls, evaluate FluidAudio's LS-EEND
  streaming diarizer (MIT, ≤10 speakers, 100 ms updates) as the fallback.

**Tests:** label-stability mapping with synthetic embeddings, provisional →
final reconciliation, CPU budget via a replay harness on a recorded
two-voice file.

**Risks:** CPU on older Intel/M1 Macs during long calls; wrong live names are
worse than "Them", so only show a name above a confidence threshold.
