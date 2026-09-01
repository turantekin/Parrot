# File map

One line per source file, so you can find the right file without grepping the
tree. Line counts are rough — they flag which files are worth reading whole.

## Entry points & harnesses

| File | L | Purpose |
|---|---|---|
| `Parrot/ParrotApp.swift` | 112 | `@main`; parses CLI harness flags before the SwiftUI `App` starts |
| `Parrot/ProfileTest.swift` | 363 | `--profile-test`: headless logic harness, ~60 assertions |
| `Parrot/SnapshotTool.swift` | 522 | Offscreen PNG renderers + transcribe/analyze harnesses |

## Models (SwiftData `@Model` + Codable values)

| File | L | Purpose |
|---|---|---|
| `Models/Meeting.swift` | 166 | `Meeting` record + `MeetingStatus` lifecycle + per-speaker names/embeddings |
| `Models/TranscriptSegment.swift` | 34 | One diarized, timestamped utterance |
| `Models/Insight.swift` | 60 | `CallInsight` (stored) and `Insight` (live value) |
| `Models/CallProfile.swift` | 92 | Per-call-type prompt config: kinds, sentiment gauges |
| `Models/KindStyle.swift` | 84 | Maps insight kinds to icon/color; `Color` helpers |
| `Models/KnowledgeBase.swift` | 54 | KB document/chunk/reference value types |
| `Models/AIUsage.swift` | 131 | Token accounting and per-model price table |
| `Models/ProcessingMode.swift` | 140 | Per-feature Local / Hybrid / Cloud; same model rule everywhere |
| `Models/SpeakerProfile.swift` | 30 | Remembered voice: name + running-mean embedding (opt-in, local) |
| `Models/DictationNote.swift` | 24 | Saved dictation utterance for the sidebar list |

## Services

| File | L | Purpose |
|---|---|---|
| `Services/RecordingManager.swift` | 623 | Orchestrates a recording session end-to-end; the hub |
| `Services/AudioCaptureManager.swift` | 700 | System audio (tap on 15+, SCK on 14.x/rescue) + mic tap, buffer conversion |
| `Services/SystemAudioTap.swift` | 250 | Core Audio process tap: audio-only capture, no Screen Recording (macOS 15+) |
| `Services/EchoCanceller.swift` | 138 | Swift wrapper over vendored SpeexDSP AEC |
| `Services/TranscriptionEngine.swift` | 947 | On-device WhisperKit; `AudioSource` routing; live preview decode |
| `Services/CloudTranscription.swift` | 355 | Opt-in Groq (batch) and Deepgram (streaming) backends + WAV encode + ranged CAF |
| `Services/GeminiTranscription.swift` | 320 | Gemini 3.5 Transcribe Interactions client + hybrid window refiner |
| `Services/GeminiLive.swift` | 360 | Gemini Transcribe Live sockets + post-call Live Translate |
| `Services/TextRewriter.swift` | 241 | Local/cloud rewrite + clipboard helper (transforms, cloud translation) |
| `Services/LocalTextModel.swift` | 220 | In-process MLX translation; Local mode auto-loads and unloads |
| `Services/TranslationService.swift` | 280 | Translation store; Apple packs asked once before a call |
| `Services/HotkeyCenter.swift` | 200 | Carbon hotkeys: hold, hands-free, paste last, two transforms |
| `Services/DictationController.swift` | 200 | Hold / hands-free dictation → focused field or clipboard |
| `Services/FocusText.swift` | 70 | AX selected-text read/write + ⌘V fallback |
| `Services/TransformController.swift` | 70 | Local vs cloud rewrite; clipboard out; busy guard |
| `Services/DiarizationEngine.swift` | 105 | FluidAudio offline pyannote diarization (CoreML): labels + per-speaker embeddings |
| `Services/AnalysisProvider.swift` | 605 | `AnalysisProvider` protocol, request/result types, prompt building, **Keychain helpers** (~L575) |
| `Services/OpenAICompatibleProvider.swift` | 528 | OpenAI-shaped LLM client (incl. Ollama); provider switching |
| `Services/CallAnalysisEngine.swift` | 350 | Drives live Copilot + post-call report analysis passes |
| `Services/KnowledgeBaseService.swift` | 251 | Ingests/chunks KB docs, retrieves context for prompts |
| `Services/ProfileStore.swift` | 101 | Persists and mutates `CallProfile`s |
| `Services/ProfilePresets.swift` | 141 | Built-in starter profiles |
| `Services/ExportService.swift` | 127 | Transcript/report export (Markdown, text) |
| `Services/PermissionFlow.swift` | 150 | System Audio (15+) / Screen Recording (14) + microphone grant flows |
| `Services/UpdateChecker.swift` | 103 | Daily GitHub release poll, feeds the update banner |
| `Services/BugReport.swift` | 120 | Pre-filled GitHub issue: diagnostics, own-window screenshot, URL builder |
| `Services/SpeakerProfileStore.swift` | 66 | Voiceprint matching (cosine ≥ 0.7), remember/forget for named voices |

