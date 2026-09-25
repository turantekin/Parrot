# Onboarding: Meet Copilot and Private / Balanced / Cloud Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild Parrot's first-run sheet so every new user meets Copilot, picks Private / Balanced / Cloud, and gets it running (Ollama installed from inside the app, or Claude/Deepgram keys checked), with downloads that keep going in the background and a Home card to finish later.

**Architecture:** Pure logic first (step order, settings per path, Copilot status, key checks, stall timeout), each covered by checks in the `--profile-test` harness. Then two app-owned services (`OllamaService`, `OllamaInstaller`) held by `RecordingManager`, like `transcriptionEngine`, so progress survives the sheet closing. Then one SwiftUI file per step, wired by a small `OnboardingModel`, and finally the Home card and Settings entry points.

**Tech Stack:** Swift 5.10, SwiftUI (macOS 14+), SwiftData, `@Observable`, URLSession, Security framework (code-signature check), NSWorkspace. Build with the Makefile (`swift build` under the hood). No XCTest; checks live in `Parrot/ProfileTest.swift`.

**Spec:** `docs/superpowers/specs/2026-09-25-onboarding-copilot-paths-design.md`

## Global Constraints

- macOS 14.0 minimum (`Package.swift` platforms `.v14`). No APIs newer than 14 without `#available`.
- Build and test only with `make build` / `make test` (release config, binary at `.build/release/Parrot`). Never Xcode.
- Tests are `check("name", condition)` lines inside `enum ProfileTest` in `Parrot/ProfileTest.swift`; each new `static func testX()` must also be called from `ProfileTest.run()` (just above the `print(failures == 0 ? ...)` line). Mark a test `@MainActor` when it touches `@MainActor` types.
- Colours, fonts and metrics come from `Parrot/Views/Theme.swift` (`Theme.Colors.*`, `Theme.Typography.*`, `Theme.Metrics.*`). No hex values in views.
- Services are `final class`, UI-agnostic, injected via `RecordingManager`. No networking in view bodies.
- API keys only via `APIKeyStore` (Keychain). Never print or log a key.
- Cloud requests only after an explicit user action. `CloudGate.globalKey` ("On-device only") greys out Balanced and Cloud.
- UI copy: short, plain English, sentence case, exactly as written in this plan.
- Setup sheet size: 600×680. Every step must fit without scrolling.
- New `.swift` files anywhere under `Parrot/` are picked up by `Package.swift` automatically. Regenerate the Xcode project once at the end (`make xcode`).
- Each commit message ends with the line `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `Parrot/Models/OnboardingFlow.swift` | new | `OnboardingStep`, `CopilotPath`, `OnboardingMode`, step order, legacy step migration, `MachineFit` memory rules |
| `Parrot/Services/CopilotSetupState.swift` | new | `CopilotChoices`, `CopilotPathSettings` (settings per path, auto-enable), `CopilotStatus` (Ready + Home card state) |
| `Parrot/Services/ProviderKeyCheck.swift` | new | One-request key checks for Claude and Deepgram |
| `Parrot/Services/OllamaService.swift` | new | App-wide Ollama server/model state and the one model pull |
| `Parrot/Services/OllamaInstaller.swift` | new | Download, unpack, verify and open the official Ollama app |
| `Parrot/Services/TranscriptionEngine.swift` | modify | Stall timeout instead of a fixed 300 s on model download |
| `Parrot/Services/RecordingManager.swift` | modify | Own `ollama` and `ollamaInstaller`; resume a pending Ollama pull at launch |
| `Parrot/Views/OllamaModelStatusView.swift` | modify | Thin view over `OllamaService` |
| `Parrot/Views/Onboarding/OnboardingModel.swift` | new | Sheet state: mode, path, step, switch, key results; move/decide later/finish |
| `Parrot/Views/Onboarding/OnboardingParts.swift` | new | `StepHeader`, `CopilotHeroCard`, `DownloadRow`, `PendingRow`, `SpeechDownloadRow` |
| `Parrot/Views/Onboarding/WelcomeStep.swift` … `ReadyStep.swift` | new | One view per step (Welcome, Permissions, MeetCopilot, CopilotPath, SpeechModel, CopilotSetup, KeyCheckField, Automatic, Ready) |
| `Parrot/Views/OnboardingView.swift` | modify | Shell only: routing, footer, 600×680; keeps `PermissionRow` and `ModelOption` |
| `Parrot/Views/CopilotHomeCard.swift` | new | Home card: turn on / finish / waiting / just turned on |
| `Parrot/Views/DashboardView.swift` | modify | Show `CopilotHomeCard` under the record button |
| `Parrot/Views/SettingsView.swift` | modify | "Set up Copilot" row; welcome-tour copy; close Settings window on either |
| `Parrot/Views/AppCommands.swift` | modify | `showWelcomeTour()` writes step names; new `showCopilotSetup()` |
| `Parrot/SnapshotTool.swift` | modify | Help shots for every new screen and the Home card |
| `Parrot/ProfileTest.swift` | modify | New checks |
| `docs/help/getting-started.html`, `docs/help/copilot-setup.html`, `FILEMAP.md` | modify | Docs |

---

### Task 1: Step order, path, mode and memory rules

**Files:**
- Create: `Parrot/Models/OnboardingFlow.swift`
- Test: `Parrot/ProfileTest.swift` (new `testOnboardingFlow`)

**Interfaces:**
- Produces:
  - `enum OnboardingStep: String, CaseIterable { case welcome, permissions, meetCopilot, copilotPath, speechModel, copilotSetup, automatic, ready }`
  - `enum CopilotPath: String, CaseIterable { case private, balanced, cloud, later }` with `static let defaultsKey = "onboardingCopilotPath"`
  - `enum OnboardingMode: String { case full, copilot }` with `static let defaultsKey = "onboardingMode"`
  - `enum OnboardingFlow` with `stepKey = "onboardingStepName"`, `legacyStepKey = "onboardingStep"`, `steps(mode:path:) -> [OnboardingStep]`, `step(_ offset: Int, from: OnboardingStep, in: [OnboardingStep]) -> OnboardingStep`, `resolve(_:in:) -> OnboardingStep`, `migrateLegacyStep(in: UserDefaults)`
  - `enum MachineFit` with `memoryGB(_ bytes: UInt64 = physicalMemory) -> Int`, `whisperModel(memoryGB:) -> String`, `ollamaModel(memoryGB:) -> String`

- [ ] **Step 1: Write the failing test**

In `Parrot/ProfileTest.swift`, add `testOnboardingFlow()` to `run()` (after `testLiveLabelStability()`), and add this function before the final closing brace of `enum ProfileTest`:

```swift
    static func testOnboardingFlow() {
        let full = OnboardingFlow.steps(mode: .full, path: nil)
        check("onboarding: full tour, no path yet",
              full == [.welcome, .permissions, .meetCopilot, .copilotPath, .speechModel, .automatic, .ready])
        let privatePath = OnboardingFlow.steps(mode: .full, path: .private)
        check("onboarding: private adds setup after speech",
              privatePath == [.welcome, .permissions, .meetCopilot, .copilotPath, .speechModel, .copilotSetup, .automatic, .ready])
        check("onboarding: balanced matches private", OnboardingFlow.steps(mode: .full, path: .balanced) == privatePath)
        check("onboarding: cloud skips the speech step",
              OnboardingFlow.steps(mode: .full, path: .cloud) == [.welcome, .permissions, .meetCopilot, .copilotPath, .copilotSetup, .automatic, .ready])
        check("onboarding: later has no setup step", OnboardingFlow.steps(mode: .full, path: .later) == full)
        check("onboarding: short tour",
              OnboardingFlow.steps(mode: .copilot, path: .balanced) == [.meetCopilot, .copilotPath, .copilotSetup, .ready])
        check("onboarding: short tour before a pick",
              OnboardingFlow.steps(mode: .copilot, path: nil) == [.meetCopilot, .copilotPath, .ready])

        check("onboarding: next after the path choice", OnboardingFlow.step(1, from: .copilotPath, in: privatePath) == .speechModel)
        check("onboarding: back from setup", OnboardingFlow.step(-1, from: .copilotSetup, in: privatePath) == .speechModel)
        check("onboarding: clamps at the end", OnboardingFlow.step(1, from: .ready, in: privatePath) == .ready)
        check("onboarding: clamps at the start", OnboardingFlow.step(-1, from: .welcome, in: privatePath) == .welcome)
        check("onboarding: an orphan step lands on the path choice", OnboardingFlow.resolve(.copilotSetup, in: full) == .copilotPath)

        let suite = "parrot.test.onboardingFlow"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        d.set(1, forKey: OnboardingFlow.legacyStepKey)
        OnboardingFlow.migrateLegacyStep(in: d)
        check("onboarding: legacy 1 → permissions",
              d.string(forKey: OnboardingFlow.stepKey) == "permissions" && d.object(forKey: OnboardingFlow.legacyStepKey) == nil)
        d.removePersistentDomain(forName: suite)
        d.set(2, forKey: OnboardingFlow.legacyStepKey)
        OnboardingFlow.migrateLegacyStep(in: d)
        check("onboarding: legacy model step → meet copilot", d.string(forKey: OnboardingFlow.stepKey) == "meetCopilot")
        d.set("ready", forKey: OnboardingFlow.stepKey)
        d.set(0, forKey: OnboardingFlow.legacyStepKey)
        OnboardingFlow.migrateLegacyStep(in: d)
        check("onboarding: a saved name wins over the legacy index", d.string(forKey: OnboardingFlow.stepKey) == "ready")
        d.removePersistentDomain(forName: suite)

        check("fit: 8 GB → base + llama", MachineFit.whisperModel(memoryGB: 8) == "base" && MachineFit.ollamaModel(memoryGB: 8) == "llama3.2:3b")
        check("fit: 16 GB → turbo + gemma", MachineFit.whisperModel(memoryGB: 16) == "large-v3-turbo" && MachineFit.ollamaModel(memoryGB: 16) == "gemma3:4b")
        check("fit: bytes round to whole GB", MachineFit.memoryGB(17_179_869_184) == 16)
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `make test 2>&1 | tail -5`
Expected: build error `cannot find 'OnboardingFlow' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Parrot/Models/OnboardingFlow.swift`:

```swift
import Foundation

/// One screen of the setup sheet. Raw values are what `onboardingStepName`
/// stores, so renaming a case strands saved progress.
enum OnboardingStep: String, CaseIterable {
    case welcome, permissions, meetCopilot, copilotPath, speechModel, copilotSetup, automatic, ready
}

/// How Copilot runs, picked on "How should Copilot work?".
enum CopilotPath: String, CaseIterable {
    case `private`, balanced, cloud, later
    static let defaultsKey = "onboardingCopilotPath"
}

/// The full first-run tour, or the short "Set up Copilot" one from Home or
/// Settings.
enum OnboardingMode: String {
    case full, copilot
    static let defaultsKey = "onboardingMode"
}

enum OnboardingFlow {
    static let stepKey = "onboardingStepName"
    /// The old Int index (0 welcome … 4 ready), read once and removed.
    static let legacyStepKey = "onboardingStep"

    static func steps(mode: OnboardingMode, path: CopilotPath?) -> [OnboardingStep] {
        switch mode {
        case .copilot:
            let setup: [OnboardingStep] = (path == nil || path == .later) ? [] : [.copilotSetup]
            return [.meetCopilot, .copilotPath] + setup + [.ready]
        case .full:
            let middle: [OnboardingStep]
            switch path {
            case .private?, .balanced?: middle = [.speechModel, .copilotSetup]
            case .cloud?: middle = [.copilotSetup]
            case .later?, nil: middle = [.speechModel]
            }
            return [.welcome, .permissions, .meetCopilot, .copilotPath] + middle + [.automatic, .ready]
        }
    }

    /// The step `offset` away, clamped to the list.
    static func step(_ offset: Int, from step: OnboardingStep, in steps: [OnboardingStep]) -> OnboardingStep {
        let index = steps.firstIndex(of: resolve(step, in: steps))! + offset
        return steps[min(max(index, 0), steps.count - 1)]
    }

    /// A saved step that no longer belongs to the list (the path changed
    /// under it) lands on the path choice.
    static func resolve(_ step: OnboardingStep, in steps: [OnboardingStep]) -> OnboardingStep {
        if steps.contains(step) { return step }
        return steps.contains(.copilotPath) ? .copilotPath : steps[0]
    }

    /// Moves the old Int step to a name, once. Anyone past permissions lands
    /// on Meet Copilot, so nobody mid-tour during an update skips it.
    static func migrateLegacyStep(in defaults: UserDefaults) {
        guard defaults.string(forKey: stepKey) == nil,
              let old = defaults.object(forKey: legacyStepKey) as? Int else { return }
        let step: OnboardingStep = old <= 0 ? .welcome : old == 1 ? .permissions : .meetCopilot
        defaults.set(step.rawValue, forKey: stepKey)
        defaults.removeObject(forKey: legacyStepKey)
    }
}

/// Defaults that fit this Mac's memory.
enum MachineFit {
    static func memoryGB(_ bytes: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Int {
        Int((Double(bytes) / 1_073_741_824).rounded())
    }

    // ponytail: one threshold for both models; split it if a 12 GB Mac
    // proves too tight for turbo plus gemma together.
    private static func isLarge(_ memoryGB: Int) -> Bool { memoryGB >= 12 }

    static func whisperModel(memoryGB: Int) -> String { isLarge(memoryGB) ? "large-v3-turbo" : "base" }
    static func ollamaModel(memoryGB: Int) -> String { isLarge(memoryGB) ? "gemma3:4b" : "llama3.2:3b" }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `make test 2>&1 | grep -E "onboarding:|fit:|^FAIL|ALL PASS|FAILURES"`
Expected: every `onboarding:` and `fit:` line starts with `PASS`, last line `ALL PASS`.

- [ ] **Step 5: Commit**

```bash
git add Parrot/Models/OnboardingFlow.swift Parrot/ProfileTest.swift
git commit -m "Onboarding: step order per path, named steps, memory-based defaults

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Settings per path and Copilot status

**Files:**
- Create: `Parrot/Services/CopilotSetupState.swift`
- Test: `Parrot/ProfileTest.swift` (new `testCopilotSetupState`)

**Interfaces:**
- Consumes: `CopilotPath` (Task 1), `CopilotProviderKind` (`Services/OpenAICompatibleProvider.swift`), `TranscriptionBackend` (`Services/CloudTranscription.swift`)
- Produces:
  - `struct CopilotChoices { path: CopilotPath; ollamaModel: String; copilotSwitchOn: Bool; claudeKeyWorks: Bool; deepgramKeyWorks: Bool; ollamaModelReady: Bool }`
  - `enum CopilotPathSettings` with keys `enableWhenReadyKey = "copilotEnableWhenOllamaReady"`, `justTurnedOnKey = "copilotJustTurnedOn"`, `cardDismissedKey = "copilotCardDismissed"`; `apply(_: CopilotChoices, to: UserDefaults = .standard)`; `@discardableResult ollamaModelReady(in: UserDefaults = .standard) -> Bool`
  - `enum CopilotStatus: Equatable { case on, waitingForModel(progress: Double?), finishOllama, needsClaudeKey, off }` with `static func current(copilotEnabled:path:enableWhenReady:ollamaPulling:ollamaProgress:hasClaudeKey:) -> CopilotStatus` and `static func showsHomeCard(_:dismissed:justTurnedOn:) -> Bool`

- [ ] **Step 1: Write the failing test**

Add `testCopilotSetupState()` to `run()` and this function to `ProfileTest`:

```swift
    @MainActor
    static func testCopilotSetupState() {
        let suite = "parrot.test.copilotSetup"
        let d = UserDefaults(suiteName: suite)!
        func fresh() { d.removePersistentDomain(forName: suite) }
        func choices(_ path: CopilotPath, on: Bool = true, claude: Bool = false,
                     deepgram: Bool = false, ollamaReady: Bool = false) -> CopilotChoices {
            CopilotChoices(path: path, ollamaModel: "gemma3:4b", copilotSwitchOn: on, claudeKeyWorks: claude,
                           deepgramKeyWorks: deepgram, ollamaModelReady: ollamaReady)
        }
        let backendKey = TranscriptionBackend.defaultsKey

        fresh(); CopilotPathSettings.apply(choices(.private), to: d)
        check("setup: private uses Ollama and local speech",
              d.string(forKey: "copilotProvider") == "ollama" && d.string(forKey: "copilotOllamaModel") == "gemma3:4b"
              && d.string(forKey: backendKey) == "local")
        check("setup: private waits for the model",
              !d.bool(forKey: "copilotEnabled") && d.bool(forKey: CopilotPathSettings.enableWhenReadyKey))
        fresh(); CopilotPathSettings.apply(choices(.private, ollamaReady: true), to: d)
        check("setup: private with the model ready turns on now",
              d.bool(forKey: "copilotEnabled") && !d.bool(forKey: CopilotPathSettings.enableWhenReadyKey))
        fresh(); CopilotPathSettings.apply(choices(.private, on: false), to: d)
        check("setup: switch off means off, nothing pending",
              !d.bool(forKey: "copilotEnabled") && !d.bool(forKey: CopilotPathSettings.enableWhenReadyKey))
        fresh(); CopilotPathSettings.apply(choices(.balanced, claude: true), to: d)
        check("setup: balanced with a working key",
              d.string(forKey: "copilotProvider") == "claude" && d.bool(forKey: "copilotEnabled")
              && d.string(forKey: backendKey) == "local")
        fresh(); CopilotPathSettings.apply(choices(.balanced), to: d)
        check("setup: balanced without a key stays off", !d.bool(forKey: "copilotEnabled"))
        fresh(); CopilotPathSettings.apply(choices(.cloud, claude: true, deepgram: true), to: d)
        check("setup: cloud with Deepgram", d.string(forKey: backendKey) == "deepgram" && d.bool(forKey: "copilotEnabled"))
        fresh(); CopilotPathSettings.apply(choices(.cloud, claude: true), to: d)
        check("setup: cloud without Deepgram keeps speech local", d.string(forKey: backendKey) == "local")
        fresh(); d.set(true, forKey: "copilotEnabled"); CopilotPathSettings.apply(choices(.later), to: d)
        check("setup: later turns Copilot off and saves the path",
              !d.bool(forKey: "copilotEnabled") && d.string(forKey: CopilotPath.defaultsKey) == "later")
        check("setup: reports keep following Copilot", d.string(forKey: "reportsProvider") == nil)

        fresh(); CopilotPathSettings.apply(choices(.private), to: d)
        check("setup: model ready switches Copilot on once",
              CopilotPathSettings.ollamaModelReady(in: d) && d.bool(forKey: "copilotEnabled")
              && d.bool(forKey: CopilotPathSettings.justTurnedOnKey))
        check("setup: a second ready does nothing", !CopilotPathSettings.ollamaModelReady(in: d))
        fresh(); CopilotPathSettings.apply(choices(.balanced), to: d)
        d.set(true, forKey: CopilotPathSettings.enableWhenReadyKey)
        check("setup: model ready ignores other paths", !CopilotPathSettings.ollamaModelReady(in: d))

        func status(_ enabled: Bool, _ path: CopilotPath?, pending: Bool = false,
                    pulling: Bool = false, key: Bool = false) -> CopilotStatus {
            CopilotStatus.current(copilotEnabled: enabled, path: path, enableWhenReady: pending,
                                  ollamaPulling: pulling, ollamaProgress: pulling ? 0.4 : nil, hasClaudeKey: key)
        }
        check("status: enabled is on", status(true, nil) == .on)
        check("status: private pulling waits", status(false, .private, pending: true, pulling: true) == .waitingForModel(progress: 0.4))
        check("status: private not pulling needs Ollama", status(false, .private, pending: true) == .finishOllama)
        check("status: private switched off is off", status(false, .private) == .off)
        check("status: balanced without a key", status(false, .balanced) == .needsClaudeKey)
        check("status: cloud with a key but off", status(false, .cloud, key: true) == .off)
        check("status: never set up is off", status(false, nil) == .off && status(false, .later) == .off)
        check("card: on shows only right after turning on",
              CopilotStatus.showsHomeCard(.on, dismissed: false, justTurnedOn: true)
              && !CopilotStatus.showsHomeCard(.on, dismissed: false, justTurnedOn: false))
        check("card: a download can't be hidden",
              CopilotStatus.showsHomeCard(.waitingForModel(progress: nil), dismissed: true, justTurnedOn: false))
        check("card: dismiss hides the nudge",
              !CopilotStatus.showsHomeCard(.off, dismissed: true, justTurnedOn: false)
              && CopilotStatus.showsHomeCard(.needsClaudeKey, dismissed: false, justTurnedOn: false))
        fresh()
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `make test 2>&1 | tail -5`
Expected: build error `cannot find 'CopilotPathSettings' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Parrot/Services/CopilotSetupState.swift`:

```swift
import Foundation

/// What the user settled on in the Copilot screens.
struct CopilotChoices {
    var path: CopilotPath
    var ollamaModel: String
    /// The Copilot card's switch: the user's consent to turn it on.
    var copilotSwitchOn: Bool
    var claudeKeyWorks: Bool
    var deepgramKeyWorks: Bool
    var ollamaModelReady: Bool
}

enum CopilotPathSettings {
    /// Private path, model still downloading: turn Copilot on when it lands.
    static let enableWhenReadyKey = "copilotEnableWhenOllamaReady"
    /// Copilot switched itself on; the Home card says so once.
    static let justTurnedOnKey = "copilotJustTurnedOn"
    static let cardDismissedKey = "copilotCardDismissed"

    /// Writes what a path implies. Leaves `whisperModel` to the speech step
    /// and `reportsProvider` empty, so reports follow Copilot.
    static func apply(_ c: CopilotChoices, to d: UserDefaults = .standard) {
        d.set(c.path.rawValue, forKey: CopilotPath.defaultsKey)
        d.set(false, forKey: enableWhenReadyKey)
        switch c.path {
        case .private:
            d.set(CopilotProviderKind.ollama.rawValue, forKey: "copilotProvider")
            d.set(c.ollamaModel, forKey: "copilotOllamaModel")
            d.set(TranscriptionBackend.local.rawValue, forKey: TranscriptionBackend.defaultsKey)
            d.set(c.copilotSwitchOn && c.ollamaModelReady, forKey: "copilotEnabled")
            d.set(c.copilotSwitchOn && !c.ollamaModelReady, forKey: enableWhenReadyKey)
        case .balanced:
            d.set(CopilotProviderKind.claude.rawValue, forKey: "copilotProvider")
            d.set(TranscriptionBackend.local.rawValue, forKey: TranscriptionBackend.defaultsKey)
            d.set(c.copilotSwitchOn && c.claudeKeyWorks, forKey: "copilotEnabled")
        case .cloud:
            d.set(CopilotProviderKind.claude.rawValue, forKey: "copilotProvider")
            let backend: TranscriptionBackend = c.deepgramKeyWorks ? .deepgram : .local
            d.set(backend.rawValue, forKey: TranscriptionBackend.defaultsKey)
            d.set(c.copilotSwitchOn && c.claudeKeyWorks, forKey: "copilotEnabled")
        case .later:
            d.set(false, forKey: "copilotEnabled")
        }
    }

    /// The Ollama model finished. Honours a pending "turn on" from the
    /// private path; returns true when it switched Copilot on.
    @discardableResult
    static func ollamaModelReady(in d: UserDefaults = .standard) -> Bool {
        guard d.bool(forKey: enableWhenReadyKey),
              d.string(forKey: CopilotPath.defaultsKey) == CopilotPath.private.rawValue else { return false }
        d.set(true, forKey: "copilotEnabled")
        d.set(false, forKey: enableWhenReadyKey)
        d.set(true, forKey: justTurnedOnKey)
        return true
    }
}

/// Where Copilot stands, for the Ready screen and the Home card.
enum CopilotStatus: Equatable {
    case on
    case waitingForModel(progress: Double?)
    case finishOllama
    case needsClaudeKey
    case off

    static func current(copilotEnabled: Bool, path: CopilotPath?, enableWhenReady: Bool,
                        ollamaPulling: Bool, ollamaProgress: Double?, hasClaudeKey: Bool) -> CopilotStatus {
        if copilotEnabled { return .on }
        switch path {
        case .private?:
            guard enableWhenReady else { return .off }
            return ollamaPulling ? .waitingForModel(progress: ollamaProgress) : .finishOllama
        case .balanced?, .cloud?:
            return hasClaudeKey ? .off : .needsClaudeKey
        case .later?, nil:
            return .off
        }
    }

    /// A download in flight always shows; "on" shows once, right after
    /// Copilot switched itself on; the nudges respect the close button.
    static func showsHomeCard(_ status: CopilotStatus, dismissed: Bool, justTurnedOn: Bool) -> Bool {
        switch status {
        case .on: justTurnedOn
        case .waitingForModel: true
        case .finishOllama, .needsClaudeKey, .off: !dismissed
        }
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `make test 2>&1 | grep -E "setup:|status:|card:|^FAIL|ALL PASS|FAILURES"`
Expected: all `PASS`, last line `ALL PASS`.

- [ ] **Step 5: Commit**

```bash
git add Parrot/Services/CopilotSetupState.swift Parrot/ProfileTest.swift
git commit -m "Copilot setup: settings per path, auto-enable, status for Ready and Home

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Key checks for Claude and Deepgram

**Files:**
- Create: `Parrot/Services/ProviderKeyCheck.swift`
- Test: `Parrot/ProfileTest.swift` (new `testProviderKeyCheck`)

**Interfaces:**
- Consumes: `TranscriptionBackend.deepgram.keychainAccount` (`"deepgram-api-key"`)
- Produces: `enum ProviderKeyCheck` with nested `enum Service { case claude, deepgram; var name: String; var keychainAccount: String? }`, `enum Outcome: Equatable { case works, rejected, unreachable }`, `static func request(_:key:) -> URLRequest`, `static func classify(status: Int?) -> Outcome`, `static func check(_:key:) async -> Outcome`, `static func message(_ outcome: Outcome?, _ service: Service) -> String?`

- [ ] **Step 1: Write the failing test**

Add `testProviderKeyCheck()` to `run()` and to `ProfileTest`:

```swift
    static func testProviderKeyCheck() {
        let c = ProviderKeyCheck.request(.claude, key: "sk-ant-x")
        check("keycheck: claude asks for one model",
              c.url?.absoluteString == "https://api.anthropic.com/v1/models?limit=1" && c.httpMethod == "GET")
        check("keycheck: claude headers",
              c.value(forHTTPHeaderField: "x-api-key") == "sk-ant-x"
              && c.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        let dg = ProviderKeyCheck.request(.deepgram, key: "abc")
        check("keycheck: deepgram projects with a token",
              dg.url?.absoluteString == "https://api.deepgram.com/v1/projects"
              && dg.value(forHTTPHeaderField: "Authorization") == "Token abc")
        check("keycheck: short timeout", c.timeoutInterval == 10 && dg.timeoutInterval == 10)
        check("keycheck: 200 works", ProviderKeyCheck.classify(status: 200) == .works)
        check("keycheck: 400, 401 and 403 reject",
              [400, 401, 403].allSatisfy { ProviderKeyCheck.classify(status: $0) == .rejected })
        check("keycheck: 429 and 500 say nothing about the key",
              ProviderKeyCheck.classify(status: 429) == .unreachable && ProviderKeyCheck.classify(status: 500) == .unreachable)
        check("keycheck: no response is unreachable", ProviderKeyCheck.classify(status: nil) == .unreachable)
        check("keycheck: messages",
              ProviderKeyCheck.message(.unreachable, .deepgram) == "Couldn't reach Deepgram. Check your internet."
              && ProviderKeyCheck.message(.rejected, .claude) == "That key didn't work. Check it and try again."
              && ProviderKeyCheck.message(.works, .claude) == "Key works"
              && ProviderKeyCheck.message(nil, .claude) == nil)
        check("keycheck: keychain slots",
              ProviderKeyCheck.Service.deepgram.keychainAccount == "deepgram-api-key"
              && ProviderKeyCheck.Service.claude.keychainAccount == nil)
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `make test 2>&1 | tail -5`
Expected: build error `cannot find 'ProviderKeyCheck' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Parrot/Services/ProviderKeyCheck.swift`:

```swift
import Foundation

/// One tiny authenticated request per service, so a typo shows up during
/// setup and not in the middle of the first call. Runs only when the user
/// presses Check key, or opens a Claude path with a key already saved.
enum ProviderKeyCheck {
    enum Service {
        case claude, deepgram

        var name: String { self == .claude ? "Anthropic" : "Deepgram" }
        /// nil = the default (Claude) Keychain slot.
        var keychainAccount: String? { self == .claude ? nil : TranscriptionBackend.deepgram.keychainAccount }
    }

    enum Outcome: Equatable { case works, rejected, unreachable }

    static func request(_ service: Service, key: String) -> URLRequest {
        var request: URLRequest
        switch service {
        case .claude:
            request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=1")!)
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .deepgram:
            request = URLRequest(url: URL(string: "https://api.deepgram.com/v1/projects")!)
            request.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 10
        return request
    }

    /// 2xx works. 400/401/403: the service read the key and said no.
    /// Anything else (429, 5xx, no answer) says nothing about the key.
    static func classify(status: Int?) -> Outcome {
        guard let status else { return .unreachable }
        switch status {
        case 200..<300: return .works
        case 400, 401, 403: return .rejected
        default: return .unreachable
        }
    }

    static func check(_ service: Service, key: String) async -> Outcome {
        let response = try? await URLSession.shared.data(for: request(service, key: key)).1
        return classify(status: (response as? HTTPURLResponse)?.statusCode)
    }

    static func message(_ outcome: Outcome?, _ service: Service) -> String? {
        switch outcome {
        case .works?: "Key works"
        case .rejected?: "That key didn't work. Check it and try again."
        case .unreachable?: "Couldn't reach \(service.name). Check your internet."
        case nil: nil
        }
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `make test 2>&1 | grep -E "keycheck:|^FAIL|ALL PASS|FAILURES"`
Expected: all `PASS`, `ALL PASS`.

- [ ] **Step 5: Commit**

```bash
git add Parrot/Services/ProviderKeyCheck.swift Parrot/ProfileTest.swift
git commit -m "Key check: one small request tells a working Claude or Deepgram key from a typo

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Speech model download fails on a stall, not after 300 s

**Files:**
- Modify: `Parrot/Services/TranscriptionEngine.swift` (the `WhisperKit.download` call at ~L154, and next to `withTimeout` at ~L335)
- Test: `Parrot/ProfileTest.swift` (new `testProgressStall`)

**Interfaces:**
- Produces: `struct TranscriptionEngine.ProgressStall { init(limit: TimeInterval, start: Date = .now); mutating func note(_ progress: Double, at: Date = .now); func isStalled(at: Date = .now) -> Bool }`

- [ ] **Step 1: Write the failing test**

Add `testProgressStall()` to `run()` and to `ProfileTest`:

```swift
    static func testProgressStall() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        var s = TranscriptionEngine.ProgressStall(limit: 60, start: t0)
        check("stall: fresh start isn't stalled", !s.isStalled(at: t0 + 59))
        check("stall: 60 s without progress is", s.isStalled(at: t0 + 60))
        s.note(0.1, at: t0 + 50)
        check("stall: progress resets the clock", !s.isStalled(at: t0 + 100))
        s.note(0.1, at: t0 + 90)
        check("stall: the same value isn't progress", s.isStalled(at: t0 + 110))
        var slow = TranscriptionEngine.ProgressStall(limit: 60, start: t0)
        for i in 1...20 { slow.note(Double(i) / 100, at: t0 + Double(i * 50)) }
        check("stall: slow but moving never trips (1000 s download)", !slow.isStalled(at: t0 + 1_030))
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `make test 2>&1 | tail -5`
Expected: build error `type 'TranscriptionEngine' has no member 'ProgressStall'`.

- [ ] **Step 3: Write the implementation**

In `Parrot/Services/TranscriptionEngine.swift`, directly above `private struct ModelLoadTimeout` (~L329), add:

```swift
    /// Tracks whether a download is still moving. Only a rise in progress
    /// counts, so a stuck value can't keep it alive.
    struct ProgressStall {
        let limit: TimeInterval
        private var best: Double = -1
        private var lastMove: Date

        init(limit: TimeInterval, start: Date = .now) {
            self.limit = limit
            lastMove = start
        }

        mutating func note(_ progress: Double, at time: Date = .now) {
            guard progress > best else { return }
            best = progress
            lastMove = time
        }

        func isStalled(at time: Date = .now) -> Bool {
            time.timeIntervalSince(lastMove) >= limit
        }
    }

    /// Like `withTimeout`, but for downloads: fails only when progress stops
    /// moving for `seconds`. A fixed limit failed the 1.6 GB turbo model on
    /// anything slower than ~5 MB/s.
    nonisolated private static func withStallTimeout<T: Sendable>(
        seconds: TimeInterval,
        _ op: @escaping @Sendable (_ tick: @escaping @Sendable (Double) -> Void) async throws -> T
    ) async throws -> T {
        let watch = OSAllocatedUnfairLock(initialState: ProgressStall(limit: seconds))
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await op { progress in watch.withLock { $0.note(progress) } } }
            group.addTask {
                while true {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    if watch.withLock({ $0.isStalled() }) { throw ModelLoadTimeout() }
                }
            }
            guard let first = try await group.next() else { throw ModelLoadTimeout() }
            group.cancelAll()
            return first
        }
    }
```

Then replace the download block (~L154–L163):

```swift
                modelFolder = try await Self.withTimeout(seconds: 300) {
                    try await WhisperKit.download(variant: resolvedModelName) { progress in
                        let fraction = min(max(progress.fractionCompleted, 0), 1)
```

with:

```swift
                modelFolder = try await Self.withStallTimeout(seconds: 60) { tick in
                    try await WhisperKit.download(variant: resolvedModelName) { progress in
                        let fraction = min(max(progress.fractionCompleted, 0), 1)
                        tick(fraction)
```

Leave the rest of that closure and the `withTimeout(seconds: 300)` around `WhisperKit(config)` (loading, not downloading) unchanged.

- [ ] **Step 4: Run the test to verify it passes**

Run: `make test 2>&1 | grep -E "stall:|^FAIL|ALL PASS|FAILURES"`
Expected: all `PASS`, `ALL PASS`.

- [ ] **Step 5: Commit**

```bash
git add Parrot/Services/TranscriptionEngine.swift Parrot/ProfileTest.swift
git commit -m "Model download: fail on 60 s without progress instead of 300 s total

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: App-wide Ollama service

**Files:**
- Create: `Parrot/Services/OllamaService.swift`
- Modify: `Parrot/Views/OllamaModelStatusView.swift` (whole file)
- Modify: `Parrot/Services/RecordingManager.swift` (property list ~L36; `prepare` ~L110)
- Test: `Parrot/ProfileTest.swift` (new `testOllamaService`)

**Interfaces:**
- Consumes: `CopilotPathSettings.ollamaModelReady(in:)`, `CopilotPathSettings.enableWhenReadyKey`, `CopilotPath.defaultsKey` (Task 2), `OpenAICompatibleProvider.ollamaModel`
- Produces: `@MainActor @Observable final class OllamaService` with `enum Status: Equatable { case checking, serverDown, missing, pulling(progress: Double?), ready, failed(String) }`, `status`, `model: String`, `isServerUp: Bool`, `isPulling: Bool`, `pullProgress: Double?`, `refresh(model:) async`, `pull(_ model: String)`, `resumeIfNeeded(defaults:) async`, `enum PullEvent: Equatable { case progress(Double?), done, failed(String) }`, `nonisolated static func parsePullLine(_:) -> PullEvent?`. `RecordingManager.ollama: OllamaService`.

- [ ] **Step 1: Write the failing test**

Add `testOllamaService()` to `run()` and to `ProfileTest`:

```swift
    @MainActor
    static func testOllamaService() {
        check("ollama: progress line",
              OllamaService.parsePullLine(#"{"status":"pulling 6a0746a1ec1a","total":200,"completed":50}"#) == .progress(0.25))
        check("ollama: success", OllamaService.parsePullLine(#"{"status":"success"}"#) == .done)
        check("ollama: error", OllamaService.parsePullLine(#"{"error":"pull model manifest: file does not exist"}"#)
              == .failed("pull model manifest: file does not exist"))
        check("ollama: manifest line carries nothing", OllamaService.parsePullLine(#"{"status":"pulling manifest"}"#) == nil)
        check("ollama: junk ignored", OllamaService.parsePullLine("not json") == nil)
        let service = OllamaService()
        check("ollama: starts checking, not pulling", service.status == .checking && !service.isPulling && service.pullProgress == nil)
        check("ollama: checking isn't a running server", !service.isServerUp)
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `make test 2>&1 | tail -5`
Expected: build error `cannot find 'OllamaService' in scope`.

- [ ] **Step 3: Write the service**

Create `Parrot/Services/OllamaService.swift`:

```swift
import Foundation

/// The local Ollama server, app-wide: is it up, is the chosen model there,
/// and the one model pull every screen reads (onboarding, Settings, the
/// Home card). It lives as long as the app, so a pull started in the setup
/// sheet keeps going and stays visible after the sheet closes. Talks only
/// to localhost:11434.
@MainActor
@Observable
final class OllamaService {
    enum Status: Equatable {
        case checking, serverDown, missing, pulling(progress: Double?), ready, failed(String)
    }

    enum PullEvent: Equatable { case progress(Double?), done, failed(String) }

    private(set) var status: Status = .checking
    /// The model `status` describes.
    private(set) var model = OpenAICompatibleProvider.ollamaModel
    private var pullTask: Task<Void, Never>?
    nonisolated private static let base = URL(string: "http://localhost:11434")!

    var isServerUp: Bool {
        switch status {
        case .checking, .serverDown: false
        default: true
        }
    }

    var isPulling: Bool {
        if case .pulling = status { true } else { false }
    }

    var pullProgress: Double? {
        if case .pulling(let progress) = status { progress } else { nil }
    }

    /// Re-reads the server and the model. Leaves a running pull of the same
    /// model alone, so polling never hides its progress.
    func refresh(model: String) async {
        if isPulling, model == self.model { return }
        if model != self.model {
            self.model = model
            status = .checking
        }
        guard let installed = await Self.installedModels() else {
            status = .serverDown
            return
        }
        let wasReady = status == .ready
        status = installed.contains(model) ? .ready : .missing
        if status == .ready, !wasReady { CopilotPathSettings.ollamaModelReady() }
    }

    /// Starts a pull unless one is already running.
    func pull(_ model: String) {
        guard pullTask == nil else { return }
        self.model = model
        status = .pulling(progress: nil)
        pullTask = Task { [weak self] in
            await self?.runPull(model)
            self?.pullTask = nil
        }
    }

    /// Launch: a private-path user whose model never finished gets the pull
    /// started again. Ollama keeps finished layers, so it picks up.
    func resumeIfNeeded(defaults: UserDefaults = .standard) async {
        guard defaults.string(forKey: CopilotPath.defaultsKey) == CopilotPath.private.rawValue,
              defaults.bool(forKey: CopilotPathSettings.enableWhenReadyKey) else { return }
        let model = OpenAICompatibleProvider.ollamaModel
        await refresh(model: model)
        if status == .missing { pull(model) }
    }

    private func runPull(_ model: String) async {
        do {
            var request = URLRequest(url: Self.base.appendingPathComponent("api/pull"))
            request.httpMethod = "POST"
            request.timeoutInterval = 3600  // multi-GB download
            request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model])
            let (bytes, _) = try await URLSession.shared.bytes(for: request)
            for try await line in bytes.lines {
                switch Self.parsePullLine(line) {
                case .progress(let progress)?:
                    status = .pulling(progress: progress)
                case .done?:
                    status = .ready
                    CopilotPathSettings.ollamaModelReady()
                    return
                case .failed(let message)?:
                    status = .failed(message)
                    return
                case nil:
                    continue
                }
            }
            status = .checking  // stream ended without a success line
            await refresh(model: model)
        } catch {
            status = .failed(error is URLError ? "Ollama stopped. Open it and try again." : error.localizedDescription)
        }
    }

    nonisolated static func parsePullLine(_ line: String) -> PullEvent? {
        struct Line: Decodable {
            let status: String?
            let total: Int64?
            let completed: Int64?
            let error: String?
        }
        guard let data = line.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(Line.self, from: data) else { return nil }
        if let error = parsed.error { return .failed(error) }
        if parsed.status == "success" { return .done }
        if let total = parsed.total, let completed = parsed.completed, total > 0 {
            return .progress(Double(completed) / Double(total))
        }
        return nil
    }

    nonisolated private static func installedModels() async -> [String]? {
        struct Tags: Decodable {
            struct Entry: Decodable { let name: String }
            let models: [Entry]
        }
        var request = URLRequest(url: base.appendingPathComponent("api/tags"))
        request.timeoutInterval = 3
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let tags = try? JSONDecoder().decode(Tags.self, from: data) else { return nil }
        return tags.models.map(\.name)
    }
}
```

- [ ] **Step 4: Own it in RecordingManager and resume at launch**

In `Parrot/Services/RecordingManager.swift`, after `let reminders = RemindersService()` (~L38) add:

```swift
    /// The local Ollama server and its one model pull, shared by onboarding,
    /// Settings and the Home card.
    let ollama = OllamaService()
```

In `prepare(modelContext:)`, after `Task { await syncMemory() }` add:

```swift
        // A private-path setup whose model download never finished.
        Task { await ollama.resumeIfNeeded() }
```

- [ ] **Step 5: Make the Settings view read the service**

Replace the whole of `Parrot/Views/OllamaModelStatusView.swift` with:

```swift
import SwiftUI

/// Lives under the Ollama model picker in Settings → Copilot: whether the
/// selected model is ready on this Mac, with a one-click download when it
/// isn't. A thin view over `OllamaService`, so a pull started in onboarding
/// shows here too and never starts twice.
struct OllamaModelStatusView: View {
    let model: String
    @Environment(RecordingManager.self) private var recordingManager

    var body: some View {
        let ollama = recordingManager.ollama
        let status: OllamaService.Status = ollama.model == model ? ollama.status : .checking
        HStack(spacing: 8) {
            switch status {
            case .checking:
                ProgressView().controlSize(.small)
                Text("Checking Ollama…").foregroundStyle(Theme.Colors.ink2)

            case .serverDown:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.Colors.warn)
                Text("Ollama isn't running — install it from ollama.com, then open it.")
                    .foregroundStyle(Theme.Colors.ink2)
                Button("Check Again") { Task { await ollama.refresh(model: model) } }
                    .buttonStyle(.link)

            case .missing:
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(Theme.Colors.ink2)
                Text("Model not downloaded yet.")
                    .foregroundStyle(Theme.Colors.ink2)
                Button("Download (\(OllamaCatalog.sizeLabel(for: model) ?? "size varies"))") {
                    ollama.pull(model)
                }
                .controlSize(.small)

            case .pulling(let progress):
                ProgressView(value: progress)
                    .frame(width: 140)
                Text(progress.map { "\(Int($0 * 100))%" } ?? "Starting…")
                    .foregroundStyle(Theme.Colors.ink2)
                    .font(Theme.Typography.mono(11))

            case .ready:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.Colors.good)
                Text("Ready — runs on this Mac.")
                    .foregroundStyle(Theme.Colors.ink2)

            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.Colors.warn)
                Text("Download failed: \(message)")
                    .foregroundStyle(Theme.Colors.ink2)
                    .lineLimit(2)
                Button("Retry") { ollama.pull(model) }
                    .buttonStyle(.link)
            }
        }
        .font(Theme.Typography.caption)
        // Re-check whenever the selected model changes (also fires on appear).
        .task(id: model) { await ollama.refresh(model: model) }
    }
}
```

- [ ] **Step 6: Run the tests**

Run: `make test 2>&1 | grep -E "ollama:|^FAIL|ALL PASS|FAILURES"`
Expected: all `PASS`, `ALL PASS`.

- [ ] **Step 7: Check Settings still shows the status**

Run: `make build && .build/release/Parrot --help-shots "$TMPDIR/parrot-shots"`, then open `$TMPDIR/parrot-shots/settings-copilot.png` with the Read tool.
Expected: the Copilot settings page renders as before (Claude is the harness provider, so no Ollama row; the point is that it doesn't crash).

- [ ] **Step 8: Commit**

```bash
git add Parrot/Services/OllamaService.swift Parrot/Views/OllamaModelStatusView.swift Parrot/Services/RecordingManager.swift Parrot/ProfileTest.swift
git commit -m "Ollama: app-wide service so a model pull survives screens and resumes at launch

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Install Ollama from inside Parrot

**Files:**
- Create: `Parrot/Services/OllamaInstaller.swift`
- Modify: `Parrot/Services/RecordingManager.swift` (next to `let ollama`)
- Modify: `Parrot/ProfileTest.swift` (add `import Security` at the top; new `testOllamaInstaller`)

**Interfaces:**
- Produces: `@MainActor @Observable final class OllamaInstaller` with `enum State: Equatable { case idle, downloading(progress: Double?), unpacking, verifying, opening, opened, failed(String) }`, `state`, `isBusy`, `install() async`, `openInstalled() async`, `nonisolated static let bundleID: String`, `nonisolated static let teamID: String`, `nonisolated static var requirement: String`, `static let websiteURL: URL`, `static func installedAppURL() -> URL?`, `nonisolated static func isSignedByOllama(_ app: URL) -> Bool`. `RecordingManager.ollamaInstaller: OllamaInstaller`.

- [ ] **Step 1: Read Ollama's signing identity from the official download**

Run:

```bash
curl -L --fail -o "$TMPDIR/Ollama-darwin.zip" https://ollama.com/download/Ollama-darwin.zip
rm -rf "$TMPDIR/ollama-check" && ditto -x -k "$TMPDIR/Ollama-darwin.zip" "$TMPDIR/ollama-check"
codesign -dv "$TMPDIR/ollama-check/Ollama.app" 2>&1 | grep -E "^Identifier=|^TeamIdentifier="
spctl -a -vv "$TMPDIR/ollama-check/Ollama.app"
```

Expected: an `Identifier=` line (the bundle ID), a `TeamIdentifier=` line (10 characters, capitals and digits), and `spctl` printing `accepted` with `source=Notarized Developer ID`. Write both values down; Step 4 uses them. If `spctl` doesn't say accepted, stop and tell Uygar: the in-app install must not ship.

- [ ] **Step 2: Write the failing test**

Add `import Security` under `import SwiftData` at the top of `Parrot/ProfileTest.swift`. Add `testOllamaInstaller()` to `run()` and to `ProfileTest`:

```swift
    static func testOllamaInstaller() {
        let team = OllamaInstaller.teamID
        check("installer: team id is a real one",
              team.count == 10 && team.allSatisfy { $0.isNumber || ($0.isLetter && $0.isUppercase) })
        check("installer: bundle id is filled in", OllamaInstaller.bundleID.contains("."))
        var requirement: SecRequirement?
        check("installer: requirement compiles",
              SecRequirementCreateWithString(OllamaInstaller.requirement as CFString, [], &requirement) == errSecSuccess)
        check("installer: an Apple app is not Ollama",
              !OllamaInstaller.isSignedByOllama(URL(fileURLWithPath: "/System/Applications/Calculator.app")))
        check("installer: a missing file is not Ollama",
              !OllamaInstaller.isSignedByOllama(URL(fileURLWithPath: "/nonexistent/Ollama.app")))
        if let path = ProcessInfo.processInfo.environment["PARROT_OLLAMA_APP"] {
            check("installer: the real download passes", OllamaInstaller.isSignedByOllama(URL(fileURLWithPath: path)))
        }
    }
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `make test 2>&1 | tail -5`
Expected: build error `cannot find 'OllamaInstaller' in scope`.

- [ ] **Step 4: Write the installer**

Create `Parrot/Services/OllamaInstaller.swift`. Put the two values from Step 1 into `bundleID` and `teamID`:

```swift
import AppKit
import Security

/// Installs the official Ollama app from inside Parrot. The sandbox lets us
/// write to Downloads and open apps, not write to /Applications, so: fetch
/// the zip into Downloads, unpack it there, check it's really signed by
/// Ollama, and open it. Files a sandboxed app writes are quarantined, so
/// macOS asks "downloaded from the Internet. Open?" once. That's the right
/// place for the decision.
@MainActor
@Observable
final class OllamaInstaller {
    enum State: Equatable {
        case idle, downloading(progress: Double?), unpacking, verifying, opening, opened, failed(String)
    }

    private(set) var state: State = .idle

    static let downloadURL = URL(string: "https://ollama.com/download/Ollama-darwin.zip")!
    static let websiteURL = URL(string: "https://ollama.com/download")!
    /// From `codesign -dv` on the official download (plan Task 6, Step 1).
    nonisolated static let bundleID = "PUT THE Identifier VALUE FROM STEP 1 HERE"
    nonisolated static let teamID = "PUT THE TeamIdentifier VALUE FROM STEP 1 HERE"
    nonisolated static var requirement: String {
        "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
    }

    var isBusy: Bool {
        switch state {
        case .downloading, .unpacking, .verifying, .opening: true
        default: false
        }
    }

    /// Ollama.app wherever Launch Services knows it: Applications, Downloads…
    static func installedAppURL() -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    func openInstalled() async {
        guard let app = Self.installedAppURL() else { return }
        await open(app)
    }

    func install() async {
        guard !isBusy else { return }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let zip = downloads.appendingPathComponent("Ollama-darwin.zip")
        let app = downloads.appendingPathComponent("Ollama.app")
        do {
            state = .downloading(progress: nil)
            try await download(to: zip)
            state = .unpacking
            try? FileManager.default.removeItem(at: app)
            try await Task.detached { try Self.unzip(zip, into: downloads) }.value
            try? FileManager.default.removeItem(at: zip)
            state = .verifying
            guard Self.isSignedByOllama(app) else {
                try? FileManager.default.removeItem(at: app)
                state = .failed("That download didn't look right. Get it from ollama.com instead.")
                return
            }
            await open(app)
        } catch {
            try? FileManager.default.removeItem(at: zip)
            state = .failed("Couldn't install Ollama. Get it from ollama.com instead.")
        }
    }

    private func open(_ app: URL) async {
        state = .opening
        do {
            _ = try await NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
            state = .opened
        } catch {
            state = .failed("Couldn't open Ollama. Open it from your Downloads folder.")
        }
    }

    private func download(to file: URL) async throws {
        let relay = ProgressRelay { [weak self] fraction in
            Task { @MainActor in self?.state = .downloading(progress: fraction) }
        }
        let (temporary, response) = try await URLSession.shared.download(from: Self.downloadURL, delegate: relay)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: temporary, to: file)
    }

    nonisolated private static func unzip(_ zip: URL, into directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, directory.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    /// True only for a valid signature from Ollama's Developer ID team.
    nonisolated static func isSignedByOllama(_ app: URL) -> Bool {
        var code: SecStaticCode?
        var requirementRef: SecRequirement?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(requirement as CFString, [], &requirementRef) == errSecSuccess,
              let requirementRef else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures)
        return SecStaticCodeCheckValidity(code, flags, requirementRef) == errSecSuccess
    }
}

/// Forwards a download task's progress. The async download API hands the
/// task to its delegate once, on creation; we watch its Progress from there.
private final class ProgressRelay: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double) -> Void
    private var observation: NSKeyValueObservation?

    init(_ onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        observation = task.progress.observe(\.fractionCompleted) { [onProgress] progress, _ in
            onProgress(progress.fractionCompleted)
        }
    }
}
```

In `Parrot/Services/RecordingManager.swift`, under `let ollama = OllamaService()` add:

```swift
    /// Installs the Ollama app from inside Parrot (onboarding, private path).
    let ollamaInstaller = OllamaInstaller()
