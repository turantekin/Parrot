# Profiles 2.0 (Copilot + Report): Share, Suggest, Gallery: Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a call profile a complete playbook (what the Copilot flags live **and** what the end-of-call report looks like), and make it portable. One file format (`.parrotprofile`) carries a profile between Macs, from Claude into Parrot, and later from a public gallery and marketplace, without ever carrying anyone's meeting data or loosening privacy.

**Why:** Profiles are Parrot's most powerful feature and the hardest to set up (persona, what to flag live, trigger rules, mood meters). Claude is very good at writing them, and people who've tuned a great "Enterprise sales" or "Investor pitch" profile want to share it. Once shared profiles exist, they're a growth loop: a gallery, then a marketplace.

**Depends on:** `docs/superpowers/plans/2026-09-26-ai-apps-connect.md` (launch release: Claude can already *read* profiles via `list_profiles` / `get_profile`, and `get_profile` already emits the format below).

**Tech Stack:** Swift 5.10+, SwiftData (`CallProfile`), `ProfileStore`, `ProfilesSettingsView`, `--profile-test` harness, Makefile Info.plist substitution for the document type and URL scheme.

## Decisions (settled 2026-09-26)

1. **Claude suggests, you approve.** Claude never changes a profile directly. It sends a suggestion; Parrot shows what would change; the user applies or discards; undo is always there.
2. **Export/import ships together with Claude suggestions**, in the release right after the Claude launch. Same file, same review screen.
3. **The gallery lives on openparrot.app**, and the owner approves every submission.
4. **Paid profiles:** the format leaves room; the decision comes much later.
5. **Privacy rule:** an imported or suggested profile can make things **more** private, never less.
6. **Report templates per profile.** Each profile defines its report sections and its coaching lens; today's fixed report becomes the Default template. Built after the Claude launch, as part of this Profiles 2.0 release.
7. **Scorecards** (criteria scored 1-5 with evidence from the call) ship in the same release.
8. **"Rewrite report with a different profile"** ships in the same release.
9. **Existing users (migration):** Copilot settings are never touched. Built-ins the user never edited switch to their new report format by default (announced once, "classic report" one click away). Tuned built-ins and user-made profiles keep the classic report and get an offer. Past meetings keep their reports; upgrading one is a manual **Rewrite report**, never a bulk rewrite.

## Where reports stand today (checked 2026-09-26)

The profile only reaches the report through `counterpart` and `tone` (passed as standing instructions, `RecordingManager.generateSummary` ~L788). Structure is fixed in `AnalysisProvider.summarySystemPrompt` (Overview, Pain points, Key points, Next steps) and `coachingSystemPrompt` ("You are a sales/meeting coach": Call snapshot, What went well, What to improve, Objections & questions, Commitments & follow-ups), for every call type. `ReportContentView.sectionLabels` hardcodes those labels, so a custom section wouldn't even render as a card. There is no "regenerate report" action (only the Groq re-transcribe setting).

## Stages

| Stage | Users get | Release |
|---|---|---|
| 1. Foundation | Claude reads profiles. The format below is written down and `get_profile` emits it | Claude launch release |
| 2. Profiles 2.0 | **Report templates + scorecards + "Rewrite report"**, Export / Import / Share, double-click a `.parrotprofile` to add it, "Claude suggests, you approve", "Optimize with Claude" | Right after the Claude launch |
| 3. Gallery | Profile gallery on openparrot.app, **Browse Profiles** in Parrot, one-click install, update notices | When stage 2 gets used |
| 4. Marketplace | Creator pages, ratings, categories, maybe paid expert profiles | When there's traction |

---

## The file format (designed now, used by every stage)

A `.parrotprofile` file is UTF-8 JSON, human-readable, at most 64 KB.

