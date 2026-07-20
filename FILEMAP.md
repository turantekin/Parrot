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
| `Models/Meeting.swift` | 122 | `Meeting` record + `MeetingStatus` lifecycle |
| `Models/TranscriptSegment.swift` | 34 | One diarized, timestamped utterance |
| `Models/Insight.swift` | 60 | `CallInsight` (stored) and `Insight` (live value) |
| `Models/CallProfile.swift` | 92 | Per-call-type prompt config: kinds, sentiment gauges |
| `Models/KindStyle.swift` | 84 | Maps insight kinds to icon/color; `Color` helpers |
| `Models/KnowledgeBase.swift` | 54 | KB document/chunk/reference value types |
| `Models/AIUsage.swift` | 131 | Token accounting and per-model price table |

## Services

| File | L | Purpose |
|---|---|---|
| `Services/RecordingManager.swift` | 623 | Orchestrates a recording session end-to-end; the hub |
| `Services/AudioCaptureManager.swift` | 616 | ScreenCaptureKit system audio + mic tap, buffer conversion |
| `Services/EchoCanceller.swift` | 138 | Swift wrapper over vendored SpeexDSP AEC |
| `Services/TranscriptionEngine.swift` | 550 | On-device WhisperKit; `AudioSource` routing |
| `Services/CloudTranscription.swift` | 355 | Opt-in Groq (batch) and Deepgram (streaming) backends + WAV encode |
| `Services/DiarizationEngine.swift` | 182 | Speaker attribution over transcript segments |
| `Services/AnalysisProvider.swift` | 605 | `AnalysisProvider` protocol, request/result types, prompt building, **Keychain helpers** (~L575) |
| `Services/OpenAICompatibleProvider.swift` | 528 | OpenAI-shaped LLM client (incl. Ollama); provider switching |
| `Services/CallAnalysisEngine.swift` | 350 | Drives live Copilot + post-call report analysis passes |
| `Services/KnowledgeBaseService.swift` | 251 | Ingests/chunks KB docs, retrieves context for prompts |
| `Services/ProfileStore.swift` | 101 | Persists and mutates `CallProfile`s |
| `Services/ProfilePresets.swift` | 141 | Built-in starter profiles |
| `Services/ExportService.swift` | 127 | Transcript/report export (Markdown, text) |
| `Services/PermissionFlow.swift` | 75 | Screen Recording + microphone grant checks |
| `Services/UpdateChecker.swift` | 103 | Daily GitHub release poll, feeds the update banner |

## Views

| File | L | Purpose |
|---|---|---|
| `Views/ContentView.swift` | 173 | Root split view + empty state |
| `Views/SidebarView.swift` | 361 | Meeting list, rows, talk-ratio strip |
| `Views/DashboardView.swift` | 329 | Landing stats + recent meetings |
| `Views/LiveRecordingView.swift` | 532 | In-call screen: chat bubbles, mic level, side tabs |
| `Views/CopilotPanelView.swift` | 729 | Live insight cards, pinned blockers, suggested replies |
| `Views/MeetingDetailView.swift` | 707 | Post-call tabs: transcript, insights, report |
| `Views/ReportContentView.swift` | 267 | Report section cards, talk-ratio bar, prose blocks |
| `Views/SentimentStripView.swift` | 60 | Sentiment gauge strip |
| `Views/SettingsView.swift` | 673 | All settings sections, provider keys, KB docs |
| `Views/ProfilesSettingsView.swift` | 689 | Call-profile editor: kinds, gauges, icon picker |
| `Views/OnboardingView.swift` | 340 | Permission walkthrough + model choice |
| `Views/OllamaModelStatusView.swift` | 136 | Local model presence/pull status |
| `Views/AudioImport.swift` | 108 | Drag-drop / file import of existing audio |
| `Views/AppCommands.swift` | 240 | `AppSession`, menu commands, context menus, notifications |
| `Views/MenuBarView.swift` | 59 | Menu bar extra |
| `Views/Theme.swift` | 151 | Single source of colors, fonts, metrics |

## Build & non-source

| Path | Purpose |
|---|---|
| `Makefile` | Canonical build: `swift build` + manual `.app` assembly |
| `project.yml` | xcodegen input; `Parrot.xcodeproj` is generated from it |
| `Package.swift` | SwiftPM deps (WhisperKit, vendored CSpeexDSP) |
| `scripts/release.sh` | Release packaging; mirrors the Makefile's bundle step |
| `Vendor/CSpeexDSP/` | Vendored C echo canceller — do not modify |
| `docs/IMPROVEMENT-ROADMAP.md` | Roadmap + build notes (incl. the Xcode race) |
| `docs/PERFORMANCE.md` | Performance findings |
| `docs/superpowers/` | Design specs and plans |
