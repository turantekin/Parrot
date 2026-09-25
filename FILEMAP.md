# File map

One line per source file, so you can find the right file without grepping the
tree. Line counts are rough — they flag which files are worth reading whole.

## Entry points & harnesses

| File | L | Purpose |
|---|---|---|
| `Parrot/ParrotApp.swift` | 178 | `@main`; parses CLI harness flags before the SwiftUI `App` starts |
| `Parrot/ProfileTest.swift` | 1750 | `--profile-test`: headless logic harness, ~540 checks |
| `Parrot/SnapshotTool.swift` | 954 | Offscreen PNG renderers + transcribe/analyze/capture harnesses |
| `Parrot/CopilotHarness.swift` | 326 | `--kb-add`, `--doc-answer-eval` (Jev precision/recall), `--copilot-replay` (question-to-card latency) |

## Models (SwiftData `@Model` + Codable values)

| File | L | Purpose |
|---|---|---|
| `Models/Meeting.swift` | 166 | `Meeting` record + `MeetingStatus` lifecycle + per-speaker names/embeddings |
| `Models/TranscriptSegment.swift` | 34 | One diarized, timestamped utterance |
| `Models/Insight.swift` | 65 | `CallInsight` (stored) and `Insight` (live value) |
| `Models/CallProfile.swift` | 92 | Per-call-type prompt config: kinds, sentiment gauges |
| `Models/KindStyle.swift` | 86 | Maps insight kinds to icon/color; `Color` helpers |
| `Models/KnowledgeBase.swift` | 54 | KB document/chunk/reference value types |
| `Models/AIUsage.swift` | 144 | Token accounting and per-model price table |
| `Models/SpeakerProfile.swift` | 30 | Remembered voice: name + running-mean embedding (opt-in, local) |
| `Models/Bookmark.swift` | 50 | A marked moment (time + label); merge window, prompt line |
| `Models/Consent.swift` | 45 | How the other side was told it's recorded; notice text |

## Services

| File | L | Purpose |
|---|---|---|
| `Services/RecordingManager.swift` | 1138 | Orchestrates a recording session end-to-end; the hub; "Still recording?" reminder; live speaker sweeps (stable/window mapping, power pacing) |
| `Services/AudioCaptureManager.swift` | 700 | System audio (tap on 15+, SCK on 14.x/rescue) + mic tap, buffer conversion |
| `Services/SystemAudioTap.swift` | 250 | Core Audio process tap: audio-only capture, no Screen Recording (macOS 15+) |
| `Services/EchoCanceller.swift` | 138 | Swift wrapper over vendored SpeexDSP AEC |
| `Services/TranscriptionEngine.swift` | 1157 | On-device WhisperKit; `AudioSource` routing; live preview decode; Silero voice gate before every decode |
| `Services/CloudTranscription.swift` | 392 | Opt-in Groq (batch) and Deepgram (streaming) backends + WAV encode |
| `Services/DiarizationEngine.swift` | 156 | FluidAudio pyannote diarization (CoreML): labels + per-speaker embeddings; whole file or a live 60 s tail |
| `Services/AnalysisProvider.swift` | 605 | `AnalysisProvider` protocol, request/result types, prompt building, **Keychain helpers** (~L575) |
| `Services/OpenAICompatibleProvider.swift` | 528 | OpenAI-shaped LLM client (incl. Ollama); provider switching |
| `Services/CallAnalysisEngine.swift` | 815 | Drives live Copilot passes; per-pace question floor; Jev fast path ("From your docs" excerpt) |
| `Services/JevDocMatcher.swift` | 175 | TypeSafe "Jev" client: one probability per KB chunk that it answers the question; same-issue verdicts for card dedup |
| `Services/KnowledgeBaseService.swift` | 532 | Ingests/chunks KB docs (heading-aware), on-device multilingual embeddings (re-embeds stale vectors), hybrid BM25 + embedding retrieval |
| `Services/ProfileStore.swift` | 111 | Persists and mutates `CallProfile`s |
| `Services/ProfilePresets.swift` | 170 | Built-in starter profiles (seven, incl. the buyer-side "Vendor call") |
| `Services/ExportService.swift` | 235 | Export: TXT, SRT, Markdown (front matter, next-step checklist instead of repeated sections) |
| `Services/PermissionFlow.swift` | 150 | System Audio (15+) / Screen Recording (14) + microphone grant flows |
| `Services/AppUpdater.swift` | 56 | Sparkle updater: daily signed appcast check, installs on quit |
| `Services/BugReport.swift` | 120 | Pre-filled GitHub issue: diagnostics, own-window screenshot, URL builder |
| `Services/SpeakerProfileStore.swift` | 85 | Voiceprint matching (cosine ≥ 0.65), narrowed to calendar invitees; remember/forget |
| `Services/Receipts.swift` | 175 | Report receipts: parse `[mm:ss]` stamps, verify against the transcript, commitment/placeholder rules |
| `Services/GlobalHotKey.swift` | 105 | Carbon system-wide shortcut (⌃⌥M mark), registered only while recording |
| `Services/CallDetector.swift` | 281 | Mic-in-use reading (Core Audio process list) + pure call start/end state machine, app names; ignores Siri, Parrot's own capture, dictation apps |
| `Services/CallWatcher.swift` | 356 | Polls the detector; Ask/Auto modes; notification actions + delegate; calendar reminders; `NotificationAccess` |
| `Services/CalendarService.swift` | 250 | EventKit read-only: current event match, notes cleaning, invite context, title → profile |
| `Services/LoginItem.swift` | 60 | "Open Parrot at login" via SMAppService.mainApp |
| `Services/MeetingMemory.swift` | 300 | Local index of finished meetings (chunks + on-device vectors, one file per meeting), hybrid search |
| `Services/AskEngine.swift` | 260 | Ask Parrot prompt/context, `[M2 12:34]` citation parsing + checks; LastCallBrief (previous meeting, open items) |
| `Services/RecordingManager+Memory.swift` | 110 | meetingFinished hook, memory sync, previous meeting, `ask()` |
| `Services/FollowUpEmail.swift` | 90 | Follow-up email prompt, subject/body split, open in Mail |
| `Services/Integrations.swift` | 230 | Apple Reminders, export folder (security-scoped bookmark), webhook (payload, HMAC, send) |
| `Services/RecordingManager+Integrations.swift` | 90 | After-call actions, follow-up drafting, next steps → Reminders |
| `Services/MCPServer.swift` | 260 | `--mcp`: read-only stdio MCP server (list/get/search meetings), opt-in, private meetings hidden |
| `Services/CloudGate.swift` | 60 | On-device-only switch: global or per-call holds; checked by every cloud path |
| `Services/Redactor.swift` | 200 | Hide emails/phones/cards/IBANs/names from cloud AI and restore them; request/result helpers |
| `Services/Retention.swift` | 55 | Automatic clean-up rules (audio / whole meetings after N days) |
| `Services/RecordingManager+Privacy.swift` | 100 | Consent recording, retention run, PrivacyLedger ("what left this Mac") |

