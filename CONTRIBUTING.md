# Contributing to Parrot

First: there's no formal process here. Open an issue, open a PR, or just say hi — we'll figure it out together. This file is only the 60-second orientation so you don't have to reverse-engineer the repo.

## Build & test

```bash
make run    # build + assemble dist/Parrot.app + launch
make test   # headless logic harness (300+ checks), run this before a PR
```

Build with `make`, not Xcode's UI — Xcode's explicit-modules build intermittently races on WhisperKit's dependencies (`make` uses plain `swift build`). If you want the IDE, `make xcode` regenerates the project from `project.yml`; never hand-edit the `.xcodeproj`.

Dependencies are pinned in the committed `Package.resolved`, so every clone builds the same versions. Don't commit a changed `Package.resolved` by accident. Bumping is a deliberate PR of its own: `swift package update`, then `make test` and launch the app.

`make signing-help` explains how to stop macOS permissions resetting between builds.

## Finding your way

- [FILEMAP.md](FILEMAP.md) — one line per source file; grep the map, not the tree
- [AGENTS.md](AGENTS.md) — layout and conventions (also read by coding agents)

## What a good PR looks like here

- `make test` passes. If you're fixing logic, add a check to `ProfileTest.swift` — there is no XCTest target, on purpose.
- UI changes are verified with the snapshot harnesses (`--snapshot`, `--copilot-snapshot`, `--sidebar-snapshot`), in light *and* dark.
- New files go through `project.yml` (then `make xcode`), plus a line in `FILEMAP.md`.
- No key material anywhere — API keys live in the Keychain, never in code, logs, or commits.

## Issues and questions

- Bugs and ideas: the ladybug inside the app (or **Help → Report a Bug…**) pre-fills everything. Or pick a form at [New issue](https://github.com/turantekin/Parrot/issues/new/choose).
- Questions: [Discussions → Q&A](https://github.com/turantekin/Parrot/discussions/categories/q-a). More in [SUPPORT.md](SUPPORT.md).
- Security or privacy problems go privately, see [SECURITY.md](SECURITY.md).

## Ground rules

- **Local-first is the product.** Anything that sends data off-device must be opt-in and labelled with exactly what it sends.
- PRs get read line by line, usually within a few days. AI-assisted contributions are welcome — this project is built that way too — but you're responsible for what you submit.
- Be kind. The [Code of Conduct](CODE_OF_CONDUCT.md) applies everywhere in the project.
