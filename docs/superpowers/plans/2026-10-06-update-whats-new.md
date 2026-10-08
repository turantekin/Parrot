# Telling People About Updates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Existing users learn that an update is waiting (a notification with Restart now) and what it brought (a one-time "What's new" card on Home, and the same notes in Sparkle's update window), all from one `WhatsNew.swift` the release refuses to ship without.

**Architecture:** `WhatsNew` is a pure value (`current` plus rules and an HTML renderer). The Home card reads it; `release.sh` asks the release binary for its HTML (`--whats-new-html X.Y.Z`, exit 1 on a version mismatch) and drops it next to the DMG, where `generate_appcast` embeds it. `AppUpdater` becomes Sparkle's delegate: on `willInstallUpdateOnQuit` it keeps the install-now block and posts one notification (held while a call records); `CallWatcher`'s notification delegate routes **Restart now** back to it. `RecordingManager` creates the updater at launch and tells it when a call stops.

**Tech Stack:** Swift 5.9+, SwiftUI (macOS 14), Sparkle 2.9.5 (`SPUUpdaterDelegate`), UserNotifications, bash (`scripts/release.sh`).

**Spec:** `docs/superpowers/specs/2026-10-06-update-whats-new-design.md`

## Global Constraints

- macOS 14+, no new packages; build with `swift build`/Makefile; tests are `--profile-test` checks in `Parrot/ProfileTest.swift`. Quick loop: `swift build 2>&1 | grep -E "error:|Build complete" && .build/debug/Parrot --profile-test | grep -E "^FAIL|whats new|update notice|ALL PASS|FAILURES"`.
- Views style only through `Theme`; match the surrounding literal spacing idiom.
- Exact copy: "Parrot X.Y.Z is perched and ready" · "It moves in next time you quit Parrot. Or right now, if you can't wait." · "Restart now" · "Finish your call first. Parrot will be right here." · "Read the full story" · "Got it". No em-dashes anywhere.
- Changelog link: `https://openparrot.app/changelog#vX.Y.Z`.
- `UNUserNotificationCenter.current()` crashes in the bare harness binary: never touch it when `Bundle.main.bundleIdentifier` is nil.
- No real customer, person or meeting names in code, tests or docs (Acme/Northwind).
- Never run a dev build against the owner's real store; verification uses the throwaway-bundle recipe (memory: parrot-real-app-test-on-store-copy).
- Commit after each task; messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **A fresh install, then onboarding finishes.** The new user must never get a "What's new" card for the version they just installed. Test: Task 2, "whats new: a fresh install is marked seen before onboarding ends".
2. **An update lands mid-call.** No notification during the recording; it goes out when the call stops. Test: Task 3, "update notice: held while recording, posted when it stops".
3. **Restart now tapped while recording.** Nothing installs. Test: Task 3, "update notice: restart refused while recording".
4. **A release whose WhatsNew is for another version, or breaks the copy rules.** `release.sh` stops before notarizing. Tests: Task 1, "whats new: html refuses another version" and "…refuses broken copy"; Task 4 dry run.
5. **Highlights with `<`, `&` or quotes.** Sparkle's window must show them as text, not markup. Test: Task 1, "whats new: html escapes text".

---

### Task 1: The WhatsNew value, its rules, and `--whats-new-html`

**Files:**
- Create: `Parrot/Services/WhatsNew.swift`
- Modify: `Parrot/ParrotApp.swift` (flag, next to `--snapshot`)
- Test: `Parrot/ProfileTest.swift` (`testWhatsNew`, add to `run()`)

**Interfaces:**
- Produces: `struct WhatsNew: Equatable { let version: String; let headline: String; let highlights: [String] }` with `static let current`, `static let sample`, `static let seenKey = "whatsNewSeenVersion"`, `var hasNews: Bool`, `var changelogURL: URL`, `var copyProblems: [String]`, `func html() -> String`, `static func escape(_:) -> String`, `static func shouldShowCard(running:news:seen:onboarded:) -> Bool`, `static func seenAfterLaunch(running:seen:onboarded:) -> String`, `static func printHTML(for:news:) -> Int32`.