```json
{
  "format": "parrot.profile",
  "formatVersion": 1,
  "sharedID": "7C1E…-stable-for-life",
  "version": 3,
  "profile": {
    "name": "Investor pitch",
    "icon": "chart.line.uptrend.xyaxis",
    "summary": "Pitching to VCs and angels.",
    "persona": "You are coaching a founder pitching …",
    "tone": "Short, direct cards.",
    "counterpart": "the investor",
    "allowGeneralKnowledge": true,
    "kinds": [
      { "key": "objection", "label": "Objection", "color": "D9534F", "icon": "exclamationmark.bubble",
        "trigger": "The investor pushes back on market size, team or traction.", "pinned": true, "priority": 2 }
    ],
    "gauges": [
      { "key": "interest", "label": "Interest", "low": "Cold", "high": "Leaning in", "color": "3F9168" }
    ],
    "report": {
      "sections": [
        { "key": "overview",  "title": "Overview",            "type": "prose",   "guide": "2-3 sentences: what the call was about and how it ended." },
        { "key": "liked",     "title": "What they liked",     "type": "bullets", "guide": "Parts of the pitch the investor responded well to." },
        { "key": "concerns",  "title": "Their concerns",      "type": "bullets", "guide": "Doubts about market, team, traction or terms." },
        { "key": "asks",      "title": "What they asked for", "type": "bullets", "guide": "Data, metrics or intros they requested." },
        { "key": "fit",       "title": "Fit",                 "type": "scorecard",
          "criteria": [
            { "key": "stage", "label": "Stage fit",   "guide": "Do they invest at our stage?" },
            { "key": "check", "label": "Check size",  "guide": "Does their typical check match the round?" }
          ] },
        { "key": "next",      "title": "Next steps",          "type": "bullets", "commitments": true, "guide": "Only what someone actually said they'd do." }
      ],
      "coaching": { "enabled": true, "role": "pitch coach",
                    "focus": "Clarity of the story, handling tough questions, the ask." }
    }
  },
  "privacy": { "recommendOnDeviceOnly": false },
  "meta": {
    "description": "Flags objections, asks and follow-up promises on investor calls.",
    "author": "Optional name", "authorURL": "https://…",
    "language": "en", "category": "fundraising", "tags": ["vc", "seed"],
    "license": "CC-BY-4.0",
    "source": "user | claude | gallery | builtin",
    "basedOn": { "sharedID": "…", "version": 2 },
    "createdWith": "Parrot 1.8.0"
  },
  "suggestion": { "targetSharedID": "…", "reason": "Your last 10 sales calls ignored 80% of 'Small talk' cards …" }
}
```