## Views

| File | L | Purpose |
|---|---|---|
| `Views/ContentView.swift` | 190 | Root split view + empty state + corner bug button |
| `Views/SidebarView.swift` | 361 | Meeting list, rows, talk-ratio strip |
| `Views/DashboardView.swift` | 329 | Landing stats + recent meetings |
| `Views/LiveRecordingView.swift` | 664 | In-call screen: chat bubbles, mic level, side tabs |
| `Views/CopilotPanelView.swift` | 729 | Live insight cards, pinned blockers, suggested replies |
| `Views/MeetingDetailView.swift` | 900 | Post-call tabs: report, translation, transcript, insights, notes |
| `Views/BugReportSheet.swift` | 150 | Bug/idea report form + the corner ladybug button |
| `Views/ReportContentView.swift` | 267 | Report section cards, talk-ratio bar, prose blocks |
| `Views/SentimentStripView.swift` | 60 | Sentiment gauge strip |
| `Views/SettingsView.swift` | 920 | Settings pages including Create (bar, auto-paste, key bindings) |
| `Views/ProfilesSettingsView.swift` | 689 | Call-profile editor: kinds, gauges, icon picker |
| `Views/OnboardingView.swift` | 340 | Permission walkthrough + model choice |
| `Views/OllamaModelStatusView.swift` | 136 | Local model presence/pull status |
| `Views/AudioImport.swift` | 108 | Drag-drop / file import of existing audio |
| `Views/AppCommands.swift` | 240 | `AppSession`, menu commands, context menus, notifications |
| `Views/MenuBarView.swift` | 59 | Menu bar extra |
| `Views/Theme.swift` | 151 | Single source of colors, fonts, metrics |
| `Views/DictationHUD.swift` | 220 | Wispr-style floating mic, HUD, hotkey chips |
| `Views/DictationListView.swift` | 80 | History of finished dictations |
| `Views/TransformsView.swift` | 120 | Manage built-in and custom rewrite presets |
| `Views/TranslateSetupView.swift` | 70 | Pre-call language picker for a translation recording |

## Build & non-source

| Path | Purpose |
|---|---|
| `Makefile` | Canonical build: `swift build` + manual `.app` assembly |
| `project.yml` | xcodegen input; `Parrot.xcodeproj` is generated from it |
| `Package.swift` | SwiftPM deps (WhisperKit, vendored CSpeexDSP) |
| `scripts/release.sh` | Release packaging; mirrors the Makefile's bundle step |
| `scripts/assemble-help.sh` | Builds the Apple Help Book into the .app from `docs/help/` (both builders call it) |
| `scripts/build-mlx-metallib.sh` | Compiles mlx-swift `mlx.metallib` — `swift build` never emits it |
| `docs/help/` | User guide: one HTML set serving GitHub Pages AND the in-app Help menu |
| `Vendor/CSpeexDSP/` | Vendored C echo canceller — do not modify |
| `docs/IMPROVEMENT-ROADMAP.md` | Roadmap + build notes (incl. the Xcode race) |
| `docs/PERFORMANCE.md` | Performance findings |
| `docs/superpowers/` | Design specs and plans |
