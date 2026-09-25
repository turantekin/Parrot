# Onboarding: Meet Copilot, and Private / Balanced / Cloud paths

Design spec, 2026-09-25. Agreed with Uygar in a brainstorming session with a
clickable mockup. Implementation not started.

## Problem

First-run onboarding (`OnboardingView`, 5 steps: Welcome → Permissions →
Choose a Model → Make it automatic → Ready) never mentions Copilot.
`copilotEnabled` defaults to `false` and `copilotProvider` to `claude`, so a
new user who never opens Settings never learns Parrot's headline feature
exists, and nobody is told that the private route needs the Ollama app.

## Goals

- Every new user sees what Copilot does and chooses how it runs.
- Three clear paths: **Private** (all on this Mac), **Balanced** (speech on
  this Mac, text to Claude), **Cloud** (Deepgram live text plus Claude).
- Downloads never block the user; they carry on after the window closes.
- "Decide later" is a real option with an easy way back.
- Ollama installs from inside Parrot, no browser trip.

## Non-goals

- TipKit tips in the main window (phase 2, separate spec).
- Running an LLM inside Parrot with no Ollama (MLX / Apple Foundation
  Models). Roadmap item; would remove the Ollama step later.
- Changing Permissions or "Make it automatic" beyond layout.
- Migrating existing users. They keep `hasCompletedOnboarding = true`; the
  Home Copilot card (below) reaches them if Copilot is off.

## The flow

```
Welcome → Permissions → Meet Copilot → How should Copilot work?
   Private:   → Speech model → Set up Copilot (Ollama)
   Balanced:  → Speech model → Set up Copilot (Claude key)
   Cloud:     → Set up Copilot (Claude + Deepgram keys)
   Decide later: → Speech model
→ Make it automatic → Ready
```

7 or 8 screens depending on path. New screens: Meet Copilot, How should
Copilot work?, Set up Copilot (three variants).

**Short tour** ("Set up Copilot" from Home or Settings):
`Meet Copilot → How should Copilot work? → Set up Copilot → Ready`.
No Decide later link there; Welcome, Permissions, Speech model and
Automatic are skipped.

## Window

The sheet grows from 500×600 to **600×680** so the new screens fit with
larger type. Every step must fit without scrolling; the snapshot harness
catches clipping (see Testing).

## Screens

### Welcome (copy change only)
"Meet Parrot. Records your calls, writes everything down, and helps you
live while you talk."

### Permissions
Unchanged.

### Meet Copilot (new)
- Title "Meet Copilot", line "Your helper during calls. It listens and
  shows you what to say, as it happens."