- [ ] **Step 1: Write the failing test**

```swift
    static func testWhatsNew() {
        let news = WhatsNew(version: "0.28.0", headline: "Fresh feathers! Parrot 0.28.0",
                            highlights: ["Folders for your documents.", "Calls stay smooth on long days."])
        let quiet = WhatsNew(version: "0.28.0", headline: "", highlights: [])
        check("whats new: shows after an update", WhatsNew.shouldShowCard(running: "0.28.0", news: news, seen: "0.27.0", onboarded: true))
        check("whats new: the first release with the card shows it too", WhatsNew.shouldShowCard(running: "0.28.0", news: news, seen: "", onboarded: true))
        check("whats new: not twice", !WhatsNew.shouldShowCard(running: "0.28.0", news: news, seen: "0.28.0", onboarded: true))
        check("whats new: never for another version", !WhatsNew.shouldShowCard(running: "0.28.1", news: news, seen: "", onboarded: true))
        check("whats new: a quiet release shows nothing", !WhatsNew.shouldShowCard(running: "0.28.0", news: quiet, seen: "", onboarded: true))
        check("whats new: never before onboarding ends", !WhatsNew.shouldShowCard(running: "0.28.0", news: news, seen: "", onboarded: false))
        check("whats new: a fresh install is marked seen before onboarding ends",
              WhatsNew.seenAfterLaunch(running: "0.28.0", seen: "", onboarded: false) == "0.28.0"
                && WhatsNew.seenAfterLaunch(running: "0.28.0", seen: "0.27.0", onboarded: true) == "0.27.0")

        check("whats new: links the changelog entry", news.changelogURL.absoluteString == "https://openparrot.app/changelog#v0.28.0")
        let html = news.html()
        check("whats new: html has the headline, list and link",
              html.contains("<h3>Fresh feathers! Parrot 0.28.0</h3>") && html.contains("<li>Folders for your documents.</li>")
                && html.contains("href=\"https://openparrot.app/changelog#v0.28.0\">Read the full story</a>"))
        check("whats new: html is a fragment Sparkle embeds", !html.lowercased().contains("<body") && !html.lowercased().contains("doctype"))
        check("whats new: html escapes text",
              WhatsNew(version: "1", headline: "A & B", highlights: ["<b>x</b>", "\"y\""]).html().contains("A &amp; B")
                && WhatsNew(version: "1", headline: "A", highlights: ["<b>x</b>", "\"y\""]).html().contains("&lt;b&gt;x&lt;/b&gt;"))
        check("whats new: a quiet release has no html", quiet.html().isEmpty)

        check("whats new: good copy passes", news.copyProblems.isEmpty && quiet.copyProblems.isEmpty)
        check("whats new: copy rules catch em-dashes, counts and length",
              !WhatsNew(version: "1", headline: "A — B", highlights: ["x", "y"]).copyProblems.isEmpty
                && !WhatsNew(version: "1", headline: "A", highlights: ["only one"]).copyProblems.isEmpty
                && !WhatsNew(version: "1", headline: "A", highlights: ["a", "b", "c", "d", "e"]).copyProblems.isEmpty
                && !WhatsNew(version: "1", headline: "A", highlights: [String(repeating: "x", count: 91), "b"]).copyProblems.isEmpty
                && !WhatsNew(version: "1", headline: "", highlights: ["a", "b"]).copyProblems.isEmpty)
        check("whats new: the shipped entry follows the rules", WhatsNew.current.copyProblems.isEmpty && WhatsNew.sample.copyProblems.isEmpty)

        check("whats new: html refuses another version", WhatsNew.printHTML(for: "0.27.9", news: news) == 1)
        check("whats new: html refuses broken copy",
              WhatsNew.printHTML(for: "1", news: WhatsNew(version: "1", headline: "A", highlights: ["one"])) == 1)
        check("whats new: html for the right version", WhatsNew.printHTML(for: "0.28.0", news: quiet) == 0)
    }
```

