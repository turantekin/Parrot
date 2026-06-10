# 🦜 Parrot

**A free, private, on-device meeting recorder for macOS.**

Parrot sits quietly on your Mac and records your Google Meet, Zoom, or any other meeting — transcribing everything in real-time, completely locally. No cloud. No API costs. No data leaving your machine. Just you and your Mac.

---

## Hey! 👋

So here's the deal — I'm Uygar, and I'm trying to build my own meeting recorder from scratch. I got tired of paying for services like Otter.ai that send all my conversations to some server I don't control. I thought, "How hard can it be to do this locally on my Mac?" Turns out... it's a journey. 😄

I'm building this with the help of [Claude](https://claude.ai) (yes, the AI — we've had a lot of late-night coding sessions together), and honestly, it's been one of the most fun projects I've worked on. It's not perfect yet — there are still bugs I'm chasing, permissions that are being annoying, and features I haven't figured out. But the core works: it captures audio, transcribes in real-time using WhisperKit, and keeps everything on your machine.

**This is a personal project. I'm learning as I go.** I'm sharing it publicly because why not? If there are any crazy coders out there who stumble upon this and want to help improve it, I would really, truly appreciate it. Whether it's fixing a bug, improving the speaker detection, or just telling me I'm doing something wrong — all of it helps. Open a PR, open an issue, or just say hi. 🙌

If you find this useful or just think the idea is cool, give it a star. It'll make my day.

## What It Does

- **Records system audio + microphone** — Captures what everyone says in a meeting (via ScreenCaptureKit) plus your own voice
- **Real-time transcription** — Watch the transcript appear as people talk, powered by WhisperKit running on your Mac's Neural Engine
- **Live Call Copilot (new!)** — An always-on assistant that watches the conversation and suggests answers, flags blockers/objections, and captures action items in real time. Opt-in, powered by the Claude API (bring your own key) — transcript text goes to the API, audio never leaves your Mac
- **Speaker diarization** — Tries to figure out who said what (basic energy-based approach for now)
- **Searchable history** — All your meetings stored locally with full-text search
- **Export** — Save transcripts as TXT or SRT (subtitle format)
- **Menu bar extra** — Quick start/stop recording from the menu bar
- **Dark mode** — Because of course

## Tech Stack