- Left: a looping sample call built from the real `CopilotPanelView` card
  views fed with sample data (not an image): the other side asks "Where is
  our data stored?", a Suggested answer card appears citing
  `security-faq.pdf`, then a pinned Blocker ("Budget isn't approved until
  Q3") while the call score rises. Same content as `docs/help/img/copilot.png`
  so the promise matches the first real call.
- Right: four benefits, icon plus one line each:
  - Know what to say: answers pop up when they ask, from your own documents.
  - Catch deal-breakers: blockers stay pinned until you handle them.
  - See how it's going: a live score and one line of coaching.
  - Leave with a report: summary, action items and a follow-up email.
- Footer strip: "Only you see it. No bot joins your call."
- Respects Reduce Motion: shows the final frame, no loop.

### How should Copilot work? (new)
Three selectable cards plus a text link:

| Card | Line |
|---|---|
| Private | Copilot runs on this Mac. Nothing leaves it. Free. Uses the Ollama app. |
| Balanced (badge: Recommended) | Audio stays on this Mac. Only text goes to Claude. Smartest answers. Needs a Claude key. |
| Cloud | Live word-by-word text plus Claude. Needs Deepgram and Claude keys. |

"Decide later" link under the cards. Continue with nothing picked shows
"Pick one to continue" and does not advance.

If on-device only (`CloudGate.globalKey`) is on, Balanced and Cloud are
greyed with "Turned off by On-device only in Settings → Privacy".

### Speech model (Private, Balanced, Decide later)
Today's picker, restyled:
- One line: "Your Mac has N GB of memory, so we picked:" and a
  "Best for your Mac" badge. Rule from `ProcessInfo.physicalMemory`:
  under 12 GB → Base; 12 GB or more → Large V3 Turbo.
- Show Base, Large V3 Turbo Compressed, Large V3 Turbo; "Show all 5
  models" expands to include Tiny and Small.
- Download starts when the step appears (preselected model), not on a
  button. Progress row: "Downloading speech model… 41%. You can keep going.
  It carries on after this window closes."

### Set up Copilot (new, three variants)
Every variant opens with the **Copilot card**: accent-bordered, sparkles
icon, "Copilot", one line on how it runs, and an On/Off switch (on by
default). The switch is the user's consent; it maps to `copilotEnabled`
as described under Settings written.

**Private (Ollama).** Three rows, each turns green on its own (poll every
1.5 s, like the permission rows):
1. Install Ollama (see "Installing Ollama").
2. Open Ollama (installed but server not answering).
3. Download model. Choice under the rows: gemma3:4b (recommended, 3.3 GB)
   or llama3.2:3b (2 GB). Progress row: "Keep going. Copilot turns on by
   itself when it's done."

If the Ollama server already answers on `localhost:11434` (any install
method, including Homebrew CLI), rows 1–2 show green immediately.
Link under row 1: "Or download it from ollama.com".

**Balanced (Claude).** Claude key field with a Check key button. Hint:
"Get a key at console.anthropic.com. Saved in your macOS keychain." Line:
"Claude also writes your after-call reports."

**Cloud (Claude + Deepgram).** Claude key field, then Deepgram key field
marked optional with "New accounts get $200 free credit." Below: the
backup speech model row (Base), "Downloading backup speech model…".

Key checks (new, one tiny request each, only when the button is pressed):
- Claude: `GET https://api.anthropic.com/v1/models` with the key.
- Deepgram: `GET https://api.deepgram.com/v1/projects` with the key.
- Results: "Key works" / "That key didn't work. Check it and try again." /
  "Couldn't reach <service>. Check your internet." Empty field: "Paste a key
  first". A key is saved to the Keychain only after it passes.

### Make it automatic
Unchanged content, restyled to the larger window.

### Ready
- Copilot card first, reflecting real state:
  - On, running on this Mac (model name). Nothing leaves your Mac.
  - On, using Claude. Only text is sent.
  - Turns on when gemma3:4b finishes (62%).
  - Almost there / Needs a working Claude key: "Finish from the card on Home."
  - Off for now (Decide later): "Set it up any time from the card on Home."
- Then: permissions row, speech model row (ready, or downloading N%),
  Deepgram row on Cloud.
- Line: "Downloads keep going after you close this."
- Button: "Let's start" (full tour) or "Done" (short tour).

## Settings written per path

| Setting | Private | Balanced | Cloud | Decide later |
|---|---|---|---|---|
| `copilotProvider` | `ollama` | `claude` | `claude` | untouched |
| `copilotOllamaModel` | chosen | untouched | untouched | untouched |
| `transcriptionBackend` | `local` | `local` | `deepgram` if its key passed, else `local` | `local` |
| `whisperModel` | chosen | chosen | `base` (backup) | chosen |
| `copilotEnabled` | switch value, applied when the Ollama model is ready | switch value if Claude key passed, else `false` | same as Balanced | `false` |
| `onboardingCopilotPath` (new) | `private` | `balanced` | `cloud` | `later` |

`reportsProvider` stays empty, so reports follow the live Copilot provider.
Private never turns on `CloudGate` (the strict lock stays a separate choice
in Settings → Privacy); adding a Claude key later then works as expected.

Why Cloud needs a Whisper model: `RecordingManager.start` requires
`transcriptionEngine.isReady` for every backend, and Deepgram falls back to
on-device Whisper when its socket fails.

## Decide later, and coming back

- **Copilot card on Home** (`DashboardView`), shown when Copilot is off or
  its setup is unfinished:
  - Off: "Turn on Copilot", one line of value, a sample suggestion, button
    "Set up Copilot", note "Takes about 2 minutes", close ✕.
  - Unfinished: "Finish setting up Copilot" with the reason (Ollama not
    set up / Claude key missing or failed).
  - Model downloading: "Copilot turns on when gemma3:4b finishes" plus a
    progress bar. No close button.
  - Close ✕ hides it for good (`copilotCardDismissed`). Existing users with
    Copilot off see it once too.
- **Settings → Copilot** gets the same "Set up Copilot" button at the top
  of the Live Call Copilot card. Always there, even after ✕.
- Both open the short tour: `MeetingActions.showCopilotSetup()` sets a
  `onboardingMode = copilot` key, then presents the same sheet as
  `showWelcomeTour()`.
- Help → Show Welcome Tour and Settings → General keep replaying the full
  tour. The General row's detail changes to "The first-run tour:
  permissions, Copilot and speech model."

## Downloads

### Speech model
Already owned by `TranscriptionEngine` (app lifetime), so it survives the
sheet closing. Changes:
- Replace the fixed 300 s timeout on `WhisperKit.download` with a stall
  timeout: fail only if progress hasn't moved for 60 s. At 300 s total,
  the 1.6 GB turbo model fails on connections slower than about 5 MB/s.
  The 300 s limit on `WhisperKit(config)` (loading, not downloading) stays.
- Record button while the model isn't ready: "Getting ready… 41%",
  inactive, instead of throwing `modelNotReady` on press.
- Toolbar pill while downloading: "Speech model 41%". On failure it becomes
  "Download failed. Retry".
- Quit mid-download: on next launch, resume the load of the selected model.
  Needs a test to confirm whether WhisperKit resumes partial files or starts
  over; either is acceptable, silently doing nothing is not.

### Ollama model
Today the pull lives in `OllamaModelStatusView`'s `@State`; when the view
goes away nobody can see progress and Settings offers a second pull.
Change: move pull and status into a new app-owned `OllamaService`
(`final class`, `@Observable`, owned by `RecordingManager` like
`transcriptionEngine`):
- `status`: serverDown / missing / pulling(progress) / ready / failed.
- `pull(model)`, `refresh()`, `installedModels()` (moved from the view).
- `OllamaModelStatusView` becomes a thin view over the service. Settings,
  onboarding, the Ready card, the Home card and the toolbar pill all read
  the same state.
- When a pull finishes and `onboardingCopilotPath == private` with the
  switch on: set `copilotEnabled = true` and show "Copilot is on" on the
  Home card.
- Quit mid-pull: on next launch, if the path is private and the model is
  still missing, pull again (Ollama keeps partial layers and resumes).
- Ollama quit mid-pull: status becomes failed with "Ollama stopped. Open it
  and retry".

## Installing Ollama (in-app)

Parrot is sandboxed (`Parrot.entitlements`: app-sandbox,
downloads.read-write, network.client). It can't write to /Applications;
it can write to Downloads and open apps.

Flow behind "Install Ollama (200 MB)":
1. Download `https://ollama.com/download/Ollama-darwin.zip` (~199 MB,
   verified live 2026-09-25) to `~/Downloads`, with progress.
2. Unzip with `/usr/bin/ditto -x -k` into `~/Downloads`.
3. Verify the code signature before launching: `SecStaticCodeCheckValidity`
   against a requirement pinning Ollama's Developer ID team. The team ID is
   read from a known-good copy (`codesign -dv`) during implementation and
   hard-coded. Mismatch → delete the download, show "That download didn't
   look right. Get it from ollama.com instead."
4. `NSWorkspace.shared.openApplication(at:)`. Files a sandboxed app writes
   are quarantined, so macOS shows its "downloaded from the Internet. Open?"
   prompt once. Row copy says so: "macOS will ask you to confirm once."
5. The row turns green when the server answers.

Things to confirm while building:
- Whether current Ollama offers to move itself to Applications on first
  launch. If not, tell the user "Move Ollama to Applications so it stays
  put" with a button that reveals it in Finder.
- That opening an app from Downloads works from the sandbox on macOS 14,
  15 and 26.

Any failure in steps 1–4 falls back to the ollama.com link with a one-line
reason. No retries in a loop.

## Code structure

| Unit | What it does | Depends on |
|---|---|---|
| `OnboardingView` (slimmed) | Window chrome, Back/Continue, dots, step routing | `OnboardingFlow` |
| `OnboardingFlow` (new, value type) | Ordered step list for a mode (full / copilot) and path; next/back; step saved by name | nothing |
| `OnboardingSteps/*.swift` (new) | One view per step: Welcome, Permissions, MeetCopilot, CopilotPath, SpeechModel, CopilotSetup (3 variants), Automatic, Ready | services below |
| `OllamaService` (new) | Server check, model pull with progress, in-app install | URLSession, Security, NSWorkspace |
| `ProviderKeyCheck` (new, enum) | One-request key checks for Claude and Deepgram | URLSession |
| `CopilotSetupCard` (new view) | Home and Settings card with its states | `OllamaService`, settings keys |

`OnboardingView.swift` is 340 lines today; with 3 new screens it would pass
800. Splitting per step keeps each file small. Existing pieces reused:
`PermissionRow`, `ModelOption`, `ProviderKeyField` (gains an optional
check-before-save), `APIKeyStore`, `SettingsView.open(_:with:)`, Copilot
card views for the demo, `Theme` for all colours and metrics.

**Saved step.** `onboardingStep` is an Int today; inserting steps would put
a user mid-onboarding during an update on the wrong screen. Store the step
by name (`onboardingStepName`), migrating the old Int once (0→welcome,
1→permissions, 2→speech, 3→automatic, 4→ready).

## Errors and edge cases

- No internet during a key check: "Couldn't reach Anthropic. Check your
  internet." The key is not saved; the user can Continue anyway, and
  Copilot stays off with the Home card explaining why.
- User switches path after entering a key: the key stays in the Keychain;
  only the settings for the new path are written.
- User picks Private on an 8 GB Mac: recommend llama3.2:3b instead of
  gemma3:4b (same memory rule as the speech model).
- On-device only turned on: Balanced and Cloud greyed (see above).
- Short tour on a Mac where Ollama is already set up: rows start green.

## Testing

- `make test` (`--profile-test`) gains checks for: `OnboardingFlow` step
  order for every mode×path, Back from the first path step, Int→name step
  migration, the memory → model recommendation rule, settings written per
  path (table above), and the stall timeout (progress stops 60 s → fails;
  slow but moving → doesn't).
- Snapshot harness: new shots at 600×680 for Meet Copilot (final frame),
  How should Copilot work?, each Set up Copilot variant, Ready (each Copilot
  state) and the Home Copilot card. Replaces the stale 4-dot
  `onboarding-*.png`.
- Real app, from the signed `dist/Parrot.app`, onboarding reset:
  1. Private on a Mac without Ollama: install in-app, macOS prompt, model
     pull, close the sheet mid-pull, Copilot turns on by itself.
  2. Balanced with a bad key, then a good key.
  3. Cloud with Deepgram, record a short call.
  4. Decide later → Home card → short tour.
  5. Quit mid speech-model download, relaunch, download resumes.

## Docs

`docs/help/getting-started.html` and `copilot-setup.html` rewritten for the
new flow with new screenshots (via the release-docs skill at release).
`FILEMAP.md` updated for the new files.

## Out of scope, noted for later

- TipKit phase 2: tips in the main window after the first recording.
- In-app LLM (MLX, or Apple Foundation Models on macOS 26) replacing Ollama.
- Groq as a Cloud option in onboarding (stays in Settings).
