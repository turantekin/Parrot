# File map

One line per source file, so you can find the right file without grepping the
tree. Line counts are rough — they flag which files are worth reading whole.

## Entry points & harnesses

| File | L | Purpose |
|---|---|---|
| `Parrot/ParrotApp.swift` | 290 | `@main`; parses CLI harness flags before the SwiftUI `App` starts |
| `Parrot/ProfileTest.swift` | 5150 | `--profile-test`: headless logic harness, ~1760 checks |
| `Parrot/ProfileTest+Parakeet.swift` | 190 | `--profile-test` checks for Parakeet: language router, per-side probe, recommendation, rewind, imports |
| `Parrot/SnapshotTool.swift` | 1680 | Offscreen PNG renderers + transcribe/analyze/capture harnesses; `--language-test <audio> [model] [seconds]` runs the live language check on a saved track; `--echo-replay` scores a recorded call's Me lines with the echo gate; `--liveloop-test` takes `LIVELOOP_MIC` to feed both tracks; `ANALYZE_REPORT=all --analyze-test ollama <model>` writes every built-in report on a model and checks the sections came back; `--store-upgrade-test <file>` upgrades an older store copy (read-only like MCP, then with the Profiles 2.0 migration); `--ask-chat-test, --ask-real` runs a real multi-turn Ask Parrot chat against Claude or Ollama |
| `Parrot/CopilotHarness.swift` | 360 | `--kb-add`, `--doc-answer-eval` (Jev precision/recall), `--copilot-replay` (question-to-card latency; `--real` sends passes to real Claude Haiku and prints each card's call time) |
| `Parrot/ToneHarness.swift` | 200 | `--nudge-replay [id] [--store path]` (a saved call through the live nudge rules, on a copy of the store), `--tone-snapshot <png>` (report card, pill, banner; light + dark), `--pill-test [png]` (a real pill on screen, captured with ScreenCaptureKit to prove it's left out; `PILL_TEST_SHARED=1` is the control) |
| `Parrot/ProfileTest+Nudges.swift` | 298 | `--profile-test` checks for live nudges, the tone timeline and seconds-based talk share |
| `Parrot/ReportPDFHarness.swift` | 190 | `--report-pdf <out.pdf> [meeting id or row] [--store path]`: a meeting's Export PDF plus a PNG per page, on a copy of the store; no meeting = the demo call (investor pitch with a scorecard); `REPORT_PDF_PAPER=a4\|letter` |
| `Parrot/ProfileTest+ReportPDF.swift` | 50 | `--profile-test` checks for the Export PDF's HTML (sections, scorecards, escaping, nothing from the transcript or notes) |

## Models (SwiftData `@Model` + Codable values)

| File | L | Purpose |
|---|---|---|
| `Models/Meeting.swift` | 410 | `Meeting` record + `MeetingStatus` lifecycle + per-speaker names/embeddings; report template snapshot; the report a rewrite replaced (undo) |
| `Models/TranscriptSegment.swift` | 34 | One diarized, timestamped utterance |
| `Models/Insight.swift` | 65 | `CallInsight` (stored) and `Insight` (live value) |
| `Models/CallProfile.swift` | 180 | Per-call-type prompt config: kinds, sentiment gauges; report choice (classic / preset / custom), sharing ids, last 5 saved versions |
| `Models/KindStyle.swift` | 86 | Maps insight kinds to icon/color; `Color` helpers |
| `Models/KnowledgeBase.swift` | 151 | KB document/chunk/reference value types; `KBScope` (Use for: all / only / off), `KBFolder`, upgrade from tags |
| `Models/AIUsage.swift` | 144 | Token accounting and per-model price table |
| `Models/SpeakerProfile.swift` | 30 | Remembered voice: name + running-mean embedding (opt-in, local) |
| `Models/Bookmark.swift` | 50 | A marked moment (time + label); merge window, prompt line |
| `Models/Nudge.swift` | 65 | A live nudge (kind, time, text, shown or held) and the Copilot's mood timeline; JSON on `Meeting` |
| `Models/Consent.swift` | 45 | How the other side was told it's recorded; notice text |
| `Models/OnboardingFlow.swift` | 79 | Setup steps per mode and path, named-step migration, memory-based model picks |

## Services

| File | L | Purpose |
|---|---|---|
| `Services/RecordingManager.swift` | 1314 | Orchestrates a recording session end-to-end; the hub; `writeReport` (Write report on a saved meeting); "Still recording?" reminder; live speaker sweeps (stable/window mapping, power pacing) |
| `Services/AudioCaptureManager.swift` | 1031 | System audio (tap on 15+, SCK on 14.x/rescue) + mic tap, buffer conversion |
| `Services/SystemAudioTap.swift` | 294 | Core Audio process tap: audio-only capture, no Screen Recording (macOS 15+) |
| `Services/EchoCanceller.swift` | 152 | Swift wrapper over vendored SpeexDSP AEC; counts frames fed no reference for the alignment log |
| `Services/EchoGate.swift` | 151 | Pure: skips a Me clip whose loudness just follows the other side's (speaker echo), once the call shows the mic hears the speakers (over the last minute, or while they talk in the minute before the clip) |
| `Services/TranscriptionEngine.swift` | 1764 | On-device WhisperKit or Parakeet; `AudioSource` routing; per-side language check (holds a Parakeet side until known, recheck + rewind); lazy fallback Whisper; live preview decode; Silero voice gate before every decode |
| `Services/LanguageRouter.swift` | 142 | Pure: which engine each side of a Parakeet call uses (held, Parakeet, Whisper), recheck schedule; `LanguageProbe` gathers each side's first 10 s of speech |
| `Services/ParakeetTranscriber.swift` | 38 | Parakeet TDT 0.6B v3 via FluidAudio (25 European languages, ~0.5 GB): load, transcribe with a script hint |
| `Services/EngineRecommendation.swift` | 25 | The model a new install starts on: Parakeet only when every Mac language and past call fits its 25 |
| `Services/CloudTranscription.swift` | 392 | Opt-in Groq (batch) and Deepgram (streaming) backends + WAV encode |
| `Services/DiarizationEngine.swift` | 156 | FluidAudio pyannote diarization (CoreML): labels + per-speaker embeddings; whole file or a live 60 s tail |
| `Services/AnalysisProvider.swift` | 605 | `AnalysisProvider` protocol, request/result types, prompt building, **Keychain helpers** (~L575) |
| `Services/OpenAICompatibleProvider.swift` | 528 | OpenAI-shaped LLM client (incl. Ollama); provider switching |
| `Services/CallAnalysisEngine.swift` | 815 | Drives live Copilot passes; per-pace question floor; Jev fast path ("From your docs" excerpt) |
| `Services/JevDocMatcher.swift` | 175 | TypeSafe "Jev" client: one probability per KB chunk that it answers the question; same-issue verdicts for card dedup |
| `Services/KnowledgeBaseService.swift` | 660 | Ingests/chunks KB docs (heading-aware), on-device multilingual embeddings (re-embeds stale vectors), hybrid BM25 + embedding retrieval; folders and Use for, `isInPlay` (the one rule for what the Assistant may quote), index v2 upgrade + backup |
| `Services/ProfileStore.swift` | 300 | Persists and mutates `CallProfile`s; the one-time Profiles 2.0 migration (backup, sharing ids, restore point, report choice); import / apply / restore a `.parrotprofile` (privacy only tightens) |
| `Services/ProfilePresets.swift` | 300 | Built-in starter profiles (eight, incl. the buyer-side "Vendor call" and "Investor pitch") and their report templates |
| `Services/ExportService.swift` | 265 | Export: TXT, SRT, Markdown (front matter, next-step checklist instead of repeated sections); `Parts` limits what an AI app gets |
| `Services/ReportPDF.swift` | 470 | Export PDF for a team: header (date, length, who attended, call type), how the call went (tiles + SVG chart from ToneTimeline), report cards; pure HTML, paginated offscreen by WebKit's print engine (cards never split), footer and page numbers stamped after |
| `Services/PermissionFlow.swift` | 150 | System Audio (15+) / Screen Recording (14) + microphone grant flows |
| `Services/AppUpdater.swift` | 148 | Sparkle updater: daily signed appcast check, installs on quit; started at launch; as Sparkle's delegate posts "update waiting" (held during a call) with Restart now; `UpdateNotice` copy + rule |
| `Services/WhatsNew.swift` | 92 | What the release brings: the Home card after updating and Sparkle's update-window notes; copy rules; `--whats-new-html X.Y.Z` for release.sh |
| `Services/BugReport.swift` | 120 | Pre-filled GitHub issue: diagnostics, own-window screenshot, URL builder |
| `Services/SpeakerProfileStore.swift` | 85 | Voiceprint matching (cosine ≥ 0.65), narrowed to calendar invitees; remember/forget |
| `Services/Receipts.swift` | 180 | Report receipts: parse `[mm:ss]` stamps, verify against the transcript, commitment/placeholder rules (the meeting's template flags its own commitment sections) |
| `Services/GlobalHotKey.swift` | 100 | Carbon system-wide shortcut (⌃⌥M mark), registered only while recording |
| `Services/CallDetector.swift` | 281 | Mic-in-use reading (Core Audio process list) + pure call start/end state machine, app names; ignores Siri, Parrot's own capture, dictation apps |
| `Services/CallWatcher.swift` | 378 | Polls the detector; Ask/Auto modes; notification actions + delegate (also routes the update's Restart now); calendar reminders and the menu bar's next call; `NotificationAccess` |
| `Services/CalendarService.swift` | 347 | EventKit read-only: current event match, next call + its video link (menu bar), notes cleaning, invite context, title → profile |
| `Services/LoginItem.swift` | 60 | "Open Parrot at login" via SMAppService.mainApp |
| `Services/NudgeDetector.swift` | 293 | Pure rules for the nine live nudges (timing + Copilot passes) and the rate limiter; `Tuning` holds every threshold |
| `Services/LiveNudgeSession.swift` | 60 | One call's nudges: detector, mood snapshots, the nudge on screen; fed by RecordingManager |
| `Services/ToneTimeline.swift` | 147 | Report maths: talk seconds per minute, talk share, turning points, numbered moments |
| `Services/MeetingMemory.swift` | 300 | Local index of finished meetings (chunks + on-device vectors, one file per meeting), hybrid search (optionally one kind of passage) |
| `Services/AskChatStore.swift` | 170 | Ask Parrot's saved chats: AskMessage/AskChat values, one JSON file, rename/delete/stale sweep, titles, day groups |
| `Services/AskEngine.swift` | 260 | Ask Parrot prompt/context, `[M2 12:34]` citation parsing + checks; LastCallBrief (previous meeting, open items) |
| `Services/RecordingManager+Memory.swift` | 110 | meetingFinished hook, memory sync, previous meeting, `ask()` |
| `Services/FollowUpEmail.swift` | 90 | Follow-up email prompt, subject/body split, open in Mail |
| `Services/Integrations.swift` | 230 | Apple Reminders, export folder (security-scoped bookmark), webhook (payload, HMAC, send) |
| `Services/RecordingManager+Integrations.swift` | 90 | After-call actions, follow-up drafting, next steps → Reminders |
| `Services/RecordingManager+Rewrite.swift` | 90 | Rewrite a meeting's report with another profile (all or nothing, privacy only tightens) and its one-step undo |
| `Services/MCPServer.swift` | 330 | `--mcp`: read-only stdio MCP server (async loop; list/get/search meetings with meaning search and date/person filters, transcript pages, commitments, prompts, read-only annotations, export to Downloads/Parrot Exports, talk-time stats, read profiles, suggest_profile leaves a suggestion in the ProfileInbox; share settings via MCPAccess), opt-in, private meetings hidden |
| `Services/MCPCommitments.swift` | 55 | Pure: commitment bullets from a report, owner = speaker of the cited receipt line |
| `Services/MCPPrompts.swift` | 170 | Pure: the seven ready-made MCP prompts (weekly digest, follow-up email, call prep, PRD from calls, create / improve a profile, design a report) |
| `Services/ProfileFile.swift` | 230 | Pure: portable `.parrotprofile` JSON (encode a CallProfile incl. its report, decode with limits, unknown fields kept) |
| `Services/ProfileReview.swift` | 210 | What a `.parrotprofile` would change (review screen groups); `PendingProfile` (a file waiting for review, read capped); `ProfileInbox`, where AI apps' suggestions wait (max 10), and its watcher |
| `Services/ReportTemplate.swift` | 200 | Pure: a profile's report sections + coaching lens; `.standard` = the classic report; builds a custom template's prompt (scorecards + fairness rule); `Scorecard` reads scores back (receipt or no score) |
| `Services/MCPAccess.swift` | 110 | What AI apps may see (share checkboxes, excluded call types), the gate every MCP tool reads through, activity counters |
| `Services/MCPBundle.swift` | 150 | One-click connect: Claude Desktop `.mcpb` (manifest, launcher that finds a moved app, icon), Cursor link, Claude Code / Codex commands |
| `Services/ParrotLink.swift` | 45 | Open-in-Parrot links: AI apps get `openparrot.app/open#m=<id>&t=` (the site hands on to `openparrot://`), ParrotAppDelegate opens them, reopening the window if closed |
| `Services/CloudGate.swift` | 60 | On-device-only switch: global or per-call holds; checked by every cloud path |
| `Services/Redactor.swift` | 200 | Hide emails/phones/cards/IBANs/names from cloud AI and restore them; request/result helpers |
| `Services/Retention.swift` | 55 | Automatic clean-up rules (audio / whole meetings after N days) |
| `Services/RecordingManager+Privacy.swift` | 100 | Consent recording, retention run, PrivacyLedger ("what left this Mac") |
| `Services/CopilotSetupState.swift` | 91 | Settings each Copilot path writes, auto-enable when the Ollama model lands, Copilot status for Ready and Home |
| `Services/ProviderKeyCheck.swift` | 56 | One-request Claude and Deepgram key checks |
| `Services/OllamaService.swift` | 134 | App-wide Ollama server state and the one model pull; resumes at launch |
| `Services/OllamaInstaller.swift` | 133 | Downloads, unpacks, signature-checks and opens the official Ollama app |

## Views

| File | L | Purpose |
|---|---|---|
| `Views/ContentView.swift` | 260 | Root split view (`MainPage`: dashboard/settings/ask/aiApps/meeting) + empty state + corner bug button; shows the Profiles 2.0 screen once; profile review sheet + suggestion banner |
| `Views/SidebarView.swift` | 390 | Meeting list, rows, talk-ratio strip; search runs as one database query per pause in typing (never in `body`) |
| `Views/DashboardView.swift` | 420 | Landing stats (word count cached per meeting) + recent meetings |
| `Views/CopilotHomeCard.swift` | 110 | Home card: turn on Copilot, finish setup, waiting for the model, just turned on |
| `Views/WhatsNewCard.swift` | 39 | Home card once per version after an update: headline, highlights, Read the full story (changelog anchor), Got it |
| `Views/LiveRecordingView.swift` | 781 | In-call screen: chat bubbles, mic level, side tabs |
| `Views/CopilotPanelView.swift` | 770 | Live insight cards, pinned blockers, suggested replies |
| `Views/BriefViews.swift` | 147 | Brief summary line, documents-in-play row, live "Briefed" card (dashboard + copilot panel) |
| `Views/SettingsCards.swift` | 191 | Settings building blocks: page, titled card, row (optional header tint), tag chip (the landing-page window look) |
| `Views/KnowledgeSettingsView.swift` | 442 | Settings → Knowledge: folders, Use for pills and menu, About line, search, drag to move; `KnowledgeList` pure helpers |
| `Views/MeetingDetailView.swift` | 1634 | Post-call tabs: transcript, insights, report (Write report when there is none); receipts actions, bookmarks card/rows; speaker naming popover (+ invitee suggestions); `SortedLines` (cached time order + binary-search playing line) |
| `Views/BugReportSheet.swift` | 150 | Bug/idea report form + the corner ladybug button |
| `Views/ReportContentView.swift` | 550 | Report section cards, scorecard rows, talk-ratio bar, prose parser (incl. one-line local reports; knows the meeting's template titles), receipt chips + popover |
| `Views/SentimentStripView.swift` | 60 | Sentiment gauge strip |
| `Views/SettingsView.swift` | 900 | All settings sections and provider keys (Knowledge lives in `KnowledgeSettingsView`) |
| `Views/ProfilesSettingsView.swift` | 770 | Call-profile editor: kinds, gauges, icon picker; read-only list of documents a profile can use; hosts the Report card; Share / Export / Import (button + drop), Saved Versions (restore) |
| `Views/ProfileReportCard.swift` | 360 | Profile editor → Report: report choice menu, sections (title, what goes here, paragraph/bullets/scorecard + criteria, promises), coaching on/off + role + focus, the built-in report offer |
| `Views/ProfileReviewView.swift` | 250 | Review screen for imported files and AI suggestions (source, reason, grouped changes, privacy line, Apply / Save as new / Discard) + the suggestion banner |
| `Views/ProfileShareViews.swift` | 130 | `.parrotprofile` UTType, share-sheet export, Export sheet (what the file holds, its text, Save…), queuing imported files |
| `Views/RewriteReportSheet.swift` | 130 | Meeting page → Rewrite Report… sheet (pick a profile, progress, cancel) and the "Rewritten with…" Undo banner |
| `Views/ProfileMigrationView.swift` | 120 | One-time "Reports can now match each call type" screen after the Profiles 2.0 update: a switch per built-in, backup link |
| `Views/OnboardingView.swift` | 182 | Setup sheet shell: step routing, footer, 600×680; PermissionRow, ModelOption |
| `Views/Onboarding/OnboardingModel.swift` | 81 | Sheet state (mode, path, step, switch, key results); move/decide later/finish |
| `Views/Onboarding/OnboardingParts.swift` | 140 | Shared rows and cards: StepHeader, CopilotHeroCard, DownloadRow, PendingRow, SpeechDownloadRow |
| `Views/Onboarding/WelcomeStep.swift` | 22 | Welcome step |
| `Views/Onboarding/PermissionsStep.swift` | 120 | Permissions step |
| `Views/Onboarding/MeetCopilotStep.swift` | 111 | Meet Copilot step: example call + benefits |
| `Views/Onboarding/CopilotPathStep.swift` | 86 | Private / Balanced / Cloud / Decide later choice |
| `Views/Onboarding/SpeechModelStep.swift` | 82 | Speech model step (pick from languages, past calls and memory; starts download) |
| `Views/Onboarding/CopilotSetupStep.swift` | 164 | Copilot path setup: Ollama install/pull, Claude/Deepgram key fields |
| `Views/Onboarding/KeyCheckField.swift` | 83 | One provider key field + Check key button and result |
| `Views/Onboarding/AutomaticStep.swift` | 104 | In-progress step while a path finishes on its own |
| `Views/Onboarding/AIAppsStep.swift` | 110 | Claude/Cursor/Codex step before Ready (not on the Private path): honest "not private" note, Connect Claude |
| `Views/Onboarding/ReadyStep.swift` | 70 | Final "Ready" screen |
| `Views/ModelDownloadProgressView.swift` | 34 | Whisper model download progress bar |
| `Views/OllamaModelStatusView.swift` | 65 | Settings → Copilot model status, a thin view over OllamaService |
| `Views/AudioImport.swift` | 108 | Drag-drop / file import of existing audio |
| `Views/AppCommands.swift` | 319 | `AppSession`, menu commands, context menus, notifications |
| `Views/MenuBarView.swift` | 223 | Menu bar extra: words-heard line, next call (Join & Record), profile picker, last call (open/copy report), Ask, X follow/say hi; `MenuBarLabel` draws the parrot + call time + muted mic as one template image |
| `Views/Theme.swift` | 160 | Single source of colors, fonts, metrics |
| `Views/NudgePill.swift` | 156 | The floating nudge pill (non-activating panel, hidden from screen capture) and the Copilot panel's nudge banner |
| `Views/ToneTimelineCard.swift` | 193 | Report card "How the call went": talk bars, mood line, numbered moments with Play |
| `Views/AutomationSettingsViews.swift` | 250 | Login item row, Call Detection + Calendar cards, detected-call banner |
| `Views/AskPageView.swift` | ~330 | Ask Parrot page: saved-chat list, conversation, AI menu, Stop |
| `Views/AskAnswerView.swift` | ~130 | ParrotAvatar + AskAnswerView (answer lines, citation chips, sources) |
| `Views/ConnectionsPrivacySettings.swift` | 255 | Settings → Connections (folder, email, webhook, switch + link to Claude & AI Apps) and → Privacy (lock, redaction, consent, clean-up) |
| `Views/AIAppsPageView.swift` | 440 | Claude & AI Apps page (connect buttons, what apps see, six jobs, activity line), first-connection banner, meeting "Ask Claude" menu, weekly report tip; `AIApps` pure rules |

## Build & non-source

| Path | Purpose |
|---|---|
| `Makefile` | Canonical build: `swift build` + manual `.app` assembly |
| `.github/workflows/ci.yml` | macOS CI: build, `--profile-test`, snapshot renders (artifact), ad-hoc `.app` assembly |
| `project.yml` | xcodegen input; `Parrot.xcodeproj` is generated from it |
| `Package.swift` | SwiftPM deps (WhisperKit, vendored CSpeexDSP) |
| `scripts/release.sh` | Release packaging; mirrors the Makefile's bundle step; builds `Parrot.mcpb` and `server.json`; refuses a version `WhatsNew` doesn't describe and embeds its notes in the appcast |
| `scripts/assemble-help.sh` | Builds the Apple Help Book into the .app from `docs/help/` (both builders call it) |
| `integrations/claude-plugin/` | Claude plugin for the connector directory: `.mcp.json` + `server/launch.sh` (same launcher as the release `.mcpb`, harness-checked), seven skills mirroring the MCP prompts, README, PRIVACY |
| `server.json` | MCP Registry entry, written by `scripts/release.sh` per release (version, `.mcpb` URL, sha256) |
| `docs/help/` | User guide: one HTML set serving GitHub Pages AND the in-app Help menu |
| `Vendor/CSpeexDSP/` | Vendored C echo canceller — do not modify |
| `docs/IMPROVEMENT-ROADMAP.md` | Roadmap + build notes (incl. the Xcode race) |
| `docs/PERFORMANCE.md` | Performance findings |
| `docs/superpowers/` | Design specs and plans |