(The last check prints nothing: a quiet release.)

- [ ] **Step 2: Run to verify it fails**

Run: `swift build 2>&1 | grep -E "error:|Build complete"`
Expected: `cannot find 'WhatsNew' in scope`.

- [ ] **Step 3: Implement `Parrot/Services/WhatsNew.swift`**

```swift
import Foundation

/// What the release brings, in a few lines: the "What's new" card on Home
/// after updating and the notes in Sparkle's update window both read it.
/// /release-docs rewrites `current` for every release, and release.sh
/// refuses one whose version it doesn't name (`--whats-new-html`).
struct WhatsNew: Equatable {
    let version: String
    /// One light line, e.g. "Fresh feathers! Parrot 0.28.0".
    let headline: String
    /// Two to four one-liners in the user's terms; empty = a quiet release.
    let highlights: [String]

    /// The entry for the version being released. Empty highlights until the
    /// next release writes its own: no card, no notes.
    static let current = WhatsNew(version: "0.27.0", headline: "", highlights: [])

    /// For the help shot and the harness.
    static let sample = WhatsNew(
        version: "0.28.0", headline: "Fresh feathers! Parrot 0.28.0",
        highlights: [
            "Folders for your documents, with one Use for setting each.",
            "Calls stay smooth, even with years of meetings saved.",
            "Search finds Görüşme when you type gorusme.",
        ])

    /// The last version whose card was closed ("" before the first one).
    static let seenKey = "whatsNewSeenVersion"

    var hasNews: Bool { !highlights.isEmpty }

    /// The version's entry on the website changelog (each release has an anchor).
    var changelogURL: URL { URL(string: "https://openparrot.app/changelog#v\(version)")! }

    /// Home shows the card once, only for the version it describes, and
    /// never to someone still in the welcome tour.
    static func shouldShowCard(running: String, news: WhatsNew, seen: String, onboarded: Bool) -> Bool {
        onboarded && news.hasNews && news.version == running && seen != running
    }

    /// A fresh install starts with its version marked seen, so finishing
    /// onboarding never pops "What's new" at someone who is new to all of it.
    static func seenAfterLaunch(running: String, seen: String, onboarded: Bool) -> String {
        onboarded ? seen : running
    }

    /// Sparkle embeds this next to the update: no DOCTYPE or body, text escaped.
    func html() -> String {
        guard hasNews else { return "" }
        let items = highlights.map { "<li>\(Self.escape($0))</li>" }.joined()
        return "<h3>\(Self.escape(headline))</h3><ul>\(items)</ul>"
            + "<p><a href=\"\(changelogURL.absoluteString)\">Read the full story</a></p>"
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// The copy rules the release enforces.
    var copyProblems: [String] {
        var problems: [String] = []
        if ([headline] + highlights).contains(where: { $0.contains("—") }) { problems.append("no em-dashes") }
        if !(highlights.isEmpty || (2...4).contains(highlights.count)) { problems.append("0, or 2 to 4 highlights") }
        if highlights.contains(where: { $0.count > 90 }) { problems.append("each highlight 90 characters at most") }
        if hasNews && headline.isEmpty { problems.append("a headline") }
        return problems
    }

    /// `--whats-new-html X.Y.Z`, for release.sh: the fragment on stdout (nothing
    /// for a quiet release) and 0, or why not on stderr and 1.
    static func printHTML(for version: String, news: WhatsNew = .current) -> Int32 {
        guard news.version == version else {
            FileHandle.standardError.write(Data("WhatsNew.swift is written for \(news.version), not \(version).\n".utf8))
            return 1
        }
        guard news.copyProblems.isEmpty else {
            FileHandle.standardError.write(Data("WhatsNew.swift needs: \(news.copyProblems.joined(separator: ", ")).\n".utf8))
            return 1
        }
        let html = news.html()
        if !html.isEmpty { print(html) }
        return 0
    }
}
```