```

- [ ] **Step 5: Run the tests, including against the real download**

Run: `make build && PARROT_OLLAMA_APP="$TMPDIR/ollama-check/Ollama.app" .build/release/Parrot --profile-test | grep -E "installer:|^FAIL|ALL PASS|FAILURES"`
Expected: all `installer:` lines `PASS`, including "the real download passes", and `ALL PASS`.

- [ ] **Step 6: Commit**

```bash
git add Parrot/Services/OllamaInstaller.swift Parrot/Services/RecordingManager.swift Parrot/ProfileTest.swift
git commit -m "Ollama: install the official app from inside Parrot, signature-checked

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: Sheet state and shared step parts

**Files:**
- Create: `Parrot/Views/Onboarding/OnboardingModel.swift`
- Create: `Parrot/Views/Onboarding/OnboardingParts.swift`
- Test: `Parrot/ProfileTest.swift` (new `testOnboardingModel`)

**Interfaces:**
- Consumes: Task 1 types, `CopilotChoices`/`CopilotPathSettings` (Task 2), `ProviderKeyCheck.Outcome` (Task 3), `TranscriptionEngine.modelState`
- Produces:
  - `@MainActor @Observable final class OnboardingModel` with `init(defaults: UserDefaults = .standard)`, `mode: OnboardingMode`, `step: OnboardingStep` (read-only), `path: CopilotPath?`, `pathError: String?`, `copilotOn: Bool`, `claudeCheck: ProviderKeyCheck.Outcome?`, `deepgramCheck: ProviderKeyCheck.Outcome?`, `ollamaModel: String`, `ollamaModelReady: Bool`, `steps`, `isFirst`, `isLast`, `move(_ offset: Int)`, `go(to:)`, `decideLater()`, `applyChoices()`, `finish()`
  - Views: `StepHeader(title:subtitle:)`, `CopilotHeroCard(title:subtitle:emphasized:bordered:accessory:)`, `DownloadRow(title:progress:note:)`, `PendingRow(title:)`, `SpeechDownloadRow(backup:)`