## Views

| File | L | Purpose |
|---|---|---|
| `Views/ContentView.swift` | 190 | Root split view + empty state + corner bug button |
| `Views/SidebarView.swift` | 361 | Meeting list, rows, talk-ratio strip |
| `Views/DashboardView.swift` | 350 | Landing stats + recent meetings |
| `Views/LiveRecordingView.swift` | 549 | In-call screen: chat bubbles, mic level, side tabs |
| `Views/CopilotPanelView.swift` | 770 | Live insight cards, pinned blockers, suggested replies |
| `Views/BriefViews.swift` | 147 | Brief summary line, documents-in-play row, live "Briefed" card (dashboard + copilot panel) |
| `Views/SettingsCards.swift` | 187 | Settings building blocks: page, titled card, row, tag chip (the landing-page window look) |
| `Views/MeetingDetailView.swift` | 1250 | Post-call tabs: transcript, insights, report; receipts actions, bookmarks card/rows; speaker naming popover (+ invitee suggestions) |
| `Views/BugReportSheet.swift` | 150 | Bug/idea report form + the corner ladybug button |
| `Views/ReportContentView.swift` | 473 | Report section cards, talk-ratio bar, prose parser (incl. one-line local reports), receipt chips + popover |
| `Views/SentimentStripView.swift` | 60 | Sentiment gauge strip |
| `Views/SettingsView.swift` | 970 | All settings sections, provider keys, KB docs |
| `Views/ProfilesSettingsView.swift` | 720 | Call-profile editor: kinds, gauges, icon picker |
| `Views/OnboardingView.swift` | 340 | Permission walkthrough + model choice |
| `Views/ModelDownloadProgressView.swift` | 34 | Whisper model download progress bar |
| `Views/OllamaModelStatusView.swift` | 136 | Local model presence/pull status |
| `Views/AudioImport.swift` | 108 | Drag-drop / file import of existing audio |
| `Views/AppCommands.swift` | 253 | `AppSession`, menu commands, context menus, notifications |
| `Views/MenuBarView.swift` | 59 | Menu bar extra |
| `Views/Theme.swift` | 160 | Single source of colors, fonts, metrics |
| `Views/AutomationSettingsViews.swift` | 250 | Login item row, Call Detection + Calendar cards, detected-call banner |
| `Views/AskView.swift` | 250 | Ask Parrot sheet: question, cited answer chips, sources, privacy line |
| `Views/ConnectionsPrivacySettings.swift` | 260 | Settings → Connections (folder, email, webhook, MCP) and → Privacy (lock, redaction, consent, clean-up) |

## Build & non-source

| Path | Purpose |
|---|---|
| `Makefile` | Canonical build: `swift build` + manual `.app` assembly |
| `.github/workflows/ci.yml` | macOS CI: build, `--profile-test`, snapshot renders (artifact), ad-hoc `.app` assembly |
| `project.yml` | xcodegen input; `Parrot.xcodeproj` is generated from it |
| `Package.swift` | SwiftPM deps (WhisperKit, vendored CSpeexDSP) |
| `scripts/release.sh` | Release packaging; mirrors the Makefile's bundle step |
| `scripts/assemble-help.sh` | Builds the Apple Help Book into the .app from `docs/help/` (both builders call it) |
| `docs/help/` | User guide: one HTML set serving GitHub Pages AND the in-app Help menu |
| `Vendor/CSpeexDSP/` | Vendored C echo canceller — do not modify |
| `docs/IMPROVEMENT-ROADMAP.md` | Roadmap + build notes (incl. the Xcode race) |
| `docs/PERFORMANCE.md` | Performance findings |
| `docs/superpowers/` | Design specs and plans |