In `Parrot/ParrotApp.swift`, before the `--snapshot` branch:

```swift
        if let i = args.firstIndex(of: "--whats-new-html"), i + 1 < args.count {
            exit(WhatsNew.printHTML(for: args[i + 1]))
        }
```

Add `testWhatsNew()` to `run()` (before the `print(failures == 0 ...)` line).

- [ ] **Step 4: Run the tests**

Run: `swift build 2>&1 | grep -E "error:|Build complete" && .build/debug/Parrot --profile-test | grep -E "^FAIL|whats new|ALL PASS|FAILURES"` and `.build/debug/Parrot --whats-new-html 0.27.0; echo "exit $?"` and `.build/debug/Parrot --whats-new-html 9.9.9; echo "exit $?"`
Expected: all `whats new:` PASS, `ALL PASS`; `exit 0` with no output; `WhatsNew.swift is written for 0.27.0, not 9.9.9.` and `exit 1`.

- [ ] **Step 5: Commit**

```bash
git add Parrot/Services/WhatsNew.swift Parrot/ParrotApp.swift Parrot/ProfileTest.swift
git commit -m "What's new: one value for the card and Sparkle's notes, with the release flag

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: The "What's new" card on Home

**Files:**
- Create: `Parrot/Views/WhatsNewCard.swift`
- Modify: `Parrot/Views/DashboardView.swift` (under `recordButton`), `Parrot/Views/ContentView.swift` (`.onAppear`), `Parrot/SnapshotTool.swift` (help shot)

**Interfaces:**
- Consumes: Task 1's `WhatsNew` (`current`, `sample`, `seenKey`, `shouldShowCard`, `seenAfterLaunch`, `changelogURL`).
- Produces: `struct WhatsNewCard: View { let news: WhatsNew; let onClose: () -> Void }`.

- [ ] **Step 1: The card**

```swift
import SwiftUI

/// Home, once per version after an update: the release's headline, a few
/// highlights, and the changelog entry for the rest. Fresh installs never
/// see it (WhatsNew.seenAfterLaunch).
struct WhatsNewCard: View {
    let news: WhatsNew
    let onClose: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CopilotHeroCard(title: news.headline, subtitle: "Here's what changed since you last looked.",
                            bordered: false) { EmptyView() }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(news.highlights, id: \.self) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "sparkle")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.accent)
                        Text(line)
                            .font(Theme.Typography.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            HStack(spacing: Theme.Metrics.controlGap) {
                Button("Read the full story") {
                    openURL(news.changelogURL)
                    onClose()
                }
                .buttonStyle(.borderedProminent)
                Button("Got it", action: onClose)
            }
        }
        .padding(Theme.Metrics.pad)
        .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius).stroke(Theme.Colors.spotlightLine, lineWidth: 1.5))
    }
}
```

- [ ] **Step 2: Show it on Home, mark fresh installs**

`DashboardView`: add

```swift
    @AppStorage(WhatsNew.seenKey) private var whatsNewSeen = ""
    @AppStorage("hasCompletedOnboarding") private var onboarded = false
```

and in `body`, between `recordButton.padding(.top, 44)` and `CopilotHomeCard()`:

```swift
                if WhatsNew.shouldShowCard(running: AppUpdater.currentVersion, news: .current,
                                           seen: whatsNewSeen, onboarded: onboarded) {
                    WhatsNewCard(news: .current) { whatsNewSeen = AppUpdater.currentVersion }
                }
```

`ContentView`: add `@AppStorage(WhatsNew.seenKey) private var whatsNewSeen = ""` and `@AppStorage("hasCompletedOnboarding") private var onboarded = false`, and extend the existing `.onAppear { open(appSession.pendingJump) }` to:

```swift
        .onAppear {
            open(appSession.pendingJump)
            // A fresh install marks its version seen before the tour ends.
            whatsNewSeen = WhatsNew.seenAfterLaunch(running: AppUpdater.currentVersion,
                                                    seen: whatsNewSeen, onboarded: onboarded)
        }