- [ ] **Step 1: Write the failing test**

Add `testOnboardingModel()` to `run()` and to `ProfileTest`:

```swift
    @MainActor
    static func testOnboardingModel() {
        let suite = "parrot.test.onboardingModel"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        let m = OnboardingModel(defaults: d)
        check("sheet: fresh starts at welcome", m.step == .welcome && m.mode == .full && m.path == nil && m.isFirst)
        m.move(1); m.move(1)
        check("sheet: welcome → permissions → meet copilot", m.step == .meetCopilot)
        m.move(1)
        check("sheet: then the path choice", m.step == .copilotPath)
        m.move(1)
        check("sheet: continue without a pick stays put",
              m.step == .copilotPath && m.pathError == "Pick one to continue")
        m.path = .balanced
        check("sheet: picking clears the error and saves the path",
              m.pathError == nil && d.string(forKey: CopilotPath.defaultsKey) == "balanced")
        m.move(1); m.move(1)
        check("sheet: balanced goes speech → setup", m.step == .copilotSetup)
        m.claudeCheck = .works
        m.move(1)
        check("sheet: leaving setup writes the settings",
              m.step == .automatic && d.bool(forKey: "copilotEnabled") && d.string(forKey: "copilotProvider") == "claude")
        let resumed = OnboardingModel(defaults: d)
        check("sheet: a relaunch resumes step and path", resumed.step == .automatic && resumed.path == .balanced)
        resumed.go(to: .copilotPath)
        resumed.decideLater()
        check("sheet: decide later moves on with Copilot off",
              resumed.step == .speechModel && resumed.path == .later && !d.bool(forKey: "copilotEnabled"))
        resumed.finish()
        check("sheet: finish clears the step and resets the mode",
              d.string(forKey: OnboardingFlow.stepKey) == nil && d.string(forKey: OnboardingMode.defaultsKey) == "full")
        d.set(OnboardingMode.copilot.rawValue, forKey: OnboardingMode.defaultsKey)
        let short = OnboardingModel(defaults: d)
        check("sheet: the short tour asks again after decide later", short.path == nil && short.step == .meetCopilot)
        d.removePersistentDomain(forName: suite)
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `make test 2>&1 | tail -5`
Expected: build error `cannot find 'OnboardingModel' in scope`.

- [ ] **Step 3: Write the model**

Create `Parrot/Views/Onboarding/OnboardingModel.swift`:

```swift
import SwiftUI

