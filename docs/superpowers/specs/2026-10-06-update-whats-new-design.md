# Telling people about updates: design

Date: 2026-10-06.
Status: **approved in brainstorming, not built.** Base: master at `ef4aee4`
(0.27.0 + help fix). Branch `feat/whats-new`.

## 1. Problem

Parrot updates itself with Sparkle: a daily check, a background download,
and an install when the user quits (`SUAutomaticallyUpdate` is on). In that
mode Sparkle shows nothing, so:

- **Nobody is told an update is waiting.** Parrot is an app people leave
  open all day (menu bar, call detection, open at login), so a downloaded
  update can sit for days before anyone quits.
- **Nobody sees what's new.** The appcast item carries no release notes,
  only a `fullReleaseNotesLink` to the GitHub releases list. The notes live
  on GitHub and openparrot.app, where existing users rarely look.

## 2. Decisions (with the owner)

| Question | Choice |
|---|---|
| What to build | **All three**: a "What's new" card after updating, a notification when an update is waiting, release notes in Sparkle's own window |
| Tone | **A tiny bit funny**: at most one light joke per message, usually a bird pun; the rest plain. No jokes about recordings, privacy, or fixes that touched someone's data |
| "Read more" goes to | **The version's entry on the website changelog**: `https://openparrot.app/changelog#vX.Y.Z` (each release already has `id={tag}` there) |

## 3. Behaviour

### 3.1 Update waiting: a notification

- Sparkle calls `updater(_:willInstallUpdateOnQuit:immediateInstallationBlock:)`
  when an automatically downloaded update is set to install on quit.
  `AppUpdater` becomes the updater delegate and returns **true** (Parrot
  handles telling the user), keeping the `immediateInstallationBlock`.
- Parrot posts **one** notification per version:
  - title: "Parrot X.Y.Z is perched and ready"
  - body: "It moves in next time you quit Parrot. Or right now, if you can't wait."
  - action button: **Restart now**, which calls the kept block (install and relaunch).
- **Never during a call.** If an update lands while recording, the notice
  waits and is posted when the recording stops. If **Restart now** is
  tapped while recording, nothing installs and a second notification says
  "Finish your call first. Parrot will be right here."
- Notifications off: nothing is posted; the card (3.2) still tells the story
  after the next quit.
- Trade-off of returning true (from Sparkle's header): further update cycles
  pause until the app restarts, and Sparkle's own week-later reminder is
  skipped. Acceptable: the update still installs on quit, the next launch
  checks again, and our notification replaces the reminder.
- Automatic updates turned off in Settings: this callback never fires;
  Sparkle shows its normal window, which now carries the notes (3.3).

### 3.2 After updating: a "What's new" card on Home

- Shown when the running version equals `WhatsNew.current.version`, it has
  highlights, and it hasn't been seen (`@AppStorage("whatsNewSeenVersion")`
  differs).
- **Fresh installs never see it**: while onboarding isn't finished, the
  current version is marked seen. Existing users who update see it, also
  the first time this feature ships (the key is empty, onboarding is done).
- Placement: the first card under the record button on Home, above the
  Assistant card, in the same card style (`CopilotHomeCard`'s look).
- Content: the headline (e.g. "Fresh feathers! Parrot X.Y.Z"), two to four
  one-line highlights, and two buttons: **Read the full story** (opens the
  changelog anchor) and **Got it** (marks it seen). Opening the link also
  marks it seen.
- A version mismatch (the app was released without a matching `WhatsNew`)
  shows no card, never stale news. `release.sh` prevents that (3.4).

### 3.3 In Sparkle's window: the same notes

- `release.sh` writes `dist/Parrot-X.Y.Z.html` (same basename as the DMG)
  before running `generate_appcast`. An HTML fragment without DOCTYPE or
  body tags is embedded automatically as the item's `<description>`.
- The fragment holds the headline, the highlights as a list, and a
  **Read the full story** link to the changelog anchor. Text is HTML-escaped.
- Seen via **Check for Updates…** or by people with automatic updates off.

### 3.4 One source, and the release gate

- `Parrot/Services/WhatsNew.swift`: a value type with `version`, `headline`,
  `highlights: [String]`, `changelogURL` (derived from the version), plus
  `static let current`. Pure helpers decide whether the card shows and
  render the HTML.
- `Parrot --whats-new-html X.Y.Z` (harness-style flag in `ParrotApp`):
  if `WhatsNew.current.version` isn't `X.Y.Z` it prints why and exits 1;
  otherwise it prints the HTML fragment (nothing when highlights are empty)
  and exits 0.
- `release.sh` runs it with the version being released: exit 1 **stops the
  release** with that message (update `WhatsNew.swift`); empty output writes
  no HTML file. Empty highlights are allowed: no card, no notes, an explicit
  quiet release.
- `/release-docs` gains a step: write `WhatsNew.current` (headline plus 2 to 4
  highlights drawn from the release notes, tone rules above) and commit it
  with the docs, before `release.sh`.

## 4. Copy

Exact strings (UI text short, plain English, at most one pun per message):

| Where | Text |
|---|---|
| Notification title | Parrot X.Y.Z is perched and ready |
| Notification body | It moves in next time you quit Parrot. Or right now, if you can't wait. |
| Notification action | Restart now |
| Busy notification | Finish your call first. Parrot will be right here. |
| Card buttons | Read the full story · Got it |
| Card headline (per release, in WhatsNew) | e.g. "Fresh feathers! Parrot 0.28.0" |

No em-dashes anywhere. Highlights: each one line, under about 90
characters, in the user's terms (what they get, where to find it).

## 5. Pieces

- `Services/WhatsNew.swift` (new): the value, `current`, `shouldShowCard(...)`, `html()`.
- `Services/AppUpdater.swift`: becomes `SPUUpdaterDelegate`; keeps the pending version and install block; posts the notices; `restartNow()` with the recording check; `recordingStopped()` posts a held notice.
- `Services/CallWatcher.swift`: its single `setNotificationCategories` call gains the update category; its notification delegate routes **Restart now** to `AppUpdater`.
- `Services/RecordingManager.swift`: tells `AppUpdater` when recording stops, and is how `AppUpdater` learns a call is in progress (a closure set at launch, no new dependency between services).
- `Views/WhatsNewCard.swift` (new): the Home card. `Views/DashboardView.swift`: shows it.
- `ParrotApp.swift`: `--whats-new-html`.
- `scripts/release.sh`: the version gate and the HTML file before `generate_appcast`.
- `.claude/skills/release-docs/SKILL.md`: the new step.

## 6. Testing

- `--profile-test`: card logic (fresh install, updated, already seen, version mismatch, empty highlights); HTML (escaping, the anchor URL, no DOCTYPE/body); copy rules (no em-dashes, 0 or 2 to 4 highlights, each under the length limit); the busy rule (no install while recording).
- Card rendered offscreen in light and dark (snapshot harness), checked for clipping.
- `release.sh` gate: a mismatched version stops it (dry run with `SKIP_NOTARIZE=1`).
- End to end, once: an older signed build pointed at a local test appcast downloads a newer build, the notification appears, **Restart now** relaunches into the new version, and the card shows once.

## 7. Out of scope

Re-notifying an ignored update, a history of past "What's new" entries in
the app, fetching notes from the network, localising the copy.
