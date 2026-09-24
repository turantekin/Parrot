# File map

One line per source file, so you can find the right file without grepping the
tree. Line counts are rough — they flag which files are worth reading whole.

## Entry points & harnesses

| File | L | Purpose |
|---|---|---|
| `Parrot/ParrotApp.swift` | 178 | `@main`; parses CLI harness flags before the SwiftUI `App` starts |
| `Parrot/ProfileTest.swift` | 1154 | `--profile-test`: headless logic harness, ~290 checks |
| `Parrot/SnapshotTool.swift` | 941 | Offscreen PNG renderers + transcribe/analyze/capture harnesses |
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

## Services

| File | L | Purpose |
|---|---|---|
| `Services/RecordingManager.swift` | 714 | Orchestrates a recording session end-to-end; the hub |
| `Services/AudioCaptureManager.swift` | 700 | System audio (tap on 15+, SCK on 14.x/rescue) + mic tap, buffer conversion |
| `Services/SystemAudioTap.swift` | 250 | Core Audio process tap: audio-only capture, no Screen Recording (macOS 15+) |
| `Services/EchoCanceller.swift` | 138 | Swift wrapper over vendored SpeexDSP AEC |
| `Services/TranscriptionEngine.swift` | 947 | On-device WhisperKit; `AudioSource` routing; live preview decode |
| `Services/CloudTranscription.swift` | 383 | Opt-in Groq (batch) and Deepgram (streaming) backends + WAV encode |
| `Services/DiarizationEngine.swift` | 105 | FluidAudio offline pyannote diarization (CoreML): labels + per-speaker embeddings |
| `Services/AnalysisProvider.swift` | 605 | `AnalysisProvider` protocol, request/result types, prompt building, **Keychain helpers** (~L575) |
| `Services/OpenAICompatibleProvider.swift` | 528 | OpenAI-shaped LLM client (incl. Ollama); provider switching |
| `Services/CallAnalysisEngine.swift` | 815 | Drives live Copilot passes; per-pace question floor; Jev fast path ("From your docs" excerpt) |
| `Services/JevDocMatcher.swift` | 175 | TypeSafe "Jev" client: one probability per KB chunk that it answers the question; same-issue verdicts for card dedup |
| `Services/KnowledgeBaseService.swift` | 403 | Ingests/chunks KB docs (heading-aware), hybrid BM25 + embedding retrieval |
| `Services/ProfileStore.swift` | 111 | Persists and mutates `CallProfile`s |
| `Services/ProfilePresets.swift` | 170 | Built-in starter profiles (seven, incl. the buyer-side "Vendor call") |
| `Services/ExportService.swift` | 127 | Transcript export: TXT (with notes, report, insights) and SRT subtitles |
| `Services/PermissionFlow.swift` | 150 | System Audio (15+) / Screen Recording (14) + microphone grant flows |
| `Services/AppUpdater.swift` | 56 | Sparkle updater: daily signed appcast check, installs on quit |
| `Services/BugReport.swift` | 120 | Pre-filled GitHub issue: diagnostics, own-window screenshot, URL builder |
| `Services/SpeakerProfileStore.swift` | 69 | Voiceprint matching (cosine ≥ 0.65), remember/forget for named voices |

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
| `Views/MeetingDetailView.swift` | 900 | Post-call tabs: transcript, insights, report; speaker naming popover + confirm card |
| `Views/BugReportSheet.swift` | 150 | Bug/idea report form + the corner ladybug button |
| `Views/ReportContentView.swift` | 267 | Report section cards, talk-ratio bar, prose blocks |
| `Views/SentimentStripView.swift` | 60 | Sentiment gauge strip |
| `Views/SettingsView.swift` | 970 | All settings sections, provider keys, KB docs |
| `Views/ProfilesSettingsView.swift` | 720 | Call-profile editor: kinds, gauges, icon picker |
| `Views/OnboardingView.swift` | 340 | Permission walkthrough + model choice |
| `Views/ModelDownloadProgressView.swift` | 34 | Whisper model download progress bar |
| `Views/OllamaModelStatusView.swift` | 136 | Local model presence/pull status |
| `Views/AudioImport.swift` | 108 | Drag-drop / file import of existing audio |
| `Views/AppCommands.swift` | 253 | `AppSession`, menu commands, context menus, notifications |
| `Views/MenuBarView.swift` | 59 | Menu bar extra |
| `Views/Theme.swift` | 158 | Single source of colors, fonts, metrics |

## Build & non-source

| Path | Purpose |
|---|---|
| `Makefile` | Canonical build: `swift build` + manual `.app` assembly |
| `project.yml` | xcodegen input; `Parrot.xcodeproj` is generated from it |
| `Package.swift` | SwiftPM deps (WhisperKit, vendored CSpeexDSP) |
| `scripts/release.sh` | Release packaging; mirrors the Makefile's bundle step |
| `scripts/assemble-help.sh` | Builds the Apple Help Book into the .app from `docs/help/` (both builders call it) |
| `docs/help/` | User guide: one HTML set serving GitHub Pages AND the in-app Help menu |
| `Vendor/CSpeexDSP/` | Vendored C echo canceller — do not modify |
| `docs/IMPROVEMENT-ROADMAP.md` | Roadmap + build notes (incl. the Xcode race) |
| `docs/PERFORMANCE.md` | Performance findings |
| `docs/superpowers/` | Design specs and plans |