/// State shared by the setup sheet's steps. Mode, path and step persist, so
/// the quit-and-reopen macOS can require after a permission grant lands the
/// user back where they were.
@MainActor
@Observable
final class OnboardingModel {
    private let defaults: UserDefaults
    let mode: OnboardingMode
    private(set) var step: OnboardingStep
    var path: CopilotPath? {
        didSet {
            defaults.set(path?.rawValue, forKey: CopilotPath.defaultsKey)
            pathError = nil
        }
    }
    var pathError: String?
    /// The Copilot card's switch: consent to turn Copilot on.
    var copilotOn = true
    var claudeCheck: ProviderKeyCheck.Outcome?
    var deepgramCheck: ProviderKeyCheck.Outcome?
    var ollamaModel: String
    /// Kept current by the private setup step's polling.
    var ollamaModelReady = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        OnboardingFlow.migrateLegacyStep(in: defaults)
        let mode = OnboardingMode(rawValue: defaults.string(forKey: OnboardingMode.defaultsKey) ?? "") ?? .full
        var saved = CopilotPath(rawValue: defaults.string(forKey: CopilotPath.defaultsKey) ?? "")
        if mode == .copilot, saved == .later { saved = nil }  // the short tour asks again
        self.mode = mode
        path = saved
        ollamaModel = defaults.string(forKey: "copilotOllamaModel")
            ?? MachineFit.ollamaModel(memoryGB: MachineFit.memoryGB())
        let steps = OnboardingFlow.steps(mode: mode, path: saved)
        let stored = OnboardingStep(rawValue: defaults.string(forKey: OnboardingFlow.stepKey) ?? "")
        step = OnboardingFlow.resolve(stored ?? steps[0], in: steps)
    }

    var steps: [OnboardingStep] { OnboardingFlow.steps(mode: mode, path: path) }
    var isFirst: Bool { step == steps.first }
    var isLast: Bool { step == steps.last }

    /// Continue (+1) and Back (-1). Continue on the path choice needs a pick;
    /// leaving the Copilot setup writes the settings it implies.
    func move(_ offset: Int) {
        if offset > 0, step == .copilotPath, path == nil {
            pathError = "Pick one to continue"
            return
        }
        if offset > 0, step == .copilotSetup { applyChoices() }
        go(to: OnboardingFlow.step(offset, from: step, in: steps))
    }

    func go(to newStep: OnboardingStep) {
        step = newStep
        defaults.set(newStep.rawValue, forKey: OnboardingFlow.stepKey)
    }

    func decideLater() {
        path = .later
        applyChoices()
        move(1)
    }

    func applyChoices() {
        guard let path else { return }
        CopilotPathSettings.apply(CopilotChoices(
            path: path, ollamaModel: ollamaModel, copilotSwitchOn: copilotOn,
            claudeKeyWorks: claudeCheck == .works, deepgramKeyWorks: deepgramCheck == .works,
            ollamaModelReady: ollamaModelReady), to: defaults)
    }

    /// Let's start / Done: the next tour starts clean.
    func finish() {
        defaults.removeObject(forKey: OnboardingFlow.stepKey)
        defaults.set(OnboardingMode.full.rawValue, forKey: OnboardingMode.defaultsKey)
    }
}
```

- [ ] **Step 4: Write the shared parts**

Create `Parrot/Views/Onboarding/OnboardingParts.swift`:

```swift
import SwiftUI

