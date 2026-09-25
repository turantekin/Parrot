---
name: release-docs
description: Get Parrot's user-facing docs ready for a release. Finds what changed since the last vX.Y.Z tag, updates docs/help (the one source for the in-app Help, openparrot.app/help and GitHub Pages) and the README, drafts the release notes in the house style, and lists what the website should add. Use before every Parrot release, and whenever the user says release, ship, publish, "what's new", release notes, changelog, or asks to document new features, even if they only asked for the release itself.
---

# Release docs

Features kept shipping without docs: speaker naming shipped in 0.16 and had
no help page until 0.21. This runs before `scripts/release.sh`, so every
release carries its own explanation. Work through the steps in order; each
ends with something concrete.

## 1. What changed, as a user would notice it

```bash
git fetch -q --tags origin
LAST=$(git describe --tags --abbrev=0 --match 'v*' origin/master)
git log "$LAST"..origin/master --no-merges --oneline
gh pr list --state merged --base master --limit 30 --json number,title,mergedAt,body
```

Also read the latest entries in `docs/IMPROVEMENT-ROADMAP.md` (Progress log).
Make a short table: change, user-facing or not, and where a user meets it
(screen, setting, menu, notification). Harness, CI, refactors and internal
fixes are not user-facing; a behaviour fix users would notice is.

## 2. Help pages: docs/help

`docs/help` is the only copy. `scripts/assemble-help.sh` bundles it into the
app at build time, the site's daily "Help sync" workflow copies it to
openparrot.app/help from the newest release tag, and GitHub Pages forwards
there. So write it here, and commit it to master before tagging.

For each user-facing change, search the pages for its on-screen words
(`grep -il "<label>" docs/help/*.html`). If it's missing, add it where someone
would look for it:

| Page | Covers |
|---|---|
| recording.html | starting, call detection, calendar, marking moments, consent, stopping |
| call-screen.html, transcript.html | the live screen, the transcript |
| reports.html | the report, receipts, who said what, moments you marked |
| connections.html | exports, Obsidian, email, Reminders, webhook, MCP |
| privacy.html | what leaves the Mac, on-device only, redaction, clean-up |
| settings.html | one line per settings page, linking to the page with the detail |
| ask.html, import.html, knowledge.html, profiles.html, troubleshooting.html | as named |

Write like the pages already do: second person, short plain sentences, the
benefit first. Put on-screen labels in `<strong>` and copy them exactly from
the Swift source, because people search for what they see. No em-dashes.
Add new search words to the page's `<meta name="keywords">` (the in-app Help
search uses them). A new page also needs a link from `index.html`.

Screenshots: `swift build && .build/debug/Parrot --help-shots "$(mktemp -d)"`,
then copy a shot into `docs/help/img` only if its visible part changed and
it looks right. The bare binary has no permissions, so a calendar card reads
"No access"; keep the old shot when the new one looks worse. Finally, every
`img/` reference must exist and `grep -c "—" docs/help/*.html` must be 0.

## 3. README (the repo's front page)

Check each section against the change table: "What it does", "And all the
everyday stuff", Privacy, Keyboard shortcuts (from `keyboardShortcut` in
`Parrot/Views/AppCommands.swift`), the wishlist (tick what shipped) and Known
issues. The user guide link is https://openparrot.app/help. No em-dashes.

## 4. Release notes

Match the last two releases (`gh release view v0.21.0 --json name,body`):

- Title `Parrot X.Y.Z: <short tagline>`, with a colon, never an em-dash.
- One lede sentence on what this release is about.
- One paragraph per feature, starting with a **bold lead-in**, then what the
  user gets and where to find it. Plain English, no internal names.
- A **Fixed** list for bugs users could have hit.
- A line on new permissions or downloads, then: "Requires macOS 14 or later
  on Apple Silicon. Existing installs will offer the update within a day."

Save it as `dist/notes-X.Y.Z.md` for `scripts/publish.sh`, with the
title as its first line (`# Parrot X.Y.Z: <short tagline>`): publish.sh makes
that line the release title, which the website's "New in" pill shows. By
hand, `gh release create --title "..." --notes-file` does the same.

## 5. What the website should add: ask the user

The home page is the user's pitch, so they choose. Read
`~/Scripts/parrot-site/content.ts` (read-only from here) to see the current
sections, then propose, per user-facing change, one of:

- **Headline**: changes why someone would download or trust Parrot. Its own
  section or a tab in the hero demo.
- **Existing section**: say which (Copilot, Knowledge, Profiles, Brains,
  Names, Report, Privacy).
- **Everyday tile**: useful but small.
- **FAQ**: answers a question a new visitor would ask.
- **Wait**: experimental, off by default or not finished.

Rank by how much it changes why someone would download or trust Parrot, and
give a one-line reason each. Leave out download buttons, version labels,
/changelog and help: those update on their own.

**Show the table and stop. Wait for the user to agree or change it.** Don't
move on until they have. Then save it as `dist/site-plan-X.Y.Z.md` (`dist/`
is ignored, so it never lands in this public repo):

```markdown
# Site plan for Parrot X.Y.Z

| Feature | Where | Why |
|---|---|---|
| Ask Parrot (⌘K) | Headline: new hero demo tab | A new reason to download |
| Live speaker labels | Wait | Experimental, off by default |

Notes: anything the user asked for, such as wording to use or avoid.
```

`scripts/publish.sh` passes this file to the site's "Site draft" workflow,
which writes the copy exactly as planned and opens a draft PR in
parrot-site. No plan file, no draft: the site then waits for a chat in
`~/Scripts/parrot-site` with `/after-release`.

## 6. Hand off

Commit the help and README changes and get them onto master before running
`scripts/release.sh <version>`: the website copies help from the release tag.
Then publish and refresh `/Applications/Parrot.app`:

```bash
scripts/publish.sh X.Y.Z dist/notes-X.Y.Z.md dist/site-plan-X.Y.Z.md
```

Run it from master (or the same steps by hand from a worktree). It starts the
site's help sync and, with the plan, the site draft; both end as PRs in
parrot-site for the user to merge.