**Rules:**
- **`sharedID` + `version`** identify a profile across Macs for life. They let the gallery say "v3 available" and let an import recognise "this is an update to a profile you have". `CallProfile` gains `sharedID: UUID?`, `sharedVersion: Int = 0` and `sharedSource: String?` (defaulted properties, so the existing store migrates). The local `id` never leaves the Mac.
- **Built-ins get fixed `sharedID`s** (their existing preset UUIDs), so the gallery can host improved versions of them too.
- **Unknown fields are kept and ignored.** A marketplace can add `price` or `creatorID` later without breaking older Parrots.
- **Never in the file:** meeting content, names from calls, knowledge-base documents or their tags, local IDs, API keys, any setting outside the profile. The export screen shows the exact contents before saving.
- **Privacy:** `recommendOnDeviceOnly: true` turns on-device-only **on** at import. Nothing in any file can turn it off; the importer ignores any attempt.
- **No `report` block = the Default template** (today's report, word for word), so old files and old profiles behave exactly as now.
- **Section types:** `prose` (a short paragraph), `bullets`, `scorecard` (criteria scored 1-5 with evidence, or "not enough evidence"). `commitments: true` marks a section whose bullets must be things someone actually said; those sections feed "what did I promise?" (`list_commitments`) and the receipts check.
- **Limits:** at most 8 report sections, 8 scorecard criteria, section guides at most 300 characters; at most 20 kinds and 6 gauges; `persona`/`tone` at most 4,000 characters each; other text at most 300. Colors must be 6-digit hex (else a default); an unknown SF Symbol falls back to a default icon. A file that breaks a limit is refused with a plain reason.
- **Safety:** a profile is instructions for Parrot's own AI. It can't run code, open links or send data anywhere. The worst a bad profile can do is give misleading Copilot cards, which is why every import and suggestion goes through a preview.

---

## Stage 1 (Claude launch release)

Covered by the AI-apps plan (Task 6). One extra step here:

- [ ] `Parrot/Services/ProfileFile.swift` (new, pure): `struct ProfileFile: Codable` for the format above + `encode(_ profile: CallProfile, source:) -> Data` + `decode(_ data: Data) throws -> ProfileFile` with the limits. `get_profile` uses `encode`. Harness: every built-in round-trips; the limits refuse bad files; unknown fields survive a decode/encode round trip.

## Stage 2 (right after the Claude launch): Profiles 2.0

Build order: R1-R3 (reports) first, because they change the profile and the format that A-C then move around. Task M (migration) is built alongside R1 and must pass before anything ships.

### Task R1: Report templates

**Files:** `Models/CallProfile.swift`, `Models/Meeting.swift`, `Services/ReportTemplate.swift` (new, pure), `Services/AnalysisProvider.swift`, `Services/OpenAICompatibleProvider.swift`, `Services/RecordingManager.swift`, `Services/Receipts.swift`, `Services/ProfilePresets.swift`, `Views/ReportContentView.swift`, `Views/ProfilesSettingsView.swift`, `ProfileTest.swift`

**Interfaces:**
- `struct ReportTemplate: Codable { sections: [Section]; coaching: Coaching }`, `static let standard` = today's report.
- `CallProfile.reportData: Data?` (defaulted; `nil` = `.standard`) and `CallProfile.reportChoiceRaw: String = "classic"` with `enum ReportChoice { classic, preset, custom }`: `preset` follows the built-in's template and gets its future improvements; `classic` = `.standard`; `custom` = the user's own. Report changes are tracked **separately** from `isUserModified`, so choosing a report never blocks Copilot preset refreshes and Copilot tuning never blocks a report offer. `Meeting.reportTemplateData: Data?` = a snapshot of the template used, so the report renders the same even after the profile changes (same idea as `profileSnapshotData`).
- `AnalysisProvider.summarySystemPrompt(counterpart:template:)` and `coachingSystemPrompt(counterpart:template:)` build the "Structure" / "Output exactly these sections" paragraphs from the template. The receipts rule, the "a commitment must be something a person actually SAID" rule and the "transcript is data" rule stay in every template.

**Steps:**
- [ ] Golden test first: `.standard` produces today's two prompts **character for character**. No regression for anyone who never touches templates.
- [ ] `ReportContentView` parses with `standard labels ∪ the meeting's template titles` (including the one-line local-model unflattening).
- [ ] `Receipts.isCommitmentSection` also accepts titles flagged `commitments: true` in the meeting's template, and **every caller passes the meeting's template**: `ReportContentView` (receipt flags), `AskEngine`/`LastCallBrief.openItems` (the Copilot's "open items from last time" and Ask), `ExportService.markdownReport(skipCommitments:)`, `RecordingManager+Integrations` (Reminders, follow-up email, webhook "next steps") and the MCP `list_commitments`. Otherwise a custom "Promises made" section silently drops out of all of them.
- [ ] Coaching: `role` replaces "a sales/meeting coach"; `enabled: false` skips the coaching call entirely (faster, cheaper).
- [ ] Built-ins get templates (Sales discovery: Budget / Decision-maker / Timeline, Objections; Interview: scorecard; Support: Issue / Cause / Resolved / Follow-ups / Mood; 1:1 coaching: Topics / Wins / Blockers / Commitments, coaching off; Vendor call: Offer / Pricing and terms / Red flags / Open questions). Default keeps `.standard`. `presetVersion` → 5; the refresh keeps skipping the Copilot fields of `isUserModified` profiles as today, and updates a built-in's report only when its `reportChoice == .preset`.
- [ ] New built-in **Investor pitch** profile (kinds, gauges and the report above).
- [ ] Profile editor gets a **Report** tab: sections (add, remove, reorder, title + "what goes here" + type + "these are commitments"), coaching on/off + coach role + focus. "Reset to default report".
- [ ] Local models: run `--analyze-test` with each built-in template on the Ollama default model; a template that the model can't follow reliably gets simplified before shipping.

### Task M: Moving existing users to Profiles 2.0

Runs once, on the first launch after the update, inside `ProfileStore.seedAndMigrateIfNeeded` (existing installs only: profiles exist and the stored `presetVersion` < 5). Fresh installs skip it and simply get the built-ins with their templates.

**Files:** `ProfileStore.swift`, `ProfilePresets.swift`, `Models/CallProfile.swift`, `ProfileFile.swift`, `Views/ProfileMigrationView.swift` (new), `ContentView.swift` (presents it once), `ProfileTest.swift`

**Order (each step idempotent, so a crash mid-way just re-runs):**
1. **Backup:** every profile written as a `.parrotprofile` to `Application Support/Parrot/Backups/profiles-before-2.0/` (never deleted automatically). Restoring = Import.
2. **Sharing IDs:** built-ins get their preset UUID as `sharedID`; user-made profiles get a new `sharedID`; `sharedVersion = 1`.
3. **Restore point:** each profile's history (Task C) gets a first entry, "Before Profiles 2.0".
4. **Report choice:**
   - built-in, not `isUserModified` → `.preset` (new template, automatic)
   - built-in, `isUserModified` → `.classic` + `reportOfferPending = true`
   - user-made (including duplicates of built-ins) → `.classic`
5. **Copilot fields untouched** for tuned built-ins and user-made profiles: persona, tone (custom rules), counterpart, kinds, gauges, on-device-only, knowledge-document tags.
6. Set `profiles2MigrationDone`; show the screen below once (`profiles2ScreenShown`).

**The one-time screen** ("Reports can now match each call type"):
- One row per profile: name, a small before/after of the section titles, a switch "Use the new report".
- Switches start **on** for untouched built-ins and **off** for tuned built-ins and user-made profiles. (User-made profiles show "Create a report template later in the profile's settings" instead of a preview.)
- Flipping sets `.preset` or `.classic`. **Done** closes it for good. Closing it any other way keeps the defaults, and it doesn't come back.
- A line at the bottom: "Your Copilot settings didn't change. A backup of every profile was saved."

**Afterwards:**
- Tuned built-ins with `reportOfferPending` show a small card in the profile editor: "A Sales report format is available. Preview / Use it / Keep classic". Either answer clears the flag.
- User-made profiles: "Create a report template" in the Report tab, from a starter (the built-in templates) or via Claude (`design_report`).
- **Past meetings:** `reportTemplateData == nil` renders with the standard labels, exactly as today. Upgrading one = **Rewrite report** (R3). No bulk rewrite.
- **Custom rules** (`tone`) keep reaching both the Copilot and the report, as today, so "always mention budget in the report" still works.

**Harness (from a v4 store fixture):**
- untouched built-in → `.preset` + template
- tuned built-in → `.classic` + offer flag, with persona, kinds and gauges byte-identical before and after
- user-made profile → `.classic`, fields identical
- a backup file per profile, and each backup decodes
- built-in `sharedID`s equal the preset UUIDs
- one history entry per profile
- running the migration twice changes nothing
- an old meeting's report parses into the same sections as before

**Store safety:** every SwiftData change here is an added, defaulted property (lightweight migration). No renames or removals. Downgrading after the update isn't supported (normal for Sparkle updates), and release notes say so.

### Task R2: Scorecards

**Files:** `ReportTemplate.swift`, `AnalysisProvider.swift`, `ReportContentView.swift`, `ProfileTest.swift`

- [ ] Prompt asks for one line per criterion: `Label: 4/5 - evidence [mm:ss]`, or `Label: not enough evidence`. Never a score without a receipt.
- [ ] Rendered as a score row per criterion (bar + number + receipt chip); unparseable lines fall back to plain bullets.
- [ ] Fairness guard in every scorecard prompt: score only the listed criteria from what was said; never age, gender, accent, looks or other personal traits; no hire/no-hire verdict unless the profile explicitly asks for a recommendation section.
- [ ] Harness: parsing `4/5`, `not enough evidence`, a missing receipt (dropped), out-of-range scores (dropped).

### Task R3: Rewrite report with a different profile

**Files:** `MeetingDetailView.swift`, `RecordingManager.swift`, `Models/Meeting.swift`, `ProfileTest.swift`

- [ ] Meeting page: **Rewrite Report…** → pick a profile (current one preselected, so "rewrite with my improved profile" is one click) → regenerates report + coaching with that profile's template, and sets the meeting's profile to it.
- [ ] The previous report is kept (`Meeting.previousReportData`: summary, coaching, template snapshot, profile id); **Undo Rewrite** restores it. One level is enough.
- [ ] Same routing and privacy as the first report: on-device-only meetings stay on the local model.
- [ ] The memory index re-indexes the new report (existing fingerprint covers summary and coaching).

### Task A: Export, Import, Share

**Files:** `ProfileFile.swift`, `ProfileStore.swift`, `ProfilesSettingsView.swift`, `ParrotApp.swift` (open-file handling), `project.yml` / Makefile Info.plist (document type `com.uygar.parrot.profile`, extension `.parrotprofile`), `ProfileTest.swift`

- [ ] Profile editor gets **Export…** (save panel) and **Share…** (the macOS share sheet: Mail, Messages, AirDrop).
- [ ] **Import…** in the profiles list, drag-and-drop onto the list, and double-clicking a `.parrotprofile` all open the **Review screen** (Task C).
- [ ] New `sharedID` → added as a new profile (`isBuiltIn = false`, `sharedSource` from `meta.source`).
- [ ] Known `sharedID` → treated as an update: if the local copy isn't user-modified, offer **Update**; if it is, offer **Keep mine / Use theirs / Keep both**.
- [ ] The profile starts with no knowledge-base documents; the Review screen says "Add your own documents after importing".

### Task B: Claude suggests (MCP)

**Files:** `MCPServer.swift`, `MCPPrompts.swift`, `ProfileFile.swift`, `ProfileTest.swift`

- [ ] New tool `suggest_profile(profile_json, reason)`. It validates with `ProfileFile.decode`, then writes the file to `Application Support/Parrot/ProfileInbox/<uuid>.parrotprofile`. It never touches SwiftData. The description says the user must approve it in Parrot. Annotations: `readOnlyHint: false`, `destructiveHint: false`.
- [ ] At most 10 files in the inbox (oldest dropped); switch-off or "Allow Claude to suggest profiles" off (new key `mcpAllowProfileSuggestions`, default on) makes the tool refuse.
- [ ] New prompts:
  - `create_profile(call_type)`: Claude asks a few questions, then calls `suggest_profile`.
  - `optimize_profile(profile, last_n = 10)`: Claude reads the profile, the last N meetings' transcripts, reports and **Copilot cards with handled/ignored state**, finds cards that were ignored, moments that were missed and report sections that came out empty or generic, and suggests a better profile (Copilot and report) with a reason per change. Needs "Copilot cards" shared; the prompt tells Claude to ask the user to tick it if it's off.
  - `design_report(profile, description)`: "make my interview report match our hiring scorecard"; Claude drafts the report template and scorecard, then calls `suggest_profile`.
- [ ] Harness: a valid suggestion lands in the inbox; an invalid one returns the reason and writes nothing; a suggestion trying `onDeviceOnly: false` on an on-device profile has no effect after review.

### Task C: Review screen, Apply, Undo

**Files:** `ProfileReviewView.swift` (new), `ProfileStore.swift`, `RecordingManager` or `AppSession` (inbox watcher), `Theme.swift`

- [ ] The app watches `ProfileInbox/`; a new file shows a banner: "Claude suggested changes to 'Sales discovery'. Review." (or "…a new profile: 'Investor pitch'").
- [ ] **Review screen**, shared by imports and suggestions:
  - who it came from (you / Claude / a file / the gallery) and Claude's reason
  - side-by-side changes, grouped as persona, what to flag (added / removed / changed kinds), report (sections, scorecard, coaching), mood meters, other
  - the privacy line when it turns on-device-only on
- [ ] Buttons: **Apply** · **Save as new profile** · **Discard**.
- [ ] **Undo:** `ProfileStore` keeps the last 5 versions of each profile (a JSON history via `ProfileFile`); the editor gets "Restore previous version".
- [ ] Applying marks the profile `isUserModified` (so preset refreshes keep it) and bumps `sharedVersion`.
- [ ] A suggestion is never applied mid-call: if a call is live with that profile, Apply waits until the call ends and says so.

### Task D: Docs

- [ ] Help: "Report templates and scorecards", "Rewrite a report", "Share and import profiles", "Let Claude build or tune a profile" (with the three prompts), and "What changed in Profiles 2.0" (the migration in plain words: Copilot untouched, which reports changed, how to switch back, where the backup is).
- [ ] Release notes + in-app What's New say the same, in two or three lines.
- [ ] AI-apps page (Task 9 there): the six jobs gain a seventh, **"Tune my Copilot"**.

## Stage 3: Gallery (when stage 2 gets used)

- [ ] **Source of truth:** a public GitHub repo (e.g. `turantekin/parrot-profiles`), one `.parrotprofile` per folder with a README and a screenshot. CI validates each file with the same rules (a small script, or `Parrot --validate-profile` in CI) and builds `index.json`.
- [ ] **Submission:** a pull request, or a form on openparrot.app that opens one. The owner approves each. A profile can be reported, and the gallery can pull it.
- [ ] **Website:** openparrot.app/profiles with category pages (Sales, Hiring, Fundraising, Support, Coaching, Legal, Health), search and "Open in Parrot" buttons.
- [ ] **In the app:** **Browse Profiles** fetches `index.json` from openparrot.app. This is user-initiated and sends nothing about the user (a plain GET of public files). Install goes through the Review screen. New URL scheme `parrot://profile/install?url=…` for one-click install from the website; it only accepts `https://openparrot.app/…` URLs.
- [ ] **Update notices:** once a day, and only when the user has gallery profiles installed, compare `sharedID`/`version` against `index.json`: "Investor pitch v4 is available". Same Keep mine / Use theirs choice as imports.
- [ ] **No empty shelves:** open the gallery with 15-20 strong profiles made by the owner (built-ins, Investor pitch, plus ones built with Claude for recruiters, consultants, agencies, real estate, founders' customer calls) before accepting outside submissions.
- [ ] License: gallery profiles are CC BY 4.0 (free to use and remix, with credit); `basedOn` records the lineage.

## Stage 4: Marketplace (decide when there's traction)

Open questions, not decided:
- **Accounts:** creator pages and ratings need identities. Reuse GitHub sign-in, or add openparrot.app accounts?
- **Quality signals:** installs and ratings would need an opt-in anonymous ping, which is a change for a local-first app. It needs its own privacy decision.
- **Paid profiles:** price, payments (e.g. Stripe or Lemon Squeezy), revenue share, refunds, and whether a paid profile can be re-shared (the CC BY gallery license wouldn't apply). The format already allows extra `meta` fields.
- **Moderation at scale:** today it's owner review; later maybe trusted reviewers.
- **Teams:** a private team gallery (a company shares its sales playbook internally) could be the first paid tier.

## Risks

| Risk | Mitigation |
|---|---|
| A shared profile gives bad or manipulative Copilot advice | Preview before install, limits, gallery review, report button; profiles can't act or send data |
| Text inside a recorded call steers Claude into a harmful suggestion | Suggestions only land in the inbox; the user sees every change; privacy can't be loosened |
| An update wipes someone's tuning | `sharedID`/`version` + `isUserModified` → Keep mine / Use theirs / Keep both; 5-version undo |
| Personal data leaks through an export | Fixed field list; KB docs, tags and IDs never exported; the export shows the full contents first |
| Format changes break old files | `formatVersion`; unknown fields kept; decoders accept every older version |
| Custom templates make reports worse on small local models | Limits (8 sections, 8 criteria); every built-in template tested on the default Ollama model; `.standard` stays byte-identical |
| Existing users are surprised by a new report format | Only untouched built-ins switch; one screen, one switch per profile; "classic report" one click away; backup + restore point |
| Migration crashes half-way | Every step idempotent; backup written first; re-runs on next launch |
| Scorecards encourage biased judgments (interviews) | Criteria-only scoring with receipts, explicit fairness guard, no verdict by default |

## Size

Stage 1 extra: 1 day. Stage 2: about 3.5-4 weeks (R1 1 week, M 3 days, R2 3 days, R3 2 days, A 3 days, B 3 days, C 4-5 days, D 1 day). Stage 3: about 1 week of app work plus the website pages. Stage 4: not sized.
