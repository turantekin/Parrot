# Live nudges and the tone timeline: design

Date: 2026-09-29. Status: **approved in brainstorming, not built.** Base:
`feat/profiles2-reports` (PR #84, Profiles 2.0) at `e1caa62`, because this
touches the report tab, the Meeting model and the Copilot response, all of
which PR #84 changes. Build on that branch, not master.

## 1. Problem

Parrot's Copilot reads the room from the words (gauges like "Frustration:
Calm → Upset", a coach line, a call score), but:

- Nothing tells you **in the moment** that something just happened, like
  "you said the price and they went silent". The coach line changes quietly
  inside a window you usually can't see during a call.
- The gauges are **overwritten** on every Copilot pass, so after the call
  there is no record of how the call went over time.

## 2. Decisions (with the user)

| Question | Choice |
|---|---|
| Where a live nudge shows | **Floating pill + the Copilot panel**: pill on top of every app, the same nudge also kept in the panel |
| After the call | **A tone timeline in the report**: talk bars, mood line, numbered moments you can play |
| Which nudges | The 9 in section 4 (5 base + 4 added in brainstorming) |
| Emotion from the voice | **Not in this spec.** Phase 2, separately: on-device, "Them" only, opt-in, external-call profiles only (EU AI Act, see section 9) |

Parakeet (second on-device transcription model) is a separate spec.

## 3. What the user sees

**During the call: the pill.** A small rounded bar, top centre of the screen
with the frontmost window (where the call usually is), floating over every app including a full-screen Zoom. Icon,
one line of text, ✕. It stays about 10 seconds (hover pauses the fade), then
fades. Clicking it brings Parrot forward on the live call. It never takes
keyboard focus from the call app.

**During the call: the Copilot panel.** The latest nudge sits as a tinted
banner above the coach line until dismissed or replaced by the next one.
When Parrot's live window is already frontmost, only the banner shows (no
pill on top of it).

**After the call: "How the call went".** A card at the top of the Report tab
(below the rewritten-report banner, above the report itself):

- Three tiles: **You talked** (percent), **Key moments** (count), and the
  profile's main gauge at the end (e.g. "Buying temp: Warm").
- **Talk bars**: one bar per minute, you vs. them, by seconds of speech.
- **Mood line**: the profile's main gauge over the call, from saved Copilot
  passes. "Main gauge" = the profile's first gauge that isn't `my_dominance`
  (that one is the talk bars already).
- **Numbered markers** under the chart, and the same numbers in a list below
  it: the nudges that fired, turning points (section 5), and the user's own
  Marks (bookmarks), each with a time and a **Play** button that seeks the
  existing audio player and transcript.

Without a Copilot there is no mood line, no mood-shift nudge and no turning
points; the bars, timing nudges and Marks still show. Imported audio files
(one mixed track, no "Me") get no card.

## 4. The nudges

All thresholds are starting values, kept as named constants and tuned with
the replay harness (section 8) on real calls. "You" and "them" come from the
two recorded tracks (`AudioSource.me` / `.them`), not from speaker detection.

| Kind | Fires when | Example text | Needs |
|---|---|---|---|
| Gone quiet | You finished a line and they've said nothing for more than 3× their median reply gap so far, and at least 6 s | They've gone quiet since you said "the price goes up in January" | timing |
| Long monologue | You've spoken 90 s with no line from them | You've been talking for 2 minutes. Check in? | timing |
| Talking over | You started while they were still speaking, 3 times within 5 min | You've talked over them 3 times. Let them finish | timing |
| Short answers | Their last 4 replies were each under 1.5 s of speech, after their earlier replies averaged 3× longer | Their answers are getting short. Ask an open question | timing |
| Speeding up | Your words per second over the last 60 s is 1.4× your median so far, after at least 5 min of your speech | You're talking faster than usual. Slow down | timing |
| Repeated point | 3 of their lines in the last 10 min are near-duplicates (on-device sentence embeddings, the ones the knowledge base uses) | They've said "it still doesn't work" 3 times. Acknowledge it | on-device embeddings |
| Mood shift | A profile gauge moves 25+ points between two Copilot passes | Frustration rose after "we can't do that date" | Copilot |
| Unanswered question | A question-type insight from them is still open 3 min after it appeared | They asked about the contract length 3 minutes ago. Not answered yet | Copilot |
| Wrap-up checklist | The Copilot says the call is wrapping up | Before you hang up: agree a next step. Contract length is still open | Copilot |

Short answers are measured in **seconds, not words**: Turkish packs a
sentence into one long word, so word counts would call every Turkish reply
short. Gone quiet compares against **their own** reply gap, so a slow
speaker doesn't trigger it on every answer.

**Wrap-up checklist** adds two booleans to the Copilot's existing JSON
response: `wrapping_up` and `next_step_agreed`. The pill lists up to three
things: open unanswered questions and open blockers the Copilot already
tracks, plus "agree a next step" when `next_step_agreed` is false. One extra
schema field, no extra AI call.

**Rules so it doesn't nag**