```

- [ ] **Step 3: Help shot**

In `SnapshotTool.swift`'s `HelpShots.run`, after the settings shots:

```swift
        shot("whats-new-card.png", size: .init(width: 640, height: 260),
             WhatsNewCard(news: .sample) {}.padding(Theme.Metrics.pad).background(Theme.Colors.canvas))
```

- [ ] **Step 4: Render and look**

```bash
SHOTS=$(mktemp -d); swift build 2>&1 | grep -E "error:|Build complete"
.build/debug/Parrot --help-shots "$SHOTS" >/dev/null && cp "$SHOTS/whats-new-card.png" "$SHOTS/light.png"
.build/debug/Parrot --help-shots "$SHOTS" --dark >/dev/null && cp "$SHOTS/whats-new-card.png" "$SHOTS/dark.png"; echo "$SHOTS"
```

Open both: headline, subtitle, three highlights with sparkles, the two buttons, no clipping; readable in dark. `make test` (or the quick loop): ALL PASS.

- [ ] **Step 5: Commit**

```bash
git add Parrot/Views/WhatsNewCard.swift Parrot/Views/DashboardView.swift Parrot/Views/ContentView.swift Parrot/SnapshotTool.swift
git commit -m "What's new: the Home card after an update, never on a fresh install

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: "Update waiting" notification and Restart now

**Files:**
- Modify: `Parrot/Services/AppUpdater.swift`, `Parrot/Services/CallWatcher.swift` (categories + route), `Parrot/Services/RecordingManager.swift` (`prepare`, `stopRecording`)
- Test: `Parrot/ProfileTest.swift` (`testUpdateNotice`)

**Interfaces:**
- Produces on `AppUpdater`: `init(startSparkle: Bool)`, `var isBusy: () -> Bool`, `func updateReady(version: String, install: @escaping () -> Void)`, `func recordingStopped()`, `func restartNow()`, `private(set) var postedVersion: String?`, `private(set) var lastNoticeBody: String?`, `static let readyCategory`, `static let restartAction`; `enum UpdateNotice` (`title(version:)`, `body`, `busyBody`, `Action { post, hold, skip }`, `onReady(version:alreadyPosted:busy:)`).

- [ ] **Step 1: Write the failing test**

```swift
    @MainActor
    static func testUpdateNotice() {
        check("update notice: the title", UpdateNotice.title(version: "0.28.0") == "Parrot 0.28.0 is perched and ready")
        check("update notice: posts when free", UpdateNotice.onReady(version: "0.28.0", alreadyPosted: nil, busy: false) == .post)
        check("update notice: waits during a call", UpdateNotice.onReady(version: "0.28.0", alreadyPosted: nil, busy: true) == .hold)
        check("update notice: once per version", UpdateNotice.onReady(version: "0.28.0", alreadyPosted: "0.28.0", busy: false) == .skip)

        var recording = true
        var installed = 0
        let updater = AppUpdater(startSparkle: false)
        updater.isBusy = { recording }
        updater.updateReady(version: "0.28.0") { installed += 1 }
        check("update notice: held while recording, posted when it stops", updater.postedVersion == nil)
        updater.restartNow()
        check("update notice: restart refused while recording",
              installed == 0 && updater.lastNoticeBody == UpdateNotice.busyBody)
        recording = false
        updater.recordingStopped()
        check("update notice: held notice goes out when the call stops", updater.postedVersion == "0.28.0")
        updater.restartNow()
        check("update notice: restart installs when free", installed == 1)
    }
```

Add `testUpdateNotice()` to `run()`.

- [ ] **Step 2: Run to verify it fails**

Run: `swift build 2>&1 | grep -E "error:|Build complete"`
Expected: `cannot find 'UpdateNotice' in scope` / `argument passed to call that takes no arguments`.

- [ ] **Step 3: Implement**