/// Title and one line, centred: the top of every step.
struct StepHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(Theme.Typography.title(24))
            if let subtitle {
                Text(subtitle)
                    .font(Theme.Typography.sans(14))
                    .foregroundStyle(Theme.Colors.ink2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 460)
    }
}

/// The big Copilot card: sparkles, one line on how it runs, and whatever
/// sits on the right (the on/off switch, a check, a close button).
struct CopilotHeroCard<Accessory: View>: View {
    let title: String
    let subtitle: String
    var emphasized = true
    var bordered = true
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.appTitle2)
                .foregroundStyle(Theme.Colors.accent)
                .frame(width: 44, height: 44)
                .background(Theme.Colors.spotlight, in: RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Typography.heroTitle)
                Text(subtitle)
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Colors.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            accessory()
        }
        .padding(bordered ? Theme.Metrics.pad : 0)
        .overlay {
            if bordered {
                RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius)
                    .stroke(emphasized ? Theme.Colors.spotlightLine : Theme.Colors.line,
                            lineWidth: emphasized ? 1.5 : 1)
            }
        }
    }
}

/// A download that carries on in the background. nil progress = starting.
struct DownloadRow: View {
    let title: String
    let progress: Double?
    let note: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "arrow.down.circle")
                .font(.appTitle3)
                .foregroundStyle(Theme.Colors.warn)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(progress.map { "\(title)… \(Int($0 * 100))%" } ?? "\(title)…")
                    .font(Theme.Typography.cardTitle)
                ProgressView(value: progress)
                Text(note)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.ink2)
            }
        }
        .padding(Theme.Metrics.popoverPad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.chip, in: RoundedRectangle(cornerRadius: Theme.Metrics.radius))
    }
}

/// A step that can't start yet.
struct PendingRow: View {
    let title: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "circle")
                .font(.appTitle3)
                .frame(width: 24)
            Text(title)
                .font(Theme.Typography.cardTitle)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.Colors.ink3)
        .padding(Theme.Metrics.popoverPad)
    }
}

/// The Whisper model's state, from the engine that owns the download (it
/// outlives the sheet).
struct SpeechDownloadRow: View {
    @Environment(RecordingManager.self) private var recordingManager
    var backup = false

    var body: some View {
        switch recordingManager.transcriptionEngine.modelState {
        case .downloading(let progress):
            DownloadRow(title: backup ? "Downloading backup speech model" : "Downloading speech model",
                        progress: progress,
                        note: "You can keep going. It carries on after this window closes.")
        case .loading:
            DownloadRow(title: "Preparing speech model", progress: nil, note: "Almost done.")
        case .ready:
            PermissionRow(icon: "waveform", askTitle: "", grantedTitle: "Speech model ready",
                          subtitle: "Turns what's said into text on this Mac", isGranted: true, action: {})
        case .error(let message):
            HStack {
                Label(message, systemImage: "xmark.circle")
                    .foregroundStyle(Theme.Colors.stop)
                Button("Retry") {
                    Task {
                        await recordingManager.transcriptionEngine.loadModel(
                            UserDefaults.standard.string(forKey: "whisperModel") ?? "base")
                    }
                }
            }
            .font(Theme.Typography.caption)
        case .notLoaded:
            EmptyView()
        }
    }
}
```

- [ ] **Step 5: Run the tests**

Run: `make test 2>&1 | grep -E "sheet:|^FAIL|ALL PASS|FAILURES"`
Expected: all `PASS`, `ALL PASS`.

- [ ] **Step 6: Commit**

```bash
git add Parrot/Views/Onboarding Parrot/ProfileTest.swift
git commit -m "Onboarding: sheet state model and shared step parts

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: Meet Copilot screen

**Files:**
- Create: `Parrot/Views/Onboarding/MeetCopilotStep.swift`
- Modify: `Parrot/SnapshotTool.swift` (onboarding shots, ~L326)

**Interfaces:**
- Consumes: `StepHeader` (Task 7), `HeroInsightCard`, `InsightCard` (`Views/CopilotPanelView.swift`), `KindResolver.fallbackStyle(forKey:)`, `Insight(kindKey:title:detail:callTime:source:)`
- Produces: `struct MeetCopilotStep: View` (no parameters). Reads `UserDefaults` key `"onboardingStillFrame"` (Bool) to show the last frame without animation.

- [ ] **Step 1: Write the view**

Create `Parrot/Views/Onboarding/MeetCopilotStep.swift`:

```swift
import SwiftUI

/// Shows what Copilot does before anyone chooses how it runs: a short
/// looping example call built from the real card views, and four benefits.
struct MeetCopilotStep: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 0 listening, 1 question heard, 2 answer card, 3 blocker pinned, 4 hold.
    @State private var phase = 0

    /// Reduce Motion, and the help-shot harness, get the finished frame.
    private var stillFrame: Bool {
        reduceMotion || UserDefaults.standard.bool(forKey: "onboardingStillFrame")
    }

    var body: some View {
        VStack(spacing: 18) {
            StepHeader(title: "Meet Copilot",
                       subtitle: "Your helper during calls. It listens and shows you what to say, as it happens.")
            HStack(alignment: .top, spacing: 18) {
                demo
                    .frame(width: 260)
                VStack(alignment: .leading, spacing: 14) {
                    benefit("lightbulb", "Know what to say", "Answers pop up when they ask, from your own documents.")
                    benefit("exclamationmark.triangle", "Catch deal-breakers", "Blockers stay pinned until you handle them.")
                    benefit("gauge.with.needle", "See how it's going", "A live score and one line of coaching.")
                    benefit("doc.text", "Leave with a report", "Summary, action items and a follow-up email.")
                }
            }
            Label("Only you see it. No bot joins your call.", systemImage: "eye.slash")
                .font(Theme.Typography.secondary)
                .padding(.vertical, Theme.Metrics.bannerInsetV)
                .frame(maxWidth: .infinity)
                .background(Theme.Colors.chip, in: RoundedRectangle(cornerRadius: Theme.Metrics.radius))
        }
        .padding(Theme.Metrics.pad)
        .task {
            if stillFrame {
                phase = 3
                return
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.6))
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { phase = (phase + 1) % 5 }
            }
        }
    }

    private var demo: some View {
        let shown = min(phase, 3)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .foregroundStyle(Theme.Colors.accent)
                Text("Copilot")
                    .font(Theme.Typography.cardTitle)
                Spacer(minLength: 0)
                Text("Listening")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.ink2)
            }
            Text(shown >= 1 ? "Them: “Where is our data stored? Security will ask.”" : "Listening to the call…")
                .font(Theme.Typography.secondary)
                .foregroundStyle(Theme.Colors.ink2)
                .fixedSize(horizontal: false, vertical: true)
            if shown >= 2 {
                HeroInsightCard(insight: Self.answer, kindStyle: KindResolver.fallbackStyle(forKey: "suggestion"),
                                isGlowing: false, onJump: {}, onDismiss: {})
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if shown >= 3 {
                InsightCard(insight: Self.blocker, kindStyle: KindResolver.fallbackStyle(forKey: "blocker"),
                            isCollapsed: false, onToggleCollapse: {}, onJump: {}, onDismiss: {})
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Metrics.popoverPad)
        .frame(height: 340, alignment: .top)
        .clipped()
        .background(Theme.Colors.panel, in: RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius))
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Example: they ask where data is stored, Copilot suggests an answer from your security document, then pins a budget blocker.")
    }

    private func benefit(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.appTitle3)
                .foregroundStyle(Theme.Colors.accent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Typography.cardTitle)
                Text(detail)
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Colors.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    static let answer = Insight(
        kindKey: "suggestion", title: "Answer the security question",
        detail: "All audio stays on your Mac. Only the text goes to the AI, and we can sign a DPA this week.",
        callTime: 754, source: "security-faq.pdf")
    static let blocker = Insight(
        kindKey: "blocker", title: "Budget isn't approved until Q3",
        detail: "They can't sign before the new budget. Ask who signs off and when.",
        callTime: 812, source: "Them")
}
```

- [ ] **Step 2: Add a help shot**

In `Parrot/SnapshotTool.swift`, directly after the `onboarding-automatic.png` shot, add:

```swift
        UserDefaults.standard.register(defaults: ["onboardingStillFrame": true])
        shot("onboarding-meet-copilot.png", size: .init(width: 600, height: 620),
             MeetCopilotStep().environment(rm).environment(rm.profileStore))
```

- [ ] **Step 3: Build and look at it**

Run: `make build && .build/release/Parrot --help-shots "$TMPDIR/parrot-shots" | tail -2`, then open `$TMPDIR/parrot-shots/onboarding-meet-copilot.png` with the Read tool.
Expected: title, subtitle, the demo panel with both cards on the left (nothing cut mid-word at the panel's bottom edge except the blocker's last line at most), four benefits on the right, the "Only you see it" strip at the bottom. If the cards don't fit in 340 pt, lower the benefits' spacing to 10 and the demo height to fit, rebuild, and look again.

- [ ] **Step 4: Commit**

```bash
git add Parrot/Views/Onboarding/MeetCopilotStep.swift Parrot/SnapshotTool.swift
git commit -m "Onboarding: Meet Copilot screen with a looping example call

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: "How should Copilot work?" screen

**Files:**
- Create: `Parrot/Views/Onboarding/CopilotPathStep.swift`
- Modify: `Parrot/SnapshotTool.swift`

**Interfaces:**
- Consumes: `OnboardingModel` from the environment (`path`, `pathError`, `mode`, `decideLater()`), `CloudGate.globalKey`, `StepHeader`
- Produces: `struct CopilotPathStep: View` (no parameters; needs `.environment(OnboardingModel)`)

- [ ] **Step 1: Write the view**

Create `Parrot/Views/Onboarding/CopilotPathStep.swift`:

```swift
import SwiftUI

/// Private / Balanced / Cloud, plus Decide later on the full tour.
struct CopilotPathStep: View {
    @Environment(OnboardingModel.self) private var model
    @AppStorage(CloudGate.globalKey) private var onDeviceOnly = false

    var body: some View {
        VStack(spacing: 14) {
            StepHeader(title: "How should Copilot work?",
                       subtitle: "Pick how private you want it. You can change this later.")
            VStack(spacing: 10) {
                card(.private, icon: "lock", title: "Private",
                     detail: "Copilot runs on this Mac. Nothing leaves it. Free. Uses the Ollama app.")
                card(.balanced, icon: "slider.horizontal.3", title: "Balanced",
                     detail: "Audio stays on this Mac. Only text goes to Claude. Smartest answers. Needs a Claude key.",
                     badge: "Recommended")
                card(.cloud, icon: "cloud", title: "Cloud",
                     detail: "Live word-by-word text plus Claude. Needs Deepgram and Claude keys.")
            }
            .frame(maxWidth: 480)
            if onDeviceOnly {
                Text("Balanced and Cloud are off because On-device only is on in Settings → Privacy.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.ink2)
            }
            if model.mode == .full {
                Button("Decide later") { withAnimation { model.decideLater() } }
                    .buttonStyle(.link)
            }
            if let error = model.pathError {
                Text(error)
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Colors.stop)
            }
        }
        .padding(Theme.Metrics.pad)
    }

    private func card(_ path: CopilotPath, icon: String, title: String, detail: String,
                      badge: String? = nil) -> some View {
        let locked = onDeviceOnly && path != .private
        let selected = model.path == path
        let shape = RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius)
        return Button { model.path = path } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.appTitle3)
                    .foregroundStyle(selected ? Theme.Colors.accent : Theme.Colors.ink)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(Theme.Typography.heroTitle)
                        if let badge {
                            Text(badge)
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Colors.accent)
                                .padding(.horizontal, Theme.Metrics.chipInsetH)
                                .padding(.vertical, Theme.Metrics.chipInsetV)
                                .background(Theme.Colors.spotlight, in: Capsule())
                        }
                    }
                    Text(detail)
                        .font(Theme.Typography.secondary)
                        .foregroundStyle(Theme.Colors.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.Colors.accent)
                }
            }
            .padding(Theme.Metrics.popoverPad)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Theme.Colors.spotlight : .clear, in: shape)
            .overlay(shape.stroke(selected ? Theme.Colors.spotlightLine : Theme.Colors.line,
                                  lineWidth: selected ? 1.5 : 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(locked)
        .opacity(locked ? 0.45 : 1)
    }
}
```

- [ ] **Step 2: Add a help shot**

In `Parrot/SnapshotTool.swift`, after the `onboarding-meet-copilot.png` shot, add:

```swift
        UserDefaults.standard.register(defaults: [CopilotPath.defaultsKey: "balanced"])
        shot("onboarding-path.png", size: .init(width: 600, height: 620),
             CopilotPathStep().environment(OnboardingModel()))