- Nothing in the first 2 minutes.
- At most one pill every 2 minutes; the same kind at most once every 5.
  Wrap-up checklist ignores the 2-minute gap (it's the last chance) but fires
  once per call.
- When several are due at once, the most useful wins (order: wrap-up,
  unanswered question, gone quiet, mood shift, talking over, repeated point,
  long monologue, short answers, speeding up). The rest are still saved for
  the timeline.
- One setting: **Live nudges** on/off, on by default, on the Copilot
  settings page. It works with or without a Copilot key.
- While Copilot is paused, no nudges.

## 5. Turning points (no AI)

A turning point is a gauge move of 25+ points between two consecutive saved
passes (the same test as the mood-shift nudge, so live and report agree).
Its text quotes **the last complete line before the move**:

> Buying temp moved toward Cold after "the price goes up in January"

Direction words come from the gauge's own low/high labels. This is worked
out on the Mac from saved data, so the report prompts (golden-tested in
PR #84) don't change and there is no extra AI call. It shows a quote rather
than the paraphrase in the brainstorm mockup ("after you offered a pilot"):
exact, and it can't invent a cause.

## 6. Data

Two JSON fields on `Meeting`, the same pattern as `bookmarksData`. Both
default to nil, so old stores migrate as they are (check with
`--store-upgrade-test` from PR #84):

- `nudgesData`: `[Nudge]`, where `Nudge` = `id`, `kind`, `time` (seconds
  into the call), `text`, `quote?`, `shown` (false = was due but lost to
  rate limiting; still on the timeline).
- `moodTimelineData`: `[MoodSnapshot]`, where `MoodSnapshot` = `time` and
  `values: [String: Int]` (gauge key → 0–100), one per Copilot pass.

Written once when the recording stops, like the Copilot insights are today.
A crash mid-call loses them; the transcript is recovered as today.

**One talk percentage everywhere.** Today there are three: characters
(live gauge, `CallAnalysisEngine.userTalkPercent`), words (report,
`Meeting.talkPercentMe` from PR #84) and now seconds (timeline). All three
should become **seconds of speech**, so the tile, the coaching bar and the
live gauge agree and Turkish isn't under-counted. This edits PR #84's
`talkPercentMe`, so it lands on top of that branch.

## 7. Architecture

- **`NudgeDetector`** (new, `Services/`): a plain struct with no UI and no
  audio. Input: finished lines (source, start, end, text), Copilot passes
  (gauges, open items, wrap-up flags), and the clock. Output: due nudges.
  Holds the thresholds and the rate limiter. Every rule is a small function,
  so each is tested alone.
- **`TranscriptionEngine` → `RecordingManager`**: already hands every
  finished line to the Copilot; it also hands it to the detector. The
  detector runs whether or not the Copilot is on.
- **`CallAnalysisEngine`**: after each pass, appends a `MoodSnapshot` and
  passes the gauges, open items and the two new flags to the detector.
- **`NudgePill`** (new, `Views/`): a non-activating floating panel
  (`NSPanel`, `.nonactivatingPanel`, level above normal windows, joins all
  spaces including full screen). Must be **excluded from screen capture**
  (`sharingType = .none`) so a user sharing their screen never shows the
  other side "they've gone quiet". Verify with a real Zoom and Meet screen
  share before the pill ships. If macOS doesn't honour it for some capture
  method, the pill does not ship on by default until the plan settles a
  fallback (for example banner only, with the pill as an opt-in).
- **Copilot panel banner**: a view in `CopilotPanelView` above the coach line.
- **`ToneTimelineCard`** (new, `Views/`): the report card. Pure view over
  `meeting.sortedSegments`, `nudges`, `moodTimeline` and `bookmarks`. The
  timeline maths (per-minute talk seconds, turning points) lives in a
  separate helper with no SwiftUI, so the harness can test it.

## 8. Testing

- `make test` (`--profile-test`): each nudge rule fires on a scripted
  timeline and stays quiet on a near-miss; the rate limiter; short answers
  on Turkish-length lines; turning point detection and its quote; talk
  seconds per minute; JSON round trip of both new fields; old store opens
  (`--store-upgrade-test`).
- **`--nudge-replay <meeting id>`** (new harness): runs the detector over a
  saved meeting's lines (and its saved passes, when present) and prints
  every nudge with its time and whether it would have been shown. Used to
  tune the thresholds on the owner's real calls before the pill ships.
- `--snapshot`: render the timeline card (with and without a mood line) and
  the pill for a visual check in light and dark.
- By hand: a real call with a screen share (pill hidden from the share),
  a full-screen Zoom (pill visible, focus stays in Zoom), Copilot paused (no
  nudges), and the setting off.

## 9. Privacy and law

Everything here is on the Mac except the Copilot, which is already an
opt-in AI the user chose. The nudges read **timing and words**, never
emotion from the voice. The EU AI Act bans inferring emotions from biometric
data (voice) at work (Art. 5(1)(f), since Feb 2025) and treats it as
high-risk for customers; text and timing are outside that definition. The
wording stays on what happened ("gone quiet", "answers are getting short"),
not what someone feels. Phase 2 (voice tone) needs its own spec and a legal
check before it ships to EU users.

## 10. Out of scope

Voice tone and laughter (phase 2); "someone's gone silent" in group calls
(needs live speaker labels); "open promise from last time" (needs knowing
who's on the call at the start); dead air, no-questions-from-you, brief goal
not covered and competitor mentioned (listed in brainstorming, not picked);
nudges in the MCP server and exports; Parakeet.
