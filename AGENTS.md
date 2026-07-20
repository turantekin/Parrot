# Parrot

macOS SwiftUI app (14.0+): records a call's system audio + mic, transcribes it
on-device with WhisperKit, and runs a live "Copilot" plus a post-call report
through a pluggable LLM provider. Local-first — cloud engines and Copilot are
opt-in and need the user's own API keys.

**Read [FILEMAP.md](FILEMAP.md) before searching the tree** — it maps every
source file to one line of purpose. Grep the map, not the codebase.

## Build & test

Use the Makefile, not Xcode. Xcode's explicit-modules build races on
WhisperKit's transitive deps; `swift build` is the reliable path.

```
make          # build + assemble dist/Parrot.app
make run      # build, assemble, launch
make test     # headless logic harness (~60 checks) via --profile-test
make clean
```

`Parrot.xcodeproj` is generated from `project.yml` — edit the yml and run
`make xcode`, never hand-edit the pbxproj. Info.plist keys are substituted at
bundle time by the Makefile, not by Xcode.

## Layout

- `Parrot/Models/` — SwiftData `@Model` types + plain Codable value types
- `Parrot/Services/` — audio, transcription, analysis, persistence, updates
- `Parrot/Views/` — SwiftUI views; `Theme.swift` holds all colors/fonts/metrics
- `Vendor/CSpeexDSP/` — vendored C echo canceller; do not modify
- `docs/` — roadmap, performance notes, design specs

## Conventions

- SwiftData for meetings/transcripts/insights; `@AppStorage` for settings;
  Keychain for API keys. Never log or commit key material.
- Services are `final class`, UI-agnostic, and injected into views — keep
  networking and audio out of view bodies.
- Style through `Theme.swift` and `Font`/`Color` extensions. No hardcoded hex
  or magic paddings in views.
- Cloud calls need an explicit user opt-in path; on-device stays the default.
- Test via the CLI harnesses in `SnapshotTool.swift` / `ProfileTest.swift`
  (`--profile-test`, `--snapshot`, `--copilot-snapshot`, `--sidebar-snapshot`,
  `--transcribe-test`, `--analyze-test`). There is no XCTest target.