```

- [ ] **Step 3: Build and look at it**

Run: `make build && .build/release/Parrot --help-shots "$TMPDIR/parrot-shots" | tail -2`, then Read `$TMPDIR/parrot-shots/onboarding-path.png`.
Expected: three cards, Balanced selected with the Recommended badge and a check, "Decide later" link under them, no text cut off.

- [ ] **Step 4: Commit**

```bash
git add Parrot/Views/Onboarding/CopilotPathStep.swift Parrot/SnapshotTool.swift
git commit -m "Onboarding: Private / Balanced / Cloud choice

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 10: "Set up Copilot" screen (three variants) and the checked key field

**Files:**
- Create: `Parrot/Views/Onboarding/KeyCheckField.swift`
- Create: `Parrot/Views/Onboarding/CopilotSetupStep.swift`
- Modify: `Parrot/SnapshotTool.swift`

**Interfaces:**
- Consumes: `OnboardingModel` (`path`, `mode`, `copilotOn`, `claudeCheck`, `deepgramCheck`, `ollamaModel`, `ollamaModelReady`), `ProviderKeyCheck`, `APIKeyStore.load/save`, `RecordingManager.ollama` / `.ollamaInstaller`, `OllamaCatalog.models` / `.sizeLabel(for:)`, `PermissionRow`, `CopilotHeroCard`, `DownloadRow`, `PendingRow`, `SpeechDownloadRow`, `StepHeader`
- Produces: `struct KeyCheckField: View` (`service`, `label`, `placeholder`, `hint`, `optional`, `result: Binding<ProviderKeyCheck.Outcome?>`), `struct CopilotSetupStep: View`

- [ ] **Step 1: Write the key field**

Create `Parrot/Views/Onboarding/KeyCheckField.swift`:

```swift
import SwiftUI

/// Onboarding's key field. Check key makes one small request, and only a
/// key that works is saved to the Keychain. A key saved earlier is checked
/// on appear, so a returning user doesn't have to press anything.
struct KeyCheckField: View {
    let service: ProviderKeyCheck.Service
    let label: String
    let placeholder: String
    let hint: String
    var optional = false
    @Binding var result: ProviderKeyCheck.Outcome?

    @State private var key = ""
    @State private var checkedKey = ""
    @State private var checking = false
    @State private var empty = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(label)
                    .font(Theme.Typography.cardTitle)
                if optional {
                    Text("(optional)")
                        .font(Theme.Typography.secondary)
                        .foregroundStyle(Theme.Colors.ink3)
                }
            }
            HStack {
                SecureField(placeholder, text: $key, prompt: Text(placeholder))
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: key) {
                        if key != checkedKey { result = nil }
                        empty = false
                    }
                Button(checking ? "Checking…" : "Check key") { Task { await check() } }
                    .disabled(checking)
            }
            status
                .font(Theme.Typography.secondary)
        }
        .task {
            let stored = service.keychainAccount.map { APIKeyStore.load(account: $0) } ?? APIKeyStore.load()
            if let stored, !stored.isEmpty, key.isEmpty {
                key = stored
                await check()
            }
        }
    }

    @ViewBuilder private var status: some View {
        if empty {
            Text("Paste a key first")
                .foregroundStyle(Theme.Colors.stop)
        } else if let message = ProviderKeyCheck.message(result, service) {
            Label(message, systemImage: result == .works ? "checkmark.circle.fill" : "exclamationmark.triangle")
                .foregroundStyle(result == .works ? Theme.Colors.good : Theme.Colors.stop)
        } else {
            Text(hint)
                .foregroundStyle(Theme.Colors.ink2)
        }
    }

    private func check() async {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            empty = true
            return
        }
        checking = true
        checkedKey = key
        let outcome = await ProviderKeyCheck.check(service, key: trimmed)
        checking = false
        result = outcome
        if outcome == .works {
            _ = service.keychainAccount.map { APIKeyStore.save(trimmed, account: $0) } ?? APIKeyStore.save(trimmed)
        }
    }
}
```

- [ ] **Step 2: Write the setup step**

Create `Parrot/Views/Onboarding/CopilotSetupStep.swift`:

```swift
import SwiftUI

/// Gets Copilot running for the chosen path. The Copilot card on top holds
/// the switch; the rows below differ per path.
struct CopilotSetupStep: View {
    @Environment(OnboardingModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 14) {
            StepHeader(title: "Set up Copilot")
            CopilotHeroCard(title: "Copilot", subtitle: heroLine) {
                Toggle("Copilot", isOn: $model.copilotOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            switch model.path {
            case .private?:
                OllamaSetupRows()
            case .balanced?:
                KeyCheckField(service: .claude, label: "Claude API key", placeholder: "sk-ant-…",
                              hint: "Get a key at console.anthropic.com. Saved in your macOS keychain.",
                              result: $model.claudeCheck)
                Text("Claude also writes your after-call reports.")
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Colors.ink2)
            case .cloud?:
                KeyCheckField(service: .claude, label: "Claude API key", placeholder: "sk-ant-…",
                              hint: "Get a key at console.anthropic.com.", result: $model.claudeCheck)
                KeyCheckField(service: .deepgram, label: "Deepgram API key", placeholder: "40-character key",
                              hint: "New accounts get $200 free credit. console.deepgram.com",
                              optional: true, result: $model.deepgramCheck)
                if model.mode == .full { SpeechDownloadRow(backup: true) }
            case .later?, nil:
                EmptyView()  // routing never shows this step without a path
            }
        }
        .frame(maxWidth: 480)
        .padding(Theme.Metrics.pad)
    }

    private var heroLine: String {
        switch model.path {
        case .private?: "Runs on this Mac with Ollama. Private and free."
        case .balanced?: "Uses Claude. Only text is sent, audio never leaves this Mac."
        case .cloud?: "Claude gives answers. Deepgram writes the words live."
        case .later?, nil: ""
        }
    }
}

/// Install Ollama → open it → download the model. Each row turns green on
/// its own: the step polls the server every 1.5 s, like the permission rows.
private struct OllamaSetupRows: View {
    @Environment(OnboardingModel.self) private var model
    @Environment(RecordingManager.self) private var recordingManager

    var body: some View {
        @Bindable var model = model
        let ollama = recordingManager.ollama
        let installer = recordingManager.ollamaInstaller
        let serverUp = ollama.isServerUp
        let appURL = OllamaInstaller.installedAppURL()
        let installed = serverUp || appURL != nil
        VStack(spacing: 8) {
            installRow(installer, installed: installed)
            if serverUp {
                done("Ollama is running")
            } else if installed {
                PermissionRow(icon: "play.fill", askTitle: "Open Ollama", grantedTitle: "",
                              subtitle: "Installed. Open it once so Parrot can find it.") {
                    Task { await installer.openInstalled() }
                }
            } else {
                PendingRow(title: "Open Ollama")
            }
            modelRow(ollama, serverUp: serverUp)
            if let appURL, appURL.path.contains("/Downloads/") {
                HStack {
                    Text("Move Ollama to Applications so it stays put.")
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([appURL]) }
                        .buttonStyle(.link)
                }
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.ink2)
            }
            if case .failed(let why) = installer.state {
                Text(why)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.stop)
                Link("Get it from ollama.com", destination: OllamaInstaller.websiteURL)
                    .font(Theme.Typography.caption)
            } else if !installed {
                Link("Or download it from ollama.com", destination: OllamaInstaller.websiteURL)
                    .font(Theme.Typography.caption)
            }
            if !ollama.isPulling, ollama.status != .ready {
                Picker("Model", selection: $model.ollamaModel) {
                    ForEach(OllamaCatalog.models, id: \.id) { Text($0.label).tag($0.id) }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 360)
            }
        }
        .task(id: model.ollamaModel) {
            while !Task.isCancelled {
                await ollama.refresh(model: model.ollamaModel)
                model.ollamaModelReady = ollama.status == .ready && ollama.model == model.ollamaModel
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    @ViewBuilder
    private func installRow(_ installer: OllamaInstaller, installed: Bool) -> some View {
        if installed {
            done("Ollama installed")
        } else {
            switch installer.state {
            case .downloading(let progress):
                DownloadRow(title: "Downloading Ollama", progress: progress, note: "About 200 MB.")
            case .unpacking, .verifying:
                DownloadRow(title: "Checking the download", progress: nil,
                            note: "Making sure it really comes from Ollama.")
            case .opening, .opened:
                DownloadRow(title: "Opening Ollama", progress: nil, note: "If macOS asks, click Open.")
            case .idle, .failed:
                PermissionRow(icon: "arrow.down.circle", askTitle: "Install Ollama", grantedTitle: "",
                              subtitle: "Free, 200 MB. macOS will ask you to confirm once.") {
                    Task { await installer.install() }
                }
            }
        }
    }

    @ViewBuilder
    private func modelRow(_ ollama: OllamaService, serverUp: Bool) -> some View {
        let name = model.ollamaModel
        let size = OllamaCatalog.sizeLabel(for: name) ?? "size varies"
        let current = ollama.model == name
        if current, case .pulling(let progress) = ollama.status {
            DownloadRow(title: "Downloading \(name)", progress: progress,
                        note: "Keep going. Copilot turns on by itself when it's done.")
        } else if current, ollama.status == .ready {
            done("\(name) is ready")
        } else if serverUp {
            PermissionRow(icon: "arrow.down.circle", askTitle: "Download \(name)", grantedTitle: "",
                          subtitle: "\(size). Runs Copilot on this Mac.") {
                ollama.pull(name)
            }
        } else {
            PendingRow(title: "Download \(name)")
        }
        if current, case .failed(let why) = ollama.status {
            Text(why)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.stop)
        }
    }

    private func done(_ title: String) -> some View {
        PermissionRow(icon: "checkmark", askTitle: "", grantedTitle: title, subtitle: "", isGranted: true, action: {})
    }
}
```

- [ ] **Step 3: Add help shots for the three variants**

In `Parrot/SnapshotTool.swift`, after the `onboarding-path.png` shot, add:

```swift
        for variant in ["private", "balanced", "cloud"] {
            UserDefaults.standard.register(defaults: [CopilotPath.defaultsKey: variant])
            shot("onboarding-setup-\(variant).png", size: .init(width: 600, height: 620),
                 CopilotSetupStep().environment(OnboardingModel()).environment(rm))
        }
```

- [ ] **Step 4: Build and look at all three**

Run: `make build && .build/release/Parrot --help-shots "$TMPDIR/parrot-shots" | tail -2`, then Read `onboarding-setup-private.png`, `onboarding-setup-balanced.png` and `onboarding-setup-cloud.png` in `$TMPDIR/parrot-shots`.
Expected: the Copilot card with its switch on top of each. Private shows the three Ollama rows (which row is dark depends on this Mac; on the dev Mac the Homebrew server may already be running, so rows 1–2 are green) and the model menu. Balanced shows one Claude field with the hint. Cloud shows both fields, Deepgram marked "(optional)". Nothing clipped.

- [ ] **Step 5: Commit**

```bash
git add Parrot/Views/Onboarding/KeyCheckField.swift Parrot/Views/Onboarding/CopilotSetupStep.swift Parrot/SnapshotTool.swift
git commit -m "Onboarding: Set up Copilot for Ollama, Claude, and Claude plus Deepgram

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 11: Move the existing steps into their own files

Pure refactor plus the speech-step changes. The old `Int`-driven sheet keeps working until Task 12.

**Files:**
- Create: `Parrot/Views/Onboarding/WelcomeStep.swift`, `PermissionsStep.swift`, `SpeechModelStep.swift`, `AutomaticStep.swift`
- Modify: `Parrot/Views/OnboardingView.swift`

**Interfaces:**
- Consumes: `MachineFit` (Task 1), `SpeechDownloadRow`, `StepHeader` (Task 7), `ModelOption`, `PermissionRow`
- Produces: `WelcomeStep`, `PermissionsStep`, `SpeechModelStep`, `AutomaticStep` (all parameterless views). `ModelOption` gains `var isRecommended = false`.

- [ ] **Step 1: Welcome**

Create `Parrot/Views/Onboarding/WelcomeStep.swift`:

```swift
import SwiftUI

struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "bird")
                .font(.system(size: 64))
                .foregroundStyle(Theme.Colors.accent)
            Text("Meet Parrot")
                .font(.appLargeTitle)
                .fontWeight(.bold)
            Text("Records your calls, writes everything down,\nand helps you live while you talk.")
                .font(Theme.Typography.sans(14))
                .foregroundStyle(Theme.Colors.ink2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            Spacer()
        }
        .padding(Theme.Metrics.pad)
    }
}
```

- [ ] **Step 2: Permissions (moved as is)**

Create `Parrot/Views/Onboarding/PermissionsStep.swift` with `import SwiftUI` and `import AVFoundation`, and a `struct PermissionsStep: View`. Cut from `Parrot/Views/OnboardingView.swift`, and paste into the struct unchanged, everything from `@State private var micGranted = …` (~L98) to the end of `private var permissionsStep: some View { … }` (~L212): the three `@State` properties, `refreshPermissions()`, `systemAudioSubtitle`, `systemAudioPendingHint`, and `permissionsStep`. Rename `private var permissionsStep: some View` to `var body: some View`.

- [ ] **Step 3: Make it automatic (moved as is)**

Create `Parrot/Views/Onboarding/AutomaticStep.swift` with `import SwiftUI` and a `struct AutomaticStep: View` that needs `@Environment(RecordingManager.self) private var recordingManager`. Cut from `OnboardingView.swift`, and paste unchanged, everything in the `// MARK: - Step 4: Make it automatic` section except `static let stepCount = 5`: the `@AppStorage(AutoRecordMode.defaultsKey)`, `calendarConnecting`, `notifications` and `loginItemOn` properties and `automaticStep`. Rename `private var automaticStep: some View` to `var body: some View`.

- [ ] **Step 4: Speech model, with the memory pick and a short list**

In `OnboardingView.swift`, add `var isRecommended = false` to `ModelOption` below `let isSelected: Bool`, and in its body replace:

```swift
                    Text(TranscriptionEngine.displayName(for: tag))
                        .font(Theme.Typography.cardTitle)
```

with:

```swift
                    HStack(spacing: 6) {
                        Text(TranscriptionEngine.displayName(for: tag))
                            .font(Theme.Typography.cardTitle)
                        if isRecommended {
                            Text("Best for your Mac")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Colors.accent)
                                .padding(.horizontal, Theme.Metrics.chipInsetH)
                                .padding(.vertical, Theme.Metrics.chipInsetV)
                                .background(Theme.Colors.spotlight, in: Capsule())
                        }
                    }
```

Delete the whole `// MARK: - Step 3: Model Download` section from `OnboardingView.swift` (`modelChoices`, `modelStep`, `selectedModel`, `selectModel`, `modelLoadingStatus`). Create `Parrot/Views/Onboarding/SpeechModelStep.swift`:

```swift
import SwiftUI

/// Picks the Whisper model, preselecting what fits this Mac's memory, and
/// starts the download right away. The engine owns the download, so it
/// keeps going after this step or the whole sheet goes away.
struct SpeechModelStep: View {
    @Environment(RecordingManager.self) private var recordingManager
    @AppStorage("whisperModel") private var selectedModel = "base"
    @State private var showAll = false
    private let memoryGB = MachineFit.memoryGB()

    /// Same five the Settings picker offers, same order. Sizes are what the
    /// hub actually serves, not what the folder is called.
    static let modelChoices: [(tag: String, size: String, blurb: String)] = [
        ("tiny", "~40 MB", "Fastest, basic accuracy"),
        ("base", "~140 MB", "Good balance of speed and accuracy"),
        ("small", "~460 MB", "Better accuracy, moderate speed"),
        ("large-v3-v20240930_626MB", "~626 MB", "Near-best accuracy, light on memory"),
        ("large-v3-turbo", "~1.6 GB", "Best accuracy, needs more RAM"),
    ]
    private static let shortList: Set<String> = ["base", "large-v3-v20240930_626MB", "large-v3-turbo"]

    var body: some View {
        let recommended = MachineFit.whisperModel(memoryGB: memoryGB)
        VStack(spacing: 14) {
            StepHeader(title: "Speech to text",
                       subtitle: "Turns what's said into text, right on this Mac.\nYour Mac has \(memoryGB) GB of memory, so we picked:")
            VStack(spacing: 8) {
                ForEach(Self.modelChoices.filter { showAll || Self.shortList.contains($0.tag) || $0.tag == selectedModel },
                        id: \.tag) { choice in
                    ModelOption(tag: choice.tag, size: choice.size, description: choice.blurb,
                                isSelected: selectedModel == choice.tag,
                                isRecommended: choice.tag == recommended,
                                action: { select(choice.tag) })
                }
            }
            .frame(maxWidth: 460)
            if !showAll {
                Button("Show all 5 models") { showAll = true }
                    .buttonStyle(.link)
            }
            SpeechDownloadRow()
                .frame(maxWidth: 460)
        }
        .padding(Theme.Metrics.pad)
        .onAppear {
            if UserDefaults.standard.object(forKey: "whisperModel") == nil {
                select(recommended)
                return
            }
            switch recordingManager.transcriptionEngine.modelState {
            case .notLoaded, .error: select(selectedModel)
            default: break
            }
        }
    }

    private func select(_ tag: String) {
        selectedModel = tag
        let engine = recordingManager.transcriptionEngine
        // Launch already started loading this one; don't restart it.
        // (`where` binds to one pattern only, so each case carries its own.)
        switch engine.modelState {
        case .downloading where engine.loadingModelName == TranscriptionEngine.displayName(for: tag),
             .loading where engine.loadingModelName == TranscriptionEngine.displayName(for: tag):
            return
        default:
            Task { await engine.loadModel(tag) }
        }
    }
}
```

- [ ] **Step 5: Point the old sheet at the new files**

In `OnboardingView.swift`, change the step switch to:

```swift
                switch currentStep {
                case 0: WelcomeStep()
                case 1: PermissionsStep()
                case 2: SpeechModelStep()
                case 3: AutomaticStep()
                case 4: readyStep
                default: WelcomeStep()
                }
```

Delete the `// MARK: - Step 1: Welcome` section. Keep `static let stepCount = 5` (move it next to `@AppStorage("onboardingStep")`), the Ready section, `PermissionRow` and `ModelOption`. Remove `import AVFoundation` if nothing left in the file uses it.

- [ ] **Step 6: Build, test, and compare the shots**

Run: `make test 2>&1 | tail -1 && .build/release/Parrot --help-shots "$TMPDIR/parrot-shots" | tail -1`, then Read `onboarding-permissions.png`, `onboarding-model.png` and `onboarding-automatic.png` in `$TMPDIR/parrot-shots`.
Expected: `ALL PASS`. Permissions and automatic look as before. The model step shows "Speech to text", the memory line, three models with the badge on the right one, "Show all 5 models", and the download row.

- [ ] **Step 7: Commit**

```bash
git add Parrot/Views/Onboarding Parrot/Views/OnboardingView.swift
git commit -m "Onboarding: one file per step; speech step picks by memory and starts at once

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 12: Ready screen and the new sheet

**Files:**
- Create: `Parrot/Views/Onboarding/ReadyStep.swift`
- Modify: `Parrot/Views/OnboardingView.swift` (shell rewrite)
- Modify: `Parrot/Views/AppCommands.swift` (`showWelcomeTour`, new `showCopilotSetup`)
- Modify: `Parrot/SnapshotTool.swift` (onboarding shots block)

**Interfaces:**
- Consumes: everything from Tasks 1–11; `CopilotStatus.current` (Task 2); `RecordingManager.ollama`
- Produces: `struct ReadyStep: View`; `OnboardingView(isPresented:)` unchanged signature; `MeetingActions.showCopilotSetup()`

- [ ] **Step 1: Write the Ready step**

Create `Parrot/Views/Onboarding/ReadyStep.swift`:

```swift
import SwiftUI

/// What's set up, Copilot first. Reads real state, so a download still in
/// flight says so.
struct ReadyStep: View {
    @Environment(OnboardingModel.self) private var model
    @Environment(RecordingManager.self) private var recordingManager
    @AppStorage("copilotEnabled") private var copilotEnabled = false
    @AppStorage(CopilotPathSettings.enableWhenReadyKey) private var enableWhenReady = false
    @AppStorage(TranscriptionBackend.defaultsKey) private var backend = TranscriptionBackend.local.rawValue
    @AppStorage("copilotOllamaModel") private var ollamaModel = "llama3.2:3b"
    @State private var hasClaudeKey = false
    @State private var celebrate = false

    var body: some View {
        let ollama = recordingManager.ollama
        let status = CopilotStatus.current(
            copilotEnabled: copilotEnabled, path: model.path, enableWhenReady: enableWhenReady,
            ollamaPulling: ollama.isPulling, ollamaProgress: ollama.pullProgress, hasClaudeKey: hasClaudeKey)
        let copy = Self.copy(status, path: model.path, ollamaModel: ollamaModel)
        VStack(spacing: 16) {
            Text("🎉")
                .font(.system(size: 56))
                .scaleEffect(celebrate ? 1.0 : 0.4)
                .opacity(celebrate ? 1 : 0)
            StepHeader(title: model.mode == .copilot ? "Copilot is set up" : "Ready to go",
                       subtitle: "Downloads keep going after you close this.")
            CopilotHeroCard(title: copy.title, subtitle: copy.detail, emphasized: status == .on) {
                if status == .on {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.appTitle2)
                        .foregroundStyle(Theme.Colors.good)
                }
            }
            if model.mode == .full {
                if backend == TranscriptionBackend.deepgram.rawValue {
                    PermissionRow(icon: "waveform", askTitle: "", grantedTitle: "Live text: Deepgram",
                                  subtitle: "The speech model on this Mac is the backup", isGranted: true, action: {})
                }
                SpeechDownloadRow()
            }
        }
        .frame(maxWidth: 480)
        .padding(Theme.Metrics.pad)
        .onAppear {
            hasClaudeKey = APIKeyStore.load() != nil
            withAnimation(.spring(response: 0.4, dampingFraction: 0.55).delay(0.05)) { celebrate = true }
        }
    }

    static func copy(_ status: CopilotStatus, path: CopilotPath?, ollamaModel: String) -> (title: String, detail: String) {
        switch status {
        case .on where path == .private:
            ("Copilot is on, running on this Mac", "\(ollamaModel). Nothing leaves your Mac.")
        case .on:
            ("Copilot is on, using Claude", "Only text is sent.")
        case .waitingForModel(let progress):
            ("Copilot turns on when \(ollamaModel) finishes",
             progress.map { "\(Int($0 * 100))% downloaded. Keep going." } ?? "Starting the download.")
        case .finishOllama:
            ("Copilot is almost there", "Finish the Ollama setup from the card on Home.")
        case .needsClaudeKey:
            ("Copilot needs a working Claude key", "Add it from the card on Home.")
        case .off:
            ("Copilot is off for now", "Set it up any time from the card on Home.")
        }
    }
}
```

- [ ] **Step 2: Rewrite the sheet shell**

In `Parrot/Views/OnboardingView.swift`, replace everything from `struct OnboardingView: View {` down to (not including) `// MARK: - Permission Row` with:

```swift
struct OnboardingView: View {
    @Binding var isPresented: Bool
    /// Rebuilt each time the sheet is presented, so it reads the current
    /// mode (full tour or Set up Copilot) and saved step.
    @State private var model = OnboardingModel()

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch model.step {
                case .welcome: WelcomeStep()
                case .permissions: PermissionsStep()
                case .meetCopilot: MeetCopilotStep()
                case .copilotPath: CopilotPathStep()
                case .speechModel: SpeechModelStep()
                case .copilotSetup: CopilotSetupStep()
                case .automatic: AutomaticStep()
                case .ready: ReadyStep()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .environment(model)

            Divider()

            HStack {
                if !model.isFirst {
                    Button("Back") { withAnimation { model.move(-1) } }
                        .buttonStyle(.plain)
                }
                Spacer()
                HStack(spacing: 6) {
                    ForEach(model.steps, id: \.self) { step in
                        Circle()
                            .fill(step == model.step ? Theme.Colors.accent : Theme.Colors.chip)
                            .frame(width: 8, height: 8)
                    }
                }
                Spacer()
                if model.isLast {
                    // Dismissal marks completion: the app-side binding writes
                    // hasCompletedOnboarding when this flips to false.
                    Button(model.mode == .copilot ? "Done" : "Let's start") {
                        model.finish()
                        isPresented = false
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Continue") { withAnimation { model.move(1) } }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(Theme.Metrics.pad)
        }
        .frame(width: 600, height: 680)
    }
}

```

This removes the old `@AppStorage("onboardingStep")`, `stepCount`, `@Environment(RecordingManager.self)` and the old Ready section. Keep `PermissionRow` and `ModelOption` below.

- [ ] **Step 3: Tour entry points write step names**

In `Parrot/Views/AppCommands.swift`, replace `showWelcomeTour()` (~L101–L107) with:

```swift
    /// Re-runs first-run onboarding. ParrotApp's sheet is derived from the
    /// hasCompletedOnboarding key, so clearing it presents the tour right
    /// away — no relaunch. Mode and step go first so the flip lands on them.
    static func showWelcomeTour() {
        UserDefaults.standard.set(OnboardingMode.full.rawValue, forKey: OnboardingMode.defaultsKey)
        UserDefaults.standard.set(OnboardingStep.welcome.rawValue, forKey: OnboardingFlow.stepKey)
        UserDefaults.standard.set(false, forKey: "hasCompletedOnboarding")
    }

    /// The short tour from Home or Settings: Meet Copilot → path → setup → Ready.
    static func showCopilotSetup() {
        UserDefaults.standard.set(OnboardingMode.copilot.rawValue, forKey: OnboardingMode.defaultsKey)
        UserDefaults.standard.set(OnboardingStep.meetCopilot.rawValue, forKey: OnboardingFlow.stepKey)
        UserDefaults.standard.set(false, forKey: "hasCompletedOnboarding")
    }
```

- [ ] **Step 4: Help shots of the real sheet**

In `Parrot/SnapshotTool.swift`:
1. In the first `UserDefaults.standard.register(defaults: [...])` of `HelpShots.run`, replace the `"onboardingStep": 2,` entry and its comment with `"onboardingStillFrame": true,`.
2. Replace the whole onboarding block, from the comment `// Onboarding, real sheet geometry (500x600)` through the per-variant `onboarding-setup-` loop added in Task 10, with:

```swift
        // Onboarding, real sheet geometry (600x680): if a step ever outgrows
        // it, these shots show the clipping before a user does. Repeated
        // register(defaults:) calls replace the keys, picking step and path.
        func onboarding(_ file: String, _ step: OnboardingStep, path: CopilotPath? = nil) {
            UserDefaults.standard.register(defaults: [
                OnboardingMode.defaultsKey: OnboardingMode.full.rawValue,
                OnboardingFlow.stepKey: step.rawValue,
                CopilotPath.defaultsKey: path?.rawValue ?? "",
            ])
            shot(file, size: .init(width: 600, height: 680),
                 OnboardingView(isPresented: .constant(true))
                    .environment(rm).environment(rm.profileStore)
                    .modelContainer(container))
        }
        onboarding("onboarding-permissions.png", .permissions)
        onboarding("onboarding-meet-copilot.png", .meetCopilot)
        onboarding("onboarding-path.png", .copilotPath, path: .balanced)
        onboarding("onboarding-model.png", .speechModel, path: .balanced)
        onboarding("onboarding-setup-private.png", .copilotSetup, path: .private)
        onboarding("onboarding-setup-balanced.png", .copilotSetup, path: .balanced)
        onboarding("onboarding-setup-cloud.png", .copilotSetup, path: .cloud)
        onboarding("onboarding-automatic.png", .automatic)
        onboarding("onboarding-ready.png", .ready, path: .balanced)
```

- [ ] **Step 5: Build, test, look at every screen**

Run: `make test 2>&1 | tail -1 && .build/release/Parrot --help-shots "$TMPDIR/parrot-shots" | tail -1`, then Read each `onboarding-*.png` in `$TMPDIR/parrot-shots`.
Expected: `ALL PASS`. Every shot is 600×680 with the Back / dots / Continue footer visible and nothing clipped. The dots count matches the path (8 for balanced and private, 7 for cloud). Ready shows "Copilot is on, using Claude" (the harness registers `copilotEnabled: true`).

- [ ] **Step 6: Try it for real**

Run: `make run`. In Parrot choose Help → Show Welcome Tour and click through: Continue on "How should Copilot work?" without a pick shows "Pick one to continue"; Decide later jumps to Speech to text; Back works everywhere; Let's start closes the sheet. Quit Parrot on the Meet Copilot step, reopen it: the sheet comes back on Meet Copilot.

- [ ] **Step 7: Commit**

```bash
git add Parrot/Views/Onboarding/ReadyStep.swift Parrot/Views/OnboardingView.swift Parrot/Views/AppCommands.swift Parrot/SnapshotTool.swift
git commit -m "Onboarding: new 600x680 sheet with Copilot steps, named steps and a real Ready screen

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 13: Home card and the Settings entry points

**Files:**
- Create: `Parrot/Views/CopilotHomeCard.swift`
- Modify: `Parrot/Views/DashboardView.swift` (body, under `recordButton`)
- Modify: `Parrot/Views/SettingsView.swift` (General "Welcome tour" row ~L268; Copilot page ~L500)
- Modify: `Parrot/SnapshotTool.swift` (one shot before the final `print`)

**Interfaces:**
- Consumes: `CopilotStatus` and `CopilotPathSettings` keys (Task 2), `RecordingManager.ollama`, `CopilotHeroCard` (Task 7), `MeetingActions.showCopilotSetup()` / `showWelcomeTour()` (Task 12)
- Produces: `struct CopilotHomeCard: View`

- [ ] **Step 1: Write the card**

Create `Parrot/Views/CopilotHomeCard.swift`:

```swift
import SwiftUI

/// On Home when Copilot is off or half set up: why it's worth it and a way
/// back into setup. Also says "Copilot is on" once, right after it switched
/// itself on when the Ollama model finished. The close button hides the
/// nudge for good; Settings → Copilot keeps the same button.
struct CopilotHomeCard: View {
    @Environment(RecordingManager.self) private var recordingManager
    @AppStorage("copilotEnabled") private var copilotEnabled = false
    @AppStorage(CopilotPath.defaultsKey) private var pathRaw = ""
    @AppStorage(CopilotPathSettings.enableWhenReadyKey) private var enableWhenReady = false
    @AppStorage(CopilotPathSettings.cardDismissedKey) private var dismissed = false
    @AppStorage(CopilotPathSettings.justTurnedOnKey) private var justTurnedOn = false
    @AppStorage("copilotOllamaModel") private var ollamaModel = "llama3.2:3b"
    @State private var hasClaudeKey = false

    var body: some View {
        let ollama = recordingManager.ollama
        let status = CopilotStatus.current(
            copilotEnabled: copilotEnabled, path: CopilotPath(rawValue: pathRaw), enableWhenReady: enableWhenReady,
            ollamaPulling: ollama.isPulling, ollamaProgress: ollama.pullProgress, hasClaudeKey: hasClaudeKey)
        Group {
            if CopilotStatus.showsHomeCard(status, dismissed: dismissed, justTurnedOn: justTurnedOn) {
                card(status)
            }
        }
        .onAppear { hasClaudeKey = APIKeyStore.load() != nil }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            hasClaudeKey = APIKeyStore.load() != nil
        }
    }

    @ViewBuilder
    private func card(_ status: CopilotStatus) -> some View {
        switch status {
        case .on:
            CopilotHeroCard(title: "Copilot is on",
                            subtitle: "It opens beside your next call and shows answers as they ask.") {
                closeButton { justTurnedOn = false }
            }
        case .waitingForModel(let progress):
            CopilotHeroCard(title: "Copilot turns on when \(ollamaModel) finishes",
                            subtitle: progress.map { "\(Int($0 * 100))% downloaded" } ?? "Starting the download",
                            emphasized: false) {
                ProgressView(value: progress)
                    .frame(width: 90)
            }
        case .finishOllama, .needsClaudeKey, .off:
            nudge(status)
        }
    }

    private func nudge(_ status: CopilotStatus) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius)
        return VStack(alignment: .leading, spacing: 12) {
            CopilotHeroCard(title: status == .off ? "Turn on Copilot" : "Finish setting up Copilot",
                            subtitle: reason(status), bordered: false) {
                closeButton { dismissed = true }
            }
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lightbulb")
                    .foregroundStyle(Theme.Colors.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("They ask about security. Copilot suggests:")
                        .foregroundStyle(Theme.Colors.ink2)
                    Text("“All audio stays on your Mac. Only the text goes to the AI.”")
                }
                .font(Theme.Typography.secondary)
            }
            .padding(Theme.Metrics.popoverPad)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Colors.chip, in: RoundedRectangle(cornerRadius: Theme.Metrics.radius))
            HStack(spacing: 10) {
                Button("Set up Copilot") { MeetingActions.showCopilotSetup() }
                    .buttonStyle(.borderedProminent)
                Text("Takes about 2 minutes")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.ink2)
            }
        }
        .padding(Theme.Metrics.pad)
        .overlay(shape.stroke(Theme.Colors.spotlightLine, lineWidth: 1.5))
    }

    private func reason(_ status: CopilotStatus) -> String {
        switch status {
        case .finishOllama: "Finish the Ollama setup to turn it on."
        case .needsClaudeKey: "It needs a working Claude key."
        default: "Suggested answers, pinned deal-breakers and a live call score, while you talk."
        }
    }

    private func closeButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .foregroundStyle(Theme.Colors.ink3)
        }
        .buttonStyle(.plain)
        .help("Hide")
        .accessibilityLabel("Hide")
    }
}
```

- [ ] **Step 2: Show it on Home**

In `Parrot/Views/DashboardView.swift`, in `body`, directly after:

```swift
                recordButton
                    .padding(.top, 44)