| What | How |
|------|-----|
| UI | SwiftUI, native macOS (no Electron!) |
| Speech-to-Text | [WhisperKit](https://github.com/argmaxinc/WhisperKit) — on-device, runs on Neural Engine |
| System Audio | ScreenCaptureKit (no virtual audio drivers needed) |
| Microphone | AVAudioEngine |
| Storage | SwiftData + SQLite |
| Target | macOS 14.0+ (Sonoma and later) |

## Screenshots

*Coming soon — the app has a clean dashboard with a big red record button, a sidebar with your meeting history, and a live transcription view.*

## Getting Started

### Prerequisites
- macOS 14.0 (Sonoma) or later
- Xcode 15+
- A Mac with Apple Silicon (recommended) or Intel

### Build & Run

```bash
git clone https://github.com/turantekin/Parrot.git
cd Parrot
open Parrot.xcodeproj
```

Then hit **Run** in Xcode (or `Cmd+R`).

### Permissions

On first launch, Parrot will ask for:
1. **Screen Recording** — needed to capture system audio from meetings (it only records audio, never your screen content)
2. **Microphone** — to capture your voice

Grant both in **System Settings > Privacy & Security**. You may need to restart the app after granting Screen Recording permission (macOS requirement).

### Choose a Model

Parrot uses WhisperKit models for transcription. Pick one during onboarding:

| Model | Size | Speed | Accuracy |
|-------|------|-------|----------|
| tiny | ~40 MB | Fastest | Basic |
| base | ~140 MB | Fast | Good |
| small | ~460 MB | Moderate | Better |
| large-v3-turbo | ~1.5 GB | Slower | Best |

The model downloads automatically on first use. `base` is a good default.

### Enable the Live Call Copilot (optional)

The Copilot watches the live transcript during a recording and pushes suggested answers, blockers, and action items into a side panel — automatically, the whole call, no button pressing.

1. Get a Claude API key from [console.anthropic.com](https://console.anthropic.com)
2. Open **Settings → Copilot**, paste the key (stored in your keychain), and flip the toggle
3. Start a recording — the Copilot panel appears next to the live transcript

**Privacy note:** Copilot sends transcript *text* to Anthropic's API to generate suggestions. Your audio never leaves your Mac, and nothing is sent unless you enable the feature. It runs on Claude Haiku, so a full hour-long call costs only a few cents.

### Give the Copilot your knowledge (optional but powerful)

In **Settings → Knowledge** you can brief the copilot like you'd brief a new teammate:

- **Drop in documents** — pricing sheets, FAQs, playbooks (PDF/text/markdown). They're chunked and embedded **on this Mac** (Apple's NaturalLanguage framework — documents are never uploaded). When a question comes up on a call, the copilot grounds its suggested answer in the best-matching passages and cites the source on the card. Each document takes an optional note like *"use for pricing questions"*.
- **Coaching instructions** — standing guidance for every call: tone, style, behavior ("keep answers short and casual, always offer Good/Better/Best on price").
- **General-knowledge fallback** — choose whether the copilot may answer beyond your documents. Cards always show where an answer came from: your document's name or *"general knowledge"*.
- **Pre-call brief** — an optional one-liner on the dashboard before you hit record ("Call with Westfield PM about AC replacement") so the copilot has context from second one.

## Project Structure

```
Parrot/
  ParrotApp.swift              # App entry point
  Models/
    Meeting.swift              # Meeting data model (SwiftData)
    TranscriptSegment.swift    # Individual transcript segments
  Services/
    AudioCaptureManager.swift  # System audio + mic capture
    TranscriptionEngine.swift  # WhisperKit wrapper
    DiarizationEngine.swift    # Speaker identification
    RecordingManager.swift     # Orchestrates everything
    ExportService.swift        # TXT/SRT export
  Views/
    ContentView.swift          # Main navigation
    DashboardView.swift        # Landing page with record button
    LiveRecordingView.swift    # Active recording UI
    MeetingDetailView.swift    # Meeting playback + transcript
    SidebarView.swift          # Meeting list
    OnboardingView.swift       # First-launch wizard
    SettingsView.swift         # App preferences
    MenuBarView.swift          # Menu bar extra
```

## What's Next (My Wishlist)

Things I want to add but haven't figured out yet:

- [ ] **Real speaker diarization** — integrate [SpeakerKit](https://github.com/argmaxinc/argmax-oss-swift) so it actually knows who's talking
- [ ] **Meeting summaries & action items** — maybe a local LLM via MLX? No cloud, obviously
- [ ] **Calendar integration** — auto-name meetings based on what's on my calendar
- [ ] **Audio playback synced with transcript** — click a line, hear that moment
- [ ] **Keyword bookmarks** — mark important moments during a recording
- [ ] **Better waveform visualization** — the current one is... functional
- [ ] **A proper app icon** — currently using the system bird icon, which is fine but not *Parrot*
- [ ] **Notarize and distribute** — so people can run it without Xcode

If any of these excite you, jump in!

## Want to Help? 🙏

Seriously, if you're into Swift/macOS development, audio processing, or ML on-device — I'd love your help. I'm one person building this in my spare time with Claude as my coding buddy, and there's a lot I don't know yet.

Here's where I could really use a hand:

- **Speaker diarization** — The current approach is embarrassingly basic (it just alternates speakers based on silence gaps). If you know anything about CoreML, Pyannote, or voice fingerprinting, please help me make this actually work.
- **Screen Recording permission headaches** — macOS permissions are driving me a little crazy. If you've dealt with ScreenCaptureKit in sandboxed apps, I want to hear from you.
- **Bug fixes** — Found something broken? Open a PR, I'll review it quickly.
- **Feature ideas** — Open an issue and let's chat about it.
- **Just vibes** — Even if you just want to say "cool project" or "this is dumb, do it this way instead" — I'm all ears.

No formal process. No templates. Just open an issue or PR and we'll figure it out together.

## Known Issues (I'm Working on It)

- **Screen Recording permission is annoying** — When running from Xcode, the binary gets re-signed each build, which can invalidate the permission. If recording fails, remove Parrot from Screen Recording in System Settings, re-add it, and restart. I'm still figuring this one out.
- **WhisperKit model download needs internet** — Only on first run. After that, everything is offline.
- **Speaker diarization is... not great** — It basically alternates speakers when there's silence. I know. It's on my list.

## License

MIT — Use it, learn from it, improve it, do whatever you want with it.

---

*Built with SwiftUI, WhisperKit, and way too many late-night [Claude Code](https://claude.ai) sessions.* 🌙

*If you're reading this and you've also tried to build something stupid-ambitious as a personal project — I see you. Keep going.* 🦜