Replace `Parrot/Services/AppUpdater.swift` with:

```swift
import Sparkle
import UserNotifications

/// The words and the one decision behind "an update is waiting".
enum UpdateNotice {
    static func title(version: String) -> String { "Parrot \(version) is perched and ready" }
    static let body = "It moves in next time you quit Parrot. Or right now, if you can't wait."
    static let busyBody = "Finish your call first. Parrot will be right here."

    enum Action: Equatable { case post, hold, skip }

    /// Tell now, wait for the call to end, or stay quiet (already told).
    static func onReady(version: String, alreadyPosted: String?, busy: Bool) -> Action {
        if alreadyPosted == version { return .skip }
        return busy ? .hold : .post
    }
}

/// Self-updating, via Sparkle.
///
/// Sparkle fetches the appcast (SUFeedURL), verifies every update against our
/// EdDSA public key (SUPublicEDKey), downloads in the background and installs
/// on quit, through its installer XPC service (the two mach-lookup exceptions
/// in the entitlements). A recording is never interrupted: Sparkle only swaps
/// the bundle when the app quits, and Restart now refuses during a call.
///
/// As the updater's delegate it tells people an update is waiting: Sparkle's
/// silent mode shows nothing, and Parrot is an app people rarely quit.
@MainActor
final class AppUpdater: NSObject, SPUUpdaterDelegate {
    static let shared = AppUpdater(startSparkle: true)

    static let readyCategory = "PARROT_UPDATE_READY"
    static let restartAction = "PARROT_RESTART_NOW"

    /// nil in unbundled dev builds and the harness: no feed, no network.
    private var controller: SPUStandardUpdaterController?
    /// Set at launch by RecordingManager: true while a call records.
    var isBusy: () -> Bool = { false }
    /// The downloaded update waiting for a quit, and Sparkle's install-now handle.
    private var pending: (version: String, install: () -> Void)?
    private(set) var postedVersion: String?
    private(set) var lastNoticeBody: String?

    init(startSparkle: Bool) {
        super.init()
        guard startSparkle, Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
    }

    /// Menu and Settings both land here. Sparkle owns the whole conversation,
    /// including the "you're already up to date" case.
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    /// False in dev builds, so UI can hide controls that would do nothing.
    var isAvailable: Bool { controller != nil }

    /// Whether updates install themselves. Bound to the Settings toggle: on by
    /// default (Info.plist SUAutomaticallyUpdate), because an update nobody
    /// clicks is an update nobody gets.
    var automaticallyUpdates: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? false }
        set { controller?.updater.automaticallyDownloadsUpdates = newValue }
    }

    /// The running bundle's version. "dev" for an unbundled binary — the
    /// version row, the sidebar footer and bug reports all read this.
    nonisolated static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    // MARK: - Update waiting

    /// Sparkle downloaded an update and will install it on quit. Returning
    /// true takes over telling the user (and pauses further checks until the
    /// next launch, which is fine: this one installs on quit either way).
    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        let version = item.displayVersionString
        MainActor.assumeIsolated { updateReady(version: version, install: immediateInstallHandler) }
        return true
    }

    func updateReady(version: String, install: @escaping () -> Void) {
        pending = (version, install)
        if UpdateNotice.onReady(version: version, alreadyPosted: postedVersion, busy: isBusy()) == .post {
            postReady(version)
        }
    }

    /// RecordingManager calls this when a call stops: a held notice goes out.
    func recordingStopped() {
        guard let pending,
              UpdateNotice.onReady(version: pending.version, alreadyPosted: postedVersion, busy: false) == .post
        else { return }
        postReady(pending.version)
    }

    /// The notification's Restart now. Never during a call.
    func restartNow() {
        guard let pending else { return }
        if isBusy() {
            notify(id: "parrot-update-busy", title: UpdateNotice.title(version: pending.version),
                   body: UpdateNotice.busyBody, category: nil)
            return
        }
        pending.install()
    }

    private func postReady(_ version: String) {
        postedVersion = version
        notify(id: "parrot-update-ready", title: UpdateNotice.title(version: version),
               body: UpdateNotice.body, category: Self.readyCategory)
    }

    /// Posts like CallWatcher does. The bare harness binary has no bundle and
    /// UNUserNotificationCenter would crash there, so it only records the body.
    private func notify(id: String, title: String, body: String, category: String?) {
        lastNoticeBody = body
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let category { content.categoryIdentifier = category }
        Task {
            let center = UNUserNotificationCenter.current()
            do {
                guard try await center.requestAuthorization(options: [.alert, .sound]) else { return }
                try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
            } catch {
                NSLog("Parrot: update notification failed, \(error.localizedDescription)")
            }
        }
    }
}
```