```

add:

```swift
                CopilotHomeCard()
```

- [ ] **Step 3: Settings entry points**

In `Parrot/Views/SettingsView.swift`:

1. General page, the "Welcome tour" row (~L268): change the detail to `"The first-run tour: permissions, Copilot and speech model."` and the button to:

```swift
                    Button("Show Welcome Tour") {
                        MeetingActions.showWelcomeTour()
                        // The tour is a sheet on the main window; get out of its way.
                        if !isEmbedded { NSApp.keyWindow?.performClose(nil) }
                    }
```

2. Copilot page, in `SettingsCard(title: "Live Call Copilot")`, between the `SettingsToggleRow(...)` and the "Call profiles" row, add:

```swift
                SettingsLabeledRow(title: "Guided setup", detail: "Pick Private, Balanced or Cloud and get Copilot running.") {
                    Button("Set up Copilot") {
                        MeetingActions.showCopilotSetup()
                        if !isEmbedded { NSApp.keyWindow?.performClose(nil) }
                    }
                }
```

- [ ] **Step 4: Help shot of the card**

In `Parrot/SnapshotTool.swift`, directly before `print("help-shots: wrote …")`, add:

```swift
        // Home card as a new user who chose Decide later sees it. Last,
        // because it flips copilotEnabled off for everything after it.
        UserDefaults.standard.register(defaults: ["copilotEnabled": false, CopilotPath.defaultsKey: "later"])
        shot("home-copilot-card.png", size: .init(width: 600, height: 260),
             CopilotHomeCard().environment(rm).padding(Theme.Metrics.pad))
```

- [ ] **Step 5: Build, test, look**

Run: `make test 2>&1 | tail -1 && .build/release/Parrot --help-shots "$TMPDIR/parrot-shots" | tail -1`, then Read `$TMPDIR/parrot-shots/home-copilot-card.png` and `settings-copilot.png`.
Expected: `ALL PASS`. The card says "Turn on Copilot" with the sample suggestion, "Set up Copilot" and "Takes about 2 minutes". Settings → Copilot shows the "Guided setup" row.

- [ ] **Step 6: Try it for real**

Run: `make run`. With Copilot off in Settings → Copilot, Home shows the card. Click Set up Copilot: the sheet opens on Meet Copilot with 4 dots, no Decide later link. Pick Balanced, then close with Done. Close the card with ✕: it stays gone after relaunch; Settings → Copilot → Set up Copilot still opens the short tour and closes the Settings window.

- [ ] **Step 7: Commit**

```bash
git add Parrot/Views/CopilotHomeCard.swift Parrot/Views/DashboardView.swift Parrot/Views/SettingsView.swift Parrot/SnapshotTool.swift
git commit -m "Copilot: Home card to finish setup later, and Set up Copilot in Settings

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 14: Docs, file map, Xcode project, and end-to-end checks

**Files:**
- Modify: `docs/help/getting-started.html`, `docs/help/copilot-setup.html`, `FILEMAP.md`
- Regenerate: `Parrot.xcodeproj` (via `make xcode`), `docs/help/img/*.png` (via help shots)

- [ ] **Step 1: Regenerate the screenshots into the help folder**

Run: `make build && .build/release/Parrot --help-shots docs/help/img | tail -1`
Expected: `help-shots: wrote N → …/docs/help/img`, with the new `onboarding-meet-copilot.png`, `onboarding-path.png`, `onboarding-setup-*.png`, `onboarding-ready.png` and `home-copilot-card.png` among them.

- [ ] **Step 2: Update Getting started**

In `docs/help/getting-started.html`, replace the whole `<h2>Pick a model</h2>` section (from that heading up to, not including, `<h2>That's all</h2>`) with:

```html
<h2>Meet Copilot</h2>
<img src="img/onboarding-meet-copilot.png" alt="The Meet Copilot step: an example call and four benefits">
<p>Next, a short example of what Copilot does during a call: when the other
side asks something, it suggests an answer from your own documents, pins
deal-breakers until you handle them, keeps a live score, and writes a report
after. Only you see it; no bot joins your call.</p>

<h2>Choose how Copilot works</h2>
<img src="img/onboarding-path.png" alt="Private, Balanced and Cloud choices">
<ul>
  <li><strong>Private.</strong> Everything stays on your Mac and it's free.
  Parrot installs the Ollama app for you (about 200 MB; macOS asks you to
  confirm once) and downloads a model. You can keep going while it
  downloads; Copilot turns on by itself when it's done.</li>
  <li><strong>Balanced.</strong> Recommended. Audio stays on your Mac, only
  the text goes to Claude. Paste a Claude key and press Check key.</li>
  <li><strong>Cloud.</strong> Deepgram writes the words live and Claude runs
  Copilot. Needs both keys; Deepgram is optional.</li>
</ul>
<p>Not sure yet? Pick <strong>Decide later</strong>. A card on Home lets you
set Copilot up any time, and so does Settings → Copilot → Set up Copilot.</p>

<h2>Speech to text</h2>
<img src="img/onboarding-model.png" alt="The speech model picker">
<p>Transcription happens on your Mac with Whisper. Parrot picks the model
that fits your Mac's memory and starts downloading it right away:
<strong>Large V3 Turbo</strong> on Macs with 12 GB or more,
<strong>Base</strong> on smaller ones. <strong>Large V3 Turbo
Compressed</strong> is the in-between: nearly the accuracy of the big one at
a third of the download. The download carries on after you close the setup
window, and the record button waits until it's done. After that,
transcription works offline.</p>

<p>You can switch models any time in Settings → Transcription.</p>
```

- [ ] **Step 3: Update Copilot setup**

In `docs/help/copilot-setup.html`, directly after `<h2>Three ways to power it</h2>`, insert:

```html
<p>The quickest way is the guided setup: Settings → Copilot → Set up
Copilot, or the Copilot card on Home. It walks you through Private (Ollama on
your Mac, installed for you), Balanced (Claude, audio stays on your Mac) or
Cloud (Claude plus Deepgram), and checks your keys before saving them.</p>
```

and in the Ollama bullet replace `Install <a href="https://ollama.com">Ollama</a> yourself, then
  pick a model in Parrot's settings.` with `The guided setup installs
  <a href="https://ollama.com">Ollama</a> for you, or install it yourself and
  pick a model in Parrot's settings.`

- [ ] **Step 4: Update the file map**

Run `wc -l` on each new or changed file below, then in `FILEMAP.md`:
- Replace the `Views/OnboardingView.swift` row's purpose with `Setup sheet shell: step routing, footer, 600×680; PermissionRow, ModelOption`.
- Replace the `Views/OllamaModelStatusView.swift` row's purpose with `Settings → Copilot model status, a thin view over OllamaService`.
- Add rows (line counts from `wc -l`), keeping the table's column format:
  - `Models/OnboardingFlow.swift` · `Setup steps per mode and path, named-step migration, memory-based model picks`
  - `Services/CopilotSetupState.swift` · `Settings each Copilot path writes, auto-enable when the Ollama model lands, Copilot status for Ready and Home`
  - `Services/ProviderKeyCheck.swift` · `One-request Claude and Deepgram key checks`
  - `Services/OllamaService.swift` · `App-wide Ollama server state and the one model pull; resumes at launch`
  - `Services/OllamaInstaller.swift` · `Downloads, unpacks, signature-checks and opens the official Ollama app`
  - `Views/Onboarding/*.swift` · `One file per setup step, plus OnboardingModel (sheet state) and OnboardingParts (shared rows and cards)`
  - `Views/CopilotHomeCard.swift` · `Home card: turn on Copilot, finish setup, waiting for the model, just turned on`

- [ ] **Step 5: Regenerate the Xcode project and run everything**

Run: `make xcode && make test 2>&1 | tail -1`
Expected: `ALL PASS`.

- [ ] **Step 6: End-to-end checks in the signed app**

Run `make`, then open `dist/Parrot.app`. For each scenario, start from Help → Show Welcome Tour:

1. **Private, no Ollama running:** quit Ollama (and `brew services stop ollama` if the Homebrew one runs). Install Ollama from the sheet: progress, macOS "Open?" prompt, row goes green. Download the model; close the sheet with Let's start mid-download. Home shows "Copilot turns on when … finishes" with progress; when it ends, "Copilot is on" and Settings → Copilot shows Copilot enabled with Ollama.
2. **Balanced:** a wrong key shows "That key didn't work…"; a real one shows "Key works"; after Let's start, Settings → Copilot is on with Claude.
3. **Cloud:** with a Deepgram key, Ready shows "Live text: Deepgram"; record 20 seconds of a video call; words stream in.
4. **Decide later:** Home card "Turn on Copilot" → Set up Copilot → short tour → Done.
5. **Quit mid speech-model download:** pick Large V3 Turbo on a Mac without it cached, quit during the download, reopen: the download restarts or resumes (note which) and finishes.

Write down anything that failed and fix it before committing. If the sandbox blocks unzipping or opening Ollama from Downloads (scenario 1), the fallback link must still work; note it in the PR.

- [ ] **Step 7: Commit**

```bash
git add docs/help FILEMAP.md Parrot.xcodeproj
git commit -m "Docs: new onboarding and guided Copilot setup; file map; Xcode project

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