`CallWatcher.start()`: add a fourth category to the `setNotificationCategories` array (it replaces the whole set):

```swift
            UNNotificationCategory(identifier: AppUpdater.readyCategory, actions: [
                UNNotificationAction(identifier: AppUpdater.restartAction, title: "Restart now", options: []),
            ], intentIdentifiers: [], options: []),
```

`CallWatcher.route(action:category:)`: add a case before the others:

```swift
        case AppUpdater.restartAction:
            AppUpdater.shared.restartNow()
```

`RecordingManager.prepare(modelContext:)`, right after `callWatcher.start()`:

```swift
        // Starts Sparkle at launch (not only when Settings opens) and keeps
        // Restart now away from a running call.
        AppUpdater.shared.isBusy = { [weak self] in self?.isRecording ?? false }
```

`RecordingManager.stopRecording()`, right after `isRecording = false`:

```swift
        AppUpdater.shared.recordingStopped()
```

- [ ] **Step 4: Run the tests**

Run: `swift build 2>&1 | grep -E "error:|Build complete" && .build/debug/Parrot --profile-test | grep -E "^FAIL|update notice|ALL PASS|FAILURES"`
Expected: all `update notice:` PASS, `ALL PASS`. Also `grep -rn "AppUpdater()" Parrot` returns nothing (every caller uses `.shared`).

- [ ] **Step 5: Commit**

```bash
git add Parrot/Services/AppUpdater.swift Parrot/Services/CallWatcher.swift Parrot/Services/RecordingManager.swift Parrot/ProfileTest.swift
git commit -m "Updates: a notification when one is waiting, with Restart now (never mid-call)

Also starts Sparkle at launch instead of on first use of Settings.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: The release pipeline

**Files:**
- Modify: `scripts/release.sh` (after `swift build`; before `generate_appcast`), `.claude/skills/release-docs/SKILL.md`

**Interfaces:**
- Consumes: Task 1's `--whats-new-html X.Y.Z` (stdout fragment / exit 1).

- [ ] **Step 1: The gate and the notes file**

In `scripts/release.sh`, right after `swift build -c release --force-resolved-versions`:

```bash
# The "What's new" card and the notes in Sparkle's update window come from
# Parrot/Services/WhatsNew.swift. A release it doesn't describe would tell
# nobody anything, so stop here, before notarizing (see /release-docs).
echo "==> checking WhatsNew.swift is written for $VERSION"
WHATS_NEW_HTML="$(.build/release/Parrot --whats-new-html "$VERSION")" || {
  echo "!! Update Parrot/Services/WhatsNew.swift for $VERSION first." >&2; exit 1; }
```

Right before `"$GENERATE_APPCAST" \` (inside the `if [ -x ... ]` block):

```bash
  # Sparkle embeds an HTML fragment named like the DMG as this update's notes.
  [ -n "$WHATS_NEW_HTML" ] && printf '%s\n' "$WHATS_NEW_HTML" > "$DIST/Parrot-$VERSION.html"
```

and change `--full-release-notes-url "https://github.com/turantekin/Parrot/releases"` to `--full-release-notes-url "https://openparrot.app/changelog"`.

- [ ] **Step 2: Prove the gate**

Run: `SKIP_NOTARIZE=1 scripts/release.sh 9.9.9 2>&1 | tail -3; echo "exit ${PIPESTATUS[0]}"`
Expected: `WhatsNew.swift is written for 0.27.0, not 9.9.9.`, `!! Update Parrot/Services/WhatsNew.swift for 9.9.9 first.`, exit 1, and `git status --short docs/ dist/ 2>/dev/null` shows nothing new (it stopped before touching them).

- [ ] **Step 3: /release-docs step**

In `.claude/skills/release-docs/SKILL.md`, add after section 4:

```markdown
## 4b. What's new: Parrot/Services/WhatsNew.swift

Existing users see this once on Home after the update, and in Sparkle's
update window. Rewrite `WhatsNew.current` for this release: `version`, a
`headline` with at most one light bird pun ("Fresh feathers! Parrot X.Y.Z",
"Parrot learned a few new tricks"), and two to four `highlights`, each one
line of 90 characters or fewer, in the user's words, drawn from the release
notes. A bug-fix-only release can stay quiet: `highlights: []`. No jokes about
recordings, privacy, or fixes that touched someone's data; no em-dashes.
`release.sh` refuses to run until this names the version and passes
`make test`. Commit it with the help and README changes.
```

- [ ] **Step 4: Commit**

```bash
git add scripts/release.sh .claude/skills/release-docs/SKILL.md
git commit -m "Release: refuse a version WhatsNew doesn't describe; embed its notes in the appcast

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Verify in a real bundle, file map, PR

**Files:**
- Modify (TEMP, removed in this task): `Parrot/Views/ContentView.swift`
- Modify: `FILEMAP.md`

- [ ] **Step 1: TEMP hook**

In `ContentView`, add a TEMP `.task` (env-gated, removed in Step 4):

```swift
        // TEMP(update-notice): fake a downloaded update, remove before commit.
        .task {
            guard let v = ProcessInfo.processInfo.environment["PARROT_TEMP_FAKE_UPDATE"] else { return }
            try? await Task.sleep(for: .seconds(5))
            AppUpdater.shared.updateReady(version: v) { NSLog("TEMP install requested") }
        }
```

- [ ] **Step 2: Run it in the throwaway bundle**

Build release, assemble the throwaway bundle `com.uygar.parrot.updatetest` (unsandboxed, ad-hoc signed, scratch `CFFIXED_USER_HOME`, onboarding marked done) as in the memory recipe, and run:
`CFFIXED_USER_HOME=<scratch> PARROT_TEMP_FAKE_UPDATE=0.28.0 <bundle>/Contents/MacOS/Parrot 2>&1 | tee <scratch>/run.log`
Expected: the notification "Parrot 0.28.0 is perched and ready" appears (macOS may ask once to allow notifications for the throwaway bundle: the owner clicks Allow); its **Restart now** prints `TEMP install requested` in the log. Then quit, delete the throwaway defaults domain and scratch home.

- [ ] **Step 3: File map**

Add rows: `Services/WhatsNew.swift` ("What's new for the release: Home card + Sparkle notes; copy rules; `--whats-new-html` for release.sh"), `Views/WhatsNewCard.swift` ("Home card once per version after an update"); update `Services/AppUpdater.swift` ("…; Sparkle delegate: update-waiting notification, Restart now (never mid-call), started at launch"), `Services/CallWatcher.swift` (mention the update category), `scripts/release.sh` row in "Build & non-source" ("…; refuses a version WhatsNew doesn't describe; embeds its notes"). Refresh line counts.

- [ ] **Step 4: Remove TEMP, full tests, commit, PR**

Remove the TEMP block (`grep -rn "TEMP(update-notice)\|PARROT_TEMP" Parrot` empty), `make test` → ALL PASS, commit FILEMAP, push `feat/whats-new`, open the PR (plain punctuation, no em-dashes, test counts, the card screenshots, and the owner's live check after the next release: the notification and the card on their own Mac).
